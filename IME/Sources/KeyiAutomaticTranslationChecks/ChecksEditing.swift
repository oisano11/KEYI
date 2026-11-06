//
//  ChecksEditing.swift
//  Product 6–8：英文上屏后的退格、其他原样上屏的时机、关闭与密码框。
//

import Foundation
import KEYITranslationClient
import KeyiIMETranslation

/// 行为 6（2026-10-30 用户实测后改）：英文上屏后就是普通文字，退格交给应用、一次删一个字母，
/// 不再还原中文；所有应用一样。暂存中的句子里，退格照常删暂存的字。
func checkBackspaceAfterEnglish() {
    section("6 backspace after English")
    let h = Harness()
    h.confirm("你好")
    h.press(.enter)
    h.arrive("Hello")
    expectEqual(h.committed, "Hello", "6: English committed before the backspace")
    expectEqual(h.press(.backspace), .passOn, "6: the first Backspace after English goes to the app")
    expectEqual(h.passedKeys.last, .backspace, "6: the app receives the Backspace")
    expectEqual(h.committed, "Hello", "6: the controller does not touch the English")
    expect(h.surface.replacements.allSatisfy { !$0.text.isEmpty }, "6: nothing is deleted by the input method")
    expect(!h.controller.isHolding, "6: no Chinese comes back")
    expectEqual(h.surface.markedText, "", "6: no marked text after the Backspace")
    expectEqual(h.press(.backspace), .passOn, "6: later Backspaces also go to the app")

    let m = Harness()
    m.confirm("你好。再见")
    m.press(.enter)
    m.arrive("Hello. Bye")
    expectEqual(m.committed, "Hello. Bye", "6: a whole paragraph is converted by one Enter")
    expectEqual(m.press(.backspace), .passOn, "6: Backspace after a paragraph goes to the app")
    expect(!m.controller.isHolding, "6: a converted paragraph never comes back as Chinese")

    let p = Harness()
    p.confirm("3你好。")
    p.press(.enter)
    expectEqual(p.stub.count, 1, "6: setup sent the Enter conversion")
    expectEqual(p.press(.backspace), .consumed, "6: Backspace inside a waiting sentence stays with the input method")
    p.stub.deliverLate(.success("Hello."), request: 0)
    drainQueue()
    expectEqual(p.controller.heldText, "你好", "6: it deletes the last held character and drops the stale result")
    expectEqual(p.committed, "3", "6: the direct prefix stays committed")

    let h2 = Harness()
    h2.confirm("你好")
    h2.press(.backspace)
    expectEqual(h2.controller.heldText, "你", "6: Backspace while typing deletes one held character")
    h2.pause()
    expectEqual(h2.stub.texts.last, "你", "6: after the edit the sentence is previewed again by the usual rules")
}

/// 行为 7：Esc、点别处、切换、组合键、⌃⌥T 都让中文原样上屏并取消请求。
func checkCommitChineseTriggers() {
    section("7 commit Chinese triggers")
    func prepared() -> Harness {
        let h = Harness()
        h.confirm("你好")
        h.confirm("。")
        h.confirm("再见")
        h.press(.enter)
        return h
    }
    let esc = prepared()
    expectEqual(esc.press(.escape), .consumed, "7: Esc is consumed")
    expectEqual(esc.committed, "你好。再见", "7: Esc commits all Chinese as-is")
    expect(!esc.controller.isHolding && esc.stub.wasCancelled(0), "7: Esc cancels requests and clears the held text")
    esc.arrive("Hello.", request: 0)
    expectEqual(esc.committed, "你好。再见", "7: results after Esc are dropped")

    let chord = prepared()
    expectEqual(chord.press(.chord), .passOn, "7: a ⌘/⌃/⌥ chord is passed on")
    expectEqual(chord.committed, "你好。再见", "7: a chord commits the Chinese first")
    expect(chord.surface.markedText.isEmpty, "7: nothing stays held after a chord")

    let click = prepared()
    click.typePinyin("ni")
    click.commitComposition()
    expectEqual(click.committed, "你好。再见ni", "7: click-away commits the Chinese and the pinyin letters")
    expect(click.stub.wasCancelled(0), "7: click-away cancels all requests")

    let off = prepared()
    off.typePinyin("ni")
    off.controller.setEnabled(false)
    expectEqual(off.committed, "你好。再见", "7: turning auto-translation off commits the Chinese")
    expectEqual(off.surface.markedText, "ni", "7: the pinyin in progress is kept after turning off")

    let switchSession = prepared()
    switchSession.controller.commitHeldAsChinese()
    switchSession.controller.setSession(KeyiTranslationSession(id: 2, appIdentifier: "com.example.other"))
    expectEqual(switchSession.committed, "你好。再见", "7: switching input method commits the Chinese")
    expectEqual(switchSession.abandonCount, 0, "7: a prior commit leaves nothing to abandon")
}

/// 行为 8：关闭自动翻译或在密码框里是普通拼音输入。
func checkPlainPinyinModes() {
    section("8 disabled / password")
    let off = Harness(enabled: false)
    off.confirm("你好")
    expectEqual(off.committed, "你好", "8: disabled: Chinese commits straight to the app")
    expect(off.surface.markedText.isEmpty && !off.controller.isHolding, "8: disabled: no sentence underline")
    off.confirm("。")
    off.pause()
    expectEqual(off.stub.count, 0, "8: disabled: no request")
    expectEqual(off.press(.enter), .passOn, "8: disabled: Enter goes to the app")

    let secure = Harness()
    secure.surface.secure = true
    secure.confirm("密码")
    expectEqual(secure.committed, "密码", "8: password field: Chinese commits straight to the app")
    expect(!secure.controller.isHolding, "8: password field: nothing is held")
    secure.pause()
    expectEqual(secure.stub.count, 0, "8: password field: no request")

    let late = Harness()
    late.confirm("你好")
    late.surface.secure = true
    late.confirm("中")
    expectEqual(late.committed, "你好中", "8: entering a password field commits the held Chinese as-is")
}
