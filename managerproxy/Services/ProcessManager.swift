//
//  ProcessManager.swift
//  ProxyPilot
//
//  Finds, gracefully terminates and (only after an explicit second confirmation)
//  force quits target applications.
//
//  ProxyPilot never calls `kill -9` on its own.
//

import AppKit
import Foundation

@MainActor
final class ProcessManager {

    private let log: LogStore

    init(log: LogStore) {
        self.log = log
    }

    // MARK: Lookup

    func runningApplications(bundleIdentifier: String) -> [NSRunningApplication] {
        guard !bundleIdentifier.isEmpty else { return [] }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
    }

    /// Matches by bundle identifier, falling back to the on-disk bundle path for
    /// apps whose identifier is missing or has changed.
    func runningApplications(for app: ManagedApplication) -> [NSRunningApplication] {
        let byIdentifier = runningApplications(bundleIdentifier: app.bundleIdentifier)
        if !byIdentifier.isEmpty { return byIdentifier }

        let targetPath = (app.bundlePath as NSString).standardizingPath
        return NSWorkspace.shared.runningApplications.filter { candidate in
            guard let url = candidate.bundleURL else { return false }
            return (url.path as NSString).standardizingPath == targetPath
        }
    }

    func primaryRunningApplication(for app: ManagedApplication) -> NSRunningApplication? {
        runningApplications(for: app)
            .sorted { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }
            .first
    }

    func isRunning(_ app: ManagedApplication) -> Bool {
        !runningApplications(for: app).isEmpty
    }

    /// The moment the oldest running instance was started — used to detect that the
    /// user relaunched an app outside of ProxyPilot.
    func earliestLaunchDate(for app: ManagedApplication) -> Date? {
        runningApplications(for: app)
            .compactMap(\.launchDate)
            .min()
    }

    // MARK: Termination

    /// Asks the app to quit and waits for it. Returns `true` when it is gone.
    func terminate(_ app: ManagedApplication, timeout: TimeInterval = 8) async -> Bool {
        let instances = runningApplications(for: app)
        guard !instances.isEmpty else { return true }

        log.info("Requesting graceful termination", category: .process, detail: [
            ("App", app.name),
            ("Bundle ID", app.bundleIdentifier),
            ("Instances", String(instances.count))
        ])

        for instance in instances {
            _ = instance.terminate()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isRunning(app) {
                log.success("Terminated cleanly", category: .process, detail: [("App", app.name)])
                return true
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        log.warning("App did not quit within the timeout", category: .process, detail: [
            ("App", app.name),
            ("Timeout", "\(Int(timeout))s")
        ])
        return !isRunning(app)
    }

    /// Force quit — only reachable behind an explicit second confirmation in the UI.
    @discardableResult
    func forceTerminate(_ app: ManagedApplication) -> Bool {
        let instances = runningApplications(for: app)
        guard !instances.isEmpty else { return true }

        var allSucceeded = true
        for instance in instances {
            let result = instance.forceTerminate()
            if !result { allSucceeded = false }
        }

        log.warning("Force quit requested by the user", category: .process, detail: [
            ("App", app.name),
            ("Result", allSucceeded ? "Success" : "Failed")
        ])
        return allSucceeded
    }

    // MARK: Termination retry loop used by the restart flow

    /// Terminate → wait → force quit (only when allowed). Mirrors PRD §13.
    func terminateForRestart(_ app: ManagedApplication, allowForceQuit: Bool) async -> Bool {
        if await terminate(app) { return true }
        guard allowForceQuit else { return false }
        return forceTerminate(app)
    }
}
