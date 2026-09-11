//
//  DirectLauncher.swift
//  ProxyPilot
//
//  Launches the app with no proxy configuration at all. Used by the explicit
//  DIRECT mode (and later by the rule engine). Proxy variables are explicitly
//  cleared so the app cannot inherit them from ProxyPilot's environment.
//

import Foundation

struct DirectLauncher: AppLaunching {

    let strategy: LaunchStrategy = .direct
    let displayName = "DirectLauncher"

    func canHandle(_ app: ManagedApplication) -> Bool {
        app.effectiveStrategy == .direct
    }

    func makePlan(app: ManagedApplication, proxy: ProxyProfile?) throws -> LaunchPlan {
        try validate(app)
        // DIRECT must never receive proxy settings, even if one happens to be assigned.
        return LaunchPlanBuilder.makePlan(app: app, proxy: nil, strategy: .direct)
    }
}
