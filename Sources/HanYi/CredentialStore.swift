import Foundation

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
    private static let directoryName = "HanYi/Credentials-v1"
    private static let allowedAccountCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
    )

    static func read(account: String) throws -> String? {
        let url = try credentialURL(account: account, createDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: url)
            guard let value = String(data: data, encoding: .utf8) else {
                throw CredentialStoreError.unreadableCredential
            }
            return value
        } catch let error as CredentialStoreError {
            throw error
        } catch {
            throw CredentialStoreError.unreadableCredential
        }
    }

    static func save(_ value: String, account: String) throws {
        let destination = try credentialURL(account: account, createDirectory: true)
        let temporary = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).tmp", isDirectory: false)
        let data = Data(value.utf8)
        let fileManager = FileManager.default

        guard fileManager.createFile(
            atPath: temporary.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CredentialStoreError.writeFailed
        }

        do {
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(
                    destination,
                    withItemAt: temporary
                )
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: destination.path
            )
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw CredentialStoreError.writeFailed
        }
    }

    private static func credentialURL(
        account: String,
        createDirectory: Bool
    ) throws -> URL {
        guard !account.isEmpty,
              account.unicodeScalars.allSatisfy({
                  allowedAccountCharacters.contains($0)
              }) else {
            throw CredentialStoreError.invalidAccount
        }

        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let directory = base.appendingPathComponent(
            directoryName,
            isDirectory: true
        )

        if createDirectory {
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: directory.path
                )
            } catch {
                throw CredentialStoreError.writeFailed
            }
        }

        return directory.appendingPathComponent(
            "\(account).secret",
            isDirectory: false
        )
    }
}
