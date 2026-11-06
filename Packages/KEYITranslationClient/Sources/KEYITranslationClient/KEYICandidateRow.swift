import AppKit

/// 光标旁面板的候选行：量宽和绘制。输入法面板（`KeyiCandidateContentView`）和 KEYI 可译设置里磨砂滑块旁的
/// 预览都用这一份，预览里的选中块、字号、字距和真实面板一模一样（11-05：预览自己用 SwiftUI 另排一遍时，
/// 选中块按另一套尺寸算，「你」右半被裁掉）。
///
/// One row of numbered candidates, the highlighted one on a pill in the theme accent.
/// When the page has English words a small 「英文」 tag ends the row. Vertical positions
/// come from measured glyph ink, not font metrics: the number sits on the characters'
/// visual middle. Coordinates are flipped (y down), origin at the row's top left.
public enum KEYICandidateRow {
    // One compact row like the system Pinyin bar (user 11-05: 「要做的和苹果一样紧凑」):
    // no pinyin line (the pinyin shows in the input field's marked text), 2.5 pt above
    // and below the 24 pt pills, 3 pt left and right, so the row is 29 pt tall.
    public static let horizontalPadding: CGFloat = 3
    static let verticalPadding: CGFloat = 2.5
    static let pillSpacing: CGFloat = 2
    // Sizes follow the system Pinyin candidate bar (design canvas v18): every candidate
    // block is 24 pt tall with 7 pt side padding and a 12 pt corner radius.
    public static let pillHorizontalPadding: CGFloat = 7
    static let pillHeight: CGFloat = 24
    static let pillRadius: CGFloat = 12
    // Horizontal spacing is measured between glyph ink, like the system Pinyin bar
    // (user 11-05: the spacing between candidates should match Apple's): 7 pt from a
    // pill's edge to the ink inside it, 6 pt from the number's ink to the characters' ink,
    // so 16 pt from one candidate's last character to the next number.
    /// From the number's ink to the characters' ink.
    static let numberToText: CGFloat = 6
    static let tagGap: CGFloat = 6
    static let tagHorizontalPadding: CGFloat = 6
    static let englishTag = "英文"

    static let candidateSize: CGFloat = 16
    /// 8.5 pt: the digits' ink is 6 pt tall, as in the system bar.
    static var indexFont: NSFont { .monospacedDigitSystemFont(ofSize: 8.5, weight: .regular) }
    static var tagFont: NSFont { .systemFont(ofSize: 11, weight: .regular) }

    /// Ink of a typical Chinese character at the candidate size, relative to its baseline.
    static let hanziInk = KEYIMixedType.inkBounds(
        of: KEYIMixedType.string("安", size: candidateSize, color: .black)
    )
    /// Ink of a digit at the number size.
    static let digitInk = KEYIMixedType.inkBounds(
        of: NSAttributedString(string: "1", attributes: [.font: indexFont])
    )

    /// From the row's left edge to where the first candidate's number starts.
    public static var leadingInset: CGFloat { horizontalPadding + pillHorizontalPadding }

    /// A candidate made only of ASCII letters (and the odd digit or symbol) is an
    /// English word from the mixed-input dictionary.
    public static func isEnglish(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy(\.isASCII)
            && text.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }

    static func numberString(_ index: Int, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: "\(index + 1)", attributes: [.font: indexFont, .foregroundColor: color])
    }

    /// Ink of a candidate's number, relative to its drawing origin.
    static func numberInk(_ index: Int) -> CGRect {
        KEYIMixedType.inkBounds(of: numberString(index, color: .black))
    }

    /// A candidate as drawn: Chinese at 16 pt, Latin letters scaled to look as tall.
    /// The highlighted one is medium weight; widths are always measured at medium so
    /// moving the highlight never shifts the row.
    static func candidateText(_ text: String, color: NSColor, highlighted: Bool = true) -> NSAttributedString {
        KEYIMixedType.string(text, size: candidateSize, weight: highlighted ? .medium : .regular, color: color)
    }

    static var pillTop: CGFloat { verticalPadding }

    /// The candidates' baseline: the characters' ink is centred in the pill.
    static func candidateBaseline(pillTop: CGFloat) -> CGFloat {
        pillTop + pillHeight / 2 + hanziInk.midY
    }

    /// Draws `layout` into the current (flipped) graphics context.
    public static func draw(_ layout: Layout, highlightedIndex: Int, tokens: KEYIThemeTokens) {
        let pillTop = Self.pillTop
        let baseline = candidateBaseline(pillTop: pillTop)
        // The number's ink is centred on the characters' ink.
        let numberBaseline = baseline - hanziInk.midY + digitInk.midY
        for (index, shown) in layout.texts.enumerated() {
            let isHighlighted = index == highlightedIndex
            if isHighlighted {
                tokens.accent.nsColor.setFill()
                NSBezierPath(
                    roundedRect: NSRect(
                        x: layout.pillX[index],
                        y: pillTop,
                        width: layout.pillWidths[index],
                        height: pillHeight
                    ),
                    xRadius: pillRadius,
                    yRadius: pillRadius
                ).fill()
            }
            // The highlighted number takes the characters' colour, like the system bar.
            let indexColor = isHighlighted ? tokens.onAccent.nsColor : tokens.ink3.nsColor
            let textColor = isHighlighted ? tokens.onAccent.nsColor : tokens.ink.nsColor
            KEYIMixedType.draw(
                numberString(index, color: indexColor),
                x: layout.numberX[index],
                baseline: numberBaseline
            )
            KEYIMixedType.draw(
                candidateText(shown, color: textColor, highlighted: isHighlighted),
                x: layout.textX[index],
                baseline: baseline
            )
        }

        if let tagX = layout.tagX {
            let tag = NSAttributedString(string: englishTag, attributes: [
                .font: tagFont,
                .foregroundColor: tokens.ink2.nsColor,
            ])
            let tagSize = tag.size()
            let tagRect = NSRect(
                x: tagX,
                y: pillTop + (pillHeight - ceil(tagSize.height) - 4) / 2,
                width: ceil(tagSize.width) + tagHorizontalPadding * 2,
                height: ceil(tagSize.height) + 4
            )
            tokens.surface2.nsColor.setFill()
            NSBezierPath(roundedRect: tagRect, xRadius: 4, yRadius: 4).fill()
            tag.draw(at: NSPoint(x: tagRect.minX + tagHorizontalPadding, y: tagRect.minY + 2))
        }
    }

    /// The text drawn for each candidate (long ones shortened with "…"), each pill's left
    /// edge and width, where the number and the characters are drawn (origins, placed so
    /// their ink lands on the spacing above), and the row size. `draw` and the panel
    /// size both come from here, so the size always covers what is drawn.
    public struct Layout: Sendable {
        public var texts: [String]
        public var pillX: [CGFloat]
        public var pillWidths: [CGFloat]
        public var numberX: [CGFloat]
        public var textX: [CGFloat]
        /// Where each pill's content starts (its left edge plus the side padding).
        public var candidateX: [CGFloat] { pillX.map { $0 + KEYICandidateRow.pillHorizontalPadding } }
        public var tagX: CGFloat?
        public var size: NSSize

        public init(
            texts: [String], pillX: [CGFloat], pillWidths: [CGFloat], numberX: [CGFloat],
            textX: [CGFloat], tagX: CGFloat?, size: NSSize
        ) {
            self.texts = texts
            self.pillX = pillX
            self.pillWidths = pillWidths
            self.numberX = numberX
            self.textX = textX
            self.tagX = tagX
            self.size = size
        }

        public static let empty = Layout(texts: [], pillX: [], pillWidths: [], numberX: [], textX: [], tagX: nil, size: .zero)
    }

    public static func layout(texts: [String], maxWidth: CGFloat) -> Layout {
        func textInk(_ text: String) -> CGRect {
            KEYIMixedType.inkBounds(of: candidateText(text, color: .black))
        }
        func textWidth(_ text: String) -> CGFloat { textInk(text).width }
        let numberInks = texts.indices.map(numberInk)
        let hasEnglish = texts.contains(where: isEnglish)
        let tagWidth = hasEnglish
            ? tagGap + ceil((englishTag as NSString).size(withAttributes: [.font: tagFont]).width)
                + tagHorizontalPadding * 2
            : 0
        // Pills reach `pillHorizontalPadding` past the content on both sides; the first
        // pill starts at the panel padding, the last one ends there.
        // Everything except the candidate texts' ink.
        let fixed = horizontalPadding * 2 + tagWidth
            + numberInks.reduce(0) { $0 + $1.width + numberToText + pillHorizontalPadding * 2 }
            + pillSpacing * CGFloat(max(texts.count - 1, 0))
        let natural = texts.map(textWidth)
        var shown = texts
        if fixed + natural.reduce(0, +) > maxWidth, !texts.isEmpty {
            // The longest candidates are shortened to a common cap, so short ones
            // (usually the single characters at the end) stay whole.
            let budget = max(maxWidth - fixed, 0)
            var low: CGFloat = 0
            var high = natural.max() ?? 0
            for _ in 0..<24 {
                let mid = (low + high) / 2
                if natural.reduce(0, { $0 + min($1, mid) }) <= budget { low = mid } else { high = mid }
            }
            shown = zip(texts, natural).map { text, width in
                width <= low ? text : shortened(text, toFit: low, measure: textWidth)
            }
        }

        var width = horizontalPadding * 2

        var x = horizontalPadding
        var pillX: [CGFloat] = [], pillWidths: [CGFloat] = [], numberX: [CGFloat] = [], textX: [CGFloat] = []
        for (index, text) in shown.enumerated() {
            if index > 0 { x += pillSpacing }
            let number = numberInks[index]
            let ink = textInk(text)
            let numberLeft = x + pillHorizontalPadding
            let textLeft = numberLeft + number.width + numberToText
            pillX.append(x)
            numberX.append(numberLeft - number.minX)
            textX.append(textLeft - ink.minX)
            let width = textLeft + ink.width + pillHorizontalPadding - x
            pillWidths.append(width)
            x += width
        }
        let tagX: CGFloat? = hasEnglish ? x + tagGap : nil
        x += tagWidth
        width = max(width, x + horizontalPadding)
        let height = verticalPadding * 2 + pillHeight
        return Layout(
            texts: shown,
            pillX: pillX,
            pillWidths: pillWidths,
            numberX: numberX,
            textX: textX,
            tagX: tagX,
            size: NSSize(width: ceil(width), height: ceil(height))
        )
    }

    /// The longest prefix of `text` plus "…" that fits in `width` (at least one
    /// character, so a candidate never disappears entirely).
    private static func shortened(
        _ text: String,
        toFit width: CGFloat,
        measure: (String) -> CGFloat
    ) -> String {
        let characters = Array(text)
        var count = characters.count - 1
        while count > 1, measure(String(characters[0..<count]) + "…") > width {
            count -= 1
        }
        return String(characters[0..<max(count, 1)]) + "…"
    }
}
