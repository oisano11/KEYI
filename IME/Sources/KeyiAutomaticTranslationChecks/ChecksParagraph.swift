//
//  ChecksParagraph.swift
//  段落暂存：。？！?! 只是普通文字，整段留在下划线里；只有回车把整段作为一次请求。
//

import Foundation
import KEYITranslationClient
import KeyiIMETranslation

private let paragraph = "你好。今天天气很好？明天见！ok!"

/// 带停顿地打出整段（含 。？！ 和英文 ok!），返回会话。
private func typeParagraphWithPauses(_ h: Harness) {
    h.confirm("你好。")
    h.pause()
    h.confirm("今天天气很好？")
    h.pause()
    h.confirm("明天见！")
    h.pause()
    h.typePinyin("ok")
    h.enterWithPinyin()
    h.confirm("!")
    h.pause()
}

func checkParagraphHold() {
    section("para: the whole paragraph is held")

    // (a) 带停顿地打字：只有预览请求，不转换，不上屏，整段仍是一个下划线文本。
    let h = Harness()
    typeParagraphWithPauses(h)
    let prefixes = ["你好。", "你好。今天天气很好？", "你好。今天天气很好？明天见！", paragraph]
    expectEqual(h.stub.texts, prefixes, "para-a: pauses send only preview requests, each for the whole text held so far")
    expect(!h.previews.contains { $0.translation == nil && !$0.source.isEmpty }, "para-a: no conversion (translating placeholder) was started")
    expect(!h.controller.isWaitingAfterEnter, "para-a: no Enter is pending")
    expectEqual(h.committed, "", "para-a: nothing is committed")
    expectEqual(h.controller.heldText, paragraph, "para-a: everything stays held as one text")
    expectEqual(h.surface.markedText, paragraph, "para-a: the whole paragraph is the marked text")
    expectEqual(h.passedKeys.count, 0, "para-a: no key was passed to the app")

    // 预览结果只进浮层与缓存。
    h.arrive("Hello. The weather is nice today? See you tomorrow! ok!")
    expectEqual(h.committed, "", "para-a: the preview result is not committed")
    expectEqual(h.controller.heldText, paragraph, "para-a: the preview result leaves the held text unchanged")

    // (b) 回车：整段一次请求，英文只上屏一次，回车被吞掉。
    let b = Harness()
    typeParagraphWithPauses(b)
    let previewCount = b.stub.count
    expectEqual(b.press(.enter), .consumed, "para-b: Enter is consumed")
    expectEqual(b.stub.count, previewCount + 1, "para-b: Enter sends exactly one conversion request")
    expectEqual(b.stub.texts.last, paragraph, "para-b: the request text is the whole paragraph")
    expect(b.previews.last?.source == paragraph && b.previews.last?.translation == nil, "para-b: the overlay shows the translating placeholder for the whole paragraph")
    expectEqual(b.committed, "", "para-b: nothing is committed before the English arrives")
    b.arrive("Hello. The weather is nice today? See you tomorrow! ok!")
    expectEqual(b.committed, "Hello. The weather is nice today? See you tomorrow! ok!", "para-b: the English is committed once")
    expectEqual(b.surface.replacements.filter { !$0.text.isEmpty }.count, 1, "para-b: exactly one write reached the app")
    expect(!b.controller.isHolding && b.surface.markedText.isEmpty, "para-b: nothing stays held")
    expect(b.passedKeys.isEmpty, "para-b: the Enter was never passed to the app")
    expectEqual(b.press(.enter), .passOn, "para-b: the next Enter goes to the app")

    // (f) 整段的预览已缓存：回车直接用，不再请求。
    let f = Harness()
    f.confirm(paragraph)
    f.pause()
    expectEqual(f.stub.texts, [paragraph], "para-f: the pause previews the whole paragraph")
    f.arrive("Cached English")
    expectEqual(f.committed, "", "para-f: the preview did not commit")
    expectEqual(f.press(.enter), .consumed, "para-f: Enter is consumed")
    expectEqual(f.stub.count, 1, "para-f: Enter reuses the cached preview, no new request")
    expectEqual(f.committed, "Cached English", "para-f: Enter commits the cached English")
    expect(!f.controller.isHolding, "para-f: nothing is held afterwards")

    // 预览之后又改了字：缓存不匹配，回车发新请求。
    let g = Harness()
    g.confirm("你好。")
    g.pause()
    g.arrive("Hello.")
    g.confirm("再见")
    g.press(.enter)
    expectEqual(g.stub.texts, ["你好。", "你好。再见"], "para-f: a changed text does not use the old cache")
}

/// 浮层提示必须说此刻回车会做什么：预览成功后改了字再回车、转换失败时，
/// 回车保留中文，提示不能还写着「回车 换英文」（10-31 复审 rc_de0645d6）。
func checkParagraphHintAfterFailure() {
    section("para: the overlay hint follows what Enter will do")

    let h = Harness()
    h.confirm("你好")
    h.pause()
    h.arrive("Hello")
    expectEqual(h.previews.last?.hint, .enterConverts, "para-h: a preview says Enter converts")
    h.confirm("再见")
    expectEqual(h.press(.enter), .consumed, "para-h: Enter converts the edited paragraph")
    expectEqual(h.previews.last?.hint, .waiting, "para-h: while waiting the hint says Enter keeps the Chinese")
    h.fail()
    let last = h.previews.last
    expectEqual(last?.source, "你好再见", "para-h: after the failure the overlay shows the held paragraph")
    expect(last?.translation == nil, "para-h: the old preview English is not shown again")
    expect(last?.hint.isFailed == true, "para-h: the hint says Enter keeps the Chinese")
    expectEqual(h.committed, "", "para-h: nothing is committed by the failure")
    expectEqual(h.controller.heldText, "你好再见", "para-h: the paragraph stays held")

    // 接着打字：失败提示收回，回车又会整段翻译。
    h.confirm("吧")
    expectEqual(h.previews.last?.hint, .enterConverts, "para-h: typing again drops the failed hint")
    expect(h.previews.last?.translation != nil, "para-h: the overlay goes back to the last preview pair")
    expectEqual(h.press(.enter), .consumed, "para-h: Enter converts again")
    expectEqual(h.stub.texts.last, "你好再见吧", "para-h: the whole paragraph is requested once more")

    // 失败后直接回车：中文原样上屏，下一下回车交给应用。
    let k = Harness()
    k.confirm("你好")
    k.press(.enter)
    k.fail()
    expect(k.previews.last?.hint.isFailed == true, "para-k: a failure with no earlier preview also shows the failed hint")
    expectEqual(k.press(.enter), .consumed, "para-k: Enter after the failure commits the Chinese")
    expectEqual(k.committed, "你好", "para-k: the Chinese is committed as typed")
    expect(k.previews.last?.source.isEmpty == true, "para-k: the overlay hides once nothing is held")
    expectEqual(k.press(.enter), .passOn, "para-k: the next Enter goes to the app")

    // 失败后退格：也收回失败提示。
    let d = Harness()
    d.confirm("你好")
    d.press(.enter)
    d.fail()
    expectEqual(d.press(.backspace), .consumed, "para-d2: Backspace edits the failed paragraph")
    expect(d.previews.last?.hint.isFailed != true, "para-d2: editing drops the failed hint")
}
