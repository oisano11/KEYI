import InputMethodKit
import KeyiIMETranslation

/// 按键分流（自动翻译）：IMK 各个按键入口都走这里，有拼音交给 Rime，没拼音先给自动翻译控制器（空格、Esc 保留中文）；组合键离场。
extension InputSession {
    /// Every IMK key entry point (`handle`, both `inputText` callbacks and `command`)
    /// goes through here, so a key is routed identically whichever way the host
    /// delivers it (lesson of c6eccc3: Enter reaches the input method through several
    /// entry points and each must be covered).
    ///
    /// With no pinyin being typed, the key is classified and offered to the
    /// controller first (`handleKey`); with nothing held it always passes on. With pinyin, the key goes to Rime as before, except
    /// that Command/Control/Option chords commit held Chinese and the pinyin
    /// letters and then leave for the application.
    func routeKey(
        client: any IMKTextInput,
        keyCode: UInt16,
        rimeKey: Int?,
        flags: NSEvent.ModifierFlags,
        releasesToApplication: Bool = false,
        characters: String? = nil,
        automaticOverride: KeyiAutomaticTranslationKey? = nil,
        process: () -> Bool
    ) -> Bool {
        settleDictationBeforeKey()
        syncTranslationClient(client)
        // A composition belongs to the client it started in. A key from another
        // client (no activation callback in between) first settles the owner's whole
        // composition there, so the remaining preedit is never drawn into this one.
        settleForeignComposition(for: client)
        keyDepth += 1
        defer { keyDepth -= 1 }
        automaticTranslation.beginUserInput()
        let chord = KeyiRimeKeyMapper.shouldPassThrough(flags)
        // 不带前缀的网址：按完还在打拼音（打后缀、在候选上挪）、或是打拼音时的退格，都接着记下的几段；
        // 拼音结束了（选了字、回车、Esc、组合键…）就从头再记（InputSession+BareDomain）。
        keepsDomainLabels = false
        let backspaceInPinyin = !chord && rimeKey == KeyiRimeKeyMapper.backspace && !currentPreedit.isEmpty
        defer {
            if !keepsDomainLabels, currentPreedit.isEmpty, !backspaceInPinyin { domainLabels = [] }
        }
        var handled = false
        let kind = automaticOverride
            ?? (releasesToApplication
                ? .chord
                : KeyiRimeKeyMapper.automaticKey(keyCode: keyCode, rimeKey: rimeKey, characters: characters, flags: flags))
        let leavesForApplication = chord || releasesToApplication || kind == .chord
        if currentPreedit.isEmpty {
            if let kind {
                switch automaticTranslation.handleKey(kind) {
                case .consumed:
                    handled = true
                case .passOn:
                    if leavesForApplication {
                        // The controller has already committed any held Chinese.
                        settleCompositionForPassThrough(client: client)
                    } else {
                        handled = process()
                    }
                }
            } else {
                handled = chord ? false : process()
            }
        } else if Self.pinyinChordLeavesForApplication(
            chord: chord,
            releasesToApplication: releasesToApplication,
            kind: kind,
            hasRimeKey: rimeKey != nil,
            isHolding: automaticTranslation.isHolding
        ) {
            // Pinyin is being typed: held Chinese first, then the pinyin as letters.
            automaticTranslation.commitHeldAsChinese()
            settleCompositionForPassThrough(client: client)
        } else if rimeKey == nil, kind == .navigation, automaticTranslation.isHolding {
            // Home / End are inert while text is held.
            handled = true
        } else {
            handled = process()
        }
        if !handled {
            // 交给应用的键：标点前面是什么（InputSession+Punctuation）跟着它变。
            noteKeyLeftToApplication(
                rimeKey: rimeKey,
                characters: characters,
                chord: leavesForApplication,
                client: client
            )
        }
        automaticTranslation.finishUserInput(pinyin: currentPreedit)
        // The marked text (held sentences + pinyin) and the candidate window are drawn
        // once per key, after Rime and the controller have both settled.
        if hasMarkedText || needsRedraw || !currentPreedit.isEmpty || automaticTranslation.isHolding {
            redrawMarked(client: client)
        }
        if currentPreedit.isEmpty {
            KeyiCandidatePanel.hideForSession(owner: ownerIdentifier)
        } else {
            presentCandidates(client: client)
        }
        if automaticTranslation.isHolding { compositionClient = client }
        return handled
    }

    /// Whether a key typed while pinyin is being composed leaves for the application
    /// (held Chinese and the pinyin letters are committed first). Enter in any modifier
    /// combination is the exception while text is held: it behaves like plain Enter
    /// (the letters join the held sentence and the key is consumed), so ⌘↩ cannot send
    /// on the first press. With nothing held it keeps the long-standing chord behaviour.
    static func pinyinChordLeavesForApplication(
        chord: Bool,
        releasesToApplication: Bool,
        kind: KeyiAutomaticTranslationKey?,
        hasRimeKey: Bool,
        isHolding: Bool
    ) -> Bool {
        if kind == .enter, isHolding, hasRimeKey, !releasesToApplication { return false }
        return chord || releasesToApplication || (!hasRimeKey && kind == .chord && isHolding)
    }

    /// Settles a composition that still belongs to another client before this client's
    /// key is routed: held Chinese went there already (`syncTranslationClient`), the
    /// pinyin follows as letters. When the owner is gone the state is dropped.
    private func settleForeignComposition(for client: any IMKTextInput) {
        guard !ownsComposition(client), compositionClient != nil || !currentPreedit.isEmpty else { return }
        settlePendingCompositionForNewClient(client)
    }

    /// Commits held text into the field that owns it: the overlay's English when it
    /// is ready for the whole paragraph, otherwise the Chinese. Used wherever the field
    /// is about to stop being ours: IMK commitComposition, deactivate, client switch.
    func settleHeldForLeaving() {
        guard translationSurfaceClient != nil else { return }
        automaticTranslation.commitHeldForLeaving()
    }

    /// 修饰键事件只给按住说话键（语音输入）用，从不吞掉、也不交给 Rime。单按 Shift 不再保留中文
    /// （用户 2026-11-23 改成空格），Shift 只管大写。
    func handleFlagsChanged(_ event: NSEvent, client sender: Any?) {
        handleDictationFlags(event, client: sender)
    }

    func secondsSinceMouseDown(now: TimeInterval) -> TimeInterval {
        if diagnosticMouseOverride {
            return diagnosticMouseDownAt.map { now - $0 } ?? .infinity
        }
        let types: [CGEventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        return types
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? .infinity
    }
}
