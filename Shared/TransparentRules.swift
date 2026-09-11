//
//  TransparentRules.swift
//  ProxyPilot
//
//  The per-app rule model and the file store both targets share.
//
//  The app writes `transparent-rules.json` into the app-group container
//  whenever the configuration changes. The extension reads it (and reloads it
//  when the file changes) and uses it to decide, per flow, whether to relay
//  through an upstream proxy or to let the system deliver the flow directly.
//
//  Secrets are deliberately NOT part of this file: only a Keychain account
//  key travels here, and the extension reads the actual password from the
//  shared keychain access group.
//

import Foundation

// MARK: - Model

/// One per-app rule: "traffic originating from `bundleID` goes through this proxy".
struct TransparentRule: Codable, Equatable, Sendable {
    var bundleID: String
    /// One of TransparentProxyConstants.scheme* — "http", "https" or "socks5".
    var proxyType: String
    var host: String
    var port: Int
    var username: String?
    /// Keychain account key (service com.proxypilot.mac.credentials) in the
    /// shared keychain group. The secret itself never touches disk.
    var passwordAccount: String?
}

/// The whole rule file. Versioned so the extension can reject incompatible formats.
struct TransparentRulesFile: Codable, Equatable, Sendable {
    var version: Int
    var rules: [TransparentRule]

    static let currentVersion = 1

    init(version: Int = TransparentRulesFile.currentVersion, rules: [TransparentRule]) {
        self.version = version
        self.rules = rules
    }
}

// MARK: - Store

enum TransparentRuleStoreError: LocalizedError {
    case containerUnavailable
    case unreadable(Error)

    var errorDescription: String? {
        switch self {
        case .containerUnavailable:
            return "The app-group container is not available."
        case .unreadable(let error):
            return "The transparent proxy rules could not be read: \(error.localizedDescription)"
        }
    }
}

enum TransparentRuleStore {

    /// The app-group container shared with the system extension.
    static func containerURL() -> URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: TransparentProxyConstants.appGroupID
        )
    }

    static func rulesURL() -> URL? {
        containerURL()?.appendingPathComponent(TransparentProxyConstants.rulesFileName)
    }

    // MARK: Write (app side)

    /// Atomically writes the rule file so the extension never observes a
    /// half-written JSON document.
    static func write(_ rulesFile: TransparentRulesFile) throws {
        guard let url = rulesURL() else {
            throw TransparentRuleStoreError.containerUnavailable
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(rulesFile)
        try data.write(to: url, options: [.atomic])
    }

    // MARK: Read (extension side)

    /// Returns the decoded rules and the file's modification date, or nil when
    /// the file is missing or malformed. `modificationDate` lets the extension
    /// avoid re-decoding the file on every flow.
    static func load() -> (rulesFile: TransparentRulesFile, modificationDate: Date?)? {
        guard let url = rulesURL() else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modificationDate = attributes?[.modificationDate] as? Date
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let file = try? JSONDecoder().decode(TransparentRulesFile.self, from: data),
              file.version == TransparentRulesFile.currentVersion else {
            return nil
        }
        return (file, modificationDate)
    }

    /// The last modified date of the rule file, without decoding it.
    static func modificationDate() -> Date? {
        guard let url = rulesURL() else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.modificationDate] as? Date
    }
}
