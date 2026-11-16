// Shelf artwork drawn with Core Graphics.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let side = 1024
let colorSpace = CGColorSpaceCreateDeviceRGB()
guard CommandLine.arguments.count == 2,
      let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                              bytesPerRow: side * 4, space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
context.setAllowsAntialiasing(true)
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: a)
}
func rounded(_ rect: CGRect, _ radius: CGFloat, fill: CGColor) {
    context.setFillColor(fill)
    context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.fillPath()
}
// The standard macOS icon grid: an 824-point body in a 1024 canvas. The artwork is laid out for an 896 tile and scaled to it.
context.translateBy(x: 512, y: 512); context.scaleBy(x: 824.0 / 896.0, y: 824.0 / 896.0); context.translateBy(x: -512, y: -512)
let tile = CGRect(x: 64, y: 64, width: 896, height: 896)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0, 0, 0, 0.28))
rounded(tile, 201, fill: color(0.95, 0.95, 0.96))
context.restoreGState()
context.saveGState()
context.addPath(CGPath(roundedRect: tile, cornerWidth: 201, cornerHeight: 201, transform: nil))
context.clip()
let gradient = CGGradient(colorsSpace: colorSpace,
    colors: [color(1, 1, 1), color(0.89, 0.89, 0.91)] as CFArray,
    locations: [0, 1])!
context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 960), end: CGPoint(x: 512, y: 64), options: [])
context.restoreGState()

// Three purposeful objects on one shelf: image, note, and link.
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -7), blur: 13, color: color(0, 0, 0, 0.18))
rounded(CGRect(x: 228, y: 360, width: 176, height: 330), 22, fill: color(0.0, 0.48, 1.0))
rounded(CGRect(x: 425, y: 360, width: 176, height: 404), 22, fill: color(1, 1, 1))
rounded(CGRect(x: 622, y: 360, width: 176, height: 278), 22, fill: color(1.0, 0.62, 0.04))
context.restoreGState()

// Image mark: a sun and quiet hillside, with crisp optical spacing.
context.setFillColor(color(1, 1, 1))
context.fillEllipse(in: CGRect(x: 330, y: 605, width: 30, height: 30))
context.move(to: CGPoint(x: 248, y: 410))
context.addLine(to: CGPoint(x: 248, y: 524))
context.addLine(to: CGPoint(x: 296, y: 578))
context.addLine(to: CGPoint(x: 337, y: 525))
context.addLine(to: CGPoint(x: 384, y: 555))
context.addLine(to: CGPoint(x: 384, y: 410))
context.closePath()
context.setFillColor(color(0.72, 0.86, 1.0)); context.fillPath()
// Note mark, deliberately shorter last line.
for (y, width) in [(CGFloat(675), CGFloat(106)), (637, 106), (599, 76)] {
    rounded(CGRect(x: 460, y: y, width: width, height: 9), 4.5, fill: color(0.56, 0.56, 0.58))
}
// A restrained horizontal link mark.
context.setStrokeColor(color(1, 1, 1))
context.setLineWidth(12); context.setLineCap(.round)
for x: CGFloat in [650, 692] {
    context.addPath(CGPath(roundedRect: CGRect(x: x, y: 509, width: 48, height: 29), cornerWidth: 14, cornerHeight: 14, transform: nil))
    context.strokePath()
}
// The shelf is the identifying silhouette, with a small shadow underneath.
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -12), blur: 18, color: color(0, 0, 0, 0.20))
rounded(CGRect(x: 188, y: 316, width: 648, height: 48), 13, fill: color(0.23, 0.23, 0.26))
context.restoreGState()
rounded(CGRect(x: 252, y: 250, width: 30, height: 70), 8, fill: color(0.23, 0.23, 0.26))
rounded(CGRect(x: 742, y: 250, width: 30, height: 70), 8, fill: color(0.23, 0.23, 0.26))
let output = URL(fileURLWithPath: CommandLine.arguments[1])
guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { exit(1) }
