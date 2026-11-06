// Automatic translation for text committed by this KEYI input session.

import Foundation
import KEYITranslationClient
import OSLog

/// 排障日志：**仅当标记文件存在时**才写，避免日常输入产生磁盘写入与延迟。
/// 标记文件：`/tmp/keyi-autotranslate-debug.flag`（内容无关，仅判断是否存在）。
/// 只记录结构与布尔判定，**不记录**用户文本内容。
public func keyiAutomaticDebugLog(_ message: String) {
    guard FileManager.default.fileExists(atPath: "/tmp/keyi-autotranslate-debug.flag") else { return }
    let path = "/tmp/keyi-autotranslate-debug.log"
    let line = "\(Date().timeIntervalSince1970) \(message)\n"
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        handle.closeFile()
    } else {
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

/// 低噪声诊断日志：只记录结构与布尔判定，**不记录**用户文本内容。
/// 日常使用不产生可读文本；排障时用 `log show --predicate 'subsystem == ...'` 读取。
private let automaticTranslationLog = Logger(
    subsystem: "com.keyi.inputmethod.keyi",
    category: "AutomaticTranslation"
)

public protocol KeyiAutomaticTranslationScheduler {
  /// 当前时刻（秒）。控制器用它测量用户自己的打字节奏，
  /// 从而不去依赖一个写死的等待秒数。
  var now: TimeInterval { get }
  @discardableResult
  func schedule(after delay: TimeInterval, action: @escaping @Sendable () -> Void) -> KeyiTranslationCancellable
}

public final class KeyiDispatchAutomaticTranslationScheduler: KeyiAutomaticTranslationScheduler {
  public init() {}

  public var now: TimeInterval { Date().timeIntervalSince1970 }

  public func schedule(after delay: TimeInterval, action: @escaping @Sendable () -> Void) -> KeyiTranslationCancellable {
    let work = DispatchWorkItem(block: action)
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    return KeyiAutomaticScheduledWork(work)
  }
}

private final class KeyiAutomaticScheduledWork: KeyiTranslationCancellable {
  private let work: DispatchWorkItem

  public init(_ work: DispatchWorkItem) {
    self.work = work
  }

  func cancel() {
    work.cancel()
  }
}

// MARK: - 打字节奏

/// 用户自己的打字节奏，用来推断“这一口气说完了”。
///
/// 只记录**停手计时开始后，用户隔多久又接着打字**的空闲间隔。早期版本统计的是“两次确认
/// 之间的间隔”，其中包含打下一个词拼音的时间；而停手计时在用户按下任何键时就会取消，
/// 真正决定会不会误切的只有空闲时间。量错了对象，界限就被系统性放大，用户总觉得慢。
///
/// 节奏属于用户，不属于某个输入框：所有输入会话共享同一份样本，换输入框不会从头学起。
/// 共享的那份存在本机偏好里：重装、重启输入法后接着用，不再从默认值重新学（2026-11-05 用户
/// 在刚重装后的 QQ 里等了 1.2 秒还没出对照）。
///
/// 只有大模型 API 风格按它等停手；本机风格确认即译，不等（见控制器 `previewWaitsForPause`）。
public final class KeyiTypingRhythm: @unchecked Sendable {
  /// 诊断跑真实输入法时指定了一次性的 `KEYI_IME_USER_DATA_DIR`，按机器速度打字：只记在内存，
  /// 不写进用户学到的节奏（与 `KeyiPreferences.rimeUserDataURL` 同一个判据）。
  public static let shared = KeyiTypingRhythm(
    storage: (ProcessInfo.processInfo.environment["KEYI_IME_USER_DATA_DIR"] ?? "").isEmpty ? .standard : nil
  )

  /// 样本不足时的停手界限。
  public static let initialQuietPeriod: TimeInterval = 0.8
  /// 下限：再快的输入也至少等这么久，避免每个词后面都发一次请求。
  public static let floorQuietPeriod: TimeInterval = 0.6
  /// 上限：慢速输入者最多等这么久。
  public static let maximumQuietPeriod: TimeInterval = 1.5
  /// 界限 = 近期空闲间隔的中位数 × 此倍数。中位数不受偶尔一次长思考的影响。
  static let medianMultiple: TimeInterval = 2.0
  static let minimumSamples = 4
  static let capacity = 24

  static let storageKey = "KEYITypingRhythmIdleGaps"

  private let lock = NSLock()
  private var samples: [TimeInterval] = []
  /// 存样本的偏好；nil 时只在内存里（检查、诊断）。
  private let storage: UserDefaults?

  public init(storage: UserDefaults? = nil) {
    self.storage = storage
    if let stored = storage?.array(forKey: Self.storageKey) as? [Double] {
      samples = Array(stored.filter { $0.isFinite && $0 > 0 }.suffix(Self.capacity))
    }
  }

  /// 当前停手界限（秒）。
  public var quietPeriod: TimeInterval {
    lock.lock()
    defer { lock.unlock() }
    guard samples.count >= Self.minimumSamples else { return Self.initialQuietPeriod }
    let sorted = samples.sorted()
    let middle = sorted.count / 2
    let median = sorted.count.isMultiple(of: 2)
      ? (sorted[middle - 1] + sorted[middle]) / 2
      : sorted[middle]
    return min(max(median * Self.medianMultiple, Self.floorQuietPeriod), Self.maximumQuietPeriod)
  }

  /// 已有的样本数，供排障与检查读取。
  public var sampleCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return samples.count
  }

  /// 记录一次“停手计时开始后又接着打字”的空闲间隔。
  public func record(idleGap: TimeInterval) {
    guard idleGap.isFinite, idleGap > 0 else { return }
    lock.lock()
    defer { lock.unlock() }
    samples.append(idleGap)
    if samples.count > Self.capacity {
      samples.removeFirst(samples.count - Self.capacity)
    }
    storage?.set(samples, forKey: Self.storageKey)
  }
}

/// 只记录状态与长度，不含文字内容。
func keyiAutomaticNotice(_ message: String) {
  keyiAutomaticDebugLog(message)
  automaticTranslationLog.notice("\(message, privacy: .public)")
}

// MARK: - 失败反馈

/// 自动翻译失败的类型。控制器只负责分类；提示文字、是否拉起伴随应用由输入法界面决定。
public struct KeyiAutomaticTranslationFailure: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    /// 连不上伴随服务：KEYI 可译没有运行，或服务进程已退出。
    case serviceUnavailable
    /// 伴随应用里还没有配置可用的翻译服务。
    case notConfigured
    case timedOut
    case emptyResult
    /// 这段超过 8 KiB，没有发请求。
    case tooLong
    case other
  }

  public let kind: Kind
  /// 控制器会在稍后自动重试一次（只用于连不上伴随服务的情况）。
  public let willRetry: Bool
  /// 失败来自打字中的浮层预览请求。预览失败不弹提示，只用于在后台拉起伴随服务。
  public let isPreview: Bool

  public init(kind: Kind, willRetry: Bool, isPreview: Bool = false) {
    self.kind = kind
    self.willRetry = willRetry
    self.isPreview = isPreview
  }

  /// Whether the user should be told about this failure (a toast). Preview failures
  /// stay silent: the user is still typing and only conversion failures matter.
  public var showsToast: Bool { !isPreview }

  /// Whether this failure asks for a background launch of the companion app.
  public var launchesCompanion: Bool { kind == .serviceUnavailable }

  static func kind(for error: Error) -> Kind {
    guard let error = error as? TranslationServiceClientError else { return .other }
    switch error {
    case .serviceUnavailable:
      return .serviceUnavailable
    case .timeout:
      return .timedOut
    case let .rejected(code, _):
      switch code {
      case .notConfigured, .unavailableProvider: return .notConfigured
      case .timeout: return .timedOut
      default: return .other
      }
    case .invalidResponse, .cancelled:
      return .other
    }
  }
}

