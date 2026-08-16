import Foundation

public enum TerminalCommandSelection {
    private static let promptMarkers = ["% ", "$ ", "# ", "> "]

    public static func currentLine(
        in value: String,
        cursorRange: NSRange
    ) -> FocusedTextSelection? {
        guard cursorRange.length == 0 else { return nil }

        let text = value as NSString
        let textLength = text.length
        guard cursorRange.location != NSNotFound,
              cursorRange.location <= textLength,
              textLength > 0 else {
            return nil
        }

        let probeLocation = lineProbeLocation(
            in: text,
            cursorLocation: cursorRange.location
        )
        let lineRange = text.lineRange(
            for: NSRange(location: probeLocation, length: 0)
        )
        guard let commandStart = commandStart(
            in: text,
            lineRange: lineRange
        ) else {
            return nil
        }

        let commandRange = trimmedRange(
            in: text,
            range: NSRange(
                location: commandStart,
                length: NSMaxRange(lineRange) - commandStart
            )
        )
        guard commandRange.length > 0,
              cursorRange.location >= NSMaxRange(commandRange),
              cursorRange.location <= NSMaxRange(lineRange) else {
            return nil
        }

        let commandSuffix = NSRange(
            location: NSMaxRange(commandRange),
            length: cursorRange.location - NSMaxRange(commandRange)
        )
        guard commandSuffix.length == 0
                || text.substring(with: commandSuffix).rangeOfCharacter(
                    from: .whitespaces.inverted
                ) == nil else {
            return nil
        }

        return FocusedTextSelection(
            text: text.substring(with: commandRange),
            range: commandRange
        )
    }

    public static func isSafeReplacement(_ text: String) -> Bool {
        !text.isEmpty
            && text.rangeOfCharacter(
                from: CharacterSet.controlCharacters.union(.newlines)
            ) == nil
    }

    private static func lineProbeLocation(
        in text: NSString,
        cursorLocation: Int
    ) -> Int {
        guard cursorLocation > 0 else { return cursorLocation }
        if cursorLocation == text.length {
            return cursorLocation - 1
        }

        let character = text.substring(
            with: NSRange(location: cursorLocation, length: 1)
        )
        return character.rangeOfCharacter(
            from: .newlines
        ) == nil ? cursorLocation : cursorLocation - 1
    }

    private static func commandStart(
        in text: NSString,
        lineRange: NSRange
    ) -> Int? {
        let line = text.substring(with: lineRange) as NSString
        let markerRanges = promptMarkers.flatMap { marker -> [NSRange] in
            allRanges(of: marker, in: line)
        }
        guard markerRanges.count == 1,
              let markerRange = markerRanges.first else {
            return nil
        }

        return lineRange.location + NSMaxRange(markerRange)
    }

    private static func allRanges(
        of marker: String,
        in text: NSString
    ) -> [NSRange] {
        var ranges: [NSRange] = []
        var searchRange = NSRange(location: 0, length: text.length)

        while searchRange.length > 0 {
            let range = text.range(of: marker, options: [], range: searchRange)
            guard range.location != NSNotFound else { break }
            ranges.append(range)

            let nextLocation = NSMaxRange(range)
            searchRange = NSRange(
                location: nextLocation,
                length: text.length - nextLocation
            )
        }

        return ranges
    }

    private static func trimmedRange(
        in text: NSString,
        range: NSRange
    ) -> NSRange {
        var start = range.location
        var end = NSMaxRange(range)

        while start < end,
              isWhitespaceOrNewline(text, at: start) {
            start += 1
        }
        while end > start,
              isWhitespaceOrNewline(text, at: end - 1) {
            end -= 1
        }

        return NSRange(location: start, length: end - start)
    }

    private static func isWhitespaceOrNewline(
        _ text: NSString,
        at location: Int
    ) -> Bool {
        let character = text.substring(
            with: NSRange(location: location, length: 1)
        )
        return character.rangeOfCharacter(
            from: .whitespacesAndNewlines
        ) != nil
    }
}
