//
//  ManagedApplication.swift
//  ProxyPilot
//
//  An application the user has added to ProxyPilot.
//

import Foundation

// MARK: - LaunchStrategy

enum LaunchStrategy: String, Codable, CaseIterable, Identifiable, Sendable {
    /// ProxyPilot decides based on the detected runtime.
    case auto
    /// Chromium / Electron style `--proxy-server=` argument.
    case chromium
    /// Conventional proxy environment variables.
    case environment
    /// No proxy at all.
    case direct

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto:        return Localized.string("Auto")
        case .chromium:    return Localized.string("Chromium")
        case .environment: return Localized.string("Environment")
        case .direct:      return Localized.string("Direct")
        }
    }

    var explanation: String {
        switch self {
        case .auto:
            return Localized.string("Pick the best strategy for the detected app runtime.")
        case .chromium:
            return Localized.string("Pass --proxy-server=<url> to the app executable.")
        case .environment:
            return Localized.string("Export HTTP_PROXY / HTTPS_PROXY / ALL_PROXY before launching.")
        case .direct:
            return Localized.string("Launch without any proxy configuration.")
        }
    }
}

// MARK: - ApplicationRuntime

enum ApplicationRuntime: String, Codable, CaseIterable, Sendable {
    case chromium
    case electron
    case native
    case unknown

    var displayName: String {
        switch self {
        case .chromium: return Localized.string("Chromium")
        case .electron: return Localized.string("Electron")
        case .native:   return Localized.string("Native")
        case .unknown:  return Localized.string("Unknown")
        }
    }

    /// Runtimes that understand `--proxy-server=`.
    var supportsChromiumArguments: Bool {
        self == .chromium || self == .electron
    }
}

// MARK: - ManagedApplication

struct ManagedApplication: Identifiable, Codable, Hashable, Sendable {
    let id: UUID

    var name: String
    var bundleIdentifier: String
    var bundlePath: String
    var executablePath: String

    var enabled: Bool

    var proxyProfileID: UUID?

    var launchStrategy: LaunchStrategy

    var bypassDomains: [String]

    /// Cached result of `AppDetector` so launcher selection stays synchronous.
    var runtime: ApplicationRuntime

    /// Phase 2: when on (and the transparent proxy master switch is on), the
    /// app's traffic is intercepted per-flow by the system extension instead of
    /// relying on Chromium arguments / environment variables alone.
    var usesTransparentProxy: Bool

    var version: String

    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        bundleIdentifier: String,
        bundlePath: String,
        executablePath: String,
        enabled: Bool = false,
        proxyProfileID: UUID? = nil,
        launchStrategy: LaunchStrategy = .auto,
        bypassDomains: [String] = AppSettings.defaultBypassList,
        runtime: ApplicationRuntime = .unknown,
        usesTransparentProxy: Bool = false,
        version: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.bundlePath = bundlePath
        self.executablePath = executablePath
        self.enabled = enabled
        self.proxyProfileID = proxyProfileID
        self.launchStrategy = launchStrategy
        self.bypassDomains = bypassDomains
        self.runtime = runtime
        self.usesTransparentProxy = usesTransparentProxy
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // MARK: Derived

    var bundleURL: URL { URL(fileURLWithPath: bundlePath) }
    var executableURL: URL { URL(fileURLWithPath: executablePath) }

    /// The closest display path, e.g. "/Applications/Codex.app".
    var displayPath: String { bundlePath }

    var isProxyConfigured: Bool { proxyProfileID != nil }

    /// Relative path shown under the app name in the list row.
    var compactPath: String {
        let home = NSHomeDirectory()
        if bundlePath.hasPrefix(home) {
            return "~" + bundlePath.dropFirst(home.count)
        }
        return bundlePath
    }

    /// Resolved launch strategy, taking `auto` into account.
    var effectiveStrategy: LaunchStrategy {
        guard launchStrategy == .auto else { return launchStrategy }
        if runtime.supportsChromiumArguments { return .chromium }
        return .environment
    }

    func existsOnDisk() -> Bool {
        FileManager.default.fileExists(atPath: bundlePath)
    }

    // MARK: Codable (tolerant of missing keys)

    enum CodingKeys: String, CodingKey {
        case id, name, bundleIdentifier, bundlePath, executablePath, enabled
        case proxyProfileID, launchStrategy, bypassDomains, runtime, version
        case usesTransparentProxy, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Unknown App"
        bundleIdentifier = try c.decodeIfPresent(String.self, forKey: .bundleIdentifier) ?? ""
        bundlePath = try c.decodeIfPresent(String.self, forKey: .bundlePath) ?? ""
        executablePath = try c.decodeIfPresent(String.self, forKey: .executablePath) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        proxyProfileID = try c.decodeIfPresent(UUID.self, forKey: .proxyProfileID)
        launchStrategy = try c.decodeIfPresent(LaunchStrategy.self, forKey: .launchStrategy) ?? .auto
        bypassDomains = try c.decodeIfPresent([String].self, forKey: .bypassDomains) ?? AppSettings.defaultBypassList
        runtime = try c.decodeIfPresent(ApplicationRuntime.self, forKey: .runtime) ?? .unknown
        usesTransparentProxy = try c.decodeIfPresent(Bool.self, forKey: .usesTransparentProxy) ?? false
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}

// MARK: - DiscoveredApplication

/// A `.app` found on disk but not necessarily managed yet.
struct DiscoveredApplication: Identifiable, Hashable, Sendable {
    let name: String
    let bundleIdentifier: String
    let bundlePath: String
    let executablePath: String
    let version: String
    let runtime: ApplicationRuntime

    var id: String { bundlePath }

    var url: URL { URL(fileURLWithPath: bundlePath) }

    static func == (lhs: DiscoveredApplication, rhs: DiscoveredApplication) -> Bool {
        lhs.bundlePath == rhs.bundlePath
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(bundlePath)
    }
}
