import AppKit
import KeyiIMETranslation
import OSLog

/// 光标旁唯一的面板：打拼音时上面是候选，下面是中英对照；没有拼音时只剩对照。
///
/// 两部分各有自己的 `owner`（与原来的候选窗、对照浮层一致）：InputMethodKit 可能同时
/// 留着好几个会话，一个会话失去焦点时不能收掉接替它的会话的那部分。面板本身由进程持有。
///
/// 摆放：面板贴在光标所在行下方，下方放不下才放上方；候选那一部分总在靠近光标的一侧。
/// 同一行里打字时左边缘和上下位置都锁住，候选行出现或收起只让面板朝远离光标的方向伸缩，
/// 带一个很短的过渡，所以视线不用跟着面板跳。
@MainActor
final class KeyiCompositionPanel {
    static let shared = KeyiCompositionPanel()

    struct Candidates {
        /// 正在打的拼音，画在候选上方一小行。
        var preedit: String = ""
        var items: [KeyiCandidateItem]
        var highlightedIndex: Int
    }

    struct Preview {
        var source: String
        var translation: String?
        var hint: KeyiAutomaticTranslationHint
    }

    private static let logger = Logger(
        subsystem: "com.keyi.inputmethod.keyi",
        category: "CompositionPanel"
    )
    /// 第一次出现时按这个高度判断下方够不够放，免得对照出来后又翻到上方。
    private static let reservedHeight: CGFloat = 150
    private static let resizeDuration: TimeInterval = 0.14
    private static let fadeDuration: TimeInterval = 0.12

    private let panel: NSPanel
    private let contentView: KeyiCompositionContentView

    private var candidates: Candidates?
    private var candidateOwner: UUID?
    private var preview: Preview?
    private var previewOwner: UUID?
    private var caretRect: NSRect = .zero
    /// 正在打的这段字第一个字所在的行（宿主此刻给的）；拿不到是 `.zero`。
    private var compositionStart: NSRect = .zero

    private var isShown = false
    private var placedBelow: Bool?
    private var lockedX: CGFloat?
    private var lockedLineY: CGFloat?
    /// 本次显示里正在打的这段字占过的行，面板一并让开。
    private var compositionLines: NSRect?
    /// 每次显示只记一次「改用鼠标」，免得每个键都刷日志。
    private var loggedMouseFallback = false

    private init() {
        let initialRect = NSRect(x: 0, y: 0, width: 360, height: 44)
        panel = NSPanel(
            contentRect: initialRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            // A deferred panel can stay at windowNumber == -1 inside a real
            // InputMethodKit process, so it is created eagerly.
            defer: false
        )
        contentView = KeyiCompositionContentView(frame: initialRect)
        KeyiPanelChrome.install(in: panel, content: contentView)
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        // 只做展示，绝不拦截鼠标或键盘。
        panel.ignoresMouseEvents = true
        panel.alphaValue = 0
    }

    /// Called during launch so the surface exists before AppKit finishes
    /// establishing window state.
    func prepare() {
        Self.logger.debug("Composition panel prepared window=\(self.panel.windowNumber)")
    }

    var isPreviewVisible: Bool { panel.isVisible && preview != nil }

    func showCandidates(_ value: Candidates, caretRect: NSRect, startRect: NSRect = .zero, owner: UUID) {
        guard !value.items.isEmpty else {
            hideCandidates(owner: owner)
            return
        }
        candidates = value
        candidateOwner = owner
        self.caretRect = KeyiPanelLayout.caretToKeep(new: caretRect, current: self.caretRect, isShown: isShown)
        compositionStart = startRect
        refresh()
    }

    func hideCandidates(owner: UUID) {
        guard candidateOwner == owner else { return }
        candidates = nil
        candidateOwner = nil
        refresh()
    }

    func showPreview(_ value: Preview, caretRect: NSRect, startRect: NSRect = .zero, owner: UUID) {
        guard !value.source.isEmpty else {
            hidePreview(owner: owner)
            return
        }
        preview = value
        previewOwner = owner
        if KeyiPanelLayout.isUsableCaret(caretRect) {
            self.caretRect = caretRect
            compositionStart = startRect
        }
        refresh()
    }

    /// 宿主排版后位置变了：只挪面板，内容不变。
    func reanchor(caretRect: NSRect, startRect: NSRect, owner: UUID) {
        guard isShown, previewOwner == owner || candidateOwner == owner,
              KeyiPanelLayout.isUsableCaret(caretRect)
        else { return }
        self.caretRect = caretRect
        compositionStart = startRect
        refresh()
    }

    func hidePreview(owner: UUID) {
        guard previewOwner == owner else { return }
        preview = nil
        previewOwner = nil
        refresh()
    }

    private func refresh() {
        guard candidates != nil || preview != nil else {
            dismiss()
            return
        }
        if !KeyiPanelLayout.isUsableCaret(caretRect), !loggedMouseFallback {
            loggedMouseFallback = true
            Self.logger.notice("No caret position from the client; placing the panel by the mouse")
        }
        let anchor = KeyiPanelLayout.anchor(for: caretRect)
        let visible = KeyiPanelLayout.visibleFrame(for: anchor)
        let size = contentView.update(
            candidates: candidates,
            preview: preview,
            maxWidth: min(visible.width - KeyiPanelLayout.screenMargin * 2, KeyiPanelLayout.maxPanelWidth)
        )

        // 换了一行（或刚出现）才重新决定放哪；同一行里打字只跟着内容伸缩。
        if !isShown || lockedLineY.map({ abs($0 - anchor.minY) > 1 }) ?? true {
            placedBelow = nil
            lockedX = nil
            // 面板仍盖住正在打的字时，靠这一行对照宿主给的光标和屏幕上的字。
            Self.logger.info("Caret line x=\(anchor.minX, privacy: .public) y=\(anchor.minY, privacy: .public) h=\(anchor.height, privacy: .public) start=\(NSStringFromRect(self.compositionStart), privacy: .public)")
        }
        lockedLineY = anchor.minY
        let lines = KeyiPanelLayout.compositionLines(
            anchor: anchor,
            start: compositionStart,
            previous: compositionLines
        )
        compositionLines = lines
        let preferredX = KeyiPanelLayout.alignmentX(anchor: anchor, start: compositionStart)
            - KeyiCompositionContentView.leadingInset
        if lockedX.map({ preferredX < $0 }) ?? true { lockedX = preferredX }
        if placedBelow == nil {
            placedBelow = KeyiPanelLayout.panelFitsBelow(
                anchor: lines,
                height: max(size.height, Self.reservedHeight),
                visible: visible
            ) || !KeyiPanelLayout.panelFitsAbove(anchor: lines, height: size.height, visible: visible)
        } else if placedBelow == true,
                  !KeyiPanelLayout.panelFitsBelow(anchor: lines, height: size.height, visible: visible) {
            placedBelow = false
        }
        let below = placedBelow ?? true
        contentView.candidatesAtTop = below

        let frame = NSRect(
            origin: KeyiPanelLayout.panelOrigin(
                size: size,
                anchor: lines,
                below: below,
                x: lockedX ?? preferredX,
                visible: visible
            ),
            size: size
        )
        setFrame(frame)
        present()
    }

    private func setFrame(_ frame: NSRect) {
        let animate = isShown
            && !KeyiPanelLayout.invisibleForDiagnostics
            && abs(panel.frame.height - frame.height) > 0.5
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.resizeDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
        panel.invalidateShadow()
    }

    private func present() {
        if !isShown {
            KeyiPanelChrome.syncFromPreferences()
            isShown = true
            // 出现时直接显示、不淡入：对照一到就看得见，不让用户多等（2026-11-05 用户要求「不要让用户等」）。
            // 用 0 秒的动画设透明度，顶掉可能还在进行的淡出；收起仍淡出。
            let alpha: CGFloat = KeyiPanelLayout.invisibleForDiagnostics ? 0 : 1
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                panel.animator().alphaValue = alpha
            }
        }
        panel.orderFrontRegardless()
    }

    private func dismiss() {
        guard isShown else { return }
        isShown = false
        contentView.rememberedCandidateWidth = nil
        placedBelow = nil
        lockedX = nil
        lockedLineY = nil
        compositionLines = nil
        compositionStart = .zero
        loggedMouseFallback = false
        if KeyiPanelLayout.invisibleForDiagnostics {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fadeDuration
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // 淡出期间又有内容要显示，就不收起。
                guard let self, !self.isShown else { return }
                self.panel.orderOut(nil)
            }
        })
    }
}

/// 面板内容：候选一段、中英对照一段，中间一条细分隔线。候选段总在靠近光标的一侧，
/// 面板在光标下方时候选在上，在上方时候选在下。尺寸变化的过渡中，各段贴着靠光标的那条边。
final class KeyiCompositionContentView: NSView {
    /// 面板左边缘到第一个候选序号的距离；面板按这个距离往左让，让序号对齐正在打的字的开头。
    static var leadingInset: CGFloat { KeyiCandidateContentView.leadingInset }
    private static let minimumWidth: CGFloat = 60
    private static let dividerInset: CGFloat = 10
    /// 有对照时面板至少这么宽：这次输入一开始就没有候选、或候选行很短时，对照和底栏仍放得下。
    static let previewMinimumWidth: CGFloat = 360

    /// 这次输入里候选行的宽度。候选收起、只剩对照时沿用它，面板不来回跳；面板收起时清掉。
    var rememberedCandidateWidth: CGFloat?

    private let candidateView = KeyiCandidateContentView(frame: .zero)
    private let previewView = KeyiTranslationPreviewContentView(frame: .zero)
    private var candidateHeight: CGFloat = 0
    private var previewHeight: CGFloat = 0

    var candidatesAtTop = true {
        didSet { if candidatesAtTop != oldValue { layoutSections() } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(candidateView)
        addSubview(previewView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("KeyiCompositionContentView 不支持从 nib 初始化")
    }

    override var isFlipped: Bool { true }

    func update(
        candidates: KeyiCompositionPanel.Candidates?,
        preview: KeyiCompositionPanel.Preview?,
        maxWidth: CGFloat
    ) -> NSSize {
        var width = Self.minimumWidth
        if let candidates {
            let size = candidateView.update(
                preedit: candidates.preedit,
                items: candidates.items,
                highlightedIndex: candidates.highlightedIndex,
                maxWidth: maxWidth
            )
            candidateHeight = size.height
            width = max(width, size.width)
            rememberedCandidateWidth = size.width
        } else {
            candidateHeight = 0
        }
        candidateView.isHidden = candidates == nil

        if let preview {
            previewView.update(
                source: preview.source,
                translation: preview.translation,
                hint: preview.hint
            )
            // 有对照时宽度跟着这次输入的候选行走（只剩对照时沿用它），至少 360；译文在这个宽度里换行。
            width = min(max(width, rememberedCandidateWidth ?? 0, Self.previewMinimumWidth), maxWidth)
            previewHeight = previewView.height(forWidth: width)
        } else {
            previewHeight = 0
        }
        previewView.isHidden = preview == nil

        let divider: CGFloat = candidates != nil && preview != nil ? 1 : 0
        needsDisplay = true
        layoutSections()
        return NSSize(
            width: ceil(width),
            height: ceil(candidateHeight + divider + previewHeight)
        )
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutSections()
    }

    /// 靠光标那一侧的段贴着那条边，另一段接在它后面。
    private func layoutSections() {
        let width = bounds.width
        let divider: CGFloat = candidateView.isHidden || previewView.isHidden ? 0 : 1
        if candidatesAtTop {
            candidateView.frame = NSRect(x: 0, y: 0, width: width, height: candidateHeight)
            previewView.frame = NSRect(
                x: 0, y: candidateHeight + divider, width: width, height: previewHeight
            )
        } else {
            let bottom = bounds.height
            candidateView.frame = NSRect(
                x: 0, y: bottom - candidateHeight, width: width, height: candidateHeight
            )
            previewView.frame = NSRect(
                x: 0, y: bottom - candidateHeight - divider - previewHeight,
                width: width, height: previewHeight
            )
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !candidateView.isHidden, !previewView.isHidden else { return }
        let y = candidatesAtTop ? candidateView.frame.maxY : candidateView.frame.minY - 1
        KeyiPanelChrome.tokens(for: self).line.nsColor.setFill()
        NSRect(
            x: Self.dividerInset,
            y: y,
            width: bounds.width - Self.dividerInset * 2,
            height: 1
        ).fill()
    }
}
