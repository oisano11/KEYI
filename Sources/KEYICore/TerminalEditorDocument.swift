import Foundation

/// An editor hand-off, not a terminal screen scrape. Context stays in the file
/// and is never exposed as the editable/translation draft.
public struct TerminalEditorDocument: Sendable {
    public enum Error: Swift.Error, LocalizedError {
        case unknownTemplate
        case ambiguousTemplate
        case reservedMarker

        public var errorDescription: String? {
            switch self {
            case .unknownTemplate: "无法识别终端草稿模板，未读取或改写历史内容。"
            case .ambiguousTemplate: "终端草稿模板存在歧义，已保留原文件。"
            case .reservedMarker: "草稿包含编辑器保留标记，不能安全写回。"
            }
        }
    }

    public let draft: String
    private let original: String
    private let range: NSRange
    private let kind: Kind

    private enum Kind: Sendable, Equatable { case plain, claude, goose }
    private static let gooseHeader = "# Goose Prompt Editor"
    private static let goosePrompt = "# Your prompt:"
    private static let gooseContexts = [
        "# Recent conversation for context:",
        "# Recent conversation for context (newest first):"
    ]

    public init(text suppliedText: String, agentID: String = "generic", stripShellOutputNewline: Bool = false) throws {
        if stripShellOutputNewline && !suppliedText.hasSuffix("\n") { throw Error.unknownTemplate }
        let text = stripShellOutputNewline ? String(suppliedText.dropLast()) : suppliedText
        let lines = Self.lines(in: text)
        let hasGooseHeader = lines.contains { $0.text == Self.gooseHeader }
        let hasClaudeContext = lines.contains {
            $0.text.hasPrefix("# ") && $0.text.contains("Claude")
                && $0.text.contains("last response")
                && $0.text.contains("for reference")
        }
        let selectedRange: NSRange
        let selectedKind: Kind
        if agentID == "goose" || hasGooseHeader {
            guard lines.first?.text == Self.gooseHeader else { throw Error.unknownTemplate }
            let prompts = lines.filter { $0.text == Self.goosePrompt }
            let contexts = lines.filter { Self.gooseContexts.contains($0.text) }
            let contextLike = lines.filter { $0.text.hasPrefix("# Recent conversation for context") }
            guard prompts.count == 1, contexts.count <= 1,
                  contextLike.count == contexts.count,
                  lines.filter({ $0.text == Self.gooseHeader }).count == 1,
                  let prompt = prompts.first else { throw Error.ambiguousTemplate }
            let start = NSMaxRange(prompt.range)
            let end = contexts.first?.range.location ?? (text as NSString).length
            guard end >= start else { throw Error.ambiguousTemplate }
            selectedRange = NSRange(location: start, length: end - start)
            selectedKind = .goose
        } else if hasClaudeContext {
            guard lines.first?.text.hasPrefix("# ") == true,
                  lines.first?.text.contains("Claude") == true,
                  lines.first?.text.contains("last response") == true else { throw Error.unknownTemplate }
            let boundaries = lines.filter {
                $0.text.hasPrefix("# ") && $0.text.contains("Write your reply below this line")
            }
            guard boundaries.count == 1, let boundary = boundaries.first else {
                throw Error.ambiguousTemplate
            }
            let prefix = (text as NSString).substring(to: boundary.range.location)
            guard Self.lines(in: prefix).allSatisfy({
                $0.text.isEmpty || $0.text.hasPrefix("#")
            }) else { throw Error.unknownTemplate }
            let start = NSMaxRange(boundary.range)
            selectedRange = NSRange(location: start, length: (text as NSString).length - start)
            selectedKind = .claude
        } else {
            // A malformed known context header must not silently become a draft.
            if lines.contains(where: {
                $0.text.hasPrefix("# Goose Prompt Editor")
                    || ($0.text.hasPrefix("# ") && $0.text.contains("Write your reply below this line"))
            }) { throw Error.unknownTemplate }
            selectedRange = NSRange(location: 0, length: (text as NSString).length)
            selectedKind = .plain
        }
        original = text
        range = selectedRange
        kind = selectedKind
        draft = (text as NSString).substring(with: selectedRange)
    }

    public func replacingDraft(with replacement: String) throws -> String {
        let replacementLines = Self.lines(in: replacement)
        switch kind {
        case .plain: break
        case .goose:
            guard !replacementLines.contains(where: {
                $0.text == Self.gooseHeader || $0.text == Self.goosePrompt
                    || $0.text.hasPrefix("# Recent conversation for context")
            }) else { throw Error.reservedMarker }
        case .claude:
            guard !replacementLines.contains(where: {
                $0.text.hasPrefix("# ") && $0.text.contains("Write your reply below this line")
            }) else { throw Error.reservedMarker }
        }
        // A context marker must remain at the start of a line after replacement.
        let separated = kind == .goose && NSMaxRange(range) < (original as NSString).length
            && !replacement.isEmpty && !replacement.hasSuffix("\n")
            ? replacement + "\n" : replacement
        return (original as NSString).replacingCharacters(in: range, with: separated)
    }

    private struct Line { let text: String; let range: NSRange }

    private static func lines(in value: String) -> [Line] {
        let text = value as NSString
        var result: [Line] = []
        var location = 0
        while location < text.length {
            let range = text.lineRange(for: NSRange(location: location, length: 0))
            let contents = text.substring(with: range).trimmingCharacters(in: .newlines)
            result.append(Line(text: contents, range: range))
            location = NSMaxRange(range)
        }
        return result
    }
}

public struct TerminalAgentProfile: Sendable, Equatable {
    public let id: String
    public let name: String
    public let shortcut: String
    public let maySendOnEditorClose: Bool
    public let notes: String

    public static let all: [TerminalAgentProfile] = [
        .init(id: "claude", name: "Claude Code", shortcut: "Ctrl+G", maySendOnEditorClose: true, notes: "识别并保留 externalEditorContext 历史块；关闭行为需本机验收"),
        .init(id: "codex", name: "Codex CLI", shortcut: "Ctrl+G", maySendOnEditorClose: false, notes: "回到草稿后由用户发送"),
        .init(id: "gemini", name: "Gemini CLI", shortcut: "Ctrl+G", maySendOnEditorClose: false, notes: "已设置 preferredEditor 时须先改本次工具的编辑器选择"),
        .init(id: "qwen", name: "Qwen Code", shortcut: "Ctrl+X", maySendOnEditorClose: false, notes: "已设置 preferredEditor 时须先改本次工具的编辑器选择"),
        .init(id: "opencode", name: "OpenCode", shortcut: "Ctrl+X 然后 E / /editor", maySendOnEditorClose: false, notes: "回到草稿后由用户发送"),
        .init(id: "aider", name: "Aider", shortcut: "Ctrl+X Ctrl+E / /editor", maySendOnEditorClose: false, notes: "只更新输入或 placeholder，不自动发送"),
        .init(id: "goose", name: "Goose", shortcut: "GOOSE_PROMPT_EDITOR / /edit", maySendOnEditorClose: true, notes: "仅编辑 Your prompt 段；完成会发送，须用户明确确认"),
        .init(id: "amp", name: "Amp", shortcut: "Ctrl+G", maySendOnEditorClose: true, notes: "关闭后发送语义待本机确认，按可能发送处理"),
        .init(id: "cursor", name: "Cursor Agent CLI", shortcut: "Ctrl+G", maySendOnEditorClose: false, notes: "仅主 prompt bar；不宣称 AskQuestion 等子对话框兼容"),
        .init(id: "copilot", name: "Copilot CLI", shortcut: "Ctrl+G / Ctrl+X 然后 E", maySendOnEditorClose: true, notes: "关闭后发送语义待本机确认，按可能发送处理"),
        .init(id: "kilo", name: "Kilo CLI", shortcut: "/editor", maySendOnEditorClose: false, notes: "使用无空格的裸可执行路径"),
        .init(id: "pi", name: "Pi Coding Agent", shortcut: "Ctrl+G", maySendOnEditorClose: false, notes: "externalEditor 设置可能盖过环境变量；仅回当前草稿"),
        .init(id: "crush", name: "Crush", shortcut: "Ctrl+O", maySendOnEditorClose: false, notes: "仅回 textarea 草稿；使用无空格的 EDITOR 路径"),
        .init(id: "kimi", name: "Kimi Code CLI", shortcut: "Ctrl+G（部分 Python 版本为 Ctrl+O）", maySendOnEditorClose: false, notes: "/editor 设置可能盖过 VISUAL/EDITOR；仅回当前输入"),
        .init(id: "vibe-python", name: "Mistral Vibe Python/Textual", shortcut: "Ctrl+G", maySendOnEditorClose: false, notes: "仅 Python/Textual，显式 --agent vibe-python；不接管未确认的 Rust 版本"),
        .init(id: "generic", name: "其他外部编辑器客户端", shortcut: "工具自己的外部编辑器入口；无接口时用 compose", maySendOnEditorClose: true, notes: "当前原生协议或编辑器选择未确认；通用草稿仅由用户主动输入、复制和粘贴")
    ]

    public static func named(_ id: String) -> TerminalAgentProfile? {
        all.first { $0.id == id }
    }
}
