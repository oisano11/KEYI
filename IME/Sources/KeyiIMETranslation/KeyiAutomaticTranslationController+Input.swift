import Foundation

// MARK: - 暂存文字的编辑

extension KeyiAutomaticTranslationController {
  var heldTextLocked: String {
    sentences.map(\.text).joined()
  }

  /// 追加到暂存的那一段；。？！ 只是普通文字，只有回车开始转换。
  /// 翻译失败的那段接着打字时回到打字中，回车时整段一次翻译。
  func appendLocked(_ text: String) {
    guard !text.isEmpty else { return }
    if let last = sentences.indices.last {
      let wasFailed = sentences[last].state == .failed
      if sentences[last].state != .typing {
        sentences[last].cancelWork()
        sentences[last].state = .typing
        sentences[last].retryUsed = false
        sentences[last].convertedByEnter = false
        sentences[last].chineseOnTurn = false
      }
      sentences[last].text += text
      // 失败提示说的是“回车保留中文”；接着打字后回车又会翻译，浮层不能再这么说。
      if wasFailed, overlayShown { restoreOverlayLocked() }
    } else {
      nextSentenceID &+= 1
      sentences.append(Sentence(id: nextSentenceID, text: text))
    }
  }

  /// 没有暂存时所有键都交给应用：英文上屏后就是普通文字，退格照常删字。
  func handleKeyLocked(_ key: KeyiAutomaticTranslationKey) -> KeyiAutomaticTranslationKeyResult {
    guard !sentences.isEmpty else { return .passOn }
    switch key {
    case .enter:
      pressEnterLocked()
      return .consumed
    case .backspace:
      deleteLastHeldCharacterLocked()
      return .consumed
    case .escape:
      commitAllAsChineseLocked()
      return .consumed
    case .navigation:
      return .consumed
    case .chord:
      commitAllAsChineseLocked()
      return .passOn
    }
  }

  /// 第一次回车：整段开始转换，已经失败的按中文上屏；仍在等译文时再按一次：全部按中文上屏。
  func pressEnterLocked() {
    if enterPending, sentences.contains(where: { $0.state == .waiting }) {
      keyiAutomaticNotice("enter again while waiting; commit Chinese")
      commitAllAsChineseLocked()
      return
    }
    enterPending = true
    for index in sentences.indices where sentences[index].state == .failed {
      sentences[index].chineseOnTurn = true
    }
    if let last = sentences.indices.last, sentences[last].state == .typing {
      startConversionLocked(at: last, byEnter: true)
    }
    drainLocked()
    settleEnterLocked()
    keyiAutomaticNotice("enter converts sentences=\(sentences.count) pending=\(enterPending)")
  }

  /// 回车后没有在等的句子了：结束这次回车，浮层回到上次的对照。
  func settleEnterLocked() {
    guard enterPending else { return }
    if sentences.contains(where: { $0.state == .waiting }) {
      if let last = sentences.last {
        preview(last.text, nil, .waiting)
        overlayShown = true
      }
      return
    }
    enterPending = false
    restoreOverlayLocked()
  }

  /// 回车后又打字：只撤销这次回车，最后一句回到打字中。
  func cancelEnterLocked() {
    guard enterPending else { return }
    enterPending = false
    for index in sentences.indices {
      sentences[index].chineseOnTurn = false
    }
    if let last = sentences.indices.last, sentences[last].convertedByEnter {
      sentences[last].cancelWork()
      sentences[last].state = .typing
      sentences[last].convertedByEnter = false
      sentences[last].retryUsed = false
    }
    keyiAutomaticNotice("enter cancelled by input")
    restoreOverlayLocked()
  }

  /// 删掉最后一个暂存字；删进在等的句子会取消它的请求，让它回到打字中。
  func deleteLastHeldCharacterLocked() {
    cancelEnterLocked()
    guard let last = sentences.indices.last else { return }
    let wasFailed = sentences[last].state == .failed
    if sentences[last].state != .typing {
      sentences[last].cancelWork()
      sentences[last].state = .typing
      sentences[last].retryUsed = false
      sentences[last].chineseOnTurn = false
    }
    sentences[last].text.removeLast()
    if sentences[last].text.isEmpty {
      sentences.removeLast()
    }
    if wasFailed, overlayShown { restoreOverlayLocked() }
  }

  /// 暂存文字全部按中文上屏，取消所有请求；立即交给会话。
  func commitAllAsChineseLocked() {
    guard !sentences.isEmpty else { return }
    keyiAutomaticNotice("commit held as Chinese sentences=\(sentences.count)")
    outbox += heldTextLocked
    cancelAllWorkLocked()
    sentences = []
    flushLocked(verifyOwnership: false)
  }

  /// 标记文字已不归我们：丢掉暂存与结果，什么都不写。
  func abandonLocked(reason: String) {
    keyiAutomaticNotice("abandon held text: \(reason)")
    cancelAllWorkLocked()
    sentences = []
    outbox = ""
    renderedHeld = ""
    sink?.automaticTranslation(render: .abandon)
    hideOverlayLocked()
  }

  func cancelAllWorkLocked() {
    for index in sentences.indices {
      sentences[index].cancelWork()
    }
    cancelPreviewLocked()
    enterPending = false
  }

  /// 只在按键里有新的输入时，才把这次停手算进用户的节奏。
  func acceptIdleGapLocked() {
    defer { pendingIdleGap = nil }
    guard let pending = pendingIdleGap, inputContinued, pending.gap > 0,
          pending.gap <= min(Self.sameRunMaximumGap, pending.period * 2) else { return }
    rhythm.record(idleGap: pending.gap)
  }
}
