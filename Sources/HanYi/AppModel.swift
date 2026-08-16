import AppKit
import Combine
import HanYiCore
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

        var title: String {
            switch self {
            case .ready: "就绪"
            case .permissionRequired: "需要辅助功能权限"
            case .preparing: "正在准备翻译资源"
            case .translating: "正在翻译"
            case .success: "翻译完成"
            case let .failure(message): message
            }
        }

        var symbolName: String {
            switch self {
            case .ready, .success: "character.cursor.ibeam"
            case .preparing, .translating: "ellipsis.circle"
            case .permissionRequired: "lock.fill"
            case .failure: "exclamationmark.triangle"
            }
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

    @Published private(set) var state: State = .ready
    @Published var translationConfiguration: TranslationSession.Configuration?
    @Published private(set) var selectedProviderID: TranslationProviderID
    @Published private(set) var selectedTargetLanguage: TranslationLanguage
    @Published private(set) var selectedScene: TranslationScene
    @Published private(set) var selectedEnglishStyle: EnglishStyle
    @Published private(set) var configuredAPIProviderIDs: Set<TranslationProviderID>
    @Published private(set) var hotKeyConfiguration: HotKeyConfiguration
    @Published private(set) var localModelEndpoint: String
    @Published private(set) var localModelName: String

    private let accessibility = AccessibilityTextClient()
    private let settings: TranslationSettingsStore
    private let hotKeySettings: HotKeySettingsStore
    private let logger = Logger(
        subsystem: "com.hanyi.input-translator",
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
        self.hotKeyConfiguration = hotKeySettings.configuration
        self.localModelEndpoint = settings.localModelEndpoint()
        self.localModelName = settings.localModelName()
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
        TranslationProviderCatalog.descriptor(for: selectedProviderID).name
    }

    var apiProviderProfiles: [APITranslationProviderProfile] {
        APITranslationProviderCatalog.profiles
    }

    var supportsTranslationCustomization: Bool {
        selectedProviderID != .appleSystem
    }

    var supportsEnglishStyleCustomization: Bool {
        supportsTranslationCustomization
            && selectedTargetLanguage == .english
            && selectedScene != .business
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

    func selectProvider(_ providerID: TranslationProviderID) {
        if providerID.requiresAPIConfiguration,
           !isAPIConfigured(providerID) {
            guard configureAPI(for: providerID) else { return }
        }
        guard settings.select(providerID) else { return }
        selectedProviderID = providerID
        if providerID == .appleSystem, state.isFailure {
            state = .ready
        }
    }

    @discardableResult
    func configureAPI(for providerID: TranslationProviderID) -> Bool {
        guard let profile = APITranslationProviderCatalog.profile(
            for: providerID
        ) else {
            showError("当前提供方不支持 API 配置")
            return false
        }

        let alert = NSAlert()
        alert.messageText = "配置 \(providerID.displayName) API"
        alert.informativeText = "API Key 仅保存到当前 macOS 用户的钥匙串；Endpoint 和模型名保存到本机设置。"

        let apiKeyField = NSSecureTextField()
        apiKeyField.placeholderString = isAPIConfigured(providerID)
            ? "已保存，留空保持不变"
            : "粘贴 API Key"
        let endpointField = NSTextField()
        endpointField.placeholderString = "https://example.com/v1/chat/completions"
        endpointField.stringValue = settings.endpoint(for: providerID)
            ?? profile.defaultEndpoint
        let modelField = NSTextField()
        modelField.stringValue = settings.model(for: providerID)
            ?? profile.defaultModel

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "API Key"), apiKeyField],
            [NSTextField(labelWithString: "Endpoint"), endpointField],
            [NSTextField(labelWithString: "模型"), modelField]
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 76
        grid.column(at: 1).width = 374
        for rowIndex in 0..<3 {
            grid.row(at: rowIndex).height = 24
        }

        // macOS 26 的 NSAlert 不再可靠地采用 NSGridView 的内在尺寸；
        // 直接作为 accessoryView 会把整张表压成几个小白条。使用明确尺寸
        // 的容器承载表单，确保标签和三个输入框始终可见、可点击。
        let formContainer = NSView(
            frame: NSRect(x: 0, y: 0, width: 460, height: 88)
        )
        grid.frame = formContainer.bounds
        grid.autoresizingMask = [.width, .height]
        formContainer.addSubview(grid)
        alert.accessoryView = formContainer
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = apiKeyField

        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        do {
            try settings.saveAPIConfiguration(
                for: providerID,
                apiKey: apiKeyField.stringValue,
                endpoint: endpointField.stringValue.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ),
                model: modelField.stringValue
            )
            configuredAPIProviderIDs.insert(providerID)
            if state.isFailure { state = .ready }
            return true
        } catch {
            showError("保存 \(providerID.displayName) API 失败：\(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func configureLocalModel() -> Bool {
        let alert = NSAlert()
        alert.messageText = "配置本地 Gemma 4"
        alert.informativeText = "无需 API Key。首次翻译会自动加载 12B 模型；闲置 3 分钟后自动卸载并释放内存。"

        let endpointField = NSTextField(string: localModelEndpoint)
        let modelField = NSTextField(string: localModelName)
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Endpoint"), endpointField],
            [NSTextField(labelWithString: "模型"), modelField]
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 76
        grid.column(at: 1).width = 374
        for rowIndex in 0..<2 {
            grid.row(at: rowIndex).height = 24
        }
        let formContainer = NSView(
            frame: NSRect(x: 0, y: 0, width: 460, height: 56)
        )
        grid.frame = formContainer.bounds
        grid.autoresizingMask = [.width, .height]
        formContainer.addSubview(grid)
        alert.accessoryView = formContainer
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = endpointField

        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        do {
            try settings.saveLocalModelConfiguration(
                endpoint: endpointField.stringValue.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ),
                model: modelField.stringValue
            )
            localModelEndpoint = settings.localModelEndpoint()
            localModelName = settings.localModelName()
            if state.isFailure { state = .ready }
            return true
        } catch {
            showError("保存本地 Gemma 4 配置失败：\(error.localizedDescription)")
            return false
        }
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

    func triggerFromMenu() {
        Task {
            try? await Task.sleep(for: .milliseconds(180))
            await triggerTranslation()
        }
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
            showError("请先配置 \(selectedProviderName) API")
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
            logger.error("Focused text capture failed: \(error.localizedDescription, privacy: .public)")
            showError(error.localizedDescription)
        }
    }

    private func beginSystemTranslation(_ request: TranslationRequest) {
        state = .preparing
        if var configuration = translationConfiguration {
            configuration.invalidate()
            translationConfiguration = configuration
        } else {
            translationConfiguration = TranslationSession.Configuration(
                source: Locale.Language(identifier: "zh-Hans"),
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
                        targetLanguage: request.targetLanguage.rawValue,
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
                        targetLanguage: request.targetLanguage.rawValue,
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
        apiTranslationTask = nil
        do {
            try await accessibility.replace(snapshot: snapshot, with: translatedText)
            logger.info("Translated text committed")
            clearPending()
            state = .success
        } catch {
            logger.error("Translated text commit failed: \(error.localizedDescription, privacy: .public)")
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
            logger.error("Translation failed: \(error.localizedDescription, privacy: .public)")
            showError("翻译失败：\(error.localizedDescription)")
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
