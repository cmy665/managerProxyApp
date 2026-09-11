//
//  KeychainService.swift
//  ProxyPilot
//
//  Proxy passwords live in the macOS Keychain. They are never written to JSON,
//  UserDefaults or the log.
//

import Foundation
import Security

final class KeychainService {

    private let service: String

    init(service: String = "com.proxypilot.mac.credentials") {
        self.service = service
    }

    /// Stable account key for a proxy profile.
    static func account(for proxyID: UUID) -> String {
        "proxy.\(proxyID.uuidString)"
    }

    // MARK: Errors

    enum KeychainError: LocalizedError {
        case unexpectedStatus(OSStatus)
        case dataConversion

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
                return message
            case .dataConversion:
                return "The stored credential could not be decoded."
            }
        }
    }

    // MARK: Read

    func password(for account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func hasPassword(for account: String) -> Bool {
        password(for: account) != nil
    }

    // MARK: Write

    @discardableResult
    func setPassword(_ password: String, for account: String) throws -> Bool {
        guard let data = password.data(using: .utf8) else { throw KeychainError.dataConversion }

        let query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }

        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(updateStatus)
        }

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        return true
    }

    // MARK: Delete

    @discardableResult
    func deletePassword(for account: String) -> Bool {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Removes every credential ProxyPilot owns.
    @discardableResult
    func deleteAll() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: Private

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
