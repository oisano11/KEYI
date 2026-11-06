import AppKit
import KEYITranslationClient
import SwiftUI

/// 设置窗口与菜单的配色：取 KEYI 当前主题（青瓷、墨蓝、朱砂，设计稿 theme.css），
/// 亮暗跟随系统外观。颜色在绘制时按当前主题解析；换主题后设置窗口整页重建（见 SettingsRootView）。
enum KEYIPalette {
    /// 当前主题。AppModel 换主题时同步改这里；颜色解析可能在任意线程，读写都很少，不加锁。
    nonisolated(unsafe) static var theme = KEYIAppearanceSettings.theme

    /// 主题强调色：本机翻译、选中、勾、侧栏选中行、控件强调。
    static let accent = token(\.accent)
    /// 强调色做字时加深一档。
    static let accentText = token(\.accentStrong)
    /// 强调色的浅底：选中卡片、侧栏选中行。
    static let accentTint = token(\.accentTint)
    /// 铺在强调色上的文字和图标。
    static let onAccent = token(\.onAccent)
    /// 系统控件（分段、滑块、下拉）的强调。
    static let controlTint = accent
    /// 英文译文的字色（亮色 accent-strong、暗色 accent），和中文分开。
    static let trans = token(\.trans)
    /// 大模型 API 色。
    static let api = token(\.api)
    static let apiTint = token(\.apiTint)
    static let danger = token(\.danger)
    /// 窗口内容区背景。
    static let canvas = token(\.win)
    /// 侧栏背景。
    static let side = token(\.side)
    /// 卡片、分组底色。
    static let surface = token(\.surface)
    /// 次一级底色：提示条、标签、进度槽。
    static let surface2 = token(\.surface2)
    static let ink = token(\.ink)
    static let ink2 = token(\.ink2)
    static let ink3 = token(\.ink3)
    static let ink4 = token(\.ink4)
    static let line = token(\.line)
    static let line2 = token(\.line2)
    static let tintWeak = token(\.tintWeak)
    /// 中性灰：未选中侧栏项的图标。
    static let neutral = ink4
    static let local = accent
    static let cloud = api

    /// 设置窗口是磨砂玻璃（2026-11-05 用户：「设置页面的也要磨砂和透明」）。卡片用半透明的 surface，
    /// 不透明度跟磨砂值走（`KEYIAppearanceSettings.windowGlass` 的 `cardAlpha`）：拖滑块时卡片底下
    /// 透出来的多少也跟着变，不只是卡片之间的缝。最通透时和窗口底色叠起来，卡片里的字在白底、黑底上都读得清。
    static func card(frost: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = KEYIAppearanceSettings.isDark(appearance)
            let alpha = KEYIAppearanceSettings.windowGlass(frost: frost, dark: isDark).cardAlpha
            return theme.tokens(dark: isDark).surface.nsColor.withAlphaComponent(alpha)
        })
    }

    /// 侧栏的底：和卡片同一不透明度的 side 色，侧栏的字和卡片里的字一样读得清。
    static func sidePane(frost: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = KEYIAppearanceSettings.isDark(appearance)
            let alpha = KEYIAppearanceSettings.windowGlass(frost: frost, dark: isDark).cardAlpha
            return theme.tokens(dark: isDark).side.nsColor.withAlphaComponent(alpha)
        })
    }
    /// 卡片里的次一级底：次要按钮、提示条、未选中的小块。
    static let chip = translucent(\.ink, light: 0.055, dark: 0.08)
    /// 侧栏在玻璃上叠一层主题浅色，换主题时整窗跟着变色。
    static let sideWash = translucent(\.accentTint, light: 0.55, dark: 0.45)

    static func nsColor(_ keyPath: KeyPath<KEYIThemeTokens, KEYIColorValue> & Sendable) -> NSColor {
        NSColor(name: nil) { appearance in
            theme.tokens(dark: KEYIAppearanceSettings.isDark(appearance))[keyPath: keyPath].nsColor
        }
    }

    private static func token(_ keyPath: KeyPath<KEYIThemeTokens, KEYIColorValue> & Sendable) -> Color {
        Color(nsColor: nsColor(keyPath))
    }

    /// 主题颜色乘一个不透明度（亮暗分开），用在玻璃上的半透明层。
    private static func translucent(
        _ keyPath: KeyPath<KEYIThemeTokens, KEYIColorValue> & Sendable,
        light: CGFloat,
        dark: CGFloat
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = KEYIAppearanceSettings.isDark(appearance)
            let color = theme.tokens(dark: isDark)[keyPath: keyPath].nsColor
            return color.withAlphaComponent(color.alphaComponent * (isDark ? dark : light))
        })
    }
}

/// 中英混排按视觉大小配对（与输入法面板的 `KeyiMixedType` 同一规则）：同一磅数下汉字几乎撑满字框，
/// 小写拉丁字母只有一半高。所以含小写字母的拉丁串按汉字字号的 1.1 倍排，字重相同；全大写和数字不放大。
///
/// 中文标点（，。？「」等）改用 PingFang SC 排：系统界面字体（PingFang UI）把它们压成半角宽，
/// 「英文?」的问号看着像半角。
enum KEYIMixedText {
    static let latinScale: CGFloat = 1.1

    private enum Run { case latin, punctuation, other }

    static func text(_ string: String, size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Text {
        var result = Text("")
        var run = ""
        var kind = Run.other
        func flush() {
            guard !run.isEmpty else { return }
            let font: Font
            switch kind {
            case .latin:
                let scaled = run.contains(where: \.isLowercase)
                font = .system(size: scaled ? size * latinScale : size, weight: weight, design: design)
            case .punctuation:
                font = design == .default ? .custom(pingFang(weight), fixedSize: size) : .system(size: size, weight: weight, design: design)
            case .other:
                font = .system(size: size, weight: weight, design: design)
            }
            result = result + Text(verbatim: run).font(font)
            run = ""
        }
        for character in string {
            let next = runKind(character)
            if next != kind { flush(); kind = next }
            run.append(character)
        }
        flush()
        return result
    }

    /// PingFang SC 按字重取 PostScript 名（只给家族名时 SwiftUI 找不到，会退回界面字体）。
    private static func pingFang(_ weight: Font.Weight) -> String {
        switch weight {
        case .semibold, .bold, .heavy, .black: "PingFangSC-Semibold"
        case .medium: "PingFangSC-Medium"
        default: "PingFangSC-Regular"
        }
    }

    private static func runKind(_ character: Character) -> Run {
        let scalars = character.unicodeScalars
        if scalars.allSatisfy({ $0.isASCII && CharacterSet.alphanumerics.contains($0) }) { return .latin }
        // CJK 符号和标点、全角形式里的标点。
        if let scalar = scalars.first, scalars.count == 1,
           (0x3000...0x303F).contains(scalar.value)
            || ((0xFF00...0xFF65).contains(scalar.value) && !CharacterSet.alphanumerics.contains(scalar)) {
            return .punctuation
        }
        return .other
    }
}

/// 当前磨砂值（0–100），由设置窗口根视图放进环境，卡片、侧栏据此取底色不透明度。
private struct KEYIGlassFrostKey: EnvironmentKey {
    static let defaultValue = KEYIAppearanceSettings.defaultGlassFrost
}

extension EnvironmentValues {
    var keyiGlassFrost: Double {
        get { self[KEYIGlassFrostKey.self] }
        set { self[KEYIGlassFrostKey.self] = newValue }
    }
}
