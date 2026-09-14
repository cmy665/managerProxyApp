//
//  TransparentProxyProvider.swift
//  ProxyPilotTransparentProxy
//
//  The system extension that makes Phase 2 real: every outbound TCP and UDP
//  flow is delivered here, and we decide per process — via the app's bundle
//  identifier — whether to relay it through the app's assigned upstream proxy
//  or to let the system deliver it directly (returning false).
//
//  Design notes
//  ------------
//  - TCP is relayed via SOCKS5 CONNECT / HTTP CONNECT. Original hostnames are
//    recovered from TLS SNI / HTTP Host headers because the system has already
//    resolved DNS by the time a TCP flow arrives.
//  - UDP (including DNS on port 53) is relayed via SOCKS5 UDP ASSOCIATE.
//    HTTP CONNECT proxies cannot carry UDP, so those flows fall back to direct.
//  - Rules live in `transparent-rules.json`. The file is reloaded when it
//    changes; a distributed notification makes the reload immediate.
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

    /// Active TCP relays. Guarded by `queue`.
    private var relays: [UUID: TCPRelay] = [:]
    /// Active UDP relays. Guarded by `queue`.
    private var udpRelays: [UUID: UDPRelay] = [:]

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
        // All outbound TCP and UDP except loopback. A nil remote/local network
        // matches everything of the given protocol and direction, excluding
        // loopback — so the upstream proxy at 127.0.0.1 keeps working.
        let tcpRule = NENetworkRule(
            remoteNetwork: nil,
            remotePrefix: 0,
            localNetwork: nil,
            localPrefix: 0,
            protocol: .TCP,
            direction: .outbound
        )
        let udpRule = NENetworkRule(
            remoteNetwork: nil,
            remotePrefix: 0,
            localNetwork: nil,
            localPrefix: 0,
            protocol: .UDP,
            direction: .outbound
        )
        settings.includedNetworkRules = [tcpRule, udpRule]

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { return }
            if let error {
                self.logger.error("applySettings failed: \(error.localizedDescription, privacy: .public)")
            } else {
                self.logger.info("Network settings applied — intercepting outbound TCP + UDP")
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
            for relay in udpRelays.values { relay.close() }
            udpRelays.removeAll()
        }
        completionHandler()
    }

    // MARK: - Flow handling

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        let bundleID = flow.metaData.sourceAppSigningIdentifier ?? ""
        guard let rule = rule(for: bundleID) else {
            return false // direct
        }

        if let tcpFlow = flow as? NEAppProxyTCPFlow {
            return handleTCPFlow(tcpFlow, rule: rule, bundleID: bundleID)
        }

        if let udpFlow = flow as? NEAppProxyUDPFlow {
            // Only SOCKS5 can relay UDP. HTTP CONNECT proxies get a direct flow.
            guard rule.proxyType == TransparentProxyConstants.schemeSOCKS5 else {
                logger.info("UDP direct (proxy type \(rule.proxyType, privacy: .public) does not support UDP): \(bundleID, privacy: .public)")
                return false
            }
            return handleUDPFlow(udpFlow, rule: rule, bundleID: bundleID)
        }

        return false
    }

    private func handleTCPFlow(_ flow: NEAppProxyTCPFlow, rule: TransparentRule, bundleID: String) -> Bool {
        logger.info("Relaying \(bundleID, privacy: .public) via \(rule.proxyType, privacy: .public) \(rule.host, privacy: .public):\(rule.port, privacy: .public)")
        let relay = TCPRelay(
            flow: flow,
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

    private func handleUDPFlow(_ flow: NEAppProxyUDPFlow, rule: TransparentRule, bundleID: String) -> Bool {
        logger.info("Intercepting UDP \(bundleID, privacy: .public) via socks5 \(rule.host, privacy: .public):\(rule.port, privacy: .public)")
        let relay = UDPRelay(
            flow: flow,
            rule: rule,
            queue: queue,
            logger: logger,
            passwordProvider: { account in
                account.map { SharedKeychain.password(for: $0) } ?? nil
            }
        )
        queue.sync {
            udpRelays[relay.id] = relay
        }
        relay.onFinish = { [weak self] id in
            self?.queue.async {
                self?.udpRelays.removeValue(forKey: id)
            }
        }
        relay.start()
        return true
    }

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
