import Foundation

/// 「统计」栏目的文案。
extension InterfaceStrings {
    var statisticsTab: String { isEnglish ? "Statistics" : "统计" }
    var statisticsDescription: String {
        isEnglish
            ? "Counts only: what you write is never stored. API costs are estimates from list prices; your provider's bill is authoritative."
            : "只记数字，不记你写的内容。费用按标价估算，以各家账单为准。"
    }
    var statsToday: String { isEnglish ? "Today" : "今天" }
    var statsHanzi: String { isEnglish ? "Chinese characters" : "汉字" }
    var statsTranslatedWords: String { isEnglish ? "Translated words" : "译文词" }
    var statsCost: String { isEnglish ? "API cost" : "API 费用" }
    var statsDate: String { isEnglish ? "Date" : "日期" }
    var statsRequests: String { isEnglish ? "Requests" : "请求" }
    var statsTokens: String { isEnglish ? "Tokens in / out" : "输入 / 输出 token" }
    var statsPricesNote: String {
        isEnglish
            ? "Defaults follow each provider's list price for its default model. Apple Translation and the local Hy-MT2 model are free. Fill in your relay's own price."
            : "默认按各家默认模型的标价。苹果翻译和本地 Hy-MT2 不花钱。中转站请填它自己的价格。"
    }
    var statsInput: String { isEnglish ? "Input" : "输入" }
    var statsOutput: String { isEnglish ? "Output" : "输出" }
    var statsResetPrice: String { isEnglish ? "Default" : "恢复默认" }
    var statsUserDictionary: String { isEnglish ? "User dictionary" : "用户词库" }
    var statsUserDictionaryUnavailable: String {
        isEnglish ? "KEYI Pinyin is not installed." : "没有安装 KEYI 拼音输入法。"
    }
    var statsExport: String { isEnglish ? "Export…" : "导出…" }
    var statsClear: String { isEnglish ? "Clear…" : "清空…" }
    var statsClearTitle: String { isEnglish ? "Clear the learned words?" : "清空学到的词？" }
    func statsClearMessage(_ backupPath: String) -> String {
        isEnglish
            ? "Candidates go back to the default order. A backup is exported first to \(backupPath)."
            : "候选会回到默认顺序。清空前会先导出一份备份到 \(backupPath)。"
    }
    var statsClearConfirm: String { isEnglish ? "Clear" : "清空" }
    func statsExported(_ count: Int) -> String {
        isEnglish ? "Exported \(count) words." : "已导出 \(count) 个词。"
    }
    var statsExportFailed: String { isEnglish ? "Export failed." : "导出失败。" }
    var statsCleared: String { isEnglish ? "Cleared. The backup is in the backups folder." : "已清空，备份在 backups 文件夹。" }
    var statsClearPending: String {
        isEnglish
            ? "KEYI Pinyin is not running; the words are cleared the next time it starts."
            : "KEYI 拼音没在运行，下次启动时清空。"
    }
    var statsClearFailed: String {
        isEnglish ? "Could not back up the dictionary, so nothing was cleared." : "备份没有成功，没有清空。"
    }
}
