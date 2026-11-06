import Darwin
import Foundation
import KEYICore
@testable import KEYIUI

enum InstalledTerminalServiceCheckFailure: LocalizedError {
    case fixturePreparation
    case draftCapture
    case templateRejected
    case translationDidNotStart
    case translationTimedOut
    case translationRequestFailed
    case sourceChangedBeforeConfirmation
    case automaticWriteBack
    case invalidTranslation
    case commitFailed
    case outputVerificationFailed
    case checkInterrupted

    var errorDescription: String? {
        switch self {
        case .fixturePreparation:
            "隔离草稿 fixture 准备失败。"
        case .draftCapture:
            "无法安全读取隔离草稿。"
        case .templateRejected:
            "Goose 草稿模板未按预期解析。"
        case .translationDidNotStart:
            "已安装翻译服务请求未能启动。"
        case .translationTimedOut:
            "已安装翻译服务请求超时。"
        case .translationRequestFailed:
            "已安装翻译服务请求失败（详情已隐藏）。"
        case .sourceChangedBeforeConfirmation:
            "确认前隔离草稿文件发生变化。"
        case .automaticWriteBack:
            "翻译结果在明确确认前发生了写回。"
        case .invalidTranslation:
            "服务返回的译文为空或与测试原文相同。"
        case .commitFailed:
            "用户明确确认后的草稿写回失败。"
        case .outputVerificationFailed:
            "最终草稿、历史块或 UTF-8 校验失败。"
        case .checkInterrupted:
            "已安装翻译服务检查被中断。"
        }
    }
}

@MainActor
private func installedTerminalServiceCheck(
    _ condition: @autoclosure () -> Bool,
    failure: InstalledTerminalServiceCheckFailure
) throws -> Int {
    guard condition() else { throw failure }
    return 1
}

/// Opt-in smoke check through the real draft-file and default translation
/// client path. It requires the already-installed KEYI translation service.
@MainActor
func runInstalledTerminalServiceChecks() async throws -> Int {
    var checks = 0
    let temporaryDirectory = try makeInstalledTerminalServiceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let goosePrefix = "# Goose Prompt Editor\n\n# Your prompt:\n"
    let historyMarker = "SYNTHETIC_HISTORY_MUST_NOT_BE_TRANSLATED_8F3D"
    let gooseHistory = "# Recent conversation for context (newest first):\n\n\(historyMarker)\nFake previous answer 🙂\n"
    let prompt = "请把 KEYI 终端翻译集成检查文本译成当前设置的目标语言：\n换行与 emoji 🙂 都要保留在草稿中。"
    let expectedDraft = prompt + "\n"
    let gooseTemplate = goosePrefix + expectedDraft + gooseHistory
    let originalBytes = Data(gooseTemplate.utf8)
    let draftURL = temporaryDirectory.appendingPathComponent("goose-prompt.txt")

    guard FileManager.default.createFile(
        atPath: draftURL.path,
        contents: originalBytes,
        attributes: [.posixPermissions: 0o600]
    ) else {
        throw InstalledTerminalServiceCheckFailure.fixturePreparation
    }
    checks += 1

    let snapshot: TerminalDraftFile.Snapshot
    do {
        snapshot = try TerminalDraftFile.capture(path: draftURL.path)
    } catch {
        throw InstalledTerminalServiceCheckFailure.draftCapture
    }
    checks += 1

    let document: TerminalEditorDocument
    do {
        document = try TerminalEditorDocument(text: snapshot.text, agentID: "goose")
    } catch {
        throw InstalledTerminalServiceCheckFailure.templateRejected
    }
    checks += try installedTerminalServiceCheck(
        document.draft == expectedDraft && !document.draft.contains(historyMarker),
        failure: .templateRejected
    )

    var commitCount = 0
    var cancelCount = 0
    let model = TerminalDraftEditorModel(
        sourceText: document.draft,
        onCommit: { translatedDraft in
            do {
                let replacedDocument = try document.replacingDraft(with: translatedDraft)
                try TerminalDraftFile.commit(replacedDocument, to: snapshot)
                commitCount += 1
            } catch {
                throw InstalledTerminalServiceCheckFailure.commitFailed
            }
        },
        onCancel: { cancelCount += 1 }
    )
    defer { model.cancel() }

    // Omitting the translator uses TerminalDraftEditorModel's production
    // default: TranslationServiceClient() connected to the installed service.
    model.translate()
    checks += try installedTerminalServiceCheck(
        model.isTranslating,
        failure: .translationDidNotStart
    )

    var requestCompleted = false
    do {
        for _ in 0..<680 {
            if !model.isTranslating {
                requestCompleted = true
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    } catch {
        model.cancel()
        throw InstalledTerminalServiceCheckFailure.checkInterrupted
    }
    guard requestCompleted || !model.isTranslating else {
        model.cancel()
        throw InstalledTerminalServiceCheckFailure.translationTimedOut
    }
    checks += 1

    let bytesBeforeConfirmation: Data
    do {
        bytesBeforeConfirmation = try Data(contentsOf: draftURL)
    } catch {
        throw InstalledTerminalServiceCheckFailure.outputVerificationFailed
    }
    checks += try installedTerminalServiceCheck(
        bytesBeforeConfirmation == originalBytes,
        failure: .sourceChangedBeforeConfirmation
    )
    checks += try installedTerminalServiceCheck(
        commitCount == 0 && cancelCount == 0,
        failure: .automaticWriteBack
    )
    checks += try installedTerminalServiceCheck(
        model.errorMessage == nil,
        failure: .translationRequestFailed
    )

    let translatedDraft = model.draftText
    checks += try installedTerminalServiceCheck(
        !translatedDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && translatedDraft != expectedDraft
            && model.sourceText == expectedDraft,
        failure: .invalidTranslation
    )

    guard model.commit() else {
        throw InstalledTerminalServiceCheckFailure.commitFailed
    }
    checks += try installedTerminalServiceCheck(
        commitCount == 1 && cancelCount == 0,
        failure: .commitFailed
    )

    let committedBytes: Data
    do {
        committedBytes = try Data(contentsOf: draftURL)
    } catch {
        throw InstalledTerminalServiceCheckFailure.outputVerificationFailed
    }
    guard let committedText = String(data: committedBytes, encoding: .utf8) else {
        throw InstalledTerminalServiceCheckFailure.outputVerificationFailed
    }
    let expectedCommittedText: String
    do {
        expectedCommittedText = try document.replacingDraft(with: translatedDraft)
    } catch {
        throw InstalledTerminalServiceCheckFailure.outputVerificationFailed
    }
    checks += try installedTerminalServiceCheck(
        committedBytes == Data(expectedCommittedText.utf8)
            && committedText.hasPrefix(goosePrefix)
            && committedText.hasSuffix(gooseHistory)
            && committedText.contains(translatedDraft),
        failure: .outputVerificationFailed
    )
    checks += 1 // String(data:encoding:) above confirms valid UTF-8.
    return checks
}

private func makeInstalledTerminalServiceTemporaryDirectory() throws -> URL {
    var template = Array("/tmp/keyi-installed-terminal-check-XXXXXX".utf8CString)
    guard let path = template.withUnsafeMutableBufferPointer({ buffer -> String? in
        guard let baseAddress = buffer.baseAddress,
              mkdtemp(baseAddress) != nil else {
            return nil
        }
        return String(cString: baseAddress)
    }) else {
        throw InstalledTerminalServiceCheckFailure.fixturePreparation
    }
    return URL(fileURLWithPath: path, isDirectory: true)
}
