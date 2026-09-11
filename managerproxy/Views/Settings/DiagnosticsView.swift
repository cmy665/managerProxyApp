//
//  DiagnosticsView.swift
//  ProxyPilot
//
//  Live view of the log ring buffer. Every value is redacted before it is stored,
//  so passwords and tokens never appear here.
//

import SwiftUI

struct DiagnosticsView: View {

    @EnvironmentObject private var state: AppState

    @State private var searchText = ""
    @State private var categoryFilter: LogCategory?
    @State private var levelFilter: LogLevel?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Hairline()
            filterBar
            Hairline()
            logList
        }
    }

    // MARK: Header

    private var header: some View {
        PageHeader(
            title: "Diagnostics",
            subtitle: "Launch decisions, proxy tests and process events. Sensitive values are redacted."
        ) {
            Button {
                Pasteboard.copy(state.log.exportText())
                state.toast = "Log copied to the clipboard"
            } label: {
                Label("Copy All", systemImage: "doc.on.doc")
            }
            .buttonStyle(SecondaryButtonStyle())

            Button {
                state.clearLogs()
                state.toast = "Log cleared"
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .padding(.horizontal, Theme.contentPadding)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    // MARK: Filters

    private var filterBar: some View {
        HStack(spacing: 8) {
            SearchField(placeholder: "Filter log…", text: $searchText, width: 220)

            Picker("", selection: $categoryFilter) {
                Text("All categories").tag(LogCategory?.none)
                ForEach(LogCategory.allCases) { category in
                    Text(category.rawValue).tag(LogCategory?.some(category))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 160)

            Picker("", selection: $levelFilter) {
                Text("All levels").tag(LogLevel?.none)
                ForEach(LogLevel.allCases, id: \.self) { level in
                    Text(level.displayName).tag(LogLevel?.some(level))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 130)

            Spacer()

            Text(Localized.format("%lld of %lld entries",
                                 filteredEntries.count,
                                 state.log.entries.count))
                .font(Theme.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Theme.contentPadding)
        .padding(.vertical, 10)
    }

    // MARK: List

    @ViewBuilder
    private var logList: some View {
        if filteredEntries.isEmpty {
            EmptyStateView(
                systemImage: "stethoscope",
                title: "No log entries",
                message: "Launch an app or run a proxy test and the details will show up here."
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredEntries) { entry in
                        LogEntryRow(entry: entry)
                        Hairline()
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private var filteredEntries: [LogEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return state.log.entries.reversed().filter { entry in
            if !state.settings.enableDebugLogging, entry.level == .debug { return false }
            if let categoryFilter, entry.category != categoryFilter { return false }
            if let levelFilter, entry.level != levelFilter { return false }
            guard !query.isEmpty else { return true }
            if entry.message.lowercased().contains(query) { return true }
            if entry.category.rawValue.lowercased().contains(query) { return true }
            return (entry.detail ?? []).contains { key, value in
                key.lowercased().contains(query) || value.lowercased().contains(query)
            }
        }
    }
}

// MARK: - Row

private struct LogEntryRow: View {

    let entry: LogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(entry.timeString)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)

                HStack(spacing: 4) {
                    Image(systemName: entry.category.symbolName)
                        .font(.system(size: 9, weight: .semibold))
                    Text(entry.category.rawValue)
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(Theme.blue)

                StatusPill(text: entry.level.displayName, color: entry.level.color)

                Spacer(minLength: 0)
            }

            Text(entry.message)
                .font(.system(size: 12, weight: .medium))
                .textSelection(.enabled)

            if let detail = entry.detail, !detail.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(detail.enumerated()), id: \.offset) { _, pair in
                        HStack(alignment: .top, spacing: 8) {
                            Text(pair.0)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 108, alignment: .leading)
                            Text(pair.1)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
