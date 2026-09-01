import Foundation
import Security

struct KeychainStore: Sendable {
    private static let service = "no.aagedal.AagedalFTPSync.credentials"
    private let passwordReader: @Sendable (String) throws -> String?
    private let passwordWriter: @Sendable (String, String) throws -> Void
    private let passwordRemover: @Sendable (String) throws -> Void

    init() {
        passwordReader = KeychainStore.readPassword
        passwordWriter = KeychainStore.writePassword
        passwordRemover = KeychainStore.deletePassword
    }

    init(
        passwordReader: @escaping @Sendable (String) throws -> String?,
        passwordWriter: @escaping @Sendable (String, String) throws -> Void,
        passwordRemover: @escaping @Sendable (String) throws -> Void
    ) {
        self.passwordReader = passwordReader
        self.passwordWriter = passwordWriter
        self.passwordRemover = passwordRemover
    }

    func password(for credentialID: String) throws -> String? {
        try passwordReader(credentialID)
    }

    func setPassword(_ password: String, for credentialID: String) throws {
        try passwordWriter(password, credentialID)
    }

    func removePassword(for credentialID: String) throws {
        try passwordRemover(credentialID)
    }

    private static func readPassword(for credentialID: String) throws -> String? {
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

    private static func writePassword(_ password: String, for credentialID: String) throws {
        let key: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credentialID
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(password.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        var status = SecItemUpdate(key as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(key.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw AppError.transferFailed("Could not save the password in Keychain (\(status)).")
        }
    }

    private static func deletePassword(for credentialID: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credentialID
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppError.transferFailed("Could not remove the password from Keychain (\(status)).")
        }
    }
}
