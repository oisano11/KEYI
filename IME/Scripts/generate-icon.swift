import CoreGraphics
import Foundation

/// Renders the input mode icon as a PDF so no binary artwork has to be
/// vendored. The mark is KEYI's "clasp" (相扣, chosen 2026-11-09): two dots,
/// each sending sound waves towards the other; the outermost wave from each side
/// reaches past the middle so the two interlock — on top the left one passes
/// over, below the right one does, with a clear gap at each crossing. At 16
/// points each side keeps one inner wave and only the front part of every wave
/// (full arcs would read as two interlocking letter Cs).
/// KEYI 可译's menu bar mark (Sources/KEYIUI/KEYIMark.swift) uses the same paths.

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
// opaque square shows as a solid block (seen 11-01). The mark is drawn in black
// on a clear background.
//
// The page holds vector paths only. Until 11-04 the old mark was rasterised
// into a bitmap and that bitmap was placed on the page. The menu bar drew it,
// but the input source indicator macOS shows under the caret when a text field
// is focused or the input source changes stayed an empty blue capsule: it shows
// WeType's vector PDF and the system Pinyin label, not a bitmap-only PDF. The
// gaps are therefore cut with path operations.

// A 780-unit box centred on the origin, y growing downwards.
let box: CGFloat = 780
let distance: CGFloat = 660      // between the two dots
let dotRadius: CGFloat = 50
let gap: CGFloat = 44            // clear gap where the outermost waves cross
// Each wave: radius (its front lies 2R from its dot), thickness at the front,
// and the part nearest the front that is drawn. The last one interlocks.
let waves: [(radius: CGFloat, thickness: CGFloat, keep: CGFloat)] = [(100, 60, 0.46), (222, 78, 0.6)]

func circle(_ cx: CGFloat, _ r: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: cx - r, y: -r, width: 2 * r, height: 2 * r), transform: nil)
}

func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGPath {
    CGPath(rect: CGRect(x: x, y: y, width: w, height: h), transform: nil)
}

/// A wave of the dot at `x0`, heading towards the other dot (`side` +1 = right).
func wave(_ x0: CGFloat, _ side: CGFloat, _ radius: CGFloat, _ thickness: CGFloat) -> CGPath {
    let cx = x0 + side * radius
    return circle(cx, radius).subtracting(circle(cx - side * thickness / 2, radius - thickness / 2))
}

/// Only the part of a wave nearest its front.
func front(_ path: CGPath, _ x0: CGFloat, _ side: CGFloat, _ radius: CGFloat, _ keep: CGFloat) -> CGPath {
    let cut = x0 + side * 2 * radius * (1 - keep)
    return path.intersection(side > 0 ? rect(cut, -box, 2 * box, 2 * box) : rect(cut - 2 * box, -box, 2 * box, 2 * box))
}

func band(_ path: CGPath) -> CGPath {
    path.union(path.copy(strokingWithWidth: gap, lineCap: .butt, lineJoin: .round, miterLimit: 10))
}

let left: CGFloat = -distance / 2, right: CGFloat = distance / 2
var drawn: [CGPath] = [circle(left, dotRadius), circle(right, dotRadius)]
for w in waves.dropLast() {
    drawn.append(front(wave(left, 1, w.radius, w.thickness), left, 1, w.radius, w.keep))
    drawn.append(front(wave(right, -1, w.radius, w.thickness), right, -1, w.radius, w.keep))
}
let outer = waves.last!
let leftOuter = wave(left, 1, outer.radius, outer.thickness)
let rightOuter = wave(right, -1, outer.radius, outer.thickness)
// On top the left wave passes over the right one; below, the right one over the left.
drawn.append(front(leftOuter, left, 1, outer.radius, outer.keep).subtracting(band(rightOuter).intersection(rect(-box, 0, 2 * box, box))))
drawn.append(front(rightOuter, right, -1, outer.radius, outer.keep).subtracting(band(leftOuter).intersection(rect(-box, -box, 2 * box, box))))

context.beginPDFPage(nil)
context.translateBy(x: size.width / 2, y: size.height / 2)
context.scaleBy(x: size.width / box, y: -size.height / box)
context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
for path in drawn {
    context.addPath(path)
    context.fillPath()
}
context.endPDFPage()
context.closePDF()

print("generate-icon: wrote \(outputURL.path)")
