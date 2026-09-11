//
//  AppLaunching.swift
//  ProxyPilot
//

import Foundation

/// A strategy that knows how to turn a `ManagedApplication` + `ProxyProfile`
/// into a concrete `LaunchPlan`.
protocol AppLaunching {
    /// The strategy this launcher implements.
    var strategy: LaunchStrategy { get }

    /// Short name shown in Diagnostics.
    var displayName: String { get }

    /// `true` when this launcher is responsible for the given app.
    func canHandle(_ app: ManagedApplication) -> Bool

    /// Builds the plan. Throws `ProxyPilotError` when the app cannot be launched.
    func makePlan(app: ManagedApplication, proxy: ProxyProfile?) throws -> LaunchPlan
}

// MARK: - Shared validation

extension AppLaunching {

    /// Rejects apps that are missing from disk or have no usable executable.
    func validate(_ app: ManagedApplication) throws {
        guard app.existsOnDisk() else {
            throw ProxyPilotError.appNotFound(name: app.name)
        }
        if app.executablePath.isEmpty || !FileManager.default.isExecutableFile(atPath: app.executablePath) {
            throw ProxyPilotError.executableNotFound(path: app.executablePath)
        }
    }
}
