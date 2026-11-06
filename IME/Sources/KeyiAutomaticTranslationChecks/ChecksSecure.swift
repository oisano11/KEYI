//
//  ChecksSecure.swift
//  行为 8 补充：句子暂存期间 Secure Keyboard Entry 才打开（系统级，客户端无变化）。
//  之后不得再有任何文字送去翻译，迟到的结果不得写入，暂存的中文原样上屏。
//

import Foundation
import KEYITranslationClient

private func noEnglishShown(_ h: Harness) -> Bool {
    !h.previews.contains { $0.translation != nil && !$0.source.isEmpty && $0.translation != "" }
}

private func overlayHidden(_ h: Harness) -> Bool {
    guard let last = h.previews.last else { return true }
    return last.source.isEmpty
}

func checkSecureInputTurnsOnWhileHeld() {
    section("8 secure input turns on while a sentence is held")

    // (a) 预览计时器触发之前。
    let a = Harness()
    a.confirm("你好")
    a.surface.secure = true
    a.pause()
    expectEqual(a.stub.count, 0, "8s-a: no preview request after secure input turned on")
    expectEqual(a.committed, "你好", "8s-a: held Chinese is committed as-is")
    expect(!a.controller.isHolding, "8s-a: nothing is held afterwards")
    expect(overlayHidden(a), "8s-a: overlay is hidden")
    a.advance(20)
    expectEqual(a.stub.count, 0, "8s-a: still no request later")
    expectEqual(a.visible, "你好", "8s-a: text is not lost or duplicated")

    // (a2) 浮层已显示旧预览时，也要收起。
    let a2 = Harness()
    a2.confirm("你好")
    a2.pause()
    a2.arrive("Hello")
    expect(!overlayHidden(a2), "8s-a2: setup shows a preview")
    a2.confirm("吗")
    a2.surface.secure = true
    a2.pause()
    expectEqual(a2.stub.count, 1, "8s-a2: no second request")
    expectEqual(a2.committed, "你好吗", "8s-a2: held Chinese is committed as-is")
    expect(overlayHidden(a2), "8s-a2: overlay is hidden")

    // (b) 接着按回车。
    let b = Harness()
    b.confirm("你好")
    b.surface.secure = true
    let enter = b.press(.enter)
    expectEqual(b.stub.count, 0, "8s-b: Enter sends no request")
    expectEqual(b.committed, "你好", "8s-b: Enter commits the Chinese unchanged")
    expect(!b.controller.isHolding && !b.controller.isWaitingAfterEnter, "8s-b: nothing held or pending")
    expectEqual(enter, .consumed, "8s-b: the Enter that settles the held text is not sent to the app")
    expect(overlayHidden(b), "8s-b: overlay is hidden")
    expectEqual(b.press(.enter), .passOn, "8s-b: the next Enter goes to the app (nothing held)")
    expectEqual(b.stub.count, 0, "8s-b: still no request")
    expectEqual(b.visible, "你好", "8s-b: text is not lost or duplicated")

    // (b2) 已按过回车、等译文时打开。
    let b2 = Harness()
    b2.confirm("你好")
    b2.press(.enter)
    expectEqual(b2.stub.count, 1, "8s-b2: setup sent the Enter conversion")
    b2.surface.secure = true
    b2.arrive("Hello")
    expectEqual(b2.committed, "你好", "8s-b2: Enter result is dropped, Chinese committed")

    // (c) 2.5 秒重试窗口里。
    let c = Harness()
    c.confirm("你好")
    c.confirm("。")
    c.press(.enter)
    c.fail(TranslationServiceClientError.serviceUnavailable("no socket"))
    expectEqual(c.stub.count, 1, "8s-c: setup waits for the retry")
    c.surface.secure = true
    c.advance(3)
    expectEqual(c.stub.count, 1, "8s-c: the retry sends nothing")
    expectEqual(c.committed, "你好。", "8s-c: held Chinese is committed as-is")
    expect(!c.controller.isHolding, "8s-c: nothing is held afterwards")
    c.advance(20)
    expectEqual(c.stub.count, 1, "8s-c: no request later")
    expectEqual(c.visible, "你好。", "8s-c: text is not lost or duplicated")

    // (d) 转换请求在途。
    let d = Harness()
    d.confirm("你好")
    d.confirm("。")
    d.press(.enter)
    expectEqual(d.stub.count, 1, "8s-d: setup has a conversion in flight")
    d.surface.secure = true
    d.arrive("Hello.")
    expectEqual(d.committed, "你好。", "8s-d: the late result is dropped, Chinese committed")
    expect(!d.visible.contains("Hello"), "8s-d: no English written")
    expect(!d.controller.isHolding, "8s-d: nothing is held afterwards")
    expectEqual(d.stub.count, 1, "8s-d: no new request")
    d.press(.backspace)
    expectEqual(d.passedKeys.last, .backspace, "8s-d: Backspace is not an English undo")

    // (e) 预览请求在途。
    let e = Harness()
    e.confirm("你好")
    e.pause()
    expectEqual(e.stub.count, 1, "8s-e: setup has a preview in flight")
    e.surface.secure = true
    e.arrive("Hello")
    expect(noEnglishShown(e), "8s-e: the preview result is not shown")
    expect(overlayHidden(e), "8s-e: overlay is hidden")
    expectEqual(e.committed, "你好", "8s-e: held Chinese is committed as-is")
    expect(!e.visible.contains("Hello"), "8s-e: no English written")

    // 当前拼音不受影响，继续按普通拼音输入。
    let p = Harness()
    p.confirm("你好")
    p.surface.secure = true
    p.typePinyin("ni")
    p.pause()
    expectEqual(p.stub.count, 0, "8s-p: no request while pinyin is typed")
    p.confirm("你")
    expectEqual(p.committed, "你好你", "8s-p: later Chinese commits straight to the app")
}

func checkSecureInputOtherKeysWhileHeld() {
    section("8 secure input turns on: other keys")
    let b = Harness()
    b.confirm("你好")
    b.surface.secure = true
    expectEqual(b.press(.backspace), .passOn, "8s-k: Backspace goes to the app after the Chinese is settled")
    expectEqual(b.committed, "你好", "8s-k: held Chinese committed unchanged")
    expectEqual(b.stub.count, 0, "8s-k: no request")

    let e = Harness()
    e.confirm("你好")
    e.surface.secure = true
    expectEqual(e.press(.escape), .consumed, "8s-k: Esc settles the held Chinese and is consumed")
    expectEqual(e.committed, "你好", "8s-k: Esc commits the Chinese unchanged")
}

/// 安全输入在按键之外（计时器、迟到结果、重试）才被发现时，写中文前也要先确认标记文字还归我们；
/// 应用已改了标记范围就什么都不写，只放弃暂存，避免重复或覆盖别人的标记文字。
func checkSecureInputRespectsOwnership() {
    section("8 secure input settles only text it still owns")
    let taken = NSRange(location: 0, length: 1)

    func expectAbandoned(_ h: Harness, _ label: String) {
        expect(h.surface.replacements.isEmpty, "8s-\(label): nothing is written into a marked range we no longer own")
        expectEqual(h.abandonCount, 1, "8s-\(label): the session is told to abandon")
        expect(!h.controller.isHolding, "8s-\(label): nothing is held afterwards")
        expect(overlayHidden(h), "8s-\(label): overlay is hidden")
    }

    // (f) 预览计时器触发时。
    let f = Harness()
    f.confirm("你好")
    f.surface.markedRangeOverride = taken
    f.surface.secure = true
    f.pause()
    expectEqual(f.stub.count, 0, "8s-f: no preview request")
    expectAbandoned(f, "f")

    // (g) 转换结果迟到时。
    let g = Harness()
    g.confirm("你好")
    g.confirm("。")
    g.press(.enter)
    g.surface.markedRangeOverride = taken
    g.surface.secure = true
    g.arrive("Hello.")
    expectAbandoned(g, "g")

    // (h) 重试计时器触发时。
    let h = Harness()
    h.confirm("你好")
    h.confirm("。")
    h.press(.enter)
    h.fail(TranslationServiceClientError.serviceUnavailable("no socket"))
    h.surface.markedRangeOverride = taken
    h.surface.secure = true
    h.advance(3)
    expectEqual(h.stub.count, 1, "8s-h: the retry sends nothing")
    expectAbandoned(h, "h")

    // (i) 预览结果迟到时。
    let i = Harness()
    i.confirm("你好")
    i.pause()
    i.surface.markedRangeOverride = taken
    i.surface.secure = true
    i.arrive("Hello")
    expect(noEnglishShown(i), "8s-i: the preview result is not shown")
    expectAbandoned(i, "i")
}
