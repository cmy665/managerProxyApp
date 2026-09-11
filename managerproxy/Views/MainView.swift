//
//  MainView.swift
//  ProxyPilot
//
//  Window shell: sidebar + page content, the master switch, and the global
//  restart / error / progress affordances.
//

import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {

    @EnvironmentObject private var state: AppState

    @State private var isDropTargeted = false

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            VStack(spacing: 0) {
                if let notice = state.masterOffNotice {
                    masterOffBanner(notice)
                }
                detailContent
            }
            .frame(minWidth: 700, maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay { dropTargetOverlay }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar { toolbarContent }
        .overlay(alignment: .bottom) { busyOverlay }
        .overlay(alignment: .bottom) { toastOverlay }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted, perform: handleDrop(providers:))
        .alert(
            state.alert?.title ?? Localized.string("ProxyPilot"),
            isPresented: isAlertPresented,
            presenting: state.alert
        ) { presentation in
            if presentation.offersProxyTest {
                Button("Test Proxy") {
                    Task { await state.testAllProxies() }
                }
            }
            if presentation.offersProxySettings {
                Button("Open Proxy Settings") {
                    state.selection = .proxies
                }
            }
            Button("OK", role: .cancel) { }
        } message: { presentation in
            Text([presentation.message, presentation.suggestion]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n"))
        }
        .alert(
            state.restartPrompt.map {
                Localized.format("%@ is currently running.", $0.app.name)
            } ?? Localized.string("ProxyPilot"),
            isPresented: isRestartPromptPresented,
            presenting: state.restartPrompt
        ) { prompt in
            if prompt.forcesQuit {
                Button(Localized.format("Force Quit %@", prompt.app.name), role: .destructive) {
                    Task { await state.forceQuitAndRestart(prompt.app) }
                }
            } else {
                Button(Localized.format("Restart %@", prompt.app.name)) {
                    Task { await state.restart(prompt.app, allowForceQuit: true) }
                }
            }
            Button("Cancel", role: .cancel) {
                state.restartPrompt = nil
            }
        } message: { prompt in
            Text(prompt.reason)
        }
        .alert(
            state.externalLaunchPrompt.map {
                Localized.format("%@ was launched outside ProxyPilot.", $0.app.name)
            } ?? Localized.string("ProxyPilot"),
            isPresented: isExternalLaunchPromptPresented,
            presenting: state.externalLaunchPrompt
        ) { prompt in
            Button(Localized.string("Restart With Proxy")) {
                Task { await state.restart(prompt.app, allowForceQuit: true) }
            }
            Button(Localized.string("Keep as is"), role: .cancel) {
                state.externalLaunchPrompt = nil
            }
        } message: { _ in
            Text(Localized.string("It is running without the proxy you assigned. Restart it through ProxyPilot to apply the settings."))
        }
    }

    // MARK: Pages

    private var isAlertPresented: Binding<Bool> {
        Binding(
            get: { state.alert != nil },
            set: { newValue in if !newValue { state.alert = nil } }
        )
    }

    private var isRestartPromptPresented: Binding<Bool> {
        Binding(
            get: { state.restartPrompt != nil },
            set: { newValue in if !newValue { state.restartPrompt = nil } }
        )
    }

    private var isExternalLaunchPromptPresented: Binding<Bool> {
        Binding(
            get: { state.externalLaunchPrompt != nil },
            set: { newValue in if !newValue { state.externalLaunchPrompt = nil } }
        )
    }

    @ViewBuilder
    private var detailContent: some View {
        switch state.selection ?? .applications {
        case .applications:
            ApplicationListView()
        case .proxies:
            ProxyListView()
        case .settings:
            SettingsView()
        case .diagnostics:
            DiagnosticsView()
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.blue)
                Text("ProxyPilot")
                    .font(.system(size: 12, weight: .semibold))
            }
        }

        ToolbarItem(placement: .primaryAction) {
            masterSwitch
        }
    }

    private var masterSwitch: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(state.settings.masterEnabled ? Theme.active : Theme.neutral)
                .frame(width: 7, height: 7)
            Text(state.settings.masterEnabled
                 ? Localized.string("ON")
                 : Localized.string("OFF"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(state.settings.masterEnabled ? Theme.active : Color.secondary)

            Toggle("", isOn: Binding(
                get: { state.settings.masterEnabled },
                set: { newValue in
                    Task { await state.setMasterEnabled(newValue) }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help("Master switch — when off, no app is launched with a proxy.")
        }
        .padding(.trailing, 4)
    }

    // MARK: Master-off banner

    private func masterOffBanner(_ notice: MasterOffNotice) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warning)
            VStack(alignment: .leading, spacing: 1) {
                Text("Master switch is off")
                    .font(.system(size: 12, weight: .semibold))
                Text(notice.summary)
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("Restart Managed Apps") {
                Task { await state.restartManagedApplications() }
            }
            .buttonStyle(SecondaryButtonStyle())
            Button("Dismiss") { state.dismissMasterOffNotice() }
                .buttonStyle(SecondaryButtonStyle())
        }
        .padding(.horizontal, Theme.contentPadding)
        .padding(.vertical, 10)
        .background(Theme.warning.opacity(0.10))
        .overlay(alignment: .bottom) { Hairline() }
    }

    // MARK: Drop target

    @ViewBuilder
    private var dropTargetOverlay: some View {
        if isDropTargeted {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.blue, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                .background(Theme.blue.opacity(0.05))
                .overlay(
                    Label("Drop .app bundles to add them", systemImage: "plus.app")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.blue)
                )
                .padding(8)
                .allowsHitTesting(false)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }

        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.pathExtension == "app" else { return }
                Task { @MainActor in
                    guard let discovered = AppScanner.makeDiscoveredApplication(from: url) else { return }
                    let added = state.add(discovered: [discovered])
                    state.toast = added > 0
                        ? Localized.format("Added %@", discovered.name)
                        : Localized.format("%@ is already in the list", discovered.name)
                }
            }
        }
        return true
    }

    // MARK: Progress + toast

    @ViewBuilder
    private var busyOverlay: some View {
        if state.isBusy, let message = state.busyMessage {
            HStack(spacing: 9) {
                ProgressView().controlSize(.small)
                Text(message).font(Theme.body)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                Capsule().fill(.regularMaterial)
            )
            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
            .padding(.bottom, 22)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var toastOverlay: some View {
        if let toast = state.toast {
            Text(toast)
                .font(Theme.body)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.primary.opacity(0.85)))
                .foregroundStyle(Color(nsColor: .textBackgroundColor))
                .padding(.bottom, 22)
                .task(id: toast) {
                    try? await Task.sleep(nanoseconds: 2_400_000_000)
                    if state.toast == toast { state.toast = nil }
                }
        }
    }
}
