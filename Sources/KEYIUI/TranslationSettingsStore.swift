import Foundation
import OSLog
import KEYICore
import KEYITranslationClient
import KEYITranslationService

enum TranslationSettingsError: LocalizedError {
    case unsupportedProvider
    case invalidEndpoint
    case missingAPIKey
    case missingModel

    var errorDescription: String? {
        let strings = InterfaceStrings.current
        return switch self {
        case .unsupportedProvider: strings.unsupportedProvider
        case .invalidEndpoint: strings.invalidEndpoint
        case .missingAPIKey: strings.missingAPIKey
        case .missingModel: strings.missingModel
        }
    }
}

@MainActor
final class TranslationSettingsStore {
    private let defaults: UserDefaults
    private let preferencesKey = "translation.preferences"

    private(set) var preferences: TranslationPreferences

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.preferences = Self.decodePreferences(from: defaults, key: preferencesKey)

        if let storedLanguage = defaults.string(
            forKey: InterfaceLanguageStorage.key
        ), let language = InterfaceLanguage(rawValue: storedLanguage) {
            preferences.interfaceLanguage = language
        } else {
            defaults.set(
                preferences.interfaceLanguage.rawValue,
                forKey: InterfaceLanguageStorage.key
            )
        }

        if !TranslationProviderCatalog.descriptor(
            for: preferences.providerID
        ).isAvailable {
            let language = preferences.interfaceLanguage
            preferences = TranslationPreferences(interfaceLanguage: language)
            persistPreferences()
        }
        migrateLegacyVolcengineConfigurationIfNeeded()
        migrateLegacyLocalModelIfNeeded()
    }

    /// 无副作用地重新读取已保存配置；复用 init 的存储键与解码规则。
    ///
    /// 子进程与父进程共用同一 UserDefaults domain；`synchronize()` 仅是显式
    /// 请求落盘值，真正保证跨进程可见的是这里每次读取磁盘最新值。
    func reloadPreferences() {
        defaults.synchronize()
        var reloaded = Self.decodePreferences(
            from: defaults,
            key: preferencesKey
        )
        if let storedLanguage = defaults.string(
            forKey: InterfaceLanguageStorage.key
        ), let language = InterfaceLanguage(rawValue: storedLanguage) {
            reloaded.interfaceLanguage = language
        }
        preferences = reloaded
    }

    private static func decodePreferences(
        from defaults: UserDefaults,
        key: String
    ) -> TranslationPreferences {
        guard let data = defaults.data(forKey: key),
              let stored = try? JSONDecoder().decode(
                  TranslationPreferences.self,
                  from: data
              ) else {
            return TranslationPreferences()
        }
        return stored
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

    func selectInterfaceLanguage(_ language: InterfaceLanguage) {
        preferences.interfaceLanguage = language
        defaults.set(language.rawValue, forKey: InterfaceLanguageStorage.key)
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
        let stored = defaults.string(forKey: endpointKey(for: providerID))
            ?? profile.defaultEndpoint
        if providerID == .volcengine {
            return VolcengineChatCompletionsMigration.migratedEndpoint(stored)
        }
        return stored
    }

    func model(for providerID: TranslationProviderID) -> String? {
        guard let profile = APITranslationProviderCatalog.profile(for: providerID) else {
            return nil
        }
        let stored = defaults.string(forKey: modelKey(for: providerID))
            ?? profile.defaultModel
        if providerID == .volcengine {
            return VolcengineChatCompletionsMigration.migratedModel(stored)
        }
        return stored
    }

    /// 当前翻译风格。旧版用户第一次读取时，按原来的「翻译方式/场景/英语风格」推出最接近的一种并存下。
    func translationStyle() -> KEYITranslationStyle {
        if let stored = defaults.string(forKey: KEYITranslationStyle.storageKey)
            .flatMap(KEYITranslationStyle.init(rawValue:)) {
            return stored
        }
        let migrated = TranslationStyleRouting.migratedStyle(from: preferences)
        defaults.set(migrated.rawValue, forKey: KEYITranslationStyle.storageKey)
        return migrated
    }

    func selectTranslationStyle(_ style: KEYITranslationStyle) {
        defaults.set(style.rawValue, forKey: KEYITranslationStyle.storageKey)
    }

    /// 写给输入法菜单看的「风格 → 引擎名」。
    func storeEngineLabels(_ labels: [KEYITranslationStyle: String]) {
        let raw = Dictionary(uniqueKeysWithValues: labels.map { ($0.key.rawValue, $0.value) })
        defaults.set(raw, forKey: KEYITranslationStyle.engineLabelsKey)
    }

    func storedEngineLabels() -> [String: String] {
        defaults.dictionary(forKey: KEYITranslationStyle.engineLabelsKey) as? [String: String] ?? [:]
    }

    /// 云端风格用的服务：上次选用的那家已配置就用它，否则按清单顺序取第一个已配置的。
    func preferredCloudProvider(
        isConfigured: (TranslationProviderID) -> Bool
    ) -> TranslationProviderID? {
        if preferences.providerID.requiresAPIConfiguration, isConfigured(preferences.providerID) {
            return preferences.providerID
        }
        return APITranslationProviderCatalog.profiles.map(\.providerID).first(where: isConfigured)
    }

    func isAPIConfigured(_ providerID: TranslationProviderID) -> Bool {
        hasStoredAPIConfiguration(for: providerID) && hasAPIKey(for: providerID)
    }

    /// 本地模型通道用哪一档 Hy-MT2；用户还没选过时为 nil。
    func localModelTier() -> LocalTranslationModelTier? {
        defaults.string(forKey: localModelTierKey).flatMap(LocalTranslationModelTier.init(rawValue:))
    }

    func selectLocalModelTier(_ tier: LocalTranslationModelTier) {
        defaults.set(tier.rawValue, forKey: localModelTierKey)
    }

    /// 旧版 LM Studio 配置被迁移后、用户还没看过提示时为 true。
    var hasLocalModelMigrationNotice: Bool {
        defaults.bool(forKey: localModelMigrationNoticeKey)
    }

    func clearLocalModelMigrationNotice() {
        defaults.removeObject(forKey: localModelMigrationNoticeKey)
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

    private func migrateLegacyVolcengineConfigurationIfNeeded() {
        let storedEndpoint = defaults.string(forKey: endpointKey(for: .volcengine))
        let storedModel = defaults.string(forKey: modelKey(for: .volcengine))
        let endpoint = VolcengineChatCompletionsMigration.migratedEndpoint(storedEndpoint)
        let model = VolcengineChatCompletionsMigration.migratedModel(storedModel)
        if let storedEndpoint, endpoint != storedEndpoint {
            defaults.set(endpoint, forKey: endpointKey(for: .volcengine))
        }
        if let storedModel, model != storedModel {
            defaults.set(model, forKey: modelKey(for: .volcengine))
        }
    }

    /// 本地模型通道不再连 LM Studio：删掉旧的地址和模型名；正在用它翻译的改回苹果系统翻译，并留一次提示。
    private func migrateLegacyLocalModelIfNeeded() {
        for key in Self.legacyLocalModelKeys {
            defaults.removeObject(forKey: key)
        }
        guard preferences.providerID == .localModel, localModelTier() == nil else { return }
        preferences.providerID = .appleSystem
        persistPreferences()
        defaults.set(true, forKey: localModelMigrationNoticeKey)
    }

    private static let legacyLocalModelKeys = [
        "translation.local.endpoint",
        "translation.local.gemma4.model"
    ]

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

    private let localModelTierKey = "translation.local.tier"
    private let localModelMigrationNoticeKey = "translation.local.migrationNotice"
}
