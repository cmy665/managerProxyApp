//
//  PersistenceService.swift
//  ProxyPilot
//
//  Codable + JSON storage in ~/Library/Application Support/ProxyPilot/
//  Secrets never land here — they live in the Keychain.
//

import Foundation

final class PersistenceService {

    // MARK: Files

    enum File: String {
        case applications = "applications.json"
        case proxies = "proxies.json"
        case settings = "settings.json"
        case rules = "rules.json"
        case launchRecords = "launch-records.json"
        case logs = "logs.json"
        case state = "state.json"
    }

    let directory: URL

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Default production location.
    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("ProxyPilot", isDirectory: true)
    }

    init(directory: URL = PersistenceService.defaultDirectory) {
        self.directory = directory
        self.encoder = PersistenceService.makeEncoder()
        self.decoder = PersistenceService.makeDecoder()
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: Date coding

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// ISO-8601 *with* fractional seconds. Plain `.iso8601` truncates to whole
    /// seconds, which would make `launch-records.json` lose its sub-second
    /// component and break exact round-trips.
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(isoFractional.string(from: date))
        }
        return encoder
    }

    /// Accepts both fractional and whole-second timestamps so files written by an
    /// older build still load.
    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = isoFractional.date(from: raw) { return date }
            if let date = isoPlain.date(from: raw) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognised date format: \(raw)"
            )
        }
        return decoder
    }

    // MARK: Paths

    func url(for file: File) -> URL {
        directory.appendingPathComponent(file.rawValue, isDirectory: false)
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
    }

    // MARK: Generic API

    @discardableResult
    func save<T: Encodable>(_ value: T, to file: File) -> Bool {
        do {
            let data = try encoder.encode(value)
            try atomicWrite(data, to: url(for: file))
            return true
        } catch {
            NSLog("[ProxyPilot] Failed to write \(file.rawValue): \(error)")
            return false
        }
    }

    func load<T: Decodable>(_ file: File, as type: T.Type) -> T? {
        let location = url(for: file)
        guard fileManager.fileExists(atPath: location.path) else { return nil }
        do {
            let data = try Data(contentsOf: location)
            guard !data.isEmpty else { return nil }
            return try decoder.decode(T.self, from: data)
        } catch {
            NSLog("[ProxyPilot] Failed to read \(file.rawValue): \(error)")
            return nil
        }
    }

    func remove(_ file: File) {
        try? fileManager.removeItem(at: url(for: file))
    }

    // MARK: Typed helpers

    func loadApplications() -> [ManagedApplication] {
        load(.applications, as: [ManagedApplication].self) ?? []
    }

    func saveApplications(_ applications: [ManagedApplication]) {
        save(applications, to: .applications)
    }

    func loadProxies() -> [ProxyProfile] {
        // The built-in DIRECT profile is synthetic and filtered out of storage.
        (load(.proxies, as: [ProxyProfile].self) ?? []).filter { !$0.isBuiltIn }
    }

    func saveProxies(_ proxies: [ProxyProfile]) {
        save(proxies.filter { !$0.isBuiltIn }, to: .proxies)
    }

    func loadSettings() -> AppSettings? {
        load(.settings, as: AppSettings.self)
    }

    func saveSettings(_ settings: AppSettings) {
        save(settings, to: .settings)
    }

    func loadRules() -> [ProxyRule] {
        load(.rules, as: [ProxyRule].self) ?? []
    }

    func saveRules(_ rules: [ProxyRule]) {
        save(rules, to: .rules)
    }

    func loadLaunchRecords() -> [LaunchRecord] {
        load(.launchRecords, as: [LaunchRecord].self) ?? []
    }

    func saveLaunchRecords(_ records: [LaunchRecord]) {
        save(records, to: .launchRecords)
    }

    func loadLogs() -> [LogEntry]? {
        load(.logs, as: [LogEntry].self)
    }

    func saveLogs(_ entries: [LogEntry]) {
        save(entries, to: .logs)
    }

    // MARK: Diagnostics helpers

    /// Names of the files that currently exist in the support directory.
    func existingFiles() -> [String] {
        (try? fileManager.contentsOfDirectory(atPath: directory.path))?.sorted() ?? []
    }
}
