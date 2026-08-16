import Foundation
import Security

enum CredentialStoreError: LocalizedError {
    case invalidAccount
    case unreadableCredential
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .invalidAccount:
            "凭据名称无效"
        case .unreadableCredential:
            "API Key 无法读取，请在“添加/管理模型 API”中重新保存一次"
        case .writeFailed:
            "API Key 保存失败"
        }
    }
}

enum CredentialStore {
    private static let keychainService = "com.hanyi.credentials"

    // 旧版本把 Key 明文存在应用私有目录；读取到即迁入钥匙串并删除明文文件。
    private static let legacyDirectoryName = "HanYi/Credentials-v1"

    private static let allowedAccountCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
    )

    static func read(account: String) throws -> String? {
        try validateAccount(account)
        if let value = readFromKeychain(account: account) {
            return value
        }

        guard let value = try readLegacyCredential(account: account) else {
            return nil
        }
        do {
            try saveToKeychain(value, account: account)
            removeLegacyCredential(account: account)
        } catch {
            // 迁移失败不影响本次读取；明文文件保留，下次读取会重试迁移。
        }
        return value
    }

    static func save(_ value: String, account: String) throws {
        try validateAccount(account)
        do {
            try saveToKeychain(value, account: account)
        } catch {
            throw CredentialStoreError.writeFailed
        }
        removeLegacyCredential(account: account)
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

    private static func legacyCredentialURL(account: String) -> URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(legacyDirectoryName, isDirectory: true)
            .appendingPathComponent("\(account).secret", isDirectory: false)
    }

    private static func readLegacyCredential(account: String) throws -> String? {
        guard let url = legacyCredentialURL(account: account),
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        guard let data = try? Data(contentsOf: url),
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            throw CredentialStoreError.unreadableCredential
        }
        return value
    }

    private static func removeLegacyCredential(account: String) {
        if let url = legacyCredentialURL(account: account) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
