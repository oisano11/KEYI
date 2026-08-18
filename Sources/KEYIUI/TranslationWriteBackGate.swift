import Foundation

@MainActor
enum TranslationWriteBackGate {
    static func requireActive(_ isActive: () -> Bool) throws {
        guard isActive() else { throw CancellationError() }
        try Task.checkCancellation()
    }
}
