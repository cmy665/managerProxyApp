//
//  TransparentProxyController.swift
//  ProxyPilot
//
//  App-side control plane for Phase 2 (transparent proxy):
//
//    1. Activate the ProxyPilotTransparentProxy system extension.
//    2. Configure and enable a NETransparentProxyManager pointing at it.
//    3. Mirror the current per-app proxy assignments into
//       `transparent-rules.json` in the app-group container so the extension
//       can decide, per flow, whether to proxy or pass through.
//
//  The extension itself performs the interception; this class only owns the
//  lifecycle and the rule file.
//

import AppKit
import Combine
import Foundation
import NetworkExtension
import SystemExtensions

@MainActor
final class TransparentProxyController: NSObject, ObservableObject {

    enum State: Equatable {
        /// Extension activation has not been attempted yet.
        case unknown
        /// Activation request submitted, awaiting user approval in System Settings.
        case activating
        /// Extension is active and the proxy configuration is enabled.
        case active
        /// Extension is active but the proxy configuration is disabled.
        case disabled
        /// Something failed; the message is user-presentable.
        case failed(String)
    }

    @Published private(set) var state: State = .unknown
    /// Count of apps currently routed through the transparent proxy.
    @Published private(set) var routedAppCount: Int = 0

    private let log: LogStore
    private var pendingEnable: Bool?
    private var activationInFlight = false

    init(log: LogStore) {
        self.log = log
        super.init()
    }

    // MARK: - Activation

    /// Submits a system-extension activation request. Idempotent: when the
    /// extension is already active the system completes the request quickly.
    func activateExtensionIfNeeded() {
        guard !activationInFlight else { return }
        activationInFlight = true
        state = .activating

        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: TransparentProxyConstants.extensionBundleID,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    // MARK: - Enable / disable

    /// Enables or disables the transparent proxy. If the extension is not yet
    /// activated, activation is triggered first and the request is applied once
    /// activation completes.
    func setEnabled(_ enabled: Bool, completion: ((Error?) -> Void)? = nil) {
        pendingEnable = enabled
        switch state {
        case .active, .disabled:
            applyEnabled(enabled, completion: completion)
        case .unknown, .failed:
            // Extension is not active yet — submit the activation request;
            // the delegate applies pendingEnable once activation finishes.
            activateExtensionIfNeeded()
        case .activating:
            // The activation delegate applies pendingEnable when it finishes.
            break
        }
    }

    private func applyEnabled(_ enabled: Bool, completion: ((Error?) -> Void)? = nil) {
        let manager = NETransparentProxyManager()
        manager.localizedDescription = "ProxyPilot Transparent Proxy"

        let protocolConfiguration = NETunnelProviderProtocol()
        protocolConfiguration.providerBundleIdentifier = TransparentProxyConstants.extensionBundleID
        protocolConfiguration.serverAddress = "127.0.0.1"
        protocolConfiguration.providerConfiguration = ["app": "ProxyPilot"]
        manager.protocolConfiguration = protocolConfiguration
        manager.isEnabled = enabled

        manager.saveToPreferences { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.state = .failed(error.localizedDescription)
                    self.log.error("Failed to \(enabled ? "enable" : "disable") transparent proxy: \(error.localizedDescription)", category: .app)
                } else {
                    self.state = enabled ? .active : .disabled
                    self.log.info("Transparent proxy \(enabled ? "enabled" : "disabled")", category: .app, detail: [
                        ("Routed apps", String(self.routedAppCount))
                    ])
                }
                completion?(error)
            }
        }
    }

    // MARK: - Rules

    /// Writes the current per-app assignments into the app-group container and
    /// notifies the extension. Credentials are mirrored into the shared
    /// keychain access group; the JSON only carries the account key.
    func syncRules(applications: [ManagedApplication], proxies: [ProxyProfile], keychain: KeychainService) {
        var rules: [TransparentRule] = []
        var routedCount = 0

        for app in applications where app.enabled && app.usesTransparentProxy {
            guard let profile = proxies.first(where: { $0.id == app.proxyProfileID }),
                  !profile.isDirect, profile.isValid else { continue }
            guard !app.bundleIdentifier.isEmpty else { continue }

            if let account = profile.passwordKeychainID, let password = keychain.password(for: account) {
                // Make the credential visible to the extension through the
                // shared keychain access group.
                SharedKeychain.setPassword(password, for: account)
            }

            rules.append(TransparentRule(
                bundleID: app.bundleIdentifier,
                proxyType: profile.type.rawValue,
                host: profile.host,
                port: profile.port,
                username: profile.username,
                passwordAccount: profile.passwordKeychainID
            ))
            routedCount += 1
        }

        routedAppCount = routedCount

        do {
            try TransparentRuleStore.write(TransparentRulesFile(rules: rules))
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name(TransparentProxyConstants.rulesChangedNotification),
                object: nil
            )
            log.info("Synced transparent proxy rules", category: .app, detail: [
                ("Routed apps", String(routedCount)),
                ("File", TransparentRuleStore.rulesURL()?.path ?? "—")
            ])
        } catch {
            log.error("Failed to sync transparent proxy rules: \(error.localizedDescription)", category: .app)
        }
    }

    // MARK: - Status

    func refreshStatus() {
        NETransparentProxyManager.loadAllFromPreferences { [weak self] managers, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.log.warning("Could not load transparent proxy configuration: \(error.localizedDescription)", category: .app)
                }
                guard let manager = managers?.first else {
                    self.state = .unknown
                    return
                }
                self.state = manager.isEnabled ? .active : .disabled
            }
        }
    }
}

// MARK: - OSSystemExtensionRequestDelegate

extension TransparentProxyController: OSSystemExtensionRequestDelegate {

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        activationInFlight = false
        state = .failed(error.localizedDescription)
        log.error("System extension activation failed: \(error.localizedDescription)", category: .app)
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        activationInFlight = false
        log.info("System extension activation finished (result \(result.rawValue))", category: .app)
        if let pending = pendingEnable {
            pendingEnable = nil
            applyEnabled(pending)
        } else {
            refreshStatus()
        }
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        // The user must approve the extension in System Settings before the
        // activation completes. macOS surfaces the "Allow" button in the
        // Privacy & Security pane — open it automatically so the user does
        // not have to hunt for it.
        log.info("System extension activation needs user approval", category: .app)
        state = .activating
        openSystemSettingsForExtensionApproval()
    }

    /// Opens System Settings → Privacy & Security, where macOS shows the
    /// "Allow" button for a pending system-extension activation.
    private func openSystemSettingsForExtensionApproval() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        // Always replace an older build of the extension.
        .replace
    }
}
