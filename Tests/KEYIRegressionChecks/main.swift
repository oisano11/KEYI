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
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
private let access = FakeTextAccess()
let model = AppModel(
    settings: TranslationSettingsStore(defaults: defaults, legacyDefaults: nil),
    hotKeySettings: HotKeySettingsStore(defaults: defaults, legacyDefaults: nil),
    accessibility: access
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
let ordinarySnapshot = AccessibilityTextClient.Snapshot(
    element: elementA, applicationProcessIdentifier: 101,
    originalValue: "source", originalSelectedRange: NSRange(location: 0, length: 6),
    selection: FocusedTextSelection(text: "source", range: NSRange(location: 0, length: 6)),
    writeMode: .value
)
try AccessibilityTextClient.validateReplacement("line one\nline two", for: ordinarySnapshot)
expect(true, "Ordinary editors and terminal search fields must retain multiline support")

private final class CompletionStub: URLProtocol {
    nonisolated(unsafe) static var responses: [String] = []
    nonisolated(unsafe) static var budgets: [Int] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard !Self.responses.isEmpty else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        Self.budgets.append(json?["max_tokens"] as? Int ?? 0)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.responses.removeFirst().utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func completion(_ content: String, reason: String? = nil) -> String {
    var choice: [String: Any] = ["message": ["role": "assistant", "content": content]]
    if let reason { choice["finish_reason"] = reason }
    return String(data: try! JSONSerialization.data(withJSONObject: ["choices": [choice]]), encoding: .utf8)!
}

let sessionConfiguration = URLSessionConfiguration.ephemeral
sessionConfiguration.protocolClasses = [CompletionStub.self]
let session = URLSession(configuration: sessionConfiguration)
defer { session.invalidateAndCancel() }
let provider = LocalModelTranslationProvider(
    configuration: LocalModelConfiguration(
        endpoint: URL(string: "http://keyi-regression.invalid/v1/chat/completions")!,
        model: "test-model", loadKey: "test-model"
    ),
    session: session,
    validateEndpoint: { _ in }
)
let request = TextTranslationRequest(sourceText: "Test input")
CompletionStub.responses = [completion("Partial", reason: "length"), completion("Complete.", reason: "stop")]
CompletionStub.budgets = []
let retried = try await provider.translate(request)
expect(retried == "Complete.", "Local translation must retry a nonempty truncated response")
expect(CompletionStub.budgets == [1024, 2048], "Retry must increase the output budget exactly once")

CompletionStub.responses = [completion("Partial", reason: "length"), completion("Still partial", reason: "length")]
var budgetFailure = false
do {
    _ = try await provider.translate(request)
} catch LocalModelTranslationError.outputBudgetExhausted {
    budgetFailure = true
}
expect(budgetFailure && CompletionStub.responses.isEmpty, "Repeated truncation must fail without returning partial text")

CompletionStub.responses = [completion("Without finish reason.")]
let compatible = try await provider.translate(request)
expect(compatible == "Without finish reason.", "Legacy responses without finish_reason must remain supported")

CompletionStub.responses = [completion("<think>Unfinished reasoning", reason: "stop")]
var reasoningRejected = false
do {
    _ = try await provider.translate(request)
} catch LocalModelTranslationError.emptyResponse {
    reasoningRejected = true
}
expect(reasoningRejected, "Unclosed reasoning must not be written as a translation")

CompletionStub.responses = [completion("<think>Reasoning</think>\nFinal.", reason: "stop")]
let cleaned = try await provider.translate(request)
expect(cleaned == "Final.", "Completed reasoning must be stripped without losing the translation")

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
