//
//  TranslationServiceContracts.swift
//  KEYI 可译 — 输入法翻译服务（阶段 02）
//
//  本文件冻结「服务端 socket 循环」与「宿主提供方实现」之间的接口。
//  由 Astra 定义；两侧实现都必须遵守，不要各自另发明一套。
//
//  依赖方向（禁止出现循环）：
//      KEYICore ─┐
//                ├─> KEYITranslationService ─> KEYIUI（宿主装配）
//      KEYITranslationClient ─┘
//  即：KEYITranslationService **不**依赖 KEYIUI；KEYIUI 依赖 KEYITranslationService，
//  在宿主侧提供 `TranslationServiceResolving` 的具体实现并启动服务。
//

import Foundation
import KEYICore
import KEYITranslationClient

/// Apple Translation 会话（系统翻译）的抽象。
///
/// 真实实现只能放在 KEYI 伴随应用进程里（KEYIUI 侧）：它需要 `Translation` 框架
/// 以及主线程上的 SwiftUI `translationTask` 来触发语言包安装。服务端 target
/// 只依赖这个协议，**绝不** import Translation。
public protocol AppleTranslationSessionProviding: Sendable {
    /// 翻译一句文本；`sourceLanguage` 为 `auto` 时表示由宿主自行判定源语言。
    /// 未安装语言对时必须抛错，由调用方映射成 `unavailableProvider`。
    func translate(
        text: String,
        sourceLanguage: String,
        targetLanguage: String,
        timeoutSeconds: Double
    ) async throws -> String

    /// 与服务请求关联的重载。旧实现可继续实现上面的入口；默认实现会转发，
    /// 需要请求级诊断的宿主可覆盖此方法。
    func translate(
        text: String,
        sourceLanguage: String,
        targetLanguage: String,
        timeoutSeconds: Double,
        requestID: String
    ) async throws -> String
}

public extension AppleTranslationSessionProviding {
    func translate(
        text: String,
        sourceLanguage: String,
        targetLanguage: String,
        timeoutSeconds: Double,
        requestID: String
    ) async throws -> String {
        try await translate(
            text: text,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            timeoutSeconds: timeoutSeconds
        )
    }
}

/// 仅用于诊断日志的错误元数据；不包含 localizedDescription 或错误正文。
public struct TranslationServiceErrorMetadata: Equatable, Sendable {
    public let typeName: String
    public let domain: String
    public let code: Int

    public init(_ error: Error) {
        let nsError = error as NSError
        typeName = Self.safeLogToken(String(reflecting: type(of: error)))
        domain = Self.safeLogToken(nsError.domain)
        code = nsError.code
    }

    /// 限制日志 token 字符与长度，避免把任意协议字段当作原始日志内容写出。
    public static func safeLogToken(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        let scalars = value.unicodeScalars.prefix(96)
        let token = String(String.UnicodeScalarView(scalars.map { allowed.contains($0) ? $0 : "_" }))
        return token.isEmpty ? "unknown" : token
    }
}

/// 系统翻译在本机不可用（例如语言包未安装）。
///
/// 宿主实现抛这个错误时，`KEYITranslationResolver` 会把它映射成线协议的
/// `unavailableProvider`，而不是笼统的 `providerError`，让输入法侧能给出
/// 「去系统设置安装语言包」这类可操作提示。
public struct AppleTranslationUnavailableError: Error, LocalizedError, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// 一次翻译的结果。
public struct TranslationServiceTranslation: Sendable {
    public let text: String
    /// 实际使用的提供方，便于证据记录与排错。
    public let providerID: String
    /// 提供方耗时（秒）。
    public let elapsedSeconds: Double

    public init(text: String, providerID: String, elapsedSeconds: Double) {
        self.text = text
        self.providerID = providerID
        self.elapsedSeconds = elapsedSeconds
    }
}

/// 服务端把请求交给宿主实现的入口。
///
/// 宿主实现负责：读取已保存的提供方/语言/语气/配置、读取凭据（仅宿主进程内，
/// 协议不传密钥）、按 providerID 分派到 `OpenAICompatibleTranslationProvider`、
/// `LocalModelTranslationProvider` 或 `AppleTranslationSessionProviding`。
public protocol TranslationServiceResolving: Sendable {
    /// 执行一次翻译。请求里的 nil 字段表示“沿用已保存配置”。
    func translate(_ request: TranslationServiceRequest) async throws -> TranslationServiceTranslation

    /// 报告当前可用的提供方列表与已选中的提供方。
    func status() async -> TranslationServiceStatus
}

/// 宿主实现应抛出的错误；服务端据此选择线协议错误码。
public enum TranslationServiceResolutionError: Error, Sendable, Equatable {
    /// 提供方未配置（缺 Key、缺 endpoint 等）。
    case notConfigured(String)
    /// 提供方在本机不可用（例如系统翻译语言包没装）。
    case unavailableProvider(String)
    /// 请求内容不合法（空文本、未知语言/语气、文本过长等）。
    case badRequest(String)
    /// 提供方自身报错（HTTP 失败、模型错误等）。
    case providerFailure(String)

    public var wireCode: TranslationServiceErrorCode {
        switch self {
        case .notConfigured: .notConfigured
        case .unavailableProvider: .unavailableProvider
        case .badRequest: .badRequest
        case .providerFailure: .providerError
        }
    }

    public var message: String {
        switch self {
        case let .notConfigured(message),
             let .unavailableProvider(message),
             let .badRequest(message),
             let .providerFailure(message):
            message
        }
    }
}

/// 请求校验：服务端在交给宿主实现之前先做一次廉价检查，
/// 宿主实现可再做一次，避免把明显无效的请求送到网络或系统框架。
public enum TranslationServiceRequestValidator {
    public static let maximumTextUTF8Bytes = 8 * 1024

    public static func validate(_ request: TranslationServiceRequest) throws {
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw TranslationServiceResolutionError.badRequest("请求文本为空")
        }
        guard request.text.utf8.count <= maximumTextUTF8Bytes else {
            throw TranslationServiceResolutionError.badRequest(
                "请求文本超过 \(maximumTextUTF8Bytes) 字节上限"
            )
        }
        if let context = request.contextText,
           context.utf8.count > maximumTextUTF8Bytes {
            throw TranslationServiceResolutionError.badRequest(
                "上下文文本超过 \(maximumTextUTF8Bytes) 字节上限"
            )
        }
    }
}

/// 把宿主错误统一映射成线协议错误。
public enum TranslationServiceErrorMapper {
    public static func map(_ error: Error) -> (TranslationServiceErrorCode, String) {
        if let resolution = error as? TranslationServiceResolutionError {
            return (resolution.wireCode, resolution.message)
        }
        if error is CancellationError {
            return (.cancelled, "翻译已取消")
        }
        return (.providerError, error.localizedDescription)
    }
}
