//
//  ChecksLeaving.swift
//  点到别处、失焦、换输入框：浮层里已有整段英文就上屏英文，否则上屏中文；都不再等结果。
//

import Foundation
import KEYITranslationClient
import KeyiIMETranslation

/// 停手后预览到了：浮层上是这一整段的英文。
private func previewed(_ text: String, _ english: String) -> Harness {
    let h = Harness()
    h.confirm(text)
    h.pause()
    h.arrive(english)
    return h
}

func checkLeavingCommitsReadyEnglish() {
    section("leave: ready English is committed, otherwise Chinese")

    let ready = previewed("你好。今天见", "Hello. See you today")
    ready.commitComposition()
    expectEqual(ready.committed, "Hello. See you today", "leave-a: click-away commits the overlay's English")
    expect(!ready.controller.isHolding && ready.surface.markedText.isEmpty, "leave-a: nothing stays held")
    expectEqual(ready.stub.count, 1, "leave-a: no new request is sent")
    expect(ready.previews.last?.source == "", "leave-a: the overlay is hidden")

    let early = Harness()
    early.confirm("你好")
    early.pause()
    expectEqual(early.stub.count, 1, "leave-b: a preview request is in flight")
    early.commitComposition()
    expectEqual(early.committed, "你好", "leave-b: English not arrived yet → Chinese")
    expect(early.stub.wasCancelled(0), "leave-b: the preview request is cancelled")
    early.arrive("Hello", request: 0)
    expectEqual(early.committed, "你好", "leave-b: the late preview writes nothing")

    let edited = previewed("你好", "Hello")
    edited.confirm("吗")
    edited.commitComposition()
    expectEqual(edited.committed, "你好吗", "leave-c: edited after the preview → Chinese")

    let back = previewed("你好", "Hello")
    back.confirm("吗")
    back.press(.backspace)
    back.commitComposition()
    expectEqual(back.committed, "Hello", "leave-d: edited back to the previewed paragraph → its English")

    let cachedOnly = previewed("你好", "Hello")
    cachedOnly.confirm("吗")
    cachedOnly.commitComposition()
    cachedOnly.confirm("你好")
    expectEqual(cachedOnly.committed, "你好吗", "leave-m: setup commits the edited paragraph as Chinese")
    cachedOnly.commitComposition()
    expectEqual(cachedOnly.committed, "你好吗你好", "leave-m: a cached English the overlay is not showing → Chinese")

    let pinyin = previewed("你好", "Hello")
    pinyin.typePinyin("ma")
    pinyin.commitComposition()
    expectEqual(pinyin.committed, "你好ma", "leave-e: pinyin in progress → Chinese + the pinyin letters")

    let waiting = Harness()
    waiting.confirm("你好")
    waiting.press(.enter)
    expect(waiting.controller.isWaitingAfterEnter, "leave-f: Enter is waiting for English")
    waiting.commitComposition()
    expectEqual(waiting.committed, "你好", "leave-f: English not arrived after Enter → Chinese")
    expect(waiting.stub.wasCancelled(0), "leave-f: the Enter request is cancelled")
    expect(!waiting.controller.isWaitingAfterEnter, "leave-f: the Enter is no longer pending")
    waiting.arrive("Hello", request: 0)
    expectEqual(waiting.committed, "你好", "leave-f: the late result writes nothing")
    expectEqual(waiting.press(.enter), .passOn, "leave-f: the next Enter goes to the app")

    let failed = Harness()
    failed.confirm("你好")
    failed.press(.enter)
    failed.fail()
    failed.commitComposition()
    expectEqual(failed.committed, "你好", "leave-g: a failed paragraph → Chinese")

    let secure = previewed("你好", "Hello")
    secure.surface.secure = true
    secure.commitComposition()
    expectEqual(secure.committed, "你好", "leave-h: secure input on → Chinese")

    let spaced = Harness()
    spaced.surface.committed = "Hi."
    spaced.confirm("你好")
    spaced.pause()
    spaced.arrive("Hello")
    spaced.commitComposition()
    expectEqual(spaced.committed, "Hi. Hello", "leave-i: the usual spacing rule applies")

    let after = previewed("你好", "Hello")
    after.commitComposition()
    after.confirm("再见")
    expectEqual(after.surface.markedText, "再见", "leave-j: the next paragraph starts fresh")
    after.commitComposition()
    expectEqual(after.committed, "Hello再见", "leave-j: the old preview does not apply to the next paragraph")

    let esc = previewed("你好", "Hello")
    expectEqual(esc.press(.escape), .consumed, "leave-k: Esc (and the Shift tap) is consumed")
    expectEqual(esc.committed, "你好", "leave-k: Esc keeps Chinese even with English ready")

    let chord = previewed("你好", "Hello")
    chord.press(.chord)
    expectEqual(chord.committed, "你好", "leave-l: a chord keeps Chinese even with English ready")
}
