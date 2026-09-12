//
//  TransparentProxyProvider.swift
//  ProxyPilotTransparentProxy
//
//  The system extension that makes Phase 2 real: every outbound TCP flow is
//  delivered here, and we decide per process — via the app's bundle identifier
//  — whether to relay it through the app's assigned upstream proxy or to let
//  the system deliver it directly (returning false).
//
//  Design notes
//  ------------
//  - Only outbound TCP is intercepted (UDP and DNS stay on the system path).
//    The included network rule below is a wildcard, so loopback traffic is
//    excluded automatically and the upstream proxy at 127.0.0.1 keeps working.
//  - Rules live in `transparent-rules.json` in the app-group container. The
//    file is reloaded when it changes; a distributed notification makes the
//    reload immediate.
//  - Credentials are read from the shared keychain at relay time, never cached
//    in memory for longer than a handshake and never written to disk.
//

import Network
import NetworkExtension
import os

final class TransparentProxyProvider: NETransparentProxyProvider {

    private let queue = DispatchQueue(label: "com.proxypilot.transparentproxy.flows")
    private let logger = Logger(
        subsystem: "com.proxypilot.mac.TransparentProxy",
        category: "provider"
    )

    /// bundleID → rule. Guarded by `queue`.
    private var rulesByBundleID: [String: TransparentRule] = [:]
    private var rulesModificationDate: Date?

    /// Absolute path to the rules file, passed by the app via
    /// protocolConfiguration.providerConfiguration. The extension runs as root
    /// and cannot rely on containerURL() (which resolves to /var/root/…).
    private var rulesFilePath: String?

    /// Active relays. Guarded by `queue`.
    private var relays: [UUID: TCPRelay] = [:]

    private var rulesObserver: NSObjectProtocol?

    deinit {
        if let rulesObserver {
            DistributedNotificationCenter.default().removeObserver(rulesObserver)
        }
    }

    // MARK: - Lifecycle

    override func startProxy(options: [String: Any]?, completionHandler: @escaping (Error?) -> Void) {
        logger.info("startProxy")

        // Extract the rules file path passed by the app. The extension runs
        // as root, so containerURL() would resolve to /var/root/… and miss
        // the user-level file the app writes.
        if let proto = protocolConfiguration as? NETunnelProviderProtocol,
           let path = proto.providerConfiguration?[TransparentProxyConstants.rulesPathKey] as? String,
           !path.isEmpty {
            rulesFilePath = path
            logger.info("Rules path from providerConfiguration: \(path, privacy: .public)")
        } else {
            logger.error("No rules path in providerConfiguration — will try app-group container as fallback")
        }

        reloadRules()

        // Observe rule changes posted by the app.
        rulesObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(TransparentProxyConstants.rulesChangedNotification),
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.reloadRules()
        }

        let settings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        // All outbound TCP except loopback. A nil remote/local network matches
        // everything of the given protocol and direction, excluding loopback.
        let tcpRule = NENetworkRule(
            remoteNetwork: nil,
            remotePrefix: 0,
            localNetwork: nil,
            localPrefix: 0,
            protocol: .TCP,
            direction: .outbound
        )
        settings.includedNetworkRules = [tcpRule]

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { return }
            if let error {
                self.logger.error("applySettings failed: \(error.localizedDescription, privacy: .public)")
            } else {
                self.logger.info("Network settings applied — intercepting outbound TCP")
            }
            completionHandler(error)
        }
    }

    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        logger.info("stopProxy reason=\(reason.rawValue, privacy: .public)")
        if let rulesObserver {
            DistributedNotificationCenter.default().removeObserver(rulesObserver)
            self.rulesObserver = nil
        }
        queue.sync {
            for relay in relays.values { relay.close() }
            relays.removeAll()
        }
        completionHandler()
    }

    // MARK: - Flow handling

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        // The provider contract delivers flows as the base class; only TCP
        // flows are intercepted (UDP goes through handleNewUDPFlow below).
        guard let tcpFlow = flow as? NEAppProxyTCPFlow else {
            logger.info("Direct (non-TCP flow)")
            return false
        }
        let bundleID = tcpFlow.metaData.sourceAppSigningIdentifier ?? ""
        guard let rule = rule(for: bundleID) else {
            logger.info("Direct (no rule): \(bundleID, privacy: .public)")
            return false
        }

        logger.info("Relaying \(bundleID, privacy: .public) via \(rule.proxyType, privacy: .public) \(rule.host, privacy: .public):\(rule.port, privacy: .public)")
        let relay = TCPRelay(
            flow: tcpFlow,
            rule: rule,
            queue: queue,
            logger: logger,
            passwordProvider: { account in
                account.map { SharedKeychain.password(for: $0) } ?? nil
            }
        )
        queue.sync {
            relays[relay.id] = relay
        }
        relay.onFinish = { [weak self] id in
            self?.queue.async {
                self?.relays.removeValue(forKey: id)
            }
        }
        relay.start()
        return true
    }

    // `handleNewUDPFlow` is intentionally not overridden: the base-class
    // default forwards UDP flows to `handleNewFlow(_:)`, which returns false
    // for non-TCP flows, so UDP (including DNS) is delivered directly by the
    // system — same behaviour as the documented Phase-1 limitation.

    // MARK: - Rules

    private func rule(for bundleID: String) -> TransparentRule? {
        reloadRulesIfChanged()
        guard !bundleID.isEmpty else { return nil }
        return rulesByBundleID[bundleID]
    }

    private func reloadRulesIfChanged() {
        let date: Date?
        if let path = rulesFilePath {
            date = TransparentRuleStore.modificationDate(atPath: path)
        } else {
            date = TransparentRuleStore.modificationDate()
        }
        guard date != rulesModificationDate else { return }
        reloadRules()
    }

    private func reloadRules() {
        // Prefer the absolute path passed by the app; fall back to the
        // app-group container (which only works when the extension runs as
        // the same user as the app).
        let loaded: (TransparentRulesFile, Date?)?
        if let path = rulesFilePath {
            let exists = FileManager.default.fileExists(atPath: path)
            logger.info("reloadRules: path=\(path, privacy: .public) exists=\(exists)")
            loaded = TransparentRuleStore.load(fromPath: path)
        } else if let url = TransparentRuleStore.rulesURL() {
            logger.info("reloadRules: fallback container path=\(url.path, privacy: .public)")
            loaded = TransparentRuleStore.load()
        } else {
            logger.error("reloadRules: no rules path available")
            loaded = nil
        }

        guard let (file, date) = loaded else {
            logger.error("reloadRules: load() returned nil")
            queue.sync { rulesByBundleID = [:] }
            rulesModificationDate = nil
            return
        }
        var byBundle: [String: TransparentRule] = [:]
        byBundle.reserveCapacity(file.rules.count)
        for rule in file.rules where !rule.bundleID.isEmpty {
            byBundle[rule.bundleID] = rule
        }
        queue.sync { rulesByBundleID = byBundle }
        rulesModificationDate = date
        logger.info("Loaded \(file.rules.count, privacy: .public) rules")
    }
}
