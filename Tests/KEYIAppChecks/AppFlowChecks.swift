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
    let settings = TranslationSettingsStore(defaults: defaults)
    // 检查不读本机真实的模型目录：一个空目录代表「本地模型还没下载」。
    let noLocalModels = LocalModelStorage(
        directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("KEYIAppFlowChecks-models-\(UUID().uuidString)", isDirectory: true)
    )
    settings.selectTranslationStyle(.natural)
    var presentations = 0
    let input = FlowTextAccess()
    let configurationModel = AppModel(
        settings: settings,
        hotKeySettings: HotKeySettingsStore(defaults: defaults),
        accessibility: input,
        presentSettings: { presentations += 1 },
        localModelStorage: noLocalModels
    )
    expect(configurationModel.translationStyle == .natural, "The stored style must be loaded")
    expect(configurationModel.selectedProviderID == .appleSystem, "Natural style without a local model must use Apple Translation")
    configurationModel.selectTranslationStyle(.blackAmerican)
    expect(presentations == 1 && configurationModel.settingsSection == .providers(.deepSeek), "A cloud style without a cloud service must open its settings once")
    expect(configurationModel.usesNaturalInsteadOfCloudStyle && configurationModel.selectedProviderID == .appleSystem, "Until a cloud service is configured, a cloud style must translate as Natural")
    expect(configurationModel.selectedEnglishStyle == .automatic, "The natural fallback must not carry the cloud voice")
    configurationModel.selectProvider(.qwen)
    expect(presentations == 2 && configurationModel.settingsSection == .providers(.qwen), "An unconfigured cloud service must open its form")
    configurationModel.openSettings(.translation)
    expect(configurationModel.cloudProviderShownInSettings == .deepSeek, "With no cloud service configured, Advanced must show the first LLM service")
    configurationModel.chooseProviderInSettings(.xAI)
    expect(configurationModel.cloudProviderShownInSettings == .xAI && configurationModel.selectedProviderID == .appleSystem, "An unconfigured provider must show its form without switching")
    configurationModel.selectTranslationStyle(.business)
    expect(!configurationModel.usesNaturalInsteadOfCloudStyle && configurationModel.selectedScene == .business, "A local style must route without a cloud service")
    expect(presentations == 3, "Choosing a local style must not open settings")
    let engineLabels = settings.storedEngineLabels()
    expect(
        engineLabels["natural"] == "苹果翻译" && engineLabels["blackAmerican"] == "需 API Key",
        "The IME menu must see each style's engine name: \(engineLabels)"
    )
    expect(!engineLabels.values.contains { $0.contains("云端") }, "Engine labels must name the engine, not say cloud")
    configurationModel.selectTranslationStyle(.natural)

    // The direct installedSource route is isolated behind a fake translator; no
    // Translation framework session or host UI is created by this check.
    if #available(macOS 26.0, *) {
        _ = settings.select(.appleSystem)
        settings.selectTargetLanguage(.english)
        settings.selectScene(.dailyChat)
        settings.selectEnglishStyle(.automatic)
        let directInput = FlowTextAccess()
        let recorder = TranslationRequestRecorder()
        let directModel = AppModel(
            settings: settings,
            hotKeySettings: HotKeySettingsStore(defaults: defaults),
            accessibility: directInput,
            presentSettings: {},
            localModelStorage: noLocalModels,
            systemTranslator: { request in
                await recorder.record(request)
                return "direct translation"
            }
        )
        await directModel.triggerTranslation()
        let directFinished = await waitForMainActor {
            directModel.state == .success || directModel.state.isFailure
        }
        let recordedRequests = await recorder.requests()
        expect(directFinished && directModel.state == .success, "Installed system translation must complete through the direct route")
        expect(directInput.replacements == ["direct translation"], "Direct system translation must write back exactly once")
        expect(directModel.systemTranslationHostRequestID == nil && directModel.translationConfiguration == nil, "Direct translation must not wait for or configure the SwiftUI host")
        expect(recordedRequests.count == 1 && recordedRequests.first?.providerID == .appleSystem, "The direct translator must receive the frozen system request")
    } else {
        expect(true, "Installed-source direct route is only available on macOS 26 or later")
    }

    // Fallback host requests are immutable snapshots and can be accepted once
    // only by the UUID captured by that host-view generation.
    _ = settings.select(.appleSystem)
    settings.selectTargetLanguage(.chinese)
    settings.selectScene(.socialMedia)
    settings.selectEnglishStyle(.british)
    let fallbackInput = FlowTextAccess()
    fallbackInput.replacementFailure = AccessibilityTextClient.Error.terminalRecoveryRequired(
        originalText: fallbackInput.original
    )
    let model = AppModel(
        settings: settings,
        hotKeySettings: HotKeySettingsStore(defaults: defaults),
        accessibility: fallbackInput,
        presentSettings: {},
        localModelStorage: noLocalModels
    )
    await model.triggerTranslation()
    guard let firstHostID = model.systemTranslationHostRequestID,
          let firstRequest = model.activeTranslationRequest(id: firstHostID) else {
        preconditionFailure("Target-language auto-detection must dispatch and accept the SwiftUI host request")
    }
    model.selectTargetLanguage(.japanese)
    model.selectScene(.business)
    model.selectEnglishStyle(.standardAmerican)
    var hostIDDuringWriteback: UUID?
    var hostConfigurationDuringWriteback = false
    fallbackInput.onReplacement = {
        hostIDDuringWriteback = model.systemTranslationHostRequestID
        hostConfigurationDuringWriteback = model.translationConfiguration != nil
    }
    expect(firstRequest.id == firstHostID && firstRequest.providerID == .appleSystem, "Host acceptance must return the dispatched request identity and provider")
    expect(firstRequest.targetLanguage == .chinese && firstRequest.scene == .automatic && firstRequest.englishStyle == .automatic, "Changing settings after dispatch must not mutate the frozen request")
    expect(model.activeTranslationRequest(id: firstHostID) == nil, "A host request must not be accepted twice")
    await model.completeTranslation(id: firstRequest.id, translatedText: "translated command")
    expect(fallbackInput.replacements.isEmpty, "A failed destructive replacement must retain the complete original command")
    expect(model.terminalRecoveryCommands == [fallbackInput.original], "A failed destructive replacement must retain the complete original command")
    expect(model.state.isFailure && !model.isBusy, "Recovery must end the active operation")
    expect(model.systemTranslationHostRequestID == nil && model.translationConfiguration == nil, "Failure must clear the host dispatch and translation configuration")
    expect(model.activeTranslationRequest(id: firstHostID) == nil, "A completed host generation must not be able to reclaim its request")
    expect(hostIDDuringWriteback == firstHostID && hostConfigurationDuringWriteback, "Host identity and session configuration must remain stable until writeback finishes")
    fallbackInput.onReplacement = nil
    let captures = fallbackInput.captures
    await model.triggerTranslation()
    expect(fallbackInput.captures == captures, "Another translation must not overwrite a command awaiting recovery")

    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    model.copyOriginalTerminalCommand(to: pasteboard)
    expect(pasteboard.string(forType: .string) == fallbackInput.original, "Explicit recovery must copy the original, including trailing spaces")
    expect(model.terminalRecoveryCommands.isEmpty && model.state == .ready, "Successful recovery must enable translation again")

    model.selectTargetLanguage(.chinese)
    await model.triggerTranslation()
    guard let secondHostID = model.systemTranslationHostRequestID,
          let secondRequest = model.activeTranslationRequest(id: secondHostID) else {
        preconditionFailure("A later shortcut must create a fresh fallback host request")
    }
    expect(secondHostID != firstHostID, "Each host view generation must get a unique request identity")
    expect(model.activeTranslationRequest(id: firstHostID) == nil, "A stale host callback must not claim the newer request")
    fallbackInput.beforeReplacementFailure = { model.recoverAfterSystemResume() }
    await model.completeTranslation(id: secondRequest.id, translatedText: "translated command")
    expect(model.terminalRecoveryCommands == [fallbackInput.original], "Resume during writeback must not discard an original command")
    model.discardOriginalTerminalCommand()
    expect(model.terminalRecoveryCommands.isEmpty && model.state == .ready, "Explicit discard must release the retained command")
    expect(pasteboard.string(forType: .string) == fallbackInput.original, "Discard must not alter the clipboard")

    if #available(macOS 26.0, *) {
        // The fake deliberately ignores Task cancellation while suspended. The
        // independent deadline must release the request; its late result must
        // neither write nor clear a newer host request.
        _ = settings.select(.appleSystem)
        settings.selectTargetLanguage(.english)
        let delayedInput = FlowTextAccess()
        let delayedResults = DeferredSystemTranslationResults()
        let timeoutModel = AppModel(
            settings: settings,
            hotKeySettings: HotKeySettingsStore(defaults: defaults),
            accessibility: delayedInput,
            presentSettings: {},
            localModelStorage: noLocalModels,
            systemTranslationTimeoutSeconds: 0.2,
            systemTranslator: { request in
                try await delayedResults.wait(for: request)
            }
        )
        await timeoutModel.triggerTranslation()
        let firstDirectIDs = await waitForRequests(1, from: delayedResults)
        expect(firstDirectIDs.count == 1, "The fake installed translator must start before the deadline")
        let firstDirectID = firstDirectIDs[0]
        let didTimeOut = await waitForMainActor {
            timeoutModel.state.isFailure && !timeoutModel.isBusy
        }
        let timeoutMessage: String
        if case let .failure(message) = timeoutModel.state {
            timeoutMessage = message
        } else {
            timeoutMessage = ""
        }
        expect(didTimeOut, "A nonresponsive system translation must release the busy state")
        expect(timeoutMessage.contains("原文已保留") || timeoutMessage.localizedCaseInsensitiveContains("original text was kept"), "Timeout must explain that the original text was kept")
        expect(delayedInput.replacements.isEmpty && timeoutModel.systemTranslationHostRequestID == nil, "Timeout must leave the original untouched and clear host state")

        timeoutModel.selectTargetLanguage(.chinese)
        await timeoutModel.triggerTranslation()
        guard let newerHostID = timeoutModel.systemTranslationHostRequestID,
              let newerRequest = timeoutModel.activeTranslationRequest(id: newerHostID) else {
            preconditionFailure("A timed-out shortcut must allow a new host request")
        }
        await delayedResults.resolve(firstDirectID, with: "late old result")
        try? await Task.sleep(for: .milliseconds(20))
        expect(delayedInput.replacements.isEmpty, "A late timed-out result must produce zero writes")
        expect(timeoutModel.systemTranslationHostRequestID == newerHostID && timeoutModel.isBusy, "A late result must not clear or replace a newer request")
        expect(timeoutModel.activeTranslationRequest(id: newerHostID) == nil, "A late result must not consume the newer host request")
        await timeoutModel.completeTranslation(id: newerRequest.id, translatedText: "new request result")
        expect(delayedInput.replacements == ["new request result"] && timeoutModel.state == .success, "The newer request must still be able to write back once")
    } else {
        expect(true, "Installed-source timeout behavior is only available on macOS 26 or later")
    }

    return checks
}

@MainActor
private final class FlowTextAccess: FocusedTextAccess {
    let isTrusted = true
    let original = "原始命令  "
    var captures = 0
    var replacements: [String] = []
    var onReplacement: (() -> Void)?
    var beforeReplacementFailure: (() -> Void)?
    var replacementFailure: Swift.Error?

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
        onReplacement?()
        beforeReplacementFailure?()
        if let replacementFailure { throw replacementFailure }
        guard isCurrent() else { throw CancellationError() }
        replacements.append(translatedText)
    }
}

private actor TranslationRequestRecorder {
    private var recordedRequests: [AppModel.TranslationRequest] = []

    func record(_ request: AppModel.TranslationRequest) {
        recordedRequests.append(request)
    }

    func requests() -> [AppModel.TranslationRequest] {
        recordedRequests
    }
}

private actor DeferredSystemTranslationResults {
    private var requestIDs: [UUID] = []
    private var continuations: [UUID: CheckedContinuation<String, any Error>] = [:]

    func wait(for request: AppModel.TranslationRequest) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            requestIDs.append(request.id)
            continuations[request.id] = continuation
        }
    }

    func allRequestIDs() -> [UUID] {
        requestIDs
    }

    func resolve(_ id: UUID, with result: String) {
        continuations.removeValue(forKey: id)?.resume(returning: result)
    }
}

@MainActor
private func waitForMainActor(
    timeoutSeconds: TimeInterval = 2,
    condition: @escaping @MainActor () -> Bool
) async -> Bool {
    let startedAt = Date()
    while Date().timeIntervalSince(startedAt) < timeoutSeconds {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return condition()
}

@MainActor
private func waitForRequests(
    _ count: Int,
    from results: DeferredSystemTranslationResults,
    timeoutSeconds: TimeInterval = 2
) async -> [UUID] {
    let startedAt = Date()
    while Date().timeIntervalSince(startedAt) < timeoutSeconds {
        let ids = await results.allRequestIDs()
        if ids.count >= count { return ids }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await results.allRequestIDs()
}
