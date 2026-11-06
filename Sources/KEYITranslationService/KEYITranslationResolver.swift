//
//  KEYITranslationResolver.swift
//  KEYI 可译 — 输入法翻译服务（阶段 02）
//
//  把线协议请求映射到 KEYI 已保存的提供方 / 语言 / 语气 / 凭据。
//  这里不引入 AppKit 或 SwiftUI；Apple Translation 通过
//  `AppleTranslationSessionProviding` 由宿主注入（真实会话在 KEYIUI 侧）。
//

import Foundation
import KEYICore
import KEYITranslationClient
import OSLog

public final class KEYITranslationResolver: TranslationServiceResolving, @unchecked Sendable {
    /// 已保存的偏好与配置读取入口（由宿主注入，避免服务端直接读 UserDefaults 规则）。
    public struct Configuration: Sendable {
        public let selectedProviderID: TranslationProviderID
        public let targetLanguage: TranslationLanguage
        public let scene: TranslationScene
        public let englishStyle: EnglishStyle
        public let providerIDs: [TranslationProviderID]

        public init(
            selectedProviderID: TranslationProviderID,
            targetLanguage: TranslationLanguage,
            scene: TranslationScene,
            englishStyle: EnglishStyle,
            providerIDs: [TranslationProviderID] = TranslationProviderCatalog.descriptors.map(\.id)
        ) {
            self.selectedProviderID = selectedProviderID
            self.targetLanguage = targetLanguage
            self.scene = scene
            self.englishStyle = englishStyle
            self.providerIDs = providerIDs
        }
    }

    private let logger = Logger(
        subsystem: "com.keyi.input-translator",
        category: "TranslationResolver"
    )
    private let configurationProvider: @Sendable () async -> Configuration
    private let apiProviderFactory: @Sendable (TranslationProviderID) async throws -> (any TranslationProvider)?
    private let localProviderFactory: @Sendable (TranslationLanguage) async throws -> (any TranslationProvider)?
    private let appleProvider: (any AppleTranslationSessionProviding)?

    public init(
        configuration: @escaping @Sendable () async -> Configuration,
        apiProvider: @escaping @Sendable (TranslationProviderID) async throws -> (any TranslationProvider)?,
        localProvider: @escaping @Sendable (TranslationLanguage) async throws -> (any TranslationProvider)? = { _ in nil },
        appleProvider: (any AppleTranslationSessionProviding)? = nil
    ) {
        configurationProvider = configuration
        apiProviderFactory = apiProvider
        localProviderFactory = localProvider
        self.appleProvider = appleProvider
    }

    public func status() async -> TranslationServiceStatus {
        // 每次 status 都重新读取最新保存配置；同一次请求内使用固定快照。
        let configuration = await configurationProvider()
        return TranslationServiceStatus(
            selectedProviderID: configuration.selectedProviderID.rawValue,
            providerIDs: configuration.providerIDs.map(\.rawValue)
        )
    }

    public func translate(
        _ request: TranslationServiceRequest
    ) async throws -> TranslationServiceTranslation {
        // 每次 translate 都重新读取最新保存配置；同一次请求内使用固定快照，
        // 避免处理中途混用新旧设置。
        let configuration = await configurationProvider()
        let providerID = try resolveProviderID(request.providerID, configuration: configuration)
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = try resolveTargetLanguage(request.targetLanguage, configuration: configuration)
        let sourceLanguage = normalizedSourceLanguage(
            request.sourceLanguage,
            target: target
        )
        let scene = resolveScene(request.scene, configuration: configuration)
        let englishStyle = resolveEnglishStyle(request.englishStyle, configuration: configuration)
        let started = Date()

        let requestID = TranslationServiceErrorMetadata.safeLogToken(request.id)
        logger.info(
            "translation_event=resolver_started request_id=\(requestID, privacy: .public) provider_id=\(providerID.rawValue, privacy: .public) source_language=\(TranslationServiceErrorMetadata.safeLogToken(sourceLanguage), privacy: .public) target_language=\(target.rawValue, privacy: .public)"
        )

        let translated: String
        switch providerID {
        case .appleSystem:
            guard let appleProvider else {
                throw TranslationServiceResolutionError.unavailableProvider(
                    "系统翻译会话未就绪（KEYI 可译主进程未提供 Apple Translation 会话）"
                )
            }
            do {
                translated = try await appleProvider.translate(
                    text: text,
                    sourceLanguage: sourceLanguage,
                    targetLanguage: target.rawValue,
                    timeoutSeconds: request.timeoutSeconds,
                    requestID: request.id
                )
            } catch let error as AppleTranslationUnavailableError {
                // 语言包缺失属于「提供方在本机不可用」，不是网络或模型失败。
                throw TranslationServiceResolutionError.unavailableProvider(
                    error.localizedDescription
                )
            }
        case .localModel:
            guard let provider = try await localProviderFactory(target) else {
                throw TranslationServiceResolutionError.notConfigured(
                    "本地模型尚未配置（KEYI 可译设置 → 本地模型）"
                )
            }
            translated = try await provider.translate(
                self.textRequest(
                    text: text,
                    context: request.contextText,
                    sourceLanguage: sourceLanguage,
                    target: target,
                    scene: scene,
                    englishStyle: englishStyle
                )
            )
        case .deepSeek, .qwen, .volcengine, .xAI, .relay:
            guard let provider = try await apiProviderFactory(providerID) else {
                throw TranslationServiceResolutionError.notConfigured(
                    "\(providerID.displayName) 尚未配置（KEYI 可译设置 → 提供方）"
                )
            }
            translated = try await provider.translate(
                self.textRequest(
                    text: text,
                    context: request.contextText,
                    sourceLanguage: sourceLanguage,
                    target: target,
                    scene: scene,
                    englishStyle: englishStyle
                )
            )
        }

        let trimmed = translated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TranslationServiceResolutionError.providerFailure(
                "\(providerID.displayName) 返回了空译文"
            )
        }
        let elapsed = Date().timeIntervalSince(started)
        logger.info(
            "translation_event=resolver_succeeded request_id=\(requestID, privacy: .public) provider_id=\(providerID.rawValue, privacy: .public) source_language=\(TranslationServiceErrorMetadata.safeLogToken(sourceLanguage), privacy: .public) target_language=\(target.rawValue, privacy: .public) elapsed_ms=\(Int(elapsed * 1000), privacy: .public)"
        )
        return TranslationServiceTranslation(
            text: trimmed,
            providerID: providerID.rawValue,
            elapsedSeconds: elapsed
        )
    }

    // MARK: - 参数解析

    private func resolveProviderID(
        _ raw: String?,
        configuration: Configuration
    ) throws -> TranslationProviderID {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, trimmed != "auto" else {
            return configuration.selectedProviderID
        }
        guard let providerID = TranslationProviderID(rawValue: trimmed),
              TranslationProviderCatalog.descriptor(for: providerID).isAvailable else {
            throw TranslationServiceResolutionError.badRequest(
                "未知或不支持的提供方：\(trimmed)"
            )
        }
        return providerID
    }

    private func resolveTargetLanguage(
        _ raw: String?,
        configuration: Configuration
    ) throws -> TranslationLanguage {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, trimmed != "auto" else {
            return configuration.targetLanguage
        }
        guard let language = TranslationLanguage(rawValue: trimmed) else {
            throw TranslationServiceResolutionError.badRequest(
                "未知的目标语言：\(trimmed)"
            )
        }
        return language
    }

    private func resolveScene(
        _ raw: String?,
        configuration: Configuration
    ) -> TranslationScene {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              let scene = TranslationScene(rawValue: raw) else {
            return configuration.scene
        }
        return scene
    }

    private func resolveEnglishStyle(
        _ raw: String?,
        configuration: Configuration
    ) -> EnglishStyle {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              let style = EnglishStyle(rawValue: raw) else {
            return configuration.englishStyle
        }
        return style
    }

    /// 目标语言就是中文时，源语言交给提供方自动判定；否则沿用请求值或中文。
    private func normalizedSourceLanguage(
        _ raw: String?,
        target: TranslationLanguage
    ) -> String {
        if target == .chinese { return "auto" }
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "zh-Hans" : trimmed
    }

    private func textRequest(
        text: String,
        context: String?,
        sourceLanguage: String,
        target: TranslationLanguage,
        scene: TranslationScene,
        englishStyle: EnglishStyle
    ) -> TextTranslationRequest {
        TextTranslationRequest(
            sourceText: text,
            contextText: context,
            sourceLanguage: sourceLanguage,
            targetLanguage: target,
            scene: scene,
            englishStyle: englishStyle
        )
    }
}
