//
//  ChecksInvariants.swift
//  上屏顺序、过期结果、归属校验、8 KiB、空格、缓存、无汉字句子。
//

import Foundation
import KEYITranslationClient
import KeyiIMETranslation

func checkCommitOrderAndStaleResults() {
    section("order / stale")
    let h = Harness()
    h.confirm("你好")
    h.confirm("。")
    h.confirm("再见")
    h.confirm("。")
    h.pause()
    expectEqual(h.stub.count, 1, "order: only the pause preview is sent for the whole paragraph")
    h.arrive("Hello. Bye.")
    expectEqual(h.committed, "", "order: a preview result never commits")
    expectEqual(h.surface.markedText, "你好。再见。", "order: the whole paragraph stays underlined")
    h.press(.enter)
    expectEqual(h.stub.count, 1, "order: Enter reuses the cached preview")
    expectEqual(h.committed, "Hello. Bye.", "order: the paragraph commits as one English text")
    expect(!h.controller.isHolding, "order: nothing is held afterwards")

    let s = Harness()
    s.confirm("你好")
    s.confirm("。")
    s.press(.enter)
    s.press(.backspace)
    expect(s.stub.wasCancelled(0), "stale: backspacing into a waiting paragraph cancels its request")
    s.stub.deliverLate(.success("Hello."), request: 0)
    drainQueue()
    expectEqual(s.committed, "", "stale: the late result of an edited paragraph is dropped")
    expectEqual(s.controller.heldText, "你好", "stale: the paragraph is back to typing")
    s.confirm("。")
    s.press(.enter)
    s.arrive("Hi.", request: 1)
    expectEqual(s.committed, "Hi.", "stale: only the new request's result is used")
}

func checkOwnershipMismatch() {
    section("ownership")
    let h = Harness()
    h.confirm("你好")
    h.confirm("。")
    h.press(.enter)
    h.surface.markedRangeOverride = NSRange(location: 0, length: 1)
    h.arrive("Hello.")
    expect(h.surface.replacements.isEmpty, "ownership: a mismatching marked range writes nothing")
    expectEqual(h.abandonCount, 1, "ownership: the session is told to abandon")
    expect(!h.controller.isHolding, "ownership: the held paragraph is dropped")

    let ok = Harness()
    ok.confirm("你好")
    ok.confirm("。")
    ok.press(.enter)
    ok.arrive("Hello.")
    expectEqual(ok.committed, "Hello.", "ownership: a matching marked range commits")

    let moved = Harness()
    moved.confirm("你好")
    moved.confirm("。")
    moved.press(.enter)
    moved.controller.setActiveClient(StubSurface())
    moved.arrive("Hello.")
    expect(moved.surface.replacements.isEmpty && moved.abandonCount == 1, "ownership: switching the text field drops the paragraph without writing")

    let session = Harness()
    session.confirm("你好")
    session.confirm("。")
    session.press(.enter)
    session.controller.setSession(KeyiTranslationSession(id: 9, appIdentifier: "com.example.host"))
    session.arrive("Hello.")
    expect(session.surface.replacements.isEmpty && session.abandonCount == 1, "ownership: a new session drops the paragraph without writing")
}

func checkLimitsSpacingAndCache() {
    section("limit / spacing / cache / no Han")
    let big = Harness()
    big.confirm(String(repeating: "你", count: 3000))
    big.pause()
    expectEqual(big.press(.enter), .consumed, "limit: Enter on an over-limit sentence is consumed")
    expectEqual(big.stub.count, 0, "limit: text over 8 KiB sends no request")
    expectEqual(big.committed, String(repeating: "你", count: 3000), "limit: Enter commits it as Chinese")
    expectEqual(big.press(.enter), .passOn, "limit: the next Enter goes to the app")

    let sp = Harness()
    sp.confirm("你好。")
    sp.press(.enter)
    sp.arrive("Hello.")
    sp.confirm("再见。")
    sp.press(.enter)
    sp.arrive("Bye.")
    expectEqual(sp.committed, "Hello. Bye.", "spacing: a space separates two English paragraphs")
    let zh = Harness()
    zh.surface.committed = "你好"
    zh.confirm("再见")
    zh.press(.enter)
    zh.arrive("Bye")
    expectEqual(zh.committed, "你好Bye", "spacing: no space after Chinese")
    let un = Harness()
    un.surface.textIsUnreadable = true
    un.confirm("你好")
    un.confirm("。")
    un.press(.enter)
    un.arrive("Hello.")
    un.confirm("再见")
    un.press(.enter)
    un.arrive("Bye")
    expectEqual(un.committed, "Hello. Bye", "spacing: an unreadable app uses the last text we committed")

    let cache = Harness()
    cache.confirm("你好")
    cache.pause()
    cache.arrive("Hello")
    cache.press(.enter)
    expectEqual(cache.stub.count, 1, "cache: Enter reuses the preview, no new request")
    expectEqual(cache.committed, "Hello", "cache: Enter commits the cached English at once")

    let nh = Harness()
    nh.confirm("你好")
    nh.confirm("。")
    nh.press(.enter)
    nh.arrive("Hello.")
    expect(!nh.controller.isHolding, "no Han: nothing is held after the paragraph is converted")
    nh.confirm(" ")
    nh.confirm("abc")
    nh.confirm("。")
    expectEqual(nh.committed, "Hello. abc。", "no Han: non-Han text after English commits directly")
    expectEqual(nh.stub.count, 1, "no Han: it sends no request")

    let key = Harness()
    key.confirm("你好")
    expectEqual(key.press(.chord), .passOn, "chord: other ⌘/⌃/⌥ keys commit Chinese and pass on")
}

func checkCommandEnterSwallowed() {
    section("⌘↩ / ⌃↩ / ⌥↩")
    // 会话把这些键按 .enter 交给控制器；第一下不交给应用。
    let h = Harness()
    h.confirm("你好")
    let first = h.press(.enter)
    expectEqual(first, .consumed, "⌘↩: the first press is swallowed like Enter")
    expect(h.passedKeys.isEmpty, "⌘↩: nothing reaches the app on the first press")
    h.arrive("Hello")
    expectEqual(h.press(.enter), .passOn, "⌘↩: after the English is committed, the key reaches the app")
}
