import Foundation
import KEYICore

/// 本地模型通道：把一条 Hy-MT2 提示词交给 KEYI 自带的 llama-server。
struct LocalModelTranslationProvider: TranslationProvider {
    /// 发出一次 chat completion 请求并返回原始响应；测试里替换成桩。
    typealias Transport = @Sendable (_ body: Data) async throws -> LocalModelHTTPResponse

    /// 服务刚启动、模型还在后台加载时，一次翻译最多等这么久。
    static let readyTimeout: Duration = .seconds(10)
    static let requestTimeout: Duration = .seconds(60)

    let id: TranslationProviderID = .localModel
    private let model: LocalTranslationModel
    private let transport: Transport

    init(model: LocalTranslationModel, transport: @escaping Transport) {
        self.model = model
        self.transport = transport
    }

    /// 连自带服务：主应用和翻译服务子进程都经运行目录里的 socket 与密钥找到它。
    static func bundled(model: LocalTranslationModel) -> LocalModelTranslationProvider {
        LocalModelTranslationProvider(model: model) { body in
            let endpoint = try await LocalModelConnection.readyEndpoint(waitingUpTo: readyTimeout)
            return try await LocalModelHTTPClient.send(
                "POST", "/v1/chat/completions",
                body: body,
                to: endpoint,
                timeout: requestTimeout
            )
        }
    }

    func translate(_ request: TextTranslationRequest) async throws -> String {
        guard !request.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalModelTranslationError.emptySource
        }
        let sampling = LocalTranslationModelCatalog.sampling
        let body = try JSONEncoder().encode(LocalChatCompletionRequest(
            messages: [LocalChatMessage(
                role: "user",
                content: HyMTPromptBuilder.userMessage(for: request, model: model)
            )],
            temperature: sampling.temperature,
            topP: sampling.topP,
            topK: sampling.topK,
            repeatPenalty: sampling.repeatPenalty,
            maxTokens: sampling.maxTokens
        ))
        let response = try await transport(body)

        guard (200..<300).contains(response.status) else {
            let message = (try? JSONDecoder().decode(
                LocalModelErrorResponse.self,
                from: response.body
            ))?.error?.message
            throw LocalModelTranslationError.httpFailure(
                statusCode: response.status,
                message: message
            )
        }
        guard let choice = (try? JSONDecoder().decode(
            LocalChatCompletionResponse.self,
            from: response.body
        ))?.choices.first else {
            throw LocalModelTranslationError.invalidResponse
        }
        // 截断的半句话不交给写回层。
        guard choice.finishReason != "length" else {
            throw LocalModelTranslationError.outputBudgetExhausted
        }
        let translation = choice.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !translation.isEmpty else {
            throw LocalModelTranslationError.emptyResponse
        }
        return translation
    }
}

private struct LocalChatCompletionRequest: Encodable, Sendable {
    let messages: [LocalChatMessage]
    let temperature: Double
    let topP: Double
    let topK: Int
    let repeatPenalty: Double
    let maxTokens: Int
    let stream: Bool = false

    private enum CodingKeys: String, CodingKey {
        case messages
        case temperature
        case topP = "top_p"
        case topK = "top_k"
        case repeatPenalty = "repeat_penalty"
        case maxTokens = "max_tokens"
        case stream
    }
}

private struct LocalChatMessage: Codable, Sendable {
    let role: String
    let content: String
}

private struct LocalChatCompletionResponse: Decodable, Sendable {
    let choices: [Choice]

    struct Choice: Decodable, Sendable {
        let message: LocalChatMessage
        let finishReason: String?

        private enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }
}

private struct LocalModelErrorResponse: Decodable, Sendable {
    let error: ErrorPayload?

    struct ErrorPayload: Decodable, Sendable {
        let message: String?
    }
}

enum LocalModelTranslationError: LocalizedError, Equatable {
    case emptySource
    case modelNotInstalled
    case invalidResponse
    case emptyResponse
    case outputBudgetExhausted
    case httpFailure(statusCode: Int, message: String?)

    var errorDescription: String? {
        let strings = InterfaceStrings.current
        return switch self {
        case .emptySource:
            strings.emptySource
        case .modelNotInstalled:
            strings.localModelNotInstalled
        case .invalidResponse:
            strings.localModelInvalidResponse
        case .emptyResponse:
            strings.localModelEmptyResponse
        case .outputBudgetExhausted:
            strings.localModelOutputTooLong
        case let .httpFailure(statusCode, message):
            strings.localModelRequestFailed(statusCode, detail: message)
        }
    }
}
