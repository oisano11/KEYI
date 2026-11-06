import AppKit
import SwiftUI
import KEYITranslationClient

/// An isolated editor session used by the terminal-draft helper process.
///
/// `sourceText` never changes. A successful translation replaces only `draftText`,
/// so the user can review/edit the result or restore the exact original draft.
@MainActor
internal final class TerminalDraftEditorModel: ObservableObject {
    typealias Translator = @MainActor (TranslationServiceRequest) async throws -> String

    @Published private(set) var sourceText: String
    @Published private(set) var draftText: String
    @Published private(set) var statusMessage: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isTranslating = false

    private(set) var isActive = true
    @Published private(set) var isWindowFocused = true
    private(set) var draftRevision: UInt64 = 0

    private let translator: Translator
    private let onCommit: @MainActor (String) throws -> Void
    private let onCancel: @MainActor () -> Void
    private var activeRequestID: String?
    private var translationTask: Task<Void, Never>?

    init(
        sourceText: String,
        translator: @escaping Translator = { request in
            try await TranslationServiceClient().translate(request)
        },
        onCommit: @escaping @MainActor (String) throws -> Void,
        onCancel: @escaping @MainActor () -> Void
    ) {
        self.sourceText = sourceText
        draftText = sourceText
        self.translator = translator
        self.onCommit = onCommit
        self.onCancel = onCancel
        errorMessage = Self.validationMessage(for: sourceText)
        statusMessage = "译文先保留在编辑器里，只有你确认后才交回当前工具。"
    }

    var draftByteCount: Int { draftText.utf8.count }

    var canTranslate: Bool {
        isActive && isWindowFocused && Self.validationMessage(for: draftText) == nil
    }

    var canCommit: Bool {
        isActive && isWindowFocused && Self.validationMessage(for: draftText) == nil
    }

    var canRestoreOriginal: Bool {
        isActive && draftText != sourceText
    }

    func editDraft(_ newValue: String) {
        guard isActive, newValue != draftText else { return }
        let cancelledPendingRequest = invalidateTranslation()
        draftText = newValue
        draftRevision &+= 1
        errorMessage = Self.validationMessage(for: newValue)
        statusMessage = cancelledPendingRequest
            ? "草稿已修改，旧翻译请求已取消。"
            : "草稿已修改；需要时可以重新翻译。"
    }

    func restoreOriginal() {
        editDraft(sourceText)
    }

    func translate() {
        guard isActive, isWindowFocused else { return }
        if let issue = Self.validationMessage(for: draftText) {
            errorMessage = issue
            statusMessage = nil
            return
        }

        _ = invalidateTranslation()
        let submittedDraft = draftText
        let submittedRevision = draftRevision
        let request = TranslationServiceRequest(
            text: submittedDraft,
            contextText: nil,
            timeoutSeconds: 30
        )
        let requestID = request.id
        let translator = self.translator

        activeRequestID = requestID
        errorMessage = nil
        statusMessage = "正在翻译当前草稿…"
        isTranslating = true
        translationTask = Task { @MainActor [weak self] in
            let result: Result<String, Error>
            do {
                result = .success(try await translator(request))
            } catch {
                result = .failure(error)
            }
            self?.receiveTranslation(
                result,
                requestID: requestID,
                submittedRevision: submittedRevision,
                submittedDraft: submittedDraft
            )
        }
    }

    /// Called by the window delegate. Losing key status invalidates any pending
    /// response before it can be reflected in the draft editor.
    func windowDidResignKey() {
        guard isActive else { return }
        isWindowFocused = false
        if invalidateTranslation() {
            statusMessage = "编辑窗口失焦，翻译请求已取消。"
        }
    }

    func windowDidBecomeKey() {
        guard isActive else { return }
        isWindowFocused = true
    }

    /// Returns true only after the user's explicit completion action succeeded.
    @discardableResult
    func commit() -> Bool {
        guard isActive, isWindowFocused else { return false }
        _ = invalidateTranslation()
        if let issue = Self.validationMessage(for: draftText) {
            errorMessage = issue
            statusMessage = nil
            return false
        }

        do {
            try onCommit(draftText)
            isActive = false
            isWindowFocused = false
            errorMessage = nil
            statusMessage = nil
            return true
        } catch {
            // Keep the exact text that the user attempted to deliver in the editor.
            errorMessage = "完成失败：\(error.localizedDescription)"
            statusMessage = "草稿仍保留在编辑器中。"
            return false
        }
    }

    /// Idempotent so the Cancel button followed by NSWindow.close() notifies the
    /// caller exactly once.
    func cancel() {
        guard isActive else { return }
        _ = invalidateTranslation()
        isActive = false
        isWindowFocused = false
        statusMessage = nil
        onCancel()
    }

    static func validationMessage(for text: String) -> String? {
        let byteCount = text.utf8.count
        guard byteCount > 0 else { return "草稿不能为空。" }
        guard byteCount <= TranslationServiceProtocol.maximumMessageBytes else {
            return "草稿超过 65536 字节上限。"
        }

        for scalar in text.unicodeScalars {
            let value = scalar.value
            // Multi-line shell drafts and pasted indentation are supported.
            if value == 0x09 || value == 0x0A || value == 0x0D { continue }
            if value <= 0x1F || (0x7F...0x9F).contains(value) {
                return "草稿含不允许的控制字符。"
            }
        }
        return nil
    }

    private func invalidateTranslation() -> Bool {
        let hadRequest = activeRequestID != nil || translationTask != nil
        activeRequestID = nil
        translationTask?.cancel()
        translationTask = nil
        isTranslating = false
        return hadRequest
    }

    private func receiveTranslation(
        _ result: Result<String, Error>,
        requestID: String,
        submittedRevision: UInt64,
        submittedDraft: String
    ) {
        guard isActive,
              isWindowFocused,
              activeRequestID == requestID,
              draftRevision == submittedRevision,
              draftText == submittedDraft else {
            return
        }

        activeRequestID = nil
        translationTask = nil
        isTranslating = false

        switch result {
        case let .success(translatedText):
            if let issue = Self.validationMessage(for: translatedText) {
                errorMessage = "译文无效：\(issue)"
                statusMessage = "原草稿已保留。"
                return
            }
            if translatedText != draftText {
                draftText = translatedText
                draftRevision &+= 1
            }
            errorMessage = nil
            statusMessage = "翻译完成；可以编辑结果、还原原文或完成交回。"
        case let .failure(error):
            errorMessage = Self.message(for: error)
            statusMessage = "翻译失败，原草稿已保留。"
        }
    }

    private static func message(for error: Error) -> String {
        guard let serviceError = error as? TranslationServiceClientError else {
            if error is CancellationError { return "翻译请求已取消。" }
            return "翻译失败：\(error.localizedDescription)"
        }
        switch serviceError {
        case .serviceUnavailable:
            return "无法连接 KEYI 翻译服务，请先运行 KEYI 可译。"
        case .invalidResponse, .timeout, .cancelled, .rejected:
            return serviceError.localizedDescription
        }
    }
}

/// A small Cocoa editor session for terminal drafts. It is intentionally a
/// standalone accessory window: it does not initialize the main app model,
/// register global shortcuts, inspect other applications, or send keystrokes.
public enum KEYITerminalEditor {
    @MainActor
    public static func run(
        source: String,
        title: String,
        completionLabel: String,
        onCommit: @escaping @MainActor (String) throws -> Void,
        onCancel: @escaping @MainActor () -> Void
    ) {
        let app = NSApplication.shared
        _ = app.setActivationPolicy(.accessory)

        let model = TerminalDraftEditorModel(
            sourceText: source,
            onCommit: onCommit,
            onCancel: onCancel
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.center()
        let delegate = TerminalDraftEditorWindowDelegate(model: model)
        window.delegate = delegate
        window.contentView = NSHostingView(
            rootView: TerminalDraftEditorView(
                model: model,
                completionLabel: completionLabel,
                closeWindow: { [weak window] in window?.close() }
            )
        )

        app.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // Keep the weak NSWindow.delegate alive for the entire Cocoa run loop.
        withExtendedLifetime(window) {
            withExtendedLifetime(delegate) {
                app.run()
            }
        }
    }
}

@MainActor
private struct TerminalDraftEditorView: View {
    @ObservedObject var model: TerminalDraftEditorModel
    let completionLabel: String
    let closeWindow: @MainActor () -> Void

    private var editorBinding: Binding<String> {
        Binding(
            get: { model.draftText },
            set: { model.editDraft($0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(completionLabel.hasPrefix("复制")
                 ? "输入或粘贴要翻译的草稿；确认后复制译文，再由你手动粘贴到当前工具。不会自动取文、粘贴或发送。"
                 : "只编辑当前草稿，不代按回车；当前工具的发送规则请看完成按钮。")
                .font(.callout)
                .foregroundStyle(.secondary)
            if completionLabel.contains("发送") {
                Text("当前工具在编辑器完成后可能立即发送。这一步是发送确认；不确定时请取消。")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            TextEditor(text: editorBinding)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 300)
                .padding(6)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.quaternary, lineWidth: 1)
                }

            HStack(spacing: 10) {
                Text("\(model.draftByteCount) UTF-8 字节")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.isTranslating {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在翻译…")
                        .font(.callout)
                }
                Button("翻译") {
                    model.translate()
                }
                .disabled(!model.canTranslate)
            }

            VStack(alignment: .leading, spacing: 4) {
                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                if let statusMessage = model.statusMessage {
                    Text(statusMessage)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("terminal-draft-status")

            HStack {
                Button("还原原文") {
                    model.restoreOriginal()
                }
                .disabled(!model.canRestoreOriginal)

                Spacer()

                Button("取消") {
                    model.cancel()
                    closeWindow()
                }
                .keyboardShortcut(.cancelAction)

                Button(completionLabel) {
                    if model.commit() {
                        closeWindow()
                    }
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!model.canCommit)
            }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 440)
    }
}

@MainActor
private final class TerminalDraftEditorWindowDelegate: NSObject, NSWindowDelegate {
    private let model: TerminalDraftEditorModel

    init(model: TerminalDraftEditorModel) {
        self.model = model
    }

    func windowDidBecomeKey(_ notification: Notification) {
        model.windowDidBecomeKey()
    }

    func windowDidResignKey(_ notification: Notification) {
        model.windowDidResignKey()
    }

    func windowWillClose(_ notification: Notification) {
        model.cancel()
        let app = NSApplication.shared
        app.stop(nil)
        // Wake the application run loop so stop() takes effect promptly.
        if let event = NSEvent.otherEvent(
            with: .applicationDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 0,
            data1: 0,
            data2: 0
        ) {
            app.postEvent(event, atStart: true)
        }
    }
}
