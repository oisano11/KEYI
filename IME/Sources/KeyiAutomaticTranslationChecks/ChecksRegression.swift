//
//  ChecksRegression.swift
//  独立评审发现的问题：直接前缀与缓存、浮层收起。（撤销相关的三项随 2026-10-30 去掉退格还原一起删除。）
//

import Foundation
import KEYITranslationClient
import KeyiIMETranslation

/// 直接前缀（第一个汉字前的非汉字）和缓存命中的句子在同一次上屏里，顺序与空格正确。
func checkDirectPrefixWithCachedSentence() {
    section("fix 2 direct prefix")
    let h = Harness()
    h.confirm("你好。")
    h.press(.enter)
    h.arrive("Hello.")
    expectEqual(h.committed, "Hello.", "fix2: setup caches 你好。")
    h.confirm("3你好。")
    expectEqual(h.committed, "Hello.3", "fix2: the direct prefix is committed at once")
    expectEqual(h.controller.heldText, "你好。", "fix2: the Han part is held as the paragraph")
    h.press(.enter)
    expectEqual(h.stub.count, 1, "fix2: Enter reuses the cached English, no new request")
    expectEqual(h.committed, "Hello.3 Hello.", "fix2: the cached paragraph converts after the prefix with correct spacing")
    expect(!h.controller.isHolding, "fix2: nothing is held")
}

/// 暂存结束的每条路径都把浮层收起。
func checkOverlayHidesWhenHoldingEnds() {
    section("fix 4 overlay hide")
    func shown() -> Harness {
        let h = Harness()
        h.confirm("你好")
        h.pause()
        h.arrive("Hello")
        expectEqual(h.previews.last?.translation, "Hello", "fix4: setup shows the overlay")
        return h
    }
    func hidden(_ h: Harness, _ label: String) {
        expectEqual(h.previews.last?.source, "", "fix4: overlay hidden after \(label)")
        expect(h.previews.last?.translation == nil, "fix4: the hide event carries no translation after \(label)")
    }
    let a = shown()
    a.confirm("吗。")
    a.press(.enter)
    a.surface.markedRangeOverride = NSRange(location: 0, length: 99)
    a.arrive("How are you?")
    expectEqual(a.abandonCount, 1, "fix4: ownership mismatch abandons")
    hidden(a, "abandon")

    let c = shown()
    c.controller.commitHeldAsChinese()
    hidden(c, "commitHeldAsChinese")

    let e = shown()
    e.controller.setEnabled(false)
    hidden(e, "setEnabled(false)")

    let g = shown()
    g.controller.setActiveClient(StubSurface())
    hidden(g, "setActiveClient change")

    let s = shown()
    s.controller.setSession(KeyiTranslationSession(id: 2, appIdentifier: "com.example.other"))
    hidden(s, "session change")

    let x = shown()
    x.press(.escape)
    hidden(x, "Esc")

    let n = shown()
    n.controller.setActiveClient(nil)
    hidden(n, "client removed")

    let sec = shown()
    sec.surface.secure = true
    sec.confirm("中")
    hidden(sec, "secure field")

    let d = shown()
    d.press(.backspace)
    d.press(.backspace)
    hidden(d, "deleting all held text")

    let t = Harness()
    t.surface.secure = true
    t.controller.setActiveClient(nil)
    t.controller.setActiveClient(t.surface)
    t.confirm("密码")
    t.pause()
    expectEqual(t.stub.count, 0, "fix4: no preview request in a secure field")
}
