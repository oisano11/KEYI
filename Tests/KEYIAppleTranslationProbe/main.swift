import AppKit
import Foundation
import KEYICore
import KEYITranslationClient
import KEYITranslationService
import Translation
@testable import KEYIUI

private let fixedTestText = "今天天气不错，我们去公园散步吧。"

private enum ProbeError: Error {
    case unexpectedProviderAccess
    case listenerDidNotStart
    case legacyProviderEntryUsed
}

private func fixedAppleResolver(
    appleProvider: any AppleTranslationSessionProviding
) -> KEYITranslationResolver {
    let configuration = KEYITranslationResolver.Configuration(
        selectedProviderID: .appleSystem,
        targetLanguage: .english,
        scene: .automatic,
        englishStyle: .automatic,
        providerIDs: [.appleSystem]
    )
    return KEYITranslationResolver(
        configuration: { configuration },
        apiProvider: { _ in throw ProbeError.unexpectedProviderAccess },
        localProvider: { _ in throw ProbeError.unexpectedProviderAccess },
        appleProvider: appleProvider
    )
}

private func validateIsolatedSocket(_ path: String) throws {
    guard path.hasPrefix("/tmp/keyi-apple-translation-fix-") else {
        throw NSError(
            domain: "KEYIAppleTranslationProbe",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "socket must use the isolated test prefix"]
        )
    }
    guard path != TranslationServiceSocketPath.defaultPath() else {
        throw NSError(
            domain: "KEYIAppleTranslationProbe",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "default service socket is forbidden"]
        )
    }
}

private func runRequest(socketPath: String, requestID: String) async -> Never {
    do {
        try validateIsolatedSocket(socketPath)
        let client = TranslationServiceClient(socketPath: socketPath)
        let request = TranslationServiceRequest(
            text: fixedTestText,
            providerID: TranslationProviderID.appleSystem.rawValue,
            sourceLanguage: "zh-Hans",
            targetLanguage: TranslationLanguage.english.rawValue,
            timeoutSeconds: 30,
            id: requestID
        )
        let started = Date()
        let translated = try await client.translate(request)
        print(
            "OUTCOME=success request_id=\(TranslationServiceErrorMetadata.safeLogToken(requestID)) provider=appleSystem source=zh-Hans target=en translated_utf8_bytes=\(translated.utf8.count) elapsed_ms=\(Int(Date().timeIntervalSince(started) * 1000))"
        )
        exit(EXIT_SUCCESS)
    } catch {
        let metadata = TranslationServiceErrorMetadata(error)
        let wireCode: String
        if let clientError = error as? TranslationServiceClientError,
           case let .rejected(code, _) = clientError {
            wireCode = code.rawValue
        } else {
            wireCode = "client_error"
        }
        print(
            "OUTCOME=failure request_id=\(TranslationServiceErrorMetadata.safeLogToken(requestID)) provider=appleSystem source=zh-Hans target=en wire_code=\(wireCode) error_type=\(metadata.typeName) error_domain=\(metadata.domain) error_code=\(metadata.code)"
        )
        exit(EXIT_FAILURE)
    }
}

private final class SyntheticAppleProvider: AppleTranslationSessionProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var receivedRequestIDs: [String] = []
    private var legacyEntryCalls = 0

    var callCount: Int {
        lock.withLock { calls }
    }

    var requestIDs: [String] {
        lock.withLock { receivedRequestIDs }
    }

    var legacyCallCount: Int {
        lock.withLock { legacyEntryCalls }
    }

    func translate(
        text: String,
        sourceLanguage: String,
        targetLanguage: String,
        timeoutSeconds: Double
    ) async throws -> String {
        lock.withLock {
            legacyEntryCalls += 1
        }
        throw ProbeError.legacyProviderEntryUsed
    }

    func translate(
        text: String,
        sourceLanguage: String,
        targetLanguage: String,
        timeoutSeconds: Double,
        requestID: String
    ) async throws -> String {
        let call = lock.withLock { () -> Int in
            calls += 1
            receivedRequestIDs.append(requestID)
            return calls
        }
        switch call {
        case 1:
            throw AppleTranslationUnavailableError("synthetic language pair unavailable")
        case 2:
            throw NSError(
                domain: "SyntheticAppleProvider",
                code: 73,
                userInfo: [NSLocalizedDescriptionKey: "SENSITIVE_SYNTHETIC_DETAIL"]
            )
        case 3:
            return "synthetic translation"
        default:
            throw ProbeError.unexpectedProviderAccess
        }
    }
}

private func verifySessionCacheIdentity() {
    let englishKey = "zh-Hans|en"
    let japaneseKey = "zh-Hans|ja"
    var cache = AppleTranslationSessionCache<String>()

    let failingPreparation = cache.beginPreparation(for: englishKey)
    cache.failPreparation(for: englishKey, identity: failingPreparation)
    guard case nil = cache.entry(for: englishKey) else {
        fatalError("a failed preparation must not add a cache entry")
    }

    let rebuildPreparation = cache.beginPreparation(for: englishKey)
    let rebuiltEntry = cache.finishPreparation(
        for: englishKey,
        identity: rebuildPreparation,
        value: "rebuilt session"
    )
    guard cache.entry(for: englishKey)?.identity == rebuiltEntry.identity,
          cache.entry(for: englishKey)?.value == "rebuilt session" else {
        fatalError("a later request must be able to rebuild after failed preparation")
    }

    let replacementPreparation = cache.beginPreparation(for: englishKey)
    let replacementEntry = cache.finishPreparation(
        for: englishKey,
        identity: replacementPreparation,
        value: "replacement session"
    )
    guard !cache.removeEntry(for: englishKey, matching: rebuiltEntry.identity),
          cache.entry(for: englishKey)?.identity == replacementEntry.identity else {
        fatalError("a failed older request must not evict its replacement session")
    }

    guard cache.removeEntry(for: englishKey, matching: replacementEntry.identity) else {
        fatalError("failure of the currently cached session must evict that entry")
    }
    guard case nil = cache.entry(for: englishKey) else {
        fatalError("failure of the currently cached session must evict that entry")
    }

    let olderPreparation = cache.beginPreparation(for: englishKey)
    let newerPreparation = cache.beginPreparation(for: englishKey)
    let newerEntry = cache.finishPreparation(
        for: englishKey,
        identity: newerPreparation,
        value: "newer prepared session"
    )
    let olderEntry = cache.finishPreparation(
        for: englishKey,
        identity: olderPreparation,
        value: "older prepared session"
    )
    guard olderEntry.value == "older prepared session",
          cache.entry(for: englishKey)?.identity == newerEntry.identity,
          cache.entry(for: englishKey)?.value == "newer prepared session" else {
        fatalError("an older completed preparation must not overwrite a newer entry")
    }

    let japanesePreparation = cache.beginPreparation(for: japaneseKey)
    let japaneseEntry = cache.finishPreparation(
        for: japaneseKey,
        identity: japanesePreparation,
        value: "Japanese session"
    )
    guard cache.entry(for: englishKey)?.identity == newerEntry.identity,
          cache.entry(for: japaneseKey)?.identity == japaneseEntry.identity,
          cache.removeEntry(for: englishKey, matching: newerEntry.identity),
          cache.entry(for: japaneseKey)?.identity == japaneseEntry.identity else {
        fatalError("cache operations for one language pair must not affect another")
    }
    print("SESSION_CACHE_IDENTITY=pass prepare_failure_uncached=pass prepare_rebuild=allowed stale_eviction=blocked current_eviction=allowed stale_prepare_write=blocked language_pair_isolation=pass")
}

private func runOfflineChecks() async throws {
    // 只检查公开错误常量，不创建 Apple session 或查询/下载语言资源。
    var errorCases: [(TranslationError, String)] = [
        (.internalError, "internal_error"),
        (.nothingToTranslate, "nothing_to_translate"),
        (.unableToIdentifyLanguage, "unable_to_identify_language"),
        (.unsupportedSourceLanguage, "unsupported_source_language"),
        (.unsupportedTargetLanguage, "unsupported_target_language"),
        (.unsupportedLanguagePairing, "unsupported_language_pairing")
    ]
    if #available(macOS 26.0, *) {
        errorCases += [(.notInstalled, "not_installed"), (.alreadyCancelled, "already_cancelled")]
    }
    for (error, expectedCategory) in errorCases {
        guard KEYITranslationAppleSessionPool.errorCategory(error) == expectedCategory else {
            fatalError("Apple errors must be classified by typed constants")
        }
    }
    let ambiguousNSError = NSError(domain: "Translation.TranslationError", code: 1)
    guard KEYITranslationAppleSessionPool.errorCategory(ambiguousNSError) == "not_translation_error" else {
        fatalError("domain/code alone must not fabricate an Apple error category")
    }
    print("APPLE_ERROR_CLASSIFICATION=pass typed_cases=\(errorCases.count) numeric_code_inference=disabled")
    verifySessionCacheIdentity()

    let syntheticError = NSError(
        domain: "SyntheticMetadataDomain",
        code: 41,
        userInfo: [NSLocalizedDescriptionKey: "SENSITIVE_SYNTHETIC_DETAIL"]
    )
    let metadata = TranslationServiceErrorMetadata(syntheticError)
    let renderedMetadata = "\(metadata.typeName)|\(metadata.domain)|\(metadata.code)"
    guard metadata.domain == "SyntheticMetadataDomain",
          metadata.code == 41,
          !renderedMetadata.contains("SENSITIVE_SYNTHETIC_DETAIL"),
          TranslationServiceErrorMetadata.safeLogToken("request\nid") == "request_id" else {
        fatalError("diagnostic metadata must keep type/domain/code without error text")
    }

    let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
        .appendingPathComponent("keyi-apple-translation-fix-offline-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let socketPath = directory.appendingPathComponent("service.sock").path
    let provider = SyntheticAppleProvider()
    let server = TranslationServiceServer(
        socketPath: socketPath,
        resolver: fixedAppleResolver(appleProvider: provider)
    )
    try server.start()
    defer { server.stop() }

    var listenerReady = false
    for _ in 0..<50 {
        if TranslationServiceSocketProbe.isServiceRunning(at: socketPath) {
            listenerReady = true
            break
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    guard listenerReady else { throw ProbeError.listenerDidNotStart }

    let client = TranslationServiceClient(socketPath: socketPath)
    let unavailableID = "offline-unavailable-\(UUID().uuidString)"
    do {
        _ = try await client.translate(
            TranslationServiceRequest(
                text: "synthetic source",
                providerID: "appleSystem",
                sourceLanguage: "zh-Hans",
                targetLanguage: "en",
                timeoutSeconds: 30,
                id: unavailableID
            )
        )
        fatalError("the synthetic unavailable provider call must fail")
    } catch let error as TranslationServiceClientError {
        guard case let .rejected(code, _) = error, code == .unavailableProvider else {
            fatalError("AppleTranslationUnavailableError must map to unavailableProvider")
        }
    } catch {
        fatalError("the synthetic unavailable response must be a mapped wire rejection")
    }
    guard provider.callCount == 1 else {
        fatalError("an unavailable response must not silently retry the provider")
    }

    let providerFailureID = "offline-provider-error-\(UUID().uuidString)"
    do {
        _ = try await client.translate(
            TranslationServiceRequest(
                text: "synthetic source",
                providerID: "appleSystem",
                sourceLanguage: "zh-Hans",
                targetLanguage: "en",
                timeoutSeconds: 30,
                id: providerFailureID
            )
        )
        fatalError("the ordinary synthetic provider error must fail")
    } catch let error as TranslationServiceClientError {
        guard case let .rejected(code, _) = error, code == .providerError else {
            fatalError("an ordinary provider error must map to providerError")
        }
    } catch {
        fatalError("the ordinary provider error must be a mapped wire rejection")
    }

    let recoveryID = "offline-recovery-\(UUID().uuidString)"
    let recovered = try await client.translate(
        TranslationServiceRequest(
            text: "synthetic source",
            providerID: "appleSystem",
            sourceLanguage: "zh-Hans",
            targetLanguage: "en",
            timeoutSeconds: 30,
            id: recoveryID
        )
    )
    guard recovered == "synthetic translation",
          provider.callCount == 3,
          provider.requestIDs == [unavailableID, providerFailureID, recoveryID],
          provider.legacyCallCount == 0 else {
        fatalError("a later independent request must recover after the synthetic failure")
    }
    print("OFFLINE_CHECKS=pass metadata_privacy=pass apple_unavailable=unavailableProvider ordinary_failure=providerError request_id_overload=pass automatic_retry=none independent_followup=recovered requests=3")
}

let arguments = CommandLine.arguments
if arguments.count == 3, arguments[1] == "--serve" {
    let socketPath = arguments[2]
    do {
        try validateIsolatedSocket(socketPath)
    } catch {
        FileHandle.standardError.write(Data("INVALID_SOCKET\n".utf8))
        exit(EXIT_FAILURE)
    }
    _ = NSApplication.shared
    let resolver = fixedAppleResolver(appleProvider: KEYITranslationAppleSession.shared)
    FileHandle.standardError.write(
        Data("ISOLATED_CONFIG provider=appleSystem api_provider=disabled local_provider=disabled\n".utf8)
    )
    TranslationServiceRunner.run(resolver: resolver, socketPath: socketPath) { path in
        FileHandle.standardError.write(Data("SERVICE_READY socket=\(path)\n".utf8))
    }
} else if arguments.count == 4, arguments[1] == "--request" {
    await runRequest(socketPath: arguments[2], requestID: arguments[3])
} else if arguments.count == 2, arguments[1] == "--offline-checks" {
    do {
        try await runOfflineChecks()
    } catch {
        let metadata = TranslationServiceErrorMetadata(error)
        let resolutionCase: String
        if let resolutionError = error as? TranslationServiceResolutionError {
            switch resolutionError {
            case .notConfigured: resolutionCase = "not_configured"
            case .unavailableProvider: resolutionCase = "unavailable_provider"
            case .badRequest: resolutionCase = "bad_request"
            case .providerFailure: resolutionCase = "provider_failure"
            }
        } else {
            resolutionCase = "none"
        }
        FileHandle.standardError.write(
            Data("OFFLINE_CHECKS=fail error_type=\(metadata.typeName) error_domain=\(metadata.domain) error_code=\(metadata.code) resolution_case=\(resolutionCase)\n".utf8)
        )
        exit(EXIT_FAILURE)
    }
} else {
    FileHandle.standardError.write(
        Data("Usage: KEYIAppleTranslationProbe --serve <isolated-socket> | --request <isolated-socket> <request-id> | --offline-checks\n".utf8)
    )
    exit(EXIT_FAILURE)
}
