//
//  ProxyTester.swift
//  ProxyPilot
//
//  Two-level proxy verification:
//    Level 1 — TCP connect to host:port, measuring latency.
//    Level 2 — a real HTTPS request *through* the proxy, reporting the status code.
//
//  A port being open is not proof that a proxy works, so Level 2 is what decides
//  whether a profile is reported as "Available".
//

import Foundation
import Network

// MARK: - Result

struct ProxyTestResult: Equatable {
    var reachable: Bool = false
    var tcpLatencyMs: Double?
    var httpLatencyMs: Double?
    var statusCode: Int?
    var testedAt: Date = Date()
    var failureReason: String?

    var isAvailable: Bool { reachable && statusCode != nil }

    func asHealth() -> ProxyHealth {
        ProxyHealth(
            isReachable: reachable,
            tcpLatencyMs: tcpLatencyMs,
            httpLatencyMs: httpLatencyMs,
            statusCode: statusCode,
            testedAt: testedAt,
            failureReason: failureReason
        )
    }

    static func failure(_ reason: String, testedAt: Date = Date()) -> ProxyTestResult {
        ProxyTestResult(reachable: false, testedAt: testedAt, failureReason: reason)
    }
}

// MARK: - ProxyTester

final class ProxyTester {

    /// TCP probe timeout.
    private let connectTimeout: TimeInterval = 4
    /// Whole-request timeout for the HTTP probe.
    private let requestTimeout: TimeInterval = 15

    // MARK: Level 1 — TCP

    func tcpConnect(host: String, port: Int) async -> (reachable: Bool, latencyMs: Double?) {
        guard !host.isEmpty, port > 0, port <= 65535 else { return (false, nil) }
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return (false, nil) }

        let start = DispatchTime.now()
        let reachable = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let box = ContinuationBox(continuation)
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            let queue = DispatchQueue(label: "com.proxypilot.proxytest.tcp")

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if box.tryResume(true) { connection.cancel() }
                case .failed, .cancelled:
                    _ = box.tryResume(false)
                case .waiting:
                    // For a closed port on loopback this fires immediately with ECONNREFUSED,
                    // and it never recovers — treat it as a failure rather than burning the timeout.
                    if box.tryResume(false) { connection.cancel() }
                default:
                    break
                }
            }

            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + self.connectTimeout) {
                if box.tryResume(false) { connection.cancel() }
            }
        }

        guard reachable else { return (false, nil) }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000
        return (true, elapsed)
    }

    // MARK: Level 2 — real request through the proxy

    func httpProbe(through proxy: ProxyProfile?, url: URL) async -> (statusCode: Int?, latencyMs: Double?, error: String?) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never

        if let proxy, !proxy.isDirect, proxy.isValid {
            configuration.connectionProxyDictionary = ProxyTester.proxyDictionary(for: proxy)
        }

        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("ProxyPilot/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        let start = DispatchTime.now()
        do {
            let (_, response) = try await session.data(for: request)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000
            let code = (response as? HTTPURLResponse)?.statusCode
            return (code, elapsed, nil)
        } catch {
            return (nil, nil, ProxyTester.describe(error))
        }
    }

    // MARK: Full test

    /// Runs both levels. `testURL` comes from Settings so the user can point at an
    /// endpoint reachable from their network.
    func test(profile: ProxyProfile, testURL: URL) async -> ProxyTestResult {
        var result = ProxyTestResult()
        result.testedAt = Date()

        if profile.isDirect {
            let (code, latency, error) = await httpProbe(through: nil, url: testURL)
            result.reachable = code != nil
            result.httpLatencyMs = latency
            result.statusCode = code
            result.failureReason = error
            return result
        }

        // Level 1
        let (reachable, tcpLatency) = await tcpConnect(host: profile.host, port: profile.port)
        result.reachable = reachable
        result.tcpLatencyMs = tcpLatency

        guard reachable else {
            result.failureReason = Localized.format("Nothing is listening on %@:%lld.",
                                                   profile.host, profile.port)
            return result
        }

        // Level 2
        let (code, httpLatency, error) = await httpProbe(through: profile, url: testURL)
        result.statusCode = code
        result.httpLatencyMs = httpLatency

        if let code {
            if (200...399).contains(code) || code == 204 {
                result.failureReason = nil
            } else {
                // A reachable-but-refused node is the most common way a proxy test
                // "succeeds" at connecting yet still fails for the real app.
                if let hint = Self.statusHint(for: code) {
                    result.failureReason = Localized.format("Proxy returned HTTP %lld. %@",
                                                           code, hint)
                } else {
                    result.failureReason = Localized.format("Proxy returned HTTP %lld.", code)
                }
            }
        } else {
            result.failureReason = error ?? Localized.string("The proxy did not complete the request.")
            // Port is open but the handshake failed — keep reachable = true so the UI
            // can distinguish "proxy is broken" from "nothing is there".
        }

        return result
    }

    /// Tries the configured URL, then the fallback list, and returns the first
    /// attempt that produced an HTTP status.
    func testWithFallbacks(profile: ProxyProfile, primaryURL: URL) async -> ProxyTestResult {
        let primary = await test(profile: profile, testURL: primaryURL)
        if primary.statusCode != nil { return primary }

        for fallback in AppSettings.fallbackTestURLs {
            guard let url = URL(string: fallback), url != primaryURL else { continue }
            let attempt = await test(profile: profile, testURL: url)
            if attempt.statusCode != nil {
                var merged = attempt
                // Keep the TCP latency from the primary run — same host:port.
                merged.tcpLatencyMs = primary.tcpLatencyMs
                return merged
            }
        }
        return primary
    }

    // MARK: Helpers

    /// CFNetwork proxy dictionary keys — these are the documented string constants.
    static func proxyDictionary(for proxy: ProxyProfile) -> [AnyHashable: Any] {
        var dictionary: [AnyHashable: Any] = [:]
        switch proxy.type {
        case .http, .https:
            dictionary["HTTPEnable"] = 1
            dictionary["HTTPProxy"] = proxy.host
            dictionary["HTTPPort"] = proxy.port
            dictionary["HTTPSEnable"] = 1
            dictionary["HTTPSProxy"] = proxy.host
            dictionary["HTTPSPort"] = proxy.port
        case .socks5:
            dictionary["SOCKSEnable"] = 1
            dictionary["SOCKSProxy"] = proxy.host
            dictionary["SOCKSPort"] = proxy.port
        case .direct:
            break
        }
        return dictionary
    }

    /// Explains the status codes that mean "the proxy works but this exit node is
    /// not usable for the target site" — by far the most confusing case.
    static func statusHint(for code: Int) -> String? {
        switch code {
        case 403:
            return Localized.string("The site refused this exit node — switch to another node in your proxy client.")
        case 451:
            return Localized.string("The site restricts this region — switch to another node.")
        case 407:
            return Localized.string("The proxy requires authentication.")
        case 502, 503, 504:
            return Localized.string("The proxy or its upstream is unavailable right now.")
        default:
            return nil
        }
    }

    static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorCannotConnectToHost:
                return Localized.string("Could not connect to the proxy.")
            case NSURLErrorCannotFindHost:
                return Localized.string("The proxy host could not be resolved.")
            case NSURLErrorTimedOut:
                return Localized.string("The request timed out.")
            case NSURLErrorNetworkConnectionLost:
                return Localized.string("The connection was closed by the proxy.")
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
                return Localized.string("TLS handshake failed through the proxy.")
            default:
                return nsError.localizedDescription
            }
        }
        return nsError.localizedDescription
    }
}

// MARK: - ContinuationBox

/// Guards a `CheckedContinuation` so concurrent callbacks can only resume it once.
final class ContinuationBox: @unchecked Sendable {
    private var continuation: CheckedContinuation<Bool, Never>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    @discardableResult
    func tryResume(_ value: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let continuation else { return false }
        self.continuation = nil
        continuation.resume(returning: value)
        return true
    }
}
