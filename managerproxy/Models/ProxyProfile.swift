//
//  ProxyProfile.swift
//  ProxyPilot
//
//  A proxy endpoint the user can assign to individual applications.
//  Passwords are NEVER stored here — only a Keychain lookup id.
//

import Foundation

// MARK: - ProxyType

enum ProxyType: String, Codable, CaseIterable, Identifiable, Sendable {
    case http
    case https
    case socks5
    case direct

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .http:   return "HTTP"
        case .https:  return "HTTPS"
        case .socks5: return "SOCKS5"
        case .direct: return "DIRECT"
        }
    }

    /// Scheme used when building `http://host:port` style URLs.
    var urlScheme: String {
        switch self {
        case .http, .https: return rawValue
        case .socks5:       return "socks5"
        case .direct:       return "direct"
        }
    }

    var isDirect: Bool { self == .direct }

    /// Types the user may pick when creating a proxy profile.
    static var selectable: [ProxyType] { [.http, .https, .socks5] }
}

// MARK: - ProxyProfile

struct ProxyProfile: Identifiable, Codable, Hashable, Sendable {
    /// Stable id of the built-in DIRECT pseudo profile.
    static let directID = UUID(uuidString: "00000000-0000-0000-0000-0000000000D1")!

    /// Defaults offered when creating a profile. HTTP and SOCKS5 proxies almost
    /// always share one port in practice — Clash's "mixed" port is 7890 — so there
    /// is a single default rather than one per protocol.
    static let defaultHost = "127.0.0.1"
    static let defaultPort = 7890

    var id: UUID
    var name: String
    var type: ProxyType
    var host: String
    var port: Int

    var username: String?
    /// Keychain account key. The secret itself lives in the Keychain.
    var passwordKeychainID: String?

    var enabled: Bool

    init(
        id: UUID = UUID(),
        name: String,
        type: ProxyType,
        host: String,
        port: Int,
        username: String? = nil,
        passwordKeychainID: String? = nil,
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.host = host
        self.port = port
        self.username = username
        self.passwordKeychainID = passwordKeychainID
        self.enabled = enabled
    }

    // MARK: Built-ins

    /// The synthetic "DIRECT" profile — never persisted, never editable.
    static var direct: ProxyProfile {
        ProxyProfile(
            id: directID,
            name: "Direct",
            type: .direct,
            host: "",
            port: 0,
            enabled: true
        )
    }

    var isBuiltIn: Bool { type.isDirect }

    var isDirect: Bool { type.isDirect }

    var usesAuthentication: Bool {
        !(username ?? "").isEmpty || (passwordKeychainID ?? "").isEmpty == false
    }

    // MARK: Derived values

    /// `http://127.0.0.1:7890` / `socks5://127.0.0.1:7890`
    var urlString: String? {
        guard !isDirect else { return nil }
        guard isValid else { return nil }
        return "\(type.urlScheme)://\(host):\(port)"
    }

    var url: URL? {
        guard let urlString else { return nil }
        return URL(string: urlString)
    }

    /// `127.0.0.1:7890`
    var displayAddress: String {
        isDirect ? "—" : "\(host):\(port)"
    }

    var displayName: String {
        isDirect ? Localized.string("Direct") : name
    }

    // MARK: Validation

    enum ValidationError: LocalizedError {
        case emptyName
        case emptyHost
        case invalidHost
        case invalidPort

        var errorDescription: String? {
            switch self {
            case .emptyName:   return Localized.string("Name cannot be empty.")
            case .emptyHost:   return Localized.string("Host cannot be empty.")
            case .invalidHost: return Localized.string("Host contains invalid characters.")
            case .invalidPort: return Localized.string("Port must be between 1 and 65535.")
            }
        }
    }

    var validationError: ValidationError? {
        if isDirect { return nil }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .emptyName }
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedHost.isEmpty { return .emptyHost }
        if trimmedHost.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "/")) ) != nil {
            return .invalidHost
        }
        if port < 1 || port > 65535 { return .invalidPort }
        return nil
    }

    var isValid: Bool { validationError == nil }

    // MARK: Codable (tolerant of missing keys)

    enum CodingKeys: String, CodingKey {
        case id, name, type, host, port, username, passwordKeychainID, enabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled Proxy"
        type = try c.decodeIfPresent(ProxyType.self, forKey: .type) ?? .http
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ProxyProfile.defaultHost
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? ProxyProfile.defaultPort
        username = try c.decodeIfPresent(String.self, forKey: .username)
        passwordKeychainID = try c.decodeIfPresent(String.self, forKey: .passwordKeychainID)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

// MARK: - Metadata

extension ProxyProfile {
    /// A short human description used in the proxied-row subtitle, e.g. "HTTP  127.0.0.1:7890".
    var subtitle: String {
        isDirect ? Localized.string("No proxy") : "\(type.displayName)  \(displayAddress)"
    }
}
