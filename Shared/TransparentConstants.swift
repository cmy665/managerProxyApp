//
//  TransparentConstants.swift
//  ProxyPilot
//
//  Constants shared between the ProxyPilot app and its transparent-proxy
//  system extension. Both targets compile this file, so nothing here may
//  depend on app-only or extension-only types.
//

import Foundation

enum TransparentProxyConstants {
    /// App Group shared by the app and the extension. The app writes
    /// `transparent-rules.json` into its container; the extension reads it.
    static let appGroupID = "group.proxypilot"

    /// The system extension's bundle identifier. The app uses it to activate
    /// the extension and to point NETransparentProxyManager at its provider.
    static let extensionBundleID = "com.proxypilot.mac.TransparentProxy"

    /// Unique name for the provider's XPC service. The prefix must match the
    /// app group, exactly like a keychain access group.
    static let machServiceName = "group.proxypilot.transparentproxy"

    /// Rule file name inside the app-group container.
    static let rulesFileName = "transparent-rules.json"

    /// Distributed notification the app posts after writing new rules.
    static let rulesChangedNotification = "com.proxypilot.transparent-rules-changed"

    /// Key in NETunnelProviderProtocol.providerConfiguration carrying the
    /// absolute path to the rules file. The system extension runs as root and
    /// therefore resolves the app-group container to /var/root/…, so the app
    /// passes its own (user-level) absolute path explicitly.
    static let rulesPathKey = "rulesFilePath"

    /// Keychain service used for proxy credentials shared with the extension.
    static let keychainService = "com.proxypilot.mac.credentials"

    /// Scheme strings stored in the rule file.
    static let schemeHTTP = "http"
    static let schemeHTTPS = "https"
    static let schemeSOCKS5 = "socks5"
}
