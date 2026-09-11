//
//  SettingsView.swift
//  ProxyPilot
//

import AppKit
import SwiftUI

struct SettingsView: View {

    @EnvironmentObject private var state: AppState

    @State private var newBypassEntry = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(
                title: "Settings",
                subtitle: "Preferences for ProxyPilot itself — never for your system proxy."
            )
            .padding(.horizontal, Theme.contentPadding)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Hairline()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    generalSection
                    proxySection
                    transparentSection
                    advancedSection
                    aboutSection
                }
                .padding(Theme.contentPadding)
                .frame(maxWidth: 620, alignment: .leading)
            }
        }
    }

    // MARK: General

    private var generalSection: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                PanelSectionTitle(text: "General")

                settingToggle(
                    title: "Launch ProxyPilot at Login",
                    subtitle: "Start the menu bar helper when you log in.",
                    isOn: Binding(
                        get: { state.settings.launchAtLogin },
                        set: { state.setLaunchAtLogin($0) }
                    )
                )

                settingToggle(
                    title: "Show Menu Bar Icon",
                    subtitle: "Keep quick per-app switches one click away.",
                    isOn: Binding(
                        get: { state.settings.showMenuBarIcon },
                        set: { state.setShowMenuBarIcon($0) }
                    )
                )

                settingToggle(
                    title: "Start Minimized",
                    subtitle: "Open straight to the menu bar without showing the window.",
                    isOn: binding(\.startMinimized)
                )

                settingToggle(
                    title: "Confirm Before Restarting Apps",
                    subtitle: "Always ask before quitting an app to apply proxy settings.",
                    isOn: binding(\.confirmBeforeRestartingApps)
                )

                FormRow(label: "Appearance",
                        hint: Localized.string("Light matches the reference design; System follows macOS.")) {
                    Picker("", selection: Binding(
                        get: { state.settings.appearance },
                        set: { state.setAppearance($0) }
                    )) {
                        ForEach(AppAppearance.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                }
            }
        }
    }

    // MARK: Proxy

    private var proxySection: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                PanelSectionTitle(text: "Proxy")

                FormRow(label: "Default Proxy",
                        hint: Localized.string("Assigned automatically when you add a new application.")) {
                    Picker("", selection: Binding(
                        get: { state.settings.defaultProxyProfileID ?? ProxyProfile.directID },
                        set: { state.setDefaultProxy($0) }
                    )) {
                        ForEach(state.allProxies) { profile in
                            Text(profile.isDirect
                                 ? Localized.string("Direct (no proxy)")
                                 : Localized.format("%@ — %@", profile.name, profile.displayAddress))
                                .tag(profile.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                FormRow(label: "Default Bypass List",
                        hint: Localized.string("Copied into every new application you add.")) {
                    VStack(alignment: .leading, spacing: 8) {
                        FlowLayout(spacing: 5) {
                            ForEach(state.settings.defaultBypassList, id: \.self) { entry in
                                HStack(spacing: 4) {
                                    Text(entry).font(Theme.monoCaption)
                                    Button {
                                        state.settings.defaultBypassList.removeAll { $0 == entry }
                                        state.persistSettings()
                                    } label: {
                                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.primary.opacity(0.06)))
                            }
                        }

                        HStack(spacing: 6) {
                            TextField("*.local", text: $newBypassEntry)
                                .textFieldStyle(.roundedBorder)
                                .font(Theme.body)
                                .onSubmit(addBypassEntry)

                            Button("Add", action: addBypassEntry)
                                .buttonStyle(SecondaryButtonStyle())
                                .disabled(newBypassEntry.trimmingCharacters(in: .whitespaces).isEmpty)

                            Button("Reset") {
                                state.settings.defaultBypassList = AppSettings.defaultBypassList
                                state.persistSettings()
                            }
                            .buttonStyle(SecondaryButtonStyle())
                        }
                    }
                }
            }
        }
    }

    private func addBypassEntry() {
        let value = newBypassEntry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        guard !state.settings.defaultBypassList.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) else {
            newBypassEntry = ""
            return
        }
        state.settings.defaultBypassList.append(value)
        state.persistSettings()
        newBypassEntry = ""
    }

    // MARK: Transparent proxy (Phase 2)

    private var transparentSection: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                PanelSectionTitle(text: "Transparent Proxy")

                settingToggle(
                    title: "Intercept Traffic Per-App",
                    subtitle: "Route apps that ignore launch arguments and environment variables. Requires the ProxyPilot system extension.",
                    isOn: Binding(
                        get: { state.settings.transparentProxyEnabled },
                        set: { state.setTransparentProxyEnabled($0) }
                    )
                )

                transparentStatusRow
            }
        }
    }

    private var transparentStatusRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                statusDot
                Text(statusText)
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                if case .activating = state.transparent.state {
                    ProgressView().controlSize(.mini)
                }
            }
            Text("Routed apps: \(state.transparent.routedAppCount)")
                .font(Theme.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 7, height: 7)
    }

    private var statusColor: Color {
        switch state.transparent.state {
        case .active:   return .green
        case .disabled: return .gray
        case .activating: return .yellow
        case .failed:   return .red
        case .unknown:  return .gray
        }
    }

    private var statusText: String {
        switch state.transparent.state {
        case .active:
            return Localized.format("Active — %lld app(s) routed", state.transparent.routedAppCount)
        case .disabled:
            return "Extension ready, proxy configuration off."
        case .activating:
            return "Waiting for system approval…"
        case .failed(let message):
            return "Failed: \(message)"
        case .unknown:
            return "Not configured yet."
        }
    }

    // MARK: Advanced

    private var advancedSection: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                PanelSectionTitle(text: "Advanced")

                settingToggle(
                    title: "Enable Debug Logging",
                    subtitle: "Include debug-level entries in Diagnostics.",
                    isOn: binding(\.enableDebugLogging)
                )

                settingToggle(
                    title: "Show Launch Command",
                    subtitle: "Display the exact command used to start an app.",
                    isOn: binding(\.showLaunchCommand)
                )

                FormRow(label: "Proxy Test URL",
                        hint: Localized.string("A small endpoint your proxy can reach. Default is Google's generate_204.")) {
                    TextField("https://www.gstatic.com/generate_204", text: binding(\.proxyTestURL))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5, design: .monospaced))
                }
            }
        }
    }

    // MARK: About

    private var aboutSection: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                PanelSectionTitle(text: "About")

                DetailRow(label: "Version", value: state.appVersion)
                DetailRow(label: "Data folder", value: state.persistence.directory.path, monospaced: true)
                DetailRow(label: "Running apps",
                          value: Localized.format("%lld managed", state.managedRunningApplications.count))
                DetailRow(label: "System proxy", value: Localized.string("Never modified"))

                HStack(spacing: 8) {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([state.persistence.directory])
                    } label: {
                        Label("Reveal Data Folder", systemImage: "folder")
                    }
                    .buttonStyle(SecondaryButtonStyle())

                    Button {
                        state.selection = .diagnostics
                    } label: {
                        Label("Open Diagnostics", systemImage: "stethoscope")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }

                Text("Phase 1 launches apps with Chromium arguments or proxy environment variables — apps that ignore both stay direct. Phase 2 (Transparent Proxy) intercepts per-app traffic with a system extension; UDP and DNS still bypass the proxy.")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Helpers

    private func binding<T: Equatable>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { state.settings[keyPath: keyPath] },
            set: { newValue in
                // Idempotent: SwiftUI can write a binding back during layout, and an
                // unconditional mutation would invalidate the graph in a loop.
                guard state.settings[keyPath: keyPath] != newValue else { return }
                state.settings[keyPath: keyPath] = newValue
                state.persistSettings()
            }
        )
    }

    private func settingToggle(title: LocalizedStringKey, subtitle: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Theme.body)
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}
