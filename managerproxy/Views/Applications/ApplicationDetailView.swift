//
//  ApplicationDetailView.swift
//  ProxyPilot
//
//  The right-hand inspector: proxy assignment, launch mode, bypass list,
//  compatibility matrix and the launch actions.
//

import SwiftUI

struct ApplicationDetailView: View {

    let app: ManagedApplication

    @EnvironmentObject private var state: AppState

    @State private var newBypassDomain = ""

    private var current: ManagedApplication {
        state.application(withID: app.id) ?? app
    }

    private var status: AppProxyStatus { state.status(for: current) }
    private var profile: ProxyProfile? { state.proxy(for: current) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                identitySection
                Hairline()
                proxySection
                Hairline()
                modeSection
                Hairline()
                bypassSection
                Hairline()
                compatibilitySection

                if state.settings.showLaunchCommand {
                    Hairline()
                    launchCommandSection
                }

                Hairline()
                actionsSection
            }
            .padding(16)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Identity

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 11) {
                AppIconView(bundlePath: current.bundlePath, size: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(current.name)
                        .font(.system(size: 15, weight: .semibold))
                    HStack(spacing: 6) {
                        StatusIndicator(status: status)
                        if !current.version.isEmpty {
                            Text("v\(current.version)")
                                .font(Theme.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 6) {
                DetailRow(label: "Bundle ID", value: current.bundleIdentifier.isEmpty ? "—" : current.bundleIdentifier, monospaced: true)
                DetailRow(label: "Path", value: current.bundlePath, monospaced: true)
                DetailRow(label: "Executable", value: current.executablePath.isEmpty ? "—" : current.executablePath, monospaced: true)
                DetailRow(label: "Runtime", value: current.runtime.displayName)
                DetailRow(
                    label: "Detected by",
                    value: AppDetector.detectionReason(
                        bundleURL: current.bundleURL,
                        bundleIdentifier: current.bundleIdentifier,
                        executableURL: current.executableURL
                    )
                )
            }
        }
    }

    // MARK: Proxy

    private var proxySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelSectionTitle(text: "Proxy")

            Picker("", selection: Binding(
                get: { current.proxyProfileID ?? ProxyProfile.directID },
                set: { newValue in
                    state.assignProxy(newValue, to: current)
                    state.toast = "Proxy updated — restart \(current.name) to apply"
                }
            )) {
                ForEach(state.allProxies) { option in
                    Text(option.isDirect
                         ? Localized.string("Direct (no proxy)")
                         : Localized.format("%@ — %@", option.name, option.displayAddress))
                        .tag(option.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(current.usesTransparentProxy)

            if current.usesTransparentProxy {
                Label(
                    "Transparent proxy is active — launch-argument and environment proxy are disabled for this app.",
                    systemImage: "info.circle"
                )
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.blue)
            } else if let profile, !profile.isDirect {
                HStack(spacing: 6) {
                    StatusPill(
                        text: state.health(for: profile).statusLabel,
                        color: state.health(for: profile).color
                    )
                    Text(profile.subtitle)
                        .font(Theme.monoCaption)
                        .foregroundStyle(.secondary)
                }

                if profile.type == .socks5, current.runtime.supportsChromiumArguments {
                    // Chromium resolves DNS locally for socks5://, so a poisoned or
                    // fake-IP answer travels to the proxy. CONNECT carries the
                    // hostname instead, which is why HTTP is the safer default here.
                    Label(
                        Localized.string("SOCKS5 resolves domains locally in Chromium — prefer an HTTP profile for this app."),
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.warning)
                }
            } else {
                Text("This app connects directly. Choose a proxy profile to route its traffic.")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            }

            if let profile, !profile.isDirect {
                transparentProxyRow
            }
        }
    }

    private var transparentProxyRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Transparent Proxy")
                        .font(Theme.body)
                    Text("Intercept this app's traffic with the system extension — covers apps that ignore launch arguments and environment variables.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 12)
                Toggle("", isOn: Binding(
                    get: { current.usesTransparentProxy },
                    set: { state.setTransparentProxyEnabled($0, for: current) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!state.settings.transparentProxyEnabled)
            }

            if !state.settings.transparentProxyEnabled {
                Text("Turn on Transparent Proxy in Settings to route this app per-flow.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.warning)
            }
        }
        .padding(.top, 4)
    }

    // MARK: Mode

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                PanelSectionTitle(text: "Mode")
                Spacer()
                Text(strategyHint)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            if current.usesTransparentProxy {
                Text("Launch mode is ignored — the system extension intercepts traffic regardless of how the app is started.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 2) {
                ForEach(LaunchStrategy.allCases) { option in
                    modeRow(option)
                        .disabled(current.usesTransparentProxy)
                }
            }
        }
    }

    private var strategyHint: String {
        guard let launcher = state.launcher.launcher(for: current) else {
            return Localized.string("Unsupported")
        }
        return Localized.format("Resolves to %@", launcher.displayName)
    }

    private func modeRow(_ option: LaunchStrategy) -> some View {
        Button {
            state.update(current) { $0.launchStrategy = option }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: current.launchStrategy == option ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(current.launchStrategy == option ? Theme.blue : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.displayName)
                        .font(Theme.body)
                    Text(option.explanation)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
    }

    // MARK: Bypass

    private var bypassSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelSectionTitle(text: "Bypass")

            FlowLayout(spacing: 5) {
                ForEach(current.bypassDomains, id: \.self) { domain in
                    HStack(spacing: 4) {
                        Text(domain)
                            .font(Theme.monoCaption)
                        Button {
                            state.update(current) { $0.bypassDomains.removeAll { $0 == domain } }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
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
                TextField("Add domain or IP…", text: $newBypassDomain)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.body)
                    .onSubmit(addBypass)

                Button("Add", action: addBypass)
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(newBypassDomain.trimmingCharacters(in: .whitespaces).isEmpty)

                Button {
                    state.resetBypassList(for: current)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(SecondaryButtonStyle())
                .help("Reset to the default bypass list")
            }

            Text("Applied as NO_PROXY and as Chromium’s --proxy-bypass-list.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private func addBypass() {
        let value = newBypassDomain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        state.addBypassDomain(value, to: current)
        newBypassDomain = ""
    }

    // MARK: Compatibility

    private var compatibilitySection: some View {
        let report = AppDetector.compatibility(for: current)

        return VStack(alignment: .leading, spacing: 8) {
            PanelSectionTitle(text: "Proxy compatibility")

            compatibilityRow(
                title: "Chromium Proxy",
                detail: report.chromiumSupported
                    ? Localized.string("--proxy-server supported")
                    : Localized.string("Not available for this runtime"),
                supported: report.chromiumSupported
            )
            compatibilityRow(
                title: "Environment Proxy",
                detail: report.environmentNote,
                supported: report.environmentSupported
            )
            compatibilityRow(
                title: "Transparent Proxy",
                detail: "Requires Advanced Mode (Phase 2)",
                supported: false
            )
        }
    }

    private func compatibilityRow(title: LocalizedStringKey, detail: String, supported: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: supported ? "checkmark.circle.fill" : "minus.circle")
                .font(.system(size: 11))
                .foregroundStyle(supported ? Theme.active : Color.secondary.opacity(0.6))
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(Theme.body)
                Text(detail).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Launch command

    private var launchCommandSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                PanelSectionTitle(text: "Launch command")
                Spacer()
                Button {
                    if let plan = state.previewPlan(for: current) {
                        Pasteboard.copy(plan.shellCommand)
                        state.toast = "Command copied"
                    }
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(SecondaryButtonStyle())
                .help("Copy the launch command")
            }

            if let plan = state.previewPlan(for: current) {
                Text(plan.shellCommand)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(9)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Theme.hairline, lineWidth: 1)
                    )
            } else {
                Text("No plan available for this configuration.")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Actions

    private var actionsSection: some View {
        VStack(spacing: 8) {
            if let profile, !profile.isDirect {
                Button {
                    Task { await state.testProxy(profile) }
                } label: {
                    HStack {
                        if state.testingProxyIDs.contains(profile.id) {
                            ProgressView().controlSize(.small)
                        }
                        Text(state.testingProxyIDs.contains(profile.id) ? "Testing…" : "Test Proxy")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle(fullWidth: true))
                .disabled(state.testingProxyIDs.contains(profile.id))
            }

            Button {
                state.requestRestart(current)
            } label: {
                Label(
                    state.isRunning(current) ? "Restart With Proxy" : "Launch With Proxy",
                    systemImage: state.isRunning(current) ? "arrow.clockwise" : "play.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle(fullWidth: true))

            if status.isWarning {
                Text(status == .proxyUnavailable
                     ? "The assigned proxy is not reachable — the app may not have network access."
                     : "The app is running with an older configuration. Restart to apply the current settings.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(status.color)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - FlowLayout

/// Minimal wrapping layout used for the bypass chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width + (rowWidth > 0 ? spacing : 0) > maxWidth, rowWidth > 0 {
                totalHeight += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + (rowWidth > 0 ? spacing : 0)
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth == .infinity ? rowWidth : maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
