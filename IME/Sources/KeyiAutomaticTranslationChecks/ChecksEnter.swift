//
//  ChecksEnter.swift
//  Product 4–5：回车、失败与重试、过期结果。
//

import Foundation
import KEYITranslationClient
import KeyiIMETranslation

/// 行为 4：第一下回车换英文不发送；英文没出来再按回车，中文原样上屏；之后回车交给应用。
func checkEnterConvertsThenPasses() {
    section("4 Enter")
    let h = Harness()
    h.confirm("你好")
    expectEqual(h.press(.enter), .consumed, "4: the first Enter is not passed to the app")
    expectEqual(h.stub.texts, ["你好"], "4: the first Enter requests the whole sentence")
    expect(h.previews.last?.source == "你好" && h.previews.last?.translation == nil, "4: the overlay shows the translating placeholder after Enter")
    h.arrive("Hello")
    expectEqual(h.committed, "Hello", "4: the English is committed when it arrives")
    expect(!h.controller.isHolding, "4: nothing is held afterwards")
    expectEqual(h.previews.last?.source, "", "4: the overlay hides once the sentences are committed")
    expect(h.passedKeys.isEmpty, "4: the first Enter was never passed")
    expectEqual(h.press(.enter), .passOn, "4: the next Enter goes to the app")

    let w = Harness()
    w.confirm("你好")
    w.press(.enter)
    expectEqual(w.press(.enter), .consumed, "4: Enter while the English is not ready is not passed")
    expectEqual(w.committed, "你好", "4: Enter while waiting commits the Chinese as-is")
    expect(w.stub.wasCancelled(0), "4: the abandoned request is cancelled")
    w.stub.deliverLate(.success("Hello"), request: 0)
    drainQueue()
    expectEqual(w.committed, "你好", "4: the late English is dropped")
    expectEqual(w.press(.enter), .passOn, "4: Enter after the Chinese commit goes to the app")

    let s = Harness()
    s.confirm("你好")
    expectEqual(s.press(.enter), .consumed, "4: Shift+Enter behaves as Enter (first press swallowed)")
}

/// 行为 4：按回车后等英文时又打字，取消这次回车，整段回到打字中；新字接在后面，下一次回车整段一起发。
func checkTypingDuringEnterWait() {
    section("4 typing during the Enter wait")
    let h = Harness()
    h.confirm("你好。再见")
    h.press(.enter)
    expectEqual(h.stub.count, 1, "para-e: Enter requests the whole paragraph")
    h.typePinyin("a")
    expect(h.stub.wasCancelled(0), "para-e: typing cancels the Enter request")
    expect(!h.controller.isWaitingAfterEnter, "para-e: the Enter is no longer pending")
    h.stub.deliverLate(.success("Hello. Bye"), request: 0)
    drainQueue()
    expectEqual(h.committed, "", "para-e: the cancelled Enter's late result is dropped")
    expectEqual(h.controller.heldText, "你好。再见", "para-e: the paragraph is back to typing")
    h.confirm("吗")
    expectEqual(h.controller.heldText, "你好。再见吗", "para-e: the new text is appended to the same paragraph")
    expectEqual(h.surface.markedText, "你好。再见吗", "para-e: the whole paragraph is underlined")
    expectEqual(h.press(.enter), .consumed, "para-e: the next Enter counts as the first press again")
    expectEqual(h.stub.count, 2, "para-e: exactly one new request is sent")
    expectEqual(h.stub.texts.last, "你好。再见吗", "para-e: the new request carries the full text")
    h.arrive("Hello. Bye?")
    expectEqual(h.committed, "Hello. Bye?", "para-e: its English is committed once")
    expect(!h.controller.isHolding, "para-e: nothing is held afterwards")
}

/// 行为 5 与 L1：失败后保持下划线并提示；回车把中文原样上屏且不被再次吞掉。
func checkFailureKeepsHeld() {
    section("5 failure (L1)")
    let h = Harness()
    h.confirm("你好")
    h.press(.enter)
    h.fail(TranslationServiceClientError.invalidResponse("bad"))
    expect(h.controller.isHolding && h.committed.isEmpty, "5: a failed sentence stays held and underlined")
    expectEqual(h.failureEvents.last, KeyiAutomaticTranslationFailure(kind: .other, willRetry: false), "5: the failure is reported")
    expectEqual(h.press(.enter), .consumed, "5/L1: Enter after a failure is consumed to commit the Chinese")
    expectEqual(h.committed, "你好", "5/L1: Enter after a failure commits the Chinese as-is")
    expectEqual(h.stub.count, 1, "5/L1: the failure Enter does not request again")
    expectEqual(h.press(.enter), .passOn, "5/L1: the following Enter is not swallowed again")

    let t = Harness()
    t.confirm("你好")
    t.press(.enter)
    t.advance(10.1)
    expectEqual(t.failureEvents.last?.kind, .timedOut, "5: a request that takes 10 s fails as timed out")
    expect(t.controller.isHolding, "5: a timed-out sentence stays held")
    t.arrive("Hello", request: 0)
    expectEqual(t.committed, "", "5: a result after the timeout is dropped")

    // 失败后接着打字：整段回到打字中，新字接在后面，下一次回车整段只发一次。
    let o = Harness()
    o.confirm("你好。")
    o.press(.enter)
    o.fail(StubError())
    o.confirm("再见")
    expect(o.controller.heldText == "你好。再见" && o.committed.isEmpty, "para-c: typing after a failure appends to the failed paragraph")
    expectEqual(o.stub.count, 1, "para-c: typing after a failure sends nothing by itself")
    expectEqual(o.press(.enter), .consumed, "para-c: Enter after more typing is consumed")
    expectEqual(o.stub.count, 2, "para-c: Enter sends exactly one more request")
    expectEqual(o.stub.texts.last, "你好。再见", "para-c: the request carries the full combined text")
    o.arrive("Hello. Bye")
    expectEqual(o.committed, "Hello. Bye", "para-c: the English is committed alone, no leading Chinese")
    expect(!o.controller.isHolding, "para-c: nothing is held afterwards")

    // 失败后没有新字就回车：中文原样上屏。
    let d = Harness()
    d.confirm("你好。再见")
    d.press(.enter)
    d.fail(StubError())
    expectEqual(d.press(.enter), .consumed, "para-d: Enter on a failed paragraph is consumed")
    expectEqual(d.committed, "你好。再见", "para-d: the Chinese is committed unchanged")
    expectEqual(d.stub.count, 1, "para-d: no new request")
    expect(!d.controller.isHolding, "para-d: nothing is held afterwards")
}

/// 行为 5：服务没开时自动重试一次，且只重试一次。
func checkServiceDownRetry() {
    section("5 service-down retry")
    let h = Harness()
    h.confirm("你好")
    h.confirm("。")
    h.press(.enter)
    let down = TranslationServiceClientError.serviceUnavailable("no socket")
    h.fail(down)
    expectEqual(h.failureEvents.last, KeyiAutomaticTranslationFailure(kind: .serviceUnavailable, willRetry: true), "5: first failure announces a retry")
    expectEqual(h.stub.count, 1, "5: the retry waits for the delay")
    h.advance(2.4)
    expectEqual(h.stub.count, 1, "5: no retry before 2.5 s")
    h.advance(0.2)
    expectEqual(h.stub.count, 2, "5: one retry after 2.5 s")
    h.fail(down)
    expectEqual(h.failureEvents.last, KeyiAutomaticTranslationFailure(kind: .serviceUnavailable, willRetry: false), "5: the second failure is final")
    h.advance(10)
    expectEqual(h.stub.count, 2, "5: service-down retries only once")
    expect(h.controller.isHolding, "5: the sentence stays held after the final failure")

    let r = Harness()
    r.confirm("你好")
    r.confirm("。")
    r.press(.enter)
    r.fail(down)
    r.advance(2.6)
    r.arrive("Hello.")
    expectEqual(r.committed, "Hello.", "5: the retry's result is committed")

    let p = Harness()
    p.confirm("你好")
    p.pause()
    p.fail(down)
    expectEqual(p.failureEvents.last, KeyiAutomaticTranslationFailure(kind: .serviceUnavailable, willRetry: false, isPreview: true), "5: a preview failure only asks for a background launch")
    p.advance(5)
    expectEqual(p.stub.count, 1, "5: preview failures are not retried")

    // Feedback decision (pure): a preview failure never shows a toast but still
    // launches the companion when the service is down; a conversion failure shows one.
    let previewDown = KeyiAutomaticTranslationFailure(kind: .serviceUnavailable, willRetry: false, isPreview: true)
    let convertDown = KeyiAutomaticTranslationFailure(kind: .serviceUnavailable, willRetry: true)
    let previewTimeout = KeyiAutomaticTranslationFailure(kind: .timedOut, willRetry: false, isPreview: true)
    expect(!previewDown.showsToast, "5: a preview failure shows no toast")
    expect(previewDown.launchesCompanion, "5: a preview serviceUnavailable still launches the companion")
    expect(convertDown.showsToast && convertDown.launchesCompanion, "5: a conversion serviceUnavailable shows a toast and launches the companion")
    expect(!previewTimeout.showsToast && !previewTimeout.launchesCompanion, "5: a preview timeout does nothing visible")
    expect(KeyiAutomaticTranslationFailure(kind: .timedOut, willRetry: false).showsToast, "5: a conversion timeout shows a toast")
}

/// 统计：译文上屏时记译文词数；回车原样上屏的中文、失败的句子不算。
func checkTranslatedWordCount() {
    section("stats translated words")
    let file = FileManager.default.temporaryDirectory
        .appendingPathComponent("keyi-words-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let stats = KEYIDailyWordStats(fileURL: file, flushDelay: 60)
    let h = Harness()
    h.controller.wordStats = stats
    h.confirm("你好世界")
    h.press(.enter)
    h.arrive("Hello, world")
    let w = Harness()
    w.controller.wordStats = stats
    w.confirm("你好")
    w.press(.enter)
    w.press(.enter)
    stats.flush()
    let today = KEYIDailyWordStats.load(from: file)[KEYIDailyWordStats.dayKey(for: Date())]
    expectEqual(today?.translatedWords, 2, "stats: only the committed translation counts its words")
    expectEqual(today?.hanzi, 0, "stats: the controller does not count Hanzi (the session counts confirmed commits)")
    expectEqual(KEYIDailyWordStats.hanziCount(in: "你好，KEYI 世界😀"), 4, "stats: Hanzi count ignores punctuation, Latin and emoji")
    expectEqual(KEYIDailyWordStats.wordCount(in: "It's a nice day."), 4, "stats: English words split on spaces")
}
