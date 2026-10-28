import AppKit
import Foundation

let canvas: CGFloat = 1024
let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: false, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
let context = NSGraphicsContext(bitmapImageRep: bitmap)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high
context.shouldAntialias = true
let cg = context.cgContext
cg.setAllowsAntialiasing(true)
cg.setShouldAntialias(true)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: r, green: g, blue: b, alpha: a)
}
func rounded(_ rect: NSRect, radius: CGFloat, fill: NSColor, stroke: NSColor? = nil, lineWidth: CGFloat = 1) {
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    fill.setFill()
    path.fill()
    if let stroke {
        stroke.setStroke()
        path.lineWidth = lineWidth
        path.stroke()
    }
}
func centeredText(_ text: String, y: CGFloat, font: NSFont, color: NSColor, tracking: CGFloat = 0) {
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .kern: tracking]
    let value = NSAttributedString(string: text, attributes: attributes)
    let measured = value.size()
    value.draw(at: NSPoint(x: (canvas - measured.width) / 2, y: y))
}
func fillPolygon(_ points: [CGPoint], color: NSColor) {
    let path = CGMutablePath()
    guard let first = points.first else { return }
    path.move(to: first)
    for point in points.dropFirst() { path.addLine(to: point) }
    path.closeSubpath()
    cg.setFillColor(color.cgColor)
    cg.addPath(path)
    cg.fillPath()
}

// Midnight-blue background with an electric-blue edge.
NSGradient(colors: [color(0.015, 0.035, 0.085), color(0.025, 0.085, 0.20), color(0.01, 0.025, 0.065)])!
    .draw(in: NSRect(x: 0, y: 0, width: canvas, height: canvas), angle: 90)
rounded(NSRect(x: 22, y: 22, width: 980, height: 980), radius: 138, fill: color(0.02, 0.04, 0.10, 0.18), stroke: color(0.03, 0.34, 0.95), lineWidth: 8)

let ring = NSBezierPath(ovalIn: NSRect(x: 232, y: 515, width: 560, height: 335))
color(0.04, 0.32, 0.87, 0.46).setStroke()
ring.lineWidth = 13
ring.stroke()
let ring2 = NSBezierPath(ovalIn: NSRect(x: 270, y: 548, width: 484, height: 270))
color(0.02, 0.70, 0.97, 0.22).setStroke()
ring2.lineWidth = 4
ring2.stroke()

let leftDoc = NSRect(x: 266, y: 575, width: 205, height: 210)
NSGradient(colors: [color(0.02, 0.63, 1), color(0.02, 0.20, 0.78)])!
    .draw(in: NSBezierPath(roundedRect: leftDoc, xRadius: 28, yRadius: 28), angle: 90)
let rightDoc = NSRect(x: 553, y: 575, width: 205, height: 210)
NSGradient(colors: [color(0.96, 0.99, 1), color(0.63, 0.82, 1)])!
    .draw(in: NSBezierPath(roundedRect: rightDoc, xRadius: 28, yRadius: 28), angle: 90)

for x in [CGFloat(318), CGFloat(605)] {
    rounded(NSRect(x: x, y: 660, width: 100, height: 72), radius: 12, fill: x < 400 ? color(0.01, 0.24, 0.64) : color(0.76, 0.89, 1))
    let glyphColor = x < 400 ? color(0.70, 0.94, 1) : color(0.02, 0.18, 0.47)
    for (y, length) in [(CGFloat(711), CGFloat(64)), (CGFloat(692), CGFloat(52)), (CGFloat(673), CGFloat(40))] {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x + 18, y: y))
        path.addLine(to: CGPoint(x: x + 18 + length, y: y))
        cg.setStrokeColor(glyphColor.cgColor)
        cg.setLineWidth(8)
        cg.setLineCap(.round)
        cg.addPath(path)
        cg.strokePath()
    }
}

let upperArrow = CGMutablePath()
upperArrow.move(to: CGPoint(x: 344, y: 825))
upperArrow.addCurve(to: CGPoint(x: 680, y: 825), control1: CGPoint(x: 410, y: 908), control2: CGPoint(x: 610, y: 908))
cg.setStrokeColor(color(0.02, 0.82, 1).cgColor)
cg.setLineWidth(28)
cg.setLineCap(.round)
cg.addPath(upperArrow)
cg.strokePath()
fillPolygon([CGPoint(x: 667, y: 860), CGPoint(x: 719, y: 825), CGPoint(x: 667, y: 790)], color: color(0.02, 0.82, 1))

let lowerArrow = CGMutablePath()
lowerArrow.move(to: CGPoint(x: 680, y: 535))
lowerArrow.addCurve(to: CGPoint(x: 344, y: 535), control1: CGPoint(x: 610, y: 458), control2: CGPoint(x: 410, y: 458))
cg.setStrokeColor(color(0.02, 0.36, 1).cgColor)
cg.setLineWidth(28)
cg.setLineCap(.round)
cg.addPath(lowerArrow)
cg.strokePath()
fillPolygon([CGPoint(x: 357, y: 570), CGPoint(x: 305, y: 535), CGPoint(x: 357, y: 500)], color: color(0.02, 0.36, 1))

centeredText("ISHA", y: 335, font: NSFont.systemFont(ofSize: 142, weight: .heavy), color: color(0.97, 0.99, 1), tracking: 5)
centeredText("CONVERTER", y: 265, font: NSFont.systemFont(ofSize: 61, weight: .bold), color: color(0.73, 0.86, 1), tracking: 5)
rounded(NSRect(x: 378, y: 132, width: 268, height: 83), radius: 42, fill: color(0.01, 0.34, 0.91), stroke: color(0.03, 0.75, 1), lineWidth: 3)
centeredText("iOS", y: 149, font: NSFont.systemFont(ofSize: 55, weight: .heavy), color: color(1, 1, 1))

NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode ISHA app icon as PNG")
}
try png.write(to: outputURL)
print("Created ISHA Converter iOS app icon at \(outputURL.path)")
