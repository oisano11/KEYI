import CoreGraphics
import Foundation

/// Renders the input mode icon as a PDF so no binary artwork has to be
/// vendored. The mark is the KEYI hummingbird; the source artwork is
/// design/ime-logo/keyi-ime-menubar.svg on branch
/// claude/keyi-input-logo-design-70b896 (128-unit box).

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write(
        Data("usage: generate-icon.swift OUTPUT_DIRECTORY\n".utf8)
    )
    exit(2)
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(
    at: outputDirectory,
    withIntermediateDirectories: true
)
let outputURL = outputDirectory.appendingPathComponent("KeyiInputLogo.pdf")

let size = CGSize(width: 16, height: 16)
// The page must be the icon size. With `mediaBox: nil` CoreGraphics uses a
// 612×792 letter page, and the input menu scales that page into a huge,
// nearly blank row (seen 10-31).
var mediaBox = CGRect(origin: .zero, size: size)
guard let context = CGContext(outputURL as CFURL, mediaBox: &mediaBox, nil) else {
    FileHandle.standardError.write(
        Data("could not create PDF context\n".utf8)
    )
    exit(1)
}

// macOS draws input method icons as templates: only the alpha counts, so an
// opaque square shows as a solid block (seen 11-01). The bird is drawn in black
// on a clear background.
//
// The page holds vector paths only. Until 11-04 the bird was rasterised into a
// 128-pixel bitmap (to cut the wing/body gap with the clear blend mode) and that
// bitmap was placed on the page. The menu bar drew it, but the input source
// indicator macOS shows under the caret when a text field is focused or the
// input source changes stayed an empty blue capsule: it shows WeType's vector
// PDF and the system Pinyin label, not a bitmap-only PDF. The gap is now cut
// with path operations instead.
let artboard: CGFloat = 128

func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

let wing = CGMutablePath()
wing.move(to: point(60, 62))
wing.addCurve(to: point(0, 0), control1: point(54, 30), control2: point(32, 6))
wing.addCurve(to: point(40, 56), control1: point(20, 20), control2: point(34, 36))
wing.addCurve(to: point(50, 74), control1: point(42, 64), control2: point(46, 70))
wing.closeSubpath()

// Bill, head, back and tail in one stroke.
let body = CGMutablePath()
body.move(to: point(127, 48))
body.addLine(to: point(96, 40.5))
body.addCurve(to: point(60, 41), control1: point(91, 27), control2: point(66, 24))
body.addCurve(to: point(20, 124), control1: point(55, 58), control2: point(44, 86))
body.addCurve(to: point(86, 64), control1: point(54, 104), control2: point(76, 84))
body.addCurve(to: point(97, 51), control1: point(89, 57), control2: point(92, 52))
body.closeSubpath()

// The wing stops 5 units short of the body all round (a 10-unit stroke).
let gap = body.copy(strokingWithWidth: 10, lineCap: .butt, lineJoin: .miter, miterLimit: 10)
let cutWing = wing.subtracting(gap)

context.beginPDFPage(nil)
// SVG coordinates grow downwards; scale the 128-unit artboard onto the 16-point page.
context.translateBy(x: 0, y: size.height)
context.scaleBy(x: size.width / artboard, y: -size.height / artboard)
context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
context.addPath(cutWing)
context.fillPath()
context.addPath(body)
context.fillPath()
context.endPDFPage()
context.closePDF()

print("generate-icon: wrote \(outputURL.path)")
