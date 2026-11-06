import InputMethodKit

/// 文字上屏与组字状态收尾：提交给宿主、清空标记文字、释放归属、显示候选。
extension InputSession {
    /// Sends committed text to the client exactly once, guarding against the
    /// re-entrant callbacks that a remote `insertText` can trigger.
    func commitToClient(_ text: String, client: any IMKTextInput) {
        guard !isDeliveringToClient else { return }
        // Resolve the range this commit replaces before resetting state, so the
        // insertion point never moves as a side effect of clearing.
        let markedRange = client.markedRange()
        // Drop the composition state before touching the client so a callback
        // arriving during insertText cannot see a half-committed composition.
        resetCompositionState()
        isDeliveringToClient = true
        defer { isDeliveringToClient = false }
        // IMK replacement-range semantics: when the client still holds our
        // marked text, the commit replaces exactly that range. Clearing the
        // marked text with a separate empty setMarkedText first would relocate
        // the insertion point and can deliver the text twice.
        client.insertText(text, replacementRange: markedRange)
        KeyiCandidatePanel.hideForSession(owner: ownerIdentifier)
    }

    /// Commits the pinyin letters. With `joiningHeldSentence` (Enter while typing
    /// pinyin) the letters join the held sentence when the controller owns it.
    func commitRawInput(client: any IMKTextInput, joiningHeldSentence: Bool = false) {
        let rawInput = rimeSession.rawInput
        if rawInput.isEmpty {
            clearComposition(updateClient: true, client: client)
            return
        }
        if joiningHeldSentence {
            rimeSession.clear()
            releaseCompositionOwnership()
            if automaticTranslation.takeCommit(rawInput) { return }
            commitToClient(rawInput, client: client)
            return
        }
        commitToClient(rawInput, client: client)
        rimeSession.clear()
    }

    func commitPendingComposition(client: any IMKTextInput) {
        guard ownsComposition(client), hasMarkedText else {
            return
        }
        commitRawInput(client: client)
    }

    func clearComposition(
        updateClient: Bool = false,
        client: (any IMKTextInput)? = nil
    ) {
        rimeSession.clear()
        if updateClient, let client {
            // Redraws what stays: the held sentences, or nothing.
            currentPreedit = ""
            redrawMarked(client: client)
        }
        resetCompositionState()
        KeyiCandidatePanel.hideForSession(owner: ownerIdentifier)
    }

    func resetCompositionState() {
        currentPreedit = ""
        currentCandidates = []
        displayOrder = nil
        highlightedIndex = 0
        candidateCursor = 0
        hasMarkedText = false
        drawnHeldText = ""
        compositionClient = nil
    }

    func releaseCompositionOwnership() {
        currentPreedit = ""
        currentCandidates = []
        displayOrder = nil
        highlightedIndex = 0
        candidateCursor = 0
        compositionClient = nil
    }

    func presentCandidates(client: any IMKTextInput, recheck: Bool = true) {
        let items = currentCandidates.map {
            KeyiCandidateItem(text: $0, comment: nil)
        }
        // Anchor the panel to the caret inside the marked text when the client
        // can report it, so the window follows the insertion point instead of a
        // fixed index. When there is no marked range the client's own selection
        // is the caret; the document start is never a valid fallback because it
        // would park the window at the top of the document.
        var lineRect = NSRect.zero
        let markedRange = client.markedRange()
        let anchorIndex: Int
        compositionStartRect = .zero
        var reportedStart = NSRect.zero
        if markedRange.location != NSNotFound, markedRange.length > 0 {
            reportedStart = Self.lineRect(client: client, index: markedRange.location)
            // The marked text is the held sentences followed by the pinyin.
            anchorIndex = markedRange.location + min(
                max(automaticTranslation.heldText.utf16count + candidateCursor - 1, 0),
                markedRange.length - 1
            )
        } else {
            let selectedRange = client.selectedRange()
            anchorIndex = selectedRange.location == NSNotFound
                ? NSNotFound
                : max(selectedRange.location - 1, 0)
        }
        guard anchorIndex != NSNotFound else {
            KeyiCandidatePanel.showForSession(
                preedit: currentPreedit,
                items: items,
                highlightedIndex: highlightedIndex,
                caretRect: .zero,
                owner: ownerIdentifier
            )
            return
        }
        _ = client.attributes(
            forCharacterIndex: anchorIndex,
            lineHeightRectangle: &lineRect
        )
        if !KeyiPanelLayout.isUsableCaret(lineRect) {
            Self.logger.info("caret unavailable; reusing last caret usable=\(KeyiPanelLayout.isUsableCaret(self.previewCaretRect), privacy: .public)")
        }
        lineRect = KeyiPanelLayout.resolvedCaret(reported: lineRect, lastKnown: previewCaretRect)
        // 对照浮层复用同一锚点，显示在光标下方。
        if KeyiPanelLayout.isUsableCaret(lineRect) { previewCaretRect = lineRect }
        if markedRange.location != NSNotFound, markedRange.length > 0 {
            compositionStartRect = startRect(reported: reportedStart, marked: markedRange, caret: lineRect)
        }
        KeyiCandidatePanel.showForSession(
            preedit: currentPreedit,
            items: items,
            highlightedIndex: highlightedIndex,
            caretRect: lineRect,
            startRect: compositionStartRect,
            owner: ownerIdentifier
        )
        if recheck { scheduleAnchorRecheck(client: client) }
    }
}
