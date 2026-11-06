import Foundation
import KEYITranslationClient

// MARK: - 与会话之间的约定

/// 控制器要求会话做的一次改动。会话据此画标记文字 = `held` + 当前拼音。
public enum KeyiAutomaticTranslationRender: Equatable, Sendable {
  /// 先把 `commit` 上屏（替换当前标记范围；空串表示不上屏），再把暂存文字设为 `held`。
  case update(commit: String, held: String)
  /// 标记文字已不归我们：暂存的句子已丢弃，什么都不写；会话只清掉自己记的暂存文字。
  case abandon
}

/// 接收控制器的改动；在 `callbackQueue` 上调用（生产环境是主队列）。
public protocol KeyiAutomaticTranslationSink: AnyObject {
  func automaticTranslation(render: KeyiAutomaticTranslationRender)
}

/// 拼音为空时会话交给控制器的按键。
public enum KeyiAutomaticTranslationKey: Equatable, Sendable {
  /// 回车，以及 Shift/⌘/⌃/⌥ + 回车。
  case enter
  case backspace
  case escape
  /// 方向键、Tab、Home/End、PgUp/PgDn、向前删除。
  case navigation
  /// 其他 ⌘/⌃/⌥ 组合键与功能键。
  case chord
}

/// `handleKey` 的结果。
public enum KeyiAutomaticTranslationKeyResult: Equatable, Sendable {
  /// 控制器已处理，按键不要再交给应用。
  case consumed
  /// 交给应用（若有暂存文字，控制器已先按中文上屏）。
  case passOn
}

/// 浮层底部那一行：此刻按回车会发生什么。
public enum KeyiAutomaticTranslationHint: Equatable, Sendable {
  /// 回车换英文，单按 Shift（或 Esc）保留中文。
  case enterConverts
  /// 按了回车、英文还没出来：再按回车或单按 Shift 保留中文。
  case waiting
  /// 这段翻译失败：再按回车或单按 Shift 保留中文；接着打字后回车会整段重新翻译。带上失败原因，面板据此写一行说明。
  case failed(KeyiAutomaticTranslationFailure.Kind)

  public var isFailed: Bool {
    if case .failed = self { return true }
    return false
  }
}

// MARK: - 控制器

/// 自动翻译控制器：暂存确认的中文（整段），回车时替换成英文上屏。
///
/// 所有入口都在 `callbackQueue` 上串行执行；从别的线程调用会同步切过去。
/// 控制器从不自己画标记文字，只通过 `sink` 告诉会话要上屏什么、暂存什么。
public final class KeyiAutomaticTranslationController: @unchecked Sendable {
  public typealias TranslateFunction = (
    TranslationServiceRequest,
    @escaping @Sendable (Result<String, Error>) -> Void
  ) -> KeyiTranslationCancellable
  public typealias FailureFunction = (KeyiAutomaticTranslationFailure) -> Void
  /// 对照浮层：`source` 为空表示收起；`translation` 为 nil 时由 `hint` 说明是在等还是失败了。
  public typealias PreviewFunction = (
    _ source: String,
    _ translation: String?,
    _ hint: KeyiAutomaticTranslationHint
  ) -> Void

  public static let requestTimeoutSeconds: TimeInterval = 10
  static let serviceRetryDelay: TimeInterval = 2.5
  static let sameRunMaximumGap: TimeInterval = 6.0
  static let cacheCapacity = 32

  /// 一句暂存文字。只有最后一句可以是 typing。
  struct Sentence {
    enum State: Equatable {
      case typing
      case waiting
      case arrived(String)
      case failed
    }

    let id: UInt64
    var text: String
    var state: State = .typing
    /// 当前请求的编号；对不上的回调一律丢弃。
    var token: UInt64 = 0
    var task: KeyiTranslationCancellable?
    var timeout: KeyiTranslationCancellable?
    var retryTimer: KeyiTranslationCancellable?
    var retryUsed = false
    var convertedByEnter = false
    var chineseOnTurn = false
    /// state 为 failed 时的原因。
    var failureKind = KeyiAutomaticTranslationFailure.Kind.other

    mutating func cancelWork() {
      task?.cancel()
      timeout?.cancel()
      retryTimer?.cancel()
      task = nil
      timeout = nil
      retryTimer = nil
    }
  }

  let translate: TranslateFunction
  let onFailure: FailureFunction
  /// 译文上屏时记每日译文词数；nil 时不记（测试、诊断）。
  public var wordStats: KEYIDailyWordStats?
  let preview: PreviewFunction
  let scheduler: KeyiAutomaticTranslationScheduler
  let rhythm: KeyiTypingRhythm
  let queue: DispatchQueue
  let queueKey = DispatchSpecificKey<UInt8>()

  /// 接收改动的会话。在第一次输入之前设置。
  public weak var sink: KeyiAutomaticTranslationSink?

  /// 预览是否等停手再发。false（本机风格）：确认候选后立即为整段发预览，结果一到就显示；
  /// true（大模型 API 风格，每次请求都计费）：按 `rhythm` 学到的停手界限等。每次安排预览时
  /// 现问，用户随时切换风格都跟着变。会话按当前风格设置；默认 true。
  public var previewWaitsForPause: () -> Bool = { true }

  var enabled = true
  var activeSurface: KeyiTranslationClientSurface?
  var session: KeyiTranslationSession?
  var sentences: [Sentence] = []
  var nextSentenceID: UInt64 = 0
  var nextToken: UInt64 = 0
  /// 本次操作结束时要上屏的文字。
  var outbox = ""
  /// 上次告诉会话的暂存文字。
  var renderedHeld = ""
  /// 会话画在暂存文字后面的拼音长度（UTF-16）。
  var preeditLength = 0
  var enterPending = false
  /// 我们自己最后上屏的文字；应用读不回时用来决定英文前的空格。
  var lastCommitted: String?
  var cache: [String: String] = [:]
  var cacheOrder: [String] = []
  var previewTimer: KeyiTranslationCancellable?
  var previewTimerToken: UInt64 = 0
  var previewTask: KeyiTranslationCancellable?
  var previewToken: UInt64 = 0
  /// 在途预览请求的原文；没有在途请求时为 nil。
  var previewSource: String?
  var lastPreview: (source: String, english: String)?
  var overlayShown = false
  var quietTimerStart: (start: TimeInterval, period: TimeInterval)?
  var pendingIdleGap: (gap: TimeInterval, period: TimeInterval)?
  var inputContinued = false

  public init(
    translate: @escaping TranslateFunction,
    onFailure: @escaping FailureFunction = { _ in },
    preview: @escaping PreviewFunction = { _, _, _ in },
    scheduler: KeyiAutomaticTranslationScheduler = KeyiDispatchAutomaticTranslationScheduler(),
    rhythm: KeyiTypingRhythm = .shared,
    callbackQueue: DispatchQueue = .main
  ) {
    self.translate = translate
    self.onFailure = onFailure
    self.preview = preview
    self.scheduler = scheduler
    self.rhythm = rhythm
    self.queue = callbackQueue
    callbackQueue.setSpecific(key: queueKey, value: 1)
  }

  func onQueue<T>(_ body: () -> T) -> T {
    if DispatchQueue.getSpecific(key: queueKey) != nil { return body() }
    return queue.sync(execute: body)
  }
}
