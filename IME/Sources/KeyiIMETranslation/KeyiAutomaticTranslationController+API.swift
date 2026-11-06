import Foundation

// MARK: - 会话调用的入口

extension KeyiAutomaticTranslationController {
  /// 当前学到的停手时长（秒），仅供诊断与检查。
  public var currentQuietPeriodForDiagnostics: TimeInterval {
    rhythm.quietPeriod
  }

  /// 暂存中的文字；会话把标记文字画成它 + 当前拼音。
  public var heldText: String {
    onQueue { heldTextLocked }
  }

  /// 是否有暂存文字。
  public var isHolding: Bool {
    onQueue { !sentences.isEmpty }
  }

  /// 是否处在“按过回车、还在等译文”。
  public var isWaitingAfterEnter: Bool {
    onQueue { enterPending }
  }

  /// 打开或关闭自动翻译。关闭时暂存文字按中文上屏，拼音由会话保留。
  public func setEnabled(_ enabled: Bool) {
    onQueue {
      guard self.enabled != enabled else { return }
      self.enabled = enabled
      keyiAutomaticNotice("enabled=\(enabled)")
      if !enabled { commitAllAsChineseLocked() }
    }
  }

  /// 当前输入会话（应用 + 代次）。变了而仍有暂存时，暂存句子被放弃，不写任何东西。
  public func setSession(_ session: KeyiTranslationSession?) {
    onQueue {
      guard self.session != session else { return }
      self.session = session
      lastCommitted = nil
      if !sentences.isEmpty { abandonLocked(reason: "session changed") }
    }
  }

  /// 当前客户端。换了客户端而仍有暂存时同样放弃暂存；会话应在切换前先调用 `commitHeldForLeaving()`。
  public func setActiveClient(_ surface: KeyiTranslationClientSurface?) {
    onQueue {
      guard activeSurface !== surface else { return }
      activeSurface = surface
      lastCommitted = nil
      cancelPreviewLocked()
      if !sentences.isEmpty { abandonLocked(reason: "client changed") }
    }
  }

  /// 每个按键事件开始时调用（在交给 Rime 之前）。取消还没发出的预览，测量停手间隔。
  /// 已在途的预览留着：接着打拼音不打断它，暂存的整段变了才由 `schedulePreviewLocked` 取消。
  public func beginUserInput() {
    onQueue {
      inputContinued = false
      if let start = quietTimerStart {
        pendingIdleGap = (scheduler.now - start.start, start.period)
      }
      quietTimerStart = nil
      cancelPreviewTimerLocked()
    }
  }

  /// 每个按键事件结束时调用，`pinyin` 是此刻 Rime 的拼音。本次按键的改动在这里交给 `sink`；
  /// 返回后会话把标记文字画成 `heldText` + 拼音。
  public func finishUserInput(pinyin: String) {
    onQueue {
      preeditLength = KeyiAutomaticTranslationText.utf16Length(pinyin)
      if !pinyin.isEmpty {
        inputContinued = true
        cancelEnterLocked()
      }
      acceptIdleGapLocked()
      flushLocked()
      if pinyin.isEmpty { schedulePreviewLocked() }
    }
  }

  /// Rime 确认上屏的文字，以及暂存时 Rime 不处理的可打印字符（空格、数字、字母、标点）。
  /// 返回 true：文字归控制器，改动已在返回前交给 `sink`；false：会话自己直接上屏。
  public func takeCommit(_ text: String) -> Bool {
    onQueue {
      guard !text.isEmpty else { return false }
      inputContinued = true
      if settleForSecureInputLocked() {
        lastCommitted = text
        return false
      }
      guard enabled, activeSurface != nil else {
        if !sentences.isEmpty {
          commitAllAsChineseLocked()
        }
        lastCommitted = text
        return false
      }
      if sentences.isEmpty {
        guard let first = text.firstIndex(where: { $0.unicodeScalars.contains(where: KeyiAutomaticTranslationText.isHan) }) else {
          lastCommitted = text
          return false
        }
        let prefix = String(text[..<first])
        outbox += prefix
        lastPreview = nil
        appendLocked(String(text[first...]))
      } else {
        cancelEnterLocked()
        appendLocked(text)
      }
      drainLocked()
      flushLocked()
      return true
    }
  }

  /// 拼音为空时的回车、退格、Esc、导航键与组合键。
  public func handleKey(_ key: KeyiAutomaticTranslationKey) -> KeyiAutomaticTranslationKeyResult {
    onQueue {
      if !sentences.isEmpty, settleForSecureInputLocked() {
        // 暂存的中文刚按原样上屏。回车和 Esc 本来就是用来结束这句的，吞掉；
        // 其余键作用在已上屏的文字上，和普通拼音输入一样交给应用。
        // 之后没有暂存了，下一下回车按普通规则交给应用。
        return key == .enter || key == .escape ? .consumed : .passOn
      }
      let result = handleKeyLocked(key)
      flushLocked()
      return result
    }
  }

  /// 组合键等必须马上交给应用的提交：暂存文字按中文上屏，取消所有请求。
  /// 改动在返回前同步交给 `sink`。
  public func commitHeldAsChinese() {
    onQueue {
      commitAllAsChineseLocked()
    }
  }

  /// 输入框即将不归我们（点到别处、失焦、换输入框、切换输入法）：
  /// 浮层里已经有整段的英文就上屏英文，否则按中文上屏；都不再等结果，取消所有请求。
  /// 密码输入、自动翻译关闭、还有拼音在打、英文没到或不是这一整段时都按中文。
  /// 改动在返回前同步交给 `sink`。
  public func commitHeldForLeaving() {
    onQueue {
      guard !sentences.isEmpty else { return }
      if settleForSecureInputLocked() { return }
      guard enabled, preeditLength == 0, let english = overlayEnglishLocked() else {
        commitAllAsChineseLocked()
        return
      }
      cancelAllWorkLocked()
      sentences[0].state = .arrived(english)
      drainLocked()
      flushLocked(verifyOwnership: false)
    }
  }

  /// 浮层此刻显示的、正是这一整段的英文；回车等待中、失败、改过字以后都没有。
  private func overlayEnglishLocked() -> String? {
    guard sentences.count == 1, !enterPending, overlayShown,
          sentences[0].state == .typing,
          let lastPreview, lastPreview.source == sentences[0].text,
          KeyiAutomaticTranslationText.containsHan(lastPreview.source)
    else { return nil }
    return lastPreview.english
  }
}
