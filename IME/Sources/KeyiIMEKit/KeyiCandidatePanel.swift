import AppKit
import KEYITranslationClient

/// One page of candidates; the panel shows text plus the numeric shortcut.
struct KeyiCandidateItem: Equatable {
    let text: String
    let comment: String?
}

/// Candidates in the composition panel (`KeyiCompositionPanel`): the top part of the
/// one panel under the caret. The API is unchanged from when the candidates had their
/// own window, so the session code does not care where they are drawn.
///
/// The panel is process owned: InputMethodKit can keep several controller sessions
/// alive at once, and a session that loses focus must not hide the candidates of the
/// session that replaced it.
enum KeyiCandidatePanel {
    /// Hides the candidates from a nonisolated InputMethodKit callback. InputMethodKit
    /// delivers these callbacks on the main thread, so the hop is unchecked by design.
    nonisolated static func hideForSession(owner: UUID) {
        MainActor.assumeIsolated {
            KeyiCompositionPanel.shared.hideCandidates(owner: owner)
        }
    }

    /// Presents the candidates from a nonisolated InputMethodKit callback.
    nonisolated static func showForSession(
        preedit: String,
        items: [KeyiCandidateItem],
        highlightedIndex: Int,
        caretRect: NSRect,
        startRect: NSRect = .zero,
        owner: UUID
    ) {
        MainActor.assumeIsolated {
            KeyiCompositionPanel.shared.showCandidates(
                .init(preedit: preedit, items: items, highlightedIndex: highlightedIndex),
                caretRect: caretRect,
                startRect: startRect,
                owner: owner
            )
        }
    }
}

/// Candidate section: one row of numbered candidates, the highlighted one on a pill in
/// the theme accent. When the page has English words (mixed Chinese/English input) a
/// small 「英文」 tag ends the row. The pinyin is not repeated here: it shows in the input
/// field's marked text, as with the system Pinyin bar. The panel draws the glass
/// background, so this view only draws the text and the pill.
///
/// The panel puts the first candidate's number on the start of the text being typed
/// (用户 11-05 选「色块左边对齐」，像苹果拼音). Vertical positions come from measured glyph
/// ink, not font metrics: the number sits on the characters' visual middle.
final class KeyiCandidateContentView: NSView {
    private var highlightedIndex = 0
    private var currentLayout = Layout.empty

    /// 量宽和绘制在共享包 `KEYICandidateRow`：KEYI 可译设置里的磨砂预览用同一份，和这里画得一模一样。
    typealias Layout = KEYICandidateRow.Layout

    static var horizontalPadding: CGFloat { KEYICandidateRow.horizontalPadding }
    static var pillHorizontalPadding: CGFloat { KEYICandidateRow.pillHorizontalPadding }

    /// From the panel's left edge to where the first candidate's number starts. The panel
    /// shifts left by this much so the number sits under the start of the text being typed.
    static var leadingInset: CGFloat { KEYICandidateRow.leadingInset }

    override var isFlipped: Bool { true }

    func update(
        preedit: String,
        items: [KeyiCandidateItem],
        highlightedIndex: Int,
        maxWidth: CGFloat
    ) -> NSSize {
        self.highlightedIndex = highlightedIndex
        currentLayout = Self.layout(preedit: preedit, texts: items.map(\.text), maxWidth: maxWidth)
        needsDisplay = true
        return currentLayout.size
    }

    static func isEnglish(_ text: String) -> Bool {
        KEYICandidateRow.isEnglish(text)
    }

    override func draw(_ dirtyRect: NSRect) {
        KEYICandidateRow.draw(currentLayout, highlightedIndex: highlightedIndex, tokens: KeyiPanelChrome.tokens(for: self))
    }

    /// The pinyin is not shown in the row, so `preedit` does not change the layout.
    static func layout(preedit: String = "", texts: [String], maxWidth: CGFloat) -> Layout {
        KEYICandidateRow.layout(texts: texts, maxWidth: maxWidth)
    }
}
