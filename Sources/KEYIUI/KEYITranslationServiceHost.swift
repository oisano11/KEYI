//
//  KEYITranslationServiceHost.swift
//  KEYI 可译 — 输入法翻译服务宿主（阶段 02）
//
//  职责：
//  1. 用已保存的提供方/语言/语气/凭据装配 `KEYITranslationResolver`；
//  2. 以 `--keyi-translation-service` 启动自身子进程，在子进程里跑服务循环
//     （不创建菜单栏 UI，符合「翻译会话与本地模型留在伴随应用中」的要求）；
//  3. 宿主退出时结束子进程，避免残留后台服务。
//
//  凭据：只在子进程内经 `CredentialStore` 读取；协议与日志都不传明文。
//

import AppKit
import Foundation
import KEYICore
import KEYITranslationClient
import KEYITranslationService
import OSLog

@MainActor
final class KEYITranslationServiceHost {
    static let shared = KEYITranslationServiceHost()

    private let logger = Logger(
        subsystem: "com.keyi.input-translator",
        category: "TranslationServiceHost"
    )
    private var process: Process?
    private var isStarted = false

    private init() {}

    /// 启动服务子进程；重复调用只启动一次。
    func startIfNeeded(socketPath: String = TranslationServiceSocketPath.defaultPath()) {
        guard !isStarted else { return }
        isStarted = true

        if TranslationServiceSocketProbe.isServiceRunning(at: socketPath) {
            logger.info("翻译服务已在运行，宿主不再启动子进程")
            return
        }

        guard let executable = Bundle.main.executableURL else {
            logger.error("无法定位 KEYI 可译可执行文件，翻译服务未启动")
            return
        }

        let child = Process()
        child.executableURL = executable
        child.arguments = TranslationServiceRunner.childProcessArguments() + [
            "--socket", socketPath
        ]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        do {
            try child.run()
            process = child
            logger.info("翻译服务子进程已启动，pid=\(child.processIdentifier, privacy: .public)")
        } catch {
            logger.error("翻译服务子进程启动失败：\(error.localizedDescription, privacy: .private)")
        }
    }

    /// 宿主退出时调用。
    func stop() {
        guard let process else { return }
        if process.isRunning {
            process.terminate()
        }
        self.process = nil
        logger.info("翻译服务子进程已结束")
    }
}

/// 服务进程实体：在子进程里执行，不启动菜单栏 UI。
public enum KEYITranslationServiceEntry {
    /// 带 `--keyi-translation-service` 启动时进入服务循环（不返回）；
    /// 否则返回 `false`，由调用方继续正常启动菜单栏应用。
    @discardableResult
    public static func runIfRequested() -> Bool {
        guard TranslationServiceRunner.shouldRunAsService() else { return false }
        let socketPath = TranslationServiceRunner.socketPath()
        // 进程启动时仍在主线程上；配置读取是 @MainActor 隔离的，这里直接沿用
        // 主线程隔离域，避免在 `dispatchMain()` 之前死等主队列。
        let resolver = MainActor.assumeIsolated {
            KEYITranslationResolverFactory.make()
        }
        TranslationServiceRunner.run(
            resolver: resolver,
            socketPath: socketPath
        )
    }
}

/// 装配 resolver：已保存偏好 + Keychain 凭据 + Apple 会话。
public enum KEYITranslationResolverFactory {
    @MainActor
    public static func make() -> any TranslationServiceResolving {
        let store = TranslationSettingsStore()
        let appleProvider = KEYITranslationAppleSession.shared

        return KEYITranslationResolver(
            configuration: {
                // 每次请求开始时重新读取已保存配置，避免使用启动时快照。
                await MainActor.run {
                    store.reloadPreferences()
                    let preferences = store.preferences
                    // 用户只选风格；用哪个引擎、带什么场景和英语风格按风格现算。
                    let style = store.translationStyle()
                    let route = TranslationStyleRouting.route(
                        for: style,
                        localModelReady: LocalModelStorage.standard
                            .preferredInstalledModel(preferring: store.localModelTier()) != nil,
                        cloudProvider: style.usesCloud
                            ? store.preferredCloudProvider(isConfigured: store.isAPIConfigured)
                            : nil
                    )
                    return KEYITranslationResolver.Configuration(
                        selectedProviderID: route.providerID,
                        targetLanguage: preferences.targetLanguage,
                        scene: route.scene,
                        englishStyle: route.englishStyle
                    )
                }
            },
            apiProvider: { providerID in
                guard TranslationProviderCatalog.descriptor(for: providerID).isAvailable,
                      providerID.requiresAPIConfiguration else {
                    return nil
                }
                guard let apiConfiguration = try? await store.apiConfiguration(for: providerID) else {
                    return nil
                }
                // 个人术语表（用户打开时）：大模型的译法攒起来提炼，留给本地模型参考。
                return GlossaryCollectingProvider(inner: OpenAICompatibleTranslationProvider(
                    configuration: apiConfiguration,
                    usageRecorder: { APIUsageLedger.standard.record(providerID: $0, usage: $1) }
                ))
            },
            localProvider: { _ in
                // 只认用户选定并已校验下载的那一档；服务由主应用常驻运行，这里只经运行目录连过去。
                let tier = await MainActor.run { store.localModelTier() }
                guard let model = LocalModelStorage.standard.preferredInstalledModel(preferring: tier) else {
                    throw TranslationServiceResolutionError.notConfigured(
                        InterfaceStrings.current.localModelNotInstalled
                    )
                }
                return LocalModelTranslationProvider.bundled(model: model)
            },
            appleProvider: appleProvider
        )
    }
}
