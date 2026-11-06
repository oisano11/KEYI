import AppKit

/// 单按 Shift：只按下又松开同一个 Shift，中间没有别的键、别的修饰键，也没有点鼠标。
/// Shift+字母（大写）、Shift+点击、Shift+⌘ 等都不算。只看 flagsChanged 事件，
/// 从不吞掉它，也不交给 Rime。
struct KeyiShiftTap {
    static let leftShift: UInt16 = 56
    static let rightShift: UInt16 = 60
    private static let modifiers: NSEvent.ModifierFlags = [.shift, .control, .option, .command, .function]

    private var pressedKeyCode: UInt16?
    private var pressedAt: TimeInterval = 0

    /// 一个 flagsChanged 事件。返回 true 表示刚完成一次单按 Shift（这次是松开）。
    /// `secondsSinceMouseDown` 只在松开时读一次：比按下到现在的时间短，就是中间点过鼠标。
    mutating func flagsChanged(
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags,
        now: TimeInterval,
        secondsSinceMouseDown: () -> TimeInterval
    ) -> Bool {
        let held = flags.intersection(Self.modifiers)
        if let pressed = pressedKeyCode {
            // 有的宿主（网页里的输入框）按住 Shift 时会再送一次同样的按下事件，
            // 那还是同一次按住，不算别的修饰键。
            if keyCode == pressed, held == .shift { return false }
            pressedKeyCode = nil
            // 松开的必须是按下的那个 Shift，且此刻没有任何修饰键还按着。
            guard keyCode == pressed, held.isEmpty else { return false }
            return secondsSinceMouseDown() >= now - pressedAt
        }
        if keyCode == Self.leftShift || keyCode == Self.rightShift, held == .shift {
            pressedKeyCode = keyCode
            pressedAt = now
        }
        return false
    }

    /// 按住 Shift 时来了别的键（含 Shift+字母）：这次不算单按。
    mutating func cancel() {
        pressedKeyCode = nil
    }
}
