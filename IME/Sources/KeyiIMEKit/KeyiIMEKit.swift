import Foundation

/// Entry points the executable target uses during launch. Kept deliberately
/// small: the input session and candidate panel stay internal to the kit.
public enum KeyiIMEKit {
    /// Creates the candidate panel before AppKit finishes launching, which is
    /// required for the panel to get a real window number in an InputMethodKit
    /// process.
    @MainActor
    public static func prepareCandidatePanel() {
        KeyiCompositionPanel.shared.prepare()
        // 「自动翻译」开关：在 KEYI 拼音的输入框里按 ⌃⌥T 切换，切到其他输入法即释放。
        KeyiHotKeyManager.shared.startTracking()
        // 用户词库：先执行上次留下的清空请求（还没打开词库），再听设置窗口的清空请求。
        KeyiUserDictionary.applyPendingResetBeforeLaunch()
        KeyiUserDictionary.startListening()
        // 雾凇词表：应用包自带的不比用户目录里的旧时副本让位；再听 KEYI 可译装好新词表后的重新部署请求。
        KeyiDictionaryUpdates.yieldToNewerBundleBeforeLaunch()
        KeyiDictionaryUpdates.startListening()
    }
}
