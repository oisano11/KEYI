//
//  KEYITranslationAppleSession.swift
//  KEYI 可译 — Apple Translation（系统翻译）会话提供者（阶段 02）
//
//  会话生命周期留在 KEYI 可译进程内，输入法进程只通过 socket 请求。
//  实现 `AppleTranslationSessionProviding`（定义在 KEYITranslationService）。
//
//  实测约束（见 /tmp/02-apple-evidence.md）：
//  - 本机 zh-Hans → en 语言包已安装；`prepareTranslation()` 约 3–8 ms；
//    同一 session 可连续翻译多句。
//  - 未安装语言对时抛 `TranslationError.notInstalled`，且 `canRequestDownloads`
//    恒为 false，不会自动下载。触发下载必须走主进程 SwiftUI `translationTask`
//    （`TranslationHostView`），本文件不负责。
//

import Foundation
import KEYICore
import KEYITranslationClient
import KEYITranslationService
import OSLog
import Translation

/// `TranslationSession` 不是 `Sendable`；跨 `@Sendable` 闭包传递时用这个盒子显式标注。
struct AppleTranslationSessionBox: @unchecked Sendable {
    let value: TranslationSession
}

/// Cache bookkeeping is independent of Apple's non-comparable session type so its
/// identity and stale-write behavior can be exercised without creating a session.
struct AppleTranslationSessionCache<Value> {
    struct Entry {
        let identity: UUID
        let value: Value
    }

    private(set) var entries: [String: Entry] = [:]
    private var latestPreparationByKey: [String: UUID] = [:]

    func entry(for key: String) -> Entry? {
        entries[key]
    }

    mutating func beginPreparation(for key: String) -> UUID {
        let identity = UUID()
        latestPreparationByKey[key] = identity
        return identity
    }

    /// Returns the prepared entry to its caller even if a newer preparation won
    /// the cache race; only the newest in-flight preparation may update the cache.
    @discardableResult
    mutating func finishPreparation(
        for key: String,
        identity: UUID,
        value: Value
    ) -> Entry {
        let entry = Entry(identity: identity, value: value)
        guard latestPreparationByKey[key] == identity else { return entry }
        entries[key] = entry
        latestPreparationByKey.removeValue(forKey: key)
        return entry
    }

    mutating func failPreparation(for key: String, identity: UUID) {
        guard latestPreparationByKey[key] == identity else { return }
        latestPreparationByKey.removeValue(forKey: key)
    }

    /// Compare-and-remove ensures a failed old session cannot evict a newer one.
    @discardableResult
    mutating func removeEntry(for key: String, matching identity: UUID) -> Bool {
        guard entries[key]?.identity == identity else { return false }
        entries.removeValue(forKey: key)
        return true
    }
}

/// Apple Translation 会话池。
///
/// 说明：`TranslationSession(installedSource:target:)` 在已安装语言对下无需 UI，
/// 因此这里用普通 actor 串行化会话创建与复用；未安装语言对直接报错，
/// 不阻塞、不假装成功。
actor KEYITranslationAppleSessionPool {
    static let shared = KEYITranslationAppleSessionPool()

    private let logger = Logger(
        subsystem: "com.keyi.input-translator",
        category: "AppleTranslationSession"
    )
    private var sessions = AppleTranslationSessionCache<TranslationSession>()

    func translate(
        text: String,
        sourceLanguage: String,
        targetLanguage: String,
        timeoutSeconds: Double
    ) async throws -> String {
        try await translate(
            text: text,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            timeoutSeconds: timeoutSeconds,
            requestID: "untracked"
        )
    }

    func translate(
        text: String,
        sourceLanguage: String,
        targetLanguage: String,
        timeoutSeconds: Double,
        requestID rawRequestID: String
    ) async throws -> String {
        // 与服务端、客户端共用同一套超时规范化规则，防止极大值转纳秒溢出。
        let timeoutSeconds = TranslationServiceProtocol.normalizedTimeoutSeconds(
            timeoutSeconds
        ) ?? TranslationServiceProtocol.defaultTimeoutSeconds
        let requestID = TranslationServiceErrorMetadata.safeLogToken(rawRequestID)
        let source = Self.resolveSourceLanguage(sourceLanguage)
        guard !targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppleTranslationSessionError.unsupportedLanguagePair(
                source: source.minimalIdentifier,
                target: targetLanguage
            )
        }
        let target = Locale.Language(identifier: targetLanguage)

        let availability = LanguageAvailability()
        let requestStarted = Date()
        let availabilityStarted = Date()
        logger.info(
            "translation_event=apple_stage_started request_id=\(requestID, privacy: .public) stage=availability source_language=\(source.minimalIdentifier, privacy: .public) target_language=\(target.minimalIdentifier, privacy: .public)"
        )
        let status = await availability.status(from: source, to: target)
        logger.info(
            "translation_event=apple_stage_completed request_id=\(requestID, privacy: .public) stage=availability status=\(Self.describe(status), privacy: .public) source_language=\(source.minimalIdentifier, privacy: .public) target_language=\(target.minimalIdentifier, privacy: .public) stage_elapsed_ms=\(Int(Date().timeIntervalSince(availabilityStarted) * 1000), privacy: .public) total_elapsed_ms=\(Int(Date().timeIntervalSince(requestStarted) * 1000), privacy: .public)"
        )
        guard status == .installed else {
            let error = AppleTranslationSessionError.languagePairNotInstalled(
                source: source.minimalIdentifier,
                target: target.minimalIdentifier,
                status: Self.describe(status)
            )
            logFailure(
                requestID: requestID,
                stage: "availability",
                source: source,
                target: target,
                error: error,
                stageStarted: availabilityStarted,
                requestStarted: requestStarted
            )
            throw error
        }

        let sessionEntry = try await session(
            for: source,
            target: target,
            requestID: requestID,
            requestStarted: requestStarted
        )
        let sessionBox = AppleTranslationSessionBox(value: sessionEntry.value)
        let translateStarted = Date()
        logger.info(
            "translation_event=apple_stage_started request_id=\(requestID, privacy: .public) stage=translate source_language=\(source.minimalIdentifier, privacy: .public) target_language=\(target.minimalIdentifier, privacy: .public)"
        )
        do {
            let response = try await withTimeout(seconds: timeoutSeconds) {
                try await sessionBox.value.translate(text)
            }
            let translated = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !translated.isEmpty else {
                throw AppleTranslationSessionError.emptyResult(
                    source: source.minimalIdentifier,
                    target: target.minimalIdentifier
                )
            }
            logger.info(
                "translation_event=apple_stage_completed request_id=\(requestID, privacy: .public) stage=translate source_language=\(source.minimalIdentifier, privacy: .public) target_language=\(target.minimalIdentifier, privacy: .public) stage_elapsed_ms=\(Int(Date().timeIntervalSince(translateStarted) * 1000), privacy: .public) total_elapsed_ms=\(Int(Date().timeIntervalSince(requestStarted) * 1000), privacy: .public)"
            )
            return translated
        } catch is TimeoutError {
            _ = sessions.removeEntry(
                for: Self.cacheKey(source, target),
                matching: sessionEntry.identity
            )
            logFailure(
                requestID: requestID,
                stage: "translate",
                source: source,
                target: target,
                error: TimeoutError(),
                stageStarted: translateStarted,
                requestStarted: requestStarted
            )
            throw AppleTranslationSessionError.timedOut(seconds: timeoutSeconds)
        } catch let error as TranslationError where Self.isNotInstalled(error) {
            _ = sessions.removeEntry(
                for: Self.cacheKey(source, target),
                matching: sessionEntry.identity
            )
            logFailure(
                requestID: requestID,
                stage: "translate",
                source: source,
                target: target,
                error: error,
                stageStarted: translateStarted,
                requestStarted: requestStarted
            )
            throw AppleTranslationSessionError.languagePairNotInstalled(
                source: source.minimalIdentifier,
                target: target.minimalIdentifier,
                status: "notInstalled"
            )
        } catch {
            logFailure(
                requestID: requestID,
                stage: "translate",
                source: source,
                target: target,
                error: error,
                stageStarted: translateStarted,
                requestStarted: requestStarted
            )
            throw error
        }
    }

    func statusSummary() async -> String {
        let availability = LanguageAvailability()
        let source = Locale.Language(identifier: "zh-Hans")
        var parts: [String] = []
        for identifier in ["en", "ja", "ko", "fr", "de", "es", "ru"] {
            let target = Locale.Language(identifier: identifier)
            let status = await availability.status(from: source, to: target)
            parts.append("zh-Hans->\(identifier): \(Self.describe(status))")
        }
        return parts.joined(separator: "; ")
    }

    private func session(
        for source: Locale.Language,
        target: Locale.Language,
        requestID: String,
        requestStarted: Date
    ) async throws -> AppleTranslationSessionCache<TranslationSession>.Entry {
        let key = Self.cacheKey(source, target)
        if let existing = sessions.entry(for: key) {
            logger.info(
                "translation_event=apple_session_reused request_id=\(requestID, privacy: .public) source_language=\(source.minimalIdentifier, privacy: .public) target_language=\(target.minimalIdentifier, privacy: .public) total_elapsed_ms=\(Int(Date().timeIntervalSince(requestStarted) * 1000), privacy: .public)"
            )
            return existing
        }
        guard #available(macOS 26.0, *) else {
            // `init(installedSource:target:)` 需要 macOS 26；更早系统上按未安装处理，
            // 由主进程的 SwiftUI `translationTask` 路径负责。
            throw AppleTranslationSessionError.requiresMacOS26
        }
        let preparationIdentity = sessions.beginPreparation(for: key)
        let session = TranslationSession(installedSource: source, target: target)
        let prepareStarted = Date()
        logger.info(
            "translation_event=apple_stage_started request_id=\(requestID, privacy: .public) stage=prepare source_language=\(source.minimalIdentifier, privacy: .public) target_language=\(target.minimalIdentifier, privacy: .public)"
        )
        do {
            try await session.prepareTranslation()
        } catch {
            sessions.failPreparation(for: key, identity: preparationIdentity)
            logFailure(
                requestID: requestID,
                stage: "prepare",
                source: source,
                target: target,
                error: error,
                stageStarted: prepareStarted,
                requestStarted: requestStarted
            )
            if let translationError = error as? TranslationError,
               Self.isNotInstalled(translationError) {
                throw AppleTranslationSessionError.languagePairNotInstalled(
                    source: source.minimalIdentifier,
                    target: target.minimalIdentifier,
                    status: "notInstalled"
                )
            }
            throw error
        }
        logger.info(
            "translation_event=apple_stage_completed request_id=\(requestID, privacy: .public) stage=prepare source_language=\(source.minimalIdentifier, privacy: .public) target_language=\(target.minimalIdentifier, privacy: .public) stage_elapsed_ms=\(Int(Date().timeIntervalSince(prepareStarted) * 1000), privacy: .public) total_elapsed_ms=\(Int(Date().timeIntervalSince(requestStarted) * 1000), privacy: .public)"
        )
        return sessions.finishPreparation(
            for: key,
            identity: preparationIdentity,
            value: session
        )
    }

    private func logFailure(
        requestID: String,
        stage: String,
        source: Locale.Language,
        target: Locale.Language,
        error: Error,
        stageStarted: Date,
        requestStarted: Date
    ) {
        let metadata = TranslationServiceErrorMetadata(error)
        let errorCategory = Self.errorCategory(error)
        logger.error(
            "translation_event=apple_stage_failed request_id=\(requestID, privacy: .public) stage=\(stage, privacy: .public) source_language=\(source.minimalIdentifier, privacy: .public) target_language=\(target.minimalIdentifier, privacy: .public) error_type=\(metadata.typeName, privacy: .public) error_domain=\(metadata.domain, privacy: .public) error_code=\(metadata.code, privacy: .public) apple_error_category=\(errorCategory, privacy: .public) stage_elapsed_ms=\(Int(Date().timeIntervalSince(stageStarted) * 1000), privacy: .public) total_elapsed_ms=\(Int(Date().timeIntervalSince(requestStarted) * 1000), privacy: .public)"
        )
    }

    private static func cacheKey(
        _ source: Locale.Language,
        _ target: Locale.Language
    ) -> String {
        "\(source.minimalIdentifier)|\(target.minimalIdentifier)"
    }

    /// NSError 桥接数字码不能区分 TranslationError；只匹配公开的类型常量。
    static func errorCategory(_ error: Error) -> String {
        guard let error = error as? TranslationError else {
            return "not_translation_error"
        }
        if #available(macOS 26.0, *) {
            if TranslationError.notInstalled ~= error { return "not_installed" }
            if TranslationError.alreadyCancelled ~= error { return "already_cancelled" }
        }
        switch error {
        case TranslationError.internalError: return "internal_error"
        case TranslationError.nothingToTranslate: return "nothing_to_translate"
        case TranslationError.unableToIdentifyLanguage: return "unable_to_identify_language"
        case TranslationError.unsupportedSourceLanguage: return "unsupported_source_language"
        case TranslationError.unsupportedTargetLanguage: return "unsupported_target_language"
        case TranslationError.unsupportedLanguagePairing: return "unsupported_language_pairing"
        default: return "unknown_translation_error"
        }
    }

    private static func isNotInstalled(_ error: TranslationError) -> Bool {
        errorCategory(error) == "not_installed"
    }

    /// KEYI 的主用例是中文 → 外文；请求方未指定源语言时按中文处理。
    private static func resolveSourceLanguage(_ raw: String) -> Locale.Language {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "auto" else {
            return Locale.Language(identifier: "zh-Hans")
        }
        return Locale.Language(identifier: trimmed)
    }

    private static func describe(_ status: LanguageAvailability.Status) -> String {
        switch status {
        case .installed: "installed"
        case .supported: "supported"
        case .unsupported: "unsupported"
        @unknown default: "unknown"
        }
    }
}

/// 供 resolver 使用的注入点。
final class KEYITranslationAppleSession: AppleTranslationSessionProviding, @unchecked Sendable {
    static let shared = KEYITranslationAppleSession()

    func translate(
        text: String,
        sourceLanguage: String,
        targetLanguage: String,
        timeoutSeconds: Double
    ) async throws -> String {
        try await translate(
            text: text,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            timeoutSeconds: timeoutSeconds,
            requestID: "untracked"
        )
    }

    func translate(
        text: String,
        sourceLanguage: String,
        targetLanguage: String,
        timeoutSeconds: Double,
        requestID: String
    ) async throws -> String {
        do {
            return try await KEYITranslationAppleSessionPool.shared.translate(
                text: text,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                timeoutSeconds: timeoutSeconds,
                requestID: requestID
            )
        } catch let error as AppleTranslationSessionError {
            switch error {
            case .languagePairNotInstalled, .unsupportedLanguagePair, .requiresMacOS26:
                throw AppleTranslationUnavailableError(
                    error.errorDescription ?? "系统翻译不可用"
                )
            case .timedOut, .emptyResult:
                throw error
            }
        }
    }

    func statusSummary() async -> String {
        await KEYITranslationAppleSessionPool.shared.statusSummary()
    }
}

enum AppleTranslationSessionError: LocalizedError, Equatable {
    case languagePairNotInstalled(source: String, target: String, status: String)
    case unsupportedLanguagePair(source: String, target: String)
    case timedOut(seconds: Double)
    case emptyResult(source: String, target: String)
    case requiresMacOS26

    var errorDescription: String? {
        switch self {
        case let .languagePairNotInstalled(source, target, status):
            "系统翻译的 \(source) → \(target) 语言包尚未安装（当前状态：\(status)）；请在「系统设置 → 通用 → 语言与地区 → 翻译语言」中安装后重试。"
        case let .unsupportedLanguagePair(source, target):
            "系统翻译不支持 \(source) → \(target)。"
        case let .timedOut(seconds):
            "系统翻译超时（超过 \(Int(seconds)) 秒）。"
        case let .emptyResult(source, target):
            "系统翻译返回了空结果（\(source) → \(target)）。"
        case .requiresMacOS26:
            "系统翻译会话需要 macOS 26 或更高版本。"
        }
    }
}
