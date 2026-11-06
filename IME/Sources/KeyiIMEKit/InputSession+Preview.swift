import InputMethodKit
import KeyiIMETranslation

/// 标记文字重画与光标旁面板定位：自动翻译的渲染结果落到输入框和面板，光标位置拿不准时按节奏复查。
extension InputSession {
    /// 对照浮层的唯一出口。收起只凭会话的 UUID，不依赖会话还活着：切换输入法时 IMK 先
    /// deactivateServer，随即可能释放这个会话，若等到主队列执行时会话已不在就跳过收起，
    /// 浮层会一直停在“翻译中…”（10-05 用户实测：切到英文输入后浮层仍在）。展示需要会话
    /// 的光标位置，会话已不在就不再展示。
    static func presentPreview(
        source: String,
        translation: String?,
        hint: KeyiAutomaticTranslationHint,
        owner: UUID,
        session: InputSession?
    ) {
        DispatchQueue.main.async { [weak session] in
            if source.isEmpty {
                KeyiTranslationPreviewPanel.hideForSession(owner: owner)
            } else if let session {
                KeyiTranslationPreviewPanel.updateForSession(
                    source: source,
                    translation: translation,
                    hint: hint,
                    caretRect: session.previewCaretRect,
                    startRect: session.compositionStartRect,
                    owner: owner
                )
            }
        }
    }

    /// Receives the controller's renders (`sink`). Inside a key event only the commit is
    /// written; the marked text is drawn once, when the key finishes, because the
    /// session's own pinyin is not final until then. Outside a key event (a late
    /// translation, the ⌃⌥T toggle) everything is drawn here.
    func applyAutomaticRender(_ render: KeyiAutomaticTranslationRender) {
        switch render {
        case .abandon:
            // The client no longer holds our held text; write nothing and forget it.
            drawnHeldText = ""
            hasMarkedText = false
            needsRedraw = true
            if currentPreedit.isEmpty { compositionClient = nil }
        case let .update(commit, _):
            guard let client = translationSurfaceClient else { return }
            if !commit.isEmpty, !isDeliveringToClient {
                let markedRange = client.markedRange()
                isDeliveringToClient = true
                client.insertText(commit, replacementRange: markedRange)
                isDeliveringToClient = false
                hasMarkedText = false
                drawnHeldText = ""
            }
            if keyDepth > 0 {
                needsRedraw = true
            } else {
                redrawMarked(client: client)
                if !currentPreedit.isEmpty, !currentCandidates.isEmpty {
                    presentCandidates(client: client)
                }
            }
        }
    }

    /// Draws the marked text: held sentences + the pinyin Rime is editing. The
    /// selection sits inside the pinyin (offset by the held length) or at the end.
    func redrawMarked(client: any IMKTextInput) {
        needsRedraw = false
        let held = automaticTranslation.heldText
        let text = held + currentPreedit
        let heldLength = held.utf16count
        defer {
            drawnHeldText = held
            if !held.isEmpty {
                compositionClient = client
            } else if currentPreedit.isEmpty {
                compositionClient = nil
            }
        }
        guard !text.isEmpty || hasMarkedText else { return }
        let length = text.utf16count
        let caret = currentPreedit.isEmpty
            ? length
            : heldLength + min(max(candidateCursor, 0), currentPreedit.utf16count)
        // Once the client holds our marked text, the update must replace exactly
        // that range; NSNotFound would ask the client to insert a second run.
        client.setMarkedText(
            text,
            selectionRange: NSRange(location: min(caret, length), length: 0),
            replacementRange: client.markedRange()
        )
        hasMarkedText = !text.isEmpty
        if !held.isEmpty {
            updatePreviewAnchor(client: client, length: length)
            scheduleAnchorRecheck(client: client)
        }
    }

    /// 每次重画后过一会儿再问一次位置，变了就挪面板。Chromium/Electron（Claude 等）在
    /// `setMarkedText` 之后才重新排版：当时问到的还是折行前的位置，贴底的输入框随后往上
    /// 长高、第一行被推上去，面板就停在第一行原来的地方盖住它（11-05 用户截图）。
    func scheduleAnchorRecheck(client: any IMKTextInput) {
        anchorRecheckGeneration &+= 1
        let generation = anchorRecheckGeneration
        for delay in Self.anchorRecheckDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, generation == self.anchorRecheckGeneration,
                      self.hasMarkedText, let owner = self.compositionClient,
                      self.isSameClient(owner, client)
                else { return }
                self.recheckAnchor(client: client)
            }
        }
    }

    private func recheckAnchor(client: any IMKTextInput) {
        if !currentPreedit.isEmpty, !currentCandidates.isEmpty {
            presentCandidates(client: client, recheck: false)
            return
        }
        let before = (previewCaretRect, compositionStartRect)
        let length = (automaticTranslation.heldText + currentPreedit).utf16count
        updatePreviewAnchor(client: client, length: length)
        guard before != (previewCaretRect, compositionStartRect) else { return }
        Self.logger.info("caret moved after layout; re-anchoring the panel")
        let owner = ownerIdentifier
        let caret = previewCaretRect
        let start = compositionStartRect
        MainActor.assumeIsolated {
            KeyiCompositionPanel.shared.reanchor(caretRect: caret, startRect: start, owner: owner)
        }
    }

    /// The comparison overlay follows the end of the marked text.
    private func updatePreviewAnchor(client: any IMKTextInput, length: Int) {
        let marked = client.markedRange()
        guard marked.location != NSNotFound, marked.length > 0 else { return }
        let reportedStart = Self.lineRect(client: client, index: marked.location)
        var rect = NSRect.zero
        _ = client.attributes(
            forCharacterIndex: marked.location + min(max(length - 1, 0), marked.length - 1),
            lineHeightRectangle: &rect
        )
        if KeyiPanelLayout.isUsableCaret(rect) { previewCaretRect = rect }
        compositionStartRect = startRect(reported: reportedStart, marked: marked, caret: rect)
    }

    /// 这段字开头所在的行：宿主给的和按光标折回推算的，取更高的那个。
    /// `reported` 是宿主给的开头位置，先于光标问（诊断按最后一次问的位置核对光标）。
    func startRect(reported: NSRect, marked: NSRange, caret: NSRect) -> NSRect {
        guard KeyiPanelLayout.isUsableCaret(caret) else { return reported }
        if let tracking = wrapTracking, tracking.location == marked.location {
            if KeyiPanelLayout.isUpwardWrap(previous: tracking.caret, caret: caret, extent: tracking.extent) {
                upwardWraps += 1
                Self.logger.info("caret wrapped back on the same line; assuming \(self.upwardWraps, privacy: .public) line(s) above")
            }
            if abs(tracking.caret.minY - caret.minY) > 1 { upwardWraps = 0 }
            let extent = min(tracking.extent.lowerBound, caret.minX)...max(tracking.extent.upperBound, caret.minX)
            wrapTracking = (marked.location, caret, extent)
        } else {
            upwardWraps = 0
            wrapTracking = (marked.location, caret, caret.minX...caret.minX)
        }
        let assumed = KeyiPanelLayout.wrappedStart(
            caret: caret,
            wraps: upwardWraps,
            x: wrapTracking?.extent.lowerBound ?? caret.minX
        )
        Self.logger.info("anchor caret=\(NSStringFromRect(caret), privacy: .public) start=\(NSStringFromRect(reported), privacy: .public) wraps=\(self.upwardWraps, privacy: .public)")
        return KeyiPanelLayout.isUsableCaret(reported) && reported.minY >= assumed.minY ? reported : assumed
    }

    static func lineRect(client: any IMKTextInput, index: Int) -> NSRect {
        var rect = NSRect.zero
        _ = client.attributes(forCharacterIndex: index, lineHeightRectangle: &rect)
        return rect
    }
}
