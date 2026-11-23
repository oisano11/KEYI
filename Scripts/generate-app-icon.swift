import AppKit
import CoreImage
import Foundation

/// 生成 KEYI 的应用图标「相扣」（2026-11-09 定稿）：深夜底上两个点，各自往对方发三道新月声波，
/// 每道后半圈淡出；两边最外一道各越过中线 64、互相穿过，上半你压对方、下半对方压你，交叉处留 12 的透明缝。
/// 颜色同一家：你这边天蓝，传到对方面前变成对方的薰衣草，反之亦然。
/// 坐标沿用设计稿的 1024 画板（坐标向下增长），64 网格：两点直径 64、相距 576，
/// 新月半径 48/100/176（前沿离声源 96/200/352），最粗 26/26/34。32px 以下换小图：两边各两道、加粗、缝加宽。
///
/// macOS（输出 .iconset，再用 iconutil 转成 icns）：
///   swift Scripts/generate-app-icon.swift /tmp/KEYI.iconset
///   iconutil -c icns /tmp/KEYI.iconset -o AppBundle/KEYI.icns
/// Windows（底板铺满、不带阴影，输出 keyi-16.png … keyi-256.png，由 Windows/IME/Scripts/make-icon.py 打包成 ico）：
///   swift Scripts/generate-app-icon.swift --windows OUTPUT_DIRECTORY

let arguments = Array(CommandLine.arguments.dropFirst())
let windowsMode = arguments.first == "--windows"
guard let outputArgument = windowsMode ? arguments.dropFirst().first : arguments.first,
      !outputArgument.hasPrefix("-") else {
    FileHandle.standardError.write(Data("usage: generate-app-icon.swift [--windows] OUTPUT\n".utf8))
    exit(2)
}
let output = URL(fileURLWithPath: outputArgument)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

// MARK: - 颜色与规格

func rgb(_ hex: UInt32) -> (CGFloat, CGFloat, CGFloat) {
    (CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255)
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    let (r, g, b) = rgb(hex)
    return CGColor(srgbRed: r, green: g, blue: b, alpha: alpha)
}

func mix(_ a: UInt32, _ b: UInt32, _ t: CGFloat, alpha: CGFloat) -> CGColor {
    let (r1, g1, b1) = rgb(a), (r2, g2, b2) = rgb(b)
    return CGColor(srgbRed: r1 + (r2 - r1) * t, green: g1 + (g2 - g1) * t, blue: b1 + (b2 - b1) * t, alpha: alpha)
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: stops.map(\.1) as CFArray,
        locations: stops.map(\.0)
    )!
}

let tileTop: UInt32 = 0x1C2142, tileBottom: UInt32 = 0x06071A
let you: UInt32 = 0x7CC8FF, them: UInt32 = 0xB9A2FF          // 天蓝、薰衣草
let youDot: UInt32 = 0xD2EEFF, themDot: UInt32 = 0xDCCFFF
let glowColor: UInt32 = 0xF1E9FF

struct Spec {
    var distance: CGFloat        // 两点间距
    var radii: [CGFloat]         // 新月半径（前沿离声源 2R）
    var thickness: [CGFloat]     // 新月前沿最粗处
    var dot: CGFloat             // 点的半径
    var gap: CGFloat             // 扣缝宽
    var fadeMid: CGFloat         // 新月最高点的不透明度（后半圈淡出）
    var bloom: CGFloat           // 光晕层的不透明度
    var glow: (rx: CGFloat, ry: CGFloat, alpha: CGFloat)
}

let full = Spec(distance: 576, radii: [48, 100, 176], thickness: [26, 26, 34], dot: 32, gap: 12,
                fadeMid: 0.2, bloom: 0.6, glow: (130, 180, 0.5))
let small = Spec(distance: 600, radii: [72, 190], thickness: [58, 64], dot: 52, gap: 22,
                 fadeMid: 0.5, bloom: 0.3, glow: (140, 200, 0.5))

// MARK: - 形状

func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r), transform: nil)
}

/// 新月：在 x0 与声源相切，side = +1 往右传、-1 往左传，前沿最粗 t。
func crescent(_ x0: CGFloat, _ radius: CGFloat, _ t: CGFloat, _ side: CGFloat) -> CGPath {
    let cx = x0 + side * radius
    return circle(cx, 512, radius).subtracting(circle(cx - side * t / 2, 512, radius - t / 2))
}

/// macOS 图标底板：n = 5 的超椭圆，占 1024 画布的 824。
let squircle: CGPath = {
    let path = CGMutablePath()
    let steps = 480, a: CGFloat = 412, n: CGFloat = 5
    for i in 0..<steps {
        let t = 2 * CGFloat.pi * CGFloat(i) / CGFloat(steps)
        let c = cos(t), s = sin(t)
        let x = 512 + a * copysign(pow(abs(c), 2 / n), c)
        let y = 512 + a * copysign(pow(abs(s), 2 / n), s)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}()

/// 一道新月的填色：颜色从声源的颜色渐变到对方的颜色（整组跨度 span），透明度沿传播方向
/// 声源处 0、最高点 fadeMid、前沿 78% 起为 1。两者都随 x 线性变化，合成一条渐变。
func waveGradient(radius: CGFloat, span: CGFloat, from: UInt32, to: UInt32, fadeMid: CGFloat) -> CGGradient {
    let fade: [(CGFloat, CGFloat)] = [(0, 0), (0.5, fadeMid), (0.78, 1), (1, 1)]
    return gradient(fade.map { u, alpha in (u, mix(from, to, min(1, u * 2 * radius / span), alpha: alpha)) })
}

struct Wave {
    var path: CGPath
    var x0: CGFloat
    var side: CGFloat
    var radius: CGFloat
    var gradient: CGGradient
}

func fill(_ context: CGContext, _ wave: Wave, clip: CGPath? = nil) {
    context.saveGState()
    context.addPath(clip ?? wave.path)
    context.clip()
    context.drawLinearGradient(
        wave.gradient,
        start: CGPoint(x: wave.x0, y: 512),
        end: CGPoint(x: wave.x0 + wave.side * 2 * wave.radius, y: 512),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    context.restoreGState()
}

struct Mark {
    var inner: [Wave]
    var outerYou: Wave        // 你这边最外一道
    var outerThem: Wave
    var youCut: CGPath        // 你这道挖掉对方压上来的地方（下半）
    var themCut: CGPath       // 对方这道挖掉你压上去的地方（上半）
    var xl: CGFloat
    var xr: CGFloat
}

func mark(_ spec: Spec) -> Mark {
    let xl = 512 - spec.distance / 2, xr = 512 + spec.distance / 2
    let span = 2 * spec.radii.last!
    var inner: [Wave] = []
    var outer: [Wave] = []
    for (side, x0, from, to) in [(CGFloat(1), xl, you, them), (CGFloat(-1), xr, them, you)] {
        for (index, (radius, t)) in zip(spec.radii, spec.thickness).enumerated() {
            let wave = Wave(path: crescent(x0, radius, t, side), x0: x0, side: side, radius: radius,
                            gradient: waveGradient(radius: radius, span: span, from: from, to: to, fadeMid: spec.fadeMid))
            if index == spec.radii.count - 1 { outer.append(wave) } else { inner.append(wave) }
        }
    }
    let top = CGPath(rect: CGRect(x: 0, y: 0, width: 1024, height: 512), transform: nil)
    let bottom = CGPath(rect: CGRect(x: 0, y: 512, width: 1024, height: 512), transform: nil)
    func band(_ wave: Wave) -> CGPath {
        wave.path.union(wave.path.copy(strokingWithWidth: spec.gap, lineCap: .butt, lineJoin: .round, miterLimit: 10))
    }
    return Mark(
        inner: inner, outerYou: outer[0], outerThem: outer[1],
        youCut: outer[0].path.subtracting(band(outer[1]).intersection(bottom)),
        themCut: outer[1].path.subtracting(band(outer[0]).intersection(top)),
        xl: xl, xr: xr
    )
}

// MARK: - 绘制

func bitmap(_ pixels: Int) -> CGContext {
    CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
}

func blurred(_ image: CGImage, sigma: CGFloat) -> CGImage? {
    let input = CIImage(cgImage: image)
    let filter = CIFilter(name: "CIGaussianBlur")!
    filter.setValue(input, forKey: kCIInputImageKey)
    filter.setValue(sigma, forKey: kCIInputRadiusKey)
    guard let result = filter.outputImage?.cropped(to: input.extent) else { return nil }
    return CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
        .createCGImage(result, from: input.extent)
}

/// windows = true：底板铺满画布（四周留 3%），不画阴影。
func render(pixels: Int, windows: Bool) -> Data? {
    let size = CGFloat(pixels)
    let spec = pixels <= 32 ? small : full
    let m = mark(spec)

    // 1024 画板 → 像素，坐标向下增长。macOS 底板在 100…924；Windows 把这一段铺到 3%…97%。
    let transform: CGAffineTransform = {
        let scale = windows ? size * 0.94 / 824 : size / 1024
        let origin = windows ? size * 0.03 - 100 * scale : 0
        return CGAffineTransform(a: scale, b: 0, c: 0, d: -scale, tx: origin, ty: size - origin)
    }()
    let unit = transform.a

    // 光晕层：三道新月（最外两道不挖缝）单独画好再高斯模糊。
    let glowLayer = bitmap(pixels)
    glowLayer.concatenate(transform)
    for wave in m.inner + [m.outerYou, m.outerThem] { fill(glowLayer, wave) }
    let bloom = glowLayer.makeImage().flatMap { blurred($0, sigma: 12 * unit) }

    let context = bitmap(pixels)
    context.concatenate(transform)

    if !windows {
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -12 * unit), blur: 28 * unit, color: color(0x000000, 0.22))
        context.addPath(squircle)
        context.setFillColor(color(tileTop))
        context.fillPath()
        context.restoreGState()
    }

    context.saveGState()
    context.addPath(squircle)
    context.clip()
    context.drawLinearGradient(gradient([(0, color(tileTop)), (1, color(tileBottom))]),
                               start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: [])

    // 两边声波交汇处的一团光
    context.saveGState()
    context.translateBy(x: 512, y: 512)
    context.scaleBy(x: spec.glow.rx, y: spec.glow.ry)
    context.drawRadialGradient(
        gradient([(0, color(glowColor, spec.glow.alpha)), (0.5, color(glowColor, spec.glow.alpha / 4)), (1, color(glowColor, 0))]),
        startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: []
    )
    context.restoreGState()

    if let bloom {
        context.saveGState()
        context.concatenate(transform.inverted())
        context.setAlpha(spec.bloom)
        context.draw(bloom, in: CGRect(x: 0, y: 0, width: size, height: size))
        context.restoreGState()
    }

    for wave in m.inner { fill(context, wave) }
    fill(context, m.outerYou, clip: m.youCut)
    fill(context, m.outerThem, clip: m.themCut)

    context.setFillColor(color(youDot))
    context.addPath(circle(m.xl, 512, spec.dot))
    context.fillPath()
    context.setFillColor(color(themDot))
    context.addPath(circle(m.xr, 512, spec.dot))
    context.fillPath()

    // 上半一层很淡的高光
    context.drawLinearGradient(gradient([(0, color(0xFFFFFF, 0.16)), (0.5, color(0xFFFFFF, 0))]),
                               start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: [])
    context.restoreGState()

    // 底板边缘一圈细光
    context.saveGState()
    context.addPath(squircle)
    context.setLineWidth(4)
    context.replacePathWithStrokedPath()
    context.clip()
    context.drawLinearGradient(
        gradient([(0, color(0xFFFFFF, 0.32)), (0.5, color(0xFFFFFF, 0)), (1, color(0xFFFFFF, 0.13))]),
        start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: []
    )
    context.restoreGState()

    guard let image = context.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
}

func write(_ name: String, pixels: Int) throws {
    guard let data = render(pixels: pixels, windows: windowsMode) else {
        FileHandle.standardError.write(Data("could not render \(name)\n".utf8))
        exit(1)
    }
    try data.write(to: output.appendingPathComponent(name))
}

if windowsMode {
    for pixels in [16, 20, 24, 32, 48, 64, 256] {
        try write("keyi-\(pixels).png", pixels: pixels)
    }
} else {
    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            try write(scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png",
                      pixels: points * scale)
        }
    }
}
print("generate-app-icon: wrote \(output.path)")
