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
    @Published private(set) var interfaceLanguage: InterfaceLanguage
    @Published private(set) var configuredAPIProviderIDs: Set<TranslationProviderID>
    @Published private(set) var hotKeyConfiguration: HotKeyConfiguration
    @Published private(set) var localModelEndpoint: String
    @Published private(set) var localModelName: String

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
        guard APITranslationProviderCatalog.profile(
            for: providerID
        ) != nil else {
            showError(strings.unsupportedProvider)
            return false
        }

        let apiKeyField = NSSecureTextField()
        apiKeyField.placeholderString = isAPIConfigured(providerID)
            ? strings.savedLeaveBlank
            : strings.pasteAPIKey
        let endpointField = NSTextField()
        endpointField.placeholderString = "https://example.com/v1/chat/completions"
        endpointField.stringValue = settings.endpoint(for: providerID) ?? ""
        let modelField = NSTextField()
        modelField.stringValue = settings.model(for: providerID) ?? ""

        guard presentConfigurationForm(
            title: strings.configureAPI(providerID),
            informativeText: strings.apiStorageInfo,
            fields: [
                (strings.apiKey, apiKeyField),
                (strings.endpoint, endpointField),
                (strings.model, modelField)
            ],
            initialFocus: apiKeyField
        ) else { return false }

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
            showError(strings.saveAPIFailed(providerID, detail: error.localizedDescription))
            return false
        }
    }

    @discardableResult
    func configureLocalModel() -> Bool {
        let endpointField = NSTextField(string: localModelEndpoint)
        let modelField = NSTextField(string: localModelName)

        guard presentConfigurationForm(
            title: strings.configureLocalModel,
            informativeText: strings.localModelInfo,
            fields: [
                (strings.endpoint, endpointField),
                (strings.model, modelField)
            ],
            initialFocus: endpointField
        ) else { return false }

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
            showError("\(strings.saveLocalModelFailedPrefix)\(error.localizedDescription)")
            return false
        }
    }

    /// 弹出带表单的配置窗口；返回用户是否点击"保存"。
    /// macOS 26 的 NSAlert 不再可靠地采用 NSGridView 的内在尺寸，
    /// 直接作为 accessoryView 会把整张表压成几个小白条，因此用明确
    /// 尺寸的容器承载表单，保证标签和输入框始终可见、可点击。
    private func presentConfigurationForm(
        title: String,
        informativeText: String,
        fields: [(label: String, view: NSView)],
        initialFocus: NSView
    ) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = informativeText

        let grid = NSGridView(
            views: fields.map { [NSTextField(labelWithString: $0.label), $0.view] }
        )
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 76
        grid.column(at: 1).width = 374
        for rowIndex in 0..<fields.count {
            grid.row(at: rowIndex).height = 24
        }

        let formContainer = NSView(
            frame: NSRect(
                x: 0,
                y: 0,
                width: 460,
                height: 24 * fields.count + 8 * max(fields.count - 1, 0)
            )
        )
        grid.frame = formContainer.bounds
        grid.autoresizingMask = [.width, .height]
        formContainer.addSubview(grid)
        alert.accessoryView = formContainer
        alert.addButton(withTitle: strings.save)
        alert.addButton(withTitle: strings.cancel)
        alert.window.initialFirstResponder = initialFocus
        return alert.runModal() == .alertFirstButtonReturn
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
            showError(strings.translationFailed(error.localizedDescription))
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
