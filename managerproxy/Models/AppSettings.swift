//
//  AppSettings.swift
//  ProxyPilot
//

import Foundation

// MARK: - Appearance

enum AppAppearance: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return Localized.string("System")
        case .light:  return Localized.string("Light")
        case .dark:   return Localized.string("Dark")
        }
    }
}

// MARK: - AppSettings

struct AppSettings: Codable, Equatable, Sendable {

    // MARK: General

    var launchAtLogin: Bool
    var showMenuBarIcon: Bool
    var startMinimized: Bool
    var confirmBeforeRestartingApps: Bool
    var appearance: AppAppearance

    // MARK: Proxy

    var defaultProxyProfileID: UUID?
    var defaultBypassList: [String]

    // MARK: Advanced

    var enableDebugLogging: Bool
    var showLaunchCommand: Bool
    var proxyTestURL: String

    /// Master switch — persisted so a relaunch keeps the user's intent.
    var masterEnabled: Bool

    /// Phase 2: master switch for the transparent proxy system extension.
    /// When on, apps with `usesTransparentProxy` are intercepted per-flow.
    var transparentProxyEnabled: Bool

    static let defaultBypassList: [String] = ["localhost", "127.0.0.1", "::1"]

    static let defaultTestURL = "https://www.gstatic.com/generate_204"

    /// Fallback used when the primary probe fails.
    static let fallbackTestURLs: [String] = [
        "https://www.gstatic.com/generate_204",
        "https://cp.cloudflare.com/generate_204",
        "https://www.apple.com/library/test/success.html"
    ]

    init(
        launchAtLogin: Bool = false,
        showMenuBarIcon: Bool = true,
        startMinimized: Bool = false,
        confirmBeforeRestartingApps: Bool = true,
        appearance: AppAppearance = .system,
        defaultProxyProfileID: UUID? = nil,
        defaultBypassList: [String] = AppSettings.defaultBypassList,
        enableDebugLogging: Bool = false,
        showLaunchCommand: Bool = true,
        proxyTestURL: String = AppSettings.defaultTestURL,
        masterEnabled: Bool = true,
        transparentProxyEnabled: Bool = false
    ) {
        self.launchAtLogin = launchAtLogin
        self.showMenuBarIcon = showMenuBarIcon
        self.startMinimized = startMinimized
        self.confirmBeforeRestartingApps = confirmBeforeRestartingApps
        self.appearance = appearance
        self.defaultProxyProfileID = defaultProxyProfileID
        self.defaultBypassList = defaultBypassList
        self.enableDebugLogging = enableDebugLogging
        self.showLaunchCommand = showLaunchCommand
        self.proxyTestURL = proxyTestURL
        self.masterEnabled = masterEnabled
        self.transparentProxyEnabled = transparentProxyEnabled
    }

    // MARK: Derived

    /// Validated test URL, falling back to the default when the user typed garbage.
    var resolvedTestURL: URL {
        if let url = URL(string: proxyTestURL.trimmingCharacters(in: .whitespacesAndNewlines)),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https",
           url.host != nil {
            return url
        }
        return URL(string: AppSettings.defaultTestURL)!
    }

    var normalizedBypassList: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for entry in defaultBypassList {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(trimmed)
        }
        return result
    }

    // MARK: Codable (tolerant)

    enum CodingKeys: String, CodingKey {
        case launchAtLogin, showMenuBarIcon, startMinimized, confirmBeforeRestartingApps
        case appearance
        case defaultProxyProfileID, defaultBypassList
        case enableDebugLogging, showLaunchCommand, proxyTestURL, masterEnabled
        case transparentProxyEnabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        showMenuBarIcon = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarIcon) ?? true
        startMinimized = try c.decodeIfPresent(Bool.self, forKey: .startMinimized) ?? false
        confirmBeforeRestartingApps = try c.decodeIfPresent(Bool.self, forKey: .confirmBeforeRestartingApps) ?? true
        appearance = try c.decodeIfPresent(AppAppearance.self, forKey: .appearance) ?? .system
        defaultProxyProfileID = try c.decodeIfPresent(UUID.self, forKey: .defaultProxyProfileID)
        defaultBypassList = try c.decodeIfPresent([String].self, forKey: .defaultBypassList) ?? AppSettings.defaultBypassList
        enableDebugLogging = try c.decodeIfPresent(Bool.self, forKey: .enableDebugLogging) ?? false
        showLaunchCommand = try c.decodeIfPresent(Bool.self, forKey: .showLaunchCommand) ?? true
        proxyTestURL = try c.decodeIfPresent(String.self, forKey: .proxyTestURL) ?? AppSettings.defaultTestURL
        masterEnabled = try c.decodeIfPresent(Bool.self, forKey: .masterEnabled) ?? true
        transparentProxyEnabled = try c.decodeIfPresent(Bool.self, forKey: .transparentProxyEnabled) ?? false
    }
}
