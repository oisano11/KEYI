import Foundation

/// 用户选的翻译风格：只说「想要什么样的英文」，用哪个引擎由 KEYI 可译决定。
///
/// 输入法菜单、KEYI 可译菜单栏和设置首页共用这一份。值存在 KEYI 可译的偏好域里，
/// 翻译服务每次请求都重新读，所以在输入法菜单里切换立即生效。
public enum KEYITranslationStyle: String, CaseIterable, Sendable {
    case natural
    case business
    case faithful
    case americanCasual
    case blackAmerican
    case british

    public static let preferencesDomain = "com.keyi.input-translator"
    public static let storageKey = "translation.stylePreset"
    /// 每个风格现在实际用哪个引擎（模型名或服务名），由 KEYI 可译写入，输入法菜单直接显示。
    public static let engineLabelsKey = "translation.styleEngineLabels"
    /// 任一进程改了风格后发出，另一进程据此刷新界面。
    public static let didChangeNotification = Notification.Name("com.keyi.translation-style.changed")

    /// 只有地道口语三种要用大模型 API；其余用本机模型，文字不出本机。
    public var usesCloud: Bool {
        switch self {
        case .natural, .business, .faithful: false
        case .americanCasual, .blackAmerican, .british: true
        }
    }

    public var chineseName: String {
        switch self {
        case .natural: "自然"
        case .business: "正式商务"
        case .faithful: "贴近原文"
        case .americanCasual: "地道美式口语"
        case .blackAmerican: "黑人英语口语"
        case .british: "英式口语"
        }
    }

    public var englishName: String {
        switch self {
        case .natural: "Natural"
        case .business: "Business"
        case .faithful: "Close to Original"
        case .americanCasual: "Casual American"
        case .blackAmerican: "Black American Casual"
        case .british: "British Casual"
        }
    }

    public var chineseSummary: String {
        switch self {
        case .natural: "日常聊天，意思准、读着顺"
        case .business: "邮件、报价、合同，数字条款不出错"
        case .faithful: "尽量照原句翻，不润色"
        case .americanCasual: "像美国人发消息"
        case .blackAmerican: "美国黑人日常说话的语气，不另加脏话"
        case .british: "像英国人发消息"
        }
    }

    public var englishSummary: String {
        switch self {
        case .natural: "Everyday messages: accurate and easy to read"
        case .business: "Email, quotes, contracts: numbers and terms stay exact"
        case .faithful: "Follows the original wording without polishing"
        case .americanCasual: "Sounds like an American texting"
        case .blackAmerican: "Everyday Black American voice, no added swearing"
        case .british: "Sounds like a Brit texting"
        }
    }

    /// 从 KEYI 可译偏好域读出当前风格；没存过时为 nil。输入法进程用它显示和勾选。
    public static func stored() -> KEYITranslationStyle? {
        CFPreferencesAppSynchronize(preferencesDomain as CFString)
        let value = CFPreferencesCopyAppValue(storageKey as CFString, preferencesDomain as CFString)
        return (value as? String).flatMap(KEYITranslationStyle.init(rawValue:))
    }

    /// KEYI 可译写入的「风格 → 引擎名」；KEYI 可译还没写过时为空，菜单就只显示风格名。
    public static func storedEngineLabels() -> [KEYITranslationStyle: String] {
        CFPreferencesAppSynchronize(preferencesDomain as CFString)
        let value = CFPreferencesCopyAppValue(engineLabelsKey as CFString, preferencesDomain as CFString)
        guard let raw = value as? [String: String] else { return [:] }
        var labels: [KEYITranslationStyle: String] = [:]
        for (key, label) in raw {
            if let style = KEYITranslationStyle(rawValue: key) { labels[style] = label }
        }
        return labels
    }

    /// 输入法进程切换风格：写进 KEYI 可译偏好域，再通知 KEYI 可译刷新界面。
    public static func store(_ style: KEYITranslationStyle) {
        CFPreferencesSetAppValue(
            storageKey as CFString,
            style.rawValue as CFString,
            preferencesDomain as CFString
        )
        CFPreferencesAppSynchronize(preferencesDomain as CFString)
        DistributedNotificationCenter.default().postNotificationName(
            didChangeNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }
}
