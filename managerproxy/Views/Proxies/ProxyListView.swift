//
//  ProxyListView.swift
//  ProxyPilot
//
//  Proxy profile table plus the inline editor panel from the design.
//

import SwiftUI

struct ProxyListView: View {

    @EnvironmentObject private var state: AppState

    @State private var editingProxyID: UUID?
    @State private var isCreatingNew = false
    @State private var searchText = ""

    private enum Column {
        static let type: CGFloat = 84
        static let address: CGFloat = 168
        static let status: CGFloat = 128
        static let actions: CGFloat = 30
    }

    private var isEditorVisible: Bool { isCreatingNew || editingProxyID != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Hairline()

            HStack(alignment: .top, spacing: 0) {
                table
                if isEditorVisible {
                    Hairline().frame(width: 1).frame(maxHeight: .infinity)
                    editorPanel
                }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        PageHeader(
            title: "Proxies",
            subtitle: "Create and manage proxy profiles."
        ) {
            SearchField(placeholder: "Search proxies…", text: $searchText, width: 190)
            Button {
                isCreatingNew = true
                editingProxyID = nil
            } label: {
                Label("Add Proxy", systemImage: "plus")
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(.horizontal, Theme.contentPadding)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    // MARK: Table

    private var table: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                TableHeaderRow {
                    HStack(spacing: 10) {
                        Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Type").frame(width: Column.type, alignment: .leading)
                        Text("Address").frame(width: Column.address, alignment: .leading)
                        Text("Status").frame(width: Column.status, alignment: .leading)
                        Text("").frame(width: Column.actions)
                    }
                }

                ForEach(filteredProxies) { profile in
                    row(for: profile)
                    Hairline()
                }

                if filteredProxies.isEmpty {
                    Text(Localized.format("No proxy profiles match “%@”.", searchText))
                        .font(Theme.body)
                        .foregroundStyle(.secondary)
                        .padding(24)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func row(for profile: ProxyProfile) -> some View {
        let health = state.health(for: profile)
        let isSelected = editingProxyID == profile.id

        return HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: pointSymbol(for: profile))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(profile.isDirect ? Color.secondary : Theme.blue)
                Text(profile.displayName)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                if profile.isBuiltIn {
                    Text("built-in")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(profile.type.displayName)
                .font(Theme.monoCaption)
                .foregroundStyle(.secondary)
                .frame(width: Column.type, alignment: .leading)

            MonoLabel(text: profile.displayAddress)
                .frame(width: Column.address, alignment: .leading)

            Group {
                if profile.isBuiltIn {
                    StatusPill(text: Localized.string("Built-in"), color: Theme.neutral)
                } else if state.testingProxyIDs.contains(profile.id) {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text("Testing…").font(Theme.caption).foregroundStyle(.secondary)
                    }
                } else {
                    StatusPill(text: health.statusLabel, color: health.color)
                }
            }
            .frame(width: Column.status, alignment: .leading)

            Menu {
                Button("Edit") {
                    isCreatingNew = false
                    editingProxyID = profile.id
                }
                .disabled(profile.isBuiltIn)

                Button("Test Connection") {
                    Task { await state.testProxy(profile) }
                }
                .disabled(profile.isBuiltIn)

                Button("Duplicate") {
                    duplicate(profile)
                }
                .disabled(profile.isBuiltIn)

                Divider()

                Button("Delete", role: .destructive) {
                    state.deleteProxy(profile)
                    if editingProxyID == profile.id { editingProxyID = nil }
                }
                .disabled(profile.isBuiltIn)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: Column.actions)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: Column.actions)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(height: 46)
        .background(isSelected ? Theme.blue.opacity(0.10) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !profile.isBuiltIn else { return }
            isCreatingNew = false
            editingProxyID = profile.id
        }
    }

    private func pointSymbol(for profile: ProxyProfile) -> String {
        switch profile.type {
        case .http, .https: return "network"
        case .socks5:       return "shield.lefthalf.filled"
        case .direct:       return "arrow.right"
        }
    }

    // MARK: Editor panel

    @ViewBuilder
    private var editorPanel: some View {
        if isCreatingNew {
            ProxyEditorView(
                original: nil,
                existingPassword: "",
                onCancel: { isCreatingNew = false }
            )
            .id("new-proxy")
            .environmentObject(state)
            .frame(width: 320)
        } else if let id = editingProxyID,
                  let profile = state.proxies.first(where: { $0.id == id }) {
            ProxyEditorView(
                original: profile,
                existingPassword: state.password(for: profile) ?? "",
                onCancel: { editingProxyID = nil }
            )
            .id(profile.id)
            .environmentObject(state)
            .frame(width: 320)
        }
    }

    // MARK: Helpers

    private func duplicate(_ profile: ProxyProfile) {
        try? state.addProxy(
            name: "\(profile.name) Copy",
            type: profile.type,
            host: profile.host,
            port: profile.port,
            username: profile.username,
            password: nil
        )
    }

    private var filteredProxies: [ProxyProfile] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return state.allProxies }
        return state.allProxies.filter {
            $0.name.lowercased().contains(query)
                || $0.displayAddress.lowercased().contains(query)
                || $0.type.displayName.lowercased().contains(query)
        }
    }
}
