import Foundation

// MARK: - 密码输入（Secure Keyboard Entry）

extension KeyiAutomaticTranslationController {
  /// 翻译请求发出之前、异步结果写入之前都要先调用它。
  /// Secure Keyboard Entry 是系统级开关，可以在句子暂存期间随时打开，客户端不会有任何变化。
  /// 它已打开时：不发任何请求，取消所有待办（预览计时、在途请求、重试、回车等待），
  /// 暂存的中文原样上屏，收起浮层，并返回 true，调用方必须立即返回、丢弃手上的结果。
  /// 当前拼音不动，由会话继续按普通拼音处理。
  /// `outsideKeyEvent` 为 true（计时器、迟到结果、重试）时，和 `flushLocked(verifyOwnership:)` 一样先确认
  /// 标记文字还归我们；应用已改了标记范围就什么都不写，只放弃暂存。
  func settleForSecureInputLocked(outsideKeyEvent: Bool = false) -> Bool {
    guard let surface = activeSurface, surface.isSecureInputEnabled() else { return false }
    keyiAutomaticNotice("secure input is on; no translation, held text stays Chinese")
    cancelPreviewLocked()
    if outsideKeyEvent, !sentences.isEmpty, !ownsMarkedTextLocked() {
      abandonLocked(reason: "secure input; marked range mismatch")
      lastPreview = nil
      return true
    }
    commitAllAsChineseLocked()
    lastPreview = nil
    hideOverlayLocked()
    return true
  }
}
