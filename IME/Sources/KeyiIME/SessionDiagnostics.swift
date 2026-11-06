import KeyiIMEBridge
import KeyiIMEDiagnostics
import KeyiIMEKit

// Drives a real KeyiInputSession through the InputMethodKit callbacks with a
// mock text client. Never registers or selects an input source.
// Run with `KEYIIME --diagnose-session`.
func runSessionDiagnostics() -> Never {
    KeyiPanelLayout.invisibleForDiagnostics = true
    // The diagnostics must never touch the user's live Rime data. This is
    // enforced here rather than only in the calling script, so running the
    // binary directly is isolated too. An explicit override is still honoured,
    // which lets the test suite point several runs at one shared scratch dir.
    let scratchRoot: URL
    if let override = ProcessInfo.processInfo.environment[
        "KEYI_IME_USER_DATA_DIR"
    ], !override.isEmpty {
        scratchRoot = URL(fileURLWithPath: override, isDirectory: true)
    } else {
        scratchRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "keyi-ime-diagnostics-\(UUID().uuidString)",
                isDirectory: true
            )
        setenv("KEYI_IME_USER_DATA_DIR", scratchRoot.path, 1)
    }
    try? FileManager.default.createDirectory(
        at: scratchRoot,
        withIntermediateDirectories: true
    )
    // Refuse to proceed if the isolation did not take effect, because the
    // alternative is writing test data into the user's real dictionary.
    guard KeyiSessionDiagnostics.userDataOverride != nil else {
        reportFailure("Diagnostics refused to run without an isolated Rime directory")
    }
    guard let session = KeyiSessionDiagnostics.sessionClass() else {
        reportFailure("KeyiInputSession is unavailable")
    }
    let client = KeyiDiagnosticTextClient()
    KeyiSessionDiagnostics.activate(session, client: client)

    var failures: [String] = []
    func expect(_ condition: Bool, _ label: String) {
        if condition {
            print("PASS: \(label)")
        } else {
            failures.append(label)
            print("FAIL: \(label)")
        }
    }

    // 你好 is typed and committed from the candidate list.
    _ = KeyiSessionDiagnostics.typeText("nihao", into: session, client: client)
    expect(client.markedText.contains("ni"), "composition is marked in client")
    _ = KeyiSessionDiagnostics.sendKey(
        36, characters: "\r", into: session, client: client
    )
    expect(client.documentText == "nihao", "return commits raw pinyin")
    expect(client.markedText.isEmpty, "marked text cleared after commit")

    // Space selects the highlighted candidate and inserts Han text.
    let spaceClient = KeyiDiagnosticTextClient()
    KeyiSessionDiagnostics.activate(session, client: spaceClient)
    _ = KeyiSessionDiagnostics.typeText("nihao", into: session, client: spaceClient)
    _ = KeyiSessionDiagnostics.sendKey(
        49, characters: " ", into: session, client: spaceClient
    )
    expect(spaceClient.documentText == "你好", "space commits 你好")

    // Escape cancels without leaving text behind.
    let escapeClient = KeyiDiagnosticTextClient()
    KeyiSessionDiagnostics.activate(session, client: escapeClient)
    _ = KeyiSessionDiagnostics.typeText("nihao", into: session, client: escapeClient)
    _ = KeyiSessionDiagnostics.sendKey(
        53, characters: "\u{1b}", into: session, client: escapeClient
    )
    expect(escapeClient.documentText.isEmpty, "escape cancels cleanly")
    expect(escapeClient.markedText.isEmpty, "escape clears marked text")

    // Digit selection picks the second visible candidate.
    let digitClient = KeyiDiagnosticTextClient()
    KeyiSessionDiagnostics.activate(session, client: digitClient)
    _ = KeyiSessionDiagnostics.typeText("shijie", into: session, client: digitClient)
    _ = KeyiSessionDiagnostics.sendKey(
        19, characters: "2", into: session, client: digitClient
    )
    expect(
        !digitClient.documentText.isEmpty
            && digitClient.documentText != "shijie",
        "digit selects a candidate"
    )

    // Command chords are passed through so the client keeps its shortcuts.
    let commandClient = KeyiDiagnosticTextClient()
    _ = KeyiSessionDiagnostics.typeText("ni", into: session, client: commandClient)
    let commandHandled = KeyiSessionDiagnostics.sendKey(
        8, characters: "c", into: session, client: commandClient,
        modifiers: .command
    )
    expect(!commandHandled, "command chord passes through")

    // Deactivation must not strand a composition in the document.
    let deactivateClient = KeyiDiagnosticTextClient()
    KeyiSessionDiagnostics.activate(session, client: deactivateClient)
    _ = KeyiSessionDiagnostics.typeText("ni", into: session, client: deactivateClient)
    KeyiSessionDiagnostics.deactivate(session, client: deactivateClient)
    expect(
        deactivateClient.markedText.isEmpty,
        "deactivation clears marked text"
    )

    // Backspacing away the last pinyin character must also clear the client's
    // marked text, not just internal state.
    let backspaceClient = KeyiDiagnosticTextClient()
    KeyiSessionDiagnostics.activate(session, client: backspaceClient)
    _ = KeyiSessionDiagnostics.typeText("ni", into: session, client: backspaceClient)
    expect(
        !backspaceClient.markedText.isEmpty,
        "composition marks text before backspace"
    )
    for _ in 0..<4 {
        _ = KeyiSessionDiagnostics.sendKey(
            51, characters: "\u{7f}", into: session, client: backspaceClient
        )
    }
    expect(
        backspaceClient.markedText.isEmpty,
        "backspacing the last character clears client marked text"
    )
    expect(
        backspaceClient.documentText.isEmpty,
        "backspacing to empty leaves no text in the document"
    )

    // Composition ownership: pinyin typed into one client must never be
    // committed into the client that gains focus afterwards.
    let ownerA = KeyiDiagnosticTextClient()
    let ownerB = KeyiDiagnosticTextClient()
    KeyiSessionDiagnostics.activate(session, client: ownerA)
    _ = KeyiSessionDiagnostics.typeText("nihao", into: session, client: ownerA)
    let ownsA = KeyiSessionDiagnostics.ownsComposition(
        session, client: ownerA
    )
    let ownsB = KeyiSessionDiagnostics.ownsComposition(
        session, client: ownerB
    )
    expect(ownsA, "session reports ownership of the composing client")
    expect(!ownsB, "session reports no ownership of an inactive client")
    KeyiSessionDiagnostics.activate(session, client: ownerB)
    expect(
        ownerB.documentText.isEmpty,
        "focus change does not leak the previous client's composition"
    )
    expect(
        !ownerA.documentText.isEmpty,
        "the composing client receives the resolved composition"
    )
    expect(
        KeyiSessionDiagnostics.ownsComposition(session, client: ownerA) == false,
        "composition ownership is released after focus change"
    )

    // Committing must insert exactly once: a double insert is the classic
    // duplicate-text bug when a remote client re-enters the input method.
    let onceClient = KeyiDiagnosticTextClient()
    KeyiSessionDiagnostics.activate(session, client: onceClient)
    _ = KeyiSessionDiagnostics.typeText("nihao", into: session, client: onceClient)
    _ = KeyiSessionDiagnostics.sendKey(
        49, characters: " ", into: session, client: onceClient
    )
    expect(
        onceClient.insertTextCallCount == 1,
        "space commits exactly once (calls=\(onceClient.insertTextCallCount))"
    )
    expect(
        onceClient.documentText == "你好",
        "single commit produced exactly 你好"
    )

    // Commit and a following composition must coexist: a commit must not erase
    // a fresh composition the engine produced in the same step.
    let chainedClient = KeyiDiagnosticTextClient()
    KeyiSessionDiagnostics.activate(session, client: chainedClient)
    _ = KeyiSessionDiagnostics.typeText("nihao", into: session, client: chainedClient)
    _ = KeyiSessionDiagnostics.sendKey(
        49, characters: " ", into: session, client: chainedClient
    )
    _ = KeyiSessionDiagnostics.typeText("shi", into: session, client: chainedClient)
    expect(
        chainedClient.markedText.contains("shi"),
        "a new composition can follow a commit in the same session"
    )
    _ = KeyiSessionDiagnostics.sendKey(
        53, characters: "\u{1b}", into: session, client: chainedClient
    )
    expect(
        chainedClient.documentText == "你好",
        "cancelling the follow-up composition preserves the committed text"
    )

    KeyiSessionDiagnostics.hidePalettes(session)
    expect(true, "hidePalettes does not crash")

    // ===== Automatic translation wiring =====
    // 生产控制器本身由 `KeyiAutomaticTranslationChecks` 用替身驱动；这里只证明
    // 真实引擎路径确实把「确认的中文」交给自动翻译，而原始拼音上屏不会。
    let wiringClient = KeyiDiagnosticTextClient()
    KeyiSessionDiagnostics.activate(session, client: wiringClient)
    KeyiSessionDiagnostics.resetConfirmedCommit(session)
    _ = KeyiSessionDiagnostics.typeText("nihao", into: session, client: wiringClient)
    _ = KeyiSessionDiagnostics.sendKey(
        49, characters: " ", into: session, client: wiringClient
    )
    expect(
        KeyiSessionDiagnostics.lastConfirmedCommit(session) == "你好",
        "confirmed Han commit reaches the automatic translation path"
    )

    let rawClient = KeyiDiagnosticTextClient()
    KeyiSessionDiagnostics.activate(session, client: rawClient)
    KeyiSessionDiagnostics.resetConfirmedCommit(session)
    _ = KeyiSessionDiagnostics.typeText("nihao", into: session, client: rawClient)
    _ = KeyiSessionDiagnostics.sendKey(
        36, characters: "\r", into: session, client: rawClient
    )
    expect(
        KeyiSessionDiagnostics.lastConfirmedCommit(session) == nil,
        "raw pinyin commit does not enter automatic translation"
    )

    // ===== Round 2 =====

    // (1) Ownership: switching clients without an activate callback must still
    // resolve the old composition into its real owner, and the new client must
    // never receive the previous window's pinyin.
    let silentA = KeyiDiagnosticTextClient()
    let silentB = KeyiDiagnosticTextClient()
    KeyiSessionDiagnostics.activate(session, client: silentA)
    _ = KeyiSessionDiagnostics.typeText("nihao", into: session, client: silentA)
    expect(
        !silentA.markedText.isEmpty,
        "round2: composition is marked in the first client"
    )
    // No activate call: the second client types while the session still points
    // at silentA, which is exactly the window-switch race.
    _ = KeyiSessionDiagnostics.typeText("shi", into: session, client: silentB)
    expect(
        silentA.markedText.isEmpty,
        "round2: new client clears the previous client's marked text"
    )
    expect(
        !silentA.documentText.isEmpty,
        "round2: previous owner receives its resolved composition"
    )
    expect(
        !silentB.documentText.contains("ni")
            && !silentB.markedText.contains("ni"),
        "round2: new client does not inherit the old pinyin"
    )
    expect(
        silentB.markedText.contains("shi"),
        "round2: new client composes its own pinyin"
    )

    // (2) A commit and a remaining preedit in one snapshot: the commit is
    // consumed first and the preedit survives. This schema never emits both at
    // once, so the snapshot is injected and the session's own ordering is what
    // is under test.
    let chainedOnce = KeyiDiagnosticTextClient(documentText: "")
    KeyiSessionDiagnostics.activate(session, client: chainedOnce)
    _ = KeyiSessionDiagnostics.typeText("ni", into: session, client: chainedOnce)
    KeyiSessionDiagnostics.inject(
        KeyiRimeResult.diagnosticResult(
            withHandled: true,
            preedit: "ni hao",
            candidates: ["你好"],
            commitText: "你好",
            highlightedCandidateIndex: 0,
            cursorPosition: 6
        ),
        into: session
    )
    _ = KeyiSessionDiagnostics.typeText("x", into: session, client: chainedOnce)
    expect(
        chainedOnce.documentText.contains("你好"),
        "round2: injected snapshot commits its text"
    )
    expect(
        chainedOnce.markedText.contains("ni")
            || chainedOnce.markedText.contains("hao"),
        "round2: preedit from the same snapshot survives the commit"
    )
    expect(
        chainedOnce.insertTextCallCount == 1,
        "round2: injected snapshot commits exactly once (calls=\(chainedOnce.insertTextCallCount))"
    )

    // (3) IMK replacement-range semantics: committing must replace the client's
    // marked range rather than clear it and then insert somewhere else.
    let anchored = KeyiDiagnosticTextClient(documentText: "abc")
    KeyiSessionDiagnostics.activate(session, client: anchored)
    _ = KeyiSessionDiagnostics.typeText("nihao", into: session, client: anchored)
    let markedBeforeCommit = anchored.markedRange()
    _ = KeyiSessionDiagnostics.sendKey(
        36, characters: "\r", into: session, client: anchored
    )
    expect(
        anchored.lastInsertReplacementRange == markedBeforeCommit,
        "round2: commit replaces the marked range (got \(anchored.lastInsertReplacementRange), expected \(markedBeforeCommit))"
    )
    expect(
        anchored.documentText == "abcnihao",
        "round2: commit lands in place without moving the insertion point"
    )

    // (4) A re-entrant callback during insertText must not deliver twice.
    let reentrant = KeyiDiagnosticTextClient()
    KeyiSessionDiagnostics.activate(session, client: reentrant)
    _ = KeyiSessionDiagnostics.typeText("nihao", into: session, client: reentrant)
    reentrant.reentrancyProbe = {
        KeyiSessionDiagnostics.deactivate(session, client: reentrant)
    }
    _ = KeyiSessionDiagnostics.sendKey(
        49, characters: " ", into: session, client: reentrant
    )
    expect(
        reentrant.insertTextCallCount == 1,
        "round2: re-entrant commit still inserts exactly once (calls=\(reentrant.insertTextCallCount))"
    )
    expect(
        reentrant.documentText == "你好",
        "round2: re-entrant commit produced exactly 你好"
    )
    reentrant.reentrancyProbe = nil

    // (5) Word-wise deletion is released to the application instead of being
    // downgraded to a plain backspace.
    let wordDelete = KeyiDiagnosticTextClient()
    KeyiSessionDiagnostics.activate(session, client: wordDelete)
    _ = KeyiSessionDiagnostics.typeText("nihao", into: session, client: wordDelete)
    let wordDeleteHandled = KeyiSessionDiagnostics.sendCommand(
        "deleteWordBackward:", into: session, client: wordDelete
    )
    expect(
        !wordDeleteHandled,
        "round2: deleteWordBackward: is released to the application"
    )
    expect(
        wordDelete.markedText.isEmpty,
        "round2: deleteWordBackward: settles the composition first"
    )

    // (6) Application commands are released, not consumed.
    for commandName in ["copy:", "paste:", "selectAll:", "undo:"] {
        let commandClient = KeyiDiagnosticTextClient()
        KeyiSessionDiagnostics.activate(session, client: commandClient)
        _ = KeyiSessionDiagnostics.typeText("ni", into: session, client: commandClient)
        expect(
            !KeyiSessionDiagnostics.sendCommand(
                commandName, into: session, client: commandClient
            ),
            "round2: \(commandName) is released to the application"
        )
    }

    // (7) Forward delete carries Rime's own keysym, so the engine and the client
    // stay in sync instead of silently disagreeing.
    let forwardDeleteClient = KeyiDiagnosticTextClient()
    KeyiSessionDiagnostics.activate(session, client: forwardDeleteClient)
    _ = KeyiSessionDiagnostics.typeText("nihao", into: session, client: forwardDeleteClient)
    let forwardHandled = KeyiSessionDiagnostics.sendKey(
        117, characters: "\u{f728}", into: session, client: forwardDeleteClient
    )
    expect(
        forwardHandled,
        "round2: forward delete is consumed by the engine"
    )
    expect(
        forwardDeleteClient.markedText.contains("ni"),
        "round2: forward delete leaves a consistent composition"
    )

    // (8) Candidate anchoring uses the client's real caret, and never falls back
    // to the start of the document when there is no marked range.
    let anchorClient = KeyiDiagnosticTextClient(documentText: "hello")
    KeyiSessionDiagnostics.activate(session, client: anchorClient)
    _ = KeyiSessionDiagnostics.typeText("nihao", into: session, client: anchorClient)
    guard let anchorIndex = anchorClient.lastAnchorIndex else {
        reportFailure("round2: candidate anchor was never queried")
    }
    expect(
        anchorIndex >= 5,
        "round2: candidate anchor sits at the caret, not document index 0 (got \(anchorIndex))"
    )

    // A client that reports no marked range must still be anchored at its own
    // selection, never at the start of the document.
    let selectionAnchorClient = KeyiDiagnosticTextClient(documentText: "hello")
    selectionAnchorClient.suppressesMarkedRange = true
    KeyiSessionDiagnostics.activate(session, client: selectionAnchorClient)
    _ = KeyiSessionDiagnostics.typeText(
        "nihao", into: session, client: selectionAnchorClient
    )
    guard let fallbackAnchor = selectionAnchorClient.lastAnchorIndex else {
        reportFailure("round2: candidate anchor was never queried without a marked range")
    }
    expect(
        fallbackAnchor >= 5,
        "round2: anchor without marked range uses the selection, not index 0 (got \(fallbackAnchor))"
    )

    // (10) The sequence the mid-review called out: type without an activate,
    // switch clients, and only then send an activate. The session must settle
    // against the real composition owner rather than the stale activeClient, so
    // the previous owner's marked text cannot be left hanging.
    let lateOwner = KeyiDiagnosticTextClient()
    let lateNewcomer = KeyiDiagnosticTextClient()
    KeyiSessionDiagnostics.activate(session, client: lateOwner)
    _ = KeyiSessionDiagnostics.typeText("nihao", into: session, client: lateOwner)
    // Keys arrive for a different client with no activation in between.
    _ = KeyiSessionDiagnostics.typeText("wu", into: session, client: lateNewcomer)
    expect(
        lateOwner.markedText.isEmpty,
        "round2: unactivated client switch clears the old owner's marked text"
    )
    expect(
        !lateOwner.documentText.isEmpty,
        "round2: unactivated client switch settles into the real owner"
    )
    // Now the activation finally arrives for the newcomer.
    KeyiSessionDiagnostics.activate(session, client: lateNewcomer)
    expect(
        lateNewcomer.markedText.contains("wu")
            || lateNewcomer.documentText.contains("wu"),
        "round2: late activation keeps the new owner's own composition"
    )
    expect(
        lateOwner.markedText.isEmpty,
        "round2: late activation leaves no marked text on the old owner"
    )

    // (11) 对照浮层随会话收起（10-05 用户实测：切到英文输入后浮层仍停在“翻译中…”）。
    // 切换输入法时 IMK 先 deactivateServer，随即可能释放这个会话；也可能不经停用直接释放。
    // 两种情况浮层都必须收起，不能指望会话活到主队列执行收起的那一刻。
    func drainMainQueue() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
    for deactivateFirst in [true, false] {
        let label = deactivateFirst ? "deactivated then released" : "released without deactivation"
        weak var released: AnyObject?
        autoreleasepool {
            guard let doomed = KeyiSessionDiagnostics.sessionClass() else {
                expect(false, "preview: another input session can be created")
                return
            }
            let doomedClient = KeyiDiagnosticTextClient()
            KeyiSessionDiagnostics.activate(doomed, client: doomedClient)
            KeyiSessionDiagnostics.showPreview("哦怕", in: doomed)
            drainMainQueue()
            expect(
                KeyiSessionDiagnostics.previewPanelVisible(session),
                "preview: the panel shows while a run waits for its translation (\(label))"
            )
            if deactivateFirst {
                KeyiSessionDiagnostics.deactivate(doomed, client: doomedClient)
            }
            released = doomed
        }
        drainMainQueue()
        expect(released == nil, "preview: the session \(label) is gone")
        expect(
            !KeyiSessionDiagnostics.previewPanelVisible(session),
            "preview: a session \(label) leaves no panel behind"
        )
    }

    // ⌘↩ while pinyin is typed and nothing is held keeps its pre-change behaviour
    // (HEAD 0cfaf90): the letters are committed, the key is passed to the app.
    do {
        let chordClient = KeyiDiagnosticTextClient()
        KeyiSessionDiagnostics.activate(session, client: chordClient)
        _ = KeyiSessionDiagnostics.typeText("nihao", into: session, client: chordClient)
        let passed = KeyiSessionDiagnostics.sendKey(
            36, characters: "\r", into: session, client: chordClient, modifiers: .command
        )
        expect(!passed, "chord enter, nothing held: ⌘↩ still goes to the app")
        expect(chordClient.documentText == "nihao" && chordClient.markedText.isEmpty, "chord enter, nothing held: ⌘↩ commits the pinyin letters first")
    }

    // (12) A composition belongs to the client it started in. A key from another
    // client with no activation callback in between must settle the owner's pinyin
    // there and must never draw it into the newcomer.
    for (name, code, chars) in [("space", UInt16(49), " "), ("enter", UInt16(36), "\r")] {
        let ownerA = KeyiDiagnosticTextClient()
        KeyiSessionDiagnostics.activate(session, client: ownerA)
        _ = KeyiSessionDiagnostics.typeText("nihao", into: session, client: ownerA)
        let strangerB = KeyiDiagnosticTextClient()
        let passedOn = KeyiSessionDiagnostics.sendKey(code, characters: chars, into: session, client: strangerB)
        expect(!passedOn, "cross-client \(name): the key goes to the app of the new client")
        expect(strangerB.markedText.isEmpty, "cross-client \(name) (auto off): no marked text in the new client")
        expect(strangerB.documentText.isEmpty, "cross-client \(name) (auto off): no pinyin in the new client")
        expect(
            ownerA.documentText == "nihao" && ownerA.markedText.isEmpty,
            "cross-client \(name) (auto off): the owner's pinyin is settled as letters in the owner"
        )
        expect(
            !KeyiSessionDiagnostics.ownsComposition(session, client: strangerB),
            "cross-client \(name) (auto off): the new client owns no composition"
        )
    }

    // (13b) = turns to the next page and - back, like Apple Pinyin and Sogou; neither
    // lands in the text.
    do {
        let client = KeyiDiagnosticTextClient()
        KeyiSessionDiagnostics.activate(session, client: client)
        _ = KeyiSessionDiagnostics.typeText("shi", into: session, client: client)
        let first = KeyiSessionDiagnostics.visibleCandidates(session)
        _ = KeyiSessionDiagnostics.sendKey(24, characters: "=", into: session, client: client)
        let second = KeyiSessionDiagnostics.visibleCandidates(session)
        expect(!second.isEmpty && second != first, "paging: = shows the next page")
        _ = KeyiSessionDiagnostics.sendKey(27, characters: "-", into: session, client: client)
        expect(KeyiSessionDiagnostics.visibleCandidates(session) == first, "paging: - goes back to the first page")
        expect(!client.documentText.contains("=") && !client.documentText.contains("-")
               && !client.markedText.contains("="),
               "paging: = and - do not land in the text")
        _ = KeyiSessionDiagnostics.sendKey(53, characters: "\u{1b}", into: session, client: client)
    }

    // (14) Mixed English: a word that is not pinyin (model, github) offers the English
    // word first; letters that spell pinyin wholly (men, change) keep Chinese first and
    // the English word at the end of the page. Space on model commits the word as is.
    do {
        func page(_ letters: String) -> [String] {
            let client = KeyiDiagnosticTextClient()
            KeyiSessionDiagnostics.activate(session, client: client)
            _ = KeyiSessionDiagnostics.typeText(letters, into: session, client: client)
            let shown = KeyiSessionDiagnostics.visibleCandidates(session)
            _ = KeyiSessionDiagnostics.sendKey(53, characters: "\u{1b}", into: session, client: client)
            return shown
        }
        expect(page("model").first == "model", "mixed english: model offers model first")
        expect(page("github").first == "GitHub", "mixed english: github offers GitHub first")
        expect(page("deploy").first == "deploy", "mixed english: deploy (SCOWL 40) offers deploy first")
        let men = page("men")
        expect(men.first == "们" && men.last == "men", "mixed english: men keeps 们 first and men last (\(men))")
        let change = page("change")
        expect(change.first.map { !$0.unicodeScalars.allSatisfy(\.isASCII) } == true && change.last == "change",
               "mixed english: change keeps Chinese first and change last (\(change))")
        let spaceClient = KeyiDiagnosticTextClient()
        KeyiSessionDiagnostics.activate(session, client: spaceClient)
        _ = KeyiSessionDiagnostics.typeText("model", into: session, client: spaceClient)
        _ = KeyiSessionDiagnostics.sendKey(49, characters: " ", into: session, client: spaceClient)
        expect(spaceClient.documentText == "model", "mixed english: space commits model (\(spaceClient.documentText))")
    }

    // (13) Per-app learning: a pick in one app moves that word to the front of the
    // same pinyin's page in that app only. A and B pick different words from one page,
    // so the check holds whatever Rime's own (global) learning does to the order.
    do {
        func learningClient(_ app: String) -> KeyiDiagnosticTextClient {
            let client = KeyiDiagnosticTextClient()
            client.bundleIdentifierOverride = app
            KeyiSessionDiagnostics.activate(session, client: client)
            return client
        }
        let pickA = learningClient("com.keyi.diagnostic.learning.a")
        _ = KeyiSessionDiagnostics.typeText("shi", into: session, client: pickA)
        let page = KeyiSessionDiagnostics.visibleCandidates(session)
        expect(page.count >= 4, "app learning: shi offers a page of candidates")
        if page.count >= 4 {
            let wordA = page[2], wordB = page[3]
            _ = KeyiSessionDiagnostics.sendKey(20, characters: "3", into: session, client: pickA)
            expect(pickA.documentText == wordA, "app learning: app A picks the third candidate")
            let pickB = learningClient("com.keyi.diagnostic.learning.b")
            _ = KeyiSessionDiagnostics.typeText("shi", into: session, client: pickB)
            let pageB = KeyiSessionDiagnostics.visibleCandidates(session)
            if let index = pageB.firstIndex(of: wordB), index < 9 {
                _ = KeyiSessionDiagnostics.sendKey(UInt16([18, 19, 20, 21, 23, 22, 26, 28, 25][index]), characters: "\(index + 1)", into: session, client: pickB)
            }
            expect(pickB.documentText == wordB, "app learning: app B picks another candidate")

            let againA = learningClient("com.keyi.diagnostic.learning.a")
            _ = KeyiSessionDiagnostics.typeText("shi", into: session, client: againA)
            expect(KeyiSessionDiagnostics.visibleCandidates(session).first == wordA, "app learning: app A shows its pick first")
            _ = KeyiSessionDiagnostics.sendKey(49, characters: " ", into: session, client: againA)
            expect(againA.documentText == wordA, "app learning: space in app A commits its pick")

            let againB = learningClient("com.keyi.diagnostic.learning.b")
            _ = KeyiSessionDiagnostics.typeText("shi", into: session, client: againB)
            let reorderedB = KeyiSessionDiagnostics.visibleCandidates(session)
            expect(reorderedB.first == wordB, "app learning: app B shows its own pick first, not app A's")
            _ = KeyiSessionDiagnostics.sendKey(125, characters: "\u{F701}", into: session, client: againB)
            _ = KeyiSessionDiagnostics.sendKey(49, characters: " ", into: session, client: againB)
            expect(
                reorderedB.count > 1 && againB.documentText == reorderedB[1],
                "app learning: arrow + space on a reordered page commits the word shown second"
            )
        }
    }

    // (9) The diagnostics never touch the live user data directory.
    expect(
        KeyiSessionDiagnostics.userDataOverride != nil,
        "round2: diagnostics run against a throwaway Rime user directory"
    )

    if failures.isEmpty {
        print("SESSION DIAGNOSTICS PASSED")
        exit(EXIT_SUCCESS)
    }
    reportFailure("session diagnostics failed: \(failures.joined(separator: ", "))")
}
