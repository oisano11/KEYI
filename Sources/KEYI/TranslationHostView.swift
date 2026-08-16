import OSLog
import SwiftUI
import Translation
import KEYICore

private let logger = Logger(
    subsystem: "com.keyi.input-translator",
    category: "TranslationHost"
)

private struct TranslationSessionBox: @unchecked Sendable {
    let value: TranslationSession
}

struct TranslationHostView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(model.translationConfiguration) { session in
                guard let request = model.activeTranslationRequest() else { return }
                guard request.providerID == .appleSystem else {
                    model.failTranslation(
                        id: request.id,
                        error: TranslationHostError.providerUnavailable
                    )
                    return
                }
                let session = TranslationSessionBox(value: session)
                do {
                    logger.info("Preparing system translation")
                    try await session.value.prepareTranslation()
                    logger.info("Translating source text")
                    let response = try await session.value.translate(request.sourceText)
                    await model.completeTranslation(
                        id: request.id,
                        translatedText: response.targetText
                    )
                } catch {
                    model.failTranslation(id: request.id, error: error)
                }
            }
    }
}

private enum TranslationHostError: LocalizedError {
    case providerUnavailable

    var errorDescription: String? {
        "当前翻译提供方暂不可用"
    }
}
