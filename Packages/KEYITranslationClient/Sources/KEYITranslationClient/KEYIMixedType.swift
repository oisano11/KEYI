import AppKit
import CoreText

/// 中英混排按视觉大小配对：同一磅数下汉字几乎撑满字框，拉丁字母的小写只有一半高，
/// 英文会显得小而散。所以含小写字母的拉丁串按汉字字号的 `latinScale` 倍排，字重相同，不靠加粗补偿；
/// 全大写（EN）和纯数字本来就和汉字差不多高，不放大。
public enum KEYIMixedType {
    public static let latinScale: CGFloat = 1.1

    /// `text` 里的拉丁字母、数字按放大后的字号，其余（汉字、标点）按 `size`。
    public static func string(
        _ text: String,
        size: CGFloat,
        weight: NSFont.Weight = .regular,
        color: NSColor
    ) -> NSAttributedString {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        let latin = NSFont.systemFont(ofSize: (size * latinScale).rounded(toPlaces: 1), weight: weight)
        let result = NSMutableAttributedString()
        var run = ""
        var runIsLatin = false
        func flush() {
            guard !run.isEmpty else { return }
            let scaled = runIsLatin && run.contains(where: \.isLowercase)
            result.append(NSAttributedString(string: run, attributes: [
                .font: scaled ? latin : base,
                .foregroundColor: color,
            ]))
            run = ""
        }
        for character in text {
            let isLatin = isLatin(character)
            if isLatin != runIsLatin { flush(); runIsLatin = isLatin }
            run.append(character)
        }
        flush()
        return result
    }

    public static func isLatin(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
    }

    /// 一行字从基线往上的高度（取其中最高的字体）。用来把基线放在指定位置。
    public static func ascent(of string: NSAttributedString) -> CGFloat {
        var ascent: CGFloat = 0
        CTLineGetTypographicBounds(CTLineCreateWithAttributedString(string), &ascent, nil, nil)
        return ascent
    }

    /// 一段字实际墨迹的范围（相对基线，y 向上）。用来按字形中线、字形顶边对齐。
    public static func inkBounds(of string: NSAttributedString) -> CGRect {
        CTLineGetImageBounds(CTLineCreateWithAttributedString(string), nil)
    }

    public static func width(of string: NSAttributedString) -> CGFloat {
        ceil(string.size().width)
    }

    /// 在翻转坐标的视图里把一行字画在 `baseline` 上。
    public static func draw(_ string: NSAttributedString, x: CGFloat, baseline: CGFloat) {
        string.draw(at: NSPoint(x: x, y: baseline - ascent(of: string)))
    }
}

private extension CGFloat {
    func rounded(toPlaces places: Int) -> CGFloat {
        let factor = pow(10, CGFloat(places))
        return (self * factor).rounded() / factor
    }
}
