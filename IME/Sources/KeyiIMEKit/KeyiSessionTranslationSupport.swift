import Carbon
import Foundation
import InputMethodKit
import KEYITranslationClient
import KeyiIMETranslation

/// Forwards the sink callbacks to the owning session. The controller keeps its
/// sink weakly, so the session owns this object.
final class KeyiSessionTranslationSink: KeyiAutomaticTranslationSink {
    private weak var session: InputSession?

    init(session: InputSession) {
        self.session = session
    }

    func automaticTranslation(render: KeyiAutomaticTranslationRender) {
        session?.applyAutomaticRender(render)
    }
}

/// The real client surface plus one diagnostics-only seam: the secure-input
/// answer. Production never sets `secureInputOverride`, so it always asks the
/// system. The diagnostics need it because any other process (a terminal with
/// Secure Keyboard Entry, a focused password field) makes the system answer
/// "secure" for the whole machine, which would make the checks depend on the
/// desktop.
final class KeyiSessionSurface: KeyiTranslationClientSurface {
    private let inner: KeyiIMKTextInputSurface
    private let secureInputOverride: () -> Bool?

    init(client: IMKTextInput, secureInputOverride: @escaping () -> Bool?) {
        inner = KeyiIMKTextInputSurface(client: client)
        self.secureInputOverride = secureInputOverride
    }

    func selectedRange() -> NSRange { inner.selectedRange() }
    func markedRange() -> NSRange { inner.markedRange() }
    func documentLength() -> Int { inner.documentLength() }
    func attributedSubstring(from range: NSRange) -> NSAttributedString? {
        inner.attributedSubstring(from: range)
    }
    func insertText(_ text: String, replacementRange: NSRange) {
        inner.insertText(text, replacementRange: replacementRange)
    }
    func hostBundleIdentifier() -> String? { inner.hostBundleIdentifier() }
    func clientChangeCount() -> Int { inner.clientChangeCount() }
    func noteObservedClientChange() { inner.noteObservedClientChange() }
    func isSecureInputEnabled() -> Bool {
        secureInputOverride() ?? inner.isSecureInputEnabled()
    }
}

/// Diagnostics-only translator: answers `EN(<source>)` deterministically, either
/// on the next main-queue turn or, while `holding`, only when released. It is
/// installed through `InputSession.diagnosticInstallFakeTranslation`, which
/// refuses to run unless `KEYI_IME_DIAGNOSTIC_FAKE_TRANSLATION=1` is set.
final class KeyiDiagnosticFakeTranslator {
    static let environmentKey = "KEYI_IME_DIAGNOSTIC_FAKE_TRANSLATION"

    static var isAllowed: Bool {
        ProcessInfo.processInfo.environment[environmentKey] == "1"
    }

    private final class Ticket: KeyiTranslationCancellable {
        let source: String
        let completion: @Sendable (Result<String, Error>) -> Void
        var cancelled = false

        init(source: String, completion: @escaping @Sendable (Result<String, Error>) -> Void) {
            self.source = source
            self.completion = completion
        }

        func cancel() { cancelled = true }
    }

    var holding = false
    private(set) var requests: [String] = []
    private var pending: [Ticket] = []

    static func english(for source: String) -> String { "EN(\(source))" }

    func translate(
        _ request: TranslationServiceRequest,
        completion: @escaping @Sendable (Result<String, Error>) -> Void
    ) -> KeyiTranslationCancellable {
        requests.append(request.text)
        let ticket = Ticket(source: request.text, completion: completion)
        if holding {
            pending.append(ticket)
        } else {
            DispatchQueue.main.async { Self.finish(ticket) }
        }
        return ticket
    }

    /// Answers every request that was held back.
    func releasePending() {
        let tickets = pending
        pending = []
        for ticket in tickets {
            DispatchQueue.main.async { Self.finish(ticket) }
        }
    }

    private static func finish(_ ticket: Ticket) {
        guard !ticket.cancelled else { return }
        ticket.completion(.success(english(for: ticket.source)))
    }
}
