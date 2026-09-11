//
//  MenuBarView.swift
//  ProxyPilot
//
//  The menu bar panel: quick per-app switches, bulk actions, tools and quit.
//

import AppKit
import SwiftUI

struct MenuBarView: View {

    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow

    @State private var isToolsExpanded = false

    private var visibleApplications: [ManagedApplication] {
        state.applications.filter { !isDirect($0) }.prefix(9).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Hairline()

            if visibleApplications.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("No applications configured")
                        .font(Theme.body)
                    Text("Open ProxyPilot to add one.")
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(visibleApplications) { app in
                        applicationRow(app)
                    }
                    if state.applications.count > visibleApplications.count {
                        Text(Localized.format("+%lld more in the app",
                                             state.applications.count - visibleApplications.count))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                    }
                }
            }

            Hairline()
            bulkActions

            Hairline()
            tools

            Hairline()
            footer

            Hairline()
            quitRow
        }
        .frame(width: 300)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image("BrandMark")
                .resizable()
                .interpolation(.high)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            Text("ProxyPilot")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer()
            Toggle("", isOn: Binding(
                get: { state.settings.masterEnabled },
                set: { newValue in Task { await state.setMasterEnabled(newValue) } }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help("Master switch")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: Application rows

    private func applicationRow(_ app: ManagedApplication) -> some View {
        let status = state.status(for: app)

        return HStack(spacing: 8) {
            AppIconView(bundlePath: app.bundlePath, size: 17)

            Text(app.name)
                .font(Theme.body)
                .lineLimit(1)

            Spacer(minLength: 6)

            Circle()
                .fill(status.color)
                .frame(width: 6, height: 6)
                .help(status.label)

            Toggle("", isOn: Binding(
                get: { app.enabled },
                set: { newValue in Task { await state.setEnabled(app, enabled: newValue) } }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    // MARK: Bulk actions

    private var bulkActions: some View {
        HStack(spacing: 0) {
            menuButton(title: "Enable All", systemImage: "checkmark.circle") {
                Task { await state.enableAll() }
            }
            menuButton(title: "Disable All", systemImage: "circle.slash") {
                Task { await state.disableAll() }
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: Tools

    private var tools: some View {
        VStack(alignment: .leading, spacing: 0) {
            menuButton(title: "Open ProxyPilot", systemImage: "macwindow") {
                showMainWindow()
            }

            Button {
                withAnimation(.easeInOut(duration: 0.12)) { isToolsExpanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 11))
                        .frame(width: 14)
                    Text("Tools")
                        .font(Theme.body)
                    Spacer()
                    Image(systemName: isToolsExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isToolsExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    menuButton(title: "Test Proxy…", systemImage: "bolt.horizontal.circle", indented: true) {
                        Task { await state.testAllProxies() }
                        showMainWindow()
                        state.selection = .proxies
                    }
                    menuButton(title: "View Logs…", systemImage: "doc.text.magnifyingglass", indented: true) {
                        showMainWindow()
                        state.selection = .diagnostics
                    }
                    menuButton(title: "Check for Updates…", systemImage: "arrow.triangle.2.circlepath", indented: true) {
                        state.alert = ErrorPresentation(
                            title: Localized.format("ProxyPilot %@ is the latest build.", state.appVersion),
                            message: Localized.string("This is a Phase 1 build. Automatic updates arrive with the signed release channel.")
                        )
                    }
                    menuButton(title: "About ProxyPilot", systemImage: "info.circle", indented: true) {
                        NSApp.activate(ignoringOtherApps: true)
                        NSApp.orderFrontStandardAboutPanel(nil)
                    }
                }
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text(state.settings.masterEnabled ? "Proxying enabled" : "Master switch off")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            Text(state.appVersion)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var quitRow: some View {
        menuButton(title: "Quit ProxyPilot", systemImage: "power") {
            NSApp.terminate(nil)
        }
    }

    // MARK: Building blocks

    private func menuButton(
        title: LocalizedStringKey,
        systemImage: String,
        indented: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 11))
                    .frame(width: 14)
                Text(title)
                    .font(Theme.body)
                Spacer(minLength: 0)
            }
            .padding(.leading, indented ? 26 : 12)
            .padding(.trailing, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func isDirect(_ app: ManagedApplication) -> Bool {
        app.proxyProfileID == nil || state.proxy(for: app)?.isDirect == true || app.launchStrategy == .direct
    }

    private func showMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
