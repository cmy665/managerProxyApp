//
//  EnvironmentLauncher.swift
//  ProxyPilot
//
//  For apps that read conventional proxy environment variables.
//
//      HTTP_PROXY=https_proxy=… ALL_PROXY=… NO_PROXY=localhost,127.0.0.1,::1
//
//  Every variable is set in BOTH upper and lower case, because tools disagree.
//  Both cases are also cleared when the profile is DIRECT so the app never
//  inherits a proxy from ProxyPilot's own environment.
//

import Foundation

struct EnvironmentLauncher: AppLaunching {

    let strategy: LaunchStrategy = .environment
    let displayName = "EnvironmentLauncher"

    func canHandle(_ app: ManagedApplication) -> Bool {
        switch app.launchStrategy {
        case .environment: return true
        case .auto:        return !app.runtime.supportsChromiumArguments
        case .chromium, .direct: return false
        }
    }

    func makePlan(app: ManagedApplication, proxy: ProxyProfile?) throws -> LaunchPlan {
        try validate(app)
        return LaunchPlanBuilder.makePlan(app: app, proxy: proxy, strategy: .environment)
    }
}
