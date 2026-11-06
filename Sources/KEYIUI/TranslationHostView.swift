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
        // Capture the dispatch identity in this view generation. A callback from
        // a cancelled session must never claim whatever request is current now.
        let requestID = model.systemTranslationHostRequestID
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text(model.strings.statusPreparing)
                .font(.callout)
        }
            .frame(width: 320, height: 100)
            .translationTask(model.translationConfiguration) { session in
                guard let requestID else {
                    logger.notice("System translation host callback ignored; reason=no_dispatch")
                    return
                }
                guard let request = model.activeTranslationRequest(id: requestID) else {
                    logger.notice("System translation host callback ignored; request_id=\(requestID.uuidString, privacy: .public); reason=stale_or_accepted")
                    return
                }
                guard request.providerID == .appleSystem else {
                    model.failTranslation(
                        id: request.id,
                        error: TranslationHostError.providerUnavailable
                    )
                    return
                }
                let session = TranslationSessionBox(value: session)
                do {
                    try Task.checkCancellation()
                    logger.notice("Preparing system translation; request_id=\(request.id.uuidString, privacy: .public)")
                    try await session.value.prepareTranslation()
                    try Task.checkCancellation()
                    logger.notice("Translating source text; request_id=\(request.id.uuidString, privacy: .public)")
                    let response = try await session.value.translate(request.sourceText)
                    try Task.checkCancellation()
                    await model.completeTranslation(
                        id: request.id,
                        translatedText: response.targetText
                    )
                } catch {
                    model.failTranslation(id: request.id, error: error)
                }
            }
            .id(requestID)
    }
}

private enum TranslationHostError: LocalizedError {
    case providerUnavailable

    var errorDescription: String? {
        InterfaceStrings.current.providerUnavailable
    }
}
