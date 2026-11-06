import AppKit
import KEYITranslationClient

/// 输入法所有浮窗（候选与对照面板、Toast）共用的外观：磨砂玻璃、圆角 14、内外两道描边，
/// 颜色取 KEYI 当前主题，亮暗跟随系统外观。
///
/// 玻璃分两层：系统模糊层只留模糊本身（材质自带的灰底藏掉），上面再叠一层主题玻璃底色，和设计稿的
/// backdrop-filter 加半透明底一致。两层都由 KEYI 可译设置「高级 › 外观」里一个「磨砂」值决定（通透到厚实，
/// 2026-11-05 由透明度、模糊度两项合成一项），改动经分布式通知送到这里，面板立即重画。
@MainActor
enum KeyiPanelChrome {
    /// 14.5：只有候选时面板高 29，正好是两端全圆的胶囊（照苹果拼音）。
    static let cornerRadius: CGFloat = 14.5

    private(set) static var theme = KEYIAppearanceSettings.theme
    private(set) static var glassFrost = KEYIAppearanceSettings.glassFrost

    /// 实际画的玻璃：一个「磨砂」值同时决定模糊半径和底色不透明度（见 `KEYIAppearanceSettings.panelGlass`），
    /// 底色下限亮暗不同。
    static func glass(dark: Bool) -> KEYIGlassMaterial {
        KEYIAppearanceSettings.panelGlass(frost: glassFrost, dark: dark)
    }

    static func isDark(_ view: NSView) -> Bool {
        KEYIAppearanceSettings.isDark(view.effectiveAppearance)
    }

    /// 这个视图此刻该用的主题颜色。
    static func tokens(for view: NSView) -> KEYIThemeTokens {
        theme.tokens(dark: KEYIAppearanceSettings.isDark(view.effectiveAppearance))
    }

    /// 给面板铺上磨砂玻璃背景和描边，`content` 铺满在上面。
    static func install(in panel: NSPanel, content: NSView) {
        let glass = KeyiGlassView(frame: NSRect(origin: .zero, size: panel.frame.size), content: content)
        glass.autoresizingMask = [.width, .height]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = glass
    }

    /// 本进程内「外观已换」的通知：所有面板的玻璃据此重画。
    fileprivate static let reloadedNotification = Notification.Name("KeyiPanelChrome.reloaded")

    /// 重新读用户设置，有变化就让所有面板重画。KEYI 可译改设置时发的分布式通知会触发它；
    /// 面板每次重新出现前也调一次，万一漏了通知，下次出现时照样用上新值。
    static func syncFromPreferences() {
        apply(theme: KEYIAppearanceSettings.theme, glassFrost: KEYIAppearanceSettings.glassFrost)
    }

    /// 换上一组外观，有变化就让所有面板重画。
    static func apply(theme: KEYITheme, glassFrost: Double) {
        let next = (theme, glassFrost)
        guard next != (self.theme, self.glassFrost) else { return }
        (self.theme, self.glassFrost) = next
        NotificationCenter.default.post(name: reloadedNotification, object: nil)
    }

    private static var preferencesObserver: NSObjectProtocol?

    /// 第一块面板建起来时开始听 KEYI 可译的外观通知，整个进程只听一份。
    fileprivate static func observePreferences() {
        guard preferencesObserver == nil else { return }
        preferencesObserver = DistributedNotificationCenter.default().addObserver(
            forName: KEYIAppearanceSettings.didChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { syncFromPreferences() }
        }
    }

    /// 可拉伸的圆角蒙版：四角保持圆角，中间拉伸。模糊在窗口之外合成，图层圆角裁不到它，要靠蒙版。
    fileprivate static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// 面板的根视图：模糊层、玻璃底色、内容、描边，自下而上叠放，整体裁成圆角。
private final class KeyiGlassView: NSView {
    private let effect = KeyiBlurView()
    private let tint = KeyiGlassTintView()
    private let border = KeyiPanelBorderView()
    private var observer: NSObjectProtocol?

    init(frame: NSRect, content: NSView) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = KeyiPanelChrome.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        effect.material = .menu
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = KeyiPanelChrome.roundedMask(radius: KeyiPanelChrome.cornerRadius)
        for view in [effect, tint, content, border] {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
        applyGlass()

        KeyiPanelChrome.observePreferences()
        observer = NotificationCenter.default.addObserver(
            forName: KeyiPanelChrome.reloadedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyGlass()
                self?.redrawAll()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("KeyiGlassView 不支持从 nib 初始化")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        redrawAll()
    }

    private func applyGlass() {
        let blur = KeyiPanelChrome.glass(dark: KeyiPanelChrome.isDark(self)).blurRadius
        effect.radius = blur
        effect.isHidden = blur <= 0
    }

    /// 主题或外观变了，面板里每一层都要重新取色。
    private func redrawAll() {
        func mark(_ view: NSView) {
            view.needsDisplay = true
            view.subviews.forEach(mark)
        }
        mark(self)
        window?.invalidateShadow()
    }
}

/// 只做模糊的系统材质层。
///
/// 菜单材质在模糊上面自带两层几乎不透明的灰底（图层名 `fill`、`tone`，另有一层 `Chameleon`），
/// 再叠玻璃色就成了实心浅灰，看不出背后的东西（11-04 用户实测）。这里把它们藏掉，只留 `backdrop`
/// 这层模糊，并把它的高斯模糊半径设成用户设置。图层由 AppKit 在布局和换外观时重建，所以每次都重新处理；
/// 找不到这些图层时（系统改了实现）就保持系统原样，只是偏实心。
private final class KeyiBlurView: NSVisualEffectView {
    var radius: Double = KEYIAppearanceSettings.panelGlass(frost: KEYIAppearanceSettings.defaultGlassFrost, dark: false).blurRadius {
        didSet { stripMaterial() }
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

/// 玻璃底色：主题玻璃色，不透明度取用户设置。
private final class KeyiGlassTintView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let base = KeyiPanelChrome.tokens(for: self).glassBase.nsColor
        base.withAlphaComponent(KeyiPanelChrome.glass(dark: KeyiPanelChrome.isDark(self)).tintAlpha).setFill()
        bounds.fill()
    }
}

/// 外圈一道主题 line 细线；暗色下内圈再加一道 glass-edge 高光。
private final class KeyiPanelBorderView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let tokens = KeyiPanelChrome.tokens(for: self)
        let radius = KeyiPanelChrome.cornerRadius
        let outer = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: radius - 0.5,
            yRadius: radius - 0.5
        )
        outer.lineWidth = 1
        tokens.line.nsColor.setStroke()
        outer.stroke()
        // 内圈高光只在暗色下画：亮色玻璃本身就浅，再加一圈白线就成了双线。
        guard KeyiPanelChrome.isDark(self) else { return }
        let inner = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5),
            xRadius: radius - 1.5,
            yRadius: radius - 1.5
        )
        inner.lineWidth = 1
        tokens.glassEdge.nsColor.setStroke()
        inner.stroke()
    }
}

/// 中英混排按视觉大小配对：实现在共享包 `KEYIMixedType`（KEYI 可译设置里的面板预览也用它）。
typealias KeyiMixedType = KEYIMixedType
