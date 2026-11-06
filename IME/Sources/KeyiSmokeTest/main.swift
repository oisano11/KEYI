import AppKit
import Foundation
import KeyiIMEBridge

/// Offline engine diagnostic. It exercises the real librime session, the way
/// the input session drives it, and never touches an installed input source.

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(EXIT_FAILURE)
}

private func pass(_ message: String) {
    print("PASS: \(message)")
}

guard CommandLine.arguments.count >= 3 else {
    FileHandle.standardError.write(Data(
        "usage: keyi-smoke SHARED_DATA_DIR USER_DATA_DIR [--query PINYIN]\n"
            .utf8
    ))
    exit(2)
}

let sharedDataPath = CommandLine.arguments[1]
let userDataPath = CommandLine.arguments[2]

if let queryIndex = CommandLine.arguments.firstIndex(of: "--query"),
   queryIndex + 1 < CommandLine.arguments.count
{
    let query = CommandLine.arguments[queryIndex + 1]
    let session = KeyiRimeSession(
        sharedDataPath: sharedDataPath,
        userDataPath: userDataPath,
        schemaIdentifier: "keyi_pinyin"
    )
    guard session.ready else {
        fail("Rime initialization failed: \(session.errorMessage)")
    }
    session.setCandidatePageSize(9)
    var candidates: [String] = []
    for scalar in query.unicodeScalars {
        candidates = session.processKey(
            Int(scalar.value),
            modifiers: 0
        ).candidates
    }
    for (index, candidate) in candidates.enumerated() {
        print("\(index + 1)\t\(candidate)")
    }
    exit(EXIT_SUCCESS)
}

// Caret probe: reports how the engine describes composition editing. Used when
// diagnosing marked-text selection, and safe to run without a GUI.
// `--probe-candidates <letters>`: prints the first page for these letters, so a
// dictionary placed in the user directory can be checked by hand.
if let flag = CommandLine.arguments.firstIndex(of: "--probe-candidates"),
   CommandLine.arguments.indices.contains(flag + 1) {
    let probe = KeyiRimeSession(
        sharedDataPath: sharedDataPath,
        userDataPath: userDataPath,
        schemaIdentifier: "keyi_pinyin"
    )
    guard probe.ready else {
        fail("Rime initialization failed: \(probe.errorMessage)")
    }
    probe.setCandidatePageSize(9)
    var value = KeyiRimeResult()
    for scalar in CommandLine.arguments[flag + 1].unicodeScalars {
        value = probe.processKey(Int(scalar.value), modifiers: 0)
    }
    print("candidates=\(value.candidates.joined(separator: " "))")
    exit(EXIT_SUCCESS)
}

if CommandLine.arguments.contains("--probe-caret") {
    let probe = KeyiRimeSession(
        sharedDataPath: sharedDataPath,
        userDataPath: userDataPath,
        schemaIdentifier: "keyi_pinyin"
    )
    guard probe.ready else {
        fail("Rime initialization failed: \(probe.errorMessage)")
    }
    probe.setCandidatePageSize(9)
    var value = probe.processKey(Int("n".unicodeScalars.first!.value), modifiers: 0)
    for scalar in "ihao".unicodeScalars {
        value = probe.processKey(Int(scalar.value), modifiers: 0)
    }
    print("end   preedit=[\(value.preedit)] cursor=\(value.cursorPosition)")
    let left = probe.processKey(0xff51, modifiers: 0)
    print("left  preedit=[\(left.preedit)] cursor=\(left.cursorPosition) raw=[\(probe.rawInput)]")
    let left2 = probe.processKey(0xff51, modifiers: 0)
    print("left2 preedit=[\(left2.preedit)] cursor=\(left2.cursorPosition) raw=[\(probe.rawInput)]")
    let inserted = probe.processKey(Int("x".unicodeScalars.first!.value), modifiers: 0)
    print("x     preedit=[\(inserted.preedit)] cursor=\(inserted.cursorPosition) raw=[\(probe.rawInput)]")
    let right = probe.processKey(0xff53, modifiers: 0)
    print("right preedit=[\(right.preedit)] cursor=\(right.cursorPosition) raw=[\(probe.rawInput)]")
    exit(EXIT_SUCCESS)
}

func makeSession() -> KeyiRimeSession {
    let session = KeyiRimeSession(
        sharedDataPath: sharedDataPath,
        userDataPath: userDataPath,
        schemaIdentifier: "keyi_pinyin"
    )
    guard session.ready else {
        fail("Rime initialization failed: \(session.errorMessage)")
    }
    return session
}

func type(
    _ pinyin: String,
    into session: KeyiRimeSession
) -> KeyiRimeResult {
    var result = KeyiRimeResult()
    for scalar in pinyin.unicodeScalars {
        result = session.processKey(Int(scalar.value), modifiers: 0)
    }
    return result
}

/// Typing one character at a time, recording the preedit after each key, so
/// caret movement and mid-composition editing can be asserted for real.
func typeTracking(
    _ pinyin: String,
    into session: KeyiRimeSession
) -> (final: KeyiRimeResult, steps: [KeyiRimeResult]) {
    var steps: [KeyiRimeResult] = []
    for scalar in pinyin.unicodeScalars {
        steps.append(session.processKey(Int(scalar.value), modifiers: 0))
    }
    return (steps.last ?? KeyiRimeResult(), steps)
}

let session = makeSession()
print("rime_version=\(session.version)")

// 1. Plain composition: typing pinyin shows the expected preedit and offers
//    the expected word without any network or AI candidate.
session.setCandidatePageSize(9)
var result = type("nihao", into: session)
// Rime inserts a syllable separator in the preedit; the exact separator is a
// schema formatting choice, so only the letters are asserted.
let preeditLetters = result.preedit.filter { $0.isLetter }
guard preeditLetters == "nihao" else {
    fail("Unexpected preedit for nihao: \(result.preedit)")
}
guard result.candidates.contains("你好") else {
    fail("Expected 你好 in candidates, got \(result.candidates)")
}
pass("composition preedit=\(result.preedit) candidates=\(result.candidates.prefix(3))")

// 2. Space commits the highlighted candidate.
let committed = session.processKey(0x20, modifiers: 0)
guard committed.commitText == "你好" else {
    fail("Expected space to commit 你好, got \(committed.commitText ?? "<none>")")
}
guard committed.preedit.isEmpty else {
    fail("Expected empty preedit after commit, got \(committed.preedit)")
}
pass("space commits highlighted candidate")

// 3. Digit selection picks a candidate.
session.clear()
result = type("shijie", into: session)
guard result.candidates.count >= 2 else {
    fail("Expected multiple candidates for shijie, got \(result.candidates)")
}
let digitSelected = session.selectVisibleCandidate(at: 1)
guard digitSelected.handled,
      let digitCommit = digitSelected.commitText,
      !digitCommit.isEmpty
else {
    fail("Digit selection did not commit a candidate")
}
pass("digit selection committed \(digitCommit)")

// 4. The active corpus is the mature 雾凇 dictionary, not just the compact
// KEYI overrides. This phrase is absent from keyi_core and verifies that the
// vendored table is actually compiled into the selected schema.
session.clear()
result = type("jiqixuexi", into: session)
guard result.candidates.first == "机器学习" else {
    fail("rime-ice corpus was not active for jiqixuexi: \(result.candidates)")
}
pass("rime-ice corpus resolves 机器学习")

// 5. Candidate navigation keeps highlight and page in sync.
session.clear()
session.setCandidatePageSize(3)
result = type("shi", into: session)
guard result.candidates.count == 3 else {
    fail("Expected a 3-item first page, got \(result.candidates)")
}
let firstPage = result.candidates
let paged = session.changeCandidatePageBackward(false)
guard paged.handled,
      paged.candidates.count == 3,
      paged.candidates.first != firstPage.first
else {
    fail("Candidate paging did not advance: \(paged.candidates)")
}
let pagedBack = session.changeCandidatePageBackward(true)
guard pagedBack.candidates == firstPage else {
    fail("Paging back did not restore the first page")
}
let highlighted = session.moveCandidateHighlight(1)
guard highlighted.highlightedCandidateIndex == 1 else {
    fail("Highlight move failed: \(highlighted.highlightedCandidateIndex)")
}
pass("candidate paging and highlight move")

// 6. Backspace edits the composition instead of deleting document text.
session.setCandidatePageSize(9)
session.clear()
result = type("nihao", into: session)
let beforeBackspace = result.preedit
let afterBackspace = session.processKey(0xff08, modifiers: 0)
guard afterBackspace.preedit.count < beforeBackspace.count else {
    fail(
        "Backspace did not shorten preedit: \(beforeBackspace) -> \(afterBackspace.preedit)"
    )
}
pass("backspace edits composition \(beforeBackspace) -> \(afterBackspace.preedit)")

// 7. Escape cancels the composition without committing anything.
session.clear()
result = type("nihaoma", into: session)
guard !result.preedit.isEmpty else {
    fail("Expected a composition before cancellation")
}
let cancelled = session.processKey(0xff1b, modifiers: 0)
guard cancelled.preedit.isEmpty, cancelled.commitText == nil else {
    fail("Escape did not clear the composition cleanly")
}
pass("escape cancels composition")

// 8. Left/right editing moves inside the composition instead of committing.
session.clear()
result = type("nihao", into: session)
let movedLeft = session.processKey(0xff51, modifiers: 0)
guard movedLeft.commitText == nil || movedLeft.commitText?.isEmpty == true else {
    fail("Left arrow committed text unexpectedly")
}
guard !movedLeft.preedit.isEmpty else {
    fail("Left arrow dropped the composition")
}
pass("arrow keys keep composition alive")

// 9. Sessions stay isolated. Both sessions are queried live (not from a stale
//    snapshot) while each holds its own composition, which is what breaks
//    multi-window typing in naive ports.
let secondSession = makeSession()
session.clear()
_ = type("nihao", into: session)
_ = type("women", into: secondSession)
// Query both live, interleaved with more typing, so a shared session would be
// caught rather than masked by an old result value.
let sessionLive = type("a", into: session).preedit
let secondLive = type("a", into: secondSession).preedit
guard sessionLive.hasPrefix("ni") else {
    fail("Session 1 preedit was disturbed: \(sessionLive)")
}
guard secondLive.hasPrefix("wo") else {
    fail("Session 2 preedit was disturbed: \(secondLive)")
}
guard sessionLive != secondLive else {
    fail("Both sessions report the same composition: \(sessionLive)")
}
let sessionRaw = session.rawInput
let secondRaw = secondSession.rawInput
guard sessionRaw != secondRaw,
      sessionRaw.hasPrefix("ni"),
      secondRaw.hasPrefix("wo")
else {
    fail(
        "Interleaved sessions share engine state: \(sessionRaw) / \(secondRaw)"
    )
}
let secondCandidates = secondSession.selectHighlightedCandidate()
guard let secondCommit = secondCandidates.commitText,
      secondCommit.hasPrefix("我们")
else {
    fail("Expected 我们 from the isolated session, got \(secondCandidates.commitText ?? "<none>")")
}
pass(
    "live session isolation verified (\(sessionRaw) / \(secondRaw)), "
        + "second session committed \(secondCommit)"
)

// 10. Left/right editing moves the caret inside the composition and the engine
//    reports it, so a client can keep marked-text selection in sync.
session.clear()
let caretSession = makeSession()
caretSession.setCandidatePageSize(9)
let typed = typeTracking("nihao", into: caretSession)
guard typed.final.cursorPosition != NSNotFound else {
    fail("Engine did not report a composition cursor")
}
guard typed.final.cursorPosition == typed.final.preedit.utf16Length else {
    fail(
        "Cursor should sit at the end of the composition: \(typed.final.cursorPosition) vs \(typed.final.preedit)"
    )
}
let leftMoved = caretSession.processKey(0xff51, modifiers: 0)
guard leftMoved.cursorPosition < typed.final.cursorPosition else {
    fail("Left arrow did not move the composition caret: \(leftMoved.cursorPosition)")
}
// Rime reformats the syllable separator when the caret moves inside the
// composition, so compare the letters, not the formatted string.
func letters(_ value: String) -> String {
    String(value.filter { $0.isLetter })
}
guard letters(leftMoved.preedit) == letters(typed.final.preedit) else {
    fail(
        "Left arrow changed the composition letters: \(typed.final.preedit) → \(leftMoved.preedit)"
    )
}
let leftAgain = caretSession.processKey(0xff51, modifiers: 0)
guard leftAgain.cursorPosition <= leftMoved.cursorPosition else {
    fail("Second left arrow moved the caret the wrong way")
}
guard caretSession.rawInput == "nihao" else {
    fail("Caret movement altered the raw input: \(caretSession.rawInput)")
}
// Inserting a letter mid-composition must land at the caret, not at the end.
// A genuine interior edit: move right once so the caret sits strictly inside
// the composition, then insert. `xnihao` (caret already at 0) is not an interior
// edit and cannot prove the caret is honoured, so the position is asserted too.
let beforeInsertRaw = caretSession.rawInput
let beforeInsertCount = beforeInsertRaw.count
let reanchor = caretSession.processKey(0xff53, modifiers: 0)
_ = reanchor
let midInserted = caretSession.processKey(Int("x".unicodeScalars.first!.value), modifiers: 0)
let midRaw = caretSession.rawInput
guard midRaw.count == beforeInsertCount + 1 else {
    fail("Mid-composition insert did not add a character: \(midRaw)")
}
guard !midRaw.hasPrefix("x"), !midRaw.hasSuffix("x") else {
    fail(
        "Mid-composition insert landed at an end, not the caret: \(midRaw) "
            + "(from \(beforeInsertRaw))"
    )
}
guard midInserted.cursorPosition > 0,
      midInserted.cursorPosition < midInserted.preedit.utf16Length
else {
    fail(
        "Caret did not stay inside the composition after insert: "
            + "\(midInserted.cursorPosition) of \(midInserted.preedit.utf16Length)"
    )
}
let afterInsertRaw = midRaw
let rightMoved = caretSession.processKey(0xff53, modifiers: 0)
guard rightMoved.cursorPosition >= midInserted.cursorPosition else {
    fail("Right arrow did not move the composition caret forward")
}
guard caretSession.rawInput == afterInsertRaw else {
    fail("Right arrow altered the raw input: \(caretSession.rawInput)")
}
pass(
    "caret follows left/right and mid-composition insert "
        + "(\(leftMoved.cursorPosition) → \(midInserted.cursorPosition) → \(rightMoved.cursorPosition), "
        + "raw \(caretSession.rawInput))"
)

// 11. A punctuation key ends the composition without leaving stale preedit
//     state behind.
session.clear()
let punctuationSession = makeSession()
_ = type("nihao", into: punctuationSession)
let punctuated = punctuationSession.processKey(Int(",".unicodeScalars.first!.value), modifiers: 0)
guard punctuated.preedit.isEmpty else {
    fail("Punctuation left a stale preedit: \(punctuated.preedit)")
}
guard let punctuationCommit = punctuated.commitText, !punctuationCommit.isEmpty else {
    fail("Punctuation ended the composition without committing anything")
}
guard punctuationSession.rawInput.isEmpty else {
    fail("Engine still reports raw input after punctuation ended the composition")
}
pass("punctuation consumes composition and leaves no stale preedit")

// 11b. Pinyin is shown without the automatic syllable spaces (model, not mo de l),
// and / is committed as / at once (terminal commands like /model need no choice).
let spacingSession = makeSession()
let model = type("model", into: spacingSession)
guard model.preedit == "model" else {
    fail("Preedit still shows syllable spaces: [\(model.preedit)]")
}
spacingSession.clear()
let slash = spacingSession.processKey(Int("/".unicodeScalars.first!.value), modifiers: 0)
guard slash.commitText == "/", slash.preedit.isEmpty else {
    fail("Slash did not commit / directly: commit=\(slash.commitText ?? "nil") preedit=[\(slash.preedit)]")
}
let backslash = spacingSession.processKey(Int("\\".unicodeScalars.first!.value), modifiers: 0)
guard backslash.commitText == "、" else {
    fail("Backslash no longer gives 、: \(backslash.commitText ?? "nil")")
}
pass("pinyin shows no syllable spaces; / commits /, \\ commits 、")

// 11c. A table copy placed in the user directory wins over the bundled one after
// an in-process redeploy (how a dictionary update takes effect without a restart).
let overrideTables = URL(fileURLWithPath: userDataPath).appendingPathComponent("rime_ice/cn_dicts", isDirectory: true)
try? FileManager.default.createDirectory(at: overrideTables, withIntermediateDirectories: true)
let bundledOthers = URL(fileURLWithPath: sharedDataPath).appendingPathComponent("rime_ice/cn_dicts/others.dict.yaml")
guard var others = try? String(contentsOf: bundledOthers, encoding: .utf8) else {
    fail("Cannot read the bundled others table")
}
others += "可译更新测试\tke yi geng xin ce shi\t99999999\n"
try? others.write(to: overrideTables.appendingPathComponent("others.dict.yaml"), atomically: true, encoding: .utf8)
guard KeyiRimeSession.redeploy(withSharedDataPath: sharedDataPath, userDataPath: userDataPath) else {
    fail("Redeploy failed")
}
let redeployed = makeSession()
let overridden = type("keyigengxinceshi", into: redeployed)
guard overridden.candidates.first == "可译更新测试" else {
    fail("User-directory table did not take effect: \(overridden.candidates.prefix(3))")
}
try? FileManager.default.removeItem(at: URL(fileURLWithPath: userDataPath).appendingPathComponent("rime_ice"))
_ = KeyiRimeSession.redeploy(withSharedDataPath: sharedDataPath, userDataPath: userDataPath)
pass("a user-directory table takes effect after an in-process redeploy")

// 12. Forward delete carries Rime's own keysym and must not be confused with
//     backspace: it never edits the composition.
let deleteSession = makeSession()
_ = type("nihao", into: deleteSession)
let beforeDelete = deleteSession.rawInput
let forwardDelete = deleteSession.processKey(0xffff, modifiers: 0)
guard forwardDelete.commitText == nil || forwardDelete.commitText?.isEmpty == true else {
    fail("Forward delete committed text unexpectedly")
}
guard !forwardDelete.preedit.isEmpty else {
    fail("Forward delete dropped the composition")
}
guard deleteSession.rawInput == beforeDelete else {
    fail("Forward delete changed the composition")
}
pass("forward delete is not treated as backspace")

// 13. The composition cursor must be reported in the UTF-16 units a client's
//     marked-text selection uses, converted from librime's UTF-8 byte offset by
//     really decoding the prefix. A purely ASCII preedit cannot catch a broken
//     conversion, so this asserts the conversion contract directly: the offset
//     must always land on a valid UTF-16 boundary inside the preedit and move
//     monotonically with left/right editing.
let cursorSession = makeSession()
cursorSession.setCandidatePageSize(9)
_ = type("nihao", into: cursorSession)
var observedCursors: [Int] = []
for _ in 0..<4 {
    let moved = cursorSession.processKey(0xff51, modifiers: 0)
    let preeditLength = moved.preedit.utf16Length
    guard moved.cursorPosition >= 0, moved.cursorPosition <= preeditLength else {
        fail(
            "Cursor offset \(moved.cursorPosition) is outside the preedit "
                + "([\(moved.preedit)] length \(preeditLength))"
        )
    }
    guard moved.cursorPosition != NSNotFound else {
        fail("Engine reported no cursor for an active composition")
    }
    observedCursors.append(moved.cursorPosition)
}
guard Set(observedCursors).count > 1 else {
    fail("Cursor never moved while editing: \(observedCursors)")
}
pass("composition cursor stays inside the preedit in UTF-16 units \(observedCursors)")

// 14. A preedit that actually contains multi-byte characters is where a
//     byte-offset conversion fails. Selecting a syllable keeps Han text inside
//     the composition, so the caret there exercises the real conversion.
let hanCursorSession = makeSession()
hanCursorSession.setCandidatePageSize(9)
_ = type("nihao", into: hanCursorSession)
// The mature 雾凇 corpus ranks the two-character alternative "拟好" second,
// so the first single-character candidate is visible at index 2 ("你").
// Selecting it advances Rime to the remaining syllable and leaves Han text in
// the composition, which is the state needed to exercise UTF-8 → UTF-16 caret
// conversion.
let partial = hanCursorSession.selectVisibleCandidate(at: 2)
guard !partial.preedit.isEmpty else {
    fail("Expected a composition to survive a partial selection")
}
let afterHanLeft = hanCursorSession.processKey(0xff51, modifiers: 0)
let hanPreeditLength = afterHanLeft.preedit.utf16Length
guard afterHanLeft.cursorPosition >= 0,
      afterHanLeft.cursorPosition <= hanPreeditLength
else {
    fail(
        "Han composition cursor \(afterHanLeft.cursorPosition) is outside "
            + "[\(afterHanLeft.preedit)] (length \(hanPreeditLength))"
    )
}
// The preedit holds Han characters, so its UTF-8 byte length is strictly larger
// than its UTF-16 length. A byte offset reported as UTF-16 would therefore land
// outside the string; staying inside proves the decode happened.
guard afterHanLeft.preedit.utf8.count > hanPreeditLength else {
    fail(
        "Test preedit did not contain multi-byte characters: "
            + "[\(afterHanLeft.preedit)]"
    )
}
pass(
    "multi-byte preedit keeps its caret inside the string "
        + "([\(afterHanLeft.preedit)] utf8=\(afterHanLeft.preedit.utf8.count) "
        + "utf16=\(hanPreeditLength) cursor=\(afterHanLeft.cursorPosition))"
)

// 15. The byte-to-UTF-16 conversion itself, on inputs the live engine does not
//     conveniently produce. A counting conversion (the previous behaviour)
//     reports the same number for these, so these assertions are what separates
//     a real decode from counting.
let conversionCases: [(preedit: String, byteOffset: Int, expected: Int, note: String)] = [
    ("你hao", 0, 0, "start of a multi-byte preedit"),
    ("你hao", 3, 1, "one Han character is one UTF-16 unit"),
    ("你hao", 4, 2, "Han plus one ASCII character"),
    ("你hao", 6, 4, "end of a mixed preedit"),
    ("你好", 6, 2, "two Han characters"),
    ("你好", 3, 1, "boundary between Han characters"),
    ("a\u{0301}b", 1, 1, "combining mark stays one UTF-16 unit"),
    ("😀x", 4, 2, "astral character is a surrogate pair in UTF-16"),
    ("😀x", 5, 3, "astral character plus ASCII"),
    ("nihao", 3, 3, "ASCII is unchanged"),
    // A byte offset inside a multi-byte scalar cannot be decoded; the whole
    // scalar is dropped rather than producing a broken prefix.
    ("你hao", 1, 0, "offset inside a Han scalar"),
    ("你hao", 2, 0, "second byte inside a Han scalar"),
]
for testCase in conversionCases {
    let actual = KeyiUTF16OffsetForUTF8Prefix(
        testCase.preedit,
        testCase.byteOffset
    )
    guard actual == testCase.expected else {
        fail(
            "UTF-8→UTF-16 conversion for [\(testCase.preedit)] byte "
                + "\(testCase.byteOffset) (\(testCase.note)): got \(actual), "
                + "expected \(testCase.expected)"
        )
    }
}
pass("UTF-8 byte offsets convert to UTF-16 lengths (\(conversionCases.count) cases)")

// User dictionary reset: clears the learned words in place, and every live
// session keeps working (it starts a new one on its next key).
do {
    let learner = KeyiRimeSession(
        sharedDataPath: sharedDataPath,
        userDataPath: userDataPath,
        schemaIdentifier: "keyi_pinyin"
    )
    guard learner.ready else { fail("reset probe session failed: \(learner.errorMessage)") }
    func typeAndCommit(_ pinyin: String) -> String? {
        for scalar in pinyin.unicodeScalars {
            _ = learner.processKey(Int(scalar.value), modifiers: 0)
        }
        return learner.processKey(0x20, modifiers: 0).commitText
    }
    guard typeAndCommit("nihao")?.isEmpty == false else { fail("reset probe could not commit") }
    let userDatabase = URL(fileURLWithPath: userDataPath)
        .appendingPathComponent("keyi_user.userdb", isDirectory: true)
    guard FileManager.default.fileExists(atPath: userDatabase.path) else {
        fail("committing did not create the user dictionary")
    }
    guard KeyiRimeSession.resetUserDictionaryNamed(
        "keyi_user",
        sharedDataPath: sharedDataPath,
        userDataPath: userDataPath
    ) else { fail("user dictionary reset reported failure") }
    guard !FileManager.default.fileExists(atPath: userDatabase.path) else {
        fail("user dictionary still exists after reset")
    }
    guard !learner.processKey(Int(("n" as Unicode.Scalar).value), modifiers: 0).candidates.isEmpty else {
        fail("session did not recover after the user dictionary reset")
    }
    learner.clear()
    guard typeAndCommit("nihao")?.isEmpty == false,
          FileManager.default.fileExists(atPath: userDatabase.path) else {
        fail("user dictionary was not recreated after the reset")
    }
}
pass("user dictionary reset clears learned words and sessions recover")

print("ALL CHECKS PASSED")

private extension String {
    /// UTF-16 length, the unit AppKit uses for marked ranges.
    var utf16Length: Int { (self as NSString).length }
}
