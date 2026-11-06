//
//  Surface.swift
//  替身应用输入框：已上屏文字 + 一段标记文字，实现与生产相同的客户端协议。
//

import Foundation
import KeyiIMETranslation

final class StubSurface: KeyiTranslationClientSurface {
    /// 已交给应用的文字。
    var committed = ""
    /// 标记文字（暂存的句子 + 拼音），排在已上屏文字之后。
    private(set) var markedText = ""
    var secure = false
    /// 读取永远失败，模拟终端这类读不回文字的应用。
    var textIsUnreadable = false
    /// 不为 nil 时，`markedRange()` 报告这个范围，模拟应用自己改动了标记文字。
    var markedRangeOverride: NSRange?
    private(set) var replacements: [(text: String, range: NSRange)] = []
    private var changeCount = 0

    private var committedLength: Int { (committed as NSString).length }
    private var markedLength: Int { (markedText as NSString).length }
    var document: String { committed + markedText }

    func setMarked(_ text: String) { markedText = text }

    func selectedRange() -> NSRange {
        return NSRange(location: committedLength + markedLength, length: 0)
    }

    func markedRange() -> NSRange {
        if let markedRangeOverride { return markedRangeOverride }
        return markedText.isEmpty
            ? NSRange(location: NSNotFound, length: 0)
            : NSRange(location: committedLength, length: markedLength)
    }

    func documentLength() -> Int { committedLength + markedLength }

    func attributedSubstring(from range: NSRange) -> NSAttributedString? {
        guard !textIsUnreadable else { return nil }
        let text = document as NSString
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0,
              range.location + range.length <= text.length else { return nil }
        return NSAttributedString(string: text.substring(with: range))
    }

    func insertText(_ text: String, replacementRange: NSRange) {
        replacements.append((text, replacementRange))
        let marked = NSRange(location: committedLength, length: markedLength)
        if replacementRange.location == NSNotFound || (!markedText.isEmpty && replacementRange == marked) {
            committed += text
            markedText = ""
        } else if replacementRange.location + replacementRange.length <= committedLength {
            let buffer = NSMutableString(string: committed)
            buffer.replaceCharacters(in: replacementRange, with: text)
            committed = buffer as String
        }
    }

    func hostBundleIdentifier() -> String? { "com.example.host" }
    func clientChangeCount() -> Int { changeCount }
    func noteObservedClientChange() { changeCount += 1 }
    func isSecureInputEnabled() -> Bool { secure }
}
