import Foundation

public enum VolcengineResponsesAPI {
    public static func requestBody(
        model: String,
        text: String,
        sourceLanguage: String,
        targetLanguage: String
    ) throws -> Data {
        try JSONEncoder().encode(
            RequestPayload(
                model: model,
                input: [
                    InputMessage(
                        role: "user",
                        content: [
                            InputContent(
                                type: "input_text",
                                text: text,
                                translationOptions: TranslationOptions(
                                    sourceLanguage: languageCode(sourceLanguage),
                                    targetLanguage: languageCode(targetLanguage)
                                )
                            )
                        ]
                    )
                ]
            )
        )
    }

    public static func translatedText(from data: Data) throws -> String? {
        let response = try JSONDecoder().decode(ResponsePayload.self, from: data)
        let candidates = [response.outputText]
            + (response.output ?? []).flatMap { output in
                (output.content ?? []).compactMap { content in
                    guard content.type == nil || content.type == "output_text" else {
                        return nil
                    }
                    return content.text
                }
            }
        return candidates.compactMap { candidate in
            let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines)
            return text?.isEmpty == false ? text : nil
        }.first
    }

    private static func languageCode(_ language: String) -> String {
        language.lowercased().hasPrefix("zh") ? "zh" : language
    }
}

private struct RequestPayload: Encodable {
    let model: String
    let input: [InputMessage]
}

private struct InputMessage: Encodable {
    let role: String
    let content: [InputContent]
}

private struct InputContent: Encodable {
    let type: String
    let text: String
    let translationOptions: TranslationOptions

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case translationOptions = "translation_options"
    }
}

private struct TranslationOptions: Encodable {
    let sourceLanguage: String
    let targetLanguage: String

    private enum CodingKeys: String, CodingKey {
        case sourceLanguage = "source_language"
        case targetLanguage = "target_language"
    }
}

private struct ResponsePayload: Decodable {
    let outputText: String?
    let output: [OutputMessage]?

    private enum CodingKeys: String, CodingKey {
        case outputText = "output_text"
        case output
    }
}

private struct OutputMessage: Decodable {
    let content: [OutputContent]?
}

private struct OutputContent: Decodable {
    let type: String?
    let text: String?
}
