import InputMethodKit
import KEYITranslationClient
import KeyiIMETranslation

/// 翻译客户端归属与菜单：本会话的宿主输入框、⌃⌥T 开关、风格切换。
extension InputSession {
    /// 把「实际客户端对象是否变化」集中到一处判断。输入法对 `IMKTextInput` 只能按需
    /// 读取，没有选区变化通知；同一应用内换输入框时 IMK 也不保证先回调 deactivate。
    /// 因此每个会话入口都调用本方法：客户端对象变了就重新认领会话身份并让在途请求失效，
    /// 客户端消失则清除认领。同一对象重复进入不做任何事，避免打断在途请求。
    @discardableResult
    func syncTranslationClient(_ client: (any IMKTextInput)?) -> KeyiTranslationClientSurface? {
        guard let client else {
            if translationSurface != nil || translationSurfaceClient != nil {
                settleHeldForLeaving()
                translationSurface = nil
                translationSurfaceClient = nil
                translationGeneration &+= 1
                automaticTranslation.setActiveClient(nil)
            }
            return nil
        }
        if let existing = translationSurface,
           let bound = translationSurfaceClient,
           bound as AnyObject === client as AnyObject
        {
            return existing
        }
        // The previous field may still hold our marked text: put its Chinese there
        // before the controller moves on (it would otherwise abandon it).
        if translationSurfaceClient != nil { settleHeldForLeaving() }
        translationGeneration &+= 1
        let surface = KeyiSessionSurface(client: client) { [weak self] in self?.diagnosticSecureInput }
        translationSurface = surface
        translationSurfaceClient = client
        automaticTranslation.setSession(
            KeyiTranslationSession(id: translationGeneration, appIdentifier: surface.hostBundleIdentifier())
        )
        automaticTranslation.setActiveClient(surface)
        automaticTranslation.setEnabled(isAutomaticTranslationEnabled)
        return surface
    }

    /// 自动翻译开关：默认开启，存于独立偏好域，输入法菜单可随时暂停/恢复。
    @objc(keyiIsAutomaticTranslationEnabled)
    var isAutomaticTranslationEnabled: Bool {
        // 诊断隔离：`--diagnose-session` 用替身客户端批量驱动按键，若自动翻译仍
        // 指向真实翻译服务，就会在断言之间异步改写替身文档并让既有检查变得不确定。
        // 与 `KEYI_IME_USER_DATA_DIR` 同样的隔离思路，真实输入法进程从不设置它。
        if ProcessInfo.processInfo.environment["KEYI_IME_DISABLE_AUTOMATIC_TRANSLATION"] == "1" {
            return false
        }
        if KeyiDiagnosticFakeTranslator.isAllowed {
            return diagnosticAutomaticOverride ?? true
        }
        return UserDefaults.standard.object(forKey: Self.automaticTranslationPreferenceKey) as? Bool ?? true
    }

    /// 切换自动翻译并返回切换后的状态。暂停时立即放弃在途请求，中文输入照常。
    ///
    /// 与 ⌃⌥T 热键走同一条路径（`KeyiHotKeyManager.toggle()`），
    /// 由通知统一同步所有会话，菜单勾选与热键因此不可能互相矛盾。
    @objc(keyiToggleAutomaticTranslation)
    @discardableResult
    func toggleAutomaticTranslation() -> Bool {
        let enabled = KeyiHotKeyManager.toggle()
        MainActor.assumeIsolated {
            KeyiToastPanel.show(text: enabled ? "自动翻译：开" : "自动翻译：关")
        }
        return enabled
    }

    static let automaticTranslationPreferenceKey = "KEYIAutomaticTranslationEnabled"

    /// 输入法菜单「打开 KEYI 可译设置…」：打开 KEYI 可译的设置窗口。
    @objc(keyiOpenTranslationSettings)
    func openTranslationSettings() {
        MainActor.assumeIsolated {
            KeyiCompanionLauncher.openSettings()
        }
    }

    /// 输入法菜单里的翻译风格名，顺序与 `KEYITranslationStyle.allCases` 一致。
    /// 引擎名不再跟在每一项后面，而是写在所在分组的组名里（`translationStyleGroupTitles`）。
    @objc(keyiTranslationStyleTitles)
    var translationStyleTitles: [String] {
        KEYITranslationStyle.allCases.map(\.chineseName)
    }

    /// 每个风格属于哪一组：0 本机翻译，1 大模型 API。
    @objc(keyiTranslationStyleGroups)
    var translationStyleGroups: [NSNumber] {
        KEYITranslationStyle.allCases.map { NSNumber(value: $0.usesCloud ? 1 : 0) }
    }

    /// 两组的组名，写明此刻用的模型或服务名（KEYI 可译算好写进偏好域；还没写过时只写组名）：
    /// 「本机翻译 · Hy-MT2 · 文字不出本机」「大模型 API · DeepSeek」。
    @objc(keyiTranslationStyleGroupTitles)
    var translationStyleGroupTitles: [String] {
        let engines = KEYITranslationStyle.storedEngineLabels()
        let local = engines[.natural].map { "本机翻译 · \($0) · 文字不出本机" } ?? "本机翻译 · 文字不出本机"
        let cloud = engines[.americanCasual].map { "大模型 API · \($0)" } ?? "大模型 API"
        return [local, cloud]
    }

    @objc(keyiSelectedTranslationStyleIndex)
    var selectedTranslationStyleIndex: Int {
        let current = KEYITranslationStyle.stored() ?? .natural
        return KEYITranslationStyle.allCases.firstIndex(of: current) ?? 0
    }

    /// 选中后写进 KEYI 可译的偏好域；下一次预览或回车就按新风格翻。
    @objc(keyiSelectTranslationStyleAtIndex:)
    func selectTranslationStyle(at index: Int) {
        let styles = KEYITranslationStyle.allCases
        guard styles.indices.contains(index) else { return }
        let style = styles[index]
        KEYITranslationStyle.store(style)
        MainActor.assumeIsolated {
            KeyiToastPanel.show(text: "翻译风格：\(style.chineseName)")
        }
    }

    func resolvedClient(for sender: Any?) -> (any IMKTextInput)? {
        if let client = sender as? any IMKTextInput {
            return client
        }
        return activeClient
    }

    func ownsComposition(_ client: any IMKTextInput) -> Bool {
        guard let compositionClient else { return false }
        return compositionClient as AnyObject === client as AnyObject
    }

    /// Copies a client reference for comparison after a weak reference may
    /// have been released.
    func isSameClient(
        _ lhs: (any IMKTextInput)?,
        _ rhs: (any IMKTextInput)?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (left?, right?):
            return left as AnyObject === right as AnyObject
        default:
            return false
        }
    }
}
