import AppKit
import Darwin
import Foundation
import KEYICore
import KEYIUI

@main
struct KEYITerminalCommand {
    @MainActor
    static func main() {
        do { try run(Array(CommandLine.arguments.dropFirst())) }
        catch {
            FileHandle.standardError.write(Data("KEYI：\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private enum Failure: Swift.Error, LocalizedError {
        case usage, invalidInput, clipboardUnavailable
        var errorDescription: String? {
            switch self {
            case .usage: "参数无效。运行 KEYITerminal --help 查看用法。"
            case .invalidInput: "草稿太大、不是 UTF-8 或包含终端控制字符。"
            case .clipboardUnavailable: "无法复制译文；草稿仍保留在编辑器中。"
            }
        }
    }

    @MainActor
    private static func run(_ arguments: [String]) throws {
        switch arguments.first {
        case nil, "--help", "-h":
            print("""
            KEYI 终端草稿桥（不读取终端历史、不自动发送按键）
              KEYITerminal edit [--agent ID] FILE
              KEYITerminal edit -              从 stdin 读取，用户确认后写到 stdout
              KEYITerminal zsh-draft register PID TTY
              KEYITerminal zsh-draft unregister SESSION-ID
              KEYITerminal zsh-draft probe HOST-PID SESSION-ID
              KEYITerminal zsh-draft capture HOST-PID
              KEYITerminal zsh-draft commit     从 stdin 读取条件写回请求
              KEYITerminal compose             通用草稿窗口，确认后复制译文，手动粘贴
              KEYITerminal list                原生编辑器入口及尚未验收边界
            不包装、不接管任何 agent 启动，不修改全局 shell 配置。
            """)
        case "compose":
            guard arguments.count == 1 else { throw Failure.usage }
            KEYITerminalEditor.run(
                source: "",
                title: "KEYI · 通用翻译草稿",
                completionLabel: "复制译文（手动粘贴）",
                onCommit: { draft in
                    NSPasteboard.general.clearContents()
                    guard NSPasteboard.general.setString(draft, forType: .string) else {
                        throw Failure.clipboardUnavailable
                    }
                },
                onCancel: { exit(1) }
            )
        case "list":
            for profile in TerminalAgentProfile.all {
                print("\(profile.id) | \(profile.name) | \(profile.shortcut) | \(profile.notes)")
            }
            print("以上为接口接入清单，不代表 Ghostty 真实宿主逐项验收通过。")
        case "edit":
            var rest = Array(arguments.dropFirst())
            let stripShellOutput = rest.first == "--shell-output"
            if stripShellOutput { rest.removeFirst() }
            let profile = try consumeProfile(&rest) ?? TerminalAgentProfile.named("generic")!
            guard rest.count == 1 else { throw Failure.usage }
            try edit(rest[0], profile: profile, stripShellOutput: stripShellOutput)
        case "zsh-draft":
            try runZshDraft(Array(arguments.dropFirst()))
        default: throw Failure.usage
        }
    }

    private static func runZshDraft(_ arguments: [String]) throws {
        guard let operation = arguments.first else { throw Failure.usage }
        switch operation {
        case "register":
            guard arguments.count == 3,
                  let shellPID = Int32(arguments[1]) else { throw Failure.usage }
            let registration = try ZshDraftHost.register(shellPID: shellPID, ttyPath: arguments[2])
            FileHandle.standardOutput.write(Data((registration + "\n").utf8))
        case "unregister":
            guard arguments.count == 2 else { throw Failure.usage }
            try ZshDraftHost.unregister(id: arguments[1])
        case "probe":
            guard arguments.count == 3,
                  let hostPID = Int32(arguments[1]) else { throw Failure.usage }
            try ZshDraftHost.probe(sessionID: arguments[2], hostPID: hostPID)
            FileHandle.standardOutput.write(Data("OK\n".utf8))
        case "capture":
            guard arguments.count == 2,
                  let hostPID = Int32(arguments[1]) else { throw Failure.usage }
            let capture = try ZshDraftHost.capture(hostPID: hostPID)
            FileHandle.standardOutput.write(try JSONEncoder().encode(capture))
        case "commit":
            guard arguments.count == 1 else { throw Failure.usage }
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard data.count <= 200_000,
                  let request = try? JSONDecoder().decode(ZshDraftCommit.self, from: data) else {
                throw Failure.usage
            }
            let acknowledgement = try ZshDraftHost.commit(request)
            FileHandle.standardOutput.write(try JSONEncoder().encode(acknowledgement))
        default:
            throw Failure.usage
        }
    }

    private static func consumeProfile(_ arguments: inout [String]) throws -> TerminalAgentProfile? {
        guard arguments.first == "--agent" else { return nil }
        guard arguments.count >= 2, let profile = TerminalAgentProfile.named(arguments[1]) else { throw Failure.usage }
        arguments.removeFirst(2)
        return profile
    }

    @MainActor
    private static func edit(_ path: String, profile: TerminalAgentProfile, stripShellOutput: Bool = false) throws {
        let snapshot = path == "-" ? nil : try TerminalDraftFile.capture(path: path)
        let original: String
        if let snapshot { original = snapshot.text }
        else {
            var bytes = Data()
            while bytes.count <= 65_536 {
                let part = FileHandle.standardInput.readData(ofLength: min(4096, 65_537 - bytes.count))
                if part.isEmpty { break }
                bytes.append(part)
            }
            guard bytes.count <= 65_536, let text = String(data: bytes, encoding: .utf8),
                  text.unicodeScalars.allSatisfy({
                      $0 == "\n" || $0 == "\r" || $0 == "\t" || !CharacterSet.controlCharacters.contains($0)
                  }) else { throw Failure.invalidInput }
            original = text
        }
        let document = try TerminalEditorDocument(text: original, agentID: path == "-" ? "generic" : profile.id, stripShellOutputNewline: stripShellOutput)
        KEYITerminalEditor.run(
            source: document.draft,
            title: "KEYI · \(profile.name) 草稿",
            completionLabel: profile.maySendOnEditorClose && path != "-"
                ? "确认写回（当前工具可能立即发送）" : "写回草稿",
            onCommit: { draft in
                let result = try document.replacingDraft(with: draft)
                if let snapshot { try TerminalDraftFile.commit(result, to: snapshot) }
                else { FileHandle.standardOutput.write(Data(result.utf8)) }
            },
            onCancel: { exit(1) }
        )
    }

}
