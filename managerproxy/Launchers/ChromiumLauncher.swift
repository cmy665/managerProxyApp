//
//  ChromiumLauncher.swift
//  ProxyPilot
//
//  Handles Chromium / Electron apps (Codex, Cursor, VS Code, Chrome, Brave, Edge…).
//
//      /Applications/Codex.app/Contents/MacOS/Codex \
//          --proxy-server=http://127.0.0.1:7890 \
//          --proxy-bypass-list=localhost;127.0.0.1;::1
//
//  The executable is read from CFBundleExecutable — never hard-coded.
//

import Foundation

struct ChromiumLauncher: AppLaunching {

    let strategy: LaunchStrategy = .chromium
    let displayName = "ChromiumLauncher"

    func canHandle(_ app: ManagedApplication) -> Bool {
        switch app.launchStrategy {
        case .chromium: return true
        case .auto:     return app.runtime.supportsChromiumArguments
        case .environment, .direct: return false
        }
    }

    func makePlan(app: ManagedApplication, proxy: ProxyProfile?) throws -> LaunchPlan {
        try validate(app)
        // A DIRECT app routed through this launcher simply gets no proxy arguments.
        return LaunchPlanBuilder.makePlan(app: app, proxy: proxy, strategy: .chromium)
    }
}
