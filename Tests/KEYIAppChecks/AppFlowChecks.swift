import AppKit
import KEYICore
@testable import KEYIUI

@MainActor
func runAppFlowChecks() async throws -> Int {
    var checks = 0
    func expect(_ condition: Bool, _ message: String) {
        precondition(condition, message)
        checks += 1
    }

    let suite = "KEYIAppFlowChecks-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = TranslationSettingsStore(defaults: defaults, legacyDefaults: nil)
    _ = settings.select(.qwen)
    var presentations = 0
    let input = FlowTextAccess()
    let configurationModel = AppModel(
        settings: settings,
        hotKeySettings: HotKeySettingsStore(defaults: defaults, legacyDefaults: nil),
        accessibility: input,
        presentSettings: { presentations += 1 }
    )
    await configurationModel.triggerTranslation()
    expect(presentations == 1, "Missing credentials must open settings from the translation shortcut")
    expect(configurationModel.settingsSection == .providers(.qwen), "Settings must open the selected unconfigured provider")
    expect(input.captures == 0 && !configurationModel.isBusy, "Configuration guidance must precede reading the user's input")
    configurationModel.selectProvider(.deepSeek)
    expect(presentations == 2 && configurationModel.settingsSection == .providers(.deepSeek), "A new provider must update an already-open settings route")

    _ = settings.select(.appleSystem)
    let model = AppModel(
        settings: settings,
        hotKeySettings: HotKeySettingsStore(defaults: defaults, legacyDefaults: nil),
        accessibility: input,
        presentSettings: {}
    )
    await model.triggerTranslation()
    let request = model.activeTranslationRequest()!
    await model.completeTranslation(id: request.id, translatedText: "translated command")
    expect(model.terminalRecoveryCommands == [input.original], "A failed destructive replacement must retain the complete original command")
    expect(model.state.isFailure && !model.isBusy, "Recovery must end the active operation")
    let captures = input.captures
    await model.triggerTranslation()
    expect(input.captures == captures, "Another translation must not overwrite a command awaiting recovery")

    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    model.copyOriginalTerminalCommand(to: pasteboard)
    expect(pasteboard.string(forType: .string) == input.original, "Explicit recovery must copy the original, including trailing spaces")
    expect(model.terminalRecoveryCommands.isEmpty && model.state == .ready, "Successful recovery must enable translation again")

    await model.triggerTranslation()
    let cancelledRequest = model.activeTranslationRequest()!
    input.beforeReplacementFailure = { model.recoverAfterSystemResume() }
    await model.completeTranslation(id: cancelledRequest.id, translatedText: "translated command")
    expect(model.terminalRecoveryCommands == [input.original], "Cancellation must not discard an original deleted by the in-flight write")
    model.discardOriginalTerminalCommand()
    expect(model.terminalRecoveryCommands.isEmpty && model.state == .ready, "Explicit discard must release the retained command")
    expect(pasteboard.string(forType: .string) == input.original, "Discard must not alter the clipboard")
    return checks
}

@MainActor
private final class FlowTextAccess: FocusedTextAccess {
    let isTrusted = true
    let original = "原始命令  "
    var captures = 0
    var beforeReplacementFailure: (() -> Void)?

    func requestTrustPrompt() {}

    func capture() async throws -> AccessibilityTextClient.Snapshot {
        captures += 1
        return AccessibilityTextClient.Snapshot(
            element: nil,
            applicationProcessIdentifier: nil,
            originalValue: original,
            originalSelectedRange: NSRange(location: (original as NSString).length, length: 0),
            selection: FocusedTextSelection(text: original, range: NSRange(location: 0, length: (original as NSString).length)),
            writeMode: .terminalPaste,
            isTerminalBuffer: true
        )
    }

    func replace(
        snapshot: AccessibilityTextClient.Snapshot,
        with translatedText: String,
        isCurrent: @escaping @MainActor () -> Bool
    ) async throws {
        beforeReplacementFailure?()
        throw AccessibilityTextClient.Error.terminalRecoveryRequired(originalText: original)
    }
}
