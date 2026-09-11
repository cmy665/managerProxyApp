//
//  Extensions.swift
//  ProxyPilot
//

import AppKit
import SwiftUI

// MARK: - Clipboard

extension View {
    func copyableText() -> some View { self.textSelection(.enabled) }
}

enum Pasteboard {
    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

// MARK: - Byte / latency formatting

enum Format {
    static func latency(_ milliseconds: Double?) -> String {
        guard let milliseconds else { return "—" }
        if milliseconds < 1 { return "<1 ms" }
        return "\(Int(milliseconds.rounded())) ms"
    }

    static func relative(_ date: Date?) -> String {
        guard let date else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func time(_ date: Date?) -> String {
        guard let date else { return "—" }
        return LogEntry.timeString(date)
    }
}

private extension LogEntry {
    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func timeString(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }
}

// MARK: - Icon loading

extension NSImage {
    /// App icons are drawn at their native resolution and scaled by SwiftUI.
    func asSwiftUIImage() -> Image { Image(nsImage: self) }
}

// MARK: - Array helpers

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

// MARK: - NSRunningApplication

extension NSRunningApplication {
    var shortDescription: String {
        "\(localizedName ?? bundleIdentifier ?? "Unknown") (pid \(processIdentifier))"
    }
}
