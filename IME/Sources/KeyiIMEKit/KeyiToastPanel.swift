import AppKit

/// 极简提示浮层：在屏幕中央偏上短暂显示一行状态文字，用于「开关已切换」与自动翻译
/// 失败原因的即时反馈。
///
/// 不接收鼠标或键盘事件，不改变任何输入行为。
@MainActor
final class KeyiToastPanel {
    private static var shared: KeyiToastPanel?

    /// 显示一行提示，`duration` 秒后自动消失；重复调用会替换当前提示。
    static func show(text: String, duration: TimeInterval = 1.2) {
        if shared == nil { shared = KeyiToastPanel() }
        shared?.present(text: text, duration: duration)
    }

    private let panel: NSPanel
    private let label: NSTextField
    private var hideWorkItem: DispatchWorkItem?

    private init() {
        let rect = NSRect(x: 0, y: 0, width: 200, height: 44)
        panel = NSPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        // 和光标旁的面板同一套外观：毛玻璃、圆角 12、描边。
        let container = NSView(frame: rect)
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.leadingAnchor.constraint(
                greaterThanOrEqualTo: container.leadingAnchor,
                constant: 14
            ),
            label.trailingAnchor.constraint(
                lessThanOrEqualTo: container.trailingAnchor,
                constant: -14
            ),
        ])
        KeyiPanelChrome.install(in: panel, content: container)

        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
    }

    private func present(text: String, duration: TimeInterval) {
        KeyiPanelChrome.syncFromPreferences()
        label.stringValue = text
        let size = label.intrinsicContentSize
        let width = max(160, size.width + 40)
        let height = max(44, size.height + 20)
        let screen = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // 屏幕上方居中偏上，避开输入光标与候选窗区域。
        let origin = NSPoint(
            x: screen.midX - width / 2,
            y: screen.maxY - height - 80
        )
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        panel.orderFrontRegardless()

        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.panel.orderOut(nil) }
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + duration,
            execute: work
        )
    }
}
