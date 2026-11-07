import InputMethodKit
import KeyiIMETranslation

/// 按键分流（自动翻译）：IMK 各个按键入口都走这里，有拼音交给 Rime，没拼音先给自动翻译控制器；单按 Shift、组合键离场。
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
        shiftTap.cancel()
        syncTranslationClient(client)
        // A composition belongs to the client it started in. A key from another
        // client (no activation callback in between) first settles the owner's whole
        // composition there, so the remaining preedit is never drawn into this one.
        settleForeignComposition(for: client)
        keyDepth += 1
        defer { keyDepth -= 1 }
        automaticTranslation.beginUserInput()
        let chord = KeyiRimeKeyMapper.shouldPassThrough(flags)
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

    /// 单按 Shift（按下又松开，中间没有别的键、修饰键或鼠标点击）：有暂存且没在打拼音时，
    /// 和 Esc 一样把中文原样上屏。事件本身照常交给应用。
    func handleFlagsChanged(_ event: NSEvent, client sender: Any?) {
        // 按住右 ⌥ 说话（语音输入）；Shift 单按的判定照常看同一个事件。
        handleDictationFlags(event, client: sender)
        let now = ProcessInfo.processInfo.systemUptime
        let tapped = shiftTap.flagsChanged(
            keyCode: event.keyCode,
            flags: event.modifierFlags.intersection(.deviceIndependentFlagsMask),
            now: now
        ) { self.secondsSinceMouseDown(now: now) }
        if event.keyCode == KeyiShiftTap.leftShift || event.keyCode == KeyiShiftTap.rightShift {
            // Modifier evidence only (no characters): which host sent which Shift edge,
            // so a host where the tap never completes can be told apart from one that
            // never delivers flagsChanged at all.
            let host = (sender as? any IMKTextInput)?.bundleIdentifier() ?? "?"
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
            Self.logger.notice(
                "shift flags key=\(event.keyCode, privacy: .public) flags=\(flags, privacy: .public) tapped=\(tapped, privacy: .public) host=\(host, privacy: .public)"
            )
        }
        guard tapped, rimeSession.ready else { return }
        // A modifier-only event may arrive with a different client proxy than the
        // letters did, so it acts on the field that owns the composition (or the held
        // text). Comparing the sender's identity would make the tap silently do nothing,
        // or look like a field switch.
        let sent = resolvedClient(for: sender)
        let owner = compositionClient ?? translationSurfaceClient
        Self.logger.notice(
            "shift tap pinyin=\(!self.currentPreedit.isEmpty, privacy: .public) holding=\(self.automaticTranslation.isHolding, privacy: .public) owner=\(owner != nil, privacy: .public) sameSender=\(self.isSameClient(owner, sent), privacy: .public)"
        )
        guard let client = owner ?? sent else { return }
        if currentPreedit.isEmpty {
            guard automaticTranslation.isHolding else { return }
            _ = routeKey(
                client: client,
                keyCode: event.keyCode,
                rimeKey: nil,
                flags: [],
                automaticOverride: .escape
            ) { false }
            return
        }
        // Pinyin is being typed: the tap turns it into Chinese (the highlighted
        // candidate) and commits it with everything held, untranslated. With
        // automatic translation off Shift stays an ordinary modifier.
        guard isAutomaticTranslationEnabled, compositionClient != nil else { return }
        // `.escape` keeps routeKey off the chord path (which would commit the
        // pinyin as letters); the closure does the work inside the key scope.
        _ = routeKey(
            client: client,
            keyCode: event.keyCode,
            rimeKey: nil,
            flags: [],
            automaticOverride: .escape
        ) {
            commitPinyinAndHeldAsChinese(client: client)
            return true
        }
    }

    /// Shift tap during pinyin: confirms the highlighted candidate (again while Rime
    /// leaves pinyin unconverted), then commits all held Chinese as it is. When Rime
    /// can select no further (`nihaov`: 你好 selected, `v` left), the rest is committed
    /// the way Rime shows it, so the selected Chinese stays and only the leftover
    /// letters go in as typed. The raw input would lose the selected Chinese.
    private func commitPinyinAndHeldAsChinese(client: any IMKTextInput) {
        var rounds = 0
        while !currentPreedit.isEmpty, rounds < 16 {
            rounds += 1
            let before = currentPreedit
            let result = currentCandidates.indices.contains(highlightedIndex)
                ? selectVisible(displayIndex: highlightedIndex, client: client)
                : rimeSession.selectHighlightedCandidate()
            guard result.handled else { break }
            _ = apply(result, client: client)
            if currentPreedit == before { break }
        }
        if !currentPreedit.isEmpty {
            let result = rimeSession.commitComposition()
            if result.handled, result.commitText?.isEmpty == false {
                _ = apply(result, client: client)
            }
            if !currentPreedit.isEmpty {
                commitRawInput(client: client, joiningHeldSentence: true)
            }
        }
        automaticTranslation.commitHeldAsChinese()
    }

    private func secondsSinceMouseDown(now: TimeInterval) -> TimeInterval {
        if diagnosticMouseOverride {
            return diagnosticMouseDownAt.map { now - $0 } ?? .infinity
        }
        let types: [CGEventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        return types
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? .infinity
    }
}
