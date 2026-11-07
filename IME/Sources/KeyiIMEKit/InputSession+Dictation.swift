import AppKit
import InputMethodKit
import KEYITranslationClient
import KeyiIMETranslation

/// 语音输入的阶段：没在录、按住右 ⌥ 在听、松开后等识别定稿。
enum KeyiDictationPhase {
    case idle
    case listening
    case finishing
}

/// 语音输入（契约 2026-11-07）：没在打拼音时按住右 ⌥ 说话，松开定稿。
///
/// 说话时识别中的文字接在暂存段后面画成标记文字（带下划线），一个字一个字流出来（`KeyiDictationReveal`），
/// 识别改了已露出的字就原地换掉；松开后剩下的字很快露完，定稿的中文和确认的候选
/// 走同一条路（`takeCommit`），并进这段，之后回车换英文、Shift 保留中文都不变。按住时又按了别的键或
/// 别的修饰键就当组合键，丢弃这次；录音中输入框不归我们了也丢弃。
extension InputSession {
    static let dictationMaximumSeconds: TimeInterval = 120
    static let dictationFinishTimeout: TimeInterval = 3

    var isDictating: Bool { dictationPhase != .idle }

    /// flagsChanged 里语音输入的部分。事件本身照常交给应用（`handle` 从不吞 flagsChanged）。
    func handleDictationFlags(_ event: NSEvent, client sender: Any?) {
        let held = event.modifierFlags.intersection(KeyiDictationKey.modifiers)
        if let down = KeyiDictationKey.rightOptionIsDown(keyCode: event.keyCode, rawFlags: event.modifierFlags.rawValue) {
            // 只记修饰键证据（键码、标志位、阶段、宿主），不记文字：哪个宿主送没送右 ⌥、为什么没开始录。
            let host = (sender as? any IMKTextInput)?.bundleIdentifier() ?? "?"
            Self.logger.notice(
                "right option down=\(down, privacy: .public) flags=\(event.modifierFlags.rawValue, privacy: .public) phase=\(String(describing: self.dictationPhase), privacy: .public) host=\(host, privacy: .public)"
            )
            if down {
                switch dictationPhase {
                case .idle:
                    if held == .option { beginDictation(sender: sender) }
                case .listening:
                    // 有的宿主按住修饰键时会重复送按下：还是同一次。
                    break
                case .finishing:
                    settleDictationNow()
                    if held == .option { beginDictation(sender: sender) }
                }
            } else if dictationPhase == .listening {
                finishDictation()
            }
            return
        }
        guard dictationPhase == .listening else { return }
        // 按住右 ⌥ 时又动了别的修饰键：当组合键，丢弃这次说的话。
        cancelDictation(reason: "another modifier")
    }

    /// 有键按下（`routeKey` 开头）。按住右 ⌥ 时按的键是组合键：丢弃这次；松开后还在等定稿：
    /// 先把已识别的文字交出去，再处理这个键，说的话不丢。
    func settleDictationBeforeKey() {
        switch dictationPhase {
        case .idle:
            return
        case .listening:
            cancelDictation(reason: "key while holding")
        case .finishing:
            settleDictationNow()
        }
    }

    /// 输入框不归我们了（点到别处、切换窗口或输入法）：停止录音，说的话丢弃。
    func abandonDictation() {
        guard isDictating else { return }
        cancelDictation(reason: "left the field")
    }

    private func beginDictation(sender: Any?) {
        guard rimeSession.ready, currentPreedit.isEmpty else {
            Self.logger.notice("dictation not started: pinyin is being typed or Rime is not ready")
            return
        }
        // 有暂存时文字接在暂存段后面，用它所在的输入框；没有时用这次事件的输入框。
        let owner = automaticTranslation.isHolding ? (compositionClient ?? translationSurfaceClient) : nil
        guard let client = owner ?? resolvedClient(for: sender) else {
            Self.logger.notice("dictation not started: no text client")
            return
        }
        syncTranslationClient(client)
        if translationSurface?.isSecureInputEnabled() == true {
            Self.logger.notice("dictation not started: secure input")
            MainActor.assumeIsolated { KeyiToastPanel.show(text: "密码输入中不能语音输入", duration: 2) }
            return
        }
        guard let engine = (diagnosticFakeDictation as KeyiDictationEngine?) ?? KeyiDictationEngines.makeDefault() else {
            Self.logger.notice("dictation not started: no recognizer")
            return
        }
        dictationGeneration &+= 1
        let generation = dictationGeneration
        dictationPhase = .listening
        dictationEngine = engine
        dictationClient = client
        dictationLiveText = ""
        dictationReveal = KeyiDictationReveal()
        dictationRevealScheduled = false
        dictationFinalArrived = false
        dictationEngineInfo = nil
        Self.logger.notice("dictation begin holding=\(self.automaticTranslation.isHolding, privacy: .public)")
        anchorDictationPanel(client: client)
        showDictationPanel()
        let limit = DispatchWorkItem { [weak self] in
            guard let self, self.dictationGeneration == generation, self.dictationPhase == .listening else { return }
            Self.logger.notice("dictation reached the time limit")
            self.finishDictation()
        }
        dictationLimitWork = limit
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dictationMaximumSeconds, execute: limit)
        engine.start(
            onText: { [weak self] text in
                guard let self, self.dictationGeneration == generation, self.isDictating else { return }
                self.updateDictationLive(KeyiDictationText.normalized(text))
            },
            onEngine: { [weak self] info in
                guard let self, self.dictationGeneration == generation, self.isDictating else { return }
                self.dictationEngineInfo = info
                self.showDictationPanel()
                if let notice = info.notice {
                    MainActor.assumeIsolated { KeyiToastPanel.show(text: notice, duration: 2.6) }
                }
            },
            onFailure: { [weak self] failure in
                guard let self, self.dictationGeneration == generation else { return }
                self.cancelDictation(reason: "failure \(failure)")
                MainActor.assumeIsolated { KeyiToastPanel.show(text: failure.message, duration: 2.4) }
            }
        )
    }

    private func updateDictationLive(_ text: String) {
        dictationReveal.update(text)
        // 已露出的字识别改了：原地换掉，不等。
        showRevealedDictation()
        scheduleDictationReveal()
    }

    /// 排下一个字：积压越多隔得越短。露完时定稿已经到了就交出去。
    private func scheduleDictationReveal() {
        guard !dictationRevealScheduled, dictationReveal.backlog > 0 else { return }
        dictationRevealScheduled = true
        let generation = dictationGeneration
        let interval = dictationReveal.stepInterval(finishing: dictationPhase == .finishing)
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
            guard let self, self.dictationGeneration == generation, self.isDictating else { return }
            self.dictationRevealScheduled = false
            self.dictationReveal.step()
            self.showRevealedDictation()
            if self.dictationReveal.backlog > 0 {
                self.scheduleDictationReveal()
            } else if self.dictationFinalArrived {
                self.deliverDictation(self.dictationReveal.targetText)
            }
        }
    }

    private func showRevealedDictation() {
        let shown = dictationReveal.shown
        guard shown != dictationLiveText, let client = dictationClient else { return }
        dictationLiveText = shown
        redrawMarked(client: client)
        showDictationPanel()
    }

    private func finishDictation() {
        guard dictationPhase == .listening, let engine = dictationEngine else { return }
        dictationPhase = .finishing
        dictationLimitWork?.cancel()
        dictationLimitWork = nil
        let generation = dictationGeneration
        // 识别收尾一般不到 0.2 秒；万一卡住，过一会儿按已识别的文字定稿。
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dictationFinishTimeout) { [weak self] in
            guard let self, self.dictationGeneration == generation, self.dictationPhase == .finishing else { return }
            Self.logger.error("dictation finish timed out; using the live text")
            self.settleDictationNow()
        }
        engine.finish { [weak self] text in
            guard let self, self.dictationGeneration == generation, self.dictationPhase == .finishing else { return }
            // 定稿先接着流完剩下的字（最多零点几秒），露完再交出去。
            self.dictationFinalArrived = true
            self.dictationReveal.update(KeyiDictationText.normalized(text))
            self.showRevealedDictation()
            if self.dictationReveal.backlog == 0 {
                self.deliverDictation(self.dictationReveal.targetText)
            } else {
                self.scheduleDictationReveal()
            }
        }
    }

    /// 不等识别收尾、也不等字流完：按此刻已识别的整段定稿。
    private func settleDictationNow() {
        guard dictationPhase == .finishing else { return }
        let text = dictationReveal.targetText
        dictationEngine?.cancel()
        deliverDictation(text)
    }

    private func cancelDictation(reason: String) {
        guard isDictating else { return }
        Self.logger.notice("dictation cancelled reason=\(reason, privacy: .public)")
        let engine = dictationEngine
        let client = dictationClient
        endDictationState()
        engine?.cancel()
        // 去掉识别中的文字，暂存段原样留着。
        if let client, hasMarkedText { redrawMarked(client: client) }
        restorePanelAfterDictation()
    }

    private func endDictationState() {
        dictationGeneration &+= 1
        dictationPhase = .idle
        dictationEngine = nil
        dictationLiveText = ""
        dictationReveal = KeyiDictationReveal()
        dictationRevealScheduled = false
        dictationFinalArrived = false
        dictationEngineInfo = nil
        dictationLimitWork?.cancel()
        dictationLimitWork = nil
    }

    /// 定稿：和确认的候选走同一条路，并进下划线段；自动翻译关闭、密码输入或没有汉字时直接上屏。
    private func deliverDictation(_ text: String) {
        guard isDictating else { return }
        let client = dictationClient
        endDictationState()
        guard let client, isSameClient(client, translationSurfaceClient) else {
            // 输入框已经换了：什么都不写。
            restorePanelAfterDictation()
            return
        }
        Self.logger.notice("dictation delivered utf16=\(text.utf16count, privacy: .public)")
        keyDepth += 1
        automaticTranslation.beginUserInput()
        if !text.isEmpty {
            Self.wordStats?.record(hanzi: KEYIDailyWordStats.hanziCount(in: text))
            if !automaticTranslation.takeCommit(text) {
                commitToClient(text, client: client)
            }
        }
        automaticTranslation.finishUserInput(pinyin: currentPreedit)
        keyDepth -= 1
        if hasMarkedText || needsRedraw || automaticTranslation.isHolding {
            redrawMarked(client: client)
        }
        if automaticTranslation.isHolding { compositionClient = client }
        restorePanelAfterDictation()
    }

    // MARK: - 面板

    /// 还没有标记文字时，面板按输入框光标放；有了以后 `redrawMarked` 跟着标记文字的末尾走。
    private func anchorDictationPanel(client: any IMKTextInput) {
        let marked = client.markedRange()
        if marked.location != NSNotFound, marked.length > 0 { return }
        let selected = client.selectedRange()
        guard selected.location != NSNotFound else { return }
        var rect = NSRect.zero
        _ = client.attributes(forCharacterIndex: max(selected.location - 1, 0), lineHeightRectangle: &rect)
        let caret = KeyiPanelLayout.resolvedCaret(reported: rect, lastKnown: previewCaretRect)
        if KeyiPanelLayout.isUsableCaret(caret) {
            previewCaretRect = caret
            compositionStartRect = caret
        }
    }

    /// 「中」行是暂存段 + 识别中的文字，下一行「正在听…」，底栏写松开右 ⌥ 结束和这次用的识别引擎。
    private func showDictationPanel() {
        let source = automaticTranslation.heldText + dictationLiveText
        let engine = dictationEngineInfo
        let owner = ownerIdentifier
        let caret = previewCaretRect
        let start = compositionStartRect
        MainActor.assumeIsolated {
            KeyiCompositionPanel.shared.showPreview(
                .init(
                    source: source,
                    translation: nil,
                    hint: .enterConverts,
                    listening: true,
                    listeningEngine: engine?.name,
                    listeningCloud: engine?.isCloud ?? false
                ),
                caretRect: caret,
                startRect: start,
                owner: owner
            )
        }
    }

    /// 说完或取消后，面板回到自动翻译此刻的对照；没有可显示的就收起。
    private func restorePanelAfterDictation() {
        if !automaticTranslation.restoreOverlay() {
            KeyiTranslationPreviewPanel.hideForSession(owner: ownerIdentifier)
        }
    }
}
