import AppKit
import KeyiIMETranslation
import OSLog

private let feedbackLog = Logger(
    subsystem: "com.keyi.inputmethod.keyi",
    category: "TranslationFeedback"
)

/// 自动翻译失败时给用户的反馈：一行提示，连不上伴随服务时在后台拉起 KEYI 可译。
///
/// 此前失败是完全静默的：KEYI 可译没开时，每次停手都悄悄失败，浮层只剩两行中文，
/// 用户无从知道原因。
@MainActor
enum KeyiTranslationFeedback {
    /// 同一条提示的最短间隔，避免每次停手都弹一次。
    private static let repeatInterval: TimeInterval = 8
    private static let displayDuration: TimeInterval = 2.5
    private static var lastShown: (text: String, time: Date)?

    static func report(_ failure: KeyiAutomaticTranslationFailure) {
        if failure.launchesCompanion {
            KeyiCompanionLauncher.launchIfNeeded()
        }
        // Preview (typing pause) failures only launch the companion; no toast.
        guard failure.showsToast else { return }
        let text = message(for: failure)
        let now = Date()
        if let lastShown, lastShown.text == text,
           now.timeIntervalSince(lastShown.time) < repeatInterval {
            return
        }
        lastShown = (text, now)
        KeyiToastPanel.show(text: text, duration: displayDuration)
    }

    static func message(for failure: KeyiAutomaticTranslationFailure) -> String {
        switch failure.kind {
        case .serviceUnavailable:
            return failure.willRetry ? "KEYI 可译未运行，正在启动…" : "连不上 KEYI 可译，原文已保留"
        case .notConfigured:
            return "翻译服务未配置，请在 KEYI 可译中设置"
        case .timedOut:
            return "翻译超时，原文已保留"
        case .emptyResult:
            return "翻译结果为空，原文已保留"
        case .tooLong:
            return "这段太长，不翻译，原文已保留"
        case .other:
            return "翻译失败，原文已保留"
        }
    }
}

/// 在后台拉起 KEYI 可译伴随应用；翻译服务运行在它的进程里。
@MainActor
enum KeyiCompanionLauncher {
    static let bundleIdentifier = "com.keyi.input-translator"
    private static let attemptInterval: TimeInterval = 30
    private static var lastAttempt: Date?

    static func launchIfNeeded() {
        // 已在运行时不重复拉起；服务暂时不可用由伴随应用自己恢复。
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty else {
            return
        }
        let now = Date()
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < attemptInterval { return }
        lastAttempt = now
        guard let url = applicationURL() else {
            feedbackLog.error("companion app not found")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        // 不激活：否则会抢走当前输入框的焦点，用户接着打的字会落到别处。
        configuration.activates = false
        configuration.addsToRecentItems = false
        feedbackLog.notice("launching companion app")
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                feedbackLog.error("companion launch failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// 打开 KEYI 可译的设置窗口。已在运行时激活它会触发“再次打开”，由它打开设置；
    /// 没运行时带参数启动，启动后直接打开设置。用户主动点的菜单，所以这里要激活。
    static func openSettings() {
        guard let url = applicationURL() else {
            feedbackLog.error("companion app not found")
            KeyiToastPanel.show(text: "没有找到 KEYI 可译")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.arguments = [openSettingsArgument]
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                feedbackLog.error("companion settings open failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// 与 KEYI 可译 AppDelegate 约定的启动参数。
    static let openSettingsArgument = "--open-settings"

    /// 优先使用“应用程序”目录里的正式安装；构建目录或测试产物里的副本可能是旧版本。
    private static func applicationURL() -> URL? {
        let candidates = [
            URL(fileURLWithPath: "/Applications/KEYI 可译.app"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/KEYI 可译.app"),
        ]
        for url in candidates where Bundle(url: url)?.bundleIdentifier == bundleIdentifier {
            return url
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }
}
