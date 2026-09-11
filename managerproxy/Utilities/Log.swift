//
//  Log.swift
//  ProxyPilot
//
//  os.Logger + an in-memory ring buffer surfaced in Settings → Diagnostics.
//  Values whose key looks sensitive are redacted before they ever reach the buffer.
//

import Combine
import Foundation
import os

@MainActor
final class LogStore: ObservableObject {

    @Published private(set) var entries: [LogEntry] = []

    /// Ring buffer capacity — enough for a debugging session, cheap to persist.
    private let capacity = 600

    private let logger = Logger(subsystem: "com.proxypilot.mac", category: "ProxyPilot")

    private let persistence: PersistenceService?
    private var flushTask: Task<Void, Never>?

    init(persistence: PersistenceService? = nil) {
        self.persistence = persistence
        if let persisted = persistence?.loadLogs() {
            entries = persisted
        }
    }

    // MARK: Public API

    func log(
        _ message: String,
        category: LogCategory,
        level: LogLevel = .info,
        detail: [(String, String)]? = nil
    ) {
        let safeDetail = detail?.map { key, value in
            (key, LogRedactor.redact(key: key, value: value))
        }

        switch level {
        case .debug:   logger.debug("\(category.rawValue, privacy: .public): \(message, privacy: .public)")
        case .info:    logger.info("\(category.rawValue, privacy: .public): \(message, privacy: .public)")
        case .success: logger.notice("\(category.rawValue, privacy: .public): \(message, privacy: .public)")
        case .warning: logger.warning("\(category.rawValue, privacy: .public): \(message, privacy: .public)")
        case .error:   logger.error("\(category.rawValue, privacy: .public): \(message, privacy: .public)")
        }

        let entry = LogEntry(category: category, level: level, message: message, detail: safeDetail)
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        scheduleFlush()
    }

    func debug(_ message: String, category: LogCategory, detail: [(String, String)]? = nil) {
        log(message, category: category, level: .debug, detail: detail)
    }

    func info(_ message: String, category: LogCategory, detail: [(String, String)]? = nil) {
        log(message, category: category, level: .info, detail: detail)
    }

    func success(_ message: String, category: LogCategory, detail: [(String, String)]? = nil) {
        log(message, category: category, level: .success, detail: detail)
    }

    func warning(_ message: String, category: LogCategory, detail: [(String, String)]? = nil) {
        log(message, category: category, level: .warning, detail: detail)
    }

    func error(_ message: String, category: LogCategory, detail: [(String, String)]? = nil) {
        log(message, category: category, level: .error, detail: detail)
    }

    func clear() {
        entries.removeAll()
        persistence?.saveLogs(entries)
    }

    func exportText() -> String {
        entries.map(\.plainText).joined(separator: "\n\n")
    }

    // MARK: Persistence

    private func scheduleFlush() {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self else { return }
            self.persistence?.saveLogs(self.entries)
        }
    }
}
