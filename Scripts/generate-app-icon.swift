import AppKit
import Foundation

/// 生成 KEYI 可译的应用图标：暖白圆角底上一只橘红到宝石红渐变的蜂鸟，
/// 照设计稿 design/ime-logo/keyi-ime-icon.svg（分支 claude/keyi-input-logo-design-70b896，128 单位画板）。
/// 输出一个 .iconset 目录，再用 iconutil 转成 icns：
///   swift Scripts/generate-app-icon.swift /tmp/KEYI.iconset
///   iconutil -c icns /tmp/KEYI.iconset -o AppBundle/KEYI.icns

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: generate-app-icon.swift OUTPUT.iconset\n".utf8))
    exit(2)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: stops.map(\.1) as CFArray,
        locations: stops.map(\.0)
    )!
}

func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

let wing: CGPath = {
    let path = CGMutablePath()
    path.move(to: point(62, 58))
    path.addCurve(to: point(6, 4), control1: point(56, 30), control2: point(36, 10))
    path.addCurve(to: point(44, 52), control1: point(26, 16), control2: point(38, 32))
    path.addCurve(to: point(54, 70), control1: point(46, 60), control2: point(50, 66))
    path.closeSubpath()
    return path
}()

let body: CGPath = {
    let path = CGMutablePath()
    path.move(to: point(126, 48))
    path.addLine(to: point(95, 42))
    path.addCurve(to: point(64, 42), control1: point(90, 30), control2: point(70, 28))
    path.addCurve(to: point(26, 120), control1: point(60, 58), control2: point(48, 84))
    path.addCurve(to: point(84, 64), control1: point(54, 102), control2: point(74, 84))
    path.addCurve(to: point(95, 50), control1: point(87, 57), control2: point(90, 52))
    path.closeSubpath()
    return path
}()

let backgroundGradient = gradient([(0, color(0xFFFDF9)), (1, color(0xF1EBE2))])
let birdGradient = gradient([(0, color(0xFF7A45)), (0.55, color(0xE8304F)), (1, color(0xB3123E))])
let sheenGradient = gradient([(0, color(0xFFFFFF, 0.35)), (0.45, color(0xFFFFFF, 0))])

func render(pixels: Int) -> Data? {
    let size = CGFloat(pixels)
    guard let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    // macOS 图标网格：圆角方块占画布 824/1024，四周留透明边。设计稿坐标向下增长。
    let inset = size * 100 / 1024
    let unit = (size - inset * 2) / 128
    context.translateBy(x: inset, y: size - inset)
    context.scaleBy(x: unit, y: -unit)

    let tile = CGPath(
        roundedRect: CGRect(x: 0, y: 0, width: 128, height: 128),
        cornerWidth: 28.6, cornerHeight: 28.6, transform: nil
    )
    context.saveGState()
    context.addPath(tile)
    context.clip()
    context.drawLinearGradient(backgroundGradient, start: point(0, 0), end: point(0, 128), options: [])

    // 蜂鸟单独画在一层：先填翅膀，再沿身体描一道透明缝，最后填身体。
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    context.translateBy(x: 17.8, y: 20.6)
    context.scaleBy(x: 0.7, y: 0.7)
    context.saveGState()
    context.addPath(wing)
    context.clip()
    context.drawLinearGradient(birdGradient, start: point(10, 0), end: point(110, 120), options: [])
    context.restoreGState()
    context.setBlendMode(.clear)
    context.addPath(body)
    context.setLineWidth(6)
    context.strokePath()
    context.setBlendMode(.normal)
    context.saveGState()
    context.addPath(body)
    context.clip()
    context.drawLinearGradient(birdGradient, start: point(10, 0), end: point(110, 120), options: [])
    context.restoreGState()
    context.endTransparencyLayer()

    context.drawLinearGradient(sheenGradient, start: point(0, 0), end: point(0, 128), options: [])
    context.restoreGState()

    guard let image = context.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        guard let data = render(pixels: points * scale) else {
            FileHandle.standardError.write(Data("could not render \(name)\n".utf8))
            exit(1)
        }
        try data.write(to: output.appendingPathComponent(name))
    }
}
print("generate-app-icon: wrote \(output.path)")
