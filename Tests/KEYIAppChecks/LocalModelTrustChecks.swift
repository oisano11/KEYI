import Darwin
import Foundation
import KEYICore
@testable import KEYIUI

/// A real TCP listener owned by this test must not receive a connection/body,
/// even when the caller invokes the provider without ensureReady first.
func runLocalModelTrustChecks() async throws {
    let listener = socket(AF_INET, SOCK_STREAM, 0)
    precondition(listener >= 0)
    defer { close(listener) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bindResult = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    precondition(bindResult == 0 && listen(listener, 1) == 0)
    var size = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(listener, $0, &size)
        }
    }
    precondition(nameResult == 0)
    let port = UInt16(bigEndian: address.sin_port)
    let provider = LocalModelTranslationProvider(configuration: LocalModelConfiguration(
        endpoint: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!,
        model: "gemma-4-12b", loadKey: "test"
    ))
    do {
        _ = try await provider.translate(TextTranslationRequest(sourceText: "private test source"))
        preconditionFailure("An unrelated local listener must not receive translations")
    } catch LocalModelTranslationError.untrustedService {
        // Expected: the production trust validator rejects this process.
    }
    var pending = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
    precondition(poll(&pending, 1, 0) == 0, "Spoof listener received a connection")
    do {
        try await LocalModelRuntime.ensureReady(configuration: LocalModelConfiguration(
            endpoint: URL(string: "http://localhost:\(port)/v1/chat/completions")!,
            model: "gemma-4-12b", loadKey: "test"
        ))
        preconditionFailure("Runtime readiness must reject a spoof before launching or loading a model")
    } catch LocalModelTranslationError.untrustedService {}
    precondition(poll(&pending, 1, 0) == 0, "Readiness probe contacted the spoof listener")
    print("Local model trust: unrelated real loopback listener blocked before HTTP")
}
