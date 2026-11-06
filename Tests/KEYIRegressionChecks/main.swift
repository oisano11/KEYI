import AppKit
import ApplicationServices
import Foundation
import Darwin
import KEYICore
@testable import KEYIUI

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--instance-lock-probe" {
    let probe = try InstanceLock(path: CommandLine.arguments[2])
    exit(probe == nil ? 23 : 0)
}

private var checkCount = 0

@MainActor
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checkCount += 1
    guard condition() else { fatalError(message) }
}

// Isolated preferences and a fake input boundary keep these checks off the desktop.
@MainActor
private final class FakeTextAccess: FocusedTextAccess {
    var isTrusted = false
    var captures = 0
    var permissionPrompts = 0
    var writes = 0

    func requestTrustPrompt() { permissionPrompts += 1 }

    func capture() async throws -> AccessibilityTextClient.Snapshot {
        captures += 1
        if !isTrusted { throw AccessibilityTextClient.Error.permissionRequired }
        throw AccessibilityTextClient.Error.noFocusedText
    }

    func replace(
        snapshot: AccessibilityTextClient.Snapshot,
        with translatedText: String,
        isCurrent: @escaping @MainActor () -> Bool
    ) async throws {
        writes += 1
    }
}

private enum FocusResolverProbeError: Swift.Error, Equatable {
    case read
    case wait
}

// Int/String handles and injected waits never inspect or activate a desktop app.
@MainActor
private final class FocusResolverFixture {
    var current = true
    var focusAtRead: Int?
    var recoverySucceeds = true
    var reads = 0
    var recoveries = 0
    var waits = 0
    var currentCheck: (@MainActor () -> Bool)?
    var afterRead: (@MainActor () throws -> Void)?
    var duringRecovery: (@MainActor () -> Void)?
    var duringWait: (@MainActor (Int) async throws -> Void)?

    func resolve(recoveryEnabled: Bool = true) async -> Result<Int, Swift.Error> {
        let recover: (@MainActor () -> Bool)?
        if recoveryEnabled {
            recover = {
                self.recoveries += 1
                self.duringRecovery?()
                return self.recoverySucceeds
            }
        } else {
            recover = nil
        }
        do {
            let element = try await FocusedElementResolver.resolve(
                isCurrent: { self.currentCheck?() ?? self.current },
                read: {
                    self.reads += 1
                    try self.afterRead?()
                    return self.focusAtRead == self.reads ? self.reads : nil
                },
                recover: recover,
                wait: {
                    self.waits += 1
                    try await self.duringWait?(self.waits)
                }
            )
            return .success(element)
        } catch {
            return .failure(error)
        }
    }
}

private func resolverValue(_ result: Result<Int, Swift.Error>) -> Int? {
    if case let .success(value) = result { return value }
    return nil
}

private func resolverError(_ result: Result<Int, Swift.Error>) -> Swift.Error? {
    if case let .failure(error) = result { return error }
    return nil
}

@MainActor
private func checkFocusedElementResolver() async throws {
    expect(AccessibilityTextClient.allowsInitialFocusRecovery(
        bundleIdentifier: "com.openai.codex", isInitialCapture: true, isTrusted: true
    ), "Trusted initial Codex capture alone must allow focus recovery")
    expect(!AccessibilityTextClient.allowsInitialFocusRecovery(
        bundleIdentifier: "com.openai.codex", isInitialCapture: false, isTrusted: true
    ), "Writeback revalidation must never enable focus recovery")
    expect(!AccessibilityTextClient.allowsInitialFocusRecovery(
        bundleIdentifier: "com.openai.codex", isInitialCapture: true, isTrusted: false
    ), "Focus recovery must not request or bypass missing AX permission")
    expect(!AccessibilityTextClient.allowsInitialFocusRecovery(
        bundleIdentifier: "com.mitchellh.ghostty", isInitialCapture: true, isTrusted: true
    ) && !AccessibilityTextClient.allowsInitialFocusRecovery(
        bundleIdentifier: nil, isInitialCapture: true, isTrusted: true
    ), "Other applications and missing bundle identity must never recover")

    let immediate = FocusResolverFixture()
    immediate.focusAtRead = 1
    let immediateResult = await immediate.resolve()
    expect(resolverValue(immediateResult) == 1 && immediate.reads == 1
           && immediate.recoveries == 0 && immediate.waits == 0,
           "Existing focus must return without recovery or delay")

    var stringReads = 0
    var stringWaits = 0
    var stringRecoveries = 0
    let stringElement = try await FocusedElementResolver.resolve(
        isCurrent: { true },
        read: { () -> String? in
            stringReads += 1
            return stringReads == 4 ? "focused" : nil
        },
        recover: { stringRecoveries += 1; return true },
        wait: { stringWaits += 1 }
    )
    expect(stringElement == "focused" && stringReads == 4 && stringWaits == 3
           && stringRecoveries == 0,
           "The fourth initial probe must still succeed without recovery")

    let recovered = FocusResolverFixture()
    recovered.focusAtRead = 5
    let recoveredResult = await recovered.resolve()
    expect(resolverValue(recoveredResult) == 5 && recovered.reads == 5
           && recovered.recoveries == 1 && recovered.waits == 4,
           "One recovery must follow four nil probes and wait before rereading")

    let lateRecovery = FocusResolverFixture()
    lateRecovery.focusAtRead = 8
    let lateResult = await lateRecovery.resolve()
    expect(resolverValue(lateResult) == 8 && lateRecovery.reads == 8
           && lateRecovery.recoveries == 1 && lateRecovery.waits == 7,
           "The fourth recovered probe must stay within eight reads and seven waits")

    let failedRecovery = FocusResolverFixture()
    failedRecovery.recoverySucceeds = false
    let failedResult = await failedRecovery.resolve()
    expect((resolverError(failedResult) as? AccessibilityTextClient.Error)?.diagnosticCode == "no_focused_text"
           && failedRecovery.reads == 4 && failedRecovery.recoveries == 1 && failedRecovery.waits == 3,
           "Rejected recovery must fail immediately without another recovery or probe")

    let exhausted = FocusResolverFixture()
    let exhaustedResult = await exhausted.resolve()
    expect((resolverError(exhaustedResult) as? AccessibilityTextClient.Error)?.diagnosticCode == "no_focused_text"
           && exhausted.reads == 8 && exhausted.recoveries == 1 && exhausted.waits == 7,
           "Successful activation without focus must exhaust one bounded retry only")

    let noRecovery = FocusResolverFixture()
    let noRecoveryResult = await noRecovery.resolve(recoveryEnabled: false)
    expect((resolverError(noRecoveryResult) as? AccessibilityTextClient.Error)?.diagnosticCode == "no_focused_text"
           && noRecovery.reads == 4 && noRecovery.recoveries == 0 && noRecovery.waits == 3,
           "Nil recovery must never activate a non-Codex or writeback target")

    let stale = FocusResolverFixture()
    stale.current = false
    let staleResult = await stale.resolve()
    expect((resolverError(staleResult) as? AccessibilityTextClient.Error)?.diagnosticCode == "content_changed"
           && stale.reads == 0 && stale.recoveries == 0 && stale.waits == 0,
           "A stale target must stop before every operation")

    let beforeRecovery = FocusResolverFixture()
    beforeRecovery.afterRead = {
        if beforeRecovery.reads == 4 { beforeRecovery.current = false }
    }
    let beforeResult = await beforeRecovery.resolve()
    expect((resolverError(beforeResult) as? AccessibilityTextClient.Error)?.diagnosticCode == "content_changed"
           && beforeRecovery.reads == 4 && beforeRecovery.recoveries == 0 && beforeRecovery.waits == 3,
           "A target change before activation must prevent recovery")

    let duringRecovery = FocusResolverFixture()
    duringRecovery.duringRecovery = { duringRecovery.current = false }
    let duringResult = await duringRecovery.resolve()
    expect((resolverError(duringResult) as? AccessibilityTextClient.Error)?.diagnosticCode == "content_changed"
           && duringRecovery.reads == 4 && duringRecovery.recoveries == 1 && duringRecovery.waits == 3,
           "A target change during recovery must stop before the recovery wait")

    let duringWait = FocusResolverFixture()
    duringWait.duringWait = { count in
        if count == 4 { duringWait.current = false }
    }
    let waitChangeResult = await duringWait.resolve()
    expect((resolverError(waitChangeResult) as? AccessibilityTextClient.Error)?.diagnosticCode == "content_changed"
           && duringWait.reads == 4 && duringWait.recoveries == 1 && duringWait.waits == 4,
           "A target change during the recovery wait must prevent another read")

    let beforeReturn = FocusResolverFixture()
    beforeReturn.focusAtRead = 1
    var checksAfterRead = 0
    beforeReturn.currentCheck = {
        if beforeReturn.reads > 0 {
            checksAfterRead += 1
            return checksAfterRead < 2
        }
        return true
    }
    let returnResult = await beforeReturn.resolve()
    expect((resolverError(returnResult) as? AccessibilityTextClient.Error)?.diagnosticCode == "content_changed"
           && beforeReturn.reads == 1 && beforeReturn.recoveries == 0
           && beforeReturn.waits == 0 && checksAfterRead == 2,
           "A found element must be revalidated immediately before return")

    let preCancelled = FocusResolverFixture()
    let preCancelledResult = await Task { @MainActor in
        withUnsafeCurrentTask { $0?.cancel() }
        return await preCancelled.resolve()
    }.value
    expect(resolverError(preCancelledResult) is CancellationError && preCancelled.reads == 0
           && preCancelled.recoveries == 0 && preCancelled.waits == 0,
           "An already cancelled task must perform no focus operations")

    let cancelledWait = FocusResolverFixture()
    cancelledWait.duringWait = { _ in withUnsafeCurrentTask { $0?.cancel() } }
    let cancelledWaitResult = await Task { @MainActor in
        await cancelledWait.resolve()
    }.value
    expect(resolverError(cancelledWaitResult) is CancellationError && cancelledWait.reads == 1
           && cancelledWait.recoveries == 0 && cancelledWait.waits == 1,
           "Task cancellation during a wait must stop before another read")

    let readFailure = FocusResolverFixture()
    readFailure.afterRead = { throw FocusResolverProbeError.read }
    let readFailureResult = await readFailure.resolve()
    expect(resolverError(readFailureResult) as? FocusResolverProbeError == .read
           && readFailure.reads == 1 && readFailure.recoveries == 0 && readFailure.waits == 0,
           "A read error must propagate unchanged instead of triggering recovery")

    let waitFailure = FocusResolverFixture()
    waitFailure.duringWait = { _ in throw FocusResolverProbeError.wait }
    let waitFailureResult = await waitFailure.resolve()
    expect(resolverError(waitFailureResult) as? FocusResolverProbeError == .wait
           && waitFailure.reads == 1 && waitFailure.recoveries == 0 && waitFailure.waits == 1,
           "A wait error must propagate unchanged without another probe")
}

let suite = "KEYIRegressionChecks-\(UUID().uuidString)"
let lockDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: lockDirectory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: lockDirectory) }
let lockPath = lockDirectory.appendingPathComponent("instance.lock").path
func probeInstanceLock() throws -> Int32 {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    child.arguments = ["--instance-lock-probe", lockPath]
    try child.run()
    child.waitUntilExit()
    return child.terminationStatus
}
var instanceLock = try InstanceLock(path: lockPath)
expect(instanceLock != nil, "First process must acquire the instance lock")
let duplicateStatus = try probeInstanceLock()
expect(duplicateStatus == 23, "A second process must be rejected while the owner is alive")
instanceLock = nil
let releasedStatus = try probeInstanceLock()
expect(releasedStatus == 0, "A remaining lock file must not prevent restart after owner exit")
// A successful AX selection setter may be acknowledged before its range is visible.
var selectionPolls = 0
var selectionWaits = 0
var selectionRequests = 0
var preparedPastes = 0
try await AccessibilityTextClient.waitForSelectionUpdate(requestSelection: {
    selectionRequests += 1
}, isReady: {
    selectionPolls += 1
    return selectionPolls >= 3
}, pause: { selectionWaits += 1 })
preparedPastes += 1
expect(selectionPolls == 3 && selectionWaits == 2 && selectionRequests == 1 && preparedPastes == 1,
       "The first request must wait for its asynchronous selection update")
var immediateWaits = 0
try await AccessibilityTextClient.waitForSelectionUpdate(requestSelection: {}, isReady: { true }, pause: {
    immediateWaits += 1
})
expect(immediateWaits == 0, "Ready selections must not incur a fixed delay")
var timedOut = false
var timeoutPolls = 0
do {
    try await AccessibilityTextClient.waitForSelectionUpdate(requestSelection: {}, isReady: {
        timeoutPolls += 1
        return false
    }, pause: {})
    preparedPastes += 1
} catch AccessibilityTextClient.Error.selectionUpdateTimedOut { timedOut = true }
expect(timedOut && timeoutPolls == 21 && preparedPastes == 1,
       "Unacknowledged selections must stop before paste after bounded polling")
var abortedForChange = false
do {
    try await AccessibilityTextClient.waitForSelectionUpdate(requestSelection: {}, isReady: {
        throw AccessibilityTextClient.Error.contentChanged
    }, pause: { fatalError("Target or content changes must not be retried") })
    preparedPastes += 1
} catch AccessibilityTextClient.Error.contentChanged { abortedForChange = true }
expect(abortedForChange && preparedPastes == 1, "Changed targets or contents must prevent paste")
var selectionCancelled = false
do {
    try await AccessibilityTextClient.waitForSelectionUpdate(requestSelection: {}, isReady: { false }, pause: {
        throw CancellationError()
    })
    preparedPastes += 1
} catch is CancellationError { selectionCancelled = true }
expect(selectionCancelled && preparedPastes == 1, "Cancellation while waiting must prevent paste")
try await checkFocusedElementResolver()
try checkFocusedElementProbe { condition, message in expect(condition, message) }
try await checkFocusedElementProbeCancellation { condition, message in expect(condition, message) }
expect(AccessibilityTextClient.allowsWindowFocusedInput(
    isSameAsWindow: false, isSameAsApplication: false, role: "AXTextArea"
), "A distinct window-focused text area may enter the existing capture path")
expect(AccessibilityTextClient.allowsWindowFocusedInput(
    isSameAsWindow: false, isSameAsApplication: false, role: "AXTextField"
), "A distinct window-focused text field may enter the existing capture path")
expect(!AccessibilityTextClient.allowsWindowFocusedInput(
    isSameAsWindow: true, isSameAsApplication: false, role: "AXTextArea"
), "A window must never be accepted as its own focused input")
expect(!AccessibilityTextClient.allowsWindowFocusedInput(
    isSameAsWindow: false, isSameAsApplication: true, role: "AXTextField"
), "An application root must never be accepted as a window-focused input")
expect(!AccessibilityTextClient.allowsWindowFocusedInput(
    isSameAsWindow: false, isSameAsApplication: false, role: nil
), "A missing role must not authorize whole-text keyboard fallback")
expect(["AXApplication", "AXWindow", "AXGroup", "AXWebArea", "AXScrollArea", "AXComboBox"].allSatisfy {
    !AccessibilityTextClient.allowsWindowFocusedInput(
        isSameAsWindow: false, isSameAsApplication: false, role: $0
    )
}, "Non-text window focus must fail closed without scanning descendants")
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
private let access = FakeTextAccess()
let model = AppModel(
    settings: TranslationSettingsStore(defaults: defaults),
    hotKeySettings: HotKeySettingsStore(defaults: defaults),
    accessibility: access,
    // 不读本机真实的模型目录：空目录代表「本地模型还没下载」。
    localModelStorage: LocalModelStorage(
        directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("KEYIRegressionChecks-models-\(UUID().uuidString)", isDirectory: true)
    )
)
await model.triggerTranslation()
expect(model.state == .permissionRequired, "Permission failure must leave preparing state")
expect(!model.isBusy && access.permissionPrompts == 1, "Permission prompt must not leave an active operation")
access.isTrusted = true
model.refreshAccessibilityStatus()
expect(model.state == .ready, "Granting permission must restore ready state")
await model.triggerTranslation()
expect(access.captures == 2, "A trigger after granting permission must not be ignored")
expect(!model.isBusy && access.writes == 0, "Failed capture must preserve the input")

model.settingsSection = .providers(.qwen)
expect(model.settingsSection.providerForEditing == .qwen, "Service route must retain Qwen")
model.settingsSection = .providers(.xAI)
expect(model.settingsSection.providerForEditing == .xAI, "An open service page must follow a new route")
model.settingsSection = .providers(.localModel)
expect(model.settingsSection.providerForEditing == .localModel, "Local model route must remain distinct")
model.settingsSection = .providers(nil)
expect(model.settingsSection.providerForEditing == .deepSeek, "Unspecified service route must have a predictable default")
expect(model.selectedProviderID == .appleSystem, "Editing a provider must not activate it")

// AX object handles are compared only; no attributes or desktop state are read.
let elementA = AXUIElementCreateApplication(101)
let elementB = AXUIElementCreateApplication(102)
let windowA = AXUIElementCreateApplication(103)
let windowB = AXUIElementCreateApplication(104)
let parentA = AXUIElementCreateApplication(105)
let target = AccessibilityTextClient.TargetIdentity(
    element: elementA, window: windowA, parent: parentA, identifier: "editor-a", role: "AXTextArea"
)
expect(target.matches(target), "Unchanged input target must match")
let otherInput = AccessibilityTextClient.TargetIdentity(
    element: elementB, window: windowA, parent: parentA, identifier: "editor-b", role: "AXTextArea"
)
expect(!target.matches(otherInput, allowsRecreatedElement: true), "Another field in the same window must not match")
let otherWindow = AccessibilityTextClient.TargetIdentity(
    element: elementB, window: windowB, parent: parentA, identifier: "editor-a", role: "AXTextArea"
)
expect(!target.matches(otherWindow, allowsRecreatedElement: true), "Another window must not match even with the same identifier")
let rerendered = AccessibilityTextClient.TargetIdentity(
    element: elementB, window: windowA, parent: parentA, identifier: "editor-a", role: "AXTextArea"
)
expect(target.matches(rerendered, allowsRecreatedElement: true), "Stable web identity must survive a rerender")
expect(!target.matches(rerendered), "Non-web paths must require the original element")
let unidentified = AccessibilityTextClient.TargetIdentity(element: elementB, window: windowA, parent: parentA)
expect(!target.matches(unidentified, allowsRecreatedElement: true), "Unknown replacement controls must not match")

for bundle in ["com.apple.Terminal", "com.mitchellh.ghostty"] {
    expect(AccessibilityTextClient.requiresTerminalOutputGuard(
        bundleIdentifier: bundle, role: "AXTextArea", valueIsSettable: false
    ), "Read-only terminal buffers must reject control characters")
    expect(AccessibilityTextClient.requiresTerminalOutputGuard(
        bundleIdentifier: bundle, role: nil, valueIsSettable: false
    ), "Opaque terminal keyboard targets must retain the output guard")
    expect(!AccessibilityTextClient.requiresTerminalOutputGuard(
        bundleIdentifier: bundle, role: "AXTextField", valueIsSettable: true
    ), "Writable terminal search fields must remain ordinary inputs")
}
expect(!AccessibilityTextClient.requiresTerminalOutputGuard(
    bundleIdentifier: "com.apple.Safari", role: nil, valueIsSettable: false
), "Ordinary applications must not inherit terminal output restrictions")

let terminalHostBundles = [
    "com.apple.Terminal",
    "com.googlecode.iterm2",
    "com.mitchellh.ghostty",
    "dev.warp.Warp-Stable",
    "com.microsoft.VSCode",
    "org.wezfurlong.wezterm",
    "net.kovidgoyal.kitty",
    "org.alacritty"
]
for bundle in terminalHostBundles {
    expect(TerminalHostCapabilities.host(for: bundle) != nil,
           "The production registry must include \(bundle)")
    expect(!TerminalHostCapabilities.allowsKeyboardFallback(bundleIdentifier: bundle),
           "Registered terminal/hybrid hosts must not reach selection-copy or keyboard fallback")
}

let dedicatedTerminalBundles = terminalHostBundles.filter {
    $0 != "com.microsoft.VSCode"
}
for bundle in dedicatedTerminalBundles {
    let opaque = TerminalHostCapabilities.route(
        bundleIdentifier: bundle, role: nil,
        valueIsSettable: false, selectedRangeIsSettable: false
    )
    expect(opaque == .rejectTerminalScreen && !opaque.mayReadAXValue,
           "Opaque terminal screens must be rejected before reading AXValue")

    let readOnly = TerminalHostCapabilities.route(
        bundleIdentifier: bundle, role: "AXTextArea",
        valueIsSettable: false, selectedRangeIsSettable: true
    )
    expect(readOnly == .rejectTerminalScreen && !readOnly.mayReadAXValue,
           "Read-only terminal buffers must not be read as editable drafts")

    let missingRange = TerminalHostCapabilities.route(
        bundleIdentifier: bundle, role: "AXTextField",
        valueIsSettable: true, selectedRangeIsSettable: false
    )
    expect(missingRange == .rejectTerminalScreen && !missingRange.mayReadAXValue,
           "A writable value without a writable range is not a verified terminal draft")

    let secureField = TerminalHostCapabilities.route(
        bundleIdentifier: bundle, role: "AXTextField", subrole: "AXSecureTextField",
        valueIsSettable: true, selectedRangeIsSettable: true
    )
    expect(secureField == .rejectTerminalScreen && !secureField.mayReadAXValue,
           "Secure text fields must never be admitted as terminal drafts")

    let editable = TerminalHostCapabilities.route(
        bundleIdentifier: bundle, role: "AXTextArea",
        valueIsSettable: true, selectedRangeIsSettable: true
    )
    expect(editable == .editableTerminalDraft && editable.requiresTerminalObservation,
           "A verified terminal AX field must use the observed editable-draft path")
}

let vscodeEditor = TerminalHostCapabilities.route(
    bundleIdentifier: "com.microsoft.VSCode",
    role: "AXTextArea",
    identifiers: ["editor"],
    domClassNames: ["monaco-editor"],
    isInWebArea: true,
    valueIsSettable: true,
    selectedRangeIsSettable: true
)
expect(vscodeEditor == .editableVSCodeEditor && vscodeEditor.mayReadAXValue,
       "A positively marked ordinary Monaco editor must not be classified as a terminal")
expect(!vscodeEditor.requiresTerminalObservation,
       "The hybrid-host editor path must not claim the terminal observation guarantee")

for classes in [Set(["xterm-helper-textarea"]), Set(["xterm"])] {
    let xtermHelper = TerminalHostCapabilities.route(
        bundleIdentifier: "com.microsoft.VSCode",
        role: "AXTextArea",
        identifiers: ["input"],
        domClassNames: classes,
        isInWebArea: true,
        valueIsSettable: true,
        selectedRangeIsSettable: true
    )
    expect(xtermHelper == .rejectTerminalScreen && !xtermHelper.mayReadAXValue,
           "xterm.js helper/control class evidence must not become a draft, even if writable")
}

let vscodeIMETextarea = TerminalHostCapabilities.route(
    bundleIdentifier: "com.microsoft.VSCode",
    role: "AXTextArea",
    identifiers: ["editor"],
    domClassNames: ["monaco-editor", "inputarea"],
    isInWebArea: true,
    valueIsSettable: true,
    selectedRangeIsSettable: true
)
expect(vscodeIMETextarea == .rejectUnclassifiedHybridTarget && !vscodeIMETextarea.mayReadAXValue,
       "An auxiliary editor textarea that may contain only IME composition must fail closed")

let unknownVSCodeField = TerminalHostCapabilities.route(
    bundleIdentifier: "com.microsoft.VSCode",
    role: nil,
    identifiers: [],
    domClassNames: ["xterm-helper-textarea-extra"],
    isInWebArea: true,
    valueIsSettable: true,
    selectedRangeIsSettable: true
)
expect(unknownVSCodeField == .rejectUnclassifiedHybridTarget && !unknownVSCodeField.mayReadAXValue,
       "Unverified VS Code shapes must fail closed without fuzzy xterm claims")

let safariRoute = TerminalHostCapabilities.route(
    bundleIdentifier: "com.apple.Safari",
    role: "AXTextArea",
    valueIsSettable: true,
    selectedRangeIsSettable: true
)
expect(safariRoute == .ordinary,
       "Non-terminal web applications must retain ordinary capture routing")
expect(AccessibilityTextClient.browserWriteStrategy(
    isWebInput: true, selectionRangeIsSettable: true
) == .paste, "Writable web editor selection must retain the existing paste route")
expect(AccessibilityTextClient.browserWriteStrategy(
    isWebInput: true, selectionRangeIsSettable: false
) == .keyboardFallback, "Unsupported non-terminal web controls must retain the existing fallback")

expect(AccessibilityTextClient.snapshotStateMatches(
    originalValue: "draft", originalRange: NSRange(location: 5, length: 0),
    currentValue: "draft", currentRange: NSRange(location: 5, length: 0)
), "An unchanged original value and cursor remain writable")
expect(!AccessibilityTextClient.snapshotStateMatches(
    originalValue: "draft", originalRange: NSRange(location: 5, length: 0),
    currentValue: "changed", currentRange: NSRange(location: 5, length: 0)
), "Changed original text must reject a stale write")
expect(!AccessibilityTextClient.snapshotStateMatches(
    originalValue: "draft", originalRange: NSRange(location: 5, length: 0),
    currentValue: "draft", currentRange: NSRange(location: 2, length: 0)
), "Changed cursor range must reject a stale write")

let verifiedTerminalValue = "译文🙂"
let verifiedTerminalRange = NSRange(location: 3, length: 0)
try AccessibilityTextClient.verifyTerminalDraftPostWriteState(
    expectedValue: verifiedTerminalValue,
    currentValue: verifiedTerminalValue,
    expectedRange: verifiedTerminalRange,
    currentRange: verifiedTerminalRange
)
expect(true, "Terminal draft writeback must accept the verified value and caret")
for (currentValue, currentRange) in [
    ("unexpected" as String?, verifiedTerminalRange as NSRange?),
    (verifiedTerminalValue as String?, NSRange(location: 2, length: 0) as NSRange?),
    (nil as String?, verifiedTerminalRange as NSRange?)
] {
    var rejectedTerminalWrite = false
    do {
        try AccessibilityTextClient.verifyTerminalDraftPostWriteState(
            expectedValue: verifiedTerminalValue,
            currentValue: currentValue,
            expectedRange: verifiedTerminalRange,
            currentRange: currentRange
        )
    } catch AccessibilityTextClient.Error.terminalWriteFailed {
        rejectedTerminalWrite = true
    }
    expect(rejectedTerminalWrite,
           "Unverified terminal value or caret must stop without retry or rollback")
}

for mode in [AccessibilityTextClient.WriteMode.keyboardPaste, .terminalPaste] {
    let terminalSnapshot = AccessibilityTextClient.Snapshot(
        element: elementA, applicationProcessIdentifier: 101,
        originalValue: "source", originalSelectedRange: NSRange(location: 0, length: 6),
        selection: FocusedTextSelection(text: "source", range: NSRange(location: 0, length: 6)),
        writeMode: mode, isTerminalBuffer: true
    )
    for unsafeText in ["line one\nline two", "text\tmore", "text\r", "text\u{1B}"] {
        var rejected = false
        do {
            try AccessibilityTextClient.validateReplacement(unsafeText, for: terminalSnapshot)
        } catch AccessibilityTextClient.Error.unsafeTerminalTranslation {
            rejected = true
        }
        expect(rejected, "Every terminal write path must reject control characters")
    }
    try AccessibilityTextClient.validateReplacement("single line", for: terminalSnapshot)
    expect(true, "Single-line terminal translation must remain allowed")
}
let editableDraftSnapshot = AccessibilityTextClient.Snapshot(
    element: elementA, applicationProcessIdentifier: 101,
    originalValue: "first line\n第二行🙂", originalSelectedRange: NSRange(location: 0, length: 18),
    selection: FocusedTextSelection(
        text: "first line\n第二行🙂", range: NSRange(location: 0, length: 18)
    ),
    writeMode: .value,
    isTerminalBuffer: true,
    isEditableTerminalDraft: true
)
try AccessibilityTextClient.validateReplacement("translated line\n译文🙂", for: editableDraftSnapshot)
expect(true, "Verified editable AX drafts may retain multiline and emoji text")
var rejectedEditableDraftControl = false
do {
    try AccessibilityTextClient.validateReplacement("unsafe\u{1B}text", for: editableDraftSnapshot)
} catch AccessibilityTextClient.Error.unsafeTerminalTranslation {
    rejectedEditableDraftControl = true
}
expect(rejectedEditableDraftControl,
       "Editable AX drafts may reject non-text control characters without banning newlines")
let ordinarySnapshot = AccessibilityTextClient.Snapshot(
    element: elementA, applicationProcessIdentifier: 101,
    originalValue: "source", originalSelectedRange: NSRange(location: 0, length: 6),
    selection: FocusedTextSelection(text: "source", range: NSRange(location: 0, length: 6)),
    writeMode: .value
)
try AccessibilityTextClient.validateReplacement("line one\nline two", for: ordinarySnapshot)
expect(true, "Ordinary editors and terminal search fields must retain multiline support")

private final class CompletionStub: @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [LocalModelHTTPResponse] = []
    private(set) var bodies: [[String: Any]] = []

    func enqueue(_ responses: LocalModelHTTPResponse...) {
        lock.withLock { queued = responses }
    }

    var remaining: Int { lock.withLock { queued.count } }

    func send(_ body: Data) throws -> LocalModelHTTPResponse {
        try lock.withLock {
            bodies.append((try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:])
            guard !queued.isEmpty else { throw LocalModelHTTPError.unreachable }
            return queued.removeFirst()
        }
    }
}

private func completion(_ content: String, reason: String? = nil, status: Int = 200) -> LocalModelHTTPResponse {
    var choice: [String: Any] = ["message": ["role": "assistant", "content": content]]
    if let reason { choice["finish_reason"] = reason }
    return LocalModelHTTPResponse(
        status: status,
        body: try! JSONSerialization.data(withJSONObject: ["choices": [choice]])
    )
}

private let completionStub = CompletionStub()
let lightModel = LocalTranslationModelCatalog.model(for: .light)
let provider = LocalModelTranslationProvider(model: lightModel) { body in
    try completionStub.send(body)
}
let request = TextTranslationRequest(sourceText: "测试输入")
completionStub.enqueue(completion("  Test input.\n", reason: "stop"))
let translated = try await provider.translate(request)
expect(translated == "Test input.", "Local translation must return the trimmed model output")
let sentBody = completionStub.bodies.last ?? [:]
let sentMessages = sentBody["messages"] as? [[String: Any]] ?? []
expect(sentMessages.count == 1 && sentMessages.first?["role"] as? String == "user",
       "Hy-MT2 takes a single user message and no system prompt")
expect((sentMessages.first?["content"] as? String)?.contains("测试输入") == true,
       "The prompt must carry the source text")
expect(sentBody["max_tokens"] as? Int == LocalTranslationModelCatalog.sampling.maxTokens
        && sentBody["top_k"] as? Int == LocalTranslationModelCatalog.sampling.topK
        && sentBody["stream"] as? Bool == false,
       "The request must use the catalog sampling and no streaming")

completionStub.enqueue(completion("Partial", reason: "length"))
var budgetFailure = false
do {
    _ = try await provider.translate(request)
} catch LocalModelTranslationError.outputBudgetExhausted {
    budgetFailure = true
}
expect(budgetFailure && completionStub.remaining == 0, "Truncated output must fail without returning partial text")

completionStub.enqueue(completion("Without finish reason."))
let compatible = try await provider.translate(request)
expect(compatible == "Without finish reason.", "Responses without finish_reason must remain supported")

completionStub.enqueue(completion("   ", reason: "stop"))
var emptyRejected = false
do {
    _ = try await provider.translate(request)
} catch LocalModelTranslationError.emptyResponse {
    emptyRejected = true
}
expect(emptyRejected, "An empty completion must not be written as a translation")

completionStub.enqueue(LocalModelHTTPResponse(status: 503, body: Data(#"{"error":{"message":"Loading model"}}"#.utf8)))
var httpFailure: LocalModelTranslationError?
do {
    _ = try await provider.translate(request)
} catch let error as LocalModelTranslationError {
    httpFailure = error
}
expect(httpFailure == .httpFailure(statusCode: 503, message: "Loading model"), "Server errors must surface status and message")

let requestsBeforeEmpty = completionStub.bodies.count
var emptySourceRejected = false
do {
    _ = try await provider.translate(TextTranslationRequest(sourceText: "  "))
} catch LocalModelTranslationError.emptySource {
    emptySourceRejected = true
}
expect(emptySourceRejected && completionStub.bodies.count == requestsBeforeEmpty, "Blank source must not reach the model")

expect(AccessibilityTextClient.pasteMatchesExpected("before translated after", expected: "before translated after"), "Exact browser replacement must succeed")
expect(AccessibilityTextClient.browserWriteStrategy(isWebInput: true, selectionRangeIsSettable: false) == .keyboardFallback, "Web inputs must never fall through to direct AXValue writes")
expect(AccessibilityTextClient.browserWriteStrategy(isWebInput: true, selectionRangeIsSettable: true) == .paste, "Web inputs with writable selection must use paste")
expect(AccessibilityTextClient.browserWriteStrategy(isWebInput: false, selectionRangeIsSettable: true) == .notWeb, "Native inputs must retain native writeback")
expect(AccessibilityTextClient.browserWriteStrategy(isWebInput: false, selectionRangeIsSettable: false) == .notWeb, "Native inputs without writable selection must retain native writeback")
expect(AccessibilityTextClient.Error.terminalRecoveryRequired(originalText: "private source").diagnosticCode == "terminal_recovery_required", "Diagnostic categories must exclude recovery text")
expect(AccessibilityTextClient.verifiedSelectionText(selectedText: "选中", value: nil, range: nil) == "选中", "Opaque value with AX selected text must remain supported")
expect(AccessibilityTextClient.verifiedSelectionText(selectedText: nil, value: "a中文b", range: NSRange(location: 1, length: 2)) == "中文", "Readable AX range must support selected text fallback")
expect(AccessibilityTextClient.verifiedSelectionText(selectedText: nil, value: nil, range: nil) == nil, "A clipboard-only control cannot supply attributed source text")
expect(AccessibilityTextClient.verifiedSelectionText(selectedText: nil, value: "a", range: NSRange(location: NSNotFound, length: 4)) == nil, "Invalid AX ranges must fail closed without overflowing")
expect(!AccessibilityTextClient.pasteMatchesExpected("translated old original x", expected: "translated new original"), "Existing translated substring plus unrelated edits must not pass writeback")
expect(!AccessibilityTextClient.pasteMatchesExpected("before translated after extra", expected: "before translated after"), "Browser verification must reject misplaced or extra input")

let isolatedPasteboard = NSPasteboard.withUniqueName()
defer { isolatedPasteboard.releaseGlobally() }
isolatedPasteboard.setString("original", forType: .string)
let clearedScope = ScopedPasteboard(pasteboard: isolatedPasteboard)
isolatedPasteboard.clearContents()
clearedScope.trackLatestChange()
clearedScope.restoreIfUnchanged()
expect(isolatedPasteboard.string(forType: .string) == "original", "Failure after clearing must restore original clipboard")
let concurrentScope = ScopedPasteboard(pasteboard: isolatedPasteboard)
isolatedPasteboard.clearContents()
isolatedPasteboard.setString("temporary translation", forType: .string)
concurrentScope.trackLatestChange()
isolatedPasteboard.clearContents()
isolatedPasteboard.setString("user copied later", forType: .string)
expect(!concurrentScope.isUnchanged, "Concurrent clipboard update must invalidate pending paste")
concurrentScope.restoreIfUnchanged()
expect(isolatedPasteboard.string(forType: .string) == "user copied later", "Restoration must preserve concurrent clipboard updates")

print("KEYI regression checks passed: \(checkCount)")
