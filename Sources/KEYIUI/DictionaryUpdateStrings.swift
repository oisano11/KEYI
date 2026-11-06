import Foundation
import KEYITranslationClient

/// 「词库更新」的文案。
extension InterfaceStrings {
    var dictionarySection: String { isEnglish ? "Pinyin dictionary" : "拼音词库" }
    func dictionaryVersion(_ version: KEYIDictionaryUpdate.Version?, installed: Bool) -> String {
        guard let version else { return isEnglish ? "Version unknown" : "版本未知" }
        // 对用户只写日期和来源，不露提交号（提交号在日志里）。
        let source = installed ? (isEnglish ? "updated" : "已更新") : (isEnglish ? "bundled" : "随包")
        return isEnglish
            ? "rime-ice, \(version.date.formatted(date: .long, time: .omitted)) · \(source)"
            : "雾凇拼音 \(chineseDate(version.date))版 · \(source)"
    }
    /// 「2026 年 10 月 31 日」。
    func chineseDate(_ date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0) 年 \(parts.month ?? 0) 月 \(parts.day ?? 0) 日"
    }
    func dictionaryLastCheck(_ date: Date?) -> String {
        guard let date else { return isEnglish ? "Not checked yet." : "还没检查过。" }
        let text = date.formatted(date: .abbreviated, time: .shortened)
        return isEnglish ? "Last checked \(text)." : "上次检查：\(text)。"
    }
    var dictionaryCheck: String { isEnglish ? "Check for updates" : "检查更新" }
    var dictionaryChecking: String { isEnglish ? "Checking…" : "正在检查…" }
    var dictionaryUpToDate: String { isEnglish ? "Already the newest." : "已是最新。" }
    var dictionaryRestore: String { isEnglish ? "Back to bundled" : "退回随包版本" }
    var dictionaryUpdate: String { isEnglish ? "Update" : "更新" }
    var dictionaryNotNow: String { isEnglish ? "Not now" : "暂不" }
    var dictionaryNotes: String { isEnglish ? "Upstream notes:" : "上游说明：" }
    var dictionaryOfferNote: String {
        isEnglish
            ? "Only the five full-pinyin tables are downloaded (about 44 MB). They are checked and test-built before use; your learned words stay."
            : "只下载五份全拼词表（约 44 MB），先校验、试编译再换上；你学到的词不受影响。"
    }
    func dictionaryDownloading(_ index: Int, _ total: Int) -> String {
        isEnglish ? "Downloading \(index)/\(total)…" : "正在下载 \(index)/\(total)…"
    }
    var dictionaryVerifying: String { isEnglish ? "Test-building…" : "正在试编译…" }
    var dictionaryApplying: String { isEnglish ? "Applying…" : "正在生效…" }
    func dictionaryInstalled(_ change: KEYIDictionaryUpdate.Change, applied: Bool) -> String {
        let counts = isEnglish
            ? "Updated: \(change.added) words added, \(change.removed) removed."
            : "已更新：新增 \(change.added) 个词，删除 \(change.removed) 个。"
        return counts + (applied ? "" : (isEnglish ? " Takes effect the next time you type." : "下次打字时生效。"))
    }
    func dictionaryRestored(applied: Bool) -> String {
        (isEnglish ? "Back to the bundled version." : "已退回随包版本。")
            + (applied ? "" : (isEnglish ? " Takes effect the next time you type." : "下次打字时生效。"))
    }
    var dictionaryCheckFailed: String { isEnglish ? "Could not reach GitHub." : "连不上 GitHub，没查到。" }
    var dictionaryInstallFailed: String {
        isEnglish ? "Update failed; the dictionary in use is unchanged." : "更新没有成功，正在用的词库没变。"
    }
    var dictionaryNoInputMethod: String { isEnglish ? "KEYI Pinyin is not installed." : "没有安装 KEYI 拼音输入法。" }
    var dictionaryMenuItem: String { isEnglish ? "Dictionary update available…" : "词库有更新…" }
}
