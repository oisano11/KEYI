import AppKit

/// 光标旁那个面板（上候选、下中英对照，`KeyiCompositionPanel`）的摆放规则。
///
/// - 放在光标所在行的下方；下方放不下时放到上方。面板不盖住光标那一行，
///   也不盖住正在打的这段字折行占过的其它行（`compositionLines`）。
/// - 左边缘对着光标，靠屏幕边时往里收。
/// - 同一行里打字时，面板只朝远离光标的方向伸缩（由面板锁住位置，见 `KeyiCompositionPanel`）。
public enum KeyiPanelLayout {
    /// Set by the `--diagnose-session*` runs before the first panel is created. The
    /// checks drive real sessions, so the composition panel is really ordered
    /// front; with this set it is fully transparent, so a test run never
    /// flashes 你好 over whatever window the user is working in. `isVisible` still
    /// reports what the checks expect.
    nonisolated(unsafe) public static var invisibleForDiagnostics = false

    /// Diagnostics: the candidate strip for these candidates when the screen allows
    /// `maxWidth`: its width, whether every candidate is drawn inside it, and the text
    /// drawn for each (long ones end in "…").
    @MainActor
    public static func candidateStripForDiagnostics(
        candidates: [String],
        maxWidth: CGFloat
    ) -> (width: CGFloat, fits: Bool, texts: [String]) {
        let layout = KeyiCandidateContentView.layout(texts: candidates, maxWidth: maxWidth)
        let lastStart = layout.candidateX.last ?? 0
        let fits = layout.candidateX.allSatisfy { $0 >= KeyiCandidateContentView.horizontalPadding }
            && lastStart < layout.size.width
        return (layout.size.width, fits, layout.texts)
    }

    /// 面板最宽多少。乱打一长串拼音时候选很长，不设上限面板会横跨整个屏幕、盖住别的
    /// 窗口（11-05 用户截图）；超出的长候选按原规则缩短加「…」。
    public static let maxPanelWidth: CGFloat = 760

    /// Diagnostics: where the first candidate's number starts, and how far the panel
    /// shifts left so the number sits on the start of the text being typed.
    @MainActor
    public static func candidateLeftEdgesForDiagnostics(candidates: [String]) -> (number: CGFloat, shift: CGFloat) {
        let layout = KeyiCandidateContentView.layout(preedit: "dou", texts: candidates, maxWidth: 760)
        return (layout.candidateX.first ?? 0, KeyiCompositionContentView.leadingInset)
    }

    /// 面板与光标之间的间距。
    public static let gap: CGFloat = 6
    /// 面板与屏幕可见区域边缘的最小距离。
    public static let screenMargin: CGFloat = 6

    /// 拿不到光标位置、改用鼠标位置时，按这么高的一行让开鼠标所在的行。
    public static let fallbackLineHeight: CGFloat = 24

    /// 宿主给的光标矩形能不能用。Chrome、Electron（如 Claude 桌面应用）常给宽度为 0 的
    /// 竖线，这仍是准确位置；只有全零或 NaN 才算没拿到。旧代码用 `isEmpty` 判断，把宽度为 0
    /// 的光标当成无效、改用鼠标位置，鼠标停在文字上时面板就盖住正在打的那一行。
    public static func isUsableCaret(_ caretRect: NSRect) -> Bool {
        let values = [caretRect.origin.x, caretRect.origin.y, caretRect.width, caretRect.height]
        guard values.allSatisfy(\.isFinite) else { return false }
        return caretRect.origin != .zero || caretRect.size != .zero
    }

    /// 这次面板用哪个光标位置。有些宿主（Antigravity 等 Chromium/Electron 应用）同一个输入框里
    /// 有的按键给得出光标、有的给全零，面板就在光标和鼠标之间来回跳。所以先用这次给的，
    /// 再用本会话上次拿到的；都没有才是 `.zero`（改用鼠标）。不再按字符范围（`firstRect`）重问：
    /// Claude 桌面应用这类宿主拿不到位置时会给窗口最左边一个假位置，面板就被摆到最左边。
    public static func resolvedCaret(reported: NSRect, lastKnown: NSRect) -> NSRect {
        if isUsableCaret(reported) { return reported }
        return isUsableCaret(lastKnown) ? lastKnown : .zero
    }

    /// 面板已经显示时又没拿到光标位置：留在原处，不跳到鼠标那里。
    public static func caretToKeep(new: NSRect, current: NSRect, isShown: Bool) -> NSRect {
        isUsableCaret(new) || !isShown || !isUsableCaret(current) ? new : current
    }

    /// 光标位置无效时用鼠标位置代替。
    public static func anchor(for caretRect: NSRect) -> NSRect {
        guard isUsableCaret(caretRect) else {
            let mouse = NSEvent.mouseLocation
            return NSRect(
                x: mouse.x,
                y: mouse.y - fallbackLineHeight / 2,
                width: 0,
                height: fallbackLineHeight
            )
        }
        return caretRect.standardized
    }

    /// 面板要让开的区域：本次显示里正在打的这段字占过的所有行。整段折到第二行后光标只在
    /// 第二行，面板若只让开光标行，放到上方时就盖住第一行（Claude、Antigravity 里都见过）。
    /// 新光标行与之前的行上下相接（折行）就并进来；离得远（换了输入框或位置）就重新开始。
    public static func compositionLines(anchor: NSRect, previous: NSRect?) -> NSRect {
        guard let previous else { return anchor }
        let reach = max(anchor.height, fallbackLineHeight)
        let adjacent = anchor.maxY >= previous.minY - reach && anchor.minY <= previous.maxY + reach
        guard adjacent else { return anchor }
        // 不用 `union`：宽度为 0 的光标（Chrome、Electron）可能被当成空矩形丢掉。
        let minX = min(previous.minX, anchor.minX)
        let minY = min(previous.minY, anchor.minY)
        return NSRect(
            x: minX,
            y: minY,
            width: max(previous.maxX, anchor.maxX) - minX,
            height: max(previous.maxY, anchor.maxY) - minY
        )
    }

    /// 正在打的这段字最多按这么多行让开；宿主给的开头位置离光标更远就不信。
    public static let maxCompositionLines: CGFloat = 12

    /// 面板要让开的区域，优先按宿主此刻给的这段字开头（`start`）到光标行（`anchor`）。
    /// Claude 这类贴底、往上长高的输入框里，折行后光标行留在原处、前面的行被推上去，
    /// 记下的旧行位置就不准，面板放到上方仍盖住上一行。开头位置拿不到或不可信时退回
    /// 按记下的行（`compositionLines(anchor:previous:)`）。
    public static func compositionLines(anchor: NSRect, start: NSRect, previous: NSRect?) -> NSRect {
        let reach = max(anchor.height, fallbackLineHeight) * maxCompositionLines
        guard isUsableCaret(start),
              start.minY >= anchor.minY - 1,
              start.maxY <= anchor.maxY + reach
        else { return compositionLines(anchor: anchor, previous: previous) }
        let start = start.standardized
        let minX = min(start.minX, anchor.minX)
        let minY = min(start.minY, anchor.minY)
        return NSRect(
            x: minX,
            y: minY,
            width: max(start.maxX, anchor.maxX) - minX,
            height: max(start.maxY, anchor.maxY) - minY
        )
    }

    /// 贴底、往上长高的输入框（Claude）里，宿主给的开头位置也可能是排版前的旧值，光标行
    /// 又留在原地，所以只能看光标：同一行里光标从靠右处一下跳回左边，就是折了一行、前面的
    /// 字被推上去一行。`extent` 是这段字在这一行里光标到过的最左、最右（只看 x）。
    /// 替换拼音（拼音变汉字）也会让光标左移，但不会跳过大半段已到过的宽度；折行后光标落在
    /// 行首附近，离这段字到过的最左边不远。
    public static func isUpwardWrap(previous: NSRect, caret: NSRect, extent: ClosedRange<CGFloat>) -> Bool {
        let height = max(caret.height, fallbackLineHeight)
        let width = extent.upperBound - extent.lowerBound
        return abs(caret.minY - previous.minY) <= 1
            && width >= height * 8
            && previous.minX - caret.minX > width / 2
            && caret.minX <= extent.lowerBound + height * 4
    }

    /// 面板左边对齐到哪：这段字开头和光标在同一行时对开头，否则对光标。以前只对第一次出现时
    /// 光标前那个字，有的宿主给的是字的左边、有的给右边（光标处），面板就时而对齐时而偏右一个字。
    public static func alignmentX(anchor: NSRect, start: NSRect) -> CGFloat {
        guard isUsableCaret(start), abs(start.minY - anchor.minY) <= 1, start.minX <= anchor.minX else {
            return anchor.minX
        }
        return start.minX
    }

    /// 往上折过 `wraps` 行时，这段字开头所在的行（光标行往上数 `wraps` 行）。
    public static func wrappedStart(caret: NSRect, wraps: Int, x: CGFloat) -> NSRect {
        guard wraps > 0 else { return .zero }
        return NSRect(x: x, y: caret.minY + CGFloat(wraps) * caret.height, width: 0, height: caret.height)
    }

    public static func visibleFrame(for anchor: NSRect) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        return screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    /// 光标下方放得下这么高的面板。
    public static func panelFitsBelow(anchor: NSRect, height: CGFloat, visible: NSRect) -> Bool {
        anchor.minY - gap - height >= visible.minY + screenMargin
    }

    /// 光标上方放得下这么高的面板。
    public static func panelFitsAbove(anchor: NSRect, height: CGFloat, visible: NSRect) -> Bool {
        anchor.maxY + gap + height <= visible.maxY - screenMargin
    }

    /// 面板的位置：`below` 时顶边贴在光标行下方，否则底边贴在光标行上方；`x` 是想要的左边缘。
    public static func panelOrigin(
        size: NSSize,
        anchor: NSRect,
        below: Bool,
        x: CGFloat,
        visible: NSRect
    ) -> NSPoint {
        let y = below ? anchor.minY - gap - size.height : anchor.maxY + gap
        return clamped(NSPoint(x: x, y: y), size: size, visible: visible)
    }

    private static func clamped(_ point: NSPoint, size: NSSize, visible: NSRect) -> NSPoint {
        NSPoint(
            x: min(max(point.x, visible.minX + screenMargin), visible.maxX - size.width - screenMargin),
            y: min(max(point.y, visible.minY + screenMargin), visible.maxY - size.height - screenMargin)
        )
    }
}
