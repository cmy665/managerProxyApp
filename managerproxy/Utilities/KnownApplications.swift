//
//  KnownApplications.swift
//  ProxyPilot
//
//  A curated mapping of well-known bundle identifiers to a display name and the
//  runtime ProxyPilot should assume. This is only a *hint* — `AppDetector` inspects
//  the bundle's Frameworks directory first and trusts the on-disk evidence.
//
//  Never decide by app name alone.
//

import Foundation

struct KnownApplication {
    let bundleIdentifier: String
    let displayName: String
    let runtime: ApplicationRuntime
}

enum KnownApplications {

    // MARK: Exact bundle identifiers

    static let all: [KnownApplication] = [
        // Chromium family
        KnownApplication(bundleIdentifier: "com.google.Chrome",              displayName: "Google Chrome",        runtime: .chromium),
        KnownApplication(bundleIdentifier: "com.google.Chrome.beta",         displayName: "Google Chrome Beta",   runtime: .chromium),
        KnownApplication(bundleIdentifier: "com.google.Chrome.canary",       displayName: "Google Chrome Canary", runtime: .chromium),
        KnownApplication(bundleIdentifier: "org.chromium.Chromium",          displayName: "Chromium",             runtime: .chromium),
        KnownApplication(bundleIdentifier: "com.brave.Browser",              displayName: "Brave Browser",        runtime: .chromium),
        KnownApplication(bundleIdentifier: "com.brave.Browser.beta",         displayName: "Brave Browser Beta",   runtime: .chromium),
        KnownApplication(bundleIdentifier: "com.microsoft.edgemac",          displayName: "Microsoft Edge",       runtime: .chromium),
        KnownApplication(bundleIdentifier: "com.microsoft.edgemac.Dev",      displayName: "Microsoft Edge Dev",   runtime: .chromium),
        KnownApplication(bundleIdentifier: "com.vivaldi.Vivaldi",            displayName: "Vivaldi",              runtime: .chromium),
        KnownApplication(bundleIdentifier: "com.operasoftware.Opera",        displayName: "Opera",                runtime: .chromium),
        KnownApplication(bundleIdentifier: "com.operasoftware.OperaGX",      displayName: "Opera GX",             runtime: .chromium),
        KnownApplication(bundleIdentifier: "company.thebrowser.Browser",     displayName: "Arc",                  runtime: .chromium),

        // Electron family
        KnownApplication(bundleIdentifier: "com.microsoft.VSCode",           displayName: "Visual Studio Code",   runtime: .electron),
        KnownApplication(bundleIdentifier: "com.microsoft.VSCodeInsiders",   displayName: "VS Code Insiders",     runtime: .electron),
        KnownApplication(bundleIdentifier: "com.todesktop.230313mzl4w4u92",  displayName: "Cursor",               runtime: .electron),
        KnownApplication(bundleIdentifier: "com.openai.codex",               displayName: "Codex",                runtime: .electron),
        KnownApplication(bundleIdentifier: "com.openai.chat",                displayName: "ChatGPT",              runtime: .electron),
        KnownApplication(bundleIdentifier: "com.hnc.Discord",                displayName: "Discord",              runtime: .electron),
        KnownApplication(bundleIdentifier: "com.tinyspeck.slackmacgap",      displayName: "Slack",                runtime: .electron),
        KnownApplication(bundleIdentifier: "notion.id",                      displayName: "Notion",               runtime: .electron),
        KnownApplication(bundleIdentifier: "com.figma.Desktop",              displayName: "Figma",                runtime: .electron),
        KnownApplication(bundleIdentifier: "com.postmanlabs.mac",            displayName: "Postman",              runtime: .electron),
        KnownApplication(bundleIdentifier: "md.obsidian",                    displayName: "Obsidian",             runtime: .electron),
        KnownApplication(bundleIdentifier: "net.whatsapp.WhatsApp",          displayName: "WhatsApp",             runtime: .electron),
        KnownApplication(bundleIdentifier: "ru.keepcoder.Telegram",          displayName: "Telegram",             runtime: .native),
        KnownApplication(bundleIdentifier: "com.electron",                   displayName: "Electron App",         runtime: .electron),
        KnownApplication(bundleIdentifier: "com.github.GitHubClient",        displayName: "GitHub Desktop",       runtime: .electron),
        KnownApplication(bundleIdentifier: "com.spotify.client",             displayName: "Spotify",              runtime: .native),
        KnownApplication(bundleIdentifier: "com.docker.docker",              displayName: "Docker Desktop",       runtime: .electron)
    ]

    private static let index: [String: KnownApplication] = {
        Dictionary(all.map { ($0.bundleIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
    }()

    /// Bundle identifier prefixes that imply a Chromium-based runtime.
    static let chromiumPrefixes: [String] = [
        "com.google.Chrome",
        "org.chromium.",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "com.vivaldi.",
        "com.operasoftware.",
        "com.google.Chrome."
    ]

    /// Bundle identifier prefixes that imply an Electron runtime.
    static let electronPrefixes: [String] = [
        "com.todesktop.",
        "com.openai.",
        "com.hnc.Discord",
        "com.tinyspeck.",
        "com.mongodb.",
        "com.electron."
    ]

    // MARK: Lookup

    static func known(bundleIdentifier: String) -> KnownApplication? {
        guard !bundleIdentifier.isEmpty else { return nil }
        if let exact = index[bundleIdentifier] { return exact }

        if chromiumPrefixes.contains(where: { bundleIdentifier.hasPrefix($0) }) {
            return KnownApplication(bundleIdentifier: bundleIdentifier, displayName: "", runtime: .chromium)
        }
        if electronPrefixes.contains(where: { bundleIdentifier.hasPrefix($0) }) {
            return KnownApplication(bundleIdentifier: bundleIdentifier, displayName: "", runtime: .electron)
        }
        return nil
    }

    /// Apps offered on first launch when they are present on disk.
    static let firstRunSuggestions: [String] = [
        "com.openai.codex",
        "com.todesktop.230313mzl4w4u92",
        "com.microsoft.VSCode",
        "com.google.Chrome",
        "com.apple.Terminal",
        "com.apple.dt.Xcode",
        "com.hnc.Discord",
        "com.tinyspeck.slackmacgap"
    ]
}
