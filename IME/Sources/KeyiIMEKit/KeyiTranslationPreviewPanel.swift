import AppKit
import KEYITranslationClient
import KeyiIMETranslation

/// 「中文 / 英文」对照：光标旁那个面板（`KeyiCompositionPanel`）里候选下面的那一段。
///
/// 为什么不是一个真正的输入框：macOS 的输入法（IMK）不拥有可编辑文本控件，
/// 用户敲的字必须落进当前应用。因此这里在光标旁的面板里，上行显示这次确认的
/// 中文原文，下行同步显示译文，作为「两个框」的可视化等价物。
enum KeyiTranslationPreviewPanel {
    nonisolated static func updateForSession(
        source: String,
        translation: String?,
        hint: KeyiAutomaticTranslationHint,
        caretRect: NSRect,
        startRect: NSRect = .zero,
        owner: UUID
    ) {
        MainActor.assumeIsolated {
            KeyiCompositionPanel.shared.showPreview(
                .init(source: source, translation: translation, hint: hint),
                caretRect: caretRect,
                startRect: startRect,
                owner: owner
            )
        }
    }

    nonisolated static func hideForSession(owner: UUID) {
        MainActor.assumeIsolated {
            KeyiCompositionPanel.shared.hidePreview(owner: owner)
        }
    }

    /// 诊断专用：对照此刻是否在屏幕上。
    nonisolated static func isVisibleForDiagnostics() -> Bool {
        MainActor.assumeIsolated { KeyiCompositionPanel.shared.isPreviewVisible }
    }
}

/// 对照内容：左边一列「中」「EN」小标，右边上行中文原文、下行译文（或三点加「翻译中…」、
/// 「翻译失败」加一行原因），最下面一条浅底提示栏写此刻回车和 Shift 的作用，右端是这次用的引擎。
/// 背景由面板画，这里只画字、提示栏底色和键帽。提示由控制器按此刻回车会做什么给出。
///
/// 宽度由面板给：跟着这次输入的候选行（至少 360），长句在这个宽度里换行，
/// 同一次输入里切换等待、失败、预览时面板不忽宽忽窄。
final class KeyiTranslationPreviewContentView: NSView {
    private var source = ""
    private var translation: String?
    private var hintKind = KeyiAutomaticTranslationHint.enterConverts
    private var style = KEYITranslationStyle.natural
    private var engineLabel: String?
    /// 按住右 ⌥ 说话中（语音输入）。
    private var listening = false
    private var listeningEngine: String?
    private var listeningCloud = false

    // 紧凑尺寸（11-05 照苹果拼音收紧，设计稿第 23 版）：上下 6、左右 10，标签列 20、到文字 6，两行间 2；
    // 底栏上 5、下 6。面板宽度由候选行决定（见 `KeyiCompositionContentView`）。
    private static let horizontalPadding: CGFloat = 10
    private static let topPadding: CGFloat = 6
    private static let bottomPadding: CGFloat = 6
    private static let labelColumn: CGFloat = 20
    private static let columnGap: CGFloat = 6
    private static let rowSpacing: CGFloat = 2
    private static let footerTop: CGFloat = 5
    private static let footerBottom: CGFloat = 6
    private static let footerGap: CGFloat = 5
    private static let keyHeight: CGFloat = 17
    private static let keyPadding: CGFloat = 4
    private static let engineDot: CGFloat = 6
    private static let engineDotGap: CGFloat = 5
    /// 提示与引擎名之间至少留这么宽。
    private static let engineSpacing: CGFloat = 14
    private static let dotSize: CGFloat = 5
    private static let dotGap: CGFloat = 3

    // 中英按视觉大小配对（`KeyiMixedType`）：原文里的拉丁字母、「EN」、「Shift」、引擎名都按
    // 同处汉字字号的 1.1 倍排。译文是整行英文，14.5pt regular 和 13pt 的原文看起来一样大，层级靠颜色；
    // 「翻译中…」「翻译失败」是中文，和原文同为 13pt。
    private static let labelSize: CGFloat = 10.5
    private static let sourceSize: CGFloat = 13
    private static let translationFont = NSFont.systemFont(ofSize: 14.5, weight: .regular)
    private static let statusFont = NSFont.systemFont(ofSize: 13, weight: .regular)
    private static let reasonSize: CGFloat = 12
    private static let reasonGap: CGFloat = 3
    private static let hintSize: CGFloat = 12
    private static let keySize: CGFloat = 11

    /// 提示栏的一段：键帽或普通文字。
    private enum HintPart {
        case key(String)
        case text(String)
        case separator
    }

    override var isFlipped: Bool { true }

    func update(
        source: String,
        translation: String?,
        hint: KeyiAutomaticTranslationHint,
        listening: Bool = false,
        listeningEngine: String? = nil,
        listeningCloud: Bool = false
    ) {
        self.source = source
        self.translation = translation
        hintKind = hint
        self.listening = listening
        self.listeningEngine = listeningEngine
        self.listeningCloud = listeningCloud
        style = KEYITranslationStyle.stored() ?? .natural
        engineLabel = KEYITranslationStyle.storedEngineLabels()[style]
        needsDisplay = true
    }


    /// 在给定面板宽度下这一段的高度。
    func height(forWidth width: CGFloat) -> CGFloat {
        let available = textWidth(forWidth: width)
        return ceil(
            Self.topPadding
                + Self.height(of: sourceString(color: .black), width: available)
                + Self.rowSpacing
                + translationHeight(width: available)
                + reasonHeight(width: available)
                + Self.bottomPadding
                + Self.footerHeight
        )
    }

    private static var footerHeight: CGFloat { footerTop + keyHeight + footerBottom }

    private static var waitingDotsWidth: CGFloat { dotSize * 3 + dotGap * 2 }

    private func textWidth(forWidth width: CGFloat) -> CGFloat {
        width - Self.horizontalPadding * 2 - Self.labelColumn - Self.columnGap
    }

    private var isWaitingForTranslation: Bool {
        (translation ?? "").isEmpty && !hintKind.isFailed
    }

    private var isFailed: Bool {
        (translation ?? "").isEmpty && hintKind.isFailed
    }

    private var translationDisplay: String {
        if listening { return "正在听…" }
        if let translation, !translation.isEmpty { return translation }
        return hintKind.isFailed ? "翻译失败" : "翻译中…"
    }

    /// 翻译失败时「翻译失败」下面那行：为什么失败、接着打字会怎样。
    private var failureReason: String? {
        guard isFailed, case let .failed(kind) = hintKind else { return nil }
        let engine = engineLabel.flatMap { $0.isEmpty ? nil : $0 } ?? "翻译服务"
        let retry = "接着打字会并进这段，下次回车整段重译。"
        switch kind {
        case .timedOut:
            return "\(engine) \(Int(KeyiAutomaticTranslationController.requestTimeoutSeconds)) 秒没有回应。" + retry
        case .serviceUnavailable:
            return "连不上 KEYI 可译。" + retry
        case .notConfigured:
            return "「\(style.chineseName)」要用的翻译服务还没配置好，请在 KEYI 可译里设置。"
        case .emptyResult:
            return "\(engine) 没有返回译文。" + retry
        case .tooLong:
            return "这段超过 8 KiB，不翻译。"
        case .other:
            return "\(engine) 出错了。" + retry
        }
    }

    private func reasonString(_ text: String, color: NSColor) -> NSAttributedString {
        KeyiMixedType.string(text, size: Self.reasonSize, color: color)
    }

    private func reasonHeight(width: CGFloat) -> CGFloat {
        guard let failureReason else { return 0 }
        return Self.reasonGap + Self.height(of: reasonString(failureReason, color: .black), width: width)
    }

    private func sourceString(color: NSColor) -> NSAttributedString {
        // 刚按下、还没识别出字时留一行空白，面板高度不跳。
        KeyiMixedType.string(source.isEmpty ? "\u{3000}" : source, size: Self.sourceSize, color: color)
    }

    private var translationFontInUse: NSFont {
        (translation ?? "").isEmpty ? Self.statusFont : Self.translationFont
    }

    private func translationHeight(width: CGFloat) -> CGFloat {
        Self.height(of: translationDisplay, font: translationFontInUse, width: width)
    }

    /// 此刻按回车会做什么：等英文时、翻译失败后，回车都是「保留中文」。单按 Shift（或 Esc）随时保留中文。
    /// 文案照契约原文（翻译失败与等英文同一句，2026-11-04 用户：「统一成「再按」」），按键名画成键帽。
    private var hintParts: [HintPart] {
        if listening {
            return [.text("说完松开"), .key("右 ⌥"), .separator, .text("按其他键取消")]
        }
        return switch hintKind {
        case .enterConverts:
            [.key("回车"), .text("换英文（\(style.chineseName)）"), .separator, .key("Shift"), .text("保留中文")]
        case .waiting, .failed:
            [.text("再按"), .key("回车"), .text("或"), .key("Shift"), .text("保留中文")]
        }
    }

    /// 提示栏右端：这次用的引擎名（Hy-MT2、DeepSeek 等），前面一个本机色或 API 色圆点。
    private var engineDisplay: String? {
        if listening { return listeningEngine ?? KeyiDictationEngineInfo.localName }
        guard let engineLabel, !engineLabel.isEmpty else { return nil }
        return engineLabel
    }

    private static func width(of part: HintPart) -> CGFloat {
        switch part {
        case .key(let name): keyWidth(name)
        case .text(let text): KeyiMixedType.width(of: hintString(text, color: .black))
        case .separator: KeyiMixedType.width(of: hintString("·", color: .black))
        }
    }

    private static func hintString(_ text: String, color: NSColor) -> NSAttributedString {
        KeyiMixedType.string(text, size: hintSize, color: color)
    }

    private static func keyString(_ name: String, color: NSColor) -> NSAttributedString {
        KeyiMixedType.string(name, size: keySize, weight: .semibold, color: color)
    }

    private static func engineString(_ text: String, color: NSColor) -> NSAttributedString {
        KeyiMixedType.string(text, size: hintSize, weight: .medium, color: color)
    }

    private static func keyWidth(_ name: String) -> CGFloat {
        max(keyHeight, KeyiMixedType.width(of: keyString(name, color: .black)) + keyPadding * 2)
    }

    private static func engineWidth(_ text: String) -> CGFloat {
        engineDot + engineDotGap + KeyiMixedType.width(of: engineString(text, color: .black))
    }

    private static func height(of string: NSAttributedString, width: CGFloat) -> CGFloat {
        ceil(string.boundingRect(
            with: NSSize(width: max(width, 1), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height)
    }

    private static func height(of text: String, font: NSFont, width: CGFloat) -> CGFloat {
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: max(width, 1), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return ceil(rect.height)
    }

    private static func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    private static func width(of text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    override func draw(_ dirtyRect: NSRect) {
        let tokens = KeyiPanelChrome.tokens(for: self)
        let available = textWidth(forWidth: bounds.width)
        let textX = Self.horizontalPadding + Self.labelColumn + Self.columnGap
        var y = Self.topPadding

        // 「中」行
        let sourceText = sourceString(color: tokens.ink2.nsColor)
        let sourceHeight = Self.height(of: sourceText, width: available)
        drawLabel("中", color: tokens.ink3.nsColor, firstLineFont: NSFont.systemFont(ofSize: Self.sourceSize), y: y)
        sourceText.draw(
            with: NSRect(x: textX, y: y, width: available, height: sourceHeight),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        y += sourceHeight + Self.rowSpacing

        // 「EN」行：本机风格用强调色，大模型风格用 API 色，失败用危险色。
        let usesAPIColor = listening ? listeningCloud : style.usesCloud
        let engineColor = usesAPIColor ? tokens.api.nsColor : tokens.accent.nsColor
        let labelColor = isFailed ? tokens.danger.nsColor : engineColor
        let rowHeight = translationHeight(width: available)
        drawLabel("EN", color: labelColor, firstLineFont: translationFontInUse, y: y)
        if isWaitingForTranslation {
            let dotY = y + (Self.lineHeight(Self.statusFont) - Self.dotSize) / 2
            for (index, alpha) in [1.0, 0.6, 0.3].enumerated() {
                engineColor.withAlphaComponent(alpha).setFill()
                NSBezierPath(ovalIn: NSRect(
                    x: textX + CGFloat(index) * (Self.dotSize + Self.dotGap),
                    y: dotY,
                    width: Self.dotSize,
                    height: Self.dotSize
                )).fill()
            }
            let waitingX = textX + Self.waitingDotsWidth + 8
            (translationDisplay as NSString).draw(
                with: NSRect(x: waitingX, y: y, width: available - (waitingX - textX), height: rowHeight),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: Self.statusFont, .foregroundColor: tokens.ink3.nsColor]
            )
        } else {
            (translationDisplay as NSString).draw(
                with: NSRect(x: textX, y: y, width: available, height: rowHeight),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [
                    .font: translationFontInUse,
                    // 译文用主题色（亮色 accent-strong、暗色 accent），和灰色原文分开；失败仍是危险色。
                    .foregroundColor: isFailed ? tokens.danger.nsColor : tokens.trans.nsColor,
                ]
            )
        }
        y += rowHeight
        if let failureReason {
            y += Self.reasonGap
            let reason = reasonString(failureReason, color: tokens.ink2.nsColor)
            let height = Self.height(of: reason, width: available)
            reason.draw(
                with: NSRect(x: textX, y: y, width: available, height: height),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            y += height
        }
        y += Self.bottomPadding

        drawFooter(top: y, tokens: tokens, engineColor: engineColor)
    }

    /// 左列小标，墨迹中线对齐右列首行文字的墨迹中线（「中」按汉字、「EN」按大写字母量）。
    private func drawLabel(_ label: String, color: NSColor, firstLineFont: NSFont, y: CGFloat) {
        let text = KeyiMixedType.string(label, size: Self.labelSize, weight: .semibold, color: color)
        // 首行基线：draw(with:) 从行顶开始排，基线在行顶下 ascender 处。
        let rowBaseline = y + firstLineFont.ascender
        // 首行文字的视觉中线：汉字取字身中线，拉丁取大写高度的一半，二者都约在基线上 0.36 em。
        let rowMiddle = rowBaseline - firstLineFont.pointSize * 0.36
        let ink = KeyiMixedType.inkBounds(of: text)
        KeyiMixedType.draw(text, x: Self.horizontalPadding, baseline: rowMiddle + ink.midY)
    }

    private func drawFooter(top: CGFloat, tokens: KEYIThemeTokens, engineColor: NSColor) {
        let band = NSRect(x: 0, y: top, width: bounds.width, height: Self.footerHeight)
        tokens.tintWeak.nsColor.setFill()
        band.fill()
        tokens.line.nsColor.setFill()
        NSRect(x: 0, y: top, width: bounds.width, height: 1).fill()

        let centerY = top + Self.footerTop + Self.keyHeight / 2
        var x = Self.horizontalPadding
        for (index, part) in hintParts.enumerated() {
            if index > 0 { x += Self.footerGap }
            let width = Self.width(of: part)
            switch part {
            case .key(let name):
                drawKey(name, x: x, centerY: centerY, width: width, tokens: tokens)
            case .text(let text):
                drawCentered(Self.hintString(text, color: tokens.ink2.nsColor), x: x, centerY: centerY)
            case .separator:
                drawCentered(Self.hintString("·", color: tokens.ink4.nsColor), x: x, centerY: centerY)
            }
            x += width
        }

        // 引擎名放得下才画，免得压住提示。
        if let engine = engineDisplay {
            let width = Self.engineWidth(engine)
            let engineX = bounds.width - Self.horizontalPadding - width
            guard engineX >= x + Self.engineSpacing else { return }
            engineColor.setFill()
            NSBezierPath(ovalIn: NSRect(
                x: engineX,
                y: centerY - Self.engineDot / 2,
                width: Self.engineDot,
                height: Self.engineDot
            )).fill()
            drawCentered(
                Self.engineString(engine, color: engineColor),
                x: engineX + Self.engineDot + Self.engineDotGap,
                centerY: centerY
            )
        }
    }

    /// 键帽：白底、细边、底边加厚，和设计稿的 .kbd 一致。
    private func drawKey(_ name: String, x: CGFloat, centerY: CGFloat, width: CGFloat, tokens: KEYIThemeTokens) {
        let rect = NSRect(x: x, y: centerY - Self.keyHeight / 2, width: width, height: Self.keyHeight)
        tokens.line2.nsColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        tokens.surface.nsColor.setFill()
        NSBezierPath(
            roundedRect: NSRect(x: rect.minX + 1, y: rect.minY + 1, width: rect.width - 2, height: rect.height - 3),
            xRadius: 3,
            yRadius: 3
        ).fill()
        let text = Self.keyString(name, color: tokens.ink.nsColor)
        drawCentered(
            text,
            x: rect.minX + (rect.width - KeyiMixedType.width(of: text)) / 2,
            centerY: centerY - 0.5
        )
    }

    /// 按汉字墨迹竖向居中：同一字号的中文和放大后的拉丁字母共用一条基线，
    /// 所以「回车」和「Shift」、中文提示和「Hy-MT2」落在同一条视觉中线上。
    private func drawCentered(_ text: NSAttributedString, x: CGFloat, centerY: CGFloat) {
        let font = text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let size = font.map { KeyiMixedType.isLatin(Character(text.string.prefix(1).description)) ? $0.pointSize / KeyiMixedType.latinScale : $0.pointSize } ?? Self.hintSize
        let weight: NSFont.Weight = font?.fontDescriptor.symbolicTraits.contains(.bold) == true ? .semibold : .regular
        let hanzi = KeyiMixedType.inkBounds(of: KeyiMixedType.string("中", size: size, weight: weight, color: .black))
        KeyiMixedType.draw(text, x: x, baseline: centerY + hanzi.midY)
    }
}
