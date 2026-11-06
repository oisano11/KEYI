import Foundation
import KEYITranslationClient

// MARK: - 按句序上屏、归属校验

extension KeyiAutomaticTranslationController {
  /// 把最前面已经有结果的句子按顺序搬进 `outbox`；碰到还在等的、打字中的、没轮到的失败句就停。
  func drainLocked() {
    while let first = sentences.first {
      switch first.state {
      case let .arrived(english):
        if KeyiAutomaticTranslationText.containsHan(first.text) {
          outbox += KeyiAutomaticTranslationText.spacingPrefix(
            before: english,
            previous: previousScalarLocked()
          ) + english
          wordStats?.record(translatedWords: KEYIDailyWordStats.wordCount(in: english))
        } else {
          // 不含汉字的句子没有请求过，原样上屏。
          outbox += english
        }
      case .failed where first.chineseOnTurn:
        outbox += first.text
      default:
        return
      }
      sentences[0].cancelWork()
      sentences.removeFirst()
    }
  }

  /// 把本次操作的结果交给会话：`outbox` 上屏，剩下的句子重新设为标记文字。
  /// `verifyOwnership` 只在按键之外上屏（译文迟到）时为 true：标记范围不归我们了就什么都不写。
  func flushLocked(verifyOwnership: Bool = false) {
    let held = heldTextLocked
    let committing = outbox
    if committing.isEmpty, held == renderedHeld { return }
    if verifyOwnership, !committing.isEmpty, !ownsMarkedTextLocked() {
      abandonLocked(reason: "marked range mismatch")
      return
    }
    outbox = ""
    renderedHeld = held
    if !committing.isEmpty { lastCommitted = committing }
    keyiAutomaticNotice("render commit utf16=\(KeyiAutomaticTranslationText.utf16Length(committing)) held=\(KeyiAutomaticTranslationText.utf16Length(held))")
    sink?.automaticTranslation(render: .update(commit: committing, held: held))
    if sentences.isEmpty { hideOverlayLocked() }
  }

  /// 应用报告了标记范围时，长度必须等于我们设置的（暂存文字 + 拼音）；没报告就以自己的记录为准。
  func ownsMarkedTextLocked() -> Bool {
    guard let surface = activeSurface else { return false }
    let expected = KeyiAutomaticTranslationText.utf16Length(renderedHeld) + preeditLength
    guard expected > 0 else { return true }
    let marked = surface.markedRange()
    guard marked.location != NSNotFound else { return true }
    return marked.length == expected
  }

  /// 英文前一个字符：先看这次已排好的，再读客户端，读不到才用自己上次上屏的内容。
  func previousScalarLocked() -> Unicode.Scalar? {
    if let scalar = outbox.unicodeScalars.last { return scalar }
    if let surface = activeSurface, let scalar = scalarBeforeMarkedLocked(surface) { return scalar }
    return lastCommitted?.unicodeScalars.last
  }

  private func scalarBeforeMarkedLocked(_ surface: KeyiTranslationClientSurface) -> Unicode.Scalar? {
    let marked = surface.markedRange()
    var location: Int?
    if marked.location != NSNotFound, marked.length > 0 {
      location = marked.location
    } else if KeyiAutomaticTranslationText.utf16Length(renderedHeld) + preeditLength == 0 {
      let caret = surface.selectedRange()
      if caret.location != NSNotFound { location = caret.location }
    }
    guard let location, location > 0 else { return nil }
    // 多读一个 UTF-16 单元，前一个字符是 emoji 等代理对时也能读到完整字符。
    let span = min(location, 2)
    return KeyiAutomaticTranslationText
      .exactText(in: NSRange(location: location - span, length: span), on: surface)?
      .unicodeScalars.last
  }
}
