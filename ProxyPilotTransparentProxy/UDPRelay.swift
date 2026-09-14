//
//  UDPRelay.swift
//  ProxyPilotTransparentProxy
//
//  Relays UDP traffic (including DNS on port 53) through a SOCKS5 proxy
//  using the UDP ASSOCIATE command. Only SOCKS5 supports UDP; HTTP CONNECT
//  proxies cannot relay UDP, so those flows are handed back to the system.
//
//  The initial remote endpoint is obtained from the first datagram read
//  (NEAppProxyUDPFlow has no remoteEndpoint property on macOS 15; the
//  endpoint arrives with each datagram via readDatagramsAndFlowEndpoints).
//
//  SOCKS5 UDP encapsulation:
//    +----+------+------+----------+----------+----------+
//    |RSV | FRAG | ATYP | DST.ADDR | DST.PORT |   DATA   |
//    +----+------+------+----------+----------+----------+
//    | 2  |  1   |  1   | Variable |    2     | Variable |
//    +----+------+------+----------+----------+----------+
//

import Foundation
import Network
import NetworkExtension
import os

final class UDPRelay {

    let id = UUID()
    private let flow: NEAppProxyUDPFlow
    private let rule: TransparentRule
    private let queue: DispatchQueue
    private let logger: Logger
    private let passwordProvider: (String?) -> String?

    private var controlConnection: NWConnection?   // TCP control channel for SOCKS5
    private var udpConnection: NWConnection?       // UDP channel to the relay endpoint
    private var isClosed = false
    private var didStartRelay = false
    var onFinish: ((UUID) -> Void)?

    /// Encapsulated SOCKS5 packets read before the relay channel is established.
    private var pendingPackets: [Data] = []

    init(
        flow: NEAppProxyUDPFlow,
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
            // 1. Open the flow and read the first datagram to learn the destination.
            flow.open(withLocalEndpoint: nil) { [weak self] error in
                guard let self else { return }
                self.queue.async {
                    if let error {
                        self.logger.error("UDP flow open failed: \(error.localizedDescription, privacy: .public)")
                        self.finish()
                        return
                    }
                    self.readFirstDatagram()
                }
            }
        }
    }

    private func readFirstDatagram() {
        guard !isClosed else { return }
        flow.readDatagrams { [weak self] datagrams, endpoints, error in
            guard let self else { return }
            self.queue.async {
                if let error {
                    self.logger.error("UDP first read failed: \(error.localizedDescription, privacy: .public)")
                    self.finish()
                    return
                }
                guard let datagrams, let endpoints, !datagrams.isEmpty else {
                    self.finish()
                    return
                }
                for (datagram, endpoint) in zip(datagrams, endpoints) {
                    if let hostEndpoint = endpoint as? NWHostEndpoint,
                       let packet = Self.encodeSOCKS5UDP(datagram: datagram, endpoint: hostEndpoint) {
                        self.pendingPackets.append(packet)
                    }
                }
                // Log the first destination for diagnostics.
                if let first = endpoints.first as? NWHostEndpoint {
                    self.logger.info("UDP first datagram → \(first.hostname, privacy: .public):\(first.port, privacy: .public) (\(datagrams[0].count)B)")
                }
                self.connectControlChannel()
            }
        }
    }

    // MARK: - SOCKS5 control channel

    private func connectControlChannel() {
        guard let port = NWEndpoint.Port(rawValue: UInt16(self.rule.port)) else {
            logger.error("UDP relay: invalid proxy port \(self.rule.port)")
            finish()
            return
        }
        logger.info("UDP relay: connecting SOCKS5 control \(self.rule.host):\(self.rule.port)")
        let connection = NWConnection(
            host: NWEndpoint.Host(self.rule.host),
            port: port,
            using: .tcp
        )
        controlConnection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.queue.async {
                switch state {
                case .ready:
                    self.logger.info("UDP relay: control channel ready")
                    self.sendSOCKS5Greeting()
                case .failed(let error):
                    self.logger.error("UDP relay: control failed: \(error.localizedDescription, privacy: .public)")
                    self.finish()
                case .cancelled:
                    self.finish()
                default:
                    break
                }
            }
        }
        connection.start(queue: queue)
    }

    private func sendSOCKS5Greeting() {
        guard let connection = controlConnection else { finish(); return }
        let needsAuth = !(rule.username ?? "").isEmpty
        let greeting: [UInt8] = needsAuth ? [0x05, 0x01, 0x02] : [0x05, 0x01, 0x00]

        connection.send(content: Data(greeting), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queue.async {
                if let error {
                    self.logger.error("UDP relay: greeting failed: \(error.localizedDescription, privacy: .public)")
                    self.finish()
                    return
                }
                self.receiveExact(2) { data in
                    guard data.count == 2, data[0] == 0x05 else {
                        self.logger.error("UDP relay: bad greeting response")
                        self.finish()
                        return
                    }
                    switch data[1] {
                    case 0x00:
                        self.sendUDPAssociate()
                    case 0x02 where needsAuth:
                        self.sendAuthThenAssociate()
                    default:
                        self.logger.error("UDP relay: no acceptable auth")
                        self.finish()
                    }
                }
            }
        })
    }

    private func sendAuthThenAssociate() {
        guard let connection = controlConnection else { finish(); return }
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
                    self.logger.error("UDP relay: auth failed: \(error.localizedDescription, privacy: .public)")
                    self.finish()
                    return
                }
                self.receiveExact(2) { data in
                    guard data.count == 2, data[0] == 0x01, data[1] == 0x00 else {
                        self.logger.error("UDP relay: auth rejected")
                        self.finish()
                        return
                    }
                    self.sendUDPAssociate()
                }
            }
        })
    }

    /// Send UDP ASSOCIATE (CMD=0x03) with 0.0.0.0:0 — the proxy picks the relay address.
    private func sendUDPAssociate() {
        guard let connection = controlConnection else { finish(); return }

        // ATYP=0x01 (IPv4), address 0.0.0.0, port 0
        let request = Data([0x05, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])

        connection.send(content: request, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queue.async {
                if let error {
                    self.logger.error("UDP relay: ASSOCIATE send failed: \(error.localizedDescription, privacy: .public)")
                    self.finish()
                    return
                }
                self.readUDPAssociateReply()
            }
        })
    }

    private func readUDPAssociateReply() {
        receiveExact(4) { [weak self] data in
            guard let self else { return }
            guard data.count == 4, data[0] == 0x05, data[1] == 0x00 else {
                let code = data.count > 1 ? data[1] : 0xFF
                self.logger.error("UDP relay: ASSOCIATE failed (code \(code))")
                self.finish()
                return
            }
            let atyp = data[3]
            switch atyp {
            case 0x01: // IPv4
                self.receiveExact(4 + 2) { addrData in
                    let ipData = Array(addrData.prefix(4))
                    let portData = Array(addrData.suffix(2))
                    let ip = "\(ipData[0]).\(ipData[1]).\(ipData[2]).\(ipData[3])"
                    let port = UInt16(portData[0]) << 8 | UInt16(portData[1])
                    self.openUDPRelay(host: ip, port: port)
                }
            case 0x04: // IPv6
                self.receiveExact(16 + 2) { addrData in
                    let ipData = Array(addrData.prefix(16))
                    let portData = Array(addrData.suffix(2))
                    let ip = ipData.map { String(format: "%02x", $0) }.joined(separator: ":")
                    let port = UInt16(portData[0]) << 8 | UInt16(portData[1])
                    self.openUDPRelay(host: ip, port: port)
                }
            case 0x03: // Domain
                self.receiveExact(1) { lenData in
                    let len = Int(lenData[0])
                    self.receiveExact(len + 2) { hostData in
                        let hostBytes = Array(hostData)
                        let host = String(bytes: hostBytes.prefix(len), encoding: .utf8) ?? ""
                        let port = UInt16(hostBytes[len]) << 8 | UInt16(hostBytes[len + 1])
                        self.openUDPRelay(host: host, port: port)
                    }
                }
            default:
                self.logger.error("UDP relay: bad atyp \(atyp)")
                self.finish()
            }
        }
    }

    // MARK: - UDP relay channel

    private func openUDPRelay(host: String, port: UInt16) {
        logger.info("UDP relay: relay endpoint \(host):\(port)")
        guard let relayPort = NWEndpoint.Port(rawValue: port) else {
            logger.error("UDP relay: invalid relay port")
            finish()
            return
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: relayPort,
            using: .udp
        )
        udpConnection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.queue.async {
                switch state {
                case .ready:
                    self.logger.info("UDP relay: UDP channel ready, flushing \(self.pendingPackets.count) pending packet(s)")
                    self.didStartRelay = true
                    self.flushPendingPackets()
                    self.startFlowReadLoop()
                    self.startUDPReadLoop()
                case .failed(let error):
                    self.logger.error("UDP relay: UDP channel failed: \(error.localizedDescription, privacy: .public)")
                    self.finish()
                case .cancelled:
                    self.finish()
                default:
                    break
                }
            }
        }
        connection.start(queue: queue)
    }

    private func flushPendingPackets() {
        for packet in pendingPackets {
            sendToUDPRelay(packet)
        }
        pendingPackets.removeAll()
    }

    // MARK: - App → Proxy

    private func startFlowReadLoop() {
        guard !isClosed else { return }
        flow.readDatagrams { [weak self] datagrams, endpoints, error in
            guard let self else { return }
            self.queue.async {
                if let error {
                    self.logger.error("UDP relay: flow read error: \(error.localizedDescription, privacy: .public)")
                    self.finish()
                    return
                }
                guard let datagrams, let endpoints, !datagrams.isEmpty else {
                    self.finish()
                    return
                }
                for (datagram, endpoint) in zip(datagrams, endpoints) {
                    if let hostEndpoint = endpoint as? NWHostEndpoint,
                       let packet = Self.encodeSOCKS5UDP(datagram: datagram, endpoint: hostEndpoint) {
                        if self.didStartRelay {
                            self.sendToUDPRelay(packet)
                        } else {
                            self.pendingPackets.append(packet)
                        }
                    }
                }
                self.startFlowReadLoop()
            }
        }
    }

    private func sendToUDPRelay(_ data: Data) {
        guard let connection = udpConnection else { return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                self.queue.async {
                    self.logger.error("UDP relay: upstream write failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        })
    }

    // MARK: - Proxy → App

    private func startUDPReadLoop() {
        guard let connection = udpConnection, !isClosed else { return }
        connection.receiveMessage { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.queue.async {
                if let error {
                    self.logger.error("UDP relay: upstream read error: \(error.localizedDescription, privacy: .public)")
                    self.finish()
                    return
                }
                if let data, !data.isEmpty {
                    if let (payload, endpoint) = Self.decodeSOCKS5UDP(packet: data) {
                        self.writeToFlow(payload: payload, from: endpoint)
                    }
                }
                if isComplete {
                    self.finish()
                    return
                }
                self.startUDPReadLoop()
            }
        }
    }

    private func writeToFlow(payload: Data, from endpoint: NWHostEndpoint) {
        flow.writeDatagrams([payload], sentBy: [endpoint]) { [weak self] error in
            guard let self else { return }
            if let error {
                self.queue.async {
                    self.logger.error("UDP relay: flow write failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    // MARK: - SOCKS5 UDP packet encoding/decoding

    /// Wrap a plain UDP datagram in the SOCKS5 UDP header.
    private static func encodeSOCKS5UDP(datagram: Data, endpoint: NWHostEndpoint) -> Data? {
        let host = endpoint.hostname
        let port = UInt16(endpoint.port) ?? 0

        var packet = Data([0x00, 0x00, 0x00]) // RSV + FRAG
        if let ip = IPv4Address(host) {
            packet.append(0x01) // ATYP IPv4
            packet.append(contentsOf: ip.rawValue)
        } else if let ip = IPv6Address(host) {
            packet.append(0x04) // ATYP IPv6
            packet.append(contentsOf: ip.rawValue)
        } else {
            // Domain
            packet.append(0x03)
            packet.append(UInt8(host.utf8.count))
            packet.append(Data(host.utf8))
        }
        packet.append(contentsOf: [UInt8(port >> 8), UInt8(port & 0xFF)])
        packet.append(datagram)
        return packet
    }

    /// Unwrap a SOCKS5 UDP packet, returning the payload and the source endpoint.
    private static func decodeSOCKS5UDP(packet: Data) -> (payload: Data, endpoint: NWHostEndpoint)? {
        let bytes = [UInt8](packet)
        guard bytes.count >= 10 else { return nil }
        // RSV(2) + FRAG(1) — skip
        var pos = 3
        let atyp = bytes[pos]; pos += 1

        let host: String
        switch atyp {
        case 0x01: // IPv4
            guard pos + 4 <= bytes.count else { return nil }
            host = "\(bytes[pos]).\(bytes[pos+1]).\(bytes[pos+2]).\(bytes[pos+3])"
            pos += 4
        case 0x04: // IPv6
            guard pos + 16 <= bytes.count else { return nil }
            let parts = (0..<8).map { i -> String in
                String(format: "%02x%02x", bytes[pos + i*2], bytes[pos + i*2 + 1])
            }
            host = parts.joined(separator: ":")
            pos += 16
        case 0x03: // Domain
            guard pos < bytes.count else { return nil }
            let len = Int(bytes[pos]); pos += 1
            guard pos + len <= bytes.count else { return nil }
            host = String(bytes: bytes[pos..<pos+len], encoding: .utf8) ?? ""
            pos += len
        default:
            return nil
        }

        guard pos + 2 <= bytes.count else { return nil }
        let port = UInt16(bytes[pos]) << 8 | UInt16(bytes[pos + 1])
        pos += 2

        let payload = Data(bytes[pos...])
        let endpoint = NWHostEndpoint(hostname: host, port: String(port))
        return (payload, endpoint)
    }

    // MARK: - Helpers

    private func receiveExact(_ count: Int, then: @escaping (Data) -> Void) {
        guard let connection = controlConnection else { finish(); return }
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
                        self.logger.error("UDP relay: read failed: \(error.localizedDescription, privacy: .public)")
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

    // MARK: - Teardown

    func close() {
        queue.async { [self] in finish() }
    }

    private func finish() {
        guard !isClosed else { return }
        isClosed = true
        udpConnection?.cancel()
        udpConnection = nil
        controlConnection?.cancel()
        controlConnection = nil
        flow.closeReadWithError(nil)
        flow.closeWriteWithError(nil)
        let relayID = id
        onFinish?(relayID)
        onFinish = nil
    }
}
