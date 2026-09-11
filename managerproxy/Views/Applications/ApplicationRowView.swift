//
//  ApplicationRowView.swift
//  ProxyPilot
//
//  One row in the Applications table. Status is conveyed by a label *and* a colour.
//

import SwiftUI

struct ApplicationRowView: View {

    let app: ManagedApplication
    let bundleIDWidth: CGFloat
    let proxyWidth: CGFloat
    let statusWidth: CGFloat
    let actionsWidth: CGFloat
    let isSelected: Bool

    @EnvironmentObject private var state: AppState
    @State private var isHovering = false

    private var status: AppProxyStatus { state.status(for: app) }
    private var isDirect: Bool { status == .direct }
    private var isRunning: Bool { state.isRunning(app) }

    var body: some View {
        HStack(spacing: 10) {
            applicationColumn
            bundleIDColumn
            proxyColumn
            statusColumn
            actionsColumn
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(height: Theme.rowHeight)
        .background(background)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture {
            state.selectedApplicationID = app.id
            state.isInspectorPresented = true
        }
        .contextMenu { menuItems }
    }

    // MARK: Columns

    private var applicationColumn: some View {
        HStack(spacing: 9) {
            AppIconView(bundlePath: app.bundlePath, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(app.name)
                        .font(Theme.appNameFont)
                        .lineLimit(1)
                    if isRunning {
                        Text("running")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.blue)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Theme.blue.opacity(0.12)))
                    }
                }
                Text(app.compactPath)
                    .font(Theme.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var bundleIDColumn: some View {
        MonoLabel(text: app.bundleIdentifier.isEmpty ? "—" : app.bundleIdentifier)
            .frame(width: bundleIDWidth, alignment: .leading)
    }

    private var proxyColumn: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(state.proxyForDisplay(app))
                .font(Theme.body)
                .lineLimit(1)
            Text(state.proxySubtitleForDisplay(app))
                .font(Theme.monoCaption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(width: proxyWidth, alignment: .leading)
    }

    private var statusColumn: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: enabledBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(isDirect)
                .help(isDirect
                      ? Localized.string("Assign a proxy profile to enable this app.")
                      : Localized.format("Enable proxying for %@", app.name))

            StatusIndicator(status: status)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: statusWidth, alignment: .leading)
    }

    private var actionsColumn: some View {
        Menu {
            menuItems
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isHovering ? .primary : .secondary)
                .frame(width: actionsWidth, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: actionsWidth)
        .help("Actions")
    }

    // MARK: Menu

    @ViewBuilder
    private var menuItems: some View {
        if !isDirect {
            Button(app.enabled
                   ? Localized.string("Disable Proxy")
                   : Localized.string("Enable Proxy")) {
                Task { await state.toggleEnabled(app) }
            }
        }

        if isRunning {
            Button("Restart With Proxy") {
                state.requestRestart(app)
            }
        } else {
            Button("Launch With Proxy") {
                Task { await state.launch(app) }
            }
        }

        if isRunning, status == .restartRequired {
            Button("Restart Required — Restart Now") {
                state.requestRestart(app)
            }
        }

        Divider()

        if let profile = state.proxy(for: app), !profile.isDirect {
            Button(Localized.format("Test %@", profile.name)) {
                Task { await state.testProxy(profile) }
            }
        }

        Button("Reveal in Finder") {
            state.revealInFinder(app)
        }

        Button("Details") {
            state.selectedApplicationID = app.id
            state.isInspectorPresented = true
        }

        Divider()

        Button("Remove from ProxyPilot", role: .destructive) {
            state.remove(app)
        }
    }

    // MARK: Helpers

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { app.enabled },
            set: { newValue in
                // Pass the requested value explicitly — deriving it from `app.enabled`
                // would double-toggle if SwiftUI writes this binding more than once.
                Task { await state.setEnabled(app, enabled: newValue) }
            }
        )
    }

    private var background: some View {
        Group {
            if isSelected {
                Theme.blue.opacity(0.10)
            } else if isHovering {
                Color.primary.opacity(0.04)
            } else {
                Color.clear
            }
        }
    }
}
