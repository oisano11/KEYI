import Combine
import Darwin
import Foundation
import KEYICore
import KEYITranslationClient
import KEYITranslationService
@testable import KEYIUI

private struct TerminalDraftCheckFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
private func terminalDraftCheck(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws -> Int {
    guard condition() else {
        throw TerminalDraftCheckFailure(message: message)
    }
    return 1
}

@MainActor
private func waitForTerminalDraftCheck(
    _ condition: () -> Bool,
    _ message: String
) async throws {
    for _ in 0..<200 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw TerminalDraftCheckFailure(message: message)
}

/// Runs deterministic state-machine checks without creating a window or
/// connecting to the user's translation service.
@MainActor
func runTerminalDraftEditorChecks() async throws -> Int {
    var checks = 0

    // Translation receives exactly the current draft with no host context, and
    // replaces only the editable draft while preserving the immutable source.
    let source = "git status"
    var observedText: String?
    var observedContextIsNil = false
    var observedProviderIsNil = false
    var observedSourceLanguageIsNil = false
    var observedTargetLanguageIsNil = false
    var observedSceneIsNil = false
    var observedStyleIsNil = false
    var observedTimeout: Double?
    var committedText: String?
    var commitCount = 0
    var cancelCount = 0
    let successModel = TerminalDraftEditorModel(
        sourceText: source,
        translator: { request in
            observedText = request.text
            observedContextIsNil = request.contextText == nil
            observedProviderIsNil = request.providerID == nil
            observedSourceLanguageIsNil = request.sourceLanguage == nil
            observedTargetLanguageIsNil = request.targetLanguage == nil
            observedSceneIsNil = request.scene == nil
            observedStyleIsNil = request.englishStyle == nil
            observedTimeout = request.timeoutSeconds
            return "show the working tree status"
        },
        onCommit: { value in
            committedText = value
            commitCount += 1
        },
        onCancel: { cancelCount += 1 }
    )
    successModel.translate()
    try await waitForTerminalDraftCheck(
        { !successModel.isTranslating },
        "成功翻译请求未结束"
    )
    checks += try terminalDraftCheck(observedText == source, "只把当前 draft 传给翻译服务")
    checks += try terminalDraftCheck(observedContextIsNil, "翻译请求 contextText 必须为空")
    checks += try terminalDraftCheck(observedProviderIsNil, "未指定提供方，沿用 KEYI 设置")
    checks += try terminalDraftCheck(observedSourceLanguageIsNil, "未指定源语言")
    checks += try terminalDraftCheck(observedTargetLanguageIsNil, "未指定目标语言")
    checks += try terminalDraftCheck(observedSceneIsNil, "未指定翻译场景")
    checks += try terminalDraftCheck(observedStyleIsNil, "未指定表达风格")
    checks += try terminalDraftCheck(observedTimeout == 30, "翻译超时固定为 30 秒")
    checks += try terminalDraftCheck(
        successModel.sourceText == source && successModel.draftText == "show the working tree status",
        "译文只替换 draft，原始 source 保持不变"
    )
    checks += try terminalDraftCheck(commitCount == 0, "翻译完成不得自动 commit")
    successModel.restoreOriginal()
    checks += try terminalDraftCheck(successModel.draftText == source, "还原原文必须精确保留 source")
    successModel.editDraft("edited command")
    checks += try terminalDraftCheck(successModel.sourceText == source, "编辑 draft 不得改写 source")
    checks += try terminalDraftCheck(successModel.commit(), "显式完成动作应调用 commit")
    checks += try terminalDraftCheck(
        commitCount == 1 && committedText == "edited command",
        "commit 只交付用户当前 draft"
    )
    checks += try terminalDraftCheck(cancelCount == 0, "成功 commit 不应再调用 cancel")

    // Editing while a response is pending cancels it; even a translator that
    // ignores cancellation cannot overwrite the newer user draft.
    var modificationContinuation: CheckedContinuation<String, Error>?
    var modificationRequestReceived = false
    var modificationTranslatorReturned = false
    let modificationSource = "original draft"
    let modificationModel = TerminalDraftEditorModel(
        sourceText: modificationSource,
        translator: { _ in
            modificationRequestReceived = true
            let value = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<String, Error>) in
                modificationContinuation = continuation
            }
            modificationTranslatorReturned = true
            return value
        },
        onCommit: { _ in },
        onCancel: {}
    )
    modificationModel.translate()
    try await waitForTerminalDraftCheck(
        { modificationRequestReceived },
        "修改用例没有收到注入的翻译请求"
    )
    modificationModel.editDraft("newer user draft")
    modificationContinuation?.resume(returning: "stale translation")
    try await waitForTerminalDraftCheck(
        { modificationTranslatorReturned },
        "修改用例的延迟翻译没有返回"
    )
    await Task.yield()
    checks += try terminalDraftCheck(
        modificationModel.sourceText == modificationSource
            && modificationModel.draftText == "newer user draft",
        "修改草稿后，迟到译文不得覆盖新 draft 或改动 source"
    )

    // Explicit cancellation closes the model session, calls only onCancel, and
    // gives a late response no write path.
    var cancelContinuation: CheckedContinuation<String, Error>?
    var cancelRequestReceived = false
    var cancelTranslatorReturned = false
    var cancelledCommitCount = 0
    var cancelledCallbackCount = 0
    let cancelSource = "cancel me"
    let cancelModel = TerminalDraftEditorModel(
        sourceText: cancelSource,
        translator: { _ in
            cancelRequestReceived = true
            let value = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<String, Error>) in
                cancelContinuation = continuation
            }
            cancelTranslatorReturned = true
            return value
        },
        onCommit: { _ in cancelledCommitCount += 1 },
        onCancel: { cancelledCallbackCount += 1 }
    )
    cancelModel.translate()
    try await waitForTerminalDraftCheck({ cancelRequestReceived }, "取消用例未收到翻译请求")
    cancelModel.cancel()
    cancelContinuation?.resume(returning: "must not be applied")
    try await waitForTerminalDraftCheck({ cancelTranslatorReturned }, "取消用例的迟到翻译没有返回")
    await Task.yield()
    cancelModel.cancel() // Idempotence: closing after clicking Cancel is harmless.
    checks += try terminalDraftCheck(
        !cancelModel.isActive && cancelModel.draftText == cancelSource,
        "取消后会话关闭且迟到结果不改 draft"
    )
    checks += try terminalDraftCheck(
        cancelledCallbackCount == 1 && cancelledCommitCount == 0,
        "取消只调用一次 onCancel，绝不自动 commit"
    )

    // Losing window focus has the same stale-response protection, but is not a
    // user cancellation and therefore does not invoke the cancel callback.
    var blurContinuation: CheckedContinuation<String, Error>?
    var blurRequestReceived = false
    var blurTranslatorReturned = false
    var blurCancelCount = 0
    let blurSource = "focus guarded draft"
    let blurModel = TerminalDraftEditorModel(
        sourceText: blurSource,
        translator: { _ in
            blurRequestReceived = true
            let value = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<String, Error>) in
                blurContinuation = continuation
            }
            blurTranslatorReturned = true
            return value
        },
        onCommit: { _ in },
        onCancel: { blurCancelCount += 1 }
    )
    var publishedFocusStates: [Bool] = []
    let focusSubscription = blurModel.$isWindowFocused.dropFirst().sink {
        publishedFocusStates.append($0)
    }
    blurModel.translate()
    try await waitForTerminalDraftCheck({ blurRequestReceived }, "失焦用例未收到翻译请求")
    blurModel.windowDidResignKey()
    blurContinuation?.resume(returning: "stale after blur")
    try await waitForTerminalDraftCheck({ blurTranslatorReturned }, "失焦用例的延迟翻译没有返回")
    await Task.yield()
    checks += try terminalDraftCheck(
        !blurModel.isWindowFocused && blurModel.draftText == blurSource,
        "失焦后取消请求，迟到译文不得覆盖 source"
    )
    checks += try terminalDraftCheck(blurCancelCount == 0, "单纯失焦不应触发 onCancel")
    checks += try terminalDraftCheck(
        publishedFocusStates == [false],
        "失焦必须向焦点 publisher 订阅者发布通知"
    )
    checks += try terminalDraftCheck(
        !blurModel.canTranslate && !blurModel.canCommit,
        "失焦时翻译与完成动作都必须禁用"
    )
    blurModel.windowDidBecomeKey()
    checks += try terminalDraftCheck(
        publishedFocusStates == [false, true],
        "恢复焦点必须向焦点 publisher 订阅者发布通知"
    )
    checks += try terminalDraftCheck(
        blurModel.canTranslate && blurModel.canCommit,
        "恢复焦点无需修改草稿即可启用翻译与完成动作"
    )
    checks += try terminalDraftCheck(
        blurModel.sourceText.utf8.elementsEqual(blurSource.utf8)
            && blurModel.draftText.utf8.elementsEqual(blurSource.utf8),
        "失焦与恢复焦点不得改变 source 或 draft 的 UTF-8 字节"
    )
    focusSubscription.cancel()

    // Translation errors leave the source draft intact and surface an error.
    let failureSource = "preserve on failure"
    let failureModel = TerminalDraftEditorModel(
        sourceText: failureSource,
        translator: { _ in throw TerminalDraftCheckFailure(message: "synthetic failure") },
        onCommit: { _ in },
        onCancel: {}
    )
    failureModel.translate()
    try await waitForTerminalDraftCheck(
        { !failureModel.isTranslating },
        "失败用例翻译请求未结束"
    )
    checks += try terminalDraftCheck(
        failureModel.sourceText == failureSource && failureModel.draftText == failureSource,
        "翻译失败必须保留原始草稿"
    )
    checks += try terminalDraftCheck(failureModel.errorMessage != nil, "翻译失败应显示错误提示")

    // A failed file handoff leaves the editor active with the exact attempted
    // text still available for correction/retry.
    let handoffSource = "draft to keep"
    let handoffModel = TerminalDraftEditorModel(
        sourceText: handoffSource,
        onCommit: { _ in throw TerminalDraftCheckFailure(message: "synthetic write failure") },
        onCancel: {}
    )
    let handoffSucceeded = handoffModel.commit()
    checks += try terminalDraftCheck(!handoffSucceeded && handoffModel.isActive, "完成失败后窗口会话仍活动")
    checks += try terminalDraftCheck(
        handoffModel.draftText == handoffSource && handoffModel.errorMessage != nil,
        "完成失败保留原草稿并显示错误"
    )

    // Draft validation allows normal multiline/tab input but rejects empty,
    // oversized, NUL, ESC, and other control characters.
    checks += try terminalDraftCheck(
        TerminalDraftEditorModel.validationMessage(for: "line one\n\tline two\r") == nil,
        "多行与 Tab 草稿应可用"
    )
    checks += try terminalDraftCheck(
        TerminalDraftEditorModel.validationMessage(for: "") != nil,
        "空草稿必须拒绝"
    )
    checks += try terminalDraftCheck(
        TerminalDraftEditorModel.validationMessage(for: String(repeating: "a", count: 65_537)) != nil,
        "超过 65536 UTF-8 字节的草稿必须拒绝"
    )
    checks += try terminalDraftCheck(
        TerminalDraftEditorModel.validationMessage(for: "safe\u{0000}bad") != nil,
        "NUL 必须拒绝"
    )
    checks += try terminalDraftCheck(
        TerminalDraftEditorModel.validationMessage(for: "safe\u{001B}bad") != nil,
        "ESC 必须拒绝"
    )
    checks += try terminalDraftCheck(
        TerminalDraftEditorModel.validationMessage(for: "safe\u{0007}bad") != nil,
        "其他控制字符必须拒绝"
    )

    checks += try await runTerminalDraftLocalServiceFileChainChecks()
    return checks
}

private struct TerminalDraftRequestObservation: Sendable {
    let text: String
    let contextText: String?
    let providerID: String?
}

private actor TerminalDraftRequestRecorder {
    private var observations: [TerminalDraftRequestObservation] = []

    func append(_ request: TranslationServiceRequest) {
        observations.append(TerminalDraftRequestObservation(
            text: request.text,
            contextText: request.contextText,
            providerID: request.providerID
        ))
    }

    func snapshot() -> [TerminalDraftRequestObservation] { observations }
}

private struct TerminalDraftStubResolver: TranslationServiceResolving {
    let recorder: TerminalDraftRequestRecorder

    func translate(_ request: TranslationServiceRequest) async throws -> TranslationServiceTranslation {
        await recorder.append(request)
        return TranslationServiceTranslation(
            text: "translated:\(request.text)",
            providerID: "keyi-app-checks-stub",
            elapsedSeconds: 0.001
        )
    }

    func status() async -> TranslationServiceStatus {
        TranslationServiceStatus(
            selectedProviderID: "keyi-app-checks-stub",
            providerIDs: ["keyi-app-checks-stub"]
        )
    }
}

private struct TerminalDraftHistoryTemplate {
    let fileName: String
    let agentID: String
    let text: String
    let historyMarker: String
}

@MainActor
private func runTerminalDraftLocalServiceFileChainChecks() async throws -> Int {
    var checks = 0
    let temporaryDirectory = try makeTerminalDraftTemporaryDirectory()
    // This is the exact private mkdtemp directory created above; it contains no
    // user files and is removed after the isolated service has stopped.
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let gooseHistory = "# Recent conversation for context (newest first):\n\nGOOSE_SECRET_HISTORY_NOT_FOR_TRANSLATION\n"
    let gooseBody = "帮我检查这份代码🙂\n保留第二行\t以及空格  "
    let gooseTemplate = "# Goose Prompt Editor\n\n# Your prompt:\n\(gooseBody)\n\(gooseHistory)"

    let claudeHistoryMarker = "CLAUDE_SECRET_PREVIOUS_ANSWER_NOT_FOR_TRANSLATION"
    let claudePrefix = "# ─── Claude's last response (for reference; removed on save) ───\n# \(claudeHistoryMarker)\n#\n# ─── Write your reply below this line ──────────────────────────\n"
    let claudeTemplate = claudePrefix + "请解释这个错误🙂\n保留后续一行"

    let templates = [
        TerminalDraftHistoryTemplate(
            fileName: "goose-prompt.txt",
            agentID: "goose",
            text: gooseTemplate,
            historyMarker: "GOOSE_SECRET_HISTORY_NOT_FOR_TRANSLATION"
        ),
        TerminalDraftHistoryTemplate(
            fileName: "claude-prompt.txt",
            agentID: "claude",
            text: claudeTemplate,
            historyMarker: claudeHistoryMarker
        )
    ]

    let recorder = TerminalDraftRequestRecorder()
    let socketPath = temporaryDirectory.appendingPathComponent("translation.sock").path
    let server = TranslationServiceServer(
        socketPath: socketPath,
        resolver: TerminalDraftStubResolver(recorder: recorder)
    )
    try server.start()
    defer { server.stop() }

    let client = TranslationServiceClient(socketPath: socketPath)
    for template in templates {
        let draftURL = temporaryDirectory.appendingPathComponent(template.fileName)
        let originalBytes = Data(template.text.utf8)
        guard FileManager.default.createFile(
            atPath: draftURL.path,
            contents: originalBytes,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw TerminalDraftCheckFailure(message: "无法创建隔离的临时草稿文件：\(template.fileName)")
        }

        let snapshot = try TerminalDraftFile.capture(path: draftURL.path)
        let document = try TerminalEditorDocument(text: snapshot.text, agentID: template.agentID)
        let requestsBefore = await recorder.snapshot()
        let requestCountBefore = requestsBefore.count
        var commitCount = 0
        var cancelCount = 0
        let model = TerminalDraftEditorModel(
            sourceText: document.draft,
            translator: { request in try await client.translate(request) },
            onCommit: { translatedDraft in
                let replacedDocument = try document.replacingDraft(with: translatedDraft)
                try TerminalDraftFile.commit(replacedDocument, to: snapshot)
                commitCount += 1
            },
            onCancel: { cancelCount += 1 }
        )

        // This remains a file + local socket integration check: no editor UI,
        // shell command, process launch, accessibility, clipboard, or key event.
        model.translate()
        try await waitForTerminalDraftCheck(
            { !model.isTranslating },
            "\(template.agentID) 本地 wire 翻译请求未结束"
        )

        checks += try terminalDraftCheck(
            model.draftText == "translated:\(document.draft)",
            "\(template.agentID) 生产 client/server/stub 链路应返回译文"
        )
        let bytesBeforeConfirmation = try Data(contentsOf: draftURL)
        checks += try terminalDraftCheck(
            bytesBeforeConfirmation == originalBytes,
            "\(template.agentID) 翻译完成但未确认时草稿文件必须逐字节不变"
        )
        checks += try terminalDraftCheck(
            commitCount == 0 && cancelCount == 0,
            "\(template.agentID) 翻译结果不能自动写回或取消"
        )

        let observations = await recorder.snapshot()
        checks += try terminalDraftCheck(
            observations.count == requestCountBefore + 1,
            "\(template.agentID) 只产生一条服务请求"
        )
        guard let observation = observations.last else {
            throw TerminalDraftCheckFailure(message: "\(template.agentID) stub resolver 未收到请求")
        }
        checks += try terminalDraftCheck(
            observation.text == document.draft,
            "\(template.agentID) provider 只收到模板当前 draft"
        )
        checks += try terminalDraftCheck(
            observation.contextText == nil && observation.providerID == nil,
            "\(template.agentID) contextText/providerID 留空，沿用 KEYI 服务设置"
        )
        checks += try terminalDraftCheck(
            !observation.text.contains(template.historyMarker),
            "\(template.agentID) 历史 marker 不得发送给 provider"
        )

        let expectedText = try document.replacingDraft(with: model.draftText)
        let expectedBytes = Data(expectedText.utf8)
        checks += try terminalDraftCheck(model.commit(), "\(template.agentID) 用户明确 commit 应成功")
        checks += try terminalDraftCheck(
            commitCount == 1 && cancelCount == 0,
            "\(template.agentID) 明确 commit 只写回一次，不调用 cancel"
        )
        let committedBytes = try Data(contentsOf: draftURL)
        checks += try terminalDraftCheck(
            committedBytes == expectedBytes,
            "\(template.agentID) commit 只替换 draft，历史/模板其余原始 bytes 保留"
        )
        checks += try terminalDraftCheck(
            String(decoding: committedBytes, as: UTF8.self).contains(template.historyMarker),
            "\(template.agentID) 原历史块仍留在文件中"
        )
    }

    return checks
}

private func makeTerminalDraftTemporaryDirectory() throws -> URL {
    var template = Array("/tmp/keyi-terminal-chain-XXXXXX".utf8CString)
    guard let path = template.withUnsafeMutableBufferPointer({ buffer -> String? in
        guard let baseAddress = buffer.baseAddress,
              mkdtemp(baseAddress) != nil else {
            return nil
        }
        return String(cString: baseAddress)
    }) else {
        throw TerminalDraftCheckFailure(message: "mkdtemp 无法创建本地链路测试目录")
    }
    return URL(fileURLWithPath: path, isDirectory: true)
}
