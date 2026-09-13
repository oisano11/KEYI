import Foundation
import Security

enum CredentialStoreError: LocalizedError {
    case invalidAccount
    case writeFailed

    var errorDescription: String? {
        let strings = InterfaceStrings.current
        return switch self {
        case .invalidAccount:
            strings.credentialInvalidAccount
        case .writeFailed:
            strings.credentialWriteFailed
        }
    }
}

enum CredentialStore {
    private static let keychainService = "com.keyi.credentials"

    private static let allowedAccountCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
    )

    static func read(account: String) throws -> String? {
        try validateAccount(account)
        return readFromKeychain(account: account)
    }

    static func save(_ value: String, account: String) throws {
        try validateAccount(account)
        do {
            try saveToKeychain(value, account: account)
        } catch {
            throw CredentialStoreError.writeFailed
        }
    }

    /// 删除指定账户的凭据；条目不存在视为成功。
    static func delete(account: String) throws {
        try validateAccount(account)
        let status = SecItemDelete(keychainQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.writeFailed
        }
    }

    private static func validateAccount(_ account: String) throws {
        guard !account.isEmpty,
              account.unicodeScalars.allSatisfy({
                  allowedAccountCharacters.contains($0)
              }) else {
            throw CredentialStoreError.invalidAccount
        }
    }

    private static func keychainQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
    }

    private static func readFromKeychain(account: String) -> String? {
        var query = keychainQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func saveToKeychain(
        _ value: String,
        account: String
    ) throws {
        let data = Data(value.utf8)
        let updateStatus = SecItemUpdate(
            keychainQuery(account: account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw CredentialStoreError.writeFailed
        }

        var attributes = keychainQuery(account: account)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CredentialStoreError.writeFailed
        }
    }
}
