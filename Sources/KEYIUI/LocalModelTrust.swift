import Foundation
import Security

/// A model identifier is not authentication. Only send text to an installed,
/// signed LM Studio process, and never forward it through an HTTP redirect.
enum LocalModelTrust {
    static func directEndpoint(_ endpoint: URL) -> URL {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              components.host?.lowercased() == "localhost" else { return endpoint }
        // Keep local requests on a literal loopback address, independent of DNS.
        components.host = "127.0.0.1"
        return components.url ?? endpoint
    }

    static func validate(_ endpoint: URL) throws {
        guard endpoint.scheme == "http",
              ["127.0.0.1", "localhost", "[::1]", "::1"].contains(endpoint.host ?? ""),
              endpoint.user == nil, endpoint.password == nil else {
            throw LocalModelTranslationError.serviceUnavailable
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-a", "-iTCP:\(endpoint.port ?? 80)", "-sTCP:LISTEN", "-Fp"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: timeout)
        defer { timeout.cancel() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let pids = Set((String(data: data, encoding: .utf8) ?? "")
            .split(separator: "\n").compactMap { line -> Int32? in
                guard line.first == "p" else { return nil }
                return Int32(line.dropFirst())
            })
        guard process.terminationStatus == 0, !pids.isEmpty else {
            throw LocalModelTranslationError.serviceUnavailable
        }
        guard pids.allSatisfy(isLMStudioProcess) else {
            throw LocalModelTranslationError.untrustedService
        }
    }

    private static func isLMStudioProcess(_ pid: Int32) -> Bool {
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary,
                                            [], &code) == errSecSuccess,
              let code,
              SecCodeCheckValidity(code, [], nil) == errSecSuccess else { return false }
        var info: CFDictionary?
        var runningStaticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &runningStaticCode) == errSecSuccess,
              let runningStaticCode,
              SecCodeCopySigningInformation(runningStaticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any],
              let executable = values[kSecCodeInfoMainExecutable as String] as? URL,
              let team = values[kSecCodeInfoTeamIdentifier as String] as? String else { return false }
        // Derive the containing app rather than trusting a process name or an
        // arbitrary response header. This also supports user Applications folders.
        var app = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        while app.path != "/", app.pathExtension != "app" { app.deleteLastPathComponent() }
        // Electron helpers are nested apps; walk outward to LM Studio's bundle.
        while app.path != "/", app.lastPathComponent != "LM Studio.app" { app.deleteLastPathComponent() }
        guard app.lastPathComponent == "LM Studio.app",
              ["/Applications/LM Studio.app",
               FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/LM Studio.app").path].contains(app.path),
              let bundle = Bundle(url: app),
              bundle.object(forInfoDictionaryKey: "CFBundleName") as? String == "LM Studio" else { return false }
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple generic" as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCreateWithPath(app as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode,
              SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else { return false }
        var appInfo: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &appInfo) == errSecSuccess,
              let appValues = appInfo as? [String: Any] else { return false }
        return appValues[kSecCodeInfoTeamIdentifier as String] as? String == team
    }
}

final class LocalModelNoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = LocalModelNoRedirectDelegate()
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

extension LocalModelTrust {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration)
    }()
}
