//
//  AddApplicationsSheet.swift
//  ProxyPilot
//
//  Pick from the apps discovered on disk, or browse for a specific .app.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AddApplicationsSheet: View {

    @Binding var isPresented: Bool
    @EnvironmentObject private var state: AppState

    @State private var searchText = ""
    @State private var selectedPaths: Set<String> = []
    @State private var isScanningLocally = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            listContent
            Hairline()
            footer
        }
        .frame(width: 600, height: 540)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add Applications")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Choose the apps you want ProxyPilot to manage.")
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task {
                        isScanningLocally = true
                        await state.refreshDiscoveredApplications()
                        isScanningLocally = false
                    }
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(isScanningLocally || state.isScanning)
            }
            SearchField(placeholder: "Search by name or bundle ID…", text: $searchText, width: 300)
        }
        .padding(16)
    }

    // MARK: List

    @ViewBuilder
    private var listContent: some View {
        if state.discoveredApplications.isEmpty {
            EmptyStateView(
                systemImage: "magnifyingglass",
                title: state.isScanning ? "Scanning…" : "Nothing found yet",
                message: "ProxyPilot looks in /Applications, ~/Applications and /System/Applications. You can also browse for a specific .app."
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { discovered in
                        row(for: discovered)
                        Hairline()
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private func row(for discovered: DiscoveredApplication) -> some View {
        let alreadyAdded = state.applications.contains { $0.bundlePath == discovered.bundlePath }
        let isSelected = selectedPaths.contains(discovered.bundlePath)

        return Button {
            guard !alreadyAdded else { return }
            if isSelected {
                selectedPaths.remove(discovered.bundlePath)
            } else {
                selectedPaths.insert(discovered.bundlePath)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? Theme.blue : Color.secondary.opacity(0.5))

                AppIconView(bundlePath: discovered.bundlePath, size: 26)

                VStack(alignment: .leading, spacing: 1) {
                    Text(discovered.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(alreadyAdded ? Color.secondary : Color.primary)
                    MonoLabel(text: discovered.bundleIdentifier.isEmpty ? discovered.bundlePath : discovered.bundleIdentifier)
                }

                Spacer(minLength: 8)

                if alreadyAdded {
                    StatusPill(text: Localized.string("Added"), color: Theme.neutral)
                } else {
                    StatusPill(
                        text: discovered.runtime.displayName,
                        color: discovered.runtime.supportsChromiumArguments ? Theme.blue : Theme.neutral
                    )
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(alreadyAdded)
        .opacity(alreadyAdded ? 0.55 : 1)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                browse()
            } label: {
                Label("Browse…", systemImage: "folder")
            }
            .buttonStyle(SecondaryButtonStyle())

            if !selectedPaths.isEmpty {
                Text(Localized.format("%lld selected", selectedPaths.count))
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Cancel") { isPresented = false }
                .buttonStyle(SecondaryButtonStyle())

            Button(Localized.format("Add %lld application(s)", selectedPaths.count)) {
                addSelected()
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(selectedPaths.isEmpty)
        }
        .padding(14)
    }

    // MARK: Actions

    private func addSelected() {
        let apps = state.discoveredApplications.filter { selectedPaths.contains($0.bundlePath) }
        let added = state.add(discovered: apps)
        state.toast = added > 0
            ? Localized.format("Added %lld application(s)", added)
            : Localized.string("Nothing new to add")
        isPresented = false
    }

    /// NSOpenPanel restricted to `.app` bundles.
    private func browse() {
        let panel = NSOpenPanel()
        panel.title = "Choose an application"
        panel.prompt = "Add"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [UTType.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)

        guard panel.runModal() == .OK else { return }

        var discovered: [DiscoveredApplication] = []
        for url in panel.urls {
            if let app = AppScanner.makeDiscoveredApplication(from: url) {
                discovered.append(app)
            }
        }
        guard !discovered.isEmpty else { return }
        let added = state.add(discovered: discovered)
        state.toast = added > 0
            ? Localized.format("Added %lld application(s)", added)
            : Localized.string("Already in the list")
        isPresented = false
    }

    // MARK: Filtering

    private var filtered: [DiscoveredApplication] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return state.discoveredApplications }
        return state.discoveredApplications.filter {
            $0.name.lowercased().contains(query) || $0.bundleIdentifier.lowercased().contains(query)
        }
    }
}
