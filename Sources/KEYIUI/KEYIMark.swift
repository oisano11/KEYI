import AppKit

/// KEYI 的「相扣」：菜单栏用的模板图，和输入法图标（IME/Scripts/generate-icon.swift）是同一组路径。
/// 两个点各往对方发两道声波，最外一道越过中线互相扣住：上半左边压右边，下半右边压左边，交叉处留一道透明缝。
/// 小尺寸每道只画靠前沿的一段（画全了像两个扣在一起的字母 C）。780 单位画板，原点在中心，坐标向下增长。
enum KEYIMark {
    /// 菜单栏模板图：只看透明度，系统按菜单栏深浅自动着色。
    static let menuBarImage: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.translateBy(x: rect.midX, y: rect.midY)
            context.scaleBy(x: rect.width / box, y: rect.height / box)
            context.setFillColor(NSColor.black.cgColor)
            for path in paths {
                context.addPath(path)
                context.fillPath()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "KEYI"
        return image
    }()

    private static let box: CGFloat = 780
    private static let distance: CGFloat = 660      // 两点间距
    private static let dotRadius: CGFloat = 50
    private static let gap: CGFloat = 44            // 扣缝
    /// 每道：半径（前沿离声源 2R）、前沿最粗处、只画靠前沿的比例。最后一道互相扣住。
    private static let waves: [(radius: CGFloat, thickness: CGFloat, keep: CGFloat)] = [(100, 60, 0.46), (222, 78, 0.6)]

    private static func circle(_ cx: CGFloat, _ r: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: cx - r, y: -r, width: 2 * r, height: 2 * r), transform: nil)
    }

    private static func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGPath {
        CGPath(rect: CGRect(x: x, y: y, width: w, height: h), transform: nil)
    }

    /// x0 处那个点往对方发的一道（side = +1 往右）。
    private static func wave(_ x0: CGFloat, _ side: CGFloat, _ radius: CGFloat, _ thickness: CGFloat) -> CGPath {
        let cx = x0 + side * radius
        return circle(cx, radius).subtracting(circle(cx - side * thickness / 2, radius - thickness / 2))
    }

    /// 只留靠前沿的一段。
    private static func front(_ path: CGPath, _ x0: CGFloat, _ side: CGFloat, _ radius: CGFloat, _ keep: CGFloat) -> CGPath {
        let cut = x0 + side * 2 * radius * (1 - keep)
        return path.intersection(side > 0 ? rect(cut, -box, 2 * box, 2 * box) : rect(cut - 2 * box, -box, 2 * box, 2 * box))
    }

    private static func band(_ path: CGPath) -> CGPath {
        path.union(path.copy(strokingWithWidth: gap, lineCap: .butt, lineJoin: .round, miterLimit: 10))
    }

    /// 每次画时现算（CGPath 不是 Sendable，不能放进静态常量）；只有几次路径运算。
    private static var paths: [CGPath] {
        let left = -distance / 2, right = distance / 2
        var drawn = [circle(left, dotRadius), circle(right, dotRadius)]
        for w in waves.dropLast() {
            drawn.append(front(wave(left, 1, w.radius, w.thickness), left, 1, w.radius, w.keep))
            drawn.append(front(wave(right, -1, w.radius, w.thickness), right, -1, w.radius, w.keep))
        }
        let outer = waves.last!
        let leftOuter = wave(left, 1, outer.radius, outer.thickness)
        let rightOuter = wave(right, -1, outer.radius, outer.thickness)
        drawn.append(front(leftOuter, left, 1, outer.radius, outer.keep)
            .subtracting(band(rightOuter).intersection(rect(-box, 0, 2 * box, box))))
        drawn.append(front(rightOuter, right, -1, outer.radius, outer.keep)
            .subtracting(band(leftOuter).intersection(rect(-box, -box, 2 * box, box))))
        return drawn
    }
}
