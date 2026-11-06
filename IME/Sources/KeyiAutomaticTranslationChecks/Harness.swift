//
//  Harness.swift
//  替身会话：扮演 InputSession，把控制器的改动画到替身输入框上。
//  标记文字 = 暂存句子 + 当前拼音；上屏替换当前标记范围。
//

import Foundation
import KEYITranslationClient
import KeyiIMETranslation

/// 控制器与回写都跑在这条串行队列上；命令行工具不跑主队列，`drainQueue` 在断言前执行完排队的回调。
let controllerQueue = DispatchQueue(label: "keyi.automatic-checks")

func drainQueue() {
    controllerQueue.sync {}
}

final class Harness: KeyiAutomaticTranslationSink {
    let stub = StubTranslation()
    let clock = FakeClock()
    let surface = StubSurface()
    let rhythm = KeyiTypingRhythm()
    private(set) var controller: KeyiAutomaticTranslationController!
    /// 会话当前的拼音（Rime 的 preedit）。
    var pinyin = ""
    /// 浮层事件，source 为空表示收起；translation 为 nil 时 hint 说明是在等还是失败了。
    private(set) var previews: [(source: String, translation: String?, hint: KeyiAutomaticTranslationHint)] = []
    private(set) var failureEvents: [KeyiAutomaticTranslationFailure] = []
    /// 控制器放行给应用的按键。
    private(set) var passedKeys: [KeyiAutomaticTranslationKey] = []
    private(set) var abandonCount = 0
    private(set) var renders: [KeyiAutomaticTranslationRender] = []

    /// `waitsForPause` 为 false 时扮演本机风格（确认即译），true 时扮演大模型 API 风格（等停手）。
    init(enabled: Bool = true, waitsForPause: Bool = true) {
        controller = KeyiAutomaticTranslationController(
            translate: { [stub] request, completion in stub.translate(request, completion: completion) },
            onFailure: { [weak self] failure in self?.failureEvents.append(failure) },
            preview: { [weak self] source, translation, hint in self?.previews.append((source, translation, hint)) },
            scheduler: clock,
            rhythm: rhythm,
            callbackQueue: controllerQueue
        )
        controller.sink = self
        controller.previewWaitsForPause = { waitsForPause }
        controller.setEnabled(enabled)
        controller.setSession(KeyiTranslationSession(id: 1, appIdentifier: "com.example.host"))
        controller.setActiveClient(surface)
    }

    // MARK: Sink

    func automaticTranslation(render: KeyiAutomaticTranslationRender) {
        renders.append(render)
        switch render {
        case let .update(commit, held):
            if !commit.isEmpty { surface.insertText(commit, replacementRange: surface.markedRange()) }
            surface.setMarked(held + pinyin)
        case .abandon:
            abandonCount += 1
        }
    }

    // MARK: 会话动作

    private func redraw() { surface.setMarked(controller.heldText + pinyin) }

    /// 用户打拼音字母（Rime 组合中）。
    func typePinyin(_ text: String) {
        controller.beginUserInput()
        pinyin = text
        controller.finishUserInput(pinyin: pinyin)
        redraw()
    }

    /// Rime 确认了一段文字（候选、数字、空格、标点都走这里）。
    func confirm(_ text: String) {
        controller.beginUserInput()
        pinyin = ""
        if !controller.takeCommit(text) {
            surface.insertText(text, replacementRange: surface.markedRange())
        }
        controller.finishUserInput(pinyin: pinyin)
        redraw()
    }

    /// 拼音中按回车：字母原样放进这句。
    func enterWithPinyin() {
        let letters = pinyin
        confirm(letters)
    }

    /// 拼音为空时的按键。返回控制器的决定；放行的键记入 `passedKeys`。
    @discardableResult
    func press(_ key: KeyiAutomaticTranslationKey) -> KeyiAutomaticTranslationKeyResult {
        controller.beginUserInput()
        let result = controller.handleKey(key)
        if result == .passOn { passedKeys.append(key) }
        controller.finishUserInput(pinyin: pinyin)
        redraw()
        return result
    }

    /// 点别处、切换输入法等：会话先调用 `commitHeldForLeaving`（英文已到就上屏英文），再按字母上屏拼音。
    func commitComposition() {
        controller.commitHeldForLeaving()
        if !pinyin.isEmpty {
            surface.insertText(pinyin, replacementRange: surface.markedRange())
            pinyin = ""
            controller.finishUserInput(pinyin: "")
        }
        redraw()
    }

    // MARK: 时间与翻译

    /// 停手：推进假时钟越过当前停手界限，并等排队的回调执行完。
    func pause() {
        clock.advance(controller.currentQuietPeriodForDiagnostics + 0.05)
        drainQueue()
    }

    /// 不推进时间，只执行已经到期的（0 秒）计时与排队的回调：相当于下一轮主循环。
    func settle() {
        clock.advance(0)
        drainQueue()
    }

    func advance(_ seconds: TimeInterval) {
        clock.advance(seconds)
        drainQueue()
    }

    /// 让最近一个未完成的请求（或指定序号的请求）以译文完成。
    func arrive(_ english: String, request: Int? = nil) {
        stub.finish(.success(english), request: request)
        drainQueue()
    }

    func fail(_ error: Error = StubError(), request: Int? = nil) {
        stub.finish(.failure(error), request: request)
        drainQueue()
    }

    /// 应用里此刻看到的全部文字（已上屏 + 标记文字）。
    var visible: String { surface.document }
    var committed: String { surface.committed }
}
