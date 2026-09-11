//
//  ProxyPilotApp.swift
//  ProxyPilot
//
//  Per-App Proxy Manager for macOS.
//
//  Two scenes: the main window and a menu bar panel. A master switch in the
//  toolbar (and in the panel) gates every proxy launch.
//

import AppKit
import SwiftUI

@main
struct ProxyPilotApp: App {

    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("ProxyPilot", id: "main") {
            MainView()
                .environmentObject(state)
                .frame(minWidth: 1000, minHeight: 620)
                .task {
                    await state.bootstrap()
                    applyStartupPreferences()
                }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1140, height: 720)
        .commands { menuCommands }

        MenuBarExtra(isInserted: Binding(
            get: { state.settings.showMenuBarIcon },
            set: { state.setShowMenuBarIcon($0) }
        )) {
            MenuBarView()
                .environmentObject(state)
        } label: {
            // Menu bar icons must be a monochrome template so they adapt to light and
            // dark menu bars — the full-colour logo would look wrong there.
            // `arrow.triangle.branch` is the SF Symbol that matches the logo's fork.
            Image(systemName: "arrow.triangle.branch")
        }
        .menuBarExtraStyle(.window)
    }

    // MARK: Commands

    @CommandsBuilder
    private var menuCommands: some Commands {
        CommandGroup(replacing: .newItem) { }

        CommandMenu("ProxyPilot") {
            Button("Enable All") {
                Task { await state.enableAll() }
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])

            Button("Disable All") {
                Task { await state.disableAll() }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])

            Divider()

            Button("Test All Proxies") {
                Task { await state.testAllProxies() }
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])

            Divider()

            Button("Applications") { state.selection = .applications }
                .keyboardShortcut("1", modifiers: .command)

            Button("Proxies") { state.selection = .proxies }
                .keyboardShortcut("2", modifiers: .command)

            Button("Settings…") { state.selection = .settings }
                .keyboardShortcut(",", modifiers: .command)

            Button("Diagnostics") { state.selection = .diagnostics }
                .keyboardShortcut("l", modifiers: [.command, .shift])
        }
    }

    // MARK: Startup

    /// Honours "Start Minimized" — but only when the menu bar icon is available,
    /// so the app can never become unreachable.
    private func applyStartupPreferences() {
        guard state.settings.startMinimized, state.settings.showMenuBarIcon else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            NSApp.hide(nil)
        }
    }
}
