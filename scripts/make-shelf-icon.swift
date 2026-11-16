// Shelf artwork drawn with AppKit: copies pegged to a line, a note in front with a picture and a link beside it.
import AppKit

guard CommandLine.arguments.count == 2 else { exit(1) }
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}
func rounded(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: height), xRadius: radius, yRadius: radius)
}
func saved(_ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState(); draw(); NSGraphicsContext.restoreGraphicsState()
}
func shadowed(_ alpha: CGFloat, blur: CGFloat, drop: CGFloat, _ draw: () -> Void) {
    saved {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(alpha)
        shadow.shadowBlurRadius = blur
        shadow.shadowOffset = NSSize(width: 0, height: -drop)
        shadow.set(); draw()
    }
}
func fill(_ path: NSBezierPath, top: NSColor, bottom: NSColor) {
    NSGradient(starting: bottom, ending: top)!.draw(in: path, angle: 90)
}

let white = NSColor.white
let paper = (top: white, bottom: color(0.94, 0.94, 0.96))
let blue = color(0.05, 0.38, 0.90)
let orange = color(1.0, 0.58, 0.0)

/// The line sags between its ends; a card hangs from the point above it.
func line(at x: CGFloat) -> CGFloat { 742 - 40 * (1 - pow((x - 512) / 452, 2)) }

/// A card hanging from `(x, line)`, turned a little, with its pegs and whatever is printed on it.
func hang(_ x: CGFloat, turn: CGFloat, width: CGFloat, height: CGFloat, radius: CGFloat,
          top: NSColor, bottom: NSColor, peg: NSColor, pegs: [CGFloat] = [0], _ content: (NSRect) -> Void) {
    saved {
        let transform = NSAffineTransform()
        transform.translateX(by: x, yBy: line(at: x)); transform.rotate(byDegrees: turn); transform.concat()
        let rect = NSRect(x: -width / 2, y: -height - 10, width: width, height: height)
        let card = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        shadowed(0.18, blur: 12, drop: 6) { bottom.setFill(); card.fill() }
        fill(card, top: top, bottom: bottom)
        content(rect)
        for offset in pegs { peg.setFill(); rounded(offset - 13, -48, 26, 80, 10).fill() }
    }
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// The standard macOS icon grid: an 824-point body in a 1024 canvas.
let body = rounded(100, 100, 824, 824, 185)
shadowed(0.30, blur: 20, drop: 10) { blue.setFill(); body.fill() }
fill(body, top: color(0.33, 0.68, 1.0), bottom: blue)
body.addClip()

let rope = NSBezierPath()
rope.move(to: NSPoint(x: 60, y: line(at: 60)))
for x in stride(from: CGFloat(66), through: 964, by: 6) { rope.line(to: NSPoint(x: x, y: line(at: x))) }
rope.lineWidth = 16; rope.lineCapStyle = .round
shadowed(0.12, blur: 12, drop: 6) { white.setStroke(); rope.stroke() }

// A picture leaving the frame on the left.
hang(184, turn: -6, width: 236, height: 320, radius: 34, top: paper.top, bottom: paper.bottom, peg: color(1, 1, 1, 0.9)) { rect in
    blue.set()
    let sun = rect.width * 0.17
    NSBezierPath(ovalIn: NSRect(x: rect.maxX - rect.width * 0.36, y: rect.maxY - rect.width * 0.36, width: sun, height: sun)).fill()
    let left = rect.minX + rect.width * 0.14, base = rect.minY + rect.height * 0.16
    let width = rect.width * 0.72, height = rect.height * 0.34
    let hills = NSBezierPath()
    hills.move(to: NSPoint(x: left, y: base))
    hills.line(to: NSPoint(x: left + width * 0.34, y: base + height))
    hills.line(to: NSPoint(x: left + width * 0.56, y: base + height * 0.52))
    hills.line(to: NSPoint(x: left + width * 0.72, y: base + height * 0.78))
    hills.line(to: NSPoint(x: left + width, y: base))
    hills.close(); hills.lineJoinStyle = .round; hills.lineWidth = 10
    hills.fill(); hills.stroke()
}
// A link leaving it on the right.
hang(840, turn: 6, width: 236, height: 280, radius: 34, top: color(1.0, 0.74, 0.24), bottom: color(1.0, 0.56, 0.0), peg: color(1, 1, 1, 0.9)) { rect in
    white.setStroke()
    for side: CGFloat in [-0.15, 0.15] {
        let width = rect.width * 0.34, height = width * 0.56
        let ring = rounded(rect.midX + side * rect.width - width / 2, rect.midY - height / 2, width, height, height / 2)
        ring.lineWidth = rect.width * 0.075; ring.stroke()
    }
}
// The newest copy, a note, in front on two orange pegs.
hang(512, turn: 0, width: 318, height: 420, radius: 40, top: paper.top, bottom: paper.bottom, peg: orange, pegs: [-86, 86]) { rect in
    color(0.72, 0.80, 0.92).setFill()
    let area = NSRect(x: rect.minX, y: rect.minY + 30, width: rect.width, height: rect.height - 70)
    for index in 0..<5 {
        let width = area.width * (index == 4 ? 0.42 : 0.68)
        rounded(area.minX + area.width * 0.16, area.maxY - area.height * 0.22 - CGFloat(index) * area.height * 0.17,
                width, area.height * 0.065, area.height * 0.033).fill()
    }
}
NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
do { try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1])) } catch { exit(1) }
