import Foundation
import OSLog
import KEYICore

struct LocalModelConfiguration: Sendable {
    let endpoint: URL
    let model: String
    let loadKey: String
}

enum TranslationSettingsError: LocalizedError {
    case unsupportedProvider
    case invalidEndpoint
    case invalidLocalEndpoint
    case missingAPIKey
    case missingModel

    var errorDescription: String? {
        switch self {
        case .unsupportedProvider: "当前提供方不支持 API 配置"
        case .invalidEndpoint: "Endpoint 必须是有效的 HTTPS 地址"
        case .invalidLocalEndpoint:
            "本地 Endpoint 必须是 localhost 或 127.0.0.1 的 HTTP 地址"
        case .missingAPIKey: "API Key 不能为空"
        case .missingModel: "模型名不能为空"
        }
    }
}

@MainActor
final class TranslationSettingsStore {
    private let defaults: UserDefaults
    private let preferencesKey = "translation.preferences"
    private let legacyMigrationKey = "translation.migrated-from-hanyi-v1"

    private(set) var preferences: TranslationPreferences

    init(
        defaults: UserDefaults = .standard,
        legacyDefaults: UserDefaults? = UserDefaults(
            suiteName: "com.hanyi.input-translator"
        )
    ) {
        self.defaults = defaults
        self.preferences = TranslationPreferences()
        migrateLegacyValues(from: legacyDefaults)
        if let data = defaults.data(forKey: preferencesKey),
           let stored = try? JSONDecoder().decode(
               TranslationPreferences.self,
               from: data
           ) {
            preferences = stored
        } else {
            preferences = TranslationPreferences()
        }

        if !TranslationProviderCatalog.descriptor(
            for: preferences.providerID
        ).isAvailable {
            preferences = TranslationPreferences()
            persistPreferences()
        }
    }

    private func migrateLegacyValues(from legacyDefaults: UserDefaults?) {
        guard let legacyDefaults,
              legacyDefaults !== defaults,
              defaults.object(forKey: legacyMigrationKey) == nil else {
            return
        }
        defer { defaults.set(true, forKey: legacyMigrationKey) }

        var keys = [preferencesKey, localEndpointKey, localModelKey]
        for providerID in APITranslationProviderCatalog.profiles.map(\.providerID) {
            keys.append(endpointKey(for: providerID))
            keys.append(modelKey(for: providerID))
        }
        for key in keys where defaults.object(forKey: key) == nil {
            if let legacyValue = legacyDefaults.object(forKey: key) {
                defaults.set(legacyValue, forKey: key)
            }
        }
    }

    func select(_ providerID: TranslationProviderID) -> Bool {
        guard TranslationProviderCatalog.descriptor(for: providerID).isAvailable else {
            return false
        }
        preferences.providerID = providerID
        persistPreferences()
        return true
    }

    func selectScene(_ scene: TranslationScene) {
        preferences.scene = scene
        persistPreferences()
    }

    func selectTargetLanguage(_ language: TranslationLanguage) {
        preferences.targetLanguage = language
        persistPreferences()
    }

    func selectEnglishStyle(_ englishStyle: EnglishStyle) {
        preferences.englishStyle = englishStyle
        persistPreferences()
    }

    func hasAPIKey(for providerID: TranslationProviderID) -> Bool {
        guard let account = apiKeyAccount(for: providerID) else { return false }
        do {
            return try CredentialStore.read(account: account)
                .map { !$0.isEmpty } ?? false
        } catch {
            return false
        }
    }

    func hasStoredAPIConfiguration(
        for providerID: TranslationProviderID
    ) -> Bool {
        defaults.string(forKey: endpointKey(for: providerID)) != nil
            && defaults.string(forKey: modelKey(for: providerID)) != nil
    }

    func endpoint(for providerID: TranslationProviderID) -> String? {
        guard let profile = APITranslationProviderCatalog.profile(for: providerID) else {
            return nil
        }
        return defaults.string(forKey: endpointKey(for: providerID))
            ?? profile.defaultEndpoint
    }

    func model(for providerID: TranslationProviderID) -> String? {
        guard let profile = APITranslationProviderCatalog.profile(for: providerID) else {
            return nil
        }
        return defaults.string(forKey: modelKey(for: providerID))
            ?? profile.defaultModel
    }

    func localModelEndpoint() -> String {
        defaults.string(forKey: localEndpointKey)
            ?? LocalModelCatalog.gemma4.defaultEndpoint
    }

    func localModelName() -> String {
        defaults.string(forKey: localModelKey)
            ?? LocalModelCatalog.gemma4.defaultModel
    }

    func saveLocalModelConfiguration(
        endpoint: String,
        model: String
    ) throws {
        guard let url = URL(string: endpoint), isAllowedLocalEndpoint(url) else {
            throw TranslationSettingsError.invalidLocalEndpoint
        }
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedModel.isEmpty else {
            throw TranslationSettingsError.missingModel
        }
        defaults.set(url.absoluteString, forKey: localEndpointKey)
        defaults.set(normalizedModel, forKey: localModelKey)
    }

    func localModelConfiguration() throws -> LocalModelConfiguration {
        guard let endpoint = URL(string: localModelEndpoint()),
              isAllowedLocalEndpoint(endpoint) else {
            throw TranslationSettingsError.invalidLocalEndpoint
        }
        let model = localModelName().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            throw TranslationSettingsError.missingModel
        }
        return LocalModelConfiguration(
            endpoint: endpoint,
            model: model,
            loadKey: LocalModelCatalog.gemma4.defaultLoadKey
        )
    }

    func saveAPIConfiguration(
        for providerID: TranslationProviderID,
        apiKey: String?,
        endpoint: String,
        model: String
    ) throws {
        guard let account = apiKeyAccount(for: providerID),
              APITranslationProviderCatalog.profile(for: providerID) != nil else {
            throw TranslationSettingsError.unsupportedProvider
        }
        guard let url = URL(string: endpoint),
              url.scheme?.lowercased() == "https",
              url.host != nil else {
            throw TranslationSettingsError.invalidEndpoint
        }

        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedModel.isEmpty else {
            throw TranslationSettingsError.missingModel
        }

        if let apiKey {
            let normalizedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalizedKey.isEmpty {
                try CredentialStore.save(normalizedKey, account: account)
            }
        }
        guard hasAPIKey(for: providerID) else {
            throw TranslationSettingsError.missingAPIKey
        }

        defaults.set(url.absoluteString, forKey: endpointKey(for: providerID))
        defaults.set(normalizedModel, forKey: modelKey(for: providerID))
    }

    func apiConfiguration(
        for providerID: TranslationProviderID
    ) async throws -> APIProviderConfiguration {
        guard let account = apiKeyAccount(for: providerID),
              let endpointString = endpoint(for: providerID),
              let endpoint = URL(string: endpointString),
              endpoint.scheme?.lowercased() == "https",
              endpoint.host != nil,
              let model = model(for: providerID),
              !model.isEmpty else {
            throw TranslationSettingsError.invalidEndpoint
        }
        let apiKey = try await Task.detached(priority: .userInitiated) {
            try CredentialStore.read(account: account)
        }.value
        guard let apiKey,
              !apiKey.isEmpty else {
            throw TranslationSettingsError.missingAPIKey
        }
        return APIProviderConfiguration(
            providerID: providerID,
            apiKey: apiKey,
            endpoint: endpoint,
            model: model
        )
    }

    private func persistPreferences() {
        guard let data = try? JSONEncoder().encode(preferences) else {
            Self.logger.error("翻译偏好编码失败，本次更改未写入磁盘")
            return
        }
        defaults.set(data, forKey: preferencesKey)
    }

    private static let logger = Logger(
        subsystem: "com.keyi.input-translator",
        category: "Settings"
    )

    private func apiKeyAccount(
        for providerID: TranslationProviderID
    ) -> String? {
        switch providerID {
        case .deepSeek: "deepseek.api-key"
        case .qwen: "qwen.api-key"
        case .volcengine: "volcengine.api-key"
        case .xAI: "xai.api-key"
        case .relay: "relay.api-key"
        case .appleSystem, .localModel: nil
        }
    }

    private func endpointKey(for providerID: TranslationProviderID) -> String {
        "translation.api.\(providerID.rawValue).endpoint"
    }

    private func modelKey(for providerID: TranslationProviderID) -> String {
        "translation.api.\(providerID.rawValue).model"
    }

    private var localEndpointKey: String {
        "translation.local.endpoint"
    }

    private var localModelKey: String {
        "translation.local.gemma4.model"
    }

    private func isAllowedLocalEndpoint(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else {
            return false
        }
        return host == "localhost"
            || host == "127.0.0.1"
            || host == "::1"
    }
}
