//
//  ChecksPunctuation.swift
//  英文后面的标点按英文（半角）出（用户 2026-11-08）：前文判断规则，以及英文标点照常并进暂存段。
//  会话里按键怎么走由 `KEYIIME --diagnose-session-translation` 的 punctuation 组用真实 Rime 检查。
//

import Foundation
import KeyiIMETranslation

func checkPunctuationAfterEnglish() {
  section("punctuation after English")
  func follows(_ text: String) -> Bool? { KeyiPunctuationContext.followsEnglish(text) }
  // 英文：字母、带音调的拉丁字母，跳过空格、数字、英文标点和 emoji 往前找。
  expectEqual(follows("hello"), true, "punct: after a letter")
  expectEqual(follows("Hello "), true, "punct: a trailing space is skipped")
  expectEqual(follows("Hello."), true, "punct: English punctuation is skipped")
  expectEqual(follows("Python3"), true, "punct: digits after a letter are skipped")
  expectEqual(follows("café"), true, "punct: accented Latin letters are English")
  expectEqual(follows("ok👍"), true, "punct: an emoji after English is skipped")
  expectEqual(follows("你好hello"), true, "punct: English after Chinese decides by the English")
  // 中文：汉字、全角标点、其他文字。
  expectEqual(follows("你好"), false, "punct: after a Han character")
  expectEqual(follows("价格20"), false, "punct: digits after Chinese stay Chinese")
  expectEqual(follows("好的👍"), false, "punct: an emoji after Chinese is skipped")
  expectEqual(follows("hello，"), false, "punct: a full-width comma is Chinese")
  expectEqual(follows("你好/"), false, "punct: an ASCII slash after Chinese is skipped")
  expectEqual(follows("2×"), false, "punct: × is not a letter")
  // 看不出来：空、只有数字或空格、换行之后。
  expectEqual(follows(""), nil, "punct: empty text decides nothing")
  expectEqual(follows("3 "), nil, "punct: digits and spaces alone decide nothing")
  expectEqual(follows("Hello\n"), nil, "punct: a new line starts afresh")

  // 哪些键：ASCII 可见字符里的标点，不含字母、数字、空格。
  for key in [",", ".", "?", "!", ":", ";", "\"", "'", "(", "[", "-", "_", "\\", "/", "<", "$", "~"] {
    let value = Int(key.unicodeScalars.first!.value)
    expect(KeyiPunctuationContext.isPunctuationKey(value), "punct: \(key) is a punctuation key")
  }
  for key in ["a", "Z", "0", "9", " "] {
    let value = Int(key.unicodeScalars.first!.value)
    expect(!KeyiPunctuationContext.isPunctuationKey(value), "punct: '\(key)' is not a punctuation key")
  }
  expect(!KeyiPunctuationContext.isPunctuationKey(0xff0d), "punct: Enter is not a punctuation key")

  // 网址和邮箱（用户 2026-11-11）：与 keyi_pinyin.schema.yaml 的 recognizer/patterns 同一套。
  for input in ["www.", "www.baidu.com", "http:", "https://x.com/a?b=1", "ftp.", "mailto:", "file:", "oisano@", "a_b.c-1@x",
                "baidu.com", "news.sina.com.cn", "baidu.com.", "github.com/oisano11", "x.ai:8080", "a-b.c1"] {
    expect(KeyiPunctuationContext.isAddressInput(input), "address: \(input) is an address")
  }
  for input in ["", "www", "women", "http", "baidu.", "baidu", "baidu..com", "baidu.com,", "-a.com", "@", "1a@", "ni hao@", "Www."] {
    expect(!KeyiPunctuationContext.isAddressInput(input), "address: '\(input)' is not an address")
  }

  // 不带前缀的网址：哪些字母能当一段、认哪些后缀。
  expect(KeyiPunctuationContext.isDomainLabel("baidu"), "domain: baidu is a label")
  expect(!KeyiPunctuationContext.isDomainLabel("xi'an") && !KeyiPunctuationContext.isDomainLabel(""), "domain: an apostrophe or nothing is not a label")
  for suffix in ["com", "cn", "net", "org", "io", "ai"] {
    expect(KeyiPunctuationContext.bareDomainSuffixes.contains(suffix), "domain: \(suffix) is a suffix")
  }
  expect(!KeyiPunctuationContext.bareDomainSuffixes.contains("women"), "domain: women is not a suffix")

  // 英文标点和中文标点一样只是普通文字：并进暂存段，不触发翻译。
  let h = Harness()
  h.confirm("你好")
  h.confirm("GitHub")
  h.confirm(",")
  expectEqual(h.controller.heldText, "你好GitHub,", "punct: an English comma joins the held paragraph")
  expectEqual(h.committed, "", "punct: nothing is committed")
  expectEqual(h.stub.count, 0, "punct: no request is sent for the comma")
}
