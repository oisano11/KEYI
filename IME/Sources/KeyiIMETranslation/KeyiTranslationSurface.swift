//
//  KeyiTranslationSurface.swift
//  KEYI 拼音输入法（自动翻译集成）
//
//  从 Squirrel 集成工作区的 KEYITranslationCommand.swift 中提取的**最小接口集合**：
//  客户端文本能力协议、真实 IMK 客户端实现、可取消句柄、输入会话身份、范围自检。
//  旧版「选区 + 快捷键」控制器与事件策略**不在此列**，自动翻译不使用它们。
//
//  改动必须在此处与自动翻译控制器之间同步，不能各自另发明一套判据。
//  来源文件随 Squirrel 路线于 2026-11-03 删除，本文件即唯一实现。
//

import Foundation
import InputMethodKit
import Carbon
import KEYITranslationClient

// MARK: - 客户端文本能力

/// 输入法客户端可被使用的文本能力。生产使用真实 `IMKTextInput`；
/// 测试使用替身实现同一协议，从而能对选区、组合状态与写回做精确控制。
public protocol KeyiTranslationClientSurface: AnyObject {
  /// 客户端文档的当前选区（读取不可用时 location 为 NSNotFound）。
  func selectedRange() -> NSRange
  /// 客户端的组合（marked）范围；组合中说明用户还在输入，不能翻译。
  func markedRange() -> NSRange
  /// 客户端文档长度（不可用时为 NSNotFound）。
  func documentLength() -> Int
  /// 读取客户端远端范围的文本；不可用时返回 nil。
  func attributedSubstring(from range: NSRange) -> NSAttributedString?
  /// 用给定文本替换客户端远端范围。
  func insertText(_ text: String, replacementRange: NSRange)
  /// 宿主应用的 bundle id，用于绑定原应用。
  func hostBundleIdentifier() -> String?
  /// 客户端可观察到的变化计数（选区 / 文档 / 组合状态）。
  ///
  /// 为什么需要它：只比较「返回瞬间」的范围与文本，无法发现「选区被移走又恢复成原样」——
  /// 这种情况在返回瞬间看起来完全没变。计数一旦增加就代表等待期间客户端发生过变化，
  /// 请求随即失效，且不会因为选区恢复原样而重新有效。
  /// 计数只依赖输入法实际能观察到的客户端事件（按键、提交、会话切换），
  /// 不能声称覆盖所有中间变化：读不到通知的宿主仍可能发生未被观察到的改动。
  /// 鼠标点击不在其中，靠写回前对光标位置与原文的精确比对兜底。
  func clientChangeCount() -> Int
  /// 记录一次「客户端可能已经变化」的观察，只递增、不做判断。
  func noteObservedClientChange()
  /// Secure Event Input is active (for example while a password field is focused).
  func isSecureInputEnabled() -> Bool
}

public extension KeyiTranslationClientSurface {
  func isSecureInputEnabled() -> Bool { false }
}

/// 真实 IMK 客户端的能力实现。对 `IMKTextInput` 的读取与写入都发生在输入法
/// 会话的主线程上；本类的所有方法都不得在后台线程使用。
public final class KeyiIMKTextInputSurface: KeyiTranslationClientSurface {
  private let client: IMKTextInput
  /// 由本类观察到的客户端变化计数。输入法进程对 `IMKTextInput` 只能按需读取，
  /// 没有选区变化通知，因此计数由输入法实际能观察到的事件驱动：按键（`handle` 里的
  /// `.keyDown`）与外部编辑快捷键。KEYIIME 只识别 keyDown，不观察鼠标按下。
  private var observedChangeCount = 0

  public init(client: IMKTextInput) {
    self.client = client
  }

  public func noteObservedClientChange() {
    observedChangeCount &+= 1
  }

  public func isSecureInputEnabled() -> Bool {
    IsSecureEventInputEnabled()
  }

  public func clientChangeCount() -> Int {
    observedChangeCount
  }

  public func selectedRange() -> NSRange {
    client.selectedRange()
  }

  public func markedRange() -> NSRange {
    client.markedRange()
  }

  public func documentLength() -> Int {
    client.length()
  }

  public func attributedSubstring(from range: NSRange) -> NSAttributedString? {
    client.attributedSubstring(from: range)
  }

  public func insertText(_ text: String, replacementRange: NSRange) {
    client.insertText(text, replacementRange: replacementRange)
  }

  public func hostBundleIdentifier() -> String? {
    client.bundleIdentifier()
  }
}

// MARK: - 可取消句柄

/// 生产与测试共用的最小取消接口：`KEYITranslationTask` 与测试替身都满足它。
public protocol KeyiTranslationCancellable: AnyObject {
  func cancel()
}

extension KEYITranslationTask: KeyiTranslationCancellable {}

// MARK: - 输入会话身份

/// 一个输入会话的身份：Rime 会话 id + 宿主应用。任一变化都让在途请求失效。
public struct KeyiTranslationSession: Equatable {
  /// 与上游 `RimeSessionId` 同一类型（`UInt`），避免截断或额外转换。
  public var id: UInt
  public var appIdentifier: String?

  public init(id: UInt, appIdentifier: String?) {
    self.id = id
    self.appIdentifier = appIdentifier
  }
}

// MARK: - 范围自检

enum KeyiTranslationRange {
  /// 范围是否可安全用于读写：非负、无溢出、且完全落在文档内。
  static func isSane(_ range: NSRange, documentLength: Int) -> Bool {
    guard range.location != NSNotFound, range.location >= 0, range.length >= 0 else { return false }
    let (upperBound, overflow) = range.location.addingReportingOverflow(range.length)
    guard !overflow else { return false }
    return upperBound <= documentLength
  }

  /// 只做与宿主文档长度**无关**的结构自检：位置有效、长度非负、无溢出。
  ///
  /// 为什么需要它：部分宿主（内嵌编辑器，如 Electron/Chromium 输入框）的
  /// `IMKTextInput.length()` 恒返回 0，但 `selectedRange()` 与 `attributedSubstring`
  /// 正常。若继续拿文档长度当越界判据，这类宿主上的自动翻译会永远被拒。
  /// 是否越界改由「精确读回」判定：只有读回文本与预期逐码元一致时才接受该范围，
  /// 读不到或读回不符一律拒绝，因此放宽文档长度约束不会降低写回安全性。
  static func isStructurallySane(_ range: NSRange) -> Bool {
    guard range.location != NSNotFound, range.location >= 0, range.length >= 0 else { return false }
    let (_, overflow) = range.location.addingReportingOverflow(range.length)
    return !overflow
  }
}
