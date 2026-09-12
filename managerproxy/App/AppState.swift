//
//  AppState.swift
//  ProxyPilot
//
//  The single source of truth. Owns the service layer, derives UI state and
//  orchestrates the restart-with-proxy flow.
//

import AppKit
import Combine
import Foundation
import ServiceManagement
import SwiftUI

// MARK: - Prompt models

struct RestartPrompt: Identifiable {
    let id = UUID()
    var app: ManagedApplication
    var reason: String
    var isForceQuitStep: Bool = false
    var forcesQuit: Bool = false
}

/// Shown when an app that the user asked ProxyPilot to proxy gets started by
/// something else (Dock, Finder, `open`), so it is running without the proxy.
struct ExternalLaunchPrompt: Identifiable {
    let id = UUID()
    var app: ManagedApplication
}

struct MasterOffNotice: Identifiable {
    let id = UUID()
    var runningAppNames: [String]

    /// One translatable sentence, so word order stays under the translator's control.
    var summary: String {
        let names = runningAppNames.joined(separator: Localized.string(", "))
        return runningAppNames.count == 1
            ? Localized.format("%@ is still running. Restart required to remove proxy settings.", names)
            : Localized.format("%@ are still running. Restart required to remove proxy settings.", names)
    }
}

// MARK: - AppState

@MainActor
final class AppState: ObservableObject {

    // MARK: Services

    let persistence: PersistenceService
    let keychain: KeychainService
    let log: LogStore
    let scanner: AppScanner
    let processManager: ProcessManager
    let launcher: LauncherEngine
    let tester: ProxyTester
    /// Phase 2 control plane: system extension activation, proxy configuration
    /// and rule-file sync.
    let transparent: TransparentProxyController

    // MARK: Persisted state

    @Published var applications: [ManagedApplication] = []
    @Published var proxies: [ProxyProfile] = []
    @Published var settings: AppSettings = AppSettings()
    /// Phase 1 only persists the model — see ProxyRule.swift.
    @Published var rules: [ProxyRule] = []

    // MARK: Runtime state

    @Published var selection: SidebarSelection? = .applications

    @Published var health: [UUID: ProxyHealth] = [:]
    @Published var testingProxyIDs: Set<UUID> = []
    @Published var launchRecords: [UUID: LaunchRecord] = [:]

    @Published var discoveredApplications: [DiscoveredApplication] = []
    @Published var isScanning = false
    @Published var lastScanDate: Date?

    @Published var selectedApplicationID: UUID?
    @Published var isInspectorPresented = false

    @Published var isBusy = false
    @Published var busyMessage: String?

    @Published var alert: ErrorPresentation?
    @Published var restartPrompt: RestartPrompt?
    @Published var masterOffNotice: MasterOffNotice?
    @Published var externalLaunchPrompt: ExternalLaunchPrompt?
    @Published var toast: String?

    /// Bumped whenever an app launches or terminates so views re-render.
    @Published private(set) var runningRevision: Int = 0

    private var hasBootstrapped = false
    private var workspaceObservers: [NSObjectProtocol] = []
    /// Apps already prompted about an external launch, so the same event is not
    /// raised twice in one session.
    private var promptedExternalLaunchAppIDs: Set<UUID> = []

    // MARK: Init

    init(
        persistence: PersistenceService = PersistenceService(),
        keychain: KeychainService = KeychainService(),
        scanner: AppScanner = AppScanner()
    ) {
        self.persistence = persistence
        self.keychain = keychain
        self.scanner = scanner
        self.log = LogStore(persistence: persistence)
        self.processManager = ProcessManager(log: log)
        self.launcher = LauncherEngine(log: log)
        self.tester = ProxyTester()
        self.transparent = TransparentProxyController(log: log)

        loadPersistedState()
        observeWorkspace()
    }

    deinit {
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    // MARK: Persistence

    private func loadPersistedState() {
        applications = persistence.loadApplications()
        proxies = persistence.loadProxies()
        settings = persistence.loadSettings() ?? AppSettings()
        rules = persistence.loadRules()
        launchRecords = Dictionary(
            persistence.loadLaunchRecords().map { ($0.appID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for profile in proxies {
            let account = KeychainService.account(for: profile.id)
            if profile.passwordKeychainID == nil, keychain.hasPassword(for: account) {
                if let index = proxies.firstIndex(where: { $0.id == profile.id }) {
                    proxies[index].passwordKeychainID = account
                }
            }
        }
    }

    private func persistApplications() {
        persistence.saveApplications(applications)
    }

    private func persistProxies() {
        persistence.saveProxies(proxies)
    }

    func persistSettings() {
        persistence.saveSettings(settings)
    }

    private func persistLaunchRecords() {
        persistence.saveLaunchRecords(Array(launchRecords.values))
    }

    // MARK: Bootstrap

    func bootstrap() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true

        log.info("ProxyPilot \(appVersion) starting", category: .app, detail: [
            ("Applications", String(applications.count)),
            ("Proxies", String(proxies.count)),
            ("Support directory", persistence.directory.path)
        ])

        if applications.isEmpty {
            seedFirstRun()
        }

        applyAppearance()
        await refreshDiscoveredApplications()
        await testAllProxies()
        refreshRunningState()

        // Phase 2: restore the transparent proxy state. setEnabled(true)
        // activates the extension (idempotent) and then saves & enables the
        // NETransparentProxyManager configuration; refreshStatus first picks
        // up any configuration saved from a previous run.
        syncTransparentRules()
        transparent.refreshStatus()
        if settings.transparentProxyEnabled {
            transparent.setEnabled(true)
        }
    }

    var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    // MARK: First run seeding

    private func seedFirstRun() {
        // Both seeded profiles point at the same port on purpose: Clash-style
        // "mixed" ports speak HTTP and SOCKS5 at once, so the protocol is a choice
        // rather than a different address.
        let defaults = [
            ProxyProfile(name: "FlClash", type: .http,
                         host: ProxyProfile.defaultHost, port: ProxyProfile.defaultPort),
            ProxyProfile(name: "Local SOCKS", type: .socks5,
                         host: ProxyProfile.defaultHost, port: ProxyProfile.defaultPort)
        ]
        proxies = defaults
        persistProxies()
        settings.defaultProxyProfileID = defaults.first?.id
        persistSettings()

        log.info("Seeded default proxy profiles", category: .persistence, detail: [
            ("Profiles", defaults.map(\.name).joined(separator: ", "))
        ])
    }

    /// Adds well-known apps that are present on disk. Only ever called on first run,
    /// and never enables proxying by itself.
    private func seedSuggestedApplications(from discovered: [DiscoveredApplication]) {
        guard applications.isEmpty else { return }
        let byBundleID = Dictionary(discovered.map { ($0.bundleIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        let defaultProxyID = settings.defaultProxyProfileID ?? proxies.first?.id

        for bundleID in KnownApplications.firstRunSuggestions {
            guard let match = byBundleID[bundleID] else { continue }
            let isDirectRuntime = match.bundleIdentifier == "com.apple.dt.Xcode"
            var app = makeManagedApplication(from: match)
            app.proxyProfileID = isDirectRuntime ? ProxyProfile.directID : defaultProxyID
            app.enabled = false
            app.launchStrategy = .auto
            applications.append(app)
        }

        if !applications.isEmpty {
            persistApplications()
            log.info("Added \(applications.count) suggested applications", category: .appScanner)
        }
    }

    private func makeManagedApplication(from discovered: DiscoveredApplication) -> ManagedApplication {
        ManagedApplication(
            name: discovered.name,
            bundleIdentifier: discovered.bundleIdentifier,
            bundlePath: discovered.bundlePath,
            executablePath: discovered.executablePath,
            enabled: false,
            proxyProfileID: settings.defaultProxyProfileID,
            launchStrategy: .auto,
            bypassDomains: settings.normalizedBypassList,
            runtime: discovered.runtime,
            version: discovered.version
        )
    }

    // MARK: Workspace observation

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification
        ]
        let box = WeakBox(self)

        for name in names {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { notification in
                guard let runningApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                    return
                }
                // Extract plain values so the async hop never captures AppKit objects.
                let bundleIdentifier = runningApp.bundleIdentifier ?? ""
                let path = runningApp.bundleURL?.path ?? ""
                let isRunning = !runningApp.isTerminated

                Task { @MainActor in
                    box.value?.handleWorkspaceChange(bundleIdentifier: bundleIdentifier, path: path, isRunning: isRunning)
                }
            }
            workspaceObservers.append(observer)
        }
    }

    private func handleWorkspaceChange(bundleIdentifier: String, path: String, isRunning: Bool) {
        runningRevision &+= 1
        let affected = applications.filter {
            $0.bundleIdentifier == bundleIdentifier
                || (bundleIdentifier.isEmpty && !path.isEmpty && $0.bundlePath == path)
        }
        for app in affected {
            log.debug("Process state changed", category: .process, detail: [
                ("App", app.name),
                ("Running", isRunning ? "yes" : "no")
            ])
        }

        guard isRunning else {
            // Forget the prompt for this session so the next external start is
            // reported again rather than silently ignored.
            for app in affected { promptedExternalLaunchAppIDs.remove(app.id) }
            return
        }

        // The user asked for this app to be proxied but started it from somewhere
        // else, so it is running un-proxied. Say so instead of letting the status
        // column be the only hint.
        if let app = affected.first(where: { shouldPromptAboutExternalLaunch($0) }) {
            promptedExternalLaunchAppIDs.insert(app.id)
            externalLaunchPrompt = ExternalLaunchPrompt(app: app)
            log.warning("Detected an external launch of a proxied app", category: .process, detail: [
                ("App", app.name),
                ("Proxy", proxySubtitleForDisplay(app))
            ])
        }
    }

    /// `true` when the user asked for a proxy on this app, it is running, and the
    /// running instance did not come from ProxyPilot.
    private func shouldPromptAboutExternalLaunch(_ app: ManagedApplication) -> Bool {
        guard promptedExternalLaunchAppIDs.contains(app.id) == false else { return false }
        guard app.enabled, settings.masterEnabled else { return false }
        guard let profile = proxy(for: app), !profile.isDirect, app.launchStrategy != .direct else { return false }
        return needsRestart(app)
    }

    func refreshRunningState() {
        runningRevision &+= 1
    }

    /// Reading `runningRevision` inside this method is intentional: it makes SwiftUI
    /// treat every `isRunning` call as dependent on process-state changes.
    func isRunning(_ app: ManagedApplication) -> Bool {
        _ = runningRevision
        return processManager.isRunning(app)
    }

    // MARK: Application lookup

    func application(withID id: UUID) -> ManagedApplication? {
        applications.first { $0.id == id }
    }

    func proxy(withID id: UUID?) -> ProxyProfile? {
        guard let id else { return nil }
        if id == ProxyProfile.directID { return .direct }
        return proxies.first { $0.id == id }
    }

    func proxy(for app: ManagedApplication) -> ProxyProfile? {
        proxy(withID: app.proxyProfileID)
    }

    /// Built-in DIRECT first, then user profiles.
    var allProxies: [ProxyProfile] {
        [ProxyProfile.direct] + proxies
    }

    var selectableProxies: [ProxyProfile] {
        [ProxyProfile.direct] + proxies.filter(\.enabled)
    }

    var defaultProxy: ProxyProfile? {
        proxy(withID: settings.defaultProxyProfileID)
    }

    // MARK: Status derivation

    func status(for app: ManagedApplication) -> AppProxyStatus {
        if app.proxyProfileID != nil, proxy(for: app) == nil {
            return .configurationMissing
        }

        // Direct means "no proxy" — either no profile assigned, an explicit DIRECT
        // profile, or an explicit DIRECT launch strategy.
        let isDirect = app.proxyProfileID == nil
            || proxy(for: app)?.isDirect == true
            || app.launchStrategy == .direct

        if isDirect { return .direct }
        guard app.enabled, settings.masterEnabled else { return .disabled }

        if let profile = proxy(for: app), let health = health[profile.id], health.hasBeenTested, !health.isReachable {
            return .proxyUnavailable
        }
        if needsRestart(app) { return .restartRequired }
        return .active
    }

    /// True when the app is running with a configuration that no longer matches.
    func needsRestart(_ app: ManagedApplication) -> Bool {
        guard isRunning(app) else { return false }
        guard app.enabled, settings.masterEnabled else { return false }
        guard let profile = proxy(for: app), !profile.isDirect else { return false }

        let signature = LaunchPlanBuilder.proxySignature(for: profile)
        guard let record = launchRecords[app.id],
              record.signature == signature,
              record.executablePath == app.executablePath else {
            return true
        }
        // If the process started noticeably later than our record, the user relaunched
        // the app by hand — it is no longer running under our proxy.
        if let launched = processManager.earliestLaunchDate(for: app),
           launched.timeIntervalSince(record.date) > 3 {
            return true
        }
        return false
    }

    var managedRunningApplications: [ManagedApplication] {
        applications.filter { isRunning($0) }
    }

    func proxyForDisplay(_ app: ManagedApplication) -> String {
        guard let profile = proxy(for: app) else { return "Direct" }
        return profile.displayName
    }

    func proxySubtitleForDisplay(_ app: ManagedApplication) -> String {
        guard let profile = proxy(for: app) else { return "No proxy" }
        return profile.subtitle
    }

    // MARK: Scanning

    func refreshDiscoveredApplications() async {
        isScanning = true
        let result = await Task.detached(priority: .userInitiated) { [scanner] in
            scanner.scan()
        }.value
        discoveredApplications = result
        lastScanDate = Date()
        isScanning = false

        log.info("Scanned \(result.count) applications", category: .appScanner, detail: [
            ("Locations", AppScanner.defaultSearchPaths.map(\.path).joined(separator: ", "))
        ])

        if applications.isEmpty {
            seedSuggestedApplications(from: result)
        }
    }

    // MARK: Application management

    @discardableResult
    func add(discovered list: [DiscoveredApplication]) -> Int {
        var added = 0
        for discovered in list {
            if applications.contains(where: { $0.bundlePath == discovered.bundlePath }) { continue }
            var app = makeManagedApplication(from: discovered)
            app.enabled = false
            app.proxyProfileID = settings.defaultProxyProfileID ?? proxies.first?.id
            applications.append(app)
            added += 1
        }
        if added > 0 {
            persistApplications()
            syncTransparentRules()
            log.info("Added \(added) application(s)", category: .appScanner, detail: [
                ("Total", String(applications.count))
            ])
        }
        return added
    }

    func remove(_ app: ManagedApplication) {
        if isRunning(app) {
            _ = processManager.forceTerminate(app)
        }
        applications.removeAll { $0.id == app.id }
        launchRecords.removeValue(forKey: app.id)
        persistApplications()
        persistLaunchRecords()
        syncTransparentRules()
        if selectedApplicationID == app.id {
            selectedApplicationID = nil
            isInspectorPresented = false
        }
        log.info("Removed \(app.name)", category: .app)
    }

    func update(_ app: ManagedApplication, mutate: (inout ManagedApplication) -> Void) {
        guard let index = applications.firstIndex(where: { $0.id == app.id }) else { return }
        mutate(&applications[index])
        applications[index].updatedAt = Date()
        persistApplications()
        syncTransparentRules()
    }

    func assignProxy(_ proxyID: UUID?, to app: ManagedApplication) {
        update(app) { target in
            target.proxyProfileID = proxyID
            if proxyID == nil || proxyID == ProxyProfile.directID {
                target.enabled = false
            }
        }
    }

    func addBypassDomain(_ domain: String, to app: ManagedApplication) {
        let trimmed = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(app) { target in
            guard !target.bypassDomains.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
            target.bypassDomains.append(trimmed)
        }
    }

    func removeBypassDomains(at offsets: IndexSet, from app: ManagedApplication) {
        update(app) { target in
            target.bypassDomains.remove(atOffsets: offsets)
        }
    }

    func resetBypassList(for app: ManagedApplication) {
        update(app) { $0.bypassDomains = AppSettings.defaultBypassList }
    }

    // MARK: Enable / disable

    func setEnabled(_ app: ManagedApplication, enabled: Bool) async {
        guard let current = application(withID: app.id) else { return }
        let isDirect = current.proxyProfileID == nil
            || proxy(for: current)?.isDirect == true
            || current.launchStrategy == .direct
        guard !isDirect else {
            // DIRECT apps have nothing to enable.
            return
        }
        guard current.enabled != enabled else { return }

        update(current) { $0.enabled = enabled }

        guard enabled else {
            log.info("Disabled proxying for \(current.name)", category: .app)
            return
        }

        log.info("Enabled proxying for \(current.name)", category: .app, detail: [
            ("Proxy", proxySubtitleForDisplay(current))
        ])

        guard isRunning(current) else {
            // Nothing is restarted and nothing is proxied yet: the settings only
            // take effect when ProxyPilot itself starts the app.
            toast = Localized.format("%@ proxy enabled — applies when ProxyPilot launches it.", current.name)
            return
        }

        if settings.confirmBeforeRestartingApps {
            restartPrompt = RestartPrompt(
                app: current,
                reason: Localized.string("Proxy settings require restarting the application.")
            )
        } else {
            await restart(current, allowForceQuit: true)
        }
    }

    func toggleEnabled(_ app: ManagedApplication) async {
        await setEnabled(app, enabled: !app.enabled)
    }

    // MARK: Restart / launch

    func requestRestart(_ app: ManagedApplication) {
        guard let current = application(withID: app.id) else { return }
        if settings.confirmBeforeRestartingApps, isRunning(current) {
            restartPrompt = RestartPrompt(
                app: current,
                reason: Localized.string("Proxy settings require restarting the application.")
            )
        } else {
            Task { await restart(current, allowForceQuit: true) }
        }
    }

    /// Terminate (if needed) then launch with the current configuration.
    func restart(_ app: ManagedApplication, allowForceQuit: Bool) async {
        guard let current = application(withID: app.id) else { return }
        isBusy = true
        busyMessage = "Restarting \(current.name)…"
        defer {
            isBusy = false
            busyMessage = nil
        }

        if isRunning(current) {
            let terminated = await processManager.terminate(current)
            if !terminated {
                if allowForceQuit {
                    // Force quit always requires a second explicit confirmation.
                    restartPrompt = RestartPrompt(
                        app: current,
                        reason: Localized.format("%@ did not quit. Force quitting may discard unsaved work.", current.name),
                        isForceQuitStep: true,
                        forcesQuit: true
                    )
                } else {
                    alert = ErrorPresentation(error: .terminationFailed(name: current.name))
                }
                refreshRunningState()
                return
            }
        }
        refreshRunningState()
        await launch(current)
    }

    func forceQuitAndRestart(_ app: ManagedApplication) async {
        guard let current = application(withID: app.id) else { return }
        processManager.forceTerminate(current)
        refreshRunningState()
        try? await Task.sleep(nanoseconds: 400_000_000)
        await launch(current)
    }

    /// Launches the app once, applying the current proxy configuration.
    func launch(_ app: ManagedApplication) async {
        guard let current = application(withID: app.id) else { return }

        if !settings.masterEnabled {
            alert = ErrorPresentation(error: .masterSwitchDisabled)
            return
        }

        isBusy = true
        busyMessage = "Launching \(current.name)…"
        defer {
            isBusy = false
            busyMessage = nil
        }

        do {
            // An explicit DIRECT strategy always wins over an assigned profile.
            let resolvedProxy: ProxyProfile? = current.launchStrategy == .direct ? nil : proxy(for: current)

            let plan = try launcher.plan(for: current, proxy: resolvedProxy)
            let recordDate = Date()
            _ = try await launcher.launch(plan)

            launchRecords[current.id] = LaunchRecord(
                appID: current.id,
                proxyProfileID: plan.proxyProfileID,
                signature: plan.proxySignature,
                strategy: plan.strategy,
                arguments: plan.arguments,
                environmentKeys: plan.proxyEnvironment.filter { !$0.value.isEmpty }.map(\.key).sorted(),
                date: recordDate,
                executablePath: current.executablePath
            )
            persistLaunchRecords()
            refreshRunningState()
            toast = plan.usesProxy
                ? Localized.format("%@ launched with proxy", current.name)
                : Localized.format("%@ launched", current.name)
        } catch let error as ProxyPilotError {
            alert = ErrorPresentation(error: error)
            log.error(error.errorDescription ?? "Launch failed", category: .launcher)
        } catch {
            alert = ErrorPresentation(error: .launchFailed(name: current.name, reason: error.localizedDescription))
        }
    }

    /// Builds the plan without launching — used by "Show Launch Command".
    func previewPlan(for app: ManagedApplication) -> LaunchPlan? {
        let resolvedProxy = app.launchStrategy == .direct ? nil : proxy(for: app)
        return try? launcher.plan(for: app, proxy: resolvedProxy)
    }

    func revealInFinder(_ app: ManagedApplication) {
        NSWorkspace.shared.activateFileViewerSelecting([app.bundleURL])
    }

    // MARK: Bulk actions

    func enableAll() async {
        for app in applications {
            let isDirect = app.proxyProfileID == nil || proxy(for: app)?.isDirect == true || app.launchStrategy == .direct
            guard !isDirect, !app.enabled else { continue }
            await setEnabled(app, enabled: true)
        }
    }

    func disableAll() async {
        for app in applications where app.enabled {
            await setEnabled(app, enabled: false)
        }
    }

    // MARK: Master switch

    func setMasterEnabled(_ enabled: Bool) async {
        // Guard against redundant writes. SwiftUI may write a control's binding back
        // during layout; an unconditional mutation would re-invalidate the graph and
        // spin the main thread forever.
        guard settings.masterEnabled != enabled else { return }

        settings.masterEnabled = enabled
        persistSettings()
        log.info("Master switch \(enabled ? "ON" : "OFF")", category: .app)
        syncTransparentRules()

        guard !enabled else {
            masterOffNotice = nil
            return
        }

        let running = applications.filter { $0.enabled && isRunning($0) }
        masterOffNotice = running.isEmpty ? nil : MasterOffNotice(runningAppNames: running.map(\.name))
    }

    /// Restarts every managed app so the proxy settings are removed.
    func restartManagedApplications() async {
        let running = applications.filter { $0.enabled && isRunning($0) }
        masterOffNotice = nil
        for app in running {
            await restart(app, allowForceQuit: false)
        }
    }

    func dismissMasterOffNotice() {
        masterOffNotice = nil
    }

    // MARK: Transparent proxy (Phase 2)

    /// Master switch for the transparent proxy. Enabling it activates the
    /// system extension (idempotent) and enables the proxy configuration.
    /// Rules are synced from the per-app `usesTransparentProxy` flags.
    func setTransparentProxyEnabled(_ enabled: Bool) {
        guard settings.transparentProxyEnabled != enabled else {
            // Still (re)sync: an app may have been toggled before first enable.
            syncTransparentRules()
            return
        }
        settings.transparentProxyEnabled = enabled
        persistSettings()
        log.info("Transparent proxy master \(enabled ? "ON" : "OFF")", category: .app)

        if enabled {
            transparent.activateExtensionIfNeeded()
            transparent.setEnabled(true)
        } else {
            transparent.setEnabled(false)
        }
        syncTransparentRules()
    }

    /// Per-app opt-in for transparent proxying.
    func setTransparentProxyEnabled(_ enabled: Bool, for app: ManagedApplication) {
        update(app) { $0.usesTransparentProxy = enabled }
    }

    /// Writes the current per-app assignments for the extension.
    func syncTransparentRules() {
        transparent.syncRules(
            applications: applications,
            proxies: proxies,
            keychain: keychain
        )
    }

    // MARK: Proxy CRUD

    func addProxy(name: String, type: ProxyType, host: String, port: Int, username: String?, password: String?) throws {
        var profile = ProxyProfile(name: name, type: type, host: host, port: port, username: username)
        if let error = profile.validationError { throw error }

        if let password, !password.isEmpty {
            let account = KeychainService.account(for: profile.id)
            try keychain.setPassword(password, for: account)
            profile.passwordKeychainID = account
        }

        proxies.append(profile)
        persistProxies()
        if settings.defaultProxyProfileID == nil {
            settings.defaultProxyProfileID = profile.id
            persistSettings()
        }
        log.info("Created proxy profile", category: .proxy, detail: [
            ("Name", profile.name),
            ("Type", profile.type.displayName),
            ("Address", profile.displayAddress),
            ("Username", profile.username ?? "—")
        ])
        syncTransparentRules()
    }

    func updateProxy(_ updated: ProxyProfile, password: String?) throws {
        guard let index = proxies.firstIndex(where: { $0.id == updated.id }) else { return }
        var profile = updated
        if let error = profile.validationError { throw error }

        if let password {
            let account = KeychainService.account(for: profile.id)
            if password.isEmpty {
                keychain.deletePassword(for: account)
                profile.passwordKeychainID = nil
            } else {
                try keychain.setPassword(password, for: account)
                profile.passwordKeychainID = account
            }
        }

        let addressChanged = proxies[index].host != profile.host
            || proxies[index].port != profile.port
            || proxies[index].type != profile.type
        proxies[index] = profile
        persistProxies()

        if addressChanged {
            // The cached health result no longer describes this endpoint.
            health.removeValue(forKey: profile.id)
        }

        log.info("Updated proxy profile", category: .proxy, detail: [
            ("Name", profile.name),
            ("Address", profile.displayAddress)
        ])
        syncTransparentRules()
    }

    func deleteProxy(_ profile: ProxyProfile) {
        guard !profile.isBuiltIn else { return }
        keychain.deletePassword(for: KeychainService.account(for: profile.id))
        proxies.removeAll { $0.id == profile.id }
        health.removeValue(forKey: profile.id)

        for index in applications.indices where applications[index].proxyProfileID == profile.id {
            applications[index].proxyProfileID = ProxyProfile.directID
            applications[index].enabled = false
        }
        if settings.defaultProxyProfileID == profile.id {
            settings.defaultProxyProfileID = proxies.first?.id
        }

        persistProxies()
        persistApplications()
        persistSettings()
        log.info("Deleted proxy profile", category: .proxy, detail: [("Name", profile.name)])
        syncTransparentRules()
    }

    func password(for profile: ProxyProfile) -> String? {
        let account = profile.passwordKeychainID ?? KeychainService.account(for: profile.id)
        return keychain.password(for: account)
    }

    // MARK: Proxy testing

    @discardableResult
    func testProxy(_ profile: ProxyProfile) async -> ProxyHealth {
        testingProxyIDs.insert(profile.id)
        defer { testingProxyIDs.remove(profile.id) }

        log.info("Testing proxy", category: .proxy, detail: [
            ("Name", profile.name),
            ("Address", profile.displayAddress),
            ("Test URL", settings.resolvedTestURL.absoluteString)
        ])

        let result = await tester.testWithFallbacks(profile: profile, primaryURL: settings.resolvedTestURL)
        let updated = result.asHealth()
        health[profile.id] = updated

        let detail: [(String, String)] = [
            ("Reachable", updated.isReachable ? "yes" : "no"),
            ("TCP", updated.tcpLatencyMs.map { "\(Int($0)) ms" } ?? "—"),
            ("HTTP", updated.httpLatencyMs.map { "\(Int($0)) ms" } ?? "—"),
            ("Status", updated.statusCode.map(String.init) ?? "—"),
            ("Reason", updated.failureReason ?? "—")
        ]
        if updated.isReachable, updated.statusCode != nil {
            log.success("Proxy available", category: .proxy, detail: detail)
        } else if updated.isReachable {
            log.warning("Proxy reachable but the HTTP probe failed", category: .proxy, detail: detail)
        } else {
            log.error("Proxy unavailable", category: .proxy, detail: detail)
        }
        return updated
    }

    func testAllProxies() async {
        for profile in proxies where profile.enabled {
            await testProxy(profile)
        }
    }

    func health(for profile: ProxyProfile) -> ProxyHealth {
        health[profile.id] ?? .unknown()
    }

    // MARK: Settings helpers

    func setLaunchAtLogin(_ enabled: Bool) {
        guard settings.launchAtLogin != enabled else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            settings.launchAtLogin = enabled
        } catch {
            settings.launchAtLogin = SMAppService.mainApp.status == .enabled
            alert = ErrorPresentation(
                title: Localized.string("Launch at login could not be changed."),
                suggestion: Localized.format("ProxyPilot must be in /Applications and signed for login items to work. (%@)", error.localizedDescription)
            )
        }
        persistSettings()
    }

    func setShowMenuBarIcon(_ enabled: Bool) {
        // Bound to MenuBarExtra(isInserted:) — must be idempotent.
        guard settings.showMenuBarIcon != enabled else { return }
        settings.showMenuBarIcon = enabled
        persistSettings()
    }

    func setAppearance(_ appearance: AppAppearance) {
        guard settings.appearance != appearance else { return }
        settings.appearance = appearance
        persistSettings()
        applyAppearance()
    }

    /// Applies the user's appearance preference. `system` leaves AppKit in charge,
    /// which is the default and the native behaviour.
    func applyAppearance() {
        switch settings.appearance {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func setDefaultProxy(_ id: UUID?) {
        guard settings.defaultProxyProfileID != id else { return }
        settings.defaultProxyProfileID = id
        persistSettings()
    }

    func clearLogs() {
        log.clear()
    }
}
