import Foundation

public struct FocusedTextSelection: Equatable, Sendable {
    public let text: String
    public let range: NSRange

    public init(text: String, range: NSRange) {
        self.text = text
        self.range = range
    }

    public static func translationSelection(
        value: String,
        selectedRange: NSRange
    ) -> FocusedTextSelection? {
        guard !value.isEmpty else { return nil }

        let utf16Length = (value as NSString).length
        let validSelection = selectedRange.location != NSNotFound
            && selectedRange.location <= utf16Length
            && selectedRange.length <= utf16Length - selectedRange.location

        guard validSelection else { return nil }

        let range = selectedRange.length > 0
            ? selectedRange
            : NSRange(location: 0, length: utf16Length)
        let text = (value as NSString).substring(with: range)

        return FocusedTextSelection(text: text, range: range)
    }

    public func replacing(in value: String, with replacement: String) -> String? {
        let utf16Length = (value as NSString).length
        guard range.location != NSNotFound,
              range.location <= utf16Length,
              range.length <= utf16Length - range.location else {
            return nil
        }

        let result = NSMutableString(string: value)
        result.replaceCharacters(in: range, with: replacement)
        return result as String
    }
}
