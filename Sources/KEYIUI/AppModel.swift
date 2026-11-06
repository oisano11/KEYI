import AppKit
import Combine
import KEYICore
import KEYITranslationClient
import KEYITranslationService
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
        case statistics
        case hotKey
        case general

        var providerForEditing: TranslationProviderID {
            guard case let .providers(providerID) = self,
                  let providerID, providerID != .appleSystem else { return .deepSeek }
            return providerID
        }
    }

    @Published private(set) var state: State = .ready
    @Published var translationConfiguration: TranslationSession.Configuration?
    /// 用户选的风格；下面的引擎、场景和英语风格都由它按 `TranslationStyleRouting` 推出。
    @Published private(set) var translationStyle: KEYITranslationStyle
    /// 这次实际用的引擎；随风格、本地模型下载和云端配置变化。
    @Published private(set) var selectedProviderID: TranslationProviderID
    /// 选了云端风格但云端没配好，这时按「自然」走本地。
    @Published private(set) var usesNaturalInsteadOfCloudStyle = false
    @Published private(set) var selectedTargetLanguage: TranslationLanguage
    @Published private(set) var selectedScene: TranslationScene
    @Published private(set) var selectedEnglishStyle: EnglishStyle
    @Published private(set) var interfaceLanguage: InterfaceLanguage
    @Published private(set) var configuredAPIProviderIDs: Set<TranslationProviderID>
    @Published private(set) var hotKeyConfiguration: HotKeyConfiguration
    @Published private(set) var localModelTier: LocalTranslationModelTier?
    @Published private(set) var installedLocalModels: Set<LocalTranslationModelTier>
    @Published private(set) var localModelDownloadProgress: [LocalTranslationModelTier: Int64] = [:]
    @Published private(set) var localModelDownloadErrors: [LocalTranslationModelTier: String] = [:]
    @Published private(set) var localModelServerState: LocalModelServer.State = .stopped
    @Published private(set) var showsLocalModelMigrationNotice: Bool
    @Published private(set) var systemTranslationHostRequestID: UUID?
    @Published var settingsSection: SettingsSection = .translation
    /// 主题与光标旁磨砂玻璃（设置「高级」里的外观）；存在共享偏好域，输入法面板同步重画。
    @Published private(set) var appearanceTheme: KEYITheme = KEYIAppearanceSettings.theme
    /// 磨砂程度 0–100（通透到厚实），光标旁面板和设置窗口共用。
    @Published private(set) var glassFrost: Double = KEYIAppearanceSettings.glassFrost
    /// 设置窗口里的「词库更新」对话框；菜单栏的新词库提示点开就弹。
    @Published var showsDictionaryUpdateSheet = false
    @Published private(set) var terminalRecoveryCommands: [String] = []
    private let accessibility: any FocusedTextAccess
    private let presentSettings: @MainActor () -> Void
    private let settings: TranslationSettingsStore
    private let hotKeySettings: HotKeySettingsStore
    private let logger = Logger(
        subsystem: "com.keyi.input-translator",
        category: "Translation"
    )
    private var pendingID: UUID?
    private var pendingSnapshot: AccessibilityTextClient.Snapshot?
    private var pendingRequest: TranslationRequest?
    private var acceptedSystemTranslationHostRequestID: UUID?
    private var writebackStartedRequestID: UUID?
    private var apiTranslationTask: Task<Void, Never>?
    private var systemTranslationTask: Task<Void, Never>?
    private var translationDeadlineTask: Task<Void, Never>?
    private var systemTranslationStage: String?
    private let systemTranslationTimeoutSeconds: TimeInterval
    private let systemTranslator: @Sendable (TranslationRequest) async throws -> String
    private var hotKeyRegistrationHandler: ((HotKeyConfiguration) throws -> Void)?
    private var terminalDraftEditorProcess: Process?
    private let localModelStorage: LocalModelStorage
    private let localModelServer: LocalModelServer
    private var localModelDownloadTasks: [LocalTranslationModelTier: Task<Void, Never>] = [:]
    private var styleObserver: NSObjectProtocol?

    init(
        settings: TranslationSettingsStore = TranslationSettingsStore(),
        hotKeySettings: HotKeySettingsStore = HotKeySettingsStore(),
        accessibility: any FocusedTextAccess = AccessibilityTextClient(),
        presentSettings: @escaping @MainActor () -> Void = { SettingsWindowController.shared.show() },
        localModelStorage: LocalModelStorage = .standard,
        localModelServer: LocalModelServer? = nil,
        systemTranslationTimeoutSeconds: TimeInterval = 60,
        systemTranslator: @escaping @Sendable (TranslationRequest) async throws -> String = { request in
            try await KEYITranslationAppleSessionPool.shared.translate(
                text: request.sourceText,
                sourceLanguage: "zh-Hans",
                targetLanguage: request.targetLanguage.rawValue,
                timeoutSeconds: 45,
                requestID: request.id.uuidString
            )
        }
    ) {
        self.accessibility = accessibility
        self.presentSettings = presentSettings
        self.settings = settings
        self.hotKeySettings = hotKeySettings
        self.translationStyle = settings.translationStyle()
        self.selectedProviderID = settings.preferences.providerID
        self.selectedTargetLanguage = settings.preferences.targetLanguage
        self.selectedScene = settings.preferences.scene
        self.selectedEnglishStyle = settings.preferences.englishStyle
        self.interfaceLanguage = settings.preferences.interfaceLanguage
        self.hotKeyConfiguration = hotKeySettings.configuration
        self.localModelStorage = localModelStorage
        self.localModelServer = localModelServer ?? .shared
        self.localModelTier = settings.localModelTier()
        self.installedLocalModels = Set(
            LocalTranslationModelCatalog.models.filter(localModelStorage.isInstalled).map(\.tier)
        )
        self.showsLocalModelMigrationNotice = settings.hasLocalModelMigrationNotice
        self.systemTranslationTimeoutSeconds = systemTranslationTimeoutSeconds.isFinite
            && systemTranslationTimeoutSeconds > 0
            ? systemTranslationTimeoutSeconds
            : 60
        self.systemTranslator = systemTranslator
        self.configuredAPIProviderIDs = Set(
            APITranslationProviderCatalog.profiles.compactMap { profile in
                settings.hasStoredAPIConfiguration(for: profile.providerID)
                    && settings.hasAPIKey(for: profile.providerID)
                    ? profile.providerID
                    : nil
            }
        )
        refreshRoute()
        // 输入法菜单里切换风格时，菜单栏和设置窗口跟着变。
        styleObserver = DistributedNotificationCenter.default().addObserver(
            forName: KEYITranslationStyle.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadTranslationStyle() }
        }
        logger.info("Translation provider loaded: \(self.selectedProviderID.rawValue, privacy: .public)")
    }

    // MARK: 翻译风格

    func selectTranslationStyle(_ style: KEYITranslationStyle) {
        settings.selectTranslationStyle(style)
        translationStyle = style
        dismissLocalModelMigrationNotice()
        refreshRoute()
        // 云端风格还没配云端服务：打开设置让用户填一次 Key；不填就先按「自然」翻。
        if usesNaturalInsteadOfCloudStyle {
            openSettings(.providers(APITranslationProviderCatalog.profiles.first?.providerID))
        }
    }

    func reloadTranslationStyle() {
        settings.reloadPreferences()
        translationStyle = settings.translationStyle()
        refreshRoute()
    }

    /// 按当前风格、本地模型和云端配置算出这次用哪个引擎，并让本地模型服务跟着启停。
    func refreshRoute() {
        let route = TranslationStyleRouting.route(
            for: translationStyle,
            localModelReady: installedLocalModelInUse != nil,
            cloudProvider: settings.preferredCloudProvider(isConfigured: isAPIConfigured)
        )
        selectedProviderID = route.providerID
        selectedScene = route.scene
        selectedEnglishStyle = route.englishStyle
        usesNaturalInsteadOfCloudStyle = route.usesNaturalInstead
        settings.storeEngineLabels(engineLabels(strings: InterfaceStrings(language: .simplifiedChinese)))
        syncLocalModelServer()
        if state.isFailure { state = .ready }
    }

    /// 每个风格现在用哪个引擎，直接写模型名或服务名；大模型风格没配 API 时写「需 API Key」。
    func engineLabels(strings: InterfaceStrings) -> [KEYITranslationStyle: String] {
        let localModelReady = installedLocalModelInUse != nil
        let cloudProvider = settings.preferredCloudProvider(isConfigured: isAPIConfigured)
        var labels: [KEYITranslationStyle: String] = [:]
        for style in KEYITranslationStyle.allCases {
            let route = TranslationStyleRouting.route(
                for: style,
                localModelReady: localModelReady,
                cloudProvider: cloudProvider
            )
            labels[style] = route.usesNaturalInstead
                ? strings.engineNeedsAPIKey
                : strings.engineName(route.providerID)
        }
        return labels
    }

    func engineLabel(for style: KEYITranslationStyle) -> String {
        engineLabels(strings: strings)[style] ?? ""
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
        // A running request owns the language pair captured at trigger time.
        // Do not invalidate its host session when the user edits future settings.
        if pendingID == nil, var configuration = translationConfiguration {
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

    /// 指定云端风格用哪家云端服务；没配置的先打开它的表单。
    func selectProvider(_ providerID: TranslationProviderID) {
        if providerID.requiresAPIConfiguration,
           !isAPIConfigured(providerID) {
            openSettings(.providers(providerID))
            return
        }
        if providerID.requiresAPIConfiguration {
            _ = settings.select(providerID)
        }
        dismissLocalModelMigrationNotice()
        refreshRoute()
    }

    // MARK: 本地模型

    /// 翻译用的那一档：用户选的已下载就用它，否则用已下载的标准档、再轻量档。
    var installedLocalModelInUse: LocalTranslationModel? {
        localModelStorage.preferredInstalledModel(preferring: localModelTier)
    }

    /// 只有正式运行的 KEYI 管本地模型服务；检查程序里新建的 AppModel 不碰真实的服务和运行目录。
    private var managesLocalModelServer = false

    /// 应用启动后调用一次：从此按风格启停本地模型服务。
    func startManagingLocalModelServer() {
        managesLocalModelServer = true
        syncLocalModelServer()
    }

    /// 选中本地模型且模型已下载时让自带服务在后台加载它，否则停掉服务释放内存。
    func syncLocalModelServer() {
        guard managesLocalModelServer else { return }
        localModelServer.onStateChange = { [weak self] state in
            self?.localModelServerState = state
        }
        let model = selectedProviderID == .localModel ? installedLocalModelInUse : nil
        localModelServer.run(modelAt: model.map(localModelStorage.fileURL(for:)))
        localModelServerState = localModelServer.state
    }

    /// 选定本地风格用哪一档。
    func useLocalModel(_ tier: LocalTranslationModelTier) {
        settings.selectLocalModelTier(tier)
        localModelTier = tier
        refreshRoute()
    }

    /// 个人术语表「现在整理」用：取正在用的大模型服务的配置。
    func apiConfigurationForGlossary(_ providerID: TranslationProviderID) async throws -> APIProviderConfiguration {
        try await settings.apiConfiguration(for: providerID)
    }

    /// 大模型风格现在用的服务；一个都没配好时为 nil。
    var cloudProviderInUse: TranslationProviderID? {
        settings.preferredCloudProvider(isConfigured: isAPIConfigured)
    }

    /// 「高级」里大模型服务表单显示哪家：深链指定的那家，否则是正在用的，再否则是列表第一家。
    var cloudProviderShownInSettings: TranslationProviderID {
        if case let .providers(providerID?) = settingsSection, providerID.requiresAPIConfiguration {
            return providerID
        }
        return cloudProviderInUse ?? APITranslationProviderCatalog.profiles.first?.providerID ?? .deepSeek
    }

    /// 有本地模型正在下载时，返回整体进度（0–1），给菜单栏显示。
    var localModelDownloadFraction: Double? {
        guard !localModelDownloadProgress.isEmpty else { return nil }
        var done: Int64 = 0
        var total: Int64 = 0
        for (tier, bytes) in localModelDownloadProgress {
            done += bytes
            total += LocalTranslationModelCatalog.model(for: tier).byteCount
        }
        return total > 0 ? min(Double(done) / Double(total), 1) : nil
    }

    /// 「高级」里选中一个服务：已配置的云端服务立刻作为云端风格的服务；其余只显示表单。
    func chooseProviderInSettings(_ providerID: TranslationProviderID) {
        settingsSection = .providers(providerID)
        if providerID.requiresAPIConfiguration, isAPIConfigured(providerID) {
            selectProvider(providerID)
        }
    }

    /// 用户点了「下载并使用」的档位；下载校验完成后直接用于翻译。
    private var localModelTiersToUseAfterDownload: Set<LocalTranslationModelTier> = []

    func downloadAndUseLocalModel(_ tier: LocalTranslationModelTier) {
        localModelTiersToUseAfterDownload.insert(tier)
        downloadLocalModel(tier)
    }

    func downloadLocalModel(_ tier: LocalTranslationModelTier) {
        guard localModelDownloadTasks[tier] == nil else { return }
        let model = LocalTranslationModelCatalog.model(for: tier)
        let downloader = LocalModelDownloader(storage: localModelStorage)
        localModelDownloadErrors[tier] = nil
        localModelDownloadProgress[tier] = localModelStorage.partialSize(for: model)
        let report: @Sendable (Int64) -> Void = { [weak self] bytes in
            let owner = self
            Task { @MainActor in
                guard let owner, owner.localModelDownloadTasks[tier] != nil else { return }
                owner.localModelDownloadProgress[tier] = bytes
            }
        }
        localModelDownloadTasks[tier] = Task { [weak self] in
            do {
                try await downloader.download(model, progress: report)
                self?.finishLocalModelDownload(tier, error: nil)
            } catch {
                self?.finishLocalModelDownload(tier, error: error)
            }
        }
    }

    func cancelLocalModelDownload(_ tier: LocalTranslationModelTier) {
        localModelDownloadTasks[tier]?.cancel()
    }

    func deleteLocalModel(_ tier: LocalTranslationModelTier) {
        if installedLocalModelInUse?.tier == tier {
            localModelServer.run(modelAt: nil)
        }
        do {
            try localModelStorage.delete(LocalTranslationModelCatalog.model(for: tier))
        } catch {
            localModelDownloadErrors[tier] = error.localizedDescription
        }
        installedLocalModels.remove(tier)
        refreshRoute()
    }

    func dismissLocalModelMigrationNotice() {
        guard showsLocalModelMigrationNotice else { return }
        settings.clearLocalModelMigrationNotice()
        showsLocalModelMigrationNotice = false
    }

    private func finishLocalModelDownload(_ tier: LocalTranslationModelTier, error: Error?) {
        localModelDownloadTasks[tier] = nil
        localModelDownloadProgress[tier] = nil
        if let error, !(error is CancellationError) {
            localModelDownloadErrors[tier] = error.localizedDescription
        }
        let wantsUse = localModelTiersToUseAfterDownload.remove(tier) != nil
        if localModelStorage.isInstalled(LocalTranslationModelCatalog.model(for: tier)) {
            installedLocalModels.insert(tier)
            // 点「下载本地翻译模型」就是同意下载完改用它，不再另弹确认。
            if wantsUse {
                useLocalModel(tier)
            } else {
                refreshRoute()
            }
        }
    }

    // MARK: 设置窗口

    /// 侧栏「统计」下面那行：今天的汉字数。
    var statisticsSubtitle: String {
        let today = KEYIDailyWordStats.load()[KEYIDailyWordStats.dayKey(for: Date())]?.hanzi ?? 0
        return strings.isEnglish ? "Today \(today) characters" : "今天 \(today) 字"
    }

    func selectAppearanceTheme(_ theme: KEYITheme) {
        guard theme != appearanceTheme else { return }
        appearanceTheme = theme
        KEYIPalette.theme = theme
        KEYIAppearanceSettings.store(theme: theme)
    }

    /// 滑块拖动时只改界面（设置窗口的玻璃当场跟着变），松手（`commit`）才写偏好并通知输入法，免得每一帧都发通知。
    func setGlassFrost(_ value: Double, commit: Bool) {
        glassFrost = value.rounded()
        if commit { KEYIAppearanceSettings.store(glassFrost: glassFrost) }
    }

    /// 菜单栏的新词库提示：打开设置，弹出词库更新对话框。
    func openDictionaryUpdate() {
        openSettings(.general)
        showsDictionaryUpdateSheet = true
    }

    func openSettings(_ section: SettingsSection = .translation) {
        settingsSection = section
        presentSettings()
    }

    func openTerminalDraftEditor() {
        if let process = terminalDraftEditorProcess, process.isRunning {
            _ = NSRunningApplication(processIdentifier: process.processIdentifier)?.activate(options: [])
            return
        }
        guard let helper = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("KEYITerminal"),
              FileManager.default.isExecutableFile(atPath: helper.path) else {
            showError(strings.terminalDraftEditorUnavailable)
            return
        }
        let process = Process()
        process.executableURL = helper
        process.arguments = ["compose"]
        do {
            try process.run()
            terminalDraftEditorProcess = process
        } catch {
            showError(strings.terminalDraftEditorUnavailable)
        }
    }

    func copyOriginalTerminalCommand(to pasteboard: NSPasteboard = .general) {
        guard let original = terminalRecoveryCommands.first else { return }
        pasteboard.clearContents()
        guard pasteboard.setString(original, forType: .string) else {
            showError(strings.terminalRecoveryRequired)
            return
        }
        discardOriginalTerminalCommand()
    }

    func discardOriginalTerminalCommand() {
        guard !terminalRecoveryCommands.isEmpty else { return }
        terminalRecoveryCommands.removeFirst()
        if !isBusy {
            state = terminalRecoveryCommands.isEmpty ? .ready : .failure(strings.terminalRecoveryRequired)
        }
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
        _ = settings.select(providerID)
        refreshRoute()
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
            logger.info("Duplicate translation trigger ignored; request_id=\(self.pendingID?.uuidString ?? "none", privacy: .public)")
            return
        }
        guard terminalRecoveryCommands.isEmpty else {
            showError(strings.terminalRecoveryRequired)
            return
        }
        // 风格可能刚在输入法菜单里改过；按最新风格算一次再冻结。
        reloadTranslationStyle()
        // Freeze all user-selected options before capture awaits the focused host.
        // The captured text/context is added to this same immutable request below.
        let providerID = selectedProviderID
        let targetLanguage = selectedTargetLanguage
        let scene = selectedScene
        let englishStyle = selectedEnglishStyle
        if providerID.requiresAPIConfiguration,
           !isAPIConfigured(providerID) {
            showError(strings.configureProviderFirst(strings.providerName(providerID)))
            openSettings(.providers(providerID))
            return
        }
        logger.info("Translation requested; provider=\(providerID.rawValue, privacy: .public); trusted=\(self.accessibility.isTrusted)")

        // 捕获是异步等待目标应用响应的；置为 preparing 让 isBusy 在
        // 等待期间挡住重复触发的快捷键，避免两次捕获交错操作剪贴板。
        state = .preparing
        do {
            let snapshot = try await accessibility.capture()
            logger.info("Focused text captured; mode=\(String(describing: snapshot.writeMode), privacy: .public); utf16Length=\((snapshot.selection.text as NSString).length)")
            let id = UUID()
            pendingID = id
            pendingSnapshot = snapshot

            let request = TranslationRequest(
                id: id,
                sourceText: snapshot.selection.text,
                contextText: snapshot.translationContext,
                providerID: providerID,
                targetLanguage: targetLanguage,
                scene: scene,
                englishStyle: englishStyle
            )
            pendingRequest = request
            writebackStartedRequestID = nil
            switch request.providerID {
            case .appleSystem:
                beginSystemTranslation(request)
            case .deepSeek, .qwen, .volcengine, .xAI, .relay:
                beginAPITranslation(request)
            case .localModel:
                beginLocalModelTranslation(request)
            }
        } catch AccessibilityTextClient.Error.permissionRequired {
            logger.error("Translation blocked: accessibility permission required")
            clearPending()
            state = .permissionRequired
            requestAccessibilityPermission()
        } catch {
            let code = (error as? AccessibilityTextClient.Error)?.diagnosticCode ?? "other"
            logger.error("Focused text capture failed; code=\(code, privacy: .public): \(error.localizedDescription, privacy: .private)")
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
        guard pendingID == request.id else { return }
        state = .preparing
        startTranslationDeadline(for: request)

        // Chinese as the target requires automatic source-language detection,
        // which the installedSource session does not provide.
        guard request.targetLanguage != .chinese else {
            dispatchSystemTranslationHost(for: request)
            return
        }
        guard #available(macOS 26.0, *) else {
            dispatchSystemTranslationHost(for: request)
            return
        }

        systemTranslationStage = "installed_session"
        logger.notice("System translation started; request_id=\(request.id.uuidString, privacy: .public); stage=installed_session; provider=\(request.providerID.rawValue, privacy: .public); source_utf16_length=\((request.sourceText as NSString).length, privacy: .public)")
        systemTranslationTask?.cancel()
        systemTranslationTask = Task { [weak self] in
            guard let self else { return }
            state = .translating
            do {
                let translatedText = try await systemTranslator(request)
                try Task.checkCancellation()
                guard pendingID == request.id else { return }
                await completeTranslation(id: request.id, translatedText: translatedText)
            } catch {
                guard pendingID == request.id else { return }
                if shouldUseTranslationHost(after: error) {
                    dispatchSystemTranslationHost(for: request)
                } else {
                    failTranslation(id: request.id, error: error)
                }
            }
        }
    }

    private func shouldUseTranslationHost(after error: Swift.Error) -> Bool {
        guard let error = error as? AppleTranslationSessionError else { return false }
        return switch error {
        case .requiresMacOS26, .languagePairNotInstalled:
            true
        case .unsupportedLanguagePair, .timedOut, .emptyResult:
            false
        }
    }

    private func dispatchSystemTranslationHost(for request: TranslationRequest) {
        guard pendingID == request.id else { return }
        systemTranslationTask = nil
        systemTranslationStage = "host_session"
        acceptedSystemTranslationHostRequestID = nil
        if var configuration = translationConfiguration {
            configuration.invalidate()
            translationConfiguration = configuration
        }
        systemTranslationHostRequestID = request.id
        translationConfiguration = TranslationSession.Configuration(
            source: request.targetLanguage == .chinese
                ? nil
                : Locale.Language(identifier: "zh-Hans"),
            target: Locale.Language(identifier: request.targetLanguage.rawValue)
        )
        state = .preparing
        logger.notice("System translation host config dispatched; request_id=\(request.id.uuidString, privacy: .public); stage=config_dispatch; provider=\(request.providerID.rawValue, privacy: .public); source_utf16_length=\((request.sourceText as NSString).length, privacy: .public)")
    }

    private func startTranslationDeadline(for request: TranslationRequest) {
        cancelTranslationDeadline()
        let timeoutSeconds = systemTranslationTimeoutSeconds
        translationDeadlineTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(timeoutSeconds))
            } catch {
                return
            }
            self?.translationDeadlineDidExpire(for: request)
        }
    }

    private func translationDeadlineDidExpire(for request: TranslationRequest) {
        guard pendingID == request.id else { return }
        let stage = systemTranslationStage ?? "system_translation"
        let timeoutSeconds = Int(systemTranslationTimeoutSeconds)
        logger.notice("System translation timed out; request_id=\(request.id.uuidString, privacy: .public); stage=\(stage, privacy: .public); provider=\(request.providerID.rawValue, privacy: .public); source_utf16_length=\((request.sourceText as NSString).length, privacy: .public); timeout_seconds=\(timeoutSeconds, privacy: .public)")
        systemTranslationTask?.cancel()
        systemTranslationTask = nil
        apiTranslationTask?.cancel()
        apiTranslationTask = nil
        clearPending()
        showError(
            strings.isEnglish
                ? "System translation timed out. The original text was kept; you can try again."
                : "系统翻译超时，原文已保留，请重试。"
        )
    }

    private func cancelTranslationDeadline() {
        translationDeadlineTask?.cancel()
        translationDeadlineTask = nil
    }

    private func clearSystemTranslationHost() {
        systemTranslationHostRequestID = nil
        acceptedSystemTranslationHostRequestID = nil
        if var configuration = translationConfiguration {
            configuration.invalidate()
        }
        translationConfiguration = nil
        systemTranslationStage = nil
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
                    configuration: configuration,
                    usageRecorder: { APIUsageLedger.standard.record(providerID: $0, usage: $1) }
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
                guard let model = installedLocalModelInUse else {
                    throw LocalModelTranslationError.modelNotInstalled
                }
                // 服务放弃重启后，用户再次翻译时重新拉起一次。
                syncLocalModelServer()
                state = .translating
                let provider = LocalModelTranslationProvider.bundled(model: model)
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

    func activeTranslationRequest(id: UUID) -> TranslationRequest? {
        guard systemTranslationHostRequestID == id,
              pendingID == id,
              let request = pendingRequest,
              request.id == id else {
            let currentRequest = pendingRequest
            logger.notice("System translation host callback ignored; request_id=\(id.uuidString, privacy: .public); stage=host_ignore; provider=\(currentRequest?.providerID.rawValue ?? TranslationProviderID.appleSystem.rawValue, privacy: .public); source_utf16_length=\((currentRequest?.sourceText as NSString?)?.length ?? 0, privacy: .public); reason=stale_or_not_dispatched")
            return nil
        }
        guard acceptedSystemTranslationHostRequestID != id else {
            logger.notice("System translation host callback ignored; request_id=\(id.uuidString, privacy: .public); stage=host_ignore; provider=\(request.providerID.rawValue, privacy: .public); source_utf16_length=\((request.sourceText as NSString).length, privacy: .public); reason=duplicate_accept")
            return nil
        }
        acceptedSystemTranslationHostRequestID = id
        systemTranslationStage = "host_prepare_and_translate"
        logger.notice("System translation host accepted request; request_id=\(id.uuidString, privacy: .public); stage=host_accept; provider=\(request.providerID.rawValue, privacy: .public); source_utf16_length=\((request.sourceText as NSString).length, privacy: .public)")
        state = .translating
        return request
    }

    func completeTranslation(id: UUID, translatedText: String) async {
        guard pendingID == id,
              let snapshot = pendingSnapshot,
              writebackStartedRequestID != id else { return }
        writebackStartedRequestID = id
        // The deadline covers translation only. Once writeback starts, AX target,
        // original-content, and request-ID validation remain the safety boundary.
        cancelTranslationDeadline()
        do {
            try await accessibility.replace(
                snapshot: snapshot,
                with: translatedText,
                isCurrent: { [weak self] in
                    self?.pendingID == id && self?.writebackStartedRequestID == id
                }
            )
            guard pendingID == id else { return }
            let completedRequest = pendingRequest
            let provider = completedRequest?.providerID.rawValue ?? "unknown"
            let sourceLength = ((completedRequest?.sourceText ?? "") as NSString).length
            logger.notice("Translated text committed; request_id=\(id.uuidString, privacy: .public); stage=writeback; provider=\(provider, privacy: .public); source_utf16_length=\(sourceLength, privacy: .public)")
            apiTranslationTask = nil
            systemTranslationTask = nil
            clearPending()
            state = .success
        } catch AccessibilityTextClient.Error.terminalRecoveryRequired(let originalText) {
            // Retain the command even if cancellation already cleared this request.
            // Never paste automatically after losing the terminal's focus.
            terminalRecoveryCommands.append(originalText)
            if pendingID == id {
                apiTranslationTask = nil
                systemTranslationTask = nil
                clearPending()
                showError(strings.terminalRecoveryRequired)
            } else if !isBusy {
                showError(strings.terminalRecoveryRequired)
            }
        } catch is CancellationError {
            guard pendingID == id else { return }
            apiTranslationTask = nil
            systemTranslationTask = nil
            clearPending()
            state = .ready
        } catch {
            guard pendingID == id else { return }
            let failureCode = (error as? AccessibilityTextClient.Error)?.diagnosticCode ?? "other"
            let failedRequest = pendingRequest
            let provider = failedRequest?.providerID.rawValue ?? "unknown"
            let sourceLength = ((failedRequest?.sourceText ?? "") as NSString).length
            logger.error("Translated text commit failed; request_id=\(id.uuidString, privacy: .public); stage=writeback; provider=\(provider, privacy: .public); source_utf16_length=\(sourceLength, privacy: .public); code=\(failureCode, privacy: .public)")
            apiTranslationTask = nil
            systemTranslationTask = nil
            clearPending()
            showError(error.localizedDescription)
        }
    }

    func failTranslation(id: UUID, error: Swift.Error) {
        guard pendingID == id else {
            let currentRequest = pendingRequest
            let provider = currentRequest?.providerID.rawValue ?? "unknown"
            let sourceLength = ((currentRequest?.sourceText ?? "") as NSString).length
            logger.notice("Translation failure ignored; request_id=\(id.uuidString, privacy: .public); stage=result_ignored; provider=\(provider, privacy: .public); source_utf16_length=\(sourceLength, privacy: .public)")
            return
        }
        let request = pendingRequest
        apiTranslationTask = nil
        systemTranslationTask = nil
        clearPending()
        if error is CancellationError {
            logger.notice("Translation cancelled; request_id=\(id.uuidString, privacy: .public); stage=cancelled; provider=\(request?.providerID.rawValue ?? "unknown", privacy: .public); source_utf16_length=\(((request?.sourceText ?? "") as NSString).length, privacy: .public)")
            state = .ready
        } else {
            logger.error("Translation failed; request_id=\(id.uuidString, privacy: .public); stage=result; provider=\(request?.providerID.rawValue ?? "unknown", privacy: .public); source_utf16_length=\(((request?.sourceText ?? "") as NSString).length, privacy: .public)")
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
        systemTranslationTask?.cancel()
        systemTranslationTask = nil
        clearPending()
        state = .ready
    }

    private func clearPending() {
        cancelTranslationDeadline()
        clearSystemTranslationHost()
        pendingSnapshot?.zshTicket?.focusObservation.invalidate()
        pendingID = nil
        pendingSnapshot = nil
        pendingRequest = nil
        writebackStartedRequestID = nil
    }
}
