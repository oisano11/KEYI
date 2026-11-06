import Foundation
import KEYITranslationClient
import KeyiIMEBridge
import OSLog

/// 用户词库（Rime 本机自学习）的导出与清空；约定见 `KEYIUserDictionaryIPC`。
/// 清空时连同按 App 学到的候选顺序（`KEYIAppCandidateLearning`）一起清。
public enum KeyiUserDictionary {
    private static let logger = Logger(subsystem: "com.keyi.input-method", category: "user-dictionary")

    /// `--export-user-dict` 模式：把正在用的词库复制一份（输入法进程占着它的锁），从副本导出文本。
    /// 返回导出的词条数，失败为 -1。只在没有输入会话的独立进程里调用。
    public static func exportLiveDictionary(to textFile: URL) -> Int {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("keyi-user-dict-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: workspace) }
        let copy = workspace.appendingPathComponent(
            KEYIUserDictionaryIPC.liveDatabaseURL.lastPathComponent,
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(at: copy, withIntermediateDirectories: true)
            guard fileManager.fileExists(atPath: KEYIUserDictionaryIPC.liveDatabaseURL.path) else {
                // 还没学过词：导出一个空词库。
                try "".write(to: textFile, atomically: true, encoding: .utf8)
                return 0
            }
            for name in try fileManager.contentsOfDirectory(atPath: KEYIUserDictionaryIPC.liveDatabaseURL.path)
            where name != "LOCK" {
                try fileManager.copyItem(
                    at: KEYIUserDictionaryIPC.liveDatabaseURL.appendingPathComponent(name),
                    to: copy.appendingPathComponent(name)
                )
            }
        } catch {
            logger.error("copy user dictionary failed: \(error.localizedDescription, privacy: .public)")
            return -1
        }
        return KeyiRimeSession.exportUserDictionaryNamed(
            KEYIUserDictionaryIPC.dictionaryName,
            userDataPath: workspace.path,
            toFile: textFile.path
        )
    }

    /// 输入法启动时调用：伴随应用在输入法没运行时留下的清空请求，在打开词库前执行。
    static func applyPendingResetBeforeLaunch() {
        guard KeyiPreferences.diagnosticsUserDataOverride == nil else { return }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: KEYIUserDictionaryIPC.pendingResetMarkerURL.path) else { return }
        try? fileManager.removeItem(at: KEYIUserDictionaryIPC.liveDatabaseURL)
        KEYIAppCandidateLearning.shared.reset()
        try? fileManager.removeItem(at: KEYIUserDictionaryIPC.pendingResetMarkerURL)
        logger.notice("user dictionary cleared at launch")
    }

    /// 输入法运行期间听伴随应用的清空请求。
    @MainActor
    public static func startListening() {
        guard KeyiPreferences.diagnosticsUserDataOverride == nil else { return }
        DistributedNotificationCenter.default().addObserver(
            forName: KEYIUserDictionaryIPC.resetRequest,
            object: nil,
            queue: .main
        ) { _ in
            // 按 App 学到的候选顺序跟用户词库一起清空。
            KEYIAppCandidateLearning.shared.reset()
            let sharedDataPath = Bundle.main.resourceURL?
                .appendingPathComponent("RimeData", isDirectory: true).path ?? ""
            let succeeded = KeyiRimeSession.resetUserDictionaryNamed(
                KEYIUserDictionaryIPC.dictionaryName,
                sharedDataPath: sharedDataPath,
                userDataPath: KeyiPreferences.rimeUserDataURL.path
            )
            if succeeded {
                try? FileManager.default.removeItem(at: KEYIUserDictionaryIPC.pendingResetMarkerURL)
            }
            logger.notice("user dictionary reset succeeded=\(succeeded, privacy: .public)")
            DistributedNotificationCenter.default().postNotificationName(
                KEYIUserDictionaryIPC.resetFinished,
                object: nil,
                userInfo: [KEYIUserDictionaryIPC.succeededKey: succeeded ? "1" : "0"],
                deliverImmediately: true
            )
        }
    }
}
