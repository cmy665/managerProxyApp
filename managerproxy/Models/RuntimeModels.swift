//
//  RuntimeModels.swift
//  ProxyPilot
//
//  Value types that describe runtime state (health, launch history, status).
//

import Foundation

// MARK: - AppProxyStatus

enum AppProxyStatus: Equatable {
    /// Enabled, proxy reachable, process launched by ProxyPilot with this config.
    case active
    /// User has not enabled proxying for this app.
    case disabled
    /// Explicitly configured to run without a proxy.
    case direct
    /// Configuration changed while the app is running — a restart is required.
    case restartRequired
    /// Proxy endpoint is not reachable.
    case proxyUnavailable
    /// Configured proxy profile no longer exists.
    case configurationMissing

    var label: String {
        switch self {
        case .active:               return Localized.string("Active")
        case .disabled:             return Localized.string("Disabled")
        case .direct:               return Localized.string("Direct")
        case .restartRequired:      return Localized.string("Restart Required")
        case .proxyUnavailable:     return Localized.string("Proxy Unavailable")
        case .configurationMissing: return Localized.string("Proxy Missing")
        }
    }

    var symbolName: String {
        switch self {
        case .active:               return "checkmark.circle.fill"
        case .disabled:             return "circle"
        case .direct:               return "circle.dashed"
        case .restartRequired:      return "arrow.clockwise.circle.fill"
        case .proxyUnavailable:     return "exclamationmark.triangle.fill"
        case .configurationMissing: return "questionmark.circle.fill"
        }
    }

    /// Statuses the user must act on.
    var isWarning: Bool {
        self == .restartRequired || self == .proxyUnavailable || self == .configurationMissing
    }
}

// MARK: - ProxyHealth

struct ProxyHealth: Equatable {
    var isReachable: Bool
    var tcpLatencyMs: Double?
    var httpLatencyMs: Double?
    var statusCode: Int?
    var testedAt: Date
    var failureReason: String?

    static func unknown() -> ProxyHealth {
        ProxyHealth(isReachable: false, tcpLatencyMs: nil, httpLatencyMs: nil,
                    statusCode: nil, testedAt: .distantPast, failureReason: nil)
    }

    var isFullyAvailable: Bool { isReachable && statusCode != nil }

    var hasBeenTested: Bool { testedAt != .distantPast }

    var summary: String {
        guard hasBeenTested else { return Localized.string("Not tested") }
        if isReachable, let code = statusCode {
            return Localized.format("Available · HTTP %lld", code)
        }
        if isReachable { return Localized.string("Reachable · HTTP probe failed") }
        return failureReason ?? Localized.string("Unavailable")
    }
}

// MARK: - LaunchRecord

/// Persisted proof that ProxyPilot launched an app with a specific configuration.
/// Used to decide whether a running app needs a restart.
struct LaunchRecord: Identifiable, Codable, Hashable, Sendable {
    var id: UUID { appID }

    let appID: UUID
    var proxyProfileID: UUID?
    /// Stable fingerprint of the proxy configuration, e.g. "http://127.0.0.1:7890".
    var signature: String
    var strategy: LaunchStrategy
    var arguments: [String]
    var environmentKeys: [String]
    var date: Date
    var executablePath: String

    init(
        appID: UUID,
        proxyProfileID: UUID?,
        signature: String,
        strategy: LaunchStrategy,
        arguments: [String] = [],
        environmentKeys: [String] = [],
        date: Date = Date(),
        executablePath: String = ""
    ) {
        self.appID = appID
        self.proxyProfileID = proxyProfileID
        self.signature = signature
        self.strategy = strategy
        self.arguments = arguments
        self.environmentKeys = environmentKeys
        self.date = date
        self.executablePath = executablePath
    }

    enum CodingKeys: String, CodingKey {
        case appID, proxyProfileID, signature, strategy, arguments, environmentKeys, date, executablePath
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appID = try c.decode(UUID.self, forKey: .appID)
        proxyProfileID = try c.decodeIfPresent(UUID.self, forKey: .proxyProfileID)
        signature = try c.decodeIfPresent(String.self, forKey: .signature) ?? "direct"
        strategy = try c.decodeIfPresent(LaunchStrategy.self, forKey: .strategy) ?? .auto
        arguments = try c.decodeIfPresent([String].self, forKey: .arguments) ?? []
        environmentKeys = try c.decodeIfPresent([String].self, forKey: .environmentKeys) ?? []
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        executablePath = try c.decodeIfPresent(String.self, forKey: .executablePath) ?? ""
    }
}

// MARK: - LaunchOutcome

enum LaunchOutcome {
    case launched(strategy: LaunchStrategy, method: LaunchMethod)
    case terminatedFirst
    case skipped

    var displayName: String {
        switch self {
        case .launched(_, let method): return method.displayName
        case .terminatedFirst:         return Localized.string("Terminated")
        case .skipped:                 return Localized.string("Skipped")
        }
    }
}

enum LaunchMethod: String {
    case workspace = "NSWorkspace"
    case process = "Foundation.Process"

    var displayName: String { rawValue }
}

// MARK: - SidebarSelection

enum SidebarSelection: String, Hashable, CaseIterable, Identifiable {
    case applications
    case proxies
    case settings
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .applications: return Localized.string("Applications")
        case .proxies:      return Localized.string("Proxies")
        case .settings:     return Localized.string("Settings")
        case .diagnostics:  return Localized.string("Diagnostics")
        }
    }

    var symbolName: String {
        switch self {
        case .applications: return "square.grid.2x2"
        case .proxies:      return "network"
        case .settings:     return "gearshape"
        case .diagnostics:  return "stethoscope"
        }
    }
}
