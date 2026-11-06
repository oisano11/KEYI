import Foundation

/// 自动翻译用到的纯文字判断：汉字、句末、英文前是否补空格。
enum KeyiAutomaticTranslationText {
  /// 自动翻译整段文字的上限；超过就不发请求，回车时按中文上屏。
  static let maximumUTF8Bytes = 8 * 1024

  static func utf16Length(_ text: String) -> Int {
    (text as NSString).length
  }

  static func containsHan(_ text: String) -> Bool {
    text.unicodeScalars.contains(where: isHan)
  }

  static func isHan(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x3134F: true
    default: false
    }
  }

  /// 英文接在 `previous` 后面时需要的前缀空格。
  static func spacingPrefix(before translation: String, previous: Unicode.Scalar?) -> String {
    guard let previous,
          let first = translation.unicodeScalars.first(where: { !openingPunctuation.contains($0) }),
          usesWordSpacing(first) else { return "" }
    if usesWordSpacing(previous) || spaceFollowingPunctuation.contains(previous) {
      return " "
    }
    return ""
  }

  static func usesWordSpacing(_ scalar: Unicode.Scalar) -> Bool {
    guard CharacterSet.alphanumerics.contains(scalar) else { return false }
    switch scalar.value {
    case 0x0E00...0x0EFF,   // 泰文、老挝文
         0x1000...0x109F,   // 缅甸文
         0x1780...0x17FF,   // 高棉文
         0x3040...0x30FF,   // 平假名、片假名
         0x31F0...0x31FF,
         0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
         0xFF00...0xFFEF,   // 全角字符
         0x20000...0x3134F:
      return false
    default:
      return true
    }
  }

  static func upperBound(of range: NSRange) -> Int {
    let (value, overflow) = range.location.addingReportingOverflow(range.length)
    return overflow ? NSNotFound : value
  }

  /// 读回 `range` 内的文字；长度对不上就当读不到。
  static func exactText(in range: NSRange, on surface: KeyiTranslationClientSurface) -> String? {
    guard KeyiTranslationRange.isStructurallySane(range),
          let value = surface.attributedSubstring(from: range)?.string,
          utf16Length(value) == range.length else { return nil }
    return value
  }

  private static let spaceFollowingPunctuation = CharacterSet(charactersIn: ".,!?;:)]}\"'”’…%")
  private static let openingPunctuation = CharacterSet(charactersIn: "\"'“‘(（[「『")
}
