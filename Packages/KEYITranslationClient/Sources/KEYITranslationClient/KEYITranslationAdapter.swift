//
//  KEYITranslationAdapter.swift
//  KEYI 可译（共享包 Packages/KEYITranslationClient；源自 Squirrel 集成阶段 02）
//
//  输入法进程里可被 IMK 调用的异步文本翻译接口。它只是 KEYI 可译伴随应用
//  翻译服务（AF_UNIX socket，NDJSON）的薄客户端，进程内不加载模型、不做
//  Apple Translation 会话，也不接触凭据。
//
//  线程模型：
//  - `translate(_:completion:)` 可从任意线程调用；回调默认投递到主队列，
//    可用 `onQueue` 指定其他队列。
//  - `TranslationServiceClient` 内部用并发 DispatchQueue 做阻塞 IO，可安全并发调用。
//
//  过期结果处理：
//  - 每次调用持有独立的共享状态；回调在目标队列**实际执行时**才原子取得
//    交付资格，排队期间被取消的请求直接丢弃结果，不触发回调。
//

import Foundation

public final class KEYITranslationAdapter: @unchecked Sendable {
    public static let shared = KEYITranslationAdapter()

    private let client: TranslationServiceClient

    public init(socketPath: String = TranslationServiceSocketPath.defaultPath()) {
        client = TranslationServiceClient(socketPath: socketPath)
    }

    /// 发起一次翻译；返回可取消的句柄。
    @discardableResult
    public func translate(
        _ request: TranslationServiceRequest,
        onQueue queue: DispatchQueue = .main,
        completion: @escaping @Sendable (Result<String, Error>) -> Void
    ) -> KEYITranslationTask {
        var request = request
        if request.id.isEmpty {
            request.id = UUID().uuidString
        }
        let state = KEYITranslationRequestState()

        let task = Task { [weak self] in
            let result: Result<String, Error>
            do {
                result = .success(try await self?.client.translate(request) ?? "")
            } catch {
                result = .failure(error)
            }
            guard state.storeResult(result) else { return }
            queue.async {
                // 交付资格在回调队列实际执行时取得：排队期间被取消则丢弃。
                guard state.claimDelivery() else { return }
                completion(result)
            }
        }
        return KEYITranslationTask(
            id: request.id,
            task: task,
            state: state
        )
    }

    /// 便捷入口：直接 await 译文。
    public func translate(_ request: TranslationServiceRequest) async throws -> String {
        var request = request
        if request.id.isEmpty {
            request.id = UUID().uuidString
        }
        return try await client.translate(request)
    }

    public func serviceStatus() async throws -> TranslationServiceStatus {
        try await client.status()
    }
}

/// 单个请求的共享状态：结果、交付资格、取消与完成标志都由它原子维护。
///
/// 不再用 `Set<String>` 表示请求身份，因此两个相同 id 的请求互不影响。
final class KEYITranslationRequestState: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<String, Error>?
    private var delivered = false
    private var completed = false
    private var cancelled = false

    /// 记录运行结果并标记任务结束；已取消时返回 false，调用方不再排队回调。
    ///
    /// `completed` 在结果产出时即为 true，与回调是否已经执行无关：成功 / 失败后
    /// `isFinished` 立即可见，回调交付是另一件事（见 `claimDelivery()`）。
    func storeResult(_ result: Result<String, Error>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled, !completed else { return false }
        self.result = result
        completed = true
        return true
    }

    /// 在回调队列实际执行时取得一次性交付资格。
    func claimDelivery() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled, !delivered, result != nil else { return false }
        delivered = true
        return true
    }

    /// 取消：放弃交付资格并标记完成；迟到的结果不再触发回调。
    func cancel() {
        lock.lock()
        cancelled = true
        completed = true
        lock.unlock()
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return completed
    }
}

/// 一次翻译请求的句柄。
public final class KEYITranslationTask: @unchecked Sendable {
    public let id: String

    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private let state: KEYITranslationRequestState

    fileprivate init(
        id: String,
        task: Task<Void, Never>,
        state: KEYITranslationRequestState
    ) {
        self.id = id
        self.task = task
        self.state = state
    }

    public var isFinished: Bool {
        state.isFinished
    }

    /// 取消请求：关闭与服务端的连接，服务端据此取消在途翻译。
    public func cancel() {
        lock.lock()
        let task = task
        self.task = nil
        lock.unlock()
        state.cancel()
        task?.cancel()
    }
}
