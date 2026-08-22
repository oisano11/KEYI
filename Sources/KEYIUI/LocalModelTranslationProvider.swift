import Foundation
import KEYICore

struct LocalModelTranslationProvider: TranslationProvider {
    let id: TranslationProviderID = .localModel
    private let configuration: LocalModelConfiguration

    init(configuration: LocalModelConfiguration) {
        self.configuration = configuration
    }

    func translate(_ request: TextTranslationRequest) async throws -> String {
        guard !request.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalModelTranslationError.emptySource
        }

        let initialBudget = LocalModelCatalog.gemma4.completionTokenBudget
        let initialCompletion = try await completion(
            for: request,
            maxTokens: initialBudget
        )
        if let translation = Self.translation(from: initialCompletion) {
            return translation
        }

        if initialCompletion.finishReason == "length" {
            let retryCompletion = try await completion(
                for: request,
                maxTokens: initialBudget + 1024
            )
            if let translation = Self.translation(from: retryCompletion) {
                return translation
            }
            if retryCompletion.finishReason == "length" {
                throw LocalModelTranslationError.outputBudgetExhausted
            }
        }

        throw LocalModelTranslationError.emptyResponse
    }

    private func completion(
        for request: TextTranslationRequest,
        maxTokens: Int
    ) async throws -> LocalChatCompletionResponse.Choice {
        var urlRequest = URLRequest(url: configuration.endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 120
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer lm-studio", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try JSONEncoder().encode(
            LocalChatCompletionRequest(
                model: configuration.model,
                messages: [
                    LocalChatMessage(
                        role: "system",
                        content: TranslationPromptBuilder.localSystemPrompt(for: request)
                    ),
                    LocalChatMessage(
                        role: "user",
                        content: TranslationPromptBuilder.localUserPrompt(for: request)
                    )
                ],
                maxTokens: maxTokens
            )
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: urlRequest)
        } catch let error as URLError where error.code == .timedOut {
            throw LocalModelTranslationError.timeout
        } catch {
            throw LocalModelTranslationError.serviceUnavailable
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LocalModelTranslationError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = (try? JSONDecoder().decode(
                LocalModelErrorResponse.self,
                from: data
            ))?.error?.message
            throw LocalModelTranslationError.httpFailure(
                statusCode: httpResponse.statusCode,
                message: message
            )
        }

        let decoded: LocalChatCompletionResponse
        do {
            decoded = try JSONDecoder().decode(
                LocalChatCompletionResponse.self,
                from: data
            )
        } catch {
            throw LocalModelTranslationError.invalidResponse
        }

        guard let choice = decoded.choices.first else {
            throw LocalModelTranslationError.invalidResponse
        }
        return choice
    }

    private static func translation(
        from choice: LocalChatCompletionResponse.Choice
    ) -> String? {
        let content = cleanTranslation(choice.message.content)
        return content.isEmpty ? nil : content
    }

    private static func cleanTranslation(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("<think>"), let end = result.range(of: "</think>") {
            result.removeSubrange(result.startIndex..<end.upperBound)
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }
}

private struct LocalChatCompletionRequest: Encodable, Sendable {
    let model: String
    let messages: [LocalChatMessage]
    let temperature: Double = 0
    let seed: Int = 42
    let maxTokens: Int
    let stream: Bool = false

    private enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case seed
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

enum LocalModelTranslationError: LocalizedError {
    case emptySource
    case serviceUnavailable
    case timeout
    case invalidResponse
    case emptyResponse
    case outputBudgetExhausted
    case httpFailure(statusCode: Int, message: String?)

    var errorDescription: String? {
        let strings = InterfaceStrings.current
        return switch self {
        case .emptySource:
            strings.emptySource
        case .serviceUnavailable:
            strings.localModelServiceUnavailable
        case .timeout:
            strings.localModelTimeout
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
