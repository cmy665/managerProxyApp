//
//  LogEntry.swift
//  ProxyPilot
//

import Foundation

// MARK: - LogCategory

enum LogCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case appScanner = "AppScanner"
    case launcher   = "Launcher"
    case proxy      = "Proxy"
    case process    = "Process"
    case persistence = "Persistence"
    case app        = "App"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .appScanner:  return "magnifyingglass.circle"
        case .launcher:    return "play.circle"
        case .proxy:       return "network"
        case .process:     return "gearshape.2"
        case .persistence: return "externaldrive"
        case .app:         return "app.badge"
        }
    }
}

// MARK: - LogLevel

enum LogLevel: String, Codable, CaseIterable, Sendable {
    case debug
    case info
    case success
    case warning
    case error

    var displayName: String { rawValue.uppercased() }
}

// MARK: - LogEntry

struct LogEntry: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let date: Date
    let category: LogCategory
    let level: LogLevel
    let message: String
    /// Ordered key/value detail. Values are already redacted.
    let detail: [(String, String)]?

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        category: LogCategory,
        level: LogLevel,
        message: String,
        detail: [(String, String)]? = nil
    ) {
        self.id = id
        self.date = date
        self.category = category
        self.level = level
        self.message = message
        self.detail = detail
    }

    static func == (lhs: LogEntry, rhs: LogEntry) -> Bool { lhs.id == rhs.id }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    // Tuples are not Codable — persist a flattened representation instead.
    enum CodingKeys: String, CodingKey {
        case id, date, category, level, message, detailKeys, detailValues
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        category = try c.decodeIfPresent(LogCategory.self, forKey: .category) ?? .app
        level = try c.decodeIfPresent(LogLevel.self, forKey: .level) ?? .info
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        let keys = try c.decodeIfPresent([String].self, forKey: .detailKeys) ?? []
        let values = try c.decodeIfPresent([String].self, forKey: .detailValues) ?? []
        if keys.isEmpty {
            detail = nil
        } else {
            detail = zip(keys, values).map { ($0, $1) }
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(date, forKey: .date)
        try c.encode(category, forKey: .category)
        try c.encode(level, forKey: .level)
        try c.encode(message, forKey: .message)
        try c.encode((detail ?? []).map(\.0), forKey: .detailKeys)
        try c.encode((detail ?? []).map(\.1), forKey: .detailValues)
    }

    var timeString: String {
        LogEntry.timeFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// Plain-text representation used by "Copy" in Diagnostics.
    var plainText: String {
        var lines = ["\(timeString)  [\(category.rawValue)] \(level.displayName)  \(message)"]
        for (key, value) in detail ?? [] {
            lines.append("    \(key): \(value)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Redaction

enum LogRedactor {
    private static let sensitiveFragments = ["password", "passwd", "secret", "token", "credential", "apikey", "api_key", "authorization"]

    static func isSensitive(key: String) -> Bool {
        let lowered = key.lowercased()
        return sensitiveFragments.contains { lowered.contains($0) }
    }

    static func redact(key: String, value: String) -> String {
        isSensitive(key: key) ? "••••••••" : value
    }
}
