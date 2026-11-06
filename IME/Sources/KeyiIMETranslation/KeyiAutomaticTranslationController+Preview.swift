import Foundation
import KEYITranslationClient

// MARK: - 打字中那句的浮层预览

extension KeyiAutomaticTranslationController {
  /// 为正在打字的那句安排预览；结果只进浮层与缓存。
  ///
  /// 本机风格（`previewWaitsForPause` 为 false）不等停手：确认候选后下一轮主循环就发请求。
  /// 大模型 API 风格等用户自己的停手界限。两种都不按拼音字母发请求（只在拼音为空时调用）。
  /// 这一整段已有在途请求时不重发；内容变了才取消旧请求。
  func schedulePreviewLocked() {
    cancelPreviewTimerLocked()
    guard enabled, !enterPending, let last = sentences.last, last.state == .typing,
          KeyiAutomaticTranslationText.containsHan(last.text),
          last.text.utf8.count <= KeyiAutomaticTranslationText.maximumUTF8Bytes else {
      cancelStalePreviewRequestLocked()
      return
    }
    let period = rhythm.quietPeriod
    quietTimerStart = (scheduler.now, period)
    if previewTask != nil, previewSource == last.text { return }
    cancelPreviewRequestLocked()
    let delay = previewWaitsForPause() ? period : 0
    previewTimerToken &+= 1
    let token = previewTimerToken
    let sentenceID = last.id
    keyiAutomaticNotice("preview wait scheduled=\(String(format: "%.2f", delay))")
    previewTimer = scheduler.schedule(after: delay) { [weak self] in
      guard let self else { return }
      self.queue.async {
        guard self.previewTimerToken == token else { return }
        self.previewTimer = nil
        self.firePreviewLocked(sentence: sentenceID)
      }
    }
  }

  func firePreviewLocked(sentence sentenceID: UInt64) {
    if settleForSecureInputLocked(outsideKeyEvent: true) { return }
    guard let last = sentences.last, last.id == sentenceID, last.state == .typing else { return }
    let source = last.text
    if let cached = cache[source] {
      showPreviewLocked(source: source, english: cached)
      return
    }
    if previewTask != nil, previewSource == source { return }
    cancelPreviewRequestLocked()
    let token = previewToken
    let request = TranslationServiceRequest(
      text: source,
      timeoutSeconds: Self.requestTimeoutSeconds,
      id: UUID().uuidString
    )
    keyiAutomaticNotice("preview request utf16=\(KeyiAutomaticTranslationText.utf16Length(source))")
    previewSource = source
    previewTask = translate(request) { [weak self] result in
      guard let self else { return }
      self.queue.async { self.receivePreviewLocked(result, source: source, token: token) }
    }
  }

  func receivePreviewLocked(_ result: Result<String, Error>, source: String, token: UInt64) {
    if settleForSecureInputLocked(outsideKeyEvent: true) {
      keyiAutomaticNotice("preview result dropped: secure input")
      return
    }
    guard previewToken == token else {
      keyiAutomaticNotice("late preview dropped")
      return
    }
    previewTask = nil
    previewSource = nil
    switch translatedText(result) {
    case let .english(english):
      cacheLocked(english, for: source)
      // 回车时这一整段的预览还在路上：直接用它，不再等回车另发的那次。
      if let index = sentences.firstIndex(where: { $0.state == .waiting && $0.text == source }) {
        keyiAutomaticNotice("sentence \(sentences[index].id) arrived from preview")
        sentences[index].cancelWork()
        sentences[index].state = .arrived(english)
        drainLocked()
        settleEnterLocked()
        flushLocked(verifyOwnership: true)
        return
      }
      guard !enterPending, let last = sentences.last, last.state == .typing, last.text == source else { return }
      showPreviewLocked(source: source, english: english)
    case let .failed(kind):
      keyiAutomaticNotice("preview failed kind=\(kind)")
      // 预览失败不弹提示；连不上服务时仍让会话在后台拉起伴随应用。
      if kind == .serviceUnavailable {
        onFailure(KeyiAutomaticTranslationFailure(kind: kind, willRetry: false, isPreview: true))
      }
    }
  }

  func showPreviewLocked(source: String, english: String) {
    lastPreview = (source, english)
    preview(source, english, .enterConverts)
    overlayShown = true
  }

  /// 取消全部预览：还没发的计时与在途请求，迟到的结果一律丢弃。
  func cancelPreviewLocked() {
    cancelPreviewTimerLocked()
    cancelPreviewRequestLocked()
  }

  /// 只取消还没发出的那次（按键开始时调用）：在途请求留着，打拼音不打断它。
  func cancelPreviewTimerLocked() {
    previewTimerToken &+= 1
    previewTimer?.cancel()
    previewTimer = nil
  }

  func cancelPreviewRequestLocked() {
    previewToken &+= 1
    previewTask?.cancel()
    previewTask = nil
    previewSource = nil
  }

  /// 在途预览的原文已不是任何一段暂存文字（改过字、上屏了）：取消它。
  /// 回车后在等的那一段仍是它时留着，结果到了直接拿去上屏。
  func cancelStalePreviewRequestLocked() {
    guard let source = previewSource else { return }
    if sentences.contains(where: { $0.text == source }) { return }
    cancelPreviewRequestLocked()
  }

  /// 浮层回到此刻的状态：这段翻译失败就说明回车会保留中文；否则回到上次预览的对照；
  /// 没有暂存或没有预览就收起。
  func restoreOverlayLocked() {
    guard let last = sentences.last else {
      hideOverlayLocked()
      return
    }
    if last.state == .failed {
      preview(last.text, nil, .failed(last.failureKind))
      overlayShown = true
    } else if let lastPreview {
      preview(lastPreview.source, lastPreview.english, .enterConverts)
      overlayShown = true
    } else {
      hideOverlayLocked()
    }
  }

  func hideOverlayLocked() {
    guard overlayShown else { return }
    overlayShown = false
    preview("", nil, .enterConverts)
  }
}
