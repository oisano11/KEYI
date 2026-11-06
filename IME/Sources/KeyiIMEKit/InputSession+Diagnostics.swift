import InputMethodKit
import KeyiIMEBridge

/// 只给诊断与自动检查用的钩子（Objective-C 选择器 keyiDiagnostic*），正式输入路径不调用。
extension InputSession {
    /// Candidates shown to the user, one entry per visible row. Used by the
    /// diagnostics target; never fabricated.
    @objc(keyiDiagnosticCandidatePresentation)
    func diagnosticCandidatePresentation() -> [String] {
        currentCandidates
    }

    /// Diagnostics-only: makes the next `processKey` consume `result` instead of
    /// asking librime. Used to cover the commit-with-remaining-preedit ordering
    /// rule, which this schema never produces on its own.
    @objc(keyiDiagnosticInjectResult:)
    func diagnosticInject(result: KeyiRimeResult?) {
        diagnosticInjectedResult = result
    }

    /// Whether a composition is currently held for this client.
    @objc(keyiDiagnosticOwnsCompositionForClient:)
    func diagnosticOwnsComposition(client sender: Any?) -> Bool {
        guard let client = sender as? any IMKTextInput else { return false }
        return ownsComposition(client)
    }

    /// Diagnostics-only control of the automatic translation seam. It does nothing
    /// unless the process was started with `KEYI_IME_DIAGNOSTIC_FAKE_TRANSLATION=1`,
    /// which only the diagnostics script sets, so the real input method cannot
    /// enable it by accident. Commands: `install`, `hold`, `release`, `secure:0|1`,
    /// `auto:0|1`, `mouse:down` (a mouse click now; after `install` only these count),
    /// `requests` (returns the sources the fake translator was asked for).
    @objc(keyiDiagnosticFakeCommand:)
    func diagnosticFakeCommand(_ command: String) -> String {
        guard KeyiDiagnosticFakeTranslator.isAllowed else { return "refused" }
        switch command {
        case "install":
            diagnosticFakeTranslator = KeyiDiagnosticFakeTranslator()
            diagnosticMouseOverride = true
            diagnosticMouseDownAt = nil
        case "mouse:down":
            diagnosticMouseOverride = true
            diagnosticMouseDownAt = ProcessInfo.processInfo.systemUptime
        case "hold":
            diagnosticFakeTranslator?.holding = true
        case "release":
            diagnosticFakeTranslator?.holding = false
            diagnosticFakeTranslator?.releasePending()
        case "secure:0", "secure:1":
            diagnosticSecureInput = command == "secure:1"
        case "auto:0", "auto:1":
            diagnosticAutomaticOverride = command == "auto:1"
            automaticTranslation.setEnabled(command == "auto:1")
        case "requests":
            return diagnosticFakeTranslator?.requests.joined(separator: "|") ?? ""
        default:
            return "unknown"
        }
        return "ok"
    }

    /// Diagnostics-only: the last text this session handed to automatic translation,
    /// or nil when it has not handed anything over. It lets a check prove that a real
    /// confirmed Han commit reaches the automatic path while raw-pinyin commit does
    /// not — i.e. that the wiring in `apply` has not drifted away from the engine.
    @objc(keyiDiagnosticLastConfirmedCommit)
    func diagnosticLastConfirmedCommit() -> String? {
        diagnosticConfirmedCommit
    }

    @objc(keyiDiagnosticResetConfirmedCommit)
    func diagnosticResetConfirmedCommit() {
        diagnosticConfirmedCommit = nil
    }

    /// Diagnostics-only: shows `source` with "翻译中…" through the same presenter the
    /// automatic translation controller uses, so a check can prove the panel goes away
    /// with the session even when IMK releases the session right after deactivation.
    @objc(keyiDiagnosticShowPreview:)
    func diagnosticShowPreview(_ source: String) {
        Self.presentPreview(
            source: source,
            translation: nil,
            hint: .waiting,
            owner: ownerIdentifier,
            session: self
        )
    }

    /// Diagnostics-only: whether the translation preview panel is on screen, whichever
    /// session showed it. Checks read it after the owning session is gone.
    @objc(keyiDiagnosticPreviewPanelVisible)
    func diagnosticPreviewPanelVisible() -> Bool {
        KeyiTranslationPreviewPanel.isVisibleForDiagnostics()
    }
}
