import AppKit
import Combine
import KEYICore
import OSLog
import Translation

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    enum State: Equatable {
        case ready
        case permissionRequired
        case preparing
        case translating
        case success
        case failure(String)

        func title(using strings: InterfaceStrings) -> String {
            switch self {
            case .ready: strings.statusReady
            case .permissionRequired: strings.statusPermissionRequired
            case .preparing: strings.statusPreparing
            case .translating: strings.statusTranslating
            case .success: strings.statusSuccess
            case let .failure(message): message
            }
        }

        var symbolName: String {
            // 菜单栏入口保持稳定的品牌标识；翻译状态由菜单首行与顶部 HUD 表达。
            "bird.fill"
        }

        var isFailure: Bool {
            if case .failure = self { return true }
            return false
        }
    }

    struct TranslationRequest: Sendable {
        let id: UUID
        let sourceText: String
        let contextText: String?
        let providerID: TranslationProviderID
        let targetLanguage: TranslationLanguage
        let scene: TranslationScene
        let englishStyle: EnglishStyle
    }

    enum SettingsSection: Hashable {
        case translation
        case providers(TranslationProviderID?)
        case hotKey
        case general
    }

    @Published private(set) var state: State = .ready
    @Published var translationConfiguration: TranslationSession.Configuration?
    @Published private(set) var selectedProviderID: TranslationProviderID
    @Published private(set) var selectedTargetLanguage: TranslationLanguage
    @Published private(set) var selectedScene: TranslationScene
    @Published private(set) var selectedEnglishStyle: EnglishStyle
    @Published private(set) var interfaceLanguage: InterfaceLanguage
    @Published private(set) var configuredAPIProviderIDs: Set<TranslationProviderID>
    @Published private(set) var hotKeyConfiguration: HotKeyConfiguration
    @Published private(set) var localModelEndpoint: String
    @Published private(set) var localModelName: String
    @Published var settingsSection: SettingsSection = .translation
    private let accessibility = AccessibilityTextClient()
    private let settings: TranslationSettingsStore
    private let hotKeySettings: HotKeySettingsStore
    private let logger = Logger(
        subsystem: "com.keyi.input-translator",
        category: "Translation"
    )
    private var pendingID: UUID?
    private var pendingSnapshot: AccessibilityTextClient.Snapshot?
    private var apiTranslationTask: Task<Void, Never>?
    private var hotKeyRegistrationHandler: ((HotKeyConfiguration) throws -> Void)?

    private init() {
        let settings = TranslationSettingsStore()
        let hotKeySettings = HotKeySettingsStore()
        self.settings = settings
        self.hotKeySettings = hotKeySettings
        self.selectedProviderID = settings.preferences.providerID
        self.selectedTargetLanguage = settings.preferences.targetLanguage
        self.selectedScene = settings.preferences.scene
        self.selectedEnglishStyle = settings.preferences.englishStyle
        self.interfaceLanguage = settings.preferences.interfaceLanguage
        self.hotKeyConfiguration = hotKeySettings.configuration
        self.localModelEndpoint = settings.configuredLocalModelEndpoint() ?? ""
        self.localModelName = settings.configuredLocalModelName() ?? ""
        self.configuredAPIProviderIDs = Set(
            APITranslationProviderCatalog.profiles.compactMap { profile in
                settings.hasStoredAPIConfiguration(for: profile.providerID)
                    && settings.hasAPIKey(for: profile.providerID)
                    ? profile.providerID
                    : nil
            }
        )
    }

    var providerDescriptors: [TranslationProviderDescriptor] {
        TranslationProviderCatalog.descriptors
    }

    var selectedProviderName: String {
        strings.providerName(selectedProviderID)
    }

    var strings: InterfaceStrings {
        InterfaceStrings(language: interfaceLanguage)
    }

    var apiProviderProfiles: [APITranslationProviderProfile] {
        APITranslationProviderCatalog.profiles
    }

    var supportsTranslationCustomization: Bool {
        selectedProviderID != .appleSystem
    }

    var supportsEnglishStyleCustomization: Bool {
        supportsTranslationCustomization
            && TranslationPromptBuilder.usesEnglishStyle(
                language: selectedTargetLanguage,
                scene: selectedScene
            )
    }

    func selectTargetLanguage(_ language: TranslationLanguage) {
        guard language != selectedTargetLanguage else { return }
        settings.selectTargetLanguage(language)
        selectedTargetLanguage = language
        if var configuration = translationConfiguration {
            configuration.invalidate()
            translationConfiguration = nil
        }
    }

    func selectScene(_ scene: TranslationScene) {
        settings.selectScene(scene)
        selectedScene = scene
    }

    func selectEnglishStyle(_ englishStyle: EnglishStyle) {
        settings.selectEnglishStyle(englishStyle)
        selectedEnglishStyle = englishStyle
    }

    func selectInterfaceLanguage(_ language: InterfaceLanguage) {
        guard language != interfaceLanguage else { return }
        settings.selectInterfaceLanguage(language)
        interfaceLanguage = language
    }

    func setHotKeyRegistrationHandler(
        _ handler: @escaping (HotKeyConfiguration) throws -> Void
    ) {
        hotKeyRegistrationHandler = handler
    }

    func configureHotKey() {
        guard let configuration = HotKeyRecorder.record(
            current: hotKeyConfiguration
        ) else { return }
        applyHotKeyConfiguration(configuration)
    }

    func restoreDefaultHotKey() {
        applyHotKeyConfiguration(.default)
    }

    private func applyHotKeyConfiguration(_ configuration: HotKeyConfiguration) {
        guard configuration != hotKeyConfiguration else { return }
        do {
            guard let hotKeyRegistrationHandler else {
                throw GlobalHotKey.Error.handlerRegistrationFailed(-1)
            }
            try hotKeyRegistrationHandler(configuration)
            try hotKeySettings.save(configuration)
            hotKeyConfiguration = configuration
            if state.isFailure { state = .ready }
        } catch {
            showError(error.localizedDescription)
        }
    }

    func isAPIConfigured(_ providerID: TranslationProviderID) -> Bool {
        configuredAPIProviderIDs.contains(providerID)
    }

    /// 设置窗口读取已存配置；Key 永不回读明文。
    func storedEndpoint(for providerID: TranslationProviderID) -> String? {
        settings.endpoint(for: providerID)
    }

    func storedModel(for providerID: TranslationProviderID) -> String? {
        settings.model(for: providerID)
    }

    func selectProvider(_ providerID: TranslationProviderID) {
        if providerID.requiresAPIConfiguration,
           !isAPIConfigured(providerID) {
            openSettings(.providers(providerID))
            return
        }
        guard settings.select(providerID) else { return }
        selectedProviderID = providerID
        if providerID == .appleSystem, state.isFailure {
            state = .ready
        }
    }

    // MARK: 设置窗口

    func openSettings(_ section: SettingsSection = .translation) {
        settingsSection = section
        SettingsWindowController.shared.show()
    }

    /// 保存云端提供方配置；校验失败抛出已本地化的错误。
    func saveProviderConfiguration(
        providerID: TranslationProviderID,
        apiKey: String,
        endpoint: String,
        model: String
    ) throws {
        try settings.saveAPIConfiguration(
            for: providerID,
            apiKey: apiKey,
            endpoint: endpoint,
            model: model
        )
        configuredAPIProviderIDs.insert(providerID)
        if state.isFailure { state = .ready }
    }

    /// 保存本地模型配置；校验失败抛出已本地化的错误。
    func saveLocalModelConfiguration(endpoint: String, model: String) throws {
        try settings.saveLocalModelConfiguration(endpoint: endpoint, model: model)
        localModelEndpoint = settings.localModelEndpoint()
        localModelName = settings.localModelName()
        if state.isFailure { state = .ready }
    }

    var isBusy: Bool {
        state == .preparing || state == .translating
    }

    var hasAccessibilityPermission: Bool {
        accessibility.isTrusted
    }

    func refreshAccessibilityStatus() {
        if !accessibility.isTrusted && !isBusy {
            state = .permissionRequired
        } else if state == .permissionRequired {
            state = .ready
        }
    }

    func requestAccessibilityPermission() {
        accessibility.requestTrustPrompt()
        refreshAccessibilityStatus()
    }

    func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func triggerTranslation() async {
        // 云端中转站可能需要几十秒。处理中重复按快捷键时继续等待当前
        // 请求，避免用户因没有立即看到结果而反复按键、不断取消并重启。
        // 真正失效的请求仍由 URLSession 超时和系统唤醒恢复逻辑清理。
        if isBusy {
            logger.info("Duplicate translation trigger ignored while request is active")
            return
        }
        if selectedProviderID.requiresAPIConfiguration,
           !isAPIConfigured(selectedProviderID) {
            showError(strings.configureProviderFirst(selectedProviderName))
            return
        }
        logger.info("Translation requested; trusted=\(self.accessibility.isTrusted)")

        // 捕获是异步等待目标应用响应的；置为 preparing 让 isBusy 在
        // 等待期间挡住重复触发的快捷键，避免两次捕获交错操作剪贴板。
        state = .preparing
        do {
            let snapshot = try await accessibility.capture()
            logger.info("Focused text captured; utf16Length=\((snapshot.selection.text as NSString).length)")
            let id = UUID()
            pendingID = id
            pendingSnapshot = snapshot

            let request = TranslationRequest(
                id: id,
                sourceText: snapshot.selection.text,
                contextText: snapshot.translationContext,
                providerID: selectedProviderID,
                targetLanguage: selectedTargetLanguage,
                scene: selectedScene,
                englishStyle: selectedEnglishStyle
            )
            switch selectedProviderID {
            case .appleSystem:
                beginSystemTranslation(request)
            case .deepSeek, .qwen, .volcengine, .xAI, .relay:
                beginAPITranslation(request)
            case .localModel:
                beginLocalModelTranslation(request)
            }
        } catch AccessibilityTextClient.Error.permissionRequired {
            logger.error("Translation blocked: accessibility permission required")
            requestAccessibilityPermission()
        } catch {
            logger.error("Focused text capture failed: \(error.localizedDescription, privacy: .private)")
            showError(userMessage(for: error))
        }
    }

    /// 错误的用户可见文案：云端提供方错误按界面语言渲染，
    /// 其余错误类型自身已本地化。
    private func userMessage(for error: Swift.Error) -> String {
        if let apiError = error as? APITranslationError {
            return apiError.localizedMessage
        }
        return error.localizedDescription
    }

    private func beginSystemTranslation(_ request: TranslationRequest) {
        state = .preparing
        if var configuration = translationConfiguration {
            configuration.invalidate()
            translationConfiguration = configuration
        } else {
            translationConfiguration = TranslationSession.Configuration(
                source: request.targetLanguage == .chinese
                    ? nil
                    : Locale.Language(identifier: "zh-Hans"),
                target: Locale.Language(identifier: request.targetLanguage.rawValue)
            )
        }
    }

    private func beginAPITranslation(_ request: TranslationRequest) {
        state = .translating
        apiTranslationTask?.cancel()
        apiTranslationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let configuration = try await settings.apiConfiguration(
                    for: request.providerID
                )
                try Task.checkCancellation()
                let provider = OpenAICompatibleTranslationProvider(
                    configuration: configuration
                )
                let translatedText = try await provider.translate(
                    TextTranslationRequest(
                        sourceText: request.sourceText,
                        contextText: request.contextText,
                        sourceLanguage: request.targetLanguage == .chinese
                            ? "auto"
                            : "zh-Hans",
                        targetLanguage: request.targetLanguage,
                        scene: request.scene,
                        englishStyle: request.englishStyle
                    )
                )
                try Task.checkCancellation()
                await completeTranslation(id: request.id, translatedText: translatedText)
            } catch {
                failTranslation(id: request.id, error: error)
            }
        }
    }

    private func beginLocalModelTranslation(_ request: TranslationRequest) {
        state = .preparing
        apiTranslationTask?.cancel()
        apiTranslationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let configuration = try settings.localModelConfiguration()
                try await LocalModelRuntime.ensureReady(configuration: configuration)
                try Task.checkCancellation()
                state = .translating
                let provider = LocalModelTranslationProvider(
                    configuration: configuration
                )
                let translatedText = try await provider.translate(
                    TextTranslationRequest(
                        sourceText: request.sourceText,
                        contextText: request.contextText,
                        sourceLanguage: request.targetLanguage == .chinese
                            ? "auto"
                            : "zh-Hans",
                        targetLanguage: request.targetLanguage,
                        scene: request.scene,
                        englishStyle: request.englishStyle
                    )
                )
                try Task.checkCancellation()
                await completeTranslation(id: request.id, translatedText: translatedText)
            } catch {
                failTranslation(id: request.id, error: error)
            }
        }
    }

    func activeTranslationRequest() -> TranslationRequest? {
        guard let id = pendingID, let snapshot = pendingSnapshot else { return nil }
        logger.info("Translation session accepted request")
        state = .translating
        return TranslationRequest(
            id: id,
            sourceText: snapshot.selection.text,
            contextText: nil,
            providerID: .appleSystem,
            targetLanguage: selectedTargetLanguage,
            scene: .faithful,
            englishStyle: .automatic
        )
    }

    func completeTranslation(id: UUID, translatedText: String) async {
        guard pendingID == id, let snapshot = pendingSnapshot else { return }
        do {
            try await accessibility.replace(
                snapshot: snapshot,
                with: translatedText,
                isCurrent: { [weak self] in self?.pendingID == id }
            )
            guard pendingID == id else { return }
            logger.info("Translated text committed")
            apiTranslationTask = nil
            clearPending()
            state = .success
        } catch is CancellationError {
            guard pendingID == id else { return }
            apiTranslationTask = nil
            clearPending()
            state = .ready
        } catch {
            guard pendingID == id else { return }
            logger.error("Translated text commit failed: \(error.localizedDescription, privacy: .private)")
            apiTranslationTask = nil
            clearPending()
            showError(error.localizedDescription)
        }
    }

    func failTranslation(id: UUID, error: Swift.Error) {
        guard pendingID == id else { return }
        apiTranslationTask = nil
        clearPending()
        if error is CancellationError {
            logger.info("Translation cancelled")
            state = .ready
        } else {
            logger.error("Translation failed: \(error.localizedDescription, privacy: .private)")
            showError(strings.translationFailed(userMessage(for: error)))
        }
    }

    func showError(_ message: String) {
        state = .failure(message)
    }

    func recoverAfterSystemResume() {
        cancelInFlightTranslation()
        refreshAccessibilityStatus()
        logger.info("Translation state recovered after system resume")
    }

    private func cancelInFlightTranslation() {
        apiTranslationTask?.cancel()
        apiTranslationTask = nil
        if var configuration = translationConfiguration {
            configuration.invalidate()
        }
        translationConfiguration = nil
        clearPending()
        state = .ready
    }

    private func clearPending() {
        pendingID = nil
        pendingSnapshot = nil
    }
}
