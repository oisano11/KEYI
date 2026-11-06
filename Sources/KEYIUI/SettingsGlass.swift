import AppKit
import KEYITranslationClient
import SwiftUI

/// 设置窗口整窗的磨砂玻璃：和光标旁面板同一套做法、同一个「磨砂」设置（2026-11-05 用户：「设置页面的也要
/// 磨砂和透明啊，这个早就说过」）。系统模糊层只留模糊本身，上面叠主题玻璃底色；模糊半径和底色不透明度
/// 都由磨砂值决定（`KEYIAppearanceSettings.windowGlass`）。拖「高级」里的磨砂滑块时，设置窗口自己就跟着变；
/// 卡片和侧栏的底色也跟着磨砂值走（`KEYIPalette.card(frost:)`，经环境值 `keyiGlassFrost` 传下去）。
///
/// 窗口本身不画背景（见 `SettingsWindowController`），背后的桌面和窗口经这里模糊后透出来。
struct SettingsGlass: NSViewRepresentable {
    /// 磨砂程度 0–100（通透到厚实）。
    let frost: Double

    func makeNSView(context: Context) -> SettingsGlassView {
        SettingsGlassView()
    }

    func updateNSView(_ view: SettingsGlassView, context: Context) {
        view.apply(frost: frost)
    }
}

final class SettingsGlassView: NSView {
    private let effect = SettingsBlurView()
    private let tint = SettingsGlassTintView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        effect.material = .menu
        effect.blendingMode = .behindWindow
        effect.state = .active
        for view in [effect, tint] {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SettingsGlassView 不支持从 nib 初始化")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func apply(frost: Double) {
        let blur = KEYIAppearanceSettings.windowGlass(frost: frost, dark: false).blurRadius
        effect.radius = blur
        effect.isHidden = blur <= 0
        if tint.frost != frost {
            tint.frost = frost
            tint.needsDisplay = true
        }
    }
}

/// 只做模糊的系统材质层。菜单材质在模糊上面自带几层几乎不透明的灰底（`fill`、`tone`、`Chameleon`），
/// 叠上玻璃色就成了实心浅灰；这里把它们藏掉，只留 `backdrop` 的模糊，半径设成用户设置。
/// 与输入法面板的 `KeyiBlurView` 同一做法（两个进程各一份）。图层由 AppKit 在布局和换外观时重建，
/// 每次都重新处理；找不到这些图层时（系统改了实现）保持系统原样，只是偏实心。
private final class SettingsBlurView: NSVisualEffectView {
    var radius: Double = 30 {
        didSet { if radius != oldValue { stripMaterial() } }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        stripMaterial()
    }

    override func updateLayer() {
        super.updateLayer()
        stripMaterial()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    private func stripMaterial() {
        guard let layer else { return }
        visit(layer)
    }

    private func visit(_ layer: CALayer) {
        switch layer.name {
        case "fill", "tone", "Chameleon":
            layer.isHidden = true
        case "backdrop":
            layer.setValue(radius, forKeyPath: "filters.gaussianBlur.inputRadius")
        default:
            break
        }
        layer.sublayers?.forEach(visit)
    }
}

/// 主题玻璃底色，不透明度由磨砂值决定（亮暗下限不同）；亮暗跟随窗口外观。
private final class SettingsGlassTintView: NSView {
    var frost: Double = KEYIAppearanceSettings.defaultGlassFrost

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = KEYIAppearanceSettings.isDark(effectiveAppearance)
        let alpha = KEYIAppearanceSettings.windowGlass(frost: frost, dark: dark).tintAlpha
        KEYIPalette.theme.tokens(dark: dark).glassBase.nsColor.withAlphaComponent(alpha).setFill()
        bounds.fill()
    }
}
