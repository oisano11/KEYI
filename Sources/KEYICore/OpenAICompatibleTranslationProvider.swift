import Foundation

public struct APIProviderConfiguration: Sendable {
    public let providerID: TranslationProviderID
    public let apiKey: String
    public let endpoint: URL
    public let model: String

    public init(
        providerID: TranslationProviderID,
        apiKey: String,
        endpoint: URL,
        model: String
    ) {
        self.providerID = providerID
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.model = model
    }
}

public struct OpenAICompatibleTranslationProvider: TranslationProvider {
    public let id: TranslationProviderID

    private let apiKey: String
    private let endpoint: URL
    private let model: String
    private let session: URLSession

    public init(
        configuration: APIProviderConfiguration,
        session: URLSession = .shared
    ) {
        id = configuration.providerID
        apiKey = configuration.apiKey
        endpoint = configuration.endpoint
        model = configuration.model
        self.session = session
    }

    public func translate(_ request: TextTranslationRequest) async throws -> String {
        guard !request.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APITranslationError.emptySource
        }

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 45
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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

        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APITranslationError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = (try? JSONDecoder().decode(
                APIErrorResponse.self,
                from: data
            ))?.error?.message
            throw APITranslationError.httpFailure(
                providerID: id,
                statusCode: httpResponse.statusCode,
                message: message
            )
        }

        let content: String?
        do {
            content = try JSONDecoder().decode(
                ChatCompletionResponse.self,
                from: data
            ).choices.first?.message.content
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw APITranslationError.invalidResponse
        }
        guard let content, !content.isEmpty else {
            throw APITranslationError.emptyResponse(providerID: id)
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

/// 云端提供方错误只携带结构化数据；用户可见文案由 UI 层
/// （InterfaceLocalization 的扩展）按当前界面语言渲染。
public enum APITranslationError: Error {
    case emptySource
    case invalidResponse
    case emptyResponse(providerID: TranslationProviderID)
    case httpFailure(
        providerID: TranslationProviderID,
        statusCode: Int,
        message: String?
    )
}
