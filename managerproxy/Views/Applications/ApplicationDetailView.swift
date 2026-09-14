//
//  ApplicationDetailView.swift
//  ProxyPilot
//
//  The right-hand inspector. Three mutually-exclusive proxy modes:
//    - Off               : no proxying
//    - Launch Proxy      : Phase 1 — --proxy-server / env vars, app must be
//                          launched by ProxyPilot
//    - Transparent Proxy : Phase 2 — system extension intercepts traffic per-flow,
//                          no launch requirement
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

    /// The currently-selected proxy mode, derived from the app's configuration.
    private var activeMode: ProxyMode {
        if current.usesTransparentProxy { return .transparent }
        if let profile, !profile.isDirect { return .launch }
        return .off
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                identitySection
                Hairline()
                modeSection
                Hairline()

                switch activeMode {
                case .launch:
                    launchProxySections
                case .transparent:
                    transparentProxySections
                case .off:
                    offSection
                }
            }
            .padding(16)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Mode selector

    private enum ProxyMode: String, CaseIterable, Identifiable {
        case off = "Off"
        case launch = "Launch Proxy"
        case transparent = "Transparent Proxy"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .off: return "circle"
            case .launch: return "terminal"
            case .transparent: return "network"
            }
        }

        var helpText: String {
            switch self {
            case .off:
                return "This app connects directly with no proxy."
            case .launch:
                return "Passes --proxy-server or proxy environment variables when launching the app. The app must be started by ProxyPilot."
            case .transparent:
                return "System extension intercepts this app's TCP traffic and relays it through an upstream proxy. Works regardless of how the app is launched."
            }
        }
    }

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelSectionTitle(text: "Proxy Mode")

            Picker("", selection: Binding(
                get: { activeMode },
                set: { newMode in
                    switch newMode {
                    case .off:
                        // Disable both launch-proxy and transparent-proxy.
                        state.update(current) {
                            $0.usesTransparentProxy = false
                            $0.proxyProfileID = nil
                        }
                    case .launch:
                        // Switch to launch proxy: disable transparent, keep
                        // the assigned profile (or assign the default).
                        state.update(current) { $0.usesTransparentProxy = false }
                        if current.proxyProfileID == nil || profile?.isDirect == true {
                            state.assignProxy(state.settings.defaultProxyProfileID ?? ProxyProfile.directID, to: current)
                        }
                    case .transparent:
                        // Transparent proxy needs a non-direct upstream. If the
                        // current profile is direct or missing, assign the default.
                        if current.proxyProfileID == nil || profile?.isDirect == true {
                            state.assignProxy(state.settings.defaultProxyProfileID ?? ProxyProfile.directID, to: current)
                        }
                        state.setTransparentProxyEnabled(true, for: current)
                    }
                }
            )) {
                ForEach(ProxyMode.allCases) { mode in
                    Label(mode.rawValue, systemImage: mode.icon).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            Text(activeMode.helpText)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Identity

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
            }
        }
    }

    // MARK: - Launch Proxy (Phase 1) sections

    @ViewBuilder
    private var launchProxySections: some View {
        launchProxyPickerSection
        Hairline()
        launchModeSection
        Hairline()
        bypassSection
        Hairline()
        launchCompatibilitySection
        if state.settings.showLaunchCommand {
            Hairline()
            launchCommandSection
        }
        Hairline()
        launchActionsSection
    }

    private var launchProxyPickerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelSectionTitle(text: "Upstream Proxy")

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

            if let profile, !profile.isDirect {
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
                    Label(
                        Localized.string("SOCKS5 resolves domains locally in Chromium — prefer an HTTP profile for this app."),
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.warning)
                }
            }
        }
    }

    private var launchModeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                PanelSectionTitle(text: "Launch Strategy")
                Spacer()
                Text(strategyHint)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 2) {
                ForEach(LaunchStrategy.allCases) { option in
                    launchModeRow(option)
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

    private func launchModeRow(_ option: LaunchStrategy) -> some View {
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

    private var launchCompatibilitySection: some View {
        let report = AppDetector.compatibility(for: current)

        return VStack(alignment: .leading, spacing: 8) {
            PanelSectionTitle(text: "Compatibility")

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

    private var launchActionsSection: some View {
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

    // MARK: - Transparent Proxy (Phase 2) sections

    @ViewBuilder
    private var transparentProxySections: some View {
        transparentProxyPickerSection
        Hairline()
        transparentStatusSection
        Hairline()
        transparentInfoSection
    }

    private var transparentProxyPickerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelSectionTitle(text: "Upstream Proxy")

            Picker("", selection: Binding(
                get: { current.proxyProfileID ?? ProxyProfile.directID },
                set: { newValue in
                    state.assignProxy(newValue, to: current)
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

            if let profile, !profile.isDirect {
                HStack(spacing: 6) {
                    StatusPill(
                        text: state.health(for: profile).statusLabel,
                        color: state.health(for: profile).color
                    )
                    Text(profile.subtitle)
                        .font(Theme.monoCaption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Label(
                    "Transparent proxy requires an upstream proxy — select one above.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.warning)
            }
        }
    }

    private var transparentStatusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelSectionTitle(text: "Status")

            HStack(spacing: 8) {
                Circle()
                    .fill(transparentStatusColor)
                    .frame(width: 8, height: 8)
                Text(transparentStatusText)
                    .font(Theme.body)
                Spacer()
            }

            if !state.settings.transparentProxyEnabled {
                Label(
                    "Transparent Proxy master switch is off. Turn it on in Settings to activate the system extension.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.warning)
            }
        }
    }

    private var transparentStatusColor: Color {
        guard state.settings.transparentProxyEnabled else { return .gray }
        switch state.transparent.state {
        case .active:   return .green
        case .activating: return .yellow
        case .failed:   return .red
        default:        return .gray
        }
    }

    private var transparentStatusText: String {
        guard state.settings.transparentProxyEnabled else { return "Master switch off" }
        switch state.transparent.state {
        case .active:
            return Localized.format("Active — intercepting traffic")
        case .activating:
            return "Activating…"
        case .failed(let message):
            return "Failed: \(message)"
        case .disabled:
            return "Extension ready"
        case .unknown:
            return "Not configured"
        }
    }

    private var transparentInfoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelSectionTitle(text: "How It Works")

            infoRow(
                icon: "bolt.fill",
                title: "No launch required",
                detail: "The system extension intercepts traffic regardless of how or when the app was started."
            )
            infoRow(
                icon: "network",
                title: "TCP only",
                detail: "Only TCP traffic is relayed. UDP and DNS continue to use the system's direct connection."
            )
            infoRow(
                icon: "lock.shield",
                title: "SNI-based routing",
                detail: "Original hostnames are recovered from TLS SNI / HTTP Host headers so upstream proxies that require domain-based routing work correctly."
            )
            infoRow(
                icon: "gearshape",
                title: "Per-app rules",
                detail: "Only apps with Transparent Proxy enabled are intercepted. All other apps are untouched."
            )
        }
    }

    private func infoRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(Theme.blue)
                .frame(width: 16, alignment: .center)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Theme.body)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Off section

    private var offSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                "This app is not proxied. It connects directly to the internet.",
                systemImage: "circle"
            )
            .font(Theme.body)
            .foregroundStyle(.secondary)

            Text("Choose Launch Proxy or Transparent Proxy above to route this app's traffic.")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    // MARK: - Bypass (shared, but only shown in Launch mode)

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

            Text("Applied as NO_PROXY and as Chromium's --proxy-bypass-list.")
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

    // MARK: - Launch command (Phase 1 only)

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
