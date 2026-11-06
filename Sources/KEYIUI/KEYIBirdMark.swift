import AppKit

/// KEYI 的蜂鸟：菜单栏用的模板图，和输入法图标（IME/Scripts/generate-icon.swift）是同一组路径，
/// 128 单位画板、坐标向下增长。翅膀和身体之间留一道透明缝。
enum KEYIBirdMark {
    /// 菜单栏模板图：只看透明度，系统按菜单栏深浅自动着色。
    static let menuBarImage: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let scale = rect.width / 128
            context.scaleBy(x: scale, y: scale)
            context.setFillColor(NSColor.black.cgColor)
            context.addPath(wing)
            context.fillPath()
            context.setBlendMode(.clear)
            context.addPath(body)
            context.setLineWidth(10)
            context.strokePath()
            context.setBlendMode(.normal)
            context.addPath(body)
            context.fillPath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "KEYI"
        return image
    }()

    private static func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    private static var wing: CGPath {
        let path = CGMutablePath()
        path.move(to: point(60, 62))
        path.addCurve(to: point(0, 0), control1: point(54, 30), control2: point(32, 6))
        path.addCurve(to: point(40, 56), control1: point(20, 20), control2: point(34, 36))
        path.addCurve(to: point(50, 74), control1: point(42, 64), control2: point(46, 70))
        path.closeSubpath()
        return path
    }

    /// 喙、头、背和尾一笔画完。
    private static var body: CGPath {
        let path = CGMutablePath()
        path.move(to: point(127, 48))
        path.addLine(to: point(96, 40.5))
        path.addCurve(to: point(60, 41), control1: point(91, 27), control2: point(66, 24))
        path.addCurve(to: point(20, 124), control1: point(55, 58), control2: point(44, 86))
        path.addCurve(to: point(86, 64), control1: point(54, 104), control2: point(76, 84))
        path.addCurve(to: point(97, 51), control1: point(89, 57), control2: point(92, 52))
        path.closeSubpath()
        return path
    }
}
