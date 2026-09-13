//
//  TCPRelay.swift
//  ProxyPilotTransparentProxy
//
//  Relays one intercepted TCP flow through the app's assigned upstream proxy.
//  Two upstream protocols are supported:
//
//    HTTP  — CONNECT <host>:<port> HTTP/1.1 (+ optional Basic auth)
//    SOCKS5 — greeting, optional user/pass auth, then CONNECT
//
//  After the handshake the flow and the upstream connection are spliced
//  bidirectionally. Half-closes are propagated so both sides see EOF normally.
//  All state is confined to a single serial queue; the class is never touched
//  from more than one thread at a time.
//

import Network
import NetworkExtension
import os

final class TCPRelay {

    let id = UUID()
    var onFinish: ((UUID) -> Void)?

    private let flow: NEAppProxyTCPFlow
    private let rule: TransparentRule
    private let queue: DispatchQueue
    private let logger: Logger
    private let passwordProvider: (String?) -> String?

    private var upstream: NWConnection?
    private var didOpenFlow = false
    private var isClosed = false
    private var didFinishRelay = false
    /// First bytes read from the app, used to recover the original hostname
    /// via TLS SNI / HTTP Host before connecting to the upstream proxy.
    private var firstData: Data?

    init(
        flow: NEAppProxyTCPFlow,
        rule: TransparentRule,
        queue: DispatchQueue,
        logger: Logger,
        passwordProvider: @escaping (String?) -> String?
    ) {
        self.flow = flow
        self.rule = rule
        self.queue = queue
        self.logger = logger
        self.passwordProvider = passwordProvider
    }

    // MARK: - Start

    func start() {
        queue.async { [self] in
            guard var destination = Self.destination(of: flow) else {
                logger.warning("TCP relay: no destination endpoint")
                finish()
                return
            }
            guard let port = NWEndpoint.Port(rawValue: UInt16(rule.port)) else {
                logger.warning("TCP relay: invalid proxy port \(rule.port)")
                finish()
                return
            }

            // Open the flow and peek at the first segment. For TLS and HTTP
            // we can recover the original hostname from SNI / Host header,
            // which upstream proxies require because they reject raw-IP
            // connections (geo-DNS, SNI vhosts, corporate proxies).
            flow.open(withLocalEndpoint: nil) { [weak self] error in
                guard let self else { return }
                self.queue.async {
                    if let error {
                        self.logger.error("Flow open failed: \(error.localizedDescription, privacy: .public)")
                        self.finish()
                        return
                    }
                    self.didOpenFlow = true
                    self.flow.readData { [weak self] data, error in
                        guard let self else { return }
                        self.queue.async {
                            if let error {
                                self.logger.error("First read failed: \(error.localizedDescription, privacy: .public)")
                                self.finish()
                                return
                            }
                            if let data, !data.isEmpty {
                                self.firstData = data
                                let isIP = IPv4Address(destination.host) != nil || IPv6Address(destination.host) != nil
                                if isIP, let hostname = SNIHelper.hostname(fromFirstBytes: data) {
                                    self.logger.info("Recovered hostname via SNI/Host: \(destination.host, privacy: .public) → \(hostname, privacy: .public)")
                                    destination.host = hostname
                                }
                            }
                            self.connectUpstream(destination: destination, port: port)
                        }
                    }
                }
            }
        }
    }

    private func connectUpstream(destination: (host: String, port: String), port: Network.NWEndpoint.Port) {
        logger.info("Connecting to proxy \(self.rule.host):\(self.rule.port) for \(destination.host):\(destination.port)")
        let connection = NWConnection(
            host: NWEndpoint.Host(self.rule.host),
            port: port,
            using: .tcp
        )
        upstream = connection
        connection.stateUpdateHandler = { [weak self] state in
            self?.handle(state: state, destination: destination)
        }
        connection.start(queue: queue)
    }

    // MARK: - Upstream state machine

    private func handle(state: NWConnection.State, destination: (host: String, port: String)) {
        switch state {
        case .ready:
            logger.info("Upstream connection ready")
            performHandshake(destination: destination)
        case .failed(let error):
            logger.error("Upstream connection failed: \(error.localizedDescription, privacy: .public)")
            finish()
        case .waiting(let error):
            logger.warning("Upstream waiting: \(error.localizedDescription, privacy: .public)")
        case .cancelled:
            logger.info("Upstream cancelled")
            finish()
        case .preparing:
            logger.info("Upstream preparing")
        default:
            logger.info("Upstream state: \(String(describing: state), privacy: .public)")
        }
    }

    // MARK: - Handshake

    private func performHandshake(destination: (host: String, port: String)) {
        switch rule.proxyType {
        case TransparentProxyConstants.schemeSOCKS5:
            sendSOCKS5Greeting(destination: destination)
        default:
            // "https" is treated as an HTTP CONNECT proxy for now.
            sendHTTPConnect(destination: destination)
        }
    }

    // MARK: HTTP CONNECT

    private func sendHTTPConnect(destination: (host: String, port: String)) {
        guard let connection = upstream else { finish(); return }

        var request = "CONNECT \(destination.host):\(destination.port) HTTP/1.1\r\n"
        request += "Host: \(destination.host):\(destination.port)\r\n"
        if let username = rule.username, !username.isEmpty,
           let password = passwordProvider(rule.passwordAccount) {
            let credentials = Data("\(username):\(password)".utf8).base64EncodedString()
            request += "Proxy-Authorization: Basic \(credentials)\r\n"
        }
        request += "\r\n"

        connection.send(content: Data(request.utf8), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queue.async {
                if let error {
                    self.logger.error("CONNECT send failed: \(error.localizedDescription, privacy: .public)")
                    self.finish()
                    return
                }
                self.readHTTPConnectResponse()
            }
        })
    }

    private func readHTTPConnectResponse() {
        guard let connection = upstream else { finish(); return }

        var buffer = Data()
        func readMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                self.queue.async {
                    if let error {
                        self.logger.error("CONNECT response read failed: \(error.localizedDescription, privacy: .public)")
                        self.finish()
                        return
                    }
                    if let data { buffer.append(data) }
                    if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                        let headerData = buffer.subdata(in: 0..<headerEnd.lowerBound)
                        let leftover = Data(buffer[headerEnd.upperBound...])
                        guard let statusLine = String(data: headerData, encoding: .utf8)?
                            .components(separatedBy: "\r\n").first,
                            let status = statusLine.components(separatedBy: " ").dropFirst().first,
                            status.hasPrefix("2") else {
                            self.logger.error("CONNECT refused: \(String(data: headerData, encoding: .utf8) ?? "?", privacy: .public)")
                            self.finish()
                            return
                        }
                        self.beginRelay(leftover: leftover)
                        return
                    }
                    if isComplete {
                        self.logger.error("CONNECT response ended before headers")
                        self.finish()
                        return
                    }
                    readMore()
                }
            }
        }
        readMore()
    }

    // MARK: SOCKS5

    private func sendSOCKS5Greeting(destination: (host: String, port: String)) {
        guard let connection = upstream else { finish(); return }

        let needsAuth = !(rule.username ?? "").isEmpty
        let greeting: [UInt8] = needsAuth ? [0x05, 0x01, 0x02] : [0x05, 0x01, 0x00]
        logger.info("SOCKS5 sending greeting (auth=\(needsAuth))")

        connection.send(content: Data(greeting), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queue.async {
                if let error {
                    self.logger.error("SOCKS5 greeting send failed: \(error.localizedDescription, privacy: .public)")
                    self.finish()
                    return
                }
                self.logger.info("SOCKS5 greeting sent, waiting for method selection")
                self.receiveExact(2) { data in
                    guard data.count == 2, data[0] == 0x05 else {
                        self.logger.error("SOCKS5 bad greeting response: \(data.map { String(format: "%02x", $0) }.joined(), privacy: .public)")
                        self.finish()
                        return
                    }
                    self.logger.info("SOCKS5 method selected: 0x\(String(format: "%02x", data[1]), privacy: .public)")
                    switch data[1] {
                    case 0x00:
                        self.sendSOCKS5Connect(destination: destination)
                    case 0x02 where needsAuth:
                        self.sendSOCKS5Auth(destination: destination)
                    default:
                        self.logger.error("SOCKS5 no acceptable auth method")
                        self.finish()
                    }
                }
            }
        })
    }

    private func sendSOCKS5Auth(destination: (host: String, port: String)) {
        guard let connection = upstream else { finish(); return }

        let username = rule.username ?? ""
        let password = passwordProvider(rule.passwordAccount) ?? ""
        var request = Data([0x01, UInt8(username.utf8.count)])
        request.append(Data(username.utf8))
        request.append(UInt8(password.utf8.count))
        request.append(Data(password.utf8))

        connection.send(content: request, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queue.async {
                if let error {
                    self.logger.error("SOCKS5 auth send failed: \(error.localizedDescription, privacy: .public)")
                    self.finish()
                    return
                }
                self.receiveExact(2) { data in
                    guard data.count == 2, data[0] == 0x01, data[1] == 0x00 else {
                        self.logger.error("SOCKS5 auth rejected")
                        self.finish()
                        return
                    }
                    self.sendSOCKS5Connect(destination: destination)
                }
            }
        })
    }

    private func sendSOCKS5Connect(destination: (host: String, port: String)) {
        guard let connection = upstream, let address = Self.socksAddress(destination.host) else {
            finish()
            return
        }

        let port = UInt16(destination.port) ?? 0
        var request = Data([0x05, 0x01, 0x00])
        request.append(address)
        request.append(contentsOf: [UInt8(port >> 8), UInt8(port & 0xFF)])

        connection.send(content: request, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queue.async {
                if let error {
                    self.logger.error("SOCKS5 connect send failed: \(error.localizedDescription, privacy: .public)")
                    self.finish()
                    return
                }
                self.readSOCKS5ConnectReply()
            }
        })
    }

    private func readSOCKS5ConnectReply() {
        receiveExact(4) { [weak self] data in
            guard let self else { return }
            guard data.count == 4, data[0] == 0x05, data[1] == 0x00 else {
                let code = data.count > 1 ? data[1] : 0xFF
                self.logger.error("SOCKS5 connect failed (code \(code))")
                self.finish()
                return
            }
            self.logger.info("SOCKS5 connect OK")
            // Reply carries the bound address; read and discard it.
            let atyp = data[3]
            let addressLength: Int
            switch atyp {
            case 0x01: addressLength = 4
            case 0x04: addressLength = 16
            case 0x03: addressLength = 1 + 255 // length byte + up to 255 bytes
            default:
                self.logger.error("SOCKS5 bad atyp \(atyp)")
                self.finish()
                return
            }
            if atyp == 0x03 {
                self.receiveExact(1) { lengthData in
                    guard lengthData.count == 1 else { self.finish(); return }
                    self.receiveExact(Int(lengthData[0]) + 2) { _ in
                        self.beginRelay(leftover: nil)
                    }
                }
            } else {
                self.receiveExact(addressLength + 2) { _ in
                    self.beginRelay(leftover: nil)
                }
            }
        }
    }

    // MARK: - Splice

    private func beginRelay(leftover: Data?) {
        guard !isClosed else { return }
        // The flow was already opened in start() to peek at SNI.
        guard didOpenFlow else {
            logger.error("beginRelay: flow not opened")
            finish()
            return
        }
        logger.info("Begin relay (firstData=\(self.firstData?.count ?? 0)B, leftover=\(leftover?.count ?? 0)B)")

        // Send the first segment we peeked at (TLS ClientHello / HTTP request)
        // to the upstream proxy now that the tunnel is established.
        if let firstData, !firstData.isEmpty {
            logger.info("Forwarding first segment to upstream (\(firstData.count)B)")
            sendToUpstream(firstData)
            self.firstData = nil
        }
        // Forward any leftover bytes from the proxy's handshake response
        // (e.g. HTTP CONNECT 200 followed by early server data) to the app.
        if let leftover, !leftover.isEmpty {
            writeToFlow(leftover)
        }
        startFlowReadLoop()
        startUpstreamReadLoop()
    }

    private func startFlowReadLoop() {
        guard !isClosed else { return }
        flow.readData(completionHandler: { [weak self] data, error in
            guard let self else { return }
            self.queue.async {
                if let data, !data.isEmpty {
                    self.logger.info("App→Proxy: \(data.count)B")
                    self.sendToUpstream(data)
                }
                let eof = data?.isEmpty == true
                if eof || error != nil {
                    // The app closed its write side — half-close upstream.
                    self.halfCloseUpstreamWrite()
                    return
                }
                self.startFlowReadLoop()
            }
        })
    }

    private func startUpstreamReadLoop() {
        guard let connection = upstream, !isClosed else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.queue.async {
                if let data, !data.isEmpty {
                    self.logger.info("Proxy→App: \(data.count)B")
                    self.writeToFlow(data)
                }
                if isComplete || error != nil {
                    // Upstream closed — close the app's read side, passing the
                    // error so the app sees the real cause.
                    self.flow.closeReadWithError(error)
                    return
                }
                self.startUpstreamReadLoop()
            }
        }
    }

    // MARK: - Data movement

    private func sendToUpstream(_ data: Data) {
        guard let connection = upstream else { return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                self.queue.async {
                    self.logger.error("Upstream write failed: \(error.localizedDescription, privacy: .public)")
                    self.flow.closeWriteWithError(error)
                }
            }
        })
    }

    private func writeToFlow(_ data: Data) {
        guard didOpenFlow else { return }
        flow.write(data) { [weak self] error in
            guard let self else { return }
            if let error {
                self.queue.async {
                    self.logger.error("Flow write failed: \(error.localizedDescription, privacy: .public)")
                    self.upstream?.cancel()
                }
            }
        }
    }

    private func halfCloseUpstreamWrite() {
        guard let connection = upstream else { return }
        // nil content + isComplete signals EOF on the write side; the read side
        // stays open so the proxy can finish flushing its response.
        connection.send(content: nil, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                self.queue.async {
                    self.logger.error("Upstream half-close failed: \(error.localizedDescription, privacy: .public)")
                    self.finish()
                }
            }
        })
    }

    // MARK: - Teardown

    func close() {
        queue.async { [self] in
            finish()
        }
    }

    private func finish() {
        guard !isClosed else { return }
        isClosed = true
        upstream?.cancel()
        upstream = nil
        if didOpenFlow {
            flow.closeReadWithError(nil)
            flow.closeWriteWithError(nil)
        }
        guard !didFinishRelay else { return }
        didFinishRelay = true
        let relayID = id
        onFinish?(relayID)
        onFinish = nil
    }

    // MARK: - Endpoint helpers

    /// The destination the app tried to reach. Prefers the original hostname
    /// (connect-by-name flows) so the proxy resolves DNS remotely.
    private static func destination(of flow: NEAppProxyTCPFlow) -> (host: String, port: String)? {
        if #available(macOS 15.0, *) {
            // The SDK maps nw_endpoint_t to the Network.NWEndpoint enum.
            let endpoint = flow.remoteFlowEndpoint
            guard case .hostPort(let host, let port) = endpoint else { return nil }
            let hostString: String
            switch host {
            case .name(let name, _): hostString = name
            case .ipv4(let address): hostString = address.debugDescription
            case .ipv6(let address): hostString = address.debugDescription
            @unknown default: return nil
            }
            guard !hostString.isEmpty else { return nil }
            return (hostString, "\(port.rawValue)")
        }
        // macOS 14: the endpoint arrives as the deprecated ObjC wrapper.
        if let hostname = flow.remoteHostname, !hostname.isEmpty,
           let destination = legacyDestination(of: flow) {
            return (hostname, destination.port)
        }
        return legacyDestination(of: flow)
    }

    /// `flow.remoteEndpoint` is deprecated in macOS 15 in favour of
    /// `remoteFlowEndpoint`; the deployment target is 14.0, so this wrapper
    /// keeps the correct API for the target while silencing the warning.
    @available(macOS, deprecated: 15.0)
    private static func legacyDestination(of flow: NEAppProxyTCPFlow) -> (host: String, port: String)? {
        guard let endpoint = flow.remoteEndpoint as? NWHostEndpoint,
              !endpoint.hostname.isEmpty else { return nil }
        return (endpoint.hostname, endpoint.port)
    }

    /// SOCKS5 ATYP + address bytes for a hostname or IP.
    private static func socksAddress(_ host: String) -> Data? {
        if let ipv4 = IPv4Address(host) {
            return Data([0x01]) + Data(ipv4.rawValue)
        }
        if let ipv6 = IPv6Address(host) {
            return Data([0x04]) + Data(ipv6.rawValue)
        }
        let bytes = Array(host.utf8)
        guard !bytes.isEmpty, bytes.count <= 255 else { return nil }
        return Data([0x03, UInt8(bytes.count)]) + Data(bytes)
    }

    // MARK: - Exact-length receive helper

    /// Reads exactly `count` bytes from the upstream connection, delivering them
    /// on `queue`. Used for the fixed-size SOCKS5 handshake frames.
    private func receiveExact(_ count: Int, then: @escaping (Data) -> Void) {
        guard let connection = upstream else { finish(); return }

        var collected = Data()
        func readRemaining(_ remaining: Int) {
            guard remaining > 0 else {
                queue.async { then(collected) }
                return
            }
            connection.receive(minimumIncompleteLength: remaining, maximumLength: remaining) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                self.queue.async {
                    if let error {
                        self.logger.error("SOCKS5 read failed: \(error.localizedDescription, privacy: .public)")
                        self.finish()
                        return
                    }
                    if let data {
                        collected.append(data)
                        readRemaining(remaining - data.count)
                        return
                    }
                    if isComplete {
                        self.finish()
                        return
                    }
                    readRemaining(remaining)
                }
            }
        }
        readRemaining(count)
    }
}
