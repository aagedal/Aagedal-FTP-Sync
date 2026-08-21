import Foundation
import Security

struct KeychainStore: Sendable {
    private let service = "no.aagedal.AagedalFTPSync.credentials"

    func password(for credentialID: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credentialID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = item as? Data,
              let password = String(data: data, encoding: .utf8) else {
            throw AppError.transferFailed("Could not read the password from Keychain (\(status)).")
        }
        return password
    }

    func setPassword(_ password: String, for credentialID: String) throws {
        let key: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credentialID
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(password.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status: OSStatus
        if SecItemCopyMatching(key as CFDictionary, nil) == errSecSuccess {
            status = SecItemUpdate(key as CFDictionary, attributes as CFDictionary)
        } else {
            status = SecItemAdd(key.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw AppError.transferFailed("Could not save the password in Keychain (\(status)).")
        }
    }

    func removePassword(for credentialID: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credentialID
        ]
        SecItemDelete(query as CFDictionary)
    }
}
