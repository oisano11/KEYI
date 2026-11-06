import Foundation
import KEYITranslationClient

/// 设置窗口收紧（2026-11-05）后用的短文案：一行里放得下的名称和短注；原来的长说明改作悬停提示。
extension InterfaceStrings {
    var translationSection: String { isEnglish ? "Translation" : "翻译" }
    var localModelShortLabel: String { isEnglish ? "On-device model" : "本机模型" }
    var cloudServiceShortLabel: String { isEnglish ? "AI service" : "大模型服务" }
    var cloudServiceNote: String { isEnglish ? "for the three casual styles" : "三种口语风格用" }
    var glassLabel: String { isEnglish ? "Frosted glass" : "磨砂" }
    var glassFrostClear: String { isEnglish ? "Clear" : "通透" }
    var glassFrostThick: String { isEnglish ? "Frosted" : "厚实" }
    var glassHelp: String {
        isEnglish
            ? "One setting for the panel beside the cursor and this window: towards Frosted the blur gets heavier and the tint more solid, towards Clear more of what's behind shows through."
            : "光标旁面板和这个窗口都用它：往右模糊更重、底色更实，往左背后的东西透得更多。"
    }
    var desktopHotKeyNote: String { isEnglish ? "translate text in the current app" : "翻译当前应用里的文字" }

    /// 「雾凇拼音 10月31日版 · 随包」：一行里放得下；完整日期在悬停提示和更新对话框里。
    func dictionaryVersionShort(_ version: KEYIDictionaryUpdate.Version?, installed: Bool) -> String {
        guard let version else { return isEnglish ? "version unknown" : "版本未知" }
        let source = installed ? (isEnglish ? "updated" : "已更新") : (isEnglish ? "bundled" : "随包")
        if isEnglish {
            return "rime-ice \(version.date.formatted(.dateTime.month(.abbreviated).day())) · \(source)"
        }
        let parts = Calendar(identifier: .gregorian).dateComponents([.month, .day], from: version.date)
        return "雾凇拼音 \(parts.month ?? 0)月\(parts.day ?? 0)日版 · \(source)"
    }

    var statsUserDictionaryShort: String { isEnglish ? "learned on this Mac, offline" : "本机自学习，不联网" }
    var statsLearnedShort: String { isEnglish ? "Learned" : "学到" }
    var statsPerAppShort: String { isEnglish ? "Per app" : "按 App 记住" }
    var statsFreeEngines: String { isEnglish ? "Hy-MT2 on this Mac · Apple" : "Hy-MT2 本机 · 苹果翻译" }
}
