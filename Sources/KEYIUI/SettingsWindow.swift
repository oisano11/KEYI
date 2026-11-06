import SwiftUI

/// 单例设置窗口；菜单与快捷键入口都汇聚到这里，
/// 深链定位由 AppModel.settingsSection 驱动。
@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    /// 默认宽度：侧栏加一栏内容，翻译风格三张卡并排正好放下（2026-11-05 收紧，原 900）。
    static let defaultWidth: CGFloat = 780
    static let minimumWidth: CGFloat = 720

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.defaultWidth, height: 520),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        // 标题栏透明、不写窗口标题：每页标题写在红绿灯那一行，侧栏和内容一直铺到顶。
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        // 磨砂玻璃（2026-11-05）：窗口自己不画背景，整窗由 SettingsGlass 模糊背后的内容再叠主题玻璃色。
        window.isOpaque = false
        window.backgroundColor = .clear
        // 高度跟着内容走（见 fitHeight），宽度用户可以拖。
        window.contentMinSize = NSSize(width: Self.minimumWidth, height: 300)
        window.center()
        super.init(window: window)
        window.contentView = NSHostingView(
            rootView: SettingsRootView(model: .shared)
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SettingsWindowController 不支持从 nib 初始化")
    }

    func show() {
        window?.title = AppModel.shared.strings.settingsTitle
        // 接了多台显示器时，启动时居中的位置可能在用户没在看的那块屏上；没打开时移到鼠标所在的屏幕中央。
        if let window, !window.isVisible, let screen = NSScreen.screens.first(where: {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            window.setFrameOrigin(NSPoint(
                x: visible.midX - window.frame.width / 2,
                y: visible.midY - window.frame.height / 2
            ))
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 窗口高度正好装下当前页的内容：切页、展开「高级」、出现提示时跟着变，顶边不动；
    /// 超过屏幕可用高度时停在屏幕高度，其余靠滚动。
    func fitHeight(toContent height: CGFloat) {
        guard let window, height > 0 else { return }
        let screen = window.screen ?? NSScreen.main
        let maxHeight = (screen?.visibleFrame.height ?? 900) - 40
        let contentHeight = min(ceil(height), maxHeight)
        let current = window.contentRect(forFrameRect: window.frame)
        guard abs(current.height - contentHeight) > 1 else { return }
        var frame = window.frameRect(forContentRect: NSRect(
            x: current.minX, y: current.maxY - contentHeight,
            width: current.width, height: contentHeight
        ))
        // 往下长时别长出屏幕底边：整体往上挪。
        if let visible = screen?.visibleFrame, frame.minY < visible.minY {
            frame.origin.y = visible.minY
        }
        window.setFrame(frame, display: true, animate: window.isVisible)
    }
}

/// 当前页内容（不含滚动）的实际高度，用来让窗口高度贴合内容。
private struct SettingsContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 左边侧栏三个栏目：翻译风格、统计、高级；右边显示选中的那一栏。
/// 栏目跟着 `AppModel.settingsSection` 走，菜单和深链（去配置大模型、旧的快捷键入口）直接落到对应栏目：
/// 服务、本地模型、目标语言和原「通用」三项都在「高级」里。
struct SettingsRootView: View {
    @ObservedObject var model: AppModel

    enum Pane { case translation, statistics, advanced }

    private var pane: Pane {
        switch model.settingsSection {
        case .translation: .translation
        case .statistics: .statistics
        case .providers, .hotKey, .general: .advanced
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(model: model, pane: pane)
                .frame(width: Self.sidebarWidth)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(KEYIPalette.sideWash.ignoresSafeArea())
                .background(KEYIPalette.sidePane(frost: model.glassFrost).ignoresSafeArea())
                // 侧栏右边一条 line 色细线。不能单独放一个忽略安全区的 Rectangle：那样画出来丢了透明度，
                // 暗色下是一条纯白线。
                .overlay(alignment: .trailing) {
                    KEYIPalette.line.frame(width: 1).ignoresSafeArea()
                }
            Group {
                switch pane {
                case .translation: TranslationPage(model: model)
                case .statistics: StatisticsPage(model: model)
                case .advanced: AdvancedPage(model: model)
                }
            }
            .id(pane)
            .transition(.opacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        // 整窗磨砂玻璃，取「高级 › 外观」里同一个磨砂值，拖滑块时这里当场跟着变。
        .background(SettingsGlass(frost: model.glassFrost).ignoresSafeArea())
        .environment(\.keyiGlassFrost, model.glassFrost)
        // 颜色在绘制时按主题解析；换主题后整页重建，所有颜色立即换上。
        .id(model.appearanceTheme)
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: SettingsWindowController.minimumWidth, minHeight: 300)
        .tint(KEYIPalette.controlTint)
        .onPreferenceChange(SettingsContentHeightKey.self) { height in
            SettingsWindowController.shared.fitHeight(toContent: height)
        }
        .sheet(isPresented: $model.showsDictionaryUpdateSheet) {
            DictionaryUpdateSheet(model: model)
        }
        .onAppear { model.reloadTranslationStyle() }
    }

    static let sidebarWidth: CGFloat = 164
    /// 透明标题栏（红绿灯）那一行的高度：页标题竖直居中在这一行里，侧栏从它下面开始。
    static let titleBarHeight: CGFloat = 30
}

/// 报告一块内容的自然高度（页标题已在内容里，从窗口顶边算起），窗口按它定高。
/// 只能挂在不被拉伸的内容上，否则量到的是窗口高度，窗口就再也缩不回去。
struct ReportsHeight: ViewModifier {
    func body(content: Content) -> some View {
        content.background(GeometryReader { geometry in
            Color.clear.preference(key: SettingsContentHeightKey.self, value: geometry.size.height)
        })
    }
}

// MARK: - 侧栏

private struct SettingsSidebar: View {
    @ObservedObject var model: AppModel
    let pane: SettingsRootView.Pane

    var body: some View {
        let strings = model.strings
        VStack(alignment: .leading, spacing: 2) {
            row(.translation, section: .translation, title: strings.translationStyle, symbol: "text.alignleft")
            row(.statistics, section: .statistics, title: strings.statisticsTab, symbol: "chart.bar")
            row(.advanced, section: .general, title: strings.advancedSettings, symbol: "gearshape")
            Spacer(minLength: 12)
            Text(footer(strings))
                .font(.system(size: 11))
                .foregroundStyle(KEYIPalette.ink3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
        }
        .padding(.horizontal, 8)
        .padding(.top, SettingsRootView.titleBarHeight + 6)
    }

    /// 三页一样：应用名和版本。统计页的隐私说明写在页内，不在侧栏重复。
    private func footer(_ strings: InterfaceStrings) -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return [strings.appName, version].compactMap { $0 }.joined(separator: " ")
    }

    private func row(
        _ target: SettingsRootView.Pane,
        section: AppModel.SettingsSection,
        title: String,
        symbol: String
    ) -> some View {
        let selected = pane == target
        return SidebarRow(selected: selected) {
            withAnimation(.snappy(duration: 0.2)) { model.settingsSection = section }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
            }
        }
    }
}

/// 侧栏一行：选中时主题浅底、深一档的强调色字，鼠标移上去淡淡一层底色。
private struct SidebarRow<Label: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .padding(.horizontal, 10)
                .foregroundStyle(selected ? KEYIPalette.accentText : KEYIPalette.ink)
                .background(
                    selected
                        ? AnyShapeStyle(KEYIPalette.accentTint)
                        : AnyShapeStyle(KEYIPalette.ink.opacity(hovering ? 0.06 : 0)),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.1)) { hovering = inside }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
