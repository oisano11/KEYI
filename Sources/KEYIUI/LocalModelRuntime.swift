import Foundation
import KEYICore

enum LocalModelRuntimeError: LocalizedError {
    case runtimeUnavailable
    case modelNotInstalled
    case serviceUnavailable

    var errorDescription: String? {
        switch self {
        case .runtimeUnavailable:
            "未找到 LM Studio 命令，请先安装 LM Studio"
        case .modelNotInstalled:
            "本机未找到 Gemma 4 12B，请在 LM Studio 下载或加载该模型"
        case .serviceUnavailable:
            "LM Studio 本地服务未能启动，请在 LM Studio 中开启 Local Server"
        }
    }
}

enum LocalModelRuntime {
    private static var lmStudioCandidates: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/.lmstudio/bin/lms",
            "/opt/homebrew/bin/lms",
            "/usr/local/bin/lms"
        ]
    }

    static func ensureReady(
        configuration: LocalModelConfiguration
    ) async throws {
        if await modelIsAvailable(configuration: configuration) {
            return
        }

        guard let executable = findLMStudioExecutable() else {
            throw LocalModelRuntimeError.runtimeUnavailable
        }

        guard configuration.model == LocalModelCatalog.gemma4.defaultModel else {
            throw LocalModelRuntimeError.modelNotInstalled
        }
        guard let loadKey = try? await installedGemma4LoadKey(
            executable: executable
        ) else {
            throw LocalModelRuntimeError.modelNotInstalled
        }

        let components = URLComponents(
            url: configuration.endpoint,
            resolvingAgainstBaseURL: false
        )
        let port = components?.port ?? 1234
        // server start 在服务已运行时可能非零退出，失败不致命，继续尝试加载。
        _ = try? await run(
            executable: executable,
            arguments: [
                "server", "start",
                "--port", String(port),
                "--bind", "127.0.0.1"
            ]
        )

        // load 失败意味着模型无法进入服务，轮询 90 秒也不会成功，立即报错。
        _ = try await run(
            executable: executable,
            arguments: [
                "load",
                loadKey,
                "--identifier", configuration.model,
                "-c", "8192",
                "--parallel", "1",
                "--ttl", String(LocalModelCatalog.gemma4.idleTTLSeconds),
                "-y"
            ]
        )

        for _ in 0..<90 {
            if await modelIsAvailable(configuration: configuration) {
                return
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw LocalModelRuntimeError.serviceUnavailable
    }

    private static func modelIsAvailable(
        configuration: LocalModelConfiguration
    ) async -> Bool {
        guard let modelsURL = modelsURL(for: configuration.endpoint) else {
            return false
        }
        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 2
        request.setValue("Bearer lm-studio", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode),
              let decoded = try? JSONDecoder().decode(
                  LocalModelsResponse.self,
                  from: data
              ) else {
            return false
        }
        return decoded.data.contains { $0.id == configuration.model }
    }

    private static func modelsURL(for endpoint: URL) -> URL? {
        guard var components = URLComponents(
            url: endpoint,
            resolvingAgainstBaseURL: false
        ) else { return nil }
        components.path = "/v1/models"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static func findLMStudioExecutable() -> String? {
        lmStudioCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func installedGemma4LoadKey(
        executable: String
    ) async throws -> String {
        let output = try await run(
            executable: executable,
            arguments: ["ls", "--json"]
        )
        guard let data = output.data(using: .utf8),
              let models = try? JSONDecoder().decode(
                  [InstalledModel].self,
                  from: data
              ) else {
            throw LocalModelRuntimeError.modelNotInstalled
        }
        if models.contains(where: {
            $0.modelKey == LocalModelCatalog.gemma4.defaultLoadKey
        }) {
            return LocalModelCatalog.gemma4.defaultLoadKey
        }
        guard let compatible = models.first(where: {
            $0.type == "llm"
                && $0.architecture == "gemma4_unified"
                && $0.paramsString == "12B"
        }) else {
            throw LocalModelRuntimeError.modelNotInstalled
        }
        return compatible.modelKey
    }

    private static func run(
        executable: String,
        arguments: [String]
    ) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            // 必须先读完管道再等待退出：子进程输出超过管道缓冲时会阻塞在
            // 写入上，先 waitUntilExit 会造成双向死锁。EOF 即子进程已退出。
            let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw LocalModelRuntimeError.serviceUnavailable
            }
            return String(data: output, encoding: .utf8) ?? ""
        }.value
    }
}

private struct InstalledModel: Decodable, Sendable {
    let type: String
    let modelKey: String
    let paramsString: String?
    let architecture: String?
}

private struct LocalModelsResponse: Decodable, Sendable {
    let data: [LocalModel]

    struct LocalModel: Decodable, Sendable {
        let id: String
    }
}
