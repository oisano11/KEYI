import Foundation
import HanYiCore

struct OpenAICompatibleTranslationProvider: TranslationProvider {
    let id: TranslationProviderID

    private let apiKey: String
    private let endpoint: URL
    private let model: String

    init(configuration: APIProviderConfiguration) {
        id = configuration.providerID
        apiKey = configuration.apiKey
        endpoint = configuration.endpoint
        model = configuration.model
    }

    func translate(_ request: TextTranslationRequest) async throws -> String {
        guard !request.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APITranslationError.emptySource
        }

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 45
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let usesVolcengineResponsesAPI = id == .volcengine
            && endpoint.path.hasSuffix("/responses")
        if usesVolcengineResponsesAPI {
            urlRequest.httpBody = try VolcengineResponsesAPI.requestBody(
                model: model,
                text: request.sourceText,
                sourceLanguage: request.sourceLanguage,
                targetLanguage: request.targetLanguage
            )
        } else {
            urlRequest.httpBody = try JSONEncoder().encode(
                ChatCompletionRequest(
                    model: model,
                    messages: [
                        ChatMessage(
                            role: "system",
                            content: TranslationPromptBuilder.systemPrompt(
                                for: request
                            )
                        ),
                        ChatMessage(
                            role: "user",
                            content: TranslationPromptBuilder.userPrompt(
                                for: request
                            )
                        )
                    ],
                    temperature: request.scene == .faithful ? 0 : 0.2
                )
            )
        }

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APITranslationError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = (try? JSONDecoder().decode(
                APIErrorResponse.self,
                from: data
            ))?.error?.message
            throw APITranslationError.httpFailure(
                providerName: id.displayName,
                statusCode: httpResponse.statusCode,
                message: message
            )
        }

        let content: String?
        do {
            if usesVolcengineResponsesAPI {
                content = try VolcengineResponsesAPI.translatedText(from: data)
            } else {
                content = try JSONDecoder().decode(
                    ChatCompletionResponse.self,
                    from: data
                ).choices.first?.message.content
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            throw APITranslationError.invalidResponse
        }
        guard let content, !content.isEmpty else {
            throw APITranslationError.emptyResponse(providerName: id.displayName)
        }
        return content
    }
}

private struct ChatCompletionRequest: Encodable, Sendable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
}

private struct ChatMessage: Codable, Sendable {
    let role: String
    let content: String
}

private struct ChatCompletionResponse: Decodable, Sendable {
    let choices: [Choice]

    struct Choice: Decodable, Sendable {
        let message: ChatMessage
    }
}

private struct APIErrorResponse: Decodable, Sendable {
    let error: ErrorPayload?

    struct ErrorPayload: Decodable, Sendable {
        let message: String?
    }
}

enum APITranslationError: LocalizedError {
    case emptySource
    case invalidResponse
    case emptyResponse(providerName: String)
    case httpFailure(providerName: String, statusCode: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .emptySource:
            return "没有可翻译的文本"
        case .invalidResponse:
            return "模型 API 返回了无效响应"
        case let .emptyResponse(providerName):
            return "\(providerName) 没有返回翻译结果"
        case let .httpFailure(providerName, statusCode, message):
            if let message, !message.isEmpty {
                return "\(providerName) 请求失败（\(statusCode)：\(message)）"
            }
            return "\(providerName) 请求失败（HTTP \(statusCode)）"
        }
    }
}
