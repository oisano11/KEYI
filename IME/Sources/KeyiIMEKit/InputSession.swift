import AppKit
import InputMethodKit
import KEYITranslationClient
import KeyiIMEBridge
import KeyiIMETranslation
import OSLog

/// Swift-owned input session. The Objective-C controller in
/// `KeyiIMEInputController` forwards InputMethodKit callbacks here; owning the
/// engine in Swift keeps the session logic testable and the controller free of
/// engine state.
///
/// Ownership rule: a composition belongs to the client it started in. Every
/// callback resolves its client through `resolveClient` and refuses to touch a
/// different one, so switching windows can never leak half-typed pinyin into
/// the newly focused field.
@objc(KeyiInputSession)
public final class InputSession: NSObject {
    static let logger = Logger(
        subsystem: "com.keyi.inputmethod.keyi",
        category: "InputSession"
    )

    let ownerIdentifier = UUID()
    let rimeSession: KeyiRimeSession

    /// The session that InputMethodKit most recently activated.
    weak var activeClient: (any IMKTextInput)?
    /// The client that owns the current composition, if any.
    weak var compositionClient: (any IMKTextInput)?

    /// Diagnostics-only seam. When set, `processKey` consumes this result
    /// instead of calling librime, so the session's own ordering rules can be
    /// driven by a controlled snapshot. It is always nil in the real input
    /// method: nothing outside the diagnostics target sets it.
    var diagnosticInjectedResult: KeyiRimeResult?

    var hasMarkedText = false {
        // 标记文本没了（发出、清掉、撤销）这段字就结束了，折行数跟着清零。Claude 发完消息后
        // 输入框清空，下一段字又从同一位置开始，不清零就把上一段的折行带过来，面板越摆越高。
        didSet {
            if !hasMarkedText {
                upwardWraps = 0
                wrapTracking = nil
            }
        }
    }
    var currentPreedit = ""
    var candidateCursor = 0
    var currentCandidates: [String] = []
    var highlightedIndex = 0
    /// 按 App 学到的页内显示顺序：`displayOrder[显示位置] = Rime 页内位置`；nil 为 Rime 原顺序。
    var displayOrder: [Int]?
    /// Set while this session is inside a remote `insertText`/`setMarkedText`
    /// call, so any re-entrant callback cannot start a second commit.
    var isDeliveringToClient = false

    // MARK: - 自动翻译

    /// KEYI 自动翻译：确认的中文留在输入法里（和拼音一起作为带下划线的标记文本），
    /// 句末或回车时整句换成英文上屏。控制器只决定“上屏什么、留下什么”，标记文本由本会话画。
    ///
    /// lazy：闭包需要捕获 `self`，而 `self` 在属性初始化阶段尚不可用。
    lazy var automaticTranslation: KeyiAutomaticTranslationController = makeAutomaticTranslation(
        translate: { [weak self] request, completion in
            // Diagnostics-only seam: `diagnosticFakeTranslator` is nil in the real input method.
            if let fake = self?.diagnosticFakeTranslator {
                return fake.translate(request, completion: completion)
            }
            return KEYITranslationAdapter.shared.translate(request, completion: completion)
        }
    )
    /// 控制器弱引用它的接收者，所以由会话持有。
    private lazy var automaticSink = KeyiSessionTranslationSink(session: self)
    /// 本次按键事件的嵌套深度。按键内的改动留到按键结束时统一重画；按键外（译文迟到、
    /// 菜单开关）的改动立刻重画。
    var keyDepth = 0
    /// Diagnostics-only: the fake translator and the secure-input / enabled answers. All
    /// nil in the real input method; see `diagnosticFakeCommand`.
    var diagnosticFakeTranslator: KeyiDiagnosticFakeTranslator?
    var diagnosticSecureInput: Bool?
    var diagnosticAutomaticOverride: Bool?
    /// Diagnostics-only: when set, mouse-down times come from `mouse:down` commands
    /// instead of the system, so the Shift-tap checks do not depend on the machine.
    var diagnosticMouseOverride = false
    var diagnosticMouseDownAt: TimeInterval?
    /// 单按 Shift 保留中文。
    var shiftTap = KeyiShiftTap()
    /// 标记文本里我们最近一次画出的暂存句子。与控制器此刻的暂存文字不一致时，按键结束会重画。
    var drawnHeldText = ""
    /// 控制器在本次按键里改了上屏或暂存文字，按键结束时重画标记文本。
    var needsRedraw = false

    // MARK: - 语音输入（按住右 ⌥ 说话，见 InputSession+Dictation）

    var dictationPhase = KeyiDictationPhase.idle
    var dictationEngine: KeyiDictationEngine?
    /// 识别中、已经露出来的文字，画在暂存段后面；定稿或取消后清空。
    var dictationLiveText = ""
    /// 最新识别的整段与露出了几个字（逐字流出）。
    var dictationReveal = KeyiDictationReveal()
    /// 下一个字已经排上了。
    var dictationRevealScheduled = false
    /// 松开后的定稿已经到了，露完就交出去。
    var dictationFinalArrived = false
    /// 这次录音用的识别引擎（面板底栏写它）。
    var dictationEngineInfo: KeyiDictationEngineInfo?
    weak var dictationClient: (any IMKTextInput)?
    /// 每次开始、结束都递增；过时的识别回调不再起作用。
    var dictationGeneration: UInt = 0
    var dictationLimitWork: DispatchWorkItem?
    /// Diagnostics-only: replaces the microphone and the recognizer (`dictation:` commands).
    var diagnosticFakeDictation: KeyiDiagnosticFakeDictation?

    /// 每日字数统计；诊断时用一次性目录，不写进用户自己的统计。
    static let wordStats: KEYIDailyWordStats? =
        KeyiPreferences.diagnosticsUserDataOverride == nil ? .shared : nil

    /// 按 App 的候选学习；诊断时只在内存里学，不碰用户自己的记录。
    static let appLearning: KEYIAppCandidateLearning =
        KeyiPreferences.diagnosticsUserDataOverride == nil ? .shared : KEYIAppCandidateLearning(fileURL: nil)
    /// 固定的诊断替身客户端不学：前面检查选过的词不能改变后面检查看到的候选顺序。
    static let unlearnedDiagnosticApp = "com.keyi.inputmethod.keyi.diagnostic"

    private func makeAutomaticTranslation(
        translate: @escaping KeyiAutomaticTranslationController.TranslateFunction
    ) -> KeyiAutomaticTranslationController {
        let controller = KeyiAutomaticTranslationController(
            translate: translate,
            onFailure: { failure in
                // 失败不再静默：提示原因，连不上伴随服务时在后台拉起 KEYI 可译。
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { KeyiTranslationFeedback.report(failure) }
                }
            },
            preview: { [weak self, owner = self.ownerIdentifier] source, translation, hint in
                // 主队列上由控制器回调；浮层只展示、不接收输入。
                InputSession.presentPreview(
                    source: source,
                    translation: translation,
                    hint: hint,
                    owner: owner,
                    session: self
                )
            }
        )
        controller.sink = automaticSink
        controller.wordStats = Self.wordStats
        // 本机风格确认即译、不等停手；大模型 API 风格每次请求计费，仍等停手（2026-11-05 合同）。
        controller.previewWaitsForPause = { (KEYITranslationStyle.stored() ?? .natural).usesCloud }
        return controller
    }
    /// 最近一次已知的光标矩形，用作对照浮层的锚点。
    var previewCaretRect: NSRect = .zero
    /// 正在打的这段字第一个字所在的行，每次重问宿主；面板据此让开整段字占的行。
    var compositionStartRect: NSRect = .zero
    /// 往上长高的输入框里光标折回的次数（`KeyiPanelLayout.isUpwardWrap`），按这段字的
    /// 开头位置（marked range 的 location）记；换了一段字就重新数。
    var upwardWraps = 0
    var wrapTracking: (location: Int, caret: NSRect, extent: ClosedRange<CGFloat>)?
    /// 每次重画递增；过时的延后重问不再执行。
    var anchorRecheckGeneration: UInt = 0
    /// 重画后隔多久再问位置（秒）：一次赶上通常的排版，一次兜住慢的。
    static let anchorRecheckDelays: [TimeInterval] = [0.08, 0.3]

    /// 当前认领的客户端包装。输入法对 `IMKTextInput` 只能按需读取，没有选区变化
    /// 通知，因此用包装对象身份 + 递增 generation 表达「输入会话变化 → 在途请求失效」。
    weak var translationSurfaceClient: (any IMKTextInput)?
    var translationSurface: KeyiSessionSurface?
    /// 每次重新认领客户端即递增，作为自动翻译控制器的会话身份。
    var translationGeneration: UInt = 0
    /// Diagnostics-only: records the text handed to automatic translation so the
    /// orchestrator can assert the production commit path is still wired. Never
    /// read by the input method itself.
    var diagnosticConfirmedCommit: String?

    public override init() {
        KeyiPreferences.registerDefaults()
        let sharedDataPath = Bundle.main.resourceURL?
            .appendingPathComponent("RimeData", isDirectory: true).path ?? ""
        let userDataPath = KeyiPreferences.rimeUserDataURL.path
        rimeSession = KeyiRimeSession(
            sharedDataPath: sharedDataPath,
            userDataPath: userDataPath,
            schemaIdentifier: "keyi_pinyin"
        )
        rimeSession.setCandidatePageSize(KeyiPreferences.candidatePageSize)
        super.init()
        if !rimeSession.ready {
            Self.logger.error(
                "Rime session unavailable: \(self.rimeSession.errorMessage, privacy: .public)"
            )
        } else {
            Self.logger.notice(
                "Rime session ready version=\(self.rimeSession.version, privacy: .public)"
            )
        }
        // 全局开关（⌃⌥T）切换时，所有存活会话同步控制器状态，
        // 保证菜单/热键与真实行为始终一致。
        NotificationCenter.default.addObserver(
            forName: KeyiHotKeyManager.didToggleNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let enabled = note.userInfo?["enabled"] as? Bool
            else { return }
            self.automaticTranslation.setEnabled(enabled)
        }
    }

    deinit {
        // IMK 也可能不经 deactivateServer 就释放会话。候选窗与对照浮层由整个输入法进程
        // 共用，只有显示它的会话能收起；会话没了就再没人收，所以离开前收起自己留下的。
        let owner = ownerIdentifier
        dictationEngine?.cancel()
        DispatchQueue.main.async {
            KeyiTranslationPreviewPanel.hideForSession(owner: owner)
            KeyiCandidatePanel.hideForSession(owner: owner)
        }
    }

    // MARK: - InputMethodKit callbacks

    @objc(keyiActivateWithClient:)
    func activate(client sender: Any?) {
        guard let client = sender as? any IMKTextInput else {
            Self.logger.debug("Activation without a text client")
            return
        }
        // 录音中换了输入框：停止录音，说的话丢弃。
        if isDictating, !isSameClient(dictationClient, client) {
            abandonDictation()
        }
        // 焦点换到另一个输入框：暂存的中文先原样上屏到它所在的输入框（之后控制器才换客户端）。
        if let bound = translationSurfaceClient, !isSameClient(bound, client) {
            settleHeldForLeaving()
        }
        // InputMethodKit reuses one controller per input session, so an
        // activation that names a different client means focus moved. Resolve
        // any pending composition into the client that actually owns it — which
        // is not necessarily `activeClient`, because keys can arrive without an
        // activation (for example after the user clicks straight into a field).
        if let owner = compositionClient, !isSameClient(owner, client) {
            commitPendingComposition(client: owner)
        } else if compositionClient == nil, hasMarkedText, let previous = activeClient,
                  !isSameClient(previous, client)
        {
            // No owner survived but the client still shows our marked text.
            clearComposition(updateClient: true, client: previous)
        }
        if let pending = compositionClient, !isSameClient(pending, client) {
            // The owner could not be reached; drop the state rather than
            // letting it hang over the newly focused client.
            clearComposition()
        }
        activeClient = client
        // 认领本会话的翻译客户端；换输入框即刻作废旧请求，旧结果不再写回。
        syncTranslationClient(client)
        // ⌃⌥T 只在有 KEYI 输入会话处于激活状态时占用。
        KeyiHotKeyManager.shared.sessionDidActivate(self)
        Self.logger.debug("Input session activated")
    }

    @objc(keyiDeactivateWithClient:)
    func deactivate(client sender: Any?) {
        if isDeliveringToClient {
            // A re-entrant deactivation triggered by our own insertText must
            // not commit a second time.
            Self.logger.debug("Ignoring re-entrant deactivation")
            return
        }
        shiftTap.cancel()
        abandonDictation()
        settleHeldForLeaving()
        if let client = resolvedClient(for: sender) {
            commitPendingComposition(client: client)
        } else {
            clearComposition()
        }
        if let senderClient = sender as? any IMKTextInput,
           activeClient as AnyObject? === senderClient as AnyObject
        {
            activeClient = nil
        } else if sender == nil {
            activeClient = nil
        }
        // 会话结束：清除认领，任何在途结果都必须失效。
        syncTranslationClient(nil)
        KeyiHotKeyManager.shared.sessionDidDeactivate(self)
        Self.logger.debug("Input session deactivated")
    }

    @objc(keyiCommitWithClient:)
    func commit(client sender: Any?) {
        guard !isDeliveringToClient else { return }
        abandonDictation()
        settleHeldForLeaving()
        if let client = resolvedClient(for: sender) {
            commitPendingComposition(client: client)
        } else {
            clearComposition()
        }
    }

    @objc(keyiRecognizedEventsForClient:)
    func recognizedEvents(client _: Any?) -> UInt {
        // flagsChanged only for the Shift tap and holding right Option to talk; it is
        // never consumed or sent to Rime.
        UInt(NSEvent.EventTypeMask.keyDown.rawValue | NSEvent.EventTypeMask.flagsChanged.rawValue)
    }

    @objc(keyiHandleEvent:client:)
    func handle(event: NSEvent?, client sender: Any?) -> Bool {
        if let event, event.type == .flagsChanged {
            handleFlagsChanged(event, client: sender)
            return false
        }
        guard rimeSession.ready,
              let event,
              event.type == .keyDown,
              let client = resolvedClient(for: sender)
        else {
            return false
        }
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
        let typed = KeyiRimeKeyMapper.typedCharacters(
            characters: event.characters,
            ignoringModifiers: event.charactersIgnoringModifiers,
            flags: flags
        )
        let rimeKey = KeyiRimeKeyMapper.rimeKey(
            keyCode: event.keyCode,
            characters: typed
        )
        return routeKey(
            client: client,
            keyCode: event.keyCode,
            rimeKey: rimeKey,
            flags: flags,
            characters: typed
        ) {
            // Keys without a Rime mapping (Home, End, function keys) are
            // classified above; whatever is left belongs to the application.
            guard let rimeKey else { return false }
            return self.processKey(
                rimeKey,
                modifiers: UInt(KeyiRimeKeyMapper.rimeModifiers(for: flags)),
                client: client
            )
        }
    }

    @objc(keyiInputText:client:)
    func inputSimpleText(_ string: String?, client sender: Any?) -> Bool {
        // `inputText:client:` carries no modifier flags; read them the same way
        // the controller does so all three input callbacks agree on pass-through.
        guard let client = resolvedClient(for: sender),
              let string,
              !string.isEmpty,
              rimeSession.ready
        else {
            return false
        }
        let flags = KeyiRimeKeyMapper.currentModifierFlags()
        let rimeKey = KeyiRimeKeyMapper.rimeKey(keyCode: UInt16.max, characters: string)
        return routeKey(
            client: client,
            keyCode: UInt16.max,
            rimeKey: rimeKey,
            flags: flags,
            characters: string
        ) {
            var handled = false
            for scalar in string.unicodeScalars where scalar.isASCII {
                handled = self.processKey(
                    Int(scalar.value),
                    modifiers: UInt(KeyiRimeKeyMapper.rimeModifiers(for: flags)),
                    client: client
                ) || handled
            }
            return handled
        }
    }

    @objc(keyiInputText:key:modifiers:client:)
    func inputDetailedText(
        _ string: String?,
        key keyCode: Int,
        modifiers flags: UInt,
        client sender: Any?
    ) -> Bool {
        let eventFlags = NSEvent.ModifierFlags(rawValue: flags)
            .intersection(.deviceIndependentFlagsMask)
        guard let client = resolvedClient(for: sender),
              rimeSession.ready
        else {
            return false
        }
        let code = UInt16(truncatingIfNeeded: keyCode)
        let rimeKey = KeyiRimeKeyMapper.rimeKey(keyCode: code, characters: string)
        return routeKey(
            client: client,
            keyCode: code,
            rimeKey: rimeKey,
            flags: eventFlags,
            characters: string
        ) {
            guard let rimeKey else { return false }
            return self.processKey(
                rimeKey,
                modifiers: UInt(KeyiRimeKeyMapper.rimeModifiers(for: eventFlags)),
                client: client
            )
        }
    }

    @objc(keyiCommandNamed:client:)
    func command(_ selectorName: String, client sender: Any?) -> Bool {
        // Commands are the platform's own editing shortcuts. macOS may deliver
        // Backspace or Return as editing commands (`deleteBackward:`,
        // `insertNewline:`) instead of key events, so they take the same route
        // as every other key entry point.
        let rimeKey: Int?
        var modifiers: UInt = 0
        var navigationCommand = false
        switch selectorName {
        case "deleteBackward:":
            rimeKey = KeyiRimeKeyMapper.backspace
        case "deleteForward:":
            rimeKey = KeyiRimeKeyMapper.deleteForward
        case "insertNewline:", "insertLineBreak:", "insertParagraph:":
            rimeKey = KeyiRimeKeyMapper.return
        case "insertTab:":
            rimeKey = KeyiRimeKeyMapper.tab
        case "insertBacktab:":
            rimeKey = KeyiRimeKeyMapper.tab
            modifiers = 1
        case "cancelOperation:":
            rimeKey = KeyiRimeKeyMapper.escape
        case "moveLeft:":
            rimeKey = KeyiRimeKeyMapper.leftArrow
        case "moveRight:":
            rimeKey = KeyiRimeKeyMapper.rightArrow
        case "moveDown:":
            rimeKey = KeyiRimeKeyMapper.downArrow
        case "moveUp:":
            rimeKey = KeyiRimeKeyMapper.upArrow
        case "pageUp:", "scrollPageUp:":
            rimeKey = KeyiRimeKeyMapper.pageUp
        case "pageDown:", "scrollPageDown:":
            rimeKey = KeyiRimeKeyMapper.pageDown
        case "moveToBeginningOfLine:", "moveToEndOfLine:",
             "moveToBeginningOfDocument:", "moveToEndOfDocument:",
             "scrollToBeginningOfDocument:", "scrollToEndOfDocument:":
            // Home / End: inert while text is held, otherwise an application command.
            rimeKey = nil
            navigationCommand = true
        default:
            // Word-wise deletion, copy:, cut:, paste:, selectAll:, undo:, redo: and
            // every other application command stay with the client. Any composition
            // is settled first, exactly like a Command/Control chord.
            rimeKey = nil
        }
        guard let client = resolvedClient(for: sender), rimeSession.ready else {
            return false
        }
        return routeKey(
            client: client,
            keyCode: UInt16.max,
            rimeKey: rimeKey,
            flags: [],
            releasesToApplication: rimeKey == nil,
            automaticOverride: navigationCommand ? .navigation : nil
        ) {
            guard let rimeKey else { return false }
            return self.processKey(rimeKey, modifiers: modifiers, client: client)
        }
    }

    @objc(keyiHidePalettes)
    func hidePalettes() {
        KeyiCandidatePanel.hideForSession(owner: ownerIdentifier)
    }
}

extension String {
    /// UTF-16 length, which is the unit AppKit uses for marked ranges.
    var utf16count: Int { (self as NSString).length }
}
