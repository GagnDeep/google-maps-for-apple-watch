import AppKit
import CoreGraphics

let size = 1024.0
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
func c(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor { CGColor(colorSpace: cs, components: [r, g, b, a])! }

// Background: map-green to deep teal gradient.
let bg = CGGradient(colorsSpace: cs, colors: [c(0.16, 0.62, 0.38), c(0.05, 0.36, 0.30)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])

// Map blocks (subtle).
ctx.setFillColor(c(1, 1, 1, 0.07))
for (x, y, w, h) in [(80.0, 640.0, 260.0, 220.0), (660.0, 700.0, 260.0, 200.0), (120.0, 140.0, 220.0, 260.0), (700.0, 120.0, 220.0, 300.0)] {
    ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: 40, cornerHeight: 40, transform: nil))
}
ctx.fillPath()

// Road: wide white curve with blue route on top.
let road = CGMutablePath()
road.move(to: CGPoint(x: -40, y: 300))
road.addCurve(to: CGPoint(x: 1064, y: 560), control1: CGPoint(x: 380, y: 120), control2: CGPoint(x: 620, y: 760))
ctx.addPath(road); ctx.setStrokeColor(c(0.97, 0.97, 0.95)); ctx.setLineWidth(120); ctx.setLineCap(.round); ctx.strokePath()
ctx.addPath(road); ctx.setStrokeColor(c(0.10, 0.45, 0.91)); ctx.setLineWidth(46); ctx.strokePath()

// Pin.
let tip = CGPoint(x: 512, y: 330), r = 190.0, cy = 640.0
let pin = CGMutablePath()
pin.move(to: tip)
pin.addCurve(to: CGPoint(x: 512 - r, y: cy), control1: CGPoint(x: 512 - r * 0.3, y: tip.y + 90), control2: CGPoint(x: 512 - r, y: cy - r * 0.75))
pin.addArc(center: CGPoint(x: 512, y: cy), radius: r, startAngle: .pi, endAngle: 0, clockwise: true)
pin.addCurve(to: tip, control1: CGPoint(x: 512 + r, y: cy - r * 0.75), control2: CGPoint(x: 512 + r * 0.3, y: tip.y + 90))
pin.closeSubpath()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: c(0, 0, 0, 0.35))
ctx.addPath(pin); ctx.setFillColor(c(0.92, 0.26, 0.21)); ctx.fillPath()
ctx.restoreGState()
// Pin highlight.
ctx.saveGState(); ctx.addPath(pin); ctx.clip()
let hl = CGGradient(colorsSpace: cs, colors: [c(1, 1, 1, 0.22), c(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(hl, start: CGPoint(x: 330, y: 830), end: CGPoint(x: 600, y: 420), options: [])
ctx.restoreGState()
ctx.setFillColor(c(0.55, 0.07, 0.06)); ctx.fillEllipse(in: CGRect(x: 512 - 72, y: cy - 72, width: 144, height: 144))
ctx.setFillColor(c(1, 1, 1)); ctx.fillEllipse(in: CGRect(x: 512 - 52, y: cy - 52, width: 104, height: 104))

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
