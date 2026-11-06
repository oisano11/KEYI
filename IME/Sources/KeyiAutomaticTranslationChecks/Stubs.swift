//
//  Stubs.swift
//  控制器检查用的替身：翻译请求、取消句柄、假时钟。
//

import Foundation
import KEYITranslationClient
import KeyiIMETranslation

/// 可控翻译请求替身：记录每次请求，由检查决定何时成功或失败。
final class StubTranslation {
    private(set) var requests: [TranslationServiceRequest] = []
    private var completions: [(Result<String, Error>) -> Void] = []
    private var pendingIndexes = Set<Int>()
    private(set) var cancelledIndexes = Set<Int>()

    var count: Int { requests.count }
    var texts: [String] { requests.map(\.text) }

    func translate(
        _ request: TranslationServiceRequest,
        completion: @escaping @Sendable (Result<String, Error>) -> Void
    ) -> KeyiTranslationCancellable {
        let index = requests.count
        requests.append(request)
        completions.append(completion)
        pendingIndexes.insert(index)
        return StubCancellable { [weak self] in
            self?.cancelledIndexes.insert(index)
            self?.pendingIndexes.remove(index)
        }
    }

    /// 完成指定的（默认最后一个）尚未完成、未取消的请求。
    @discardableResult
    func finish(_ result: Result<String, Error>, request index: Int? = nil) -> Bool {
        guard let target = index ?? pendingIndexes.max(), pendingIndexes.contains(target) else { return false }
        pendingIndexes.remove(target)
        completions[target](result)
        return true
    }

    /// 无视取消状态把结果投递给第 `index` 个请求，模拟取消后才到的迟到回调。
    func deliverLate(_ result: Result<String, Error>, request index: Int) {
        guard completions.indices.contains(index) else {
            expect(false, "stub: request \(index) was never sent")
            return
        }
        completions[index](result)
    }

    func wasCancelled(_ index: Int) -> Bool { cancelledIndexes.contains(index) }
}

final class StubCancellable: KeyiTranslationCancellable {
    private let onCancel: () -> Void
    init(onCancel: @escaping () -> Void = {}) { self.onCancel = onCancel }
    func cancel() { onCancel() }
}

/// 假时钟：同时是控制器的调度器。`advance` 推进虚拟时间并执行到期任务，被取消的任务不执行。
final class FakeClock: KeyiAutomaticTranslationScheduler {
    private final class Scheduled: KeyiTranslationCancellable {
        let deadline: TimeInterval
        var action: (@Sendable () -> Void)?
        init(deadline: TimeInterval, action: @escaping @Sendable () -> Void) {
            self.deadline = deadline
            self.action = action
        }
        func cancel() { action = nil }
    }

    private var scheduled: [Scheduled] = []
    var now: TimeInterval = 0

    @discardableResult
    func schedule(after delay: TimeInterval, action: @escaping @Sendable () -> Void) -> KeyiTranslationCancellable {
        let item = Scheduled(deadline: now + delay, action: action)
        scheduled.append(item)
        return item
    }

    func advance(_ seconds: TimeInterval) {
        now += seconds
        let due = scheduled.filter { $0.deadline <= now }
        scheduled.removeAll { $0.deadline <= now }
        for entry in due { entry.action?() }
    }
}

struct StubError: Error {}
