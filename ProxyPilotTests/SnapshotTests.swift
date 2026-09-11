//
//  SnapshotTests.swift
//  ProxyPilotTests
//
//  Renders each screen offscreen to /tmp/proxypilot-shots so the layout can be
//  reviewed without a display. Not an assertion suite — it fails only if a view
//  cannot be rasterised at all.
//

import AppKit
import SwiftUI
import XCTest
@testable import ProxyPilot

@MainActor
final class SnapshotTests: XCTestCase {

    private let outputDirectory = URL(fileURLWithPath: "/tmp/proxypilot-shots", isDirectory: true)

    // `nonisolated` so they can be used as default argument values.
    private nonisolated static let english = Locale(identifier: "en")
    private nonisolated static let simplifiedChinese = Locale(identifier: "zh-Hans")

    private func makeState(locale: Locale = SnapshotTests.english) -> AppState {
        Localized.localeOverride = locale
        defer { Localized.localeOverride = nil }
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ProxyPilotSnapshots-\(UUID().uuidString)", isDirectory: true)
        let state = AppState(persistence: PersistenceService(directory: directory))

        // Deterministic, design-matching fixture data.
        let flclash = ProxyProfile(
            id: UUID(uuidString: "97F0EC75-25DF-4BC5-8047-BDB0F680C3E8")!,
            name: "FlClash", type: .http, host: "127.0.0.1", port: 7890
        )
        let socks = ProxyProfile(
            id: UUID(uuidString: "18DCD0FA-5C06-461E-836A-A0FA284FBF67")!,
            name: "Local SOCKS", type: .socks5, host: "127.0.0.1", port: 7890
        )
        let office = ProxyProfile(
            id: UUID(uuidString: "0F1C2D3E-4A5B-4C6D-8E7F-90A1B2C3D4E5")!,
            name: "Office Proxy", type: .http, host: "10.0.0.1", port: 8080
        )
        state.proxies = [flclash, socks, office]
        state.health[flclash.id] = ProxyHealth(
            isReachable: true, tcpLatencyMs: 4, httpLatencyMs: 182,
            statusCode: 204, testedAt: Date(), failureReason: nil
        )
        state.health[socks.id] = ProxyHealth(
            isReachable: true, tcpLatencyMs: 3, httpLatencyMs: 96,
            statusCode: 204, testedAt: Date(), failureReason: nil
        )
        state.health[office.id] = ProxyHealth(
            isReachable: false, tcpLatencyMs: nil, httpLatencyMs: nil,
            statusCode: nil, testedAt: Date(),
            failureReason: Localized.format("Nothing is listening on %@:%lld.", "10.0.0.1", 8080)
        )

        let fixtures: [(String, String, String, String, ApplicationRuntime, Bool)] = [
            ("Codex", "com.openai.codex", "/Applications/Codex.app",
             "/Applications/Codex.app/Contents/MacOS/Codex", .electron, true),
            ("Cursor", "com.cursor.Cursor", "/Applications/Cursor.app",
             "/Applications/Cursor.app/Contents/MacOS/Cursor", .electron, true),
            ("Visual Studio Code", "com.microsoft.VSCode", "/Applications/Visual Studio Code.app",
             "/Applications/Visual Studio Code.app/Contents/MacOS/Electron", .electron, true),
            ("Google Chrome", "com.google.Chrome", "/Applications/Google Chrome.app",
             "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", .chromium, false),
            ("Terminal", "com.apple.Terminal", "/System/Applications/Utilities/Terminal.app",
             "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", .native, true),
            ("Xcode", "com.apple.dt.Xcode", "/Applications/Xcode.app",
             "/Applications/Xcode.app/Contents/MacOS/Xcode", .native, false)
        ]

        state.applications = fixtures.map { name, bundleID, path, executable, runtime, enabled in
            ManagedApplication(
                name: name,
                bundleIdentifier: bundleID,
                bundlePath: path,
                executablePath: executable,
                enabled: enabled,
                proxyProfileID: name == "Google Chrome" || name == "Xcode"
                    ? ProxyProfile.directID
                    : (name == "Terminal" ? socks.id : flclash.id),
                launchStrategy: .auto,
                bypassDomains: AppSettings.defaultBypassList,
                runtime: runtime,
                version: "1.0"
            )
        }
        state.health[ProxyProfile.directID] = .unknown()
        return state
    }

    // MARK: Rendering

    private func render(
        _ view: some View,
        size: CGSize,
        named name: String,
        appearance: NSAppearance.Name = .aqua,
        locale: Locale = SnapshotTests.english
    ) throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        // SwiftUI reads Environment(\.locale); models and services read Localized.
        // Pin both so the shots are deterministic and language-switchable.
        Localized.localeOverride = locale
        defer { Localized.localeOverride = nil }

        let hosting = NSHostingView(rootView: view.environment(\.locale, locale))
        hosting.frame = CGRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        // Pin the appearance so the shots are reproducible and comparable with the
        // reference design (the host machine is in Dark mode).
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()

        // Give SwiftUI's attribute graph time to settle before rasterising.
        RunLoop.current.run(until: Date().addingTimeInterval(0.9))
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()

        defer { window.orderOut(nil) }

        guard let representation = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw XCTSkip("Could not allocate a bitmap for \(name)")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: representation)

        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw XCTSkip("Could not encode PNG for \(name)")
        }
        let destination = outputDirectory.appendingPathComponent(name)
        try data.write(to: destination)
        XCTAssertGreaterThan(data.count, 4_000, "\(name) looks empty (\(data.count) bytes)")
        print("[snapshot] \(destination.path) (\(data.count) bytes)")
    }

    private let windowSize = CGSize(width: 1180, height: 720)

    // MARK: Screens

    func testRenderApplicationsScreen() throws {
        let state = makeState()
        state.selection = .applications
        try render(MainView().environmentObject(state), size: windowSize, named: "01-applications.png")
    }

    func testRenderApplicationDetail() throws {
        let state = makeState()
        // `.inspector` composites in its own layer, which `cacheDisplay` cannot
        // traverse — render the pane on its own instead.
        let app = try XCTUnwrap(state.applications.first { $0.name == "Cursor" })
        try render(
            ApplicationDetailView(app: app)
                .environmentObject(state)
                .frame(width: 340, height: 700),
            size: CGSize(width: 340, height: 700),
            named: "02-application-detail.png"
        )
    }

    func testRenderProxiesScreen() throws {
        let state = makeState()
        state.selection = .proxies
        // The "unavailable" row should read as a warning.
        try render(MainView().environmentObject(state), size: windowSize, named: "03-proxies.png")
    }

    func testRenderProxyEditor() throws {
        let state = makeState()
        let profile = try XCTUnwrap(state.proxies.first)
        try render(
            ProxyEditorView(original: profile, existingPassword: "demo-password", onCancel: {})
                .environmentObject(state)
                .frame(width: 320, height: 620),
            size: CGSize(width: 320, height: 620),
            named: "04-proxy-editor.png"
        )
    }

    func testRenderSettingsScreen() throws {
        let state = makeState()
        state.selection = .settings
        try render(MainView().environmentObject(state), size: windowSize, named: "05-settings.png")
    }

    func testRenderDiagnosticsScreen() throws {
        let state = makeState()
        state.selection = .diagnostics
        state.settings.enableDebugLogging = false
        state.log.info("ProxyPilot 1.0 (1) starting", category: .app, detail: [
            ("Applications", "6"), ("Proxies", "3"),
            ("Support directory", state.persistence.directory.path)
        ])
        state.log.success("Launched Codex", category: .launcher, detail: [
            ("Executable", "/Applications/Codex.app/Contents/MacOS/Codex"),
            ("Strategy", "Chromium"),
            ("Launch method", "NSWorkspace"),
            ("Proxy", "http://127.0.0.1:7890"),
            ("Arguments", "--proxy-server=http://127.0.0.1:7890 --proxy-bypass-list=localhost;127.0.0.1;::1"),
            ("Result", "Success")
        ])
        state.log.success("Proxy available", category: .proxy, detail: [
            ("Reachable", "yes"), ("TCP", "4 ms"), ("HTTP", "182 ms"),
            ("Status", "204"), ("Reason", "—")
        ])
        state.log.error("Proxy unavailable", category: .proxy, detail: [
            ("Reachable", "no"), ("TCP", "—"), ("HTTP", "—"), ("Status", "—"),
            ("Reason", "Nothing is listening on 10.0.0.1:8080.")
        ])
        try render(MainView().environmentObject(state), size: windowSize, named: "06-diagnostics.png")
    }

    func testRenderMenuBarPanel() throws {
        let state = makeState()
        try render(
            MenuBarView().environmentObject(state).frame(width: 300),
            size: CGSize(width: 300, height: 380),
            named: "07-menu-bar.png"
        )
    }

    func testRenderSidebarStandalone() throws {
        let state = makeState()
        state.selection = .proxies
        // The sidebar uses vibrancy, which `cacheDisplay` cannot traverse from the
        // split view root — render it on its own to inspect it.
        try render(
            SidebarView().environmentObject(state).frame(width: 208, height: 420),
            size: CGSize(width: 208, height: 420),
            named: "09-sidebar.png"
        )
    }

    func testRenderApplicationsScreenDark() throws {
        let state = makeState()
        state.selection = .applications
        try render(
            MainView().environmentObject(state),
            size: windowSize,
            named: "11-applications-dark.png",
            appearance: .darkAqua
        )
    }

    func testRenderRowToggleStates() throws {
        let state = makeState()
        let enabled = try XCTUnwrap(state.applications.first { $0.name == "Visual Studio Code" })
        let direct = try XCTUnwrap(state.applications.first { $0.name == "Google Chrome" })

        let rows = VStack(spacing: 0) {
            ApplicationRowView(
                app: enabled, bundleIDWidth: 200, proxyWidth: 176, statusWidth: 158,
                actionsWidth: 30, isSelected: false
            )
            Hairline()
            ApplicationRowView(
                app: direct, bundleIDWidth: 200, proxyWidth: 176, statusWidth: 158,
                actionsWidth: 30, isSelected: false
            )
        }
        .environmentObject(state)
        .frame(width: 640)
        .background(Color(nsColor: .textBackgroundColor))
        .scaleEffect(1.9, anchor: .topLeading)
        .frame(width: 980, height: 240, alignment: .topLeading)

        try render(rows, size: CGSize(width: 980, height: 240), named: "12-row-toggles.png")
    }

    /// The brand headers use vibrancy-backed containers that `cacheDisplay` does not
    /// always traverse from a full-window root, so they get their own reference shot.
    func testRenderNavigationShell() throws {
        let state = makeState()
        state.selection = .proxies

        let comparison = VStack(alignment: .leading, spacing: 6) {
            Text("SidebarView").font(.caption)
            SidebarView().environmentObject(state).frame(width: 300, height: 300)
            Text("MenuBarView").font(.caption)
            MenuBarView().environmentObject(state).frame(width: 300)
        }
        .padding(12)
        .frame(width: 324, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))

        try render(
            comparison.scaleEffect(1.4, anchor: .topLeading)
                .frame(width: 470, height: 820, alignment: .topLeading),
            size: CGSize(width: 470, height: 820),
            named: "13-navigation-shell.png"
        )
    }

    // MARK: Simplified Chinese
    //
    // Rendered with zh-Hans pinned, so a missing or mismatched key shows up as
    // English text sitting in an otherwise Chinese layout.

    func testRenderApplicationsScreenChinese() throws {
        let state = makeState(locale: Self.simplifiedChinese)
        state.selection = .applications
        try render(MainView().environmentObject(state), size: windowSize,
                   named: "20-applications-zh.png", locale: Self.simplifiedChinese)
    }

    func testRenderApplicationDetailChinese() throws {
        let state = makeState(locale: Self.simplifiedChinese)
        let app = try XCTUnwrap(state.applications.first { $0.name == "Cursor" })
        try render(ApplicationDetailView(app: app).environmentObject(state)
                        .frame(width: 340, height: 700),
                   size: CGSize(width: 340, height: 700),
                   named: "21-application-detail-zh.png", locale: Self.simplifiedChinese)
    }

    func testRenderProxiesScreenChinese() throws {
        let state = makeState(locale: Self.simplifiedChinese)
        state.selection = .proxies
        try render(MainView().environmentObject(state), size: windowSize,
                   named: "22-proxies-zh.png", locale: Self.simplifiedChinese)
    }

    func testRenderProxyEditorChinese() throws {
        let state = makeState(locale: Self.simplifiedChinese)
        let profile = try XCTUnwrap(state.proxies.first)
        try render(ProxyEditorView(original: profile, existingPassword: "demo-password", onCancel: {})
                        .environmentObject(state)
                        .frame(width: 320, height: 620),
                   size: CGSize(width: 320, height: 620),
                   named: "23-proxy-editor-zh.png", locale: Self.simplifiedChinese)
    }

    func testRenderSettingsScreenChinese() throws {
        let state = makeState(locale: Self.simplifiedChinese)
        state.selection = .settings
        try render(MainView().environmentObject(state), size: windowSize,
                   named: "24-settings-zh.png", locale: Self.simplifiedChinese)
    }

    func testRenderDiagnosticsScreenChinese() throws {
        let state = makeState(locale: Self.simplifiedChinese)
        state.selection = .diagnostics
        state.log.info("ProxyPilot 1.0 (1) starting", category: .app, detail: [
            ("Applications", "6"), ("Proxies", "3")
        ])
        state.log.success("Proxy available", category: .proxy, detail: [
            ("Reachable", "yes"), ("TCP", "4 ms"), ("HTTP", "182 ms"), ("Status", "204")
        ])
        try render(MainView().environmentObject(state), size: windowSize,
                   named: "25-diagnostics-zh.png", locale: Self.simplifiedChinese)
    }

    func testRenderMenuBarPanelChinese() throws {
        let state = makeState(locale: Self.simplifiedChinese)
        try render(MenuBarView().environmentObject(state).frame(width: 300),
                   size: CGSize(width: 300, height: 380),
                   named: "26-menu-bar-zh.png", locale: Self.simplifiedChinese)
    }

    func testRenderNavigationShellChinese() throws {
        let state = makeState(locale: Self.simplifiedChinese)
        state.selection = .proxies

        let comparison = VStack(alignment: .leading, spacing: 6) {
            Text("SidebarView").font(.caption)
            SidebarView().environmentObject(state).frame(width: 300, height: 300)
            Text("MenuBarView").font(.caption)
            MenuBarView().environmentObject(state).frame(width: 300)
        }
        .padding(12)
        .frame(width: 324, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))

        try render(comparison.scaleEffect(1.4, anchor: .topLeading)
                        .frame(width: 470, height: 820, alignment: .topLeading),
                   size: CGSize(width: 470, height: 820),
                   named: "27-navigation-shell-zh.png", locale: Self.simplifiedChinese)
    }

    func testRenderControlSwatches() throws {
        let on = Binding.constant(true)
        let off = Binding.constant(false)

        let swatches = VStack(alignment: .leading, spacing: 14) {
            Text("Switches (on / off)").font(Theme.body)
            HStack(spacing: 10) {
                Toggle("", isOn: on).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                Toggle("", isOn: off).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                Toggle("", isOn: on).labelsHidden().toggleStyle(.switch).controlSize(.small)
                Toggle("", isOn: off).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }

            Text("Status").font(Theme.body)
            HStack(spacing: 16) {
                ForEach([AppProxyStatus.active, .disabled, .direct, .restartRequired, .proxyUnavailable], id: \.label) { status in
                    StatusIndicator(status: status)
                }
            }

            Text("Pills").font(Theme.body)
            HStack(spacing: 8) {
                StatusPill(text: "Available", color: Theme.active)
                StatusPill(text: "Unavailable", color: Theme.danger)
                StatusPill(text: "Built-in", color: Theme.neutral)
                StatusPill(text: "Electron", color: Theme.blue)
            }

            Text("Buttons").font(Theme.body)
            HStack(spacing: 8) {
                Button("Primary") {}.buttonStyle(PrimaryButtonStyle())
                Button("Secondary") {}.buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(20)
        .frame(width: 420, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))

        try render(swatches, size: CGSize(width: 420, height: 300), named: "10-controls.png")
    }
}
