//
//  TranslationServiceRunner.swift
//  KEYI 可译 — 输入法翻译服务（阶段 02）
//
//  服务进程的入口装配。宿主应用（KEYI 可译）用
//  `Bundle.main.executableURL` + `TranslationServiceRunner.childProcessArguments()`
//  把「自己」再启动一次，只是带上 `--keyi-translation-service`；
//  该实例不创建菜单栏 UI，只跑 socket 服务循环。
//

import Foundation
import KEYICore
import KEYITranslationClient
import OSLog

public enum TranslationServiceRunner {
    /// 服务进程的启动参数。
    public static let launchArgument = "--keyi-translation-service"

    private static let logger = Logger(
        subsystem: "com.keyi.input-translator",
        category: "TranslationService"
    )

    public static func shouldRunAsService(
        arguments: [String] = CommandLine.arguments
    ) -> Bool {
        arguments.contains(launchArgument)
    }

    /// 供宿主启动子进程使用的参数。
    public static func childProcessArguments() -> [String] {
        [launchArgument]
    }

    /// 从参数里读取自定义 socket 路径（用于验证与排错）。
    public static func socketPath(
        arguments: [String] = CommandLine.arguments
    ) -> String {
        if let index = arguments.firstIndex(of: "--socket"),
           index + 1 < arguments.count {
            let candidate = arguments[index + 1]
            if !candidate.isEmpty { return candidate }
        }
        return TranslationServiceSocketPath.defaultPath()
    }

    /// 服务进程主体：起服务后不返回。
    public static func run(
        resolver: any TranslationServiceResolving,
        speech: (any SpeechTranscriptionProviding)? = nil,
        socketPath: String? = nil,
        onReady: (@Sendable (String) -> Void)? = nil
    ) -> Never {
        let path = socketPath ?? self.socketPath()

        // 单实例：已有服务在监听时直接退出，避免两个进程抢同一个 socket。
        if TranslationServiceSocketProbe.isServiceRunning(at: path) {
            logger.info("翻译服务已在运行，忽略重复启动")
            FileHandle.standardError.write(Data("翻译服务已在运行：\(path)\n".utf8))
            exit(EXIT_SUCCESS)
        }

        let server = TranslationServiceServer(socketPath: path, resolver: resolver, speech: speech)
        do {
            try server.start()
        } catch {
            FileHandle.standardError.write(
                Data("翻译服务启动失败：\(error.localizedDescription)\n".utf8)
            )
            exit(EXIT_FAILURE)
        }
        onReady?(path)

        installSignalHandlers(server: server)
        monitorParentProcess(server: server)
        dispatchMain()
    }

    private static func installSignalHandlers(server: TranslationServiceServer) {
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(
                signal: signalNumber,
                queue: .global(qos: .userInitiated)
            )
            source.setEventHandler {
                server.stop()
                exit(EXIT_SUCCESS)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// 宿主应用退出后，服务进程不应留在后台。
    private static func monitorParentProcess(server: TranslationServiceServer) {
        let initialParent = getppid()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .background))
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler {
            let currentParent = getppid()
            if currentParent == 1 || currentParent != initialParent {
                logger.info("宿主进程已退出，翻译服务停止")
                server.stop()
                exit(EXIT_SUCCESS)
            }
        }
        timer.resume()
        parentMonitor = timer
    }

    nonisolated(unsafe) private static var signalSources: [DispatchSourceSignal] = []
    nonisolated(unsafe) private static var parentMonitor: DispatchSourceTimer?
}

/// socket 存活探测：唯一实现，服务端与客户端共用同一规则。
public enum TranslationServiceSocketProbe {
    public static func isServiceRunning(at path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { _ = Darwin.close(descriptor) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            return false
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                Darwin.connect(
                    descriptor,
                    socketPointer,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        return result == 0
    }
}
