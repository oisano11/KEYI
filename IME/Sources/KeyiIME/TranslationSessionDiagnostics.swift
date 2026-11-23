import InputMethodKit
import KeyiIMEDiagnostics
import KeyiIMEKit

// Automatic translation on, with a fake translator ("EN(<source>)") injected
// through the session's diagnostics seam. It only works when the script sets
// KEYI_IME_DIAGNOSTIC_FAKE_TRANSLATION=1. Real Rime, mock client.
// Run with `KEYIIME --diagnose-session-translation`.
func runTranslationSessionDiagnostics() -> Never {
    KeyiPanelLayout.invisibleForDiagnostics = true
    guard ProcessInfo.processInfo.environment["KEYI_IME_DIAGNOSTIC_FAKE_TRANSLATION"] == "1",
          KeyiSessionDiagnostics.userDataOverride != nil,
          let session = KeyiSessionDiagnostics.sessionClass()
    else {
        reportFailure("translation diagnostics need KEYI_IME_DIAGNOSTIC_FAKE_TRANSLATION=1 and an isolated Rime directory")
    }
    var failures: [String] = []
    func expect(_ condition: Bool, _ label: String) {
        print("\(condition ? "PASS" : "FAIL"): \(label)")
        if !condition { failures.append(label) }
    }
    func pump(_ seconds: TimeInterval = 0.15) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
    func fresh() -> KeyiDiagnosticTextClient {
        let client = KeyiDiagnosticTextClient()
        KeyiSessionDiagnostics.activate(session, client: client)
        return client
    }
    @discardableResult
    func key(_ code: UInt16, _ chars: String, _ client: KeyiDiagnosticTextClient,
             _ modifiers: NSEvent.ModifierFlags = []) -> Bool {
        KeyiSessionDiagnostics.sendKey(code, characters: chars, into: session, client: client, modifiers: modifiers)
    }
    func type(_ text: String, _ client: KeyiDiagnosticTextClient) {
        _ = KeyiSessionDiagnostics.typeText(text, into: session, client: client)
    }
    /// Types 你好 and confirms it with space.
    func holdNihao(_ client: KeyiDiagnosticTextClient) {
        type("nihao", client)
        key(49, " ", client)
    }
    expect(KeyiSessionDiagnostics.fakeTranslation("install", in: session) == "ok", "translation: fake translator installs")
    // Pin the secure-input answer: the real system answer is machine-wide (a locked
    // screen or a focused password field in any app turns it on), which made this
    // group depend on the state of the machine running it.
    expect(KeyiSessionDiagnostics.fakeTranslation("secure:0", in: session) == "ok", "translation: secure input is pinned off for the checks")

    // (P) 英文后面的标点按英文（半角）出，中文后面照旧是中文标点（用户 2026-11-08）。
    func client(_ text: String, readable: Bool = true) -> KeyiDiagnosticTextClient {
        let client = KeyiDiagnosticTextClient(documentText: text)
        client.refusesTextReads = !readable
        KeyiSessionDiagnostics.activate(session, client: client)
        return client
    }
    // 第一个汉字之前的英文直接上屏：拼音直接接标点、回车上屏字母、空格选英文候选，之后的标点都是英文的。
    var c = fresh()
    type("hello", c)
    type(",", c)
    expect(c.committedText == "hello," && c.markedText.isEmpty, "punctuation 1: hello then , gives hello, (got \(c.committedText))")
    c = fresh()
    type("model", c)
    key(36, "\r", c)
    type(",", c)
    expect(c.committedText == "model,", "punctuation 1: Enter-committed letters then , gives model, (got \(c.committedText))")
    c = fresh()
    type("hello", c)
    key(49, " ", c)
    type("?", c)
    expect(c.committedText == "hello?", "punctuation 1: an English candidate then ? gives ? (got \(c.committedText))")
    // 输入框里原有的英文（读得回来的宿主）。
    c = client("Hello there")
    type(",", c)
    expect(c.committedText == "Hello there,", "punctuation 2: after English already in the field , is English (got \(c.committedText))")
    c = client("Hello.")
    type("\"", c)
    expect(c.committedText == "Hello.\"", "punctuation 2: a quote after English. is a plain quote (got \(c.committedText))")
    c = client("git commit ")
    type("-", c)
    expect(c.committedText == "git commit -" && c.markedText.isEmpty, "punctuation 2: - after a space after English goes straight in, no dash menu (got \(c.committedText) marked \(c.markedText))")
    c = client("Python3")
    type(",", c)
    expect(c.committedText == "Python3,", "punctuation 2: digits after English stay English (got \(c.committedText))")
    // 中文后面、什么都看不出来时照旧是中文标点。
    c = client("你好")
    type(",", c)
    expect(c.committedText == "你好，", "punctuation 3: after Chinese in the field , stays Chinese (got \(c.committedText))")
    c = client("价格20")
    type(",", c)
    expect(c.committedText == "价格20，", "punctuation 3: digits after Chinese stay Chinese (got \(c.committedText))")
    c = fresh()
    type(",", c)
    expect(c.committedText == "，", "punctuation 3: an empty field gives Chinese punctuation (got \(c.committedText))")
    c = fresh()
    holdNihao(c)
    type(",", c)
    expect(c.markedText == "你好，" && c.committedText.isEmpty, "punctuation 3: after held Chinese , is Chinese and joins the paragraph (got \(c.markedText))")
    key(53, "\u{1b}", c)
    // 打拼音直接按标点：按面板上第一个候选转字。women 面板上第一个是 我们（不是英文 women）。
    c = fresh()
    type("women", c)
    type(",", c)
    expect(c.markedText == "我们，" && c.committedText.isEmpty, "punctuation 3: women then , takes the shown 我们 and a Chinese comma (got \(c.markedText) / \(c.committedText))")
    key(53, "\u{1b}", c)
    // 下划线段里：英文后面的标点是英文的，标点照旧并进这段、不触发翻译。
    c = fresh()
    holdNihao(c)
    type("github", c)
    type(",", c)
    expect(c.markedText == "你好GitHub," && c.committedText.isEmpty, "punctuation 4: inside the paragraph , after GitHub is English and stays held (got \(c.markedText))")
    type("haode", c)
    type(".", c)
    expect(c.markedText == "你好GitHub,好的。", "punctuation 4: after Chinese again . is Chinese (got \(c.markedText))")
    key(53, "\u{1b}", c)
    c = fresh()
    holdNihao(c)
    type("hello", c)
    key(36, "\r", c)
    type("?", c)
    expect(c.markedText == "你好hello?" && c.committedText.isEmpty, "punctuation 4: Enter-committed letters then ? inside the paragraph (got \(c.markedText))")
    key(36, "\r", c)
    pump()
    expect(c.committedText == "EN(你好hello?)", "punctuation 4: the paragraph with English punctuation is translated once (got \(c.committedText))")
    // 译文上屏后接着打标点；读不回文字的宿主（终端）靠输入法自己记下的上屏内容。
    KeyiSessionDiagnostics.fakeTranslation("reply:Good evening", in: session)
    c = client("", readable: false)
    type("wanshang", c)
    key(49, " ", c)
    key(36, "\r", c)
    pump()
    KeyiSessionDiagnostics.fakeTranslation("reply:", in: session)
    expect(c.committedText == "Good evening", "punctuation 5: setup: the English is committed (got \(c.committedText))")
    type("!", c)
    expect(c.committedText == "Good evening!", "punctuation 5: ! after the committed English is English (got \(c.committedText))")
    c = client("", readable: false)
    type("hello", c)
    key(36, "\r", c)
    type(",", c)
    expect(c.committedText == "hello,", "punctuation 5: unreadable field: , after Enter-committed letters is English (got \(c.committedText))")
    // 交给应用直接打出的大写字母（读不回的宿主，替身不会自己打字，只看输入法交出的标点）。
    c = client("", readable: false)
    expect(!KeyiSessionDiagnostics.typeText("A", into: session, client: c), "punctuation 5: setup: a capital letter goes to the app")
    type(",", c)
    expect(c.committedText == ",", "punctuation 5: , after a capital the app typed is English (got \(c.committedText))")
    // 光标可能挪了（回车交给应用、点了鼠标）之后，读不回的宿主不知道前面是什么，照旧是中文标点。
    c = client("", readable: false)
    type("hello", c)
    key(36, "\r", c)
    expect(!key(36, "\r", c), "punctuation 6: setup: the next Enter goes to the app")
    type(",", c)
    expect(c.committedText == "hello，", "punctuation 6: after Enter went to the app the context is unknown: Chinese (got \(c.committedText))")
    c = client("", readable: false)
    type("hello", c)
    key(36, "\r", c)
    KeyiSessionDiagnostics.fakeTranslation("mouse:down", in: session)
    pump(0.05)
    type(",", c)
    expect(c.committedText == "hello，", "punctuation 6: after a mouse click the context is unknown: Chinese (got \(c.committedText))")
    c = client("", readable: false)
    type("hello", c)
    key(36, "\r", c)
    key(51, "\u{7f}", c)
    type(".", c)
    expect(c.committedText == "hello.", "punctuation 6: Backspace passed to the app keeps the English before it (got \(c.committedText))")
    // 输入框读得回来时，点过鼠标后按光标前的文字判断。
    c = client("你好")
    KeyiSessionDiagnostics.fakeTranslation("mouse:down", in: session)
    pump(0.05)
    type(",", c)
    expect(c.committedText == "你好，", "punctuation 6: readable field after a click: Chinese before the caret gives Chinese (got \(c.committedText))")

    // (P7) 网址和邮箱（用户 2026-11-11）：www.、https:、字母@ 之后整段照打的样子留在输入里，
    // 标点前的字母不转汉字；空格、回车都按打的样子上屏，有暂存段时并进去。
    c = fresh()
    type("www.baidu.com", c)
    expect(c.markedText == "www.baidu.com" && c.committedText.isEmpty, "punctuation 7: www.baidu.com stays as typed, not 万维网。百度。 (got \(c.markedText) / \(c.committedText))")
    expect(KeyiSessionDiagnostics.visibleCandidates(session).isEmpty, "punctuation 7: a web address shows no candidates")
    key(49, " ", c)
    expect(c.committedText == "www.baidu.com" && c.markedText.isEmpty, "punctuation 7: space commits the address as typed (got \(c.committedText))")
    c = fresh()
    type("https://x.com/a?b=1&c=2#d", c)
    key(36, "\r", c)
    expect(c.committedText == "https://x.com/a?b=1&c=2#d", "punctuation 7: digits, = - & # / ? stay in an https address (got \(c.committedText))")
    c = fresh()
    type("www.site123.com", c)
    expect(c.markedText == "www.site123.com", "punctuation 7: digits in an address do not pick candidates (got \(c.markedText))")
    key(53, "\u{1b}", c)
    c = fresh()
    type("oisano@icloud.com", c)
    key(49, " ", c)
    expect(c.committedText == "oisano@icloud.com", "punctuation 7: letters then @ is an email, as typed, not 哦isano@iCloud (got \(c.committedText))")
    c = fresh()
    holdNihao(c)
    type("www.baidu.com", c)
    key(49, " ", c)
    expect(c.markedText == "你好www.baidu.com" && c.committedText.isEmpty, "punctuation 7: an address after held Chinese joins the paragraph (got \(c.markedText))")
    key(53, "\u{1b}", c)
    c = fresh()
    type("www.ab", c)
    key(51, "\u{8}", c); key(51, "\u{8}", c); key(51, "\u{8}", c)
    expect(c.markedText == "www" && KeyiSessionDiagnostics.visibleCandidates(session).first == "万维网", "punctuation 7: deleting back to www gives pinyin candidates again (got \(c.markedText))")
    key(53, "\u{1b}", c)

    // (P8) 不带前缀的网址（用户 2026-11-11「把 baidu.com 这种不带前缀的也修好」）：按 . 照旧先转字，
    // 接着打到常见后缀时候选里多一项整段网址；选它就把转出来的字改回照打的样子，后面的路径照打。
    func domain(_ text: String, held: Bool = false) -> KeyiDiagnosticTextClient {
        let c = fresh()
        if held { holdNihao(c) }
        type(text, c)
        return c
    }
    c = domain("baidu.com")
    expect(KeyiSessionDiagnostics.visibleCandidates(session).first == "baidu.com", "punctuation 8: baidu.com offers the address first (got \(KeyiSessionDiagnostics.visibleCandidates(session)))")
    expect(c.markedText == "baidu.com", "punctuation 8: with the address highlighted the field already shows baidu.com (got \(c.markedText))")
    key(125, "", c)
    expect(c.markedText == "百度。com", "punctuation 8: moving to a Chinese candidate shows 百度。 and the pinyin again (got \(c.markedText))")
    key(126, "", c)
    key(49, " ", c)
    expect(c.committedText == "baidu.com" && c.markedText.isEmpty, "punctuation 8: space commits baidu.com as typed (got \(c.committedText) / \(c.markedText))")
    c = domain("baidu.com", held: true)
    key(36, "\r", c)
    expect(c.markedText == "你好baidu.com" && c.committedText.isEmpty, "punctuation 8: Enter after held Chinese: 百度。 is replaced inside the paragraph (got \(c.markedText))")
    key(53, "\u{1b}", c)
    // 用户 11-11 截图：英文 mail. 在暂存段里，后面 sina 转成了「是那。」——整段 mail.sina.com 都要接上。
    c = domain("mail.sina.com", held: true)
    expect(KeyiSessionDiagnostics.visibleCandidates(session).first == "mail.sina.com", "punctuation 8: mail. before sina. stays part of the address (got \(KeyiSessionDiagnostics.visibleCandidates(session)))")
    expect(c.markedText == "你好mail.sina.com", "punctuation 8: the paragraph shows mail.sina.com, not 是那。com (got \(c.markedText))")
    key(49, " ", c)
    expect(c.markedText == "你好mail.sina.com", "punctuation 8: space keeps mail.sina.com (got \(c.markedText))")
    key(53, "\u{1b}", c)
    c = domain("github.com/oisano11")
    key(49, " ", c)
    expect(c.committedText == "GitHub.com/oisano11", "punctuation 8: English already committed stays, the path is typed as is (got \(c.committedText))")
    c = domain("news.sina.com.cn")
    key(49, " ", c)
    expect(c.committedText == "news.sina.com.cn", "punctuation 8: several labels and . after the suffix (got \(c.committedText))")
    c = domain("baidu.com,")
    expect(c.committedText == "baidu.com,", "punctuation 8: other punctuation commits the address, then English punctuation (got \(c.committedText))")
    c = domain("claude.ai", held: true)
    key(49, " ", c)
    expect(c.markedText == "你好claude.ai", "punctuation 8: claude.ai (got \(c.markedText))")
    key(53, "\u{1b}", c)
    // 整段都能拼成拼音时网址排第二，空格照旧出中文；普通的中文句号不受影响。
    c = domain("woaini.ai")
    expect(Array(KeyiSessionDiagnostics.visibleCandidates(session).prefix(2)) == ["爱", "woaini.ai"], "punctuation 8: all-pinyin woaini.ai puts the address second (got \(KeyiSessionDiagnostics.visibleCandidates(session)))")
    key(49, " ", c)
    expect(c.markedText == "我爱你。爱", "punctuation 8: space still gives 我爱你。爱 (got \(c.markedText))")
    key(53, "\u{1b}", c)
    c = domain("haode.wozoule")
    key(49, " ", c)
    expect(c.markedText == "好的。我走了", "punctuation 8: haode.wozoule is still 好的。我走了 (got \(c.markedText))")
    key(53, "\u{1b}", c)
    // 第二项是什么跟着词表变（com 有英文联想 come），按此刻面板上的第二项核对。
    c = domain("zhihu.com")
    let zhihuPage = KeyiSessionDiagnostics.visibleCandidates(session)
    type("2", c)
    expect(zhihuPage.first == "zhihu.com" && zhihuPage.count > 1 && c.markedText == "知乎。" + zhihuPage[1],
           "punctuation 8: a digit still picks the shown candidate (got \(c.markedText), page \(zhihuPage))")
    key(53, "\u{1b}", c)
    // 中间按了别的键（这里是空格选字）就不再接：. 之后的不算网址。
    c = domain("baidu")
    key(49, " ", c)
    type(".com", c)
    expect(!KeyiSessionDiagnostics.visibleCandidates(session).contains("baidu.com"), "punctuation 8: after space picked 百度 there is no address (got \(KeyiSessionDiagnostics.visibleCandidates(session)))")
    key(53, "\u{1b}", c)
    // 打后缀时退格再打回来，网址那一项还在；退格删进已经上屏的部分时输入作废。
    c = domain("github.com")
    key(51, "\u{8}", c); key(51, "\u{8}", c)
    type("om", c)
    expect(KeyiSessionDiagnostics.visibleCandidates(session).first == "GitHub.com", "punctuation 8: deleting and retyping the suffix offers the address again (got \(KeyiSessionDiagnostics.visibleCandidates(session)))")
    key(53, "\u{1b}", c)
    c = domain("github.com/")
    key(51, "\u{8}", c); key(51, "\u{8}", c); key(51, "\u{8}", c); key(51, "\u{8}", c)
    expect(c.markedText.isEmpty && c.committedText == "GitHub.", "punctuation 8: backspacing the address down to what is committed drops it (got \(c.committedText) / \(c.markedText))")

    // (1) Space confirms: the Chinese stays as marked text and is not committed.
    c = fresh()
    holdNihao(c)
    expect(c.markedText == "你好" && c.committedText.isEmpty, "translation 1: confirmed Chinese is marked text, nothing committed")
    type("wo", c)
    expect(c.markedText == "你好wo" && c.committedText.isEmpty, "translation 1: marked text = held Chinese + pinyin")
    expect(c.selectedRange().location == 4, "translation 1: caret sits inside the pinyin, offset by the held length")
    expect((c.lastAnchorIndex ?? -1) >= 3, "translation 1: candidate anchor is offset by the held length")
    key(53, "\u{1b}", c)
    expect(c.markedText == "你好" && c.committedText.isEmpty, "translation 1: Esc clears the pinyin and keeps the held Chinese")
    key(53, "\u{1b}", c)
    pump()

    // (2) 。 is ordinary text and stays held; Enter commits English for the whole paragraph
    // and is not passed on.
    c = fresh()
    holdNihao(c)
    type(".", c)
    pump()
    expect(c.markedText == "你好。" && c.committedText.isEmpty, "translation 2: 。stays held with the paragraph, nothing committed")
    expect(key(36, "\r", c), "translation 2: Enter after 。is not passed to the app")
    pump()
    expect(c.committedText == "EN(你好。)" && c.markedText.isEmpty, "translation 2: Enter commits English for the whole paragraph including 。")
    expect(!key(36, "\r", c), "translation 2: the next Enter after the paragraph goes to the app")
    c = fresh()
    holdNihao(c)
    expect(key(36, "\r", c), "translation 2: first Enter is not passed to the app")
    pump()
    expect(c.committedText == "EN(你好)" && c.markedText.isEmpty, "translation 2: Enter commits English")
    expect(!key(36, "\r", c), "translation 2: the next Enter goes to the app")
    // (6) After the English is committed it is plain text: Backspace goes to the app.
    c = fresh()
    holdNihao(c)
    key(36, "\r", c)
    pump()
    expect(!key(51, "\u{7f}", c), "translation 6: Backspace after English goes to the app")
    expect(c.committedText == "EN(你好)" && c.markedText.isEmpty, "translation 6: no Chinese comes back")
    // Backspace inside a held sentence still deletes a held character.
    c = fresh()
    holdNihao(c)
    expect(key(51, "\u{7f}", c), "translation 6: Backspace inside the held sentence is handled")
    expect(c.markedText == "你" && c.committedText.isEmpty, "translation 6: it deletes one held character")
    key(53, "\u{1b}", c)

    // (3) A second Enter while waiting commits the Chinese, then Enter is passed on.
    // 谢谢 has not been translated before, so the controller's cache cannot answer it.
    KeyiSessionDiagnostics.fakeTranslation("hold", in: session)
    c = fresh()
    type("xiexie", c)
    key(49, " ", c)
    expect(c.markedText == "谢谢", "translation 3: 谢谢 is held")
    expect(key(36, "\r", c), "translation 3: first Enter swallowed")
    pump()
    expect(c.markedText == "谢谢" && c.committedText.isEmpty, "translation 3: still waiting for English")
    expect(key(36, "\r", c), "translation 3: second Enter swallowed")
    expect(c.committedText == "谢谢" && c.markedText.isEmpty, "translation 3: second Enter commits the Chinese")
    KeyiSessionDiagnostics.fakeTranslation("release", in: session)
    pump()
    expect(c.committedText == "谢谢", "translation 3: the late English is dropped")
    expect(!key(36, "\r", c), "translation 3: third Enter goes to the app")

    // (4) Esc commits the Chinese.
    c = fresh()
    holdNihao(c)
    expect(key(53, "\u{1b}", c), "translation 4: Esc is handled")
    expect(c.committedText == "你好" && c.markedText.isEmpty, "translation 4: Esc commits the Chinese")

    // (5) commitComposition (click-away): held Chinese + pinyin letters.
    c = fresh()
    holdNihao(c)
    type("wo", c)
    KeyiSessionDiagnostics.commitComposition(session, client: c)
    expect(c.committedText == "你好wo" && c.markedText.isEmpty, "translation 5: commitComposition commits Chinese + pinyin letters")
    pump()
    expect(c.committedText == "你好wo", "translation 5: nothing is translated afterwards")
    // Click-away with the overlay's English ready commits the English.
    c = fresh()
    holdNihao(c)
    pump(1.8)
    KeyiSessionDiagnostics.commitComposition(session, client: c)
    expect(c.committedText == "EN(你好)" && c.markedText.isEmpty, "translation 5: click-away with the preview ready commits English")
    // Deactivate (switching window or input method) follows the same rule.
    c = fresh()
    holdNihao(c)
    pump(1.8)
    KeyiSessionDiagnostics.deactivate(session, client: c)
    expect(c.committedText == "EN(你好)" && c.markedText.isEmpty, "translation 5: deactivate with the preview ready commits English")
    // Click-away before the English arrives commits the Chinese.
    KeyiSessionDiagnostics.fakeTranslation("hold", in: session)
    c = fresh()
    type("zaijian", c)
    key(49, " ", c)
    pump(1.8)
    KeyiSessionDiagnostics.commitComposition(session, client: c)
    expect(c.committedText == "再见" && c.markedText.isEmpty, "translation 5: click-away before the English arrives commits Chinese")
    KeyiSessionDiagnostics.fakeTranslation("release", in: session)
    pump()
    expect(c.committedText == "再见", "translation 5: the late preview writes nothing")

    // (10) Space keeps the Chinese (user 2026-11-23, instead of tapping Shift).
    func tapShift(_ client: KeyiDiagnosticTextClient, _ code: UInt16 = 56) -> (Bool, Bool) {
        let down = KeyiSessionDiagnostics.sendFlags(code, modifiers: .shift, into: session, client: client)
        let up = KeyiSessionDiagnostics.sendFlags(code, modifiers: [], into: session, client: client)
        return (down, up)
    }
    c = fresh()
    holdNihao(c)
    expect(c.markedText == "你好" && c.committedText.isEmpty, "translation 10: space during pinyin still selects (held)")
    expect(key(49, " ", c), "translation 10: space with text held is swallowed")
    expect(c.committedText == "你好" && c.markedText.isEmpty, "translation 10: space commits the held Chinese")
    pump(1.8)
    expect(c.committedText == "你好", "translation 10: the space-committed Chinese is not translated")
    expect(!key(36, "\r", c), "translation 10: the next Enter goes to the app")
    // With nothing held, space is an ordinary space again.
    expect(!key(49, " ", c) && c.committedText == "你好", "translation 10: space with nothing held goes to the app")
    c = fresh()
    holdNihao(c)
    pump(1.8)
    key(49, " ", c)
    expect(c.committedText == "你好" && c.markedText.isEmpty, "translation 10: space keeps Chinese even with English ready")
    // Shift+space counts as space.
    c = fresh()
    holdNihao(c)
    key(49, " ", c, .shift)
    expect(c.committedText == "你好" && c.markedText.isEmpty, "translation 10: Shift+space keeps the Chinese")
    // Space after Enter while the English is not out yet keeps the Chinese.
    // 明天 has not been translated before, so the controller's cache cannot answer it.
    KeyiSessionDiagnostics.fakeTranslation("hold", in: session)
    c = fresh()
    type("mingtian", c)
    key(49, " ", c)
    expect(c.markedText == "明天", "translation 10: 明天 is held (got \(c.markedText))")
    key(36, "\r", c)
    pump()
    expect(c.markedText == "明天" && c.committedText.isEmpty, "translation 10: still waiting for English")
    expect(key(49, " ", c), "translation 10: space while waiting is swallowed")
    expect(c.committedText == "明天" && c.markedText.isEmpty, "translation 10: space while waiting commits the Chinese")
    KeyiSessionDiagnostics.fakeTranslation("release", in: session)
    pump()
    expect(c.committedText == "明天", "translation 10: the late English is dropped after space")
    // Space during pinyin selects the candidate into the paragraph; the next space commits.
    c = fresh()
    holdNihao(c)
    type("shijie", c)
    key(49, " ", c)
    expect(c.markedText == "你好世界" && c.committedText.isEmpty, "translation 10: space during pinyin joins the candidate (got \(c.markedText))")
    key(49, " ", c)
    expect(c.committedText == "你好世界" && c.markedText.isEmpty, "translation 10: the second space commits 你好世界")
    // Tapping Shift no longer keeps the Chinese: Shift only types capitals.
    c = fresh()
    holdNihao(c)
    let (shiftDown, shiftUp) = tapShift(c)
    expect(!shiftDown && !shiftUp, "translation 10: Shift events are never consumed")
    expect(c.markedText == "你好" && c.committedText.isEmpty, "translation 10: tapping Shift keeps the paragraph held")
    type("wo", c)
    _ = tapShift(c)
    expect(c.committedText.isEmpty && c.markedText.hasPrefix("你好"), "translation 10: tapping Shift during pinyin commits nothing")
    key(53, "\u{1b}", c)
    key(53, "\u{1b}", c)
    expect(c.committedText == "你好" && c.markedText.isEmpty, "translation 10: Esc still keeps the Chinese")

    // (7) Digits typed between Chinese join the sentence (a space would keep the Chinese).
    c = fresh()
    holdNihao(c)
    type("3", c)
    type("shijie", c)
    key(49, " ", c)
    expect(c.markedText == "你好3世界" && c.committedText.isEmpty, "translation 7: a digit joins the held sentence")
    key(36, "\r", c)
    pump()
    expect(c.committedText == "EN(你好3世界)", "translation 7: the whole sentence is translated together")

    // Enter while typing pinyin keeps the letters in the sentence.
    c = fresh()
    holdNihao(c)
    type("ab", c)
    key(36, "\r", c)
    expect(c.markedText == "你好ab", "translation 0: Enter while typing pinyin joins the letters, no translation yet")
    key(53, "\u{1b}", c)

    // (8) ⌘↩ counts as Enter and is swallowed on the first press.
    c = fresh()
    holdNihao(c)
    expect(key(36, "\r", c, .command), "translation 8: ⌘↩ is swallowed")
    pump()
    expect(c.committedText == "EN(你好)", "translation 8: ⌘↩ converts like Enter")
    expect(!key(36, "\r", c, .command), "translation 8: the next ⌘↩ goes to the app")
    // Other chords commit the Chinese and go to the app; navigation keys do nothing.
    c = fresh()
    holdNihao(c)
    expect(key(123, "\u{f702}", c), "translation 8: ← is inert while text is held")
    expect(key(115, "\u{f729}", c), "translation 8: Home is inert while text is held")
    expect(c.markedText == "你好", "translation 8: navigation keeps the held Chinese")
    expect(!key(8, "c", c, .command), "translation 8: ⌘C goes to the app")
    expect(c.committedText == "你好" && c.markedText.isEmpty, "translation 8: ⌘C first commits the Chinese")

    // The same keys arrive through the IMK command callback on some hosts.
    c = fresh()
    holdNihao(c)
    expect(KeyiSessionDiagnostics.sendCommand("insertNewline:", into: session, client: c), "translation cmd: insertNewline: is swallowed while text is held")
    pump()
    expect(c.committedText == "EN(你好)", "translation cmd: insertNewline: converts like Enter")
    expect(!KeyiSessionDiagnostics.sendCommand("deleteBackward:", into: session, client: c), "translation cmd: deleteBackward: after English goes to the app")
    expect(c.committedText == "EN(你好)" && c.markedText.isEmpty, "translation cmd: no Chinese comes back")
    c = fresh()
    holdNihao(c)
    expect(KeyiSessionDiagnostics.sendCommand("moveLeft:", into: session, client: c), "translation cmd: moveLeft: is inert while text is held")
    expect(KeyiSessionDiagnostics.sendCommand("deleteBackward:", into: session, client: c), "translation cmd: deleteBackward: deletes the last held character")
    expect(c.markedText == "你", "translation cmd: backspace removes one held character")
    key(53, "\u{1b}", c)

    // (9) Password fields and auto-off behave like plain pinyin.
    KeyiSessionDiagnostics.fakeTranslation("secure:1", in: session)
    c = fresh()
    holdNihao(c)
    expect(c.committedText == "你好" && c.markedText.isEmpty, "translation 9: secure field commits Chinese immediately")
    KeyiSessionDiagnostics.fakeTranslation("secure:0", in: session)
    KeyiSessionDiagnostics.fakeTranslation("auto:0", in: session)
    c = fresh()
    holdNihao(c)
    expect(c.committedText == "你好" && c.markedText.isEmpty, "translation 9: automatic translation off commits Chinese immediately")
    expect(!key(36, "\r", c), "translation 9: Enter goes straight to the app when off")
    KeyiSessionDiagnostics.fakeTranslation("auto:1", in: session)

    // ⌘↩ while pinyin is typed and nothing is held (auto-translation off) keeps its
    // pre-change behaviour: letters committed, key passed to the app.
    KeyiSessionDiagnostics.fakeTranslation("auto:0", in: session)
    c = fresh()
    type("nihao", c)
    expect(!key(36, "\r", c, .command), "translation ⌘↩ with nothing held: the key goes to the app")
    expect(c.committedText == "nihao" && c.markedText.isEmpty, "translation ⌘↩ with nothing held: the letters are committed first")
    KeyiSessionDiagnostics.fakeTranslation("auto:1", in: session)
    // Auto on but nothing confirmed yet: same.
    c = fresh()
    type("nihao", c)
    expect(!key(36, "\r", c, .command), "translation ⌘↩ auto on, nothing held: the key goes to the app")
    expect(c.committedText == "nihao" && c.markedText.isEmpty, "translation ⌘↩ auto on, nothing held: the letters are committed first")

    // (10) A key from another client, with no activation in between, never draws
    // the owner's remaining preedit there. The owner's whole composition is settled
    // (held Chinese + pinyin letters) in the owner.
    for (name, code, chars) in [("space", UInt16(49), " "), ("enter", UInt16(36), "\r")] {
        let ownerA = fresh()
        holdNihao(ownerA)
        type("nihao", ownerA)
        let strangerB = KeyiDiagnosticTextClient()
        let passedOn = key(code, chars, strangerB)
        pump()
        expect(!passedOn, "translation cross-client \(name): the key goes to the app of the new client")
        expect(strangerB.markedText.isEmpty, "translation cross-client \(name): no marked text in the new client")
        expect(strangerB.documentText.isEmpty, "translation cross-client \(name): no pinyin or Chinese in the new client")
        expect(
            ownerA.committedText == "你好nihao" && ownerA.markedText.isEmpty,
            "translation cross-client \(name): the owner is settled with held Chinese + pinyin letters"
        )
        expect(
            !KeyiSessionDiagnostics.ownsComposition(session, client: strangerB),
            "translation cross-client \(name): the new client owns no composition"
        )
    }

    // (11) Command / Control / Option + Enter behave like Enter: with held text the
    // first press converts and is never passed on; pinyin being typed joins the held
    // sentence first.
    for (name, flags) in [
        ("⌘↩", NSEvent.ModifierFlags.command),
        ("⌃↩", NSEvent.ModifierFlags.control),
        ("⌥↩", NSEvent.ModifierFlags.option),
        ("⇧↩", NSEvent.ModifierFlags.shift),
    ] {
        c = fresh()
        holdNihao(c)
        type("wo", c)
        let passedOn = key(36, "\r", c, flags)
        expect(passedOn, "translation \(name) during pinyin: the key is consumed")
        expect(c.committedText.isEmpty, "translation \(name) during pinyin: nothing reaches the document")
        expect(c.markedText == "你好wo", "translation \(name) during pinyin: the letters join the held sentence")
        expect(key(36, "\r", c), "translation \(name) during pinyin: the next Enter is consumed")
        pump()
        expect(c.committedText == "EN(你好wo)" && c.markedText.isEmpty, "translation \(name) during pinyin: the next Enter converts")
        // Held text with no pinyin: the first press converts and is consumed.
        c = fresh()
        holdNihao(c)
        expect(key(36, "\r", c, flags), "translation \(name) with held text: the first press is consumed")
        pump()
        expect(c.committedText == "EN(你好)", "translation \(name) with held text: converts")
    }

    expect(
        KeyiSessionDiagnostics.fakeTranslation("requests", in: session).contains("你好"),
        "translation: the fake translator was the one asked"
    )

    // (12) Shift+digit types the symbol on that key, also when the host reports the
    // bare digit as charactersIgnoringModifiers (it typed the digit before).
    do {
        func shiftKey(_ code: UInt16, _ symbol: String, _ digit: String, _ client: KeyiDiagnosticTextClient) {
            _ = KeyiSessionDiagnostics.sendFlags(56, modifiers: .shift, into: session, client: client)
            _ = KeyiSessionDiagnostics.sendKey(code, characters: symbol, into: session, client: client,
                                               modifiers: .shift, charactersIgnoringModifiers: digit)
            _ = KeyiSessionDiagnostics.sendFlags(56, modifiers: [], into: session, client: client)
        }
        c = fresh()
        type("nihao", c)
        shiftKey(18, "!", "1", c)
        expect(!c.markedText.contains("1") && !c.committedText.contains("1"),
               "translation: Shift+1 while typing pinyin does not type the digit")
        expect(c.markedText.hasSuffix("！") || c.committedText.hasSuffix("！"),
               "translation: Shift+1 while typing pinyin types ！")
        c = fresh()
        shiftKey(18, "!", "1", c)
        expect(c.committedText == "！", "translation: Shift+1 with nothing typed commits ！")
        c = fresh()
        shiftKey(19, "@", "2", c)
        expect(c.committedText == "@", "translation: Shift+2 with nothing typed commits @")
        c = fresh()
        holdNihao(c)
        shiftKey(18, "!", "1", c)
        expect(c.markedText.hasSuffix("！") && !c.markedText.contains("1"),
               "translation: Shift+1 after held Chinese joins ！ to the sentence")
        c = fresh()
        type("nihao", c)
        key(18, "1", c)
        expect((c.markedText + c.committedText).contains("你") && !(c.markedText + c.committedText).contains("1"),
               "translation: a bare digit while typing pinyin still picks the candidate")
    }

    // (13) The candidate row shows only candidates (the pinyin is on its own small line
    // above, not trailing the row) and is never wider than the screen: long candidates
    // end in "…".
    MainActor.assumeIsolated {
        let nine = ["可以", "刻意", "可疑", "科一", "可依", "课椅", "可意", "可", "刻"]
        let short = KeyiPanelLayout.candidateStripForDiagnostics(candidates: nine, maxWidth: 1428)
        expect(short.texts == nine && short.fits,
               "translation: short candidates are shown whole")
        let shortWithPinyin = short.width
        let long = ["拼音放到后面显示是出于什么逻辑可以", "拼音放到后面先试试处于什么逻辑可以",
                    "拼音放倒后棉线事实处于什么逻辑可以", "拼音", "平", "品", "拼", "凭", "评"]
        let strip = KeyiPanelLayout.candidateStripForDiagnostics(candidates: long, maxWidth: 800)
        expect(strip.width <= 800, "translation: the strip is never wider than the screen (\(strip.width))")
        expect(strip.fits, "translation: every candidate is drawn inside the strip")
        expect(strip.texts[0].hasSuffix("…") && strip.texts[0].hasPrefix("拼音"),
               "translation: a long candidate is shortened with …")
        expect(Array(strip.texts[3...]) == Array(long[3...]),
               "translation: short candidates stay whole when long ones are shortened")
        let edges = KeyiPanelLayout.candidateLeftEdgesForDiagnostics(candidates: ["都", "斗"])
        expect(edges.number == edges.shift,
               "translation: the first candidate's number and the typed text share one left edge (\(edges))")
        let wide = KeyiPanelLayout.candidateStripForDiagnostics(candidates: long, maxWidth: 4000)
        expect(wide.texts == long, "translation: nothing is shortened when it fits")
        // Nine pills (10 pt padding each side, 17 pt text, per the design) measure about
        // 616; a trailing pinyin would push the row well past 680.
        expect(shortWithPinyin < 680, "translation: the strip has no trailing pinyin (\(shortWithPinyin))")
    }

    // (11) Candidates and the 中/英 preview share one panel next to the caret: it never
    // covers the caret line, stays on screen, goes below the line when there is room
    // and above it otherwise. Below the line its top edge is the same whether or not
    // the candidate row is there, so only the bottom moves when the row comes and goes.
    do {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let withCandidates = NSSize(width: 460, height: 136)
        let previewOnly = NSSize(width: 460, height: 96)
        func frame(_ size: NSSize, caretY: CGFloat, x: CGFloat = 100) -> (NSRect, Bool) {
            let caret = NSRect(x: x, y: caretY, width: 1, height: 20)
            let below = KeyiPanelLayout.panelFitsBelow(anchor: caret, height: 150, visible: screen)
                || !KeyiPanelLayout.panelFitsAbove(anchor: caret, height: size.height, visible: screen)
            let origin = KeyiPanelLayout.panelOrigin(size: size, anchor: caret, below: below, x: x - 12, visible: screen)
            return (NSRect(origin: origin, size: size), below)
        }
        let caretAt: [(String, CGFloat, CGFloat)] = [
            ("near the screen bottom", 30, 100), ("mid screen", 450, 100),
            ("near the screen top", 860, 100), ("right edge", 300, 1400),
        ]
        for (label, y, x) in caretAt {
            let caret = NSRect(x: x, y: y, width: 1, height: 20)
            for size in [withCandidates, previewOnly] {
                let (panel, _) = frame(size, caretY: y, x: x)
                expect(!panel.intersects(caret), "panels 11: \(label) the panel does not cover the caret line (\(panel))")
                expect(screen.insetBy(dx: 5, dy: 5).contains(panel), "panels 11: \(label) the panel stays on screen")
            }
        }
        let (mid, midBelow) = frame(withCandidates, caretY: 450)
        let (midPreview, _) = frame(previewOnly, caretY: 450)
        expect(midBelow && mid.maxY <= 450, "panels 11: mid screen the panel is below the caret line")
        expect(mid.maxY == midPreview.maxY, "panels 11: the top edge stays put when the candidate row goes away")
        expect(abs(mid.minX - 88) < 0.5, "panels 11: the panel's text lines up with the caret")
        let (low, lowBelow) = frame(withCandidates, caretY: 30)
        expect(!lowBelow && low.minY >= 50, "panels 11: near the bottom the panel goes above the caret line")
        // The text being typed wraps to a second line: the caret is only on line 2, but
        // the panel above it must not cover line 1 of the same composition.
        let line1 = NSRect(x: 600, y: 60, width: 0, height: 20)
        let line2 = NSRect(x: 100, y: 36, width: 0, height: 20)
        let wrapped = KeyiPanelLayout.compositionLines(
            anchor: line2,
            previous: KeyiPanelLayout.compositionLines(anchor: line1, previous: nil)
        )
        let wrappedOrigin = KeyiPanelLayout.panelOrigin(
            size: previewOnly, anchor: wrapped, below: false, x: 88, visible: screen
        )
        let wrappedPanel = NSRect(origin: wrappedOrigin, size: previewOnly)
        expect(!wrappedPanel.intersects(line1) && !wrappedPanel.intersects(line2),
               "panels 13: above a wrapped composition the panel covers neither line (\(wrappedPanel))")
        // Claude's composer grows upward: after the wrap the caret line stays where line 1
        // was and line 1 moves up, so the remembered rows are stale. The host's rect for
        // the first marked character says where the composition really starts.
        let movedUp = NSRect(x: 600, y: 84, width: 0, height: 20)
        let stale = KeyiPanelLayout.compositionLines(anchor: line1, previous: nil)
        let grown = KeyiPanelLayout.compositionLines(anchor: line1, start: movedUp, previous: stale)
        let grownPanel = NSRect(
            origin: KeyiPanelLayout.panelOrigin(size: previewOnly, anchor: grown, below: false, x: 88, visible: screen),
            size: previewOnly
        )
        expect(!grownPanel.intersects(movedUp) && !grownPanel.intersects(line1),
               "panels 13: above an upward-growing composer the panel covers neither line (\(grownPanel))")
        expect(KeyiPanelLayout.compositionLines(anchor: line1, start: .zero, previous: stale) == stale,
               "panels 13: without the start rect the remembered rows are used")
        expect(KeyiPanelLayout.compositionLines(
                   anchor: line1, start: NSRect(x: 0, y: 880, width: 0, height: 20), previous: stale) == stale,
               "panels 13: a start rect far above the caret is not trusted")
        // Claude also reports the composition start at the old (pre-wrap) spot, so the
        // caret is the only signal: on the same y it jumps from near the right back to the
        // left edge. Turning pinyin into characters moves it left too, but not that far.
        let beforeWrap = NSRect(x: 1060, y: 53, width: 1, height: 22)
        let afterWrap = NSRect(x: 470, y: 53, width: 1, height: 22)
        expect(KeyiPanelLayout.isUpwardWrap(previous: beforeWrap, caret: afterWrap, extent: 436...1060),
               "panels 14: a caret jumping back to the left on the same line is a wrap")
        expect(!KeyiPanelLayout.isUpwardWrap(
                   previous: NSRect(x: 620, y: 53, width: 1, height: 22),
                   caret: NSRect(x: 548, y: 53, width: 1, height: 22), extent: 436...620),
               "panels 14: pinyin turning into characters is not a wrap")
        expect(!KeyiPanelLayout.isUpwardWrap(
                   previous: beforeWrap, caret: NSRect(x: 470, y: 31, width: 1, height: 22), extent: 436...1060),
               "panels 14: a caret on a lower line is not an upward wrap")
        expect(!KeyiPanelLayout.isUpwardWrap(
                   previous: beforeWrap, caret: NSRect(x: 700, y: 53, width: 1, height: 22), extent: 436...1060),
               "panels 14: a caret that stays far from the line start is not a wrap")
        let assumedStart = KeyiPanelLayout.wrappedStart(caret: afterWrap, wraps: 1, x: 436)
        let upLines = KeyiPanelLayout.compositionLines(anchor: afterWrap, start: assumedStart, previous: nil)
        let upPanel = NSRect(
            origin: KeyiPanelLayout.panelOrigin(size: previewOnly, anchor: upLines, below: false, x: 424, visible: screen),
            size: previewOnly
        )
        expect(!upPanel.intersects(assumedStart) && !upPanel.intersects(afterWrap),
               "panels 14: after an upward wrap the panel clears the line above (\(upPanel))")
        expect(KeyiPanelLayout.alignmentX(anchor: NSRect(x: 130, y: 53, width: 1, height: 22),
                                          start: NSRect(x: 100, y: 53, width: 1, height: 22)) == 100,
               "panels 15: the panel lines up with the start of the composition on the caret line")
        expect(KeyiPanelLayout.alignmentX(anchor: NSRect(x: 130, y: 53, width: 1, height: 22),
                                          start: NSRect(x: 100, y: 75, width: 1, height: 22)) == 130,
               "panels 15: a start on another line does not move the panel sideways")
        let elsewhere = NSRect(x: 100, y: 500, width: 0, height: 20)
        expect(KeyiPanelLayout.compositionLines(anchor: elsewhere, previous: wrapped) == elsewhere,
               "panels 13: a caret far from the earlier lines starts over")
        // Chrome and Electron report a zero-width caret: it is still the caret, not "no
        // position" (which would place the panel by the mouse, over the line being typed).
        let thinCaret = NSRect(x: 400, y: 30, width: 0, height: 20)
        expect(KeyiPanelLayout.anchor(for: thinCaret) == thinCaret,
               "panels 11: a zero-width caret is used as the anchor")
        expect(!KeyiPanelLayout.isUsableCaret(.zero)
               && !KeyiPanelLayout.isUsableCaret(NSRect(x: CGFloat.nan, y: 0, width: 0, height: 20)),
               "panels 11: a zero or NaN rect is not a caret position")
        expect(KeyiPanelLayout.anchor(for: .zero).height == KeyiPanelLayout.fallbackLineHeight,
               "panels 11: the mouse fallback keeps a line's height clear")
        // Antigravity answers some keys with a caret and others with nothing in the same
        // field; the panel must not jump to the mouse and back while the user types.
        let caret = NSRect(x: 300, y: 400, width: 0, height: 20)
        let lastKnown = NSRect(x: 280, y: 400, width: 0, height: 20)
        expect(KeyiPanelLayout.resolvedCaret(reported: caret, lastKnown: lastKnown) == caret,
               "panels 12: the reported caret wins")
        expect(KeyiPanelLayout.resolvedCaret(reported: .zero, lastKnown: lastKnown) == lastKnown,
               "panels 12: no caret falls back to the last caret, not the mouse")
        expect(KeyiPanelLayout.resolvedCaret(reported: .zero, lastKnown: .zero) == .zero,
               "panels 12: never had a caret: the mouse is the last resort")
        expect(KeyiPanelLayout.caretToKeep(new: .zero, current: caret, isShown: true) == caret,
               "panels 12: a shown panel stays put when a key brings no caret")
        expect(KeyiPanelLayout.caretToKeep(new: lastKnown, current: caret, isShown: true) == lastKnown,
               "panels 12: a shown panel follows a new caret")
        expect(KeyiPanelLayout.caretToKeep(new: .zero, current: caret, isShown: false) == .zero,
               "panels 12: a hidden panel does not reuse an old caret by itself")
    }
    // (20) Dictation: hold right ⌥ to talk (contract 2026-11-07). The microphone and the
    // recognizer are replaced by a fake that reports live and final text.
    @discardableResult
    func dictation(_ command: String) -> String {
        KeyiSessionDiagnostics.fakeTranslation("dictation:" + command, in: session)
    }
    @discardableResult
    func rightOption(_ down: Bool, _ client: KeyiDiagnosticTextClient) -> Bool {
        KeyiSessionDiagnostics.sendFlags(61, modifiers: down ? .option : [], into: session, client: client)
    }
    expect(dictation("install") == "ok", "dictation: fake recognizer installs")
    // The user's own voice key setting must not change these checks: pin right ⌥.
    expect(dictation("key:61:0") == "右 ⌥", "dictation: the voice key is pinned to right ⌥ for the checks")
    c = fresh()
    let startsBefore = Int(dictation("starts")) ?? -1
    expect(!rightOption(true, c) && dictation("phase") == "listening",
           "dictation 1: holding right ⌥ starts listening; the event still reaches the app")
    rightOption(true, c)
    expect(Int(dictation("starts")) == startsBefore + 1, "dictation 1: a repeated press while holding is the same recording")
    expect(KeyiSessionDiagnostics.previewPanelVisible(session), "dictation 1: the panel shows while listening")
    dictation("say:今天")
    expect(c.markedText.isEmpty, "dictation 1: recognized text is not dropped in all at once")
    pump(0.5)
    expect(c.markedText == "今天" && c.committedText.isEmpty, "dictation 1: live text flows into the field as marked text")
    dictation("say:今天下午 开会")
    expect(c.markedText == "今天", "dictation 1: new words wait their turn after what is shown")
    pump(0.3)
    expect(c.markedText.count > 2 && c.markedText.count < 6,
           "dictation 1: new words come out one character at a time")
    pump(1)
    expect(c.markedText == "今天下午开会" && c.committedText.isEmpty,
           "dictation 1: all words come out; spaces next to Chinese are dropped")
    dictation("say:今天下午三点开会")
    expect(c.markedText == "今天下午三点",
           "dictation 1: a revision of shown words replaces them in place at once")
    pump(1)
    expect(c.markedText == "今天下午三点开会", "dictation 1: the rest of the revision flows in")
    dictation("say:今天下午三点在会议室开会")
    dictation("final:今天下午三点在会议室开会。")
    expect(!rightOption(false, c), "dictation 1: the release still reaches the app")
    pump(1)
    expect(dictation("phase") == "idle", "dictation 1: releasing right ⌥ finishes once the last words are out")
    expect(c.markedText == "今天下午三点在会议室开会。" && c.committedText.isEmpty,
           "dictation 1: the final Chinese joins the underlined paragraph")
    // A cloud style stored on this machine waits for the typing pause before previewing.
    pump(1.8)
    expect(KeyiSessionDiagnostics.fakeTranslation("requests", in: session).hasSuffix("今天下午三点在会议室开会。"),
           "dictation 1: the paragraph is previewed like typed Chinese")
    key(36, "\r", c)
    pump()
    expect(c.committedText == "EN(今天下午三点在会议室开会。)" && c.markedText.isEmpty,
           "dictation 1: Enter puts the English in")

    c = fresh()
    holdNihao(c)
    rightOption(true, c)
    dictation("say:我们走吧")
    pump(0.8)
    expect(c.markedText == "你好我们走吧" && c.committedText.isEmpty, "dictation 2: live text follows the held Chinese")
    rightOption(false, c)
    pump()
    expect(c.markedText == "你好我们走吧" && c.committedText.isEmpty, "dictation 2: the speech joins the held paragraph")
    key(53, "\u{1b}", c)
    pump()
    expect(c.committedText == "你好我们走吧" && c.markedText.isEmpty, "dictation 2: Esc keeps typed and spoken Chinese as is")

    c = fresh()
    holdNihao(c)
    rightOption(true, c)
    dictation("say:不要这个")
    key(0, "å", c, .option)
    expect(dictation("phase") == "idle", "dictation 3: a key while holding right ⌥ cancels the recording")
    rightOption(false, c)
    pump()
    expect(!c.markedText.contains("不要这个") && !c.committedText.contains("不要这个"),
           "dictation 3: the cancelled speech is never written")

    c = fresh()
    rightOption(true, c)
    dictation("say:取消")
    KeyiSessionDiagnostics.sendFlags(55, modifiers: [.option, .command], into: session, client: c)
    expect(dictation("phase") == "idle" && c.markedText.isEmpty && c.committedText.isEmpty,
           "dictation 4: another modifier while holding cancels and writes nothing")
    KeyiSessionDiagnostics.sendFlags(55, modifiers: .option, into: session, client: c)
    rightOption(false, c)
    pump()
    expect(c.markedText.isEmpty && c.committedText.isEmpty, "dictation 4: nothing arrives after the release")

    c = fresh()
    holdNihao(c)
    rightOption(true, c)
    dictation("say:点到别处")
    KeyiSessionDiagnostics.commitComposition(session, client: c)
    expect(dictation("phase") == "idle" && !c.committedText.contains("点到别处") && !c.markedText.contains("点到别处"),
           "dictation 5: leaving the field stops listening and drops the speech")
    rightOption(false, c)
    pump()
    expect(!c.committedText.contains("点到别处"), "dictation 5: nothing arrives later")

    c = fresh()
    let startsWithPinyin = Int(dictation("starts")) ?? -1
    type("ni", c)
    rightOption(true, c)
    expect(dictation("phase") == "idle" && Int(dictation("starts")) == startsWithPinyin,
           "dictation 6: no recording while pinyin is being typed")
    rightOption(false, c)
    key(53, "\u{1b}", c)

    KeyiSessionDiagnostics.fakeTranslation("secure:1", in: session)
    c = fresh()
    rightOption(true, c)
    expect(dictation("phase") == "idle", "dictation 7: no recording in a password field")
    rightOption(false, c)
    KeyiSessionDiagnostics.fakeTranslation("secure:0", in: session)

    KeyiSessionDiagnostics.fakeTranslation("auto:0", in: session)
    c = fresh()
    rightOption(true, c)
    dictation("say:直接上屏")
    pump(0.8)
    expect(c.markedText == "直接上屏", "dictation 8: with automatic translation off the live text is still marked")
    rightOption(false, c)
    pump(0.6)
    expect(c.committedText == "直接上屏" && c.markedText.isEmpty,
           "dictation 8: with automatic translation off the Chinese goes straight in")
    KeyiSessionDiagnostics.fakeTranslation("auto:1", in: session)

    c = fresh()
    dictation("hold")
    rightOption(true, c)
    dictation("say:好的")
    rightOption(false, c)
    expect(dictation("phase") == "finishing", "dictation 9: released, waiting for the final text")
    type("a", c)
    expect(c.markedText == "好的a" && dictation("phase") == "idle",
           "dictation 9: a key before the final text keeps everything heard, shown or not, then types")
    dictation("release")
    pump()
    expect(c.markedText == "好的a", "dictation 9: the late final text writes nothing")
    key(53, "\u{1b}", c)
    key(53, "\u{1b}", c)

    c = fresh()
    KeyiSessionDiagnostics.sendFlags(58, modifiers: .option, into: session, client: c)
    expect(dictation("phase") == "idle", "dictation 10: left ⌥ does not record")
    KeyiSessionDiagnostics.sendFlags(58, modifiers: [], into: session, client: c)

    c = fresh()
    rightOption(true, c)
    dictation("say:OK")
    rightOption(false, c)
    pump(0.6)
    expect(c.committedText == "OK" && c.markedText.isEmpty,
           "dictation 11: speech without Chinese goes straight in, like typed letters")

    c = fresh()
    rightOption(true, c)
    dictation("final:")
    rightOption(false, c)
    pump()
    expect(c.markedText.isEmpty && c.committedText.isEmpty && !KeyiSessionDiagnostics.previewPanelVisible(session),
           "dictation 12: hearing nothing writes nothing and the panel goes away")

    // (21) The voice key is the user's own choice (contract 2026-11-08): a single modifier
    // behaves like right ⌥; a key combination or a function key belongs to the input method.
    let keyUpMask = UInt(NSEvent.EventTypeMask.keyUp.rawValue)
    func flags(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags, _ client: KeyiDiagnosticTextClient) {
        KeyiSessionDiagnostics.sendFlags(code, modifiers: modifiers, into: session, client: client)
    }
    @discardableResult
    func keyUp(_ code: UInt16, _ chars: String, _ client: KeyiDiagnosticTextClient,
               _ modifiers: NSEvent.ModifierFlags = []) -> Bool {
        KeyiSessionDiagnostics.sendKey(code, characters: chars, into: session, client: client, modifiers: modifiers, type: .keyUp)
    }
    @discardableResult
    func keyRepeat(_ code: UInt16, _ chars: String, _ client: KeyiDiagnosticTextClient,
                   _ modifiers: NSEvent.ModifierFlags = []) -> Bool {
        KeyiSessionDiagnostics.sendKey(code, characters: chars, into: session, client: client, modifiers: modifiers, isARepeat: true)
    }
    func starts() -> Int { Int(dictation("starts")) ?? -1 }

    expect(dictation("key:54:0") == "右 ⌘", "voice key 1: right ⌘ can be the voice key")
    expect((UInt(dictation("events")) ?? 0) & keyUpMask == 0, "voice key 1: a modifier voice key asks for no keyUp events")
    c = fresh()
    rightOption(true, c)
    expect(dictation("phase") == "idle", "voice key 1: right ⌥ no longer records")
    rightOption(false, c)
    flags(55, .command, c)
    expect(dictation("phase") == "idle", "voice key 1: left ⌘ does not record")
    flags(55, [], c)
    expect(!KeyiSessionDiagnostics.sendFlags(54, modifiers: .command, into: session, client: c)
           && dictation("phase") == "listening",
           "voice key 1: holding right ⌘ records; the press still reaches the app")
    dictation("say:右边命令键")
    flags(54, [], c)
    pump(1)
    expect(dictation("phase") == "idle" && c.markedText == "右边命令键" && c.committedText.isEmpty,
           "voice key 1: releasing right ⌘ finishes; the Chinese joins the paragraph")
    key(53, "\u{1b}", c)

    let ctrlOpt: NSEvent.ModifierFlags = [.control, .option]
    expect(dictation("key:9:\(ctrlOpt.rawValue):v") == "⌃⌥V", "voice key 2: ⌃⌥V can be the voice key")
    expect((UInt(dictation("events")) ?? 0) & keyUpMask != 0, "voice key 2: a key combination asks for keyUp events")
    c = fresh()
    holdNihao(c)
    var before = starts()
    flags(59, .control, c)
    flags(58, ctrlOpt, c)
    expect(key(9, "v", c, ctrlOpt) && dictation("phase") == "listening" && starts() == before + 1,
           "voice key 2: pressing ⌃⌥V starts listening and the key never reaches the app")
    expect(keyRepeat(9, "v", c, ctrlOpt) && starts() == before + 1 && dictation("phase") == "listening",
           "voice key 2: repeats while holding are swallowed and stay the same recording")
    dictation("say:组合键")
    pump(0.8)
    expect(c.markedText == "你好组合键" && c.committedText.isEmpty, "voice key 2: live text follows the held Chinese")
    expect(keyUp(9, "v", c, ctrlOpt), "voice key 2: the release is swallowed too")
    pump()
    expect(dictation("phase") == "idle" && c.markedText == "你好组合键" && c.committedText.isEmpty,
           "voice key 2: releasing V finishes; the speech joins the paragraph")
    flags(58, .control, c)
    flags(59, [], c)
    expect(c.markedText == "你好组合键" && c.committedText.isEmpty,
           "voice key 2: letting go of the modifiers afterwards changes nothing (no Shift tap, no letters)")
    pump(1.8)
    key(36, "\r", c)
    pump(0.5)
    expect(c.committedText == "EN(你好组合键)", "voice key 2: Enter puts the English in as usual")

    c = fresh()
    flags(59, .control, c)
    flags(58, ctrlOpt, c)
    key(9, "v", c, ctrlOpt)
    dictation("say:先松修饰键")
    flags(58, .control, c)
    expect(dictation("phase") != "listening", "voice key 3: letting go of ⌥ while V is still down ends the recording")
    expect(keyRepeat(9, "v", c, .control) && keyUp(9, "v", c, .control),
           "voice key 3: V repeating and released afterwards is swallowed")
    flags(59, [], c)
    pump(1)
    expect(c.markedText == "先松修饰键" && !c.committedText.contains("v") && !c.markedText.contains("v"),
           "voice key 3: the speech is kept and no letter v is typed")
    key(53, "\u{1b}", c)

    c = fresh()
    flags(59, .control, c)
    flags(58, ctrlOpt, c)
    key(9, "v", c, ctrlOpt)
    dictation("say:不要这个")
    flags(55, ctrlOpt.union(.command), c)
    expect(dictation("phase") == "idle", "voice key 4: another modifier while holding ⌃⌥V cancels")
    flags(55, ctrlOpt, c)
    keyUp(9, "v", c, ctrlOpt)
    flags(58, .control, c)
    flags(59, [], c)
    pump()
    expect(!c.markedText.contains("不要这个") && !c.committedText.contains("不要这个"),
           "voice key 4: the cancelled speech is never written")

    c = fresh()
    flags(59, .control, c)
    flags(58, ctrlOpt, c)
    key(9, "v", c, ctrlOpt)
    dictation("say:不要")
    key(0, "a", c, ctrlOpt)
    expect(dictation("phase") == "idle", "voice key 4: another key while holding ⌃⌥V cancels")
    keyUp(9, "v", c, ctrlOpt)
    flags(58, .control, c)
    flags(59, [], c)
    pump()
    expect(!c.markedText.contains("不要") && !c.committedText.contains("不要"),
           "voice key 4: nothing from the cancelled recording arrives")

    c = fresh()
    before = starts()
    expect(!key(9, "v", c, .control) && dictation("phase") == "idle" && starts() == before,
           "voice key 5: ⌃V without ⌥ is an ordinary chord for the app")
    type("ni", c)
    expect(key(9, "v", c, ctrlOpt) && dictation("phase") == "idle" && starts() == before,
           "voice key 5: no recording while pinyin is being typed (the key still stays out of the app)")
    keyUp(9, "v", c, ctrlOpt)
    key(53, "\u{1b}", c)

    // A release that happened in another app never reached us: the next press still starts.
    c = fresh()
    key(9, "v", c, ctrlOpt)
    KeyiSessionDiagnostics.commitComposition(session, client: c)
    c = fresh()
    before = starts()
    expect(key(9, "v", c, ctrlOpt) && dictation("phase") == "listening" && starts() == before + 1,
           "voice key 6: a press after a lost release starts a new recording")
    dictation("final:")
    keyUp(9, "v", c, ctrlOpt)
    pump()

    expect(dictation("key:96:0") == "F5", "voice key 7: F5 alone can be the voice key")
    c = fresh()
    expect(key(96, "\u{F708}", c, .function) && dictation("phase") == "listening",
           "voice key 7: holding F5 (the system adds Fn) records")
    dictation("say:OK")
    expect(keyUp(96, "\u{F708}", c, .function), "voice key 7: releasing F5 is swallowed")
    pump(0.6)
    expect(dictation("phase") == "idle" && c.committedText == "OK" && c.markedText.isEmpty,
           "voice key 7: releasing F5 finishes")

    expect(dictation("key:63:0") == "Fn", "voice key 8: Fn alone can be the voice key")
    c = fresh()
    flags(63, .function, c)
    expect(dictation("phase") == "listening", "voice key 8: holding Fn records")
    dictation("final:")
    flags(63, [], c)
    pump()
    expect(dictation("phase") == "idle", "voice key 8: releasing Fn finishes")
    dictation("key:default")

    if failures.isEmpty {
        print("TRANSLATION SESSION DIAGNOSTICS PASSED")
        exit(EXIT_SUCCESS)
    }
    reportFailure("translation session diagnostics failed: \(failures.joined(separator: ", "))")
}
