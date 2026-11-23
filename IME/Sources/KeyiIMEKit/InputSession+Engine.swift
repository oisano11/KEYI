import InputMethodKit
import KEYITranslationClient
import KeyiIMEBridge
import KeyiIMETranslation

/// Rime 引擎接线：按键送进 librime、候选翻页与选择、按 App 学习的候选重排。
extension InputSession {
    /// Runs a key through the engine, honouring the diagnostics-only injected
    /// snapshot. Every composition-producing call goes through here so the
    /// injection point stays in one place.
    private func engineProcessKey(_ key: Int, modifiers: UInt) -> KeyiRimeResult {
        if let injected = diagnosticInjectedResult {
            diagnosticInjectedResult = nil
            return injected
        }
        return rimeSession.processKey(key, modifiers: modifiers)
    }

    @discardableResult
    func processKey(
        _ key: Int,
        modifiers: UInt,
        client: any IMKTextInput
    ) -> Bool {
        // 不带前缀的网址：打拼音时按 . 转出了什么记下来（InputSession+BareDomain）。
        guard let label = domainLabelBeingClosed(key: key, modifiers: modifiers, client: client) else {
            return processKeyInSession(key, modifiers: modifiers, client: client)
        }
        let heldBefore = automaticTranslation.heldText
        let continuing = domainLabelsUsable(for: client)
        keyCommitLog = ""
        let handled = processKeyInSession(key, modifiers: modifiers, client: client)
        let committed = keyCommitLog ?? ""
        keyCommitLog = nil
        if currentPreedit.isEmpty {
            recordDomainLabel(
                raw: label + ".",
                heldBefore: heldBefore,
                committed: committed,
                continuing: continuing,
                client: client
            )
        }
        return handled
    }

    private func processKeyInSession(
        _ key: Int,
        modifiers: UInt,
        client: any IMKTextInput
    ) -> Bool {
        // 英文后面的标点按英文出（用户 2026-11-08）；中文后面照旧交给 Rime 出中文标点。
        if let handled = typeEnglishPunctuationIfNeeded(key, modifiers: modifiers, client: client) {
            return handled
        }
        // Text is held and no pinyin is being typed: printable keys Rime does not
        // handle (space, digits, capitals, symbols) join the held sentence.
        if currentPreedit.isEmpty, automaticTranslation.isHolding, key >= 0x20, key <= 0x7e {
            let result = engineProcessKey(key, modifiers: modifiers)
            if result.handled { return apply(result, client: client) }
            guard let scalar = Unicode.Scalar(UInt32(key)) else { return false }
            return automaticTranslation.takeCommit(String(Character(scalar)))
        }
        // A composition in another client must not consume this client's keys.
        guard ownsComposition(client) else {
            if key == KeyiRimeKeyMapper.space
                || key == KeyiRimeKeyMapper.return
                || key == KeyiRimeKeyMapper.escape
                || key == KeyiRimeKeyMapper.tab
            {
                return false
            }
            // A fresh composition in this client starts now.
            return startOrContinueComposition(
                key: key,
                modifiers: modifiers,
                client: client
            )
        }

        // 正在打网址或邮箱（Rime recognizer，没有候选）：数字、= - ' 和其他符号照打进输入，不选候选、
        // 不翻页；空格和回车一样，把整段照打的样子上屏（有暂存段时并进去）。
        if KeyiPunctuationContext.isAddressInput(rimeSession.rawInput), modifiers & ~UInt(0b11) == 0 {
            if key == KeyiRimeKeyMapper.space {
                commitRawInput(client: client, joiningHeldSentence: true)
                return true
            }
            if key > 0x20, key <= 0x7e {
                return startOrContinueComposition(key: key, modifiers: modifiers, client: client)
            }
        }
        if let index = candidateIndex(forKey: key, modifiers: modifiers) {
            return selectCandidate(at: index, client: client)
        }

        switch key {
        case KeyiRimeKeyMapper.space:
            return selectHighlightedCandidate(client: client)
        case KeyiRimeKeyMapper.escape:
            clearComposition(updateClient: true, client: client)
            return true
        // = / - 翻页和苹果拼音、搜狗等一致（契约 11-05）；只在有候选时，没有拼音时照常输入。
        case KeyiRimeKeyMapper.pageDown, KeyiRimeKeyMapper.equal:
            return changePage(backward: false, client: client)
        case KeyiRimeKeyMapper.pageUp, KeyiRimeKeyMapper.minus:
            return changePage(backward: true, client: client)
        case KeyiRimeKeyMapper.tab:
            return moveHighlight(by: modifiers & 1 == 1 ? -1 : 1, client: client)
        case KeyiRimeKeyMapper.downArrow:
            return moveHighlight(by: 1, client: client)
        case KeyiRimeKeyMapper.upArrow:
            return moveHighlight(by: -1, client: client)
        case KeyiRimeKeyMapper.return:
            // Raw pinyin: keep what the user typed instead of swallowing it. While
            // text is held the letters join the sentence. 网址那一项高亮时照打的样子就是整段网址。
            if isDomainOffer(at: highlightedIndex) {
                acceptDomainOffer(client: client)
                return true
            }
            commitRawInput(client: client, joiningHeldSentence: true)
            return true
        case KeyiRimeKeyMapper.deleteForward:
            // Rime owns its own forward-delete keysym. Hand it to the engine and
            // adopt whatever it reports, so the engine and client never drift
            // apart; `apply` clears the marked text when the composition ends.
            return apply(
                engineProcessKey(key, modifiers: modifiers),
                client: client
            )
        default:
            return startOrContinueComposition(
                key: key,
                modifiers: modifiers,
                client: client
            )
        }
    }

    private func startOrContinueComposition(
        key: Int,
        modifiers: UInt,
        client: any IMKTextInput
    ) -> Bool {
        // Defensive: the engine holds one composition. If it still belongs to
        // another client, settle that composition into the client that actually
        // started it — never into the newly focused one. When the original owner
        // is gone, drop the state instead of writing pinyin into a stranger.
        if !ownsComposition(client), hasMarkedText || compositionClient != nil {
            settlePendingCompositionForNewClient(client)
        }
        let result = engineProcessKey(key, modifiers: modifiers)
        if result.handled, compositionClient == nil {
            compositionClient = client
        }
        return apply(result, client: client)
    }

    /// Resolves a pending composition because a different client is about to
    /// start typing. The pending text goes to the client that really owns it; if
    /// that owner no longer exists, the state is dropped rather than leaked into
    /// whichever window now has focus.
    func settlePendingCompositionForNewClient(
        _ client: any IMKTextInput
    ) {
        if let owner = compositionClient, !isSameClient(owner, client) {
            commitRawInput(client: owner)
            return
        }
        rimeSession.clear()
        resetCompositionState()
        KeyiCandidatePanel.hideForSession(owner: ownerIdentifier)
    }

    /// A Command/Control/Option shortcut is leaving for the focused application.
    /// Resolve the composition first so the released chord cannot strand a
    /// half-typed preedit in the document.
    func settleCompositionForPassThrough(client: any IMKTextInput) {
        guard rimeSession.ready else { return }
        if let owner = compositionClient {
            commitRawInput(client: owner)
        } else if hasMarkedText {
            clearComposition(updateClient: true, client: client)
        }
    }

    func apply(
        _ result: KeyiRimeResult,
        client: any IMKTextInput
    ) -> Bool {
        guard result.handled else {
            return false
        }

        // Order matters: consume the commit first, then adopt whatever new
        // context the engine produced. A commit never erases a fresh
        // composition that followed it.
        if let commit = result.commitText.map(stripAddressShownPrefix), !commit.isEmpty {
            diagnosticConfirmedCommit = commit
            Self.wordStats?.record(hanzi: KEYIDailyWordStats.hanziCount(in: commit))
            keyiAutomaticDebugLog("confirmed commit reaching automatic path utf16=\((commit as NSString).length)")
            // Confirmed Chinese is held by the automatic translation controller (and
            // drawn as marked text); it only comes back here when the controller
            // does not own it (translation off, secure field, no Chinese yet).
            if !automaticTranslation.takeCommit(commit) {
                commitToClient(commit, client: client)
            }
        }

        // The commit path releases ownership; a composition that survives the
        // commit (or starts in the same step) still belongs to this client.
        if !result.preedit.isEmpty {
            compositionClient = client
        }
        currentPreedit = result.preedit
        adoptCandidates(result, client: client)
        candidateCursor = result.cursorPosition == NSNotFound
            ? currentPreedit.utf16count
            : result.cursorPosition
        if !addressShownPrefix.isEmpty, !currentPreedit.isEmpty {
            // 网址里已经上屏的开头（github.）不再画；退格删进它时整段作废。
            let raw = rimeSession.rawInput
            if raw.hasPrefix(addressShownPrefix), raw.count > addressShownPrefix.count,
               currentPreedit.hasPrefix(addressShownPrefix)
            {
                currentPreedit = stripAddressShownPrefix(currentPreedit)
                candidateCursor = max(candidateCursor - addressShownPrefix.utf16count, 0)
            } else {
                rimeSession.clear()
                currentPreedit = ""
            }
        }

        if currentPreedit.isEmpty {
            // The engine dropped the composition without committing (for
            // example after a punctuation key). The marked text is redrawn without
            // the pinyin when the key finishes (`routeKey`), so no stale preedit
            // is left on screen.
            releaseCompositionOwnership()
            KeyiCandidatePanel.hideForSession(owner: ownerIdentifier)
            return true
        }
        // The marked text and the candidate window are drawn when the key finishes.
        return true
    }

    private func selectCandidate(
        at index: Int,
        client: any IMKTextInput
    ) -> Bool {
        if isDomainOffer(at: index) {
            acceptDomainOffer(client: client)
            return true
        }
        let result = selectVisible(displayIndex: index, client: client)
        if !result.handled {
            // The engine refused the selection; echo the raw input so the
            // keystroke is not lost.
            commitRawInput(client: client)
            return true
        }
        return apply(result, client: client)
    }

    private func selectHighlightedCandidate(
        client: any IMKTextInput
    ) -> Bool {
        if currentCandidates.indices.contains(highlightedIndex) {
            return selectCandidate(at: highlightedIndex, client: client)
        }
        let result = rimeSession.selectHighlightedCandidate()
        return apply(result, client: client)
    }

    private func changePage(
        backward: Bool,
        client: any IMKTextInput
    ) -> Bool {
        let result = rimeSession.changeCandidatePageBackward(backward)
        return apply(result, client: client)
    }

    private func moveHighlight(by delta: Int, client: any IMKTextInput) -> Bool {
        if displayOrder != nil {
            // A reordered page moves its own highlight; Rime's would walk Rime's order.
            let target = highlightedIndex + delta
            if currentCandidates.indices.contains(target) {
                highlightedIndex = target
                return true
            }
            return changePage(backward: target < 0, client: client)
        }
        let result = rimeSession.moveCandidateHighlight(delta)
        return apply(result, client: client)
    }

    /// Adopts Rime's page: English words placed by `mixedEnglishOrder`, then reordered by
    /// what the user picked in this app for this pinyin.
    private func adoptCandidates(_ result: KeyiRimeResult, client: any IMKTextInput) {
        let candidates = result.candidates
        let input = rimeSession.rawInput
        let english = Self.mixedEnglishOrder(candidates, input: input)
        let placed = english.map { $0.map { candidates[$0] } } ?? candidates
        let learned = learningApp(client).flatMap {
            Self.appLearning.order(placed, app: $0, input: input)
        }
        let composed = (learned ?? Array(placed.indices)).map { english?[$0] ?? $0 }
        let order: [Int]? = composed == Array(candidates.indices) ? nil : composed
        displayOrder = order
        currentCandidates = order.map { $0.map { candidates[$0] } } ?? candidates
        let rimeHighlight = result.highlightedCandidateIndex
        if let order {
            // A fresh page highlights the learned first word; a moved Rime highlight keeps its word.
            highlightedIndex = rimeHighlight == 0 ? 0 : (order.firstIndex(of: rimeHighlight) ?? 0)
        } else {
            highlightedIndex = rimeHighlight
        }
        placeDomainOffer(rimeCount: candidates.count, client: client)
    }

    /// 中英混输的摆法（规则见 `KeyiPinyinSyllables.mixedEnglishOrder`，iOS 键盘共用同一份）。
    /// 返回 `result[显示位置] = Rime 页内位置`，不用调整时为 nil。
    static func mixedEnglishOrder(_ candidates: [String], input: String) -> [Int]? {
        KeyiPinyinSyllables.mixedEnglishOrder(candidates, input: input)
    }

    /// Selects the candidate shown at `index` and remembers the pick for this app.
    func selectVisible(displayIndex index: Int, client: any IMKTextInput) -> KeyiRimeResult {
        let input = rimeSession.rawInput
        let word = currentCandidates[index]
        let choices = currentCandidates.count
        let result = rimeSession.selectVisibleCandidate(at: displayOrder?[index] ?? index)
        if result.handled, choices > 1, let app = learningApp(client) {
            Self.appLearning.record(app: app, input: input, word: word)
        }
        return result
    }

    /// The app whose picks are learned, or nil: no bundle identifier, a secure field, or
    /// the fixed diagnostics client.
    private func learningApp(_ client: any IMKTextInput) -> String? {
        guard let app = client.bundleIdentifier(), !app.isEmpty else { return nil }
        if KeyiPreferences.diagnosticsUserDataOverride != nil, app == Self.unlearnedDiagnosticApp { return nil }
        if translationSurface?.isSecureInputEnabled() == true { return nil }
        return app
    }

    private func candidateIndex(forKey key: Int, modifiers: UInt) -> Int? {
        // Only bare digits select candidates; Shift/Option/Caps chords stay
        // with the client.
        guard modifiers == 0 else { return nil }
        guard key >= 0x31, key <= 0x39 else { return nil }
        let index = key - 0x31
        return currentCandidates.indices.contains(index) ? index : nil
    }
}
