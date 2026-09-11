//
//  SharedKeychain.swift
//  ProxyPilot
//
//  Keychain access for proxy credentials shared between the app and the
//  transparent-proxy system extension, via the app-group keychain access group.
//  The app mirrors credentials here when rules change; the extension reads the
//  password from here when it relays a flow. The secret never touches disk.
//

import Foundation
import Security

enum SharedKeychain {

    /// `TEAMID.group.proxypilot` — the keychain access group that the App
    /// Group capability grants to both the app and the extension.
    static var accessGroup: String {
        "\(teamIdentifierPrefix)\(TransparentProxyConstants.appGroupID)"
    }

    private static func teamIdentifierPrefix() -> String {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                task, "com.apple.developer.team-identifier" as CFString, nil),
              let team = value as? String, !team.isEmpty else {
            return ""
        }
        return team + "."
    }

    // MARK: Read (used by the extension)

    static func password(for account: String) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: TransparentProxyConstants.keychainService,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: Write (used by the app to mirror credentials)

    @discardableResult
    static func setPassword(_ password: String, for account: String) -> Bool {
        guard let data = password.data(using: .utf8) else { return false }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: TransparentProxyConstants.keychainService,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }
}
