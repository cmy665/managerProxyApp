//
//  LauncherEngine.swift
//  ProxyPilot
//
//  The heart of the MVP. Picks a strategy, builds the plan, then starts the app.
//
//  Launching goes through LaunchServices (NSWorkspace) because that produces a
//  properly registered GUI process with our arguments and environment. Foundation's
//  Process is the fallback for bundles LaunchServices refuses to open.
//

import AppKit
import Foundation

@MainActor
final class LauncherEngine {

    private let log: LogStore
    private let launchers: [AppLaunching]

    init(log: LogStore, launchers: [AppLaunching]? = nil) {
        self.log = log
        self.launchers = launchers ?? [DirectLauncher(), ChromiumLauncher(), EnvironmentLauncher()]
    }

    // MARK: Strategy selection

    func launcher(for app: ManagedApplication) -> AppLaunching? {
        launchers.first { $0.canHandle(app) }
    }

    func strategyDescription(for app: ManagedApplication) -> String {
        guard let launcher = launcher(for: app) else { return "Unsupported" }
        return "\(launcher.displayName) · \(app.effectiveStrategy.displayName)"
    }

    /// Builds the plan without launching — used for the "Show Launch Command" preview.
    func plan(for app: ManagedApplication, proxy: ProxyProfile?) throws -> LaunchPlan {
        guard let launcher = launcher(for: app) else {
            throw ProxyPilotError.unsupportedLaunchStrategy(strategy: app.launchStrategy.displayName)
        }
        return try launcher.makePlan(app: app, proxy: proxy)
    }

    // MARK: Launching

    @discardableResult
    func launch(_ plan: LaunchPlan) async throws -> LaunchMethod {
        let bundleURL = URL(fileURLWithPath: plan.bundlePath)

        if FileManager.default.fileExists(atPath: bundleURL.path) {
            do {
                _ = try await openWithLaunchServices(bundleURL: bundleURL, plan: plan)
                logLaunch(plan: plan, method: .workspace, success: true)
                return .workspace
            } catch {
                log.warning("LaunchServices could not open the bundle — falling back to Process", category: .launcher, detail: [
                    ("App", plan.appName),
                    ("Reason", error.localizedDescription)
                ])
            }
        }

        do {
            try runWithProcess(plan: plan)
            logLaunch(plan: plan, method: .process, success: true)
            return .process
        } catch {
            logLaunch(plan: plan, method: .process, success: false)
            throw ProxyPilotError.launchFailed(name: plan.appName, reason: error.localizedDescription)
        }
    }

    // MARK: LaunchServices

    private func openWithLaunchServices(bundleURL: URL, plan: LaunchPlan) async throws -> NSRunningApplication {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NSRunningApplication, Error>) in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.arguments = plan.arguments
            configuration.environment = plan.environment
            // The restart flow terminates the app first, so LaunchServices will start a
            // genuine new process that honours our arguments.
            configuration.createsNewApplicationInstance = false
            configuration.activates = true

            NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { application, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let application {
                    continuation.resume(returning: application)
                } else {
                    continuation.resume(
                        throwing: ProxyPilotError.launchFailed(
                            name: plan.appName,
                            reason: "LaunchServices returned no application instance."
                        )
                    )
                }
            }
        }
    }

    // MARK: Foundation.Process fallback

    private func runWithProcess(plan: LaunchPlan) throws {
        let executableURL = URL(fileURLWithPath: plan.executablePath)
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ProxyPilotError.executableNotFound(path: plan.executablePath)
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = plan.arguments
        process.environment = plan.environment
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        // Detach the child from ProxyPilot's process group so quitting ProxyPilot
        // never affects the launched app.
        process.qualityOfService = .userInitiated

        try process.run()
    }

    // MARK: Logging

    private func logLaunch(plan: LaunchPlan, method: LaunchMethod, success: Bool) {
        var detail: [(String, String)] = [
            ("Executable", plan.executablePath),
            ("Strategy", plan.strategy.displayName),
            ("Launch method", method.displayName),
            ("Proxy", plan.usesProxy ? plan.proxySignature : "DIRECT"),
            ("Result", success ? "Success" : "Failure")
        ]
        if !plan.arguments.isEmpty {
            detail.append(("Arguments", plan.arguments.joined(separator: " ")))
        }
        let environmentSummary = LaunchPlanBuilder.managedEnvironmentKeys
            .sorted()
            .compactMap { key -> String? in
                guard let value = plan.proxyEnvironment[key], !value.isEmpty else { return nil }
                return "\(key)=\(value)"
            }
            .joined(separator: " ")
        if !environmentSummary.isEmpty {
            detail.append(("Environment", environmentSummary))
        }

        log.log(
            success ? "Launched \(plan.appName)" : "Failed to launch \(plan.appName)",
            category: .launcher,
            level: success ? .success : .error,
            detail: detail
        )
    }
}
