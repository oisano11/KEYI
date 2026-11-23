import Foundation

/// 英文后面的标点按英文（半角）出（用户 2026-11-08）：标点键前面是英文时直接出键上的原字符，
/// 不经 Rime 换成中文标点；前面是中文时照旧是中文标点。
public enum KeyiPunctuationContext {
  /// 会被 Rime 换成中文标点、英文后面应直接出原字符的键：ASCII 可见字符里除字母和数字以外的。
  public static func isPunctuationKey(_ key: Int) -> Bool {
    guard key >= 0x21, key <= 0x7e, let scalar = Unicode.Scalar(UInt32(key)) else { return false }
    return !isASCIILetter(scalar) && !isASCIIDigit(scalar)
  }

  /// 正在打的字母是不是网址或邮箱（与 keyi_pinyin.schema.yaml 的 recognizer/patterns 同一套）：
  /// www.、http:、https:、ftp.、ftp:、mailto:、file: 开头，或字母开头接着 @，或带点的域名（baidu.com，
  /// 只会由会话认出后整段放进 Rime，打字时点号进不了输入）。是的话后面打的字母、数字和符号都留在输入里
  /// 交给 Rime，不按候选转汉字、不换中文标点、数字不选候选。
  public static func isAddressInput<S: StringProtocol>(_ input: S) -> Bool {
    let text = String(input)
    guard let first = text.unicodeScalars.first, (0x61...0x7a).contains(first.value) else { return false }
    for prefix in ["www.", "http:", "https:", "ftp.", "ftp:", "mailto:", "file:"] where text.hasPrefix(prefix) {
      return true
    }
    if let at = text.firstIndex(of: "@") {
      return text[..<at].unicodeScalars.allSatisfy { scalar in
        (0x61...0x7a).contains(scalar.value) || isASCIIDigit(scalar) || "-_.".unicodeScalars.contains(scalar)
      }
    }
    return isDottedName(text)
  }

  /// 带点的域名：`^[a-z0-9][-a-z0-9]*([.][a-z0-9][-a-z0-9]*)+([./:?#].*)?$`（Rime 的 domain 规则）。
  static func isDottedName(_ text: String) -> Bool {
    let scalars = Array(text.unicodeScalars)
    func isNameScalar(_ scalar: Unicode.Scalar) -> Bool {
      (0x61...0x7a).contains(scalar.value) || isASCIIDigit(scalar) || scalar == "-"
    }
    var index = 0
    var labels = 0
    while index < scalars.count {
      // 一个标签：字母或数字开头。
      guard (0x61...0x7a).contains(scalars[index].value) || isASCIIDigit(scalars[index]) else { break }
      while index < scalars.count, isNameScalar(scalars[index]) { index += 1 }
      labels += 1
      guard index + 1 < scalars.count, scalars[index] == ".",
            (0x61...0x7a).contains(scalars[index + 1].value) || isASCIIDigit(scalars[index + 1])
      else { break }
      index += 1
    }
    guard labels >= 2 else { return false }
    return index == scalars.count || "./:?#".unicodeScalars.contains(scalars[index])
  }

  /// 不带前缀的网址认哪些后缀（baidu.com、claude.ai）：打拼音时按 . 转出「百度。」之后，
  /// 接着打的字母正好是其中一个，候选里就多一项整段照打的网址。
  public static let bareDomainSuffixes: Set<String> = [
    "com", "cn", "net", "org", "io", "ai", "app", "dev", "co", "me", "tv", "cc", "top", "xyz",
    "info", "edu", "gov", "uk", "jp", "hk", "tw", "us", "de", "fr", "kr", "sg", "site", "tech",
  ]

  /// 打拼音时按 . 之前的字母能不能当网址的一段：只有小写字母（拼音里的 ' 分隔、大写都不算）。
  public static func isDomainLabel<S: StringProtocol>(_ input: S) -> Bool {
    !input.isEmpty && input.unicodeScalars.allSatisfy { (0x61...0x7a).contains($0.value) }
  }

  /// `text` 末尾（光标前）是不是英文：从后往前跳过空格、数字、英文标点和 emoji，碰到的第一个字是
  /// 拉丁字母就是英文（true），是汉字、全角标点或其他文字就不是（false）。只有这些中性字符、
  /// 碰到换行或什么都没有时返回 nil，由更前面的文字决定，再不知道就按中文。
  public static func followsEnglish<S: StringProtocol>(_ text: S) -> Bool? {
    for scalar in text.unicodeScalars.reversed() {
      if isLineBreak(scalar) { return nil }
      if isNeutral(scalar) { continue }
      return isLatinLetter(scalar)
    }
    return nil
  }

  static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
    (0x41...0x5a).contains(scalar.value) || (0x61...0x7a).contains(scalar.value)
  }

  static func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
    (0x30...0x39).contains(scalar.value)
  }

  /// 英文字母和带音调的拉丁字母（café、naïve）；× ÷ 不算。
  static func isLatinLetter(_ scalar: Unicode.Scalar) -> Bool {
    if isASCIILetter(scalar) { return true }
    switch scalar.value {
    case 0xd7, 0xf7: return false
    case 0xc0...0x24f: return true
    default: return false
    }
  }

  static func isLineBreak(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x0a, 0x0b, 0x0c, 0x0d, 0x85, 0x2028, 0x2029: true
    default: false
    }
  }

  /// 不决定语言的字：空格、制表符、数字、英文标点（"Hello." 后面的引号仍跟英文）、emoji。
  static func isNeutral(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x09, 0x20, 0xa0: return true
    case 0x21...0x7e: return !isASCIILetter(scalar)
    case 0x200d, 0xfe00...0xfe0f: return true
    default: return scalar.properties.isEmojiPresentation || (scalar.properties.isEmoji && scalar.value > 0x7f)
    }
  }
}
