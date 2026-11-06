//
//  ChecksTyping.swift
//  Product 0–3：拼音中回车、暂存、预览、数字英文并入、句末标点。
//

import Foundation
import KEYITranslationClient
import KeyiIMETranslation

/// 行为 0：拼音中回车只把字母放进句子；带下划线时 Tab、Home、End 和方向键不起作用。
func checkPinyinEnterAndNavigation() {
    section("0 pinyin enter / navigation keys")
    let h = Harness()
    h.confirm("我想买")
    h.typePinyin("ok")
    h.enterWithPinyin()
    expectEqual(h.controller.heldText, "我想买ok", "0: Enter while typing pinyin puts the letters into the sentence")
    expectEqual(h.committed, "", "0: Enter while typing pinyin commits nothing to the app")
    expectEqual(h.stub.count, 0, "0: Enter while typing pinyin requests no translation")
    h.typePinyin("ni")
    expectEqual(h.visible, "我想买okni", "0: marked text is the held sentence plus the pinyin being typed")
    h.typePinyin("")
    expectEqual(h.press(.navigation), .consumed, "0: arrow/Tab/Home/End/PageUp/PageDown/forward-delete do nothing while held")
    expectEqual(h.controller.heldText, "我想买ok", "0: navigation keys leave the held sentence unchanged")
    expect(h.passedKeys.isEmpty && h.committed.isEmpty, "0: navigation keys are not passed to the app")
}

/// 行为 1：确认的汉字留在下划线句里，停手后只更新浮层预览，打字时不显示“翻译中…”。
func checkHoldAndPreview() {
    section("1 hold + preview")
    let h = Harness()
    h.confirm("你好")
    expectEqual(h.committed, "", "1: confirmed Chinese is not committed to the app")
    expectEqual(h.surface.markedText, "你好", "1: confirmed Chinese is shown as marked text")
    expect(h.controller.isHolding, "1: controller reports a held sentence")
    expectEqual(h.stub.count, 0, "1: confirming does not request anything immediately")
    expect(!h.previews.contains { $0.translation == nil && !$0.source.isEmpty }, "1: typing never shows the translating placeholder")
    let quiet = h.controller.currentQuietPeriodForDiagnostics
    h.clock.advance(quiet - 0.01)
    drainQueue()
    expectEqual(h.stub.count, 0, "1: just under the quiet period sends no preview request")
    h.clock.advance(0.02)
    drainQueue()
    expectEqual(h.stub.count, 1, "1: the quiet period sends one preview request")
    h.arrive("Hello")
    expect(h.previews.last?.source == "你好" && h.previews.last?.translation == "Hello", "1: the preview result goes only to the overlay")
    expectEqual(h.committed, "", "1: a pause never commits English")
    expectEqual(h.surface.markedText, "你好", "1: a pause leaves the marked Chinese unchanged")
}

/// 行为 1：再打字取消预览；拼音中不预览；超长文字不预览。
func checkPreviewCancelledByTyping() {
    section("1 preview cancelled by typing")
    let h = Harness()
    h.confirm("你")
    h.pause()
    expectEqual(h.stub.count, 1, "1: preview of the first character is requested")
    h.confirm("好")
    expect(h.stub.wasCancelled(0), "1: more typing cancels the in-flight preview")
    h.stub.deliverLate(.success("Hi"), request: 0)
    drainQueue()
    expect(h.previews.last?.translation != "Hi", "1: a cancelled preview result is not shown")
    let quiet = h.controller.currentQuietPeriodForDiagnostics
    h.clock.advance(quiet * 0.7)
    h.confirm("吗")
    h.clock.advance(quiet * 0.7)
    drainQueue()
    expectEqual(h.stub.count, 1, "1: typing restarts the quiet timer")
    h.typePinyin("ni")
    h.pause()
    expectEqual(h.stub.count, 1, "1: no preview request while pinyin is being typed")
}

/// 行为 1b（2026-11-05）：本机风格确认候选即发预览、不等停手；打拼音不打断在途的预览，
/// 整段变了才取消旧的；回车时在途的同段预览直接拿来上屏；大模型风格仍等停手；节奏存在本机。
func checkLocalStylePreviewsImmediately() {
    section("1b local styles preview at once")
    let h = Harness(waitsForPause: false)
    h.confirm("你")
    h.settle()
    expectEqual(h.stub.texts, ["你"], "1b: confirming sends the preview at once, no pause needed")
    h.typePinyin("h")
    h.typePinyin("hao")
    expect(!h.stub.wasCancelled(0), "1b: typing pinyin does not cancel the in-flight preview")
    h.arrive("You", request: 0)
    expect(h.previews.last?.source == "你" && h.previews.last?.translation == "You", "1b: the preview shows while pinyin is being typed")
    expectEqual(h.stub.count, 1, "1b: pinyin letters send no request")
    h.confirm("好")
    h.settle()
    expectEqual(h.stub.texts, ["你", "你好"], "1b: the next confirmation previews the whole sentence at once")
    h.confirm("吗")
    expect(h.stub.wasCancelled(1), "1b: a changed sentence cancels the older in-flight preview")
    h.settle()
    expectEqual(h.stub.texts.last, "你好吗", "1b: the changed sentence is previewed at once")
    h.press(.enter)
    expect(!h.stub.wasCancelled(2), "1b: Enter keeps the in-flight preview of the same sentence")
    h.arrive("How are you?", request: 2)
    expectEqual(h.committed, "How are you?", "1b: Enter commits the preview's result as soon as it arrives")
    expect(h.stub.count == 4 && h.stub.wasCancelled(3), "1b: the Enter request for the same text is cancelled")
    expect(!h.controller.isHolding, "1b: nothing is left held")

    let b = Harness(waitsForPause: false)
    b.confirm("你好")
    b.settle()
    b.arrive("Hello")
    b.confirm("吗")
    b.settle()
    b.arrive("How are you?")
    b.press(.backspace)
    b.settle()
    expectEqual(b.stub.count, 2, "1b: backspacing back to a cached sentence sends no request")
    expectEqual(b.previews.last?.translation, "Hello", "1b: the cached preview shows at once")

    let api = Harness(waitsForPause: true)
    api.confirm("你好")
    api.settle()
    expectEqual(api.stub.count, 0, "1b: API styles still wait for a pause")
    api.pause()
    expectEqual(api.stub.count, 1, "1b: API styles preview after the pause")

    expectEqual(KeyiTypingRhythm().quietPeriod, 0.8, "1b: the wait before any rhythm is learned is 0.8 s")
    let suite = "com.keyi.checks.rhythm.\(UUID().uuidString)"
    if let defaults = UserDefaults(suiteName: suite) {
        let first = KeyiTypingRhythm(storage: defaults)
        for gap in [0.2, 0.25, 0.2, 0.3] { first.record(idleGap: gap) }
        let second = KeyiTypingRhythm(storage: defaults)
        expectEqual(second.sampleCount, 4, "1b: the learned rhythm survives a restart")
        expectEqual(second.quietPeriod, first.quietPeriod, "1b: the restarted rhythm keeps the learned wait")
        defaults.removePersistentDomain(forName: suite)
    } else {
        expect(false, "1b: could not open a scratch preferences suite")
    }
}

/// 行为 2：数字、空格、英文并入这一句；没有暂存时英文和数字直接上屏。（L2）
func checkDigitsAndEnglishJoin() {
    section("2 digits / spaces / English join the sentence (L2)")
    let h = Harness()
    h.confirm("我想买")
    h.confirm("3")
    h.confirm("个苹果")
    h.confirm(" ")
    h.typePinyin("ok")
    h.enterWithPinyin()
    h.confirm("。")
    expectEqual(h.stub.count, 0, "2/L2: 。 alone starts no request")
    h.press(.enter)
    expectEqual(h.stub.texts, ["我想买3个苹果 ok。"], "2/L2: Chinese, digits, spaces and English are translated as one paragraph")
    h.arrive("I want to buy 3 apples ok.")
    expectEqual(h.committed, "I want to buy 3 apples ok.", "2/L2: nothing is dropped; the whole sentence becomes English")

    let plain = Harness()
    plain.confirm("3")
    plain.confirm("abc")
    expectEqual(plain.committed, "3abc", "2: with nothing held, digits and English go straight to the app")
    expectEqual(plain.stub.count, 0, "2: with nothing held, digits and English are not translated")
    plain.confirm("3你好")
    expectEqual(plain.committed, "3abc3", "2: text before the first Han character goes straight to the app")
    expectEqual(plain.controller.heldText, "你好", "2: the Han part starts the held sentence")
}

/// 行为 3（段落暂存）：。？！?! 和 . ; … ， 一样只是普通文字，整段留在下划线里；只有回车开始转换。
func checkSentenceTerminators() {
    section("3 terminators are ordinary characters")
    for mark in ["。", "？", "！", "?", "!", ".", ";", "…", "，"] {
        let t = Harness()
        t.confirm("好")
        t.confirm(mark)
        expectEqual(t.stub.count, 0, "3: \(mark) starts no request")
        expectEqual(t.surface.markedText, "好" + mark, "3: \(mark) stays in the held paragraph")
        expectEqual(t.committed, "", "3: \(mark) commits nothing")
        t.confirm("再见")
        expectEqual(t.controller.heldText, "好" + mark + "再见", "3: text after \(mark) joins the same paragraph")
        t.press(.enter)
        expectEqual(t.stub.texts, ["好" + mark + "再见"], "3: Enter sends the whole paragraph including \(mark)")
    }
}
