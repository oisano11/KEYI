import AppKit
import Foundation

/// KEYI 的三套主题。每套有亮、暗两种，跟随系统外观自动切换。
///
/// 输入法面板和 KEYI 可译设置共用这一份配色（照抄设计稿 theme.css），
/// 值存在 KEYI 可译偏好域里，任一进程改了都发通知，另一进程据此重画。
public enum KEYITheme: String, CaseIterable, Sendable {
    /// 青瓷：本机天青蓝（饱和，设计稿第 18 版）+ 大模型琥珀（默认）。
    case celadon
    /// 墨蓝：本机靛蓝 + 大模型橙。
    case indigo
    /// 朱砂：本机朱红 + 大模型深青。
    case vermilion

    public var chineseName: String {
        switch self {
        case .celadon: "青瓷"
        case .indigo: "墨蓝"
        case .vermilion: "朱砂"
        }
    }

    public var englishName: String {
        switch self {
        case .celadon: "Celadon"
        case .indigo: "Indigo"
        case .vermilion: "Vermilion"
        }
    }

    /// 这套主题在亮色或暗色外观下的全部颜色。
    public func tokens(dark: Bool) -> KEYIThemeTokens {
        var tokens = dark ? KEYIThemeTokens.darkBase : KEYIThemeTokens.lightBase
        switch (self, dark) {
        case (.celadon, false):
            tokens.accent = .hex(0x0E6FA8); tokens.accentStrong = .hex(0x0A5A8A)
            tokens.accentTint = .hex(0xE0EFF8); tokens.onAccent = .hex(0xFFFFFF)
            tokens.api = .hex(0x9A4A0B); tokens.apiTint = .hex(0xFBEFE3)
        case (.celadon, true):
            tokens.accent = .hex(0x5BC0F0); tokens.accentStrong = .hex(0x9AD8F7)
            tokens.accentTint = .rgba(91, 192, 240, 0.18); tokens.onAccent = .hex(0x0B1820)
            tokens.api = .hex(0xF0A65E); tokens.apiTint = .rgba(240, 166, 94, 0.14)
        // 墨蓝、朱砂 2026-11-05 改色（用户：「墨蓝看着更像紫色，朱砂更像橙色——那是 Claude 的主题色」）：
        // 墨蓝从偏紫的宝蓝（色相 227°）改成墨色深蓝（218°），朱砂从橙红（12°）改成正红（4°）。
        case (.indigo, false):
            tokens.accent = .hex(0x1F437F); tokens.accentStrong = .hex(0x152F5C)
            tokens.accentTint = .hex(0xE2E9F4); tokens.onAccent = .hex(0xFFFFFF)
            tokens.api = .hex(0xA34A00); tokens.apiTint = .hex(0xFCEEDF)
        case (.indigo, true):
            tokens.accent = .hex(0x789FE2); tokens.accentStrong = .hex(0xA9C3EE)
            tokens.accentTint = .rgba(120, 159, 226, 0.16); tokens.onAccent = .hex(0x0B1528)
            tokens.api = .hex(0xFFAA5C); tokens.apiTint = .rgba(255, 170, 92, 0.14)
        case (.vermilion, false):
            tokens.accent = .hex(0xB5251C); tokens.accentStrong = .hex(0x8C1912)
            tokens.accentTint = .hex(0xF8E3E0); tokens.onAccent = .hex(0xFFFFFF)
            tokens.api = .hex(0x1F6A86); tokens.apiTint = .hex(0xE3F0F5)
            // 朱砂里危险色改用洋红，免得和强调色撞色。
            tokens.danger = .hex(0x9B1D5A); tokens.dangerTint = .hex(0xF8E6EF)
        case (.vermilion, true):
            tokens.accent = .hex(0xEB5850); tokens.accentStrong = .hex(0xF48C85)
            tokens.accentTint = .rgba(235, 88, 80, 0.16); tokens.onAccent = .hex(0x2A0705)
            tokens.api = .hex(0x6CC3E0); tokens.apiTint = .rgba(108, 195, 224, 0.14)
            tokens.danger = .hex(0xFF8FC0); tokens.dangerTint = .rgba(255, 143, 192, 0.14)
        }
        // 译文色（theme.css --trans）：亮色取深一档的强调色，暗色取强调色，和灰色的中文原文分开。
        tokens.trans = dark ? tokens.accent : tokens.accentStrong
        return tokens
    }
}

/// 一个颜色值（sRGB，0–1）。共享包不绑定 SwiftUI，界面层自己转成需要的类型。
public struct KEYIColorValue: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public static func hex(_ value: UInt32) -> KEYIColorValue {
        KEYIColorValue(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            alpha: 1
        )
    }

    public static func rgba(_ red: Int, _ green: Int, _ blue: Int, _ alpha: Double) -> KEYIColorValue {
        KEYIColorValue(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255, alpha: alpha)
    }

    public var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

/// 设计稿 theme.css 里的全部颜色变量。
public struct KEYIThemeTokens: Equatable, Sendable {
    public var bg, win, side, surface, surface2: KEYIColorValue
    public var ink, ink2, ink3, ink4: KEYIColorValue
    public var line, line2, tintWeak: KEYIColorValue
    public var glass, glassEdge: KEYIColorValue
    /// 光标旁磨砂玻璃的底色；透明度由用户设置决定，这里 alpha 为 1。
    public var glassBase: KEYIColorValue
    public var danger, dangerTint, knob: KEYIColorValue
    public var accent, accentStrong, accentTint, onAccent: KEYIColorValue
    public var api, apiTint: KEYIColorValue
    /// 译文文字色：中文原文用 ink-2 灰，英文译文用主题色，一眼分开（`tokens(dark:)` 里按亮暗设定）。
    public var trans: KEYIColorValue = .hex(0x000000)

    static let lightBase = KEYIThemeTokens(
        bg: .hex(0xE4E6EA), win: .hex(0xFBFBFC), side: .hex(0xF0F1F3),
        surface: .hex(0xFFFFFF), surface2: .hex(0xF1F2F4),
        ink: .hex(0x1C1D21), ink2: .hex(0x4F535C), ink3: .hex(0x62666F), ink4: .hex(0x8A8E96),
        line: .rgba(0, 0, 0, 0.08), line2: .rgba(0, 0, 0, 0.14), tintWeak: .rgba(0, 0, 0, 0.03),
        glass: .rgba(246, 246, 248, 0.9), glassEdge: .rgba(255, 255, 255, 0.55),
        glassBase: .rgba(250, 250, 252, 1),
        danger: .hex(0xB3261E), dangerTint: .hex(0xFBE9E8), knob: .hex(0xFFFFFF),
        accent: .hex(0x0E6FA8), accentStrong: .hex(0x0A5A8A), accentTint: .hex(0xE0EFF8),
        onAccent: .hex(0xFFFFFF), api: .hex(0x9A4A0B), apiTint: .hex(0xFBEFE3)
    )

    static let darkBase = KEYIThemeTokens(
        bg: .hex(0x121418), win: .hex(0x1B1D22), side: .hex(0x202228),
        surface: .hex(0x26292F), surface2: .hex(0x30333A),
        ink: .hex(0xECEDF0), ink2: .hex(0xB5B9C2), ink3: .hex(0x9CA1AB), ink4: .hex(0x737882),
        line: .rgba(255, 255, 255, 0.08), line2: .rgba(255, 255, 255, 0.16), tintWeak: .rgba(255, 255, 255, 0.04),
        glass: .rgba(40, 42, 48, 0.88), glassEdge: .rgba(255, 255, 255, 0.12),
        glassBase: .rgba(36, 38, 44, 1),
        danger: .hex(0xFF8A80), dangerTint: .rgba(255, 138, 128, 0.14), knob: .hex(0xF4F5F7),
        accent: .hex(0x5BC0F0), accentStrong: .hex(0x9AD8F7), accentTint: .rgba(91, 192, 240, 0.18),
        onAccent: .hex(0x0B1820), api: .hex(0xF0A65E), apiTint: .rgba(240, 166, 94, 0.14)
    )
}

/// 磨砂玻璃此刻的样子：模糊半径、玻璃底色的不透明度；设置窗口另有卡片底色的不透明度。
public struct KEYIGlassMaterial: Equatable, Sendable {
    public var blurRadius: Double
    public var tintAlpha: Double
    /// 设置窗口里卡片（半透明 surface）的不透明度；光标面板没有卡片，为 0。
    public var cardAlpha: Double = 0

    public init(blurRadius: Double, tintAlpha: Double, cardAlpha: Double = 0) {
        self.blurRadius = blurRadius
        self.tintAlpha = tintAlpha
        self.cardAlpha = cardAlpha
    }
}

/// 主题与磨砂玻璃的用户设置。存在 KEYI 可译偏好域，改动后发分布式通知，
/// 输入法进程收到后重画面板。
///
/// 玻璃只有一个「磨砂」值（2026-11-05 用户：「像苹果的磨砂玻璃那样，只需要一个调节」）：从通透到厚实，
/// 模糊半径和底色不透明度一起变，和苹果的材质从薄到厚一样。原来的透明度、模糊度两项不再读。
public enum KEYIAppearanceSettings {
    public static let preferencesDomain = KEYITranslationStyle.preferencesDomain
    public static let themeKey = "appearance.theme"
    public static let glassFrostKey = "appearance.glassFrost"
    public static let didChangeNotification = Notification.Name("com.keyi.appearance.changed")

    public static let defaultTheme = KEYITheme.celadon
    /// 磨砂程度，0（通透）–100（厚实）。
    public static let defaultGlassFrost = 50.0
    public static let glassFrostRange: ClosedRange<Double> = 0...100

    public static var theme: KEYITheme {
        (copyValue(themeKey) as? String).flatMap(KEYITheme.init(rawValue:)) ?? defaultTheme
    }

    public static var glassFrost: Double {
        number(glassFrostKey, default: defaultGlassFrost, range: glassFrostRange)
    }

    public static func store(theme: KEYITheme) {
        setValue(theme.rawValue as CFString, key: themeKey)
    }

    public static func store(glassFrost: Double) {
        setValue(clamped(glassFrost, glassFrostRange) as CFNumber, key: glassFrostKey)
    }

    // 磨砂值到玻璃的映射（2026-11-05 第二版，用户：「拖了没什么变化…拖的时候要明显」）。
    //
    // 看得出的差别是「背后透出来多少」和「透出来的有多糊」。两样都按几何级数走：磨砂每加 10，
    // 透出来的比例乘同一个倍数、模糊半径乘同一个倍数，所以 0–10 和 90–100 一样看得出变化；
    // 线性插值时前半段几乎没变化（底色 0.64→0.8 看着差不多），后半段才突然变实。
    //
    // 0 端只略模糊（半径 3），条纹清楚；100 端模糊 48、底色 0.96，条纹糊成色块。
    // 底色下限按「最通透时字还读得清」定，亮暗分开（见下面各常量）。

    /// 磨砂 0 / 100 时的模糊半径（点）。
    public static let glassBlurRange: ClosedRange<Double> = 3...48

    /// 光标旁面板的玻璃。`dark` 是面板此刻的外观。
    public static func panelGlass(frost: Double, dark: Bool) -> KEYIGlassMaterial {
        let f = clamped(frost, glassFrostRange) / 100
        let floor = dark ? tintFloorDark : tintFloorLight
        return KEYIGlassMaterial(
            blurRadius: geometric(f, glassBlurRange.lowerBound, glassBlurRange.upperBound),
            tintAlpha: 1 - geometric(f, 1 - floor, 1 - 0.96)
        )
    }

    /// 设置窗口的玻璃：窗口底色和面板同一套映射（页标题、分组小标题、提示行直接写在窗口底色上，
    /// 和面板上的字一样要读得清）；卡片和侧栏再叠一层 surface，跟着磨砂从 0.2 到 0.85，把卡片和缝隙分开。
    public static func windowGlass(frost: Double, dark: Bool) -> KEYIGlassMaterial {
        var glass = panelGlass(frost: frost, dark: dark)
        glass.cardAlpha = 1 - geometric(clamped(frost, glassFrostRange) / 100, 1 - 0.2, 1 - 0.85)
        return glass
    }

    // 底色下限按最坏的背景算对比度（WCAG，sRGB 混合；ui-review/round10 截图实测与算式一致）：
    // 亮色玻璃最怕黑底网页、黑色终端，暗色玻璃最怕白底网页。要求正文（ink）≥ 4.5:1、
    // 译文与说明（主题色、ink2）≈ 3:1。再往下压，译文和说明先读不清：
    // 亮色 0.55 时译文 2.4:1；暗色 0.64 时正文 4.0:1、译文 2.3:1。设置窗口底色曾用 0.4，
    // 黑底上页面说明、分组小标题读不出来（round10 实测）。

    /// 玻璃底色下限（磨砂 0）。亮色 0.63：黑底上正文 7.0:1、译文 3.0:1、ink2 3.2:1；
    /// 暗色 0.73：白底上正文 5.3:1、译文 3.0:1、ink2 3.2:1。
    public static let tintFloorLight = 0.63
    public static let tintFloorDark = 0.73

    /// `t`∈0…1 时从 `from` 按几何级数走到 `to`。
    private static func geometric(_ t: Double, _ from: Double, _ to: Double) -> Double {
        from * pow(to / from, t)
    }

    /// 当前主题在给定外观下的颜色。
    public static func tokens(dark: Bool) -> KEYIThemeTokens {
        theme.tokens(dark: dark)
    }

    /// 给定外观是不是暗色。
    public static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private static func copyValue(_ key: String) -> CFPropertyList? {
        CFPreferencesAppSynchronize(preferencesDomain as CFString)
        return CFPreferencesCopyAppValue(key as CFString, preferencesDomain as CFString)
    }

    private static func number(_ key: String, default fallback: Double, range: ClosedRange<Double>) -> Double {
        guard let value = copyValue(key) as? NSNumber else { return fallback }
        return clamped(value.doubleValue, range)
    }

    private static func clamped(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private static func setValue(_ value: CFPropertyList, key: String) {
        CFPreferencesSetAppValue(key as CFString, value, preferencesDomain as CFString)
        CFPreferencesAppSynchronize(preferencesDomain as CFString)
        DistributedNotificationCenter.default().postNotificationName(
            didChangeNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }
}
