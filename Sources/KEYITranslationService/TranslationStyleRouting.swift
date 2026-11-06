import KEYICore
import KEYITranslationClient

/// 按风格实际用哪个引擎、带什么场景和英语风格去翻译。
public struct TranslationRoute: Equatable, Sendable {
    public let providerID: TranslationProviderID
    public let scene: TranslationScene
    public let englishStyle: EnglishStyle
    /// 选了云端风格但云端没配好，这次按「自然」翻。
    public let usesNaturalInstead: Bool
}

/// 风格 → 引擎：本地风格有本地模型就用本地模型，没下载就暂用苹果翻译；
/// 云端风格用已配置的云端服务，没配好就按「自然」走本地。
public enum TranslationStyleRouting {
    public static func route(
        for style: KEYITranslationStyle,
        localModelReady: Bool,
        cloudProvider: TranslationProviderID?
    ) -> TranslationRoute {
        if style.usesCloud, let cloudProvider {
            return TranslationRoute(
                providerID: cloudProvider,
                scene: scene(for: style),
                englishStyle: englishStyle(for: style),
                usesNaturalInstead: false
            )
        }
        let localStyle = style.usesCloud ? KEYITranslationStyle.natural : style
        return TranslationRoute(
            providerID: localModelReady ? .localModel : .appleSystem,
            scene: scene(for: localStyle),
            englishStyle: englishStyle(for: localStyle),
            usesNaturalInstead: style.usesCloud
        )
    }

    public static func scene(for style: KEYITranslationStyle) -> TranslationScene {
        switch style {
        case .business: .business
        case .faithful: .faithful
        case .natural, .americanCasual, .blackAmerican, .british: .automatic
        }
    }

    public static func englishStyle(for style: KEYITranslationStyle) -> EnglishStyle {
        switch style {
        case .americanCasual: .westCoast
        case .blackAmerican: .blackAmerican
        case .british: .british
        case .natural, .business, .faithful: .automatic
        }
    }

    /// 从旧版「翻译方式/场景/英语风格」三项设置推出最接近的风格，只在第一次升级时用。
    public static func migratedStyle(from preferences: TranslationPreferences) -> KEYITranslationStyle {
        switch preferences.scene {
        case .business: return .business
        case .faithful: return .faithful
        case .automatic, .dailyChat, .socialMedia: break
        }
        guard preferences.providerID.requiresAPIConfiguration else { return .natural }
        switch preferences.englishStyle {
        case .blackAmerican: return .blackAmerican
        case .british: return .british
        case .automatic, .standardAmerican, .westCoast: return .americanCasual
        }
    }
}
