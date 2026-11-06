import Foundation
import KEYICore

func runTerminalEditorDocumentChecks() throws -> Int {
    var count = 0
    func expect(_ value: Bool, _ message: String) {
        count += 1
        precondition(value, message)
    }
    func rejects(_ text: String, agent: String) {
        do {
            _ = try TerminalEditorDocument(text: text, agentID: agent)
            expect(false, "Malformed context must not become translation input")
        } catch { expect(true, "Known malformed context rejected") }
    }
    let draft = "帮我检查这份代码🙂\n保留第二行\t以及空格  "
    for profile in TerminalAgentProfile.all where profile.id != "goose" {
        let document = try TerminalEditorDocument(text: draft, agentID: profile.id)
        expect(document.draft == draft, "Every standard file adapter preserves UTF-8/multiline input")
        expect(try document.replacingDraft(with: "Check this code🙂\nKeep the second line")
            == "Check this code🙂\nKeep the second line", "Adapter replaces only its draft file")
        expect(try document.replacingDraft(with: draft) == draft, "No-op round trip preserves exact draft")
    }
    let goosePrefix = "# Goose Prompt Editor\n\n# Your prompt:\n"
    let gooseSuffix = "# Recent conversation for context (newest first):\n\nSECRET HISTORY MUST NOT BE SENT\n"
    let goose = try TerminalEditorDocument(text: goosePrefix + draft + "\n" + gooseSuffix, agentID: "goose")
    expect(goose.draft == draft + "\n", "Goose exposes the prompt only")
    expect(!goose.draft.contains("SECRET HISTORY"), "Goose never exposes conversation context")
    expect(try goose.replacingDraft(with: "Translated draft")
        == goosePrefix + "Translated draft\n" + gooseSuffix, "Goose preserves its complete history suffix")
    let gooseNoContext = try TerminalEditorDocument(text: goosePrefix + draft, agentID: "goose")
    expect(gooseNoContext.draft == draft, "Goose without history remains supported")
    let gooseDetected = try TerminalEditorDocument(text: goosePrefix + draft + "\n" + gooseSuffix)
    expect(gooseDetected.draft == goose.draft, "Known history format is protected even without a profile argument")
    rejects("# Goose Prompt Editor\nnot a known prompt template", agent: "goose")
    rejects(draft, agent: "goose")
    rejects(goosePrefix + "# Your prompt:\n" + draft, agent: "goose")
    rejects(goosePrefix + draft + "\n" + gooseSuffix + gooseSuffix, agent: "goose")
    rejects(goosePrefix + draft + "\n# Recent conversation for context UNKNOWN\nsecret", agent: "goose")
    do {
        _ = try goose.replacingDraft(with: "# Recent conversation for context:\nleak")
        expect(false, "Generated prompt must not inject a native context marker")
    } catch { expect(true, "Generated context markers are rejected") }
    let claudePrefix = "# ─── Claude's last response (for reference; removed on save) ───\n# SECRET PREVIOUS ANSWER\n#\n# ─── Write your reply below this line ──────────────────────────\n"
    let claude = try TerminalEditorDocument(text: claudePrefix + draft, agentID: "claude")
    expect(claude.draft == draft, "Claude exposes only the reply below its explicit boundary")
    expect(!claude.draft.contains("SECRET"), "Claude's previous answer never becomes provider input")
    expect(try claude.replacingDraft(with: "Current reply") == claudePrefix + "Current reply", "Claude reference prefix stays byte-for-byte intact")
    rejects(claudePrefix + "# ─── Write your reply below this line ───\n" + draft, agent: "claude")
    rejects("# ─── Claude's last response (for reference; removed on save) ───\nsecret\n" + draft, agent: "claude")
    let empty = try TerminalEditorDocument(text: "", agentID: "codex")
    expect(empty.draft.isEmpty, "An empty editor hand-off is allowed")
    let shellOutput = try TerminalEditorDocument(text: "多行🙂\n\n", stripShellOutputNewline: true)
    expect(shellOutput.draft == "多行🙂\n", "Only fish's generated output newline is removed")
    expect(try shellOutput.replacingDraft(with: "line one\n\n") == "line one\n\n", "Intentional draft trailing newlines survive shell hand-off")
    expect(TerminalAgentProfile.all.filter { $0.id != "generic" }.count == 15, "Fifteen documented native editor contracts have profiles")
    for profile in TerminalAgentProfile.all {
        expect(TerminalAgentProfile.named(profile.id) == profile, "Profile IDs are stable")
    }
    expect(TerminalAgentProfile.named("goose")!.maySendOnEditorClose, "Goose must show explicit send confirmation")
    return count
}
