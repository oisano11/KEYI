import Foundation
import KEYITranslationClient
import KeyiIMEBridge
import OSLog

/// 雾凇词表更新的输入法一侧（约定见 `KEYIDictionaryUpdate`）：启动时让过期副本让位给随包词表，
/// `--verify-dictionary` 试编译下载的词表，运行时听 KEYI 可译的请求在进程内重新部署。输入法不联网。
public enum KeyiDictionaryUpdates {
    private static let logger = Logger(subsystem: "com.keyi.input-method", category: "dictionary-update")

    static var sharedDataURL: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("RimeData", isDirectory: true)
    }

    /// 输入法启动、打开词库前：应用包自带的词表不比用户目录里的旧，就删掉用户目录的副本。
    static func yieldToNewerBundleBeforeLaunch() {
        guard KeyiPreferences.diagnosticsUserDataOverride == nil, let rimeData = sharedDataURL else { return }
        if KEYIDictionaryUpdate.yieldToNewerBundle(rimeData: rimeData) {
            logger.notice("bundled rime-ice tables are as new as the user copies; user copies removed")
        }
    }

    /// `--verify-dictionary <目录>`：目录里是下载的五份词表。在一次性的用户目录里用随包数据加这些词表
    /// 部署一次，能编出词库、打 nihao 有「你好」才算通过。只在没有输入会话的独立进程里调用。
    public static func verifyStagedTables(in staged: URL) -> Bool {
        let fileManager = FileManager.default
        guard let rimeData = sharedDataURL else { return false }
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("keyi-dictionary-verify-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: scratch) }
        let locations = KEYIDictionaryUpdate.Locations(rimeUserData: scratch, support: scratch)
        // Rime 编译很宽容：一份坏掉的词表只会被跳过，别的词表照样打得出「你好」。所以先逐份核对
        // 格式和条数（不比随包的少一成以上），再试编译。
        for name in KEYIDictionaryUpdate.tableNames {
            let bundled = rimeData.appendingPathComponent("rime_ice/cn_dicts/\(name).dict.yaml")
            let previousCount = (try? String(contentsOf: bundled, encoding: .utf8))
                .flatMap(KEYIDictionaryUpdate.entries(in:))?.count ?? 0
            guard let text = try? String(contentsOf: locations.table(name, in: staged), encoding: .utf8),
                  KEYIDictionaryUpdate.isAcceptable(text, table: name, previousCount: previousCount)
            else {
                logger.error("verify: table \(name, privacy: .public) is not a full rime-ice table")
                return false
            }
        }
        do {
            try fileManager.createDirectory(at: locations.tablesDirectory, withIntermediateDirectories: true)
            for name in KEYIDictionaryUpdate.tableNames {
                try fileManager.copyItem(at: locations.table(name, in: staged), to: locations.table(name))
            }
        } catch {
            logger.error("verify: copy failed \(error.localizedDescription, privacy: .public)")
            return false
        }
        let session = KeyiRimeSession(
            sharedDataPath: rimeData.path,
            userDataPath: scratch.path,
            schemaIdentifier: "keyi_pinyin"
        )
        guard session.ready else { return false }
        var result = KeyiRimeResult()
        for scalar in "nihao".unicodeScalars {
            result = session.processKey(Int(scalar.value), modifiers: 0)
        }
        let built = fileManager.fileExists(atPath: scratch.appendingPathComponent("build/keyi_pinyin.table.bin").path)
        return built && result.candidates.contains("你好")
    }

    /// 输入法运行期间听 KEYI 可译的重新部署请求（新词表装好或退回随包版本之后）。
    @MainActor
    public static func startListening() {
        guard KeyiPreferences.diagnosticsUserDataOverride == nil else { return }
        DistributedNotificationCenter.default().addObserver(
            forName: KEYIDictionaryUpdate.reloadRequest,
            object: nil,
            queue: .main
        ) { _ in
            let sharedDataPath = sharedDataURL?.path ?? ""
            let userDataPath = KeyiPreferences.rimeUserDataURL.path
            // 重新编译要几秒，放到后台；期间按键会等编译完成（同一把锁）。
            DispatchQueue.global(qos: .userInitiated).async {
                let succeeded = KeyiRimeSession.redeploy(withSharedDataPath: sharedDataPath, userDataPath: userDataPath)
                logger.notice("dictionary redeploy succeeded=\(succeeded, privacy: .public)")
                DistributedNotificationCenter.default().postNotificationName(
                    KEYIDictionaryUpdate.reloadFinished,
                    object: nil,
                    userInfo: [KEYIDictionaryUpdate.succeededKey: succeeded ? "1" : "0"],
                    deliverImmediately: true
                )
            }
        }
    }
}
