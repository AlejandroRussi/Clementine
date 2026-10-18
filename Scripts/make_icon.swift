// Renders Clementine's app icon: a glossy clementine on a warm cream tile,
// circled by a faint segmented ring that echoes the conversion wheel.
//   swift Scripts/make_icon.swift Resources/AppIcon.png
import AppKit

let S: CGFloat = 1024
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png")
let space = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat(hex >> 16 & 255) / 255, CGFloat(hex >> 8 & 255) / 255,
                                            CGFloat(hex & 255) / 255, a])!
}
func gradient(_ colors: [CGColor], _ locs: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locs)!
}

// MARK: Tile (macOS icon grid: 824pt squircle inset 100pt, soft drop shadow)
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: c(0x5A2A00, 0.32))
ctx.addPath(tilePath); ctx.setFillColor(c(0xFFF1E0)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
// Warm cream → apricot wash, lit from the top left.
ctx.drawLinearGradient(gradient([c(0xFFF8EE), c(0xFFE3C4), c(0xFFC99A)], [0, 0.55, 1]),
                       start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
// Soft glow behind the fruit.
ctx.drawRadialGradient(gradient([c(0xFFFFFF, 0.75), c(0xFFFFFF, 0)], [0, 1]),
                       startCenter: CGPoint(x: 470, y: 560), startRadius: 0,
                       endCenter: CGPoint(x: 470, y: 560), endRadius: 430, options: [])
// Inner top highlight edge.
ctx.addPath(tilePath); ctx.setStrokeColor(c(0xFFFFFF, 0.7)); ctx.setLineWidth(6); ctx.strokePath()
ctx.restoreGState()

let center = CGPoint(x: 512, y: 488)

// MARK: Wheel ring — 10 rounded segments, one highlighted
ctx.saveGState()
let ringR: CGFloat = 330
ctx.setLineCap(.round)
for i in 0..<10 {
    let start = CGFloat.pi / 2 - CGFloat(i) * 2 * .pi / 10 - 0.2
    let end = start - 2 * .pi / 10 + 0.4
    ctx.addArc(center: center, radius: ringR, startAngle: start, endAngle: end, clockwise: true)
    ctx.setStrokeColor(i == 1 ? c(0xFF7A1A, 0.85) : c(0xE07A3A, 0.22))
    ctx.setLineWidth(i == 1 ? 18 : 12)
    ctx.strokePath()
}
ctx.restoreGState()

// MARK: Clementine
let fruitR: CGFloat = 228
let fruit = CGRect(x: center.x - fruitR, y: center.y - fruitR * 0.96, width: fruitR * 2, height: fruitR * 1.92)

// Contact shadow
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -26), blur: 46, color: c(0x8A3200, 0.45))
ctx.addEllipse(in: fruit); ctx.setFillColor(c(0xF06A10)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addEllipse(in: fruit); ctx.clip()
// Body: bright peel lit from top-left, deepening to a burnt rim.
ctx.drawRadialGradient(gradient([c(0xFFC067), c(0xFF9A2E), c(0xF5700F), c(0xD9520A)], [0, 0.35, 0.75, 1]),
                       startCenter: CGPoint(x: center.x - 80, y: center.y + 95), startRadius: 0,
                       endCenter: CGPoint(x: center.x + 10, y: center.y - 10), endRadius: fruitR * 1.08, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
// Peel dimples: tiny pores, denser toward the rim.
var seed: UInt64 = 0xC1E3E7
func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(1 << 31) }
for _ in 0..<900 {
    let a = rnd() * 2 * .pi, r = sqrt(rnd()) * fruitR
    let p = CGPoint(x: center.x + cos(a) * r, y: center.y + sin(a) * r * 0.96)
    let s = 2.2 + rnd() * 2.6
    ctx.setFillColor(c(0xB84506, 0.10 + 0.14 * r / fruitR))
    ctx.fillEllipse(in: CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s))
}
// Soft bounce light from the tile along the lower right.
ctx.drawRadialGradient(gradient([c(0xFFD9A8, 0.35), c(0xFFD9A8, 0)], [0, 1]),
                       startCenter: CGPoint(x: center.x + 150, y: center.y - 190), startRadius: 0,
                       endCenter: CGPoint(x: center.x + 150, y: center.y - 190), endRadius: 160, options: [])
ctx.restoreGState()

// Specular highlight
ctx.saveGState()
ctx.translateBy(x: center.x - 92, y: center.y + 108)
ctx.rotate(by: 0.55)
let hl = CGRect(x: -62, y: -34, width: 124, height: 68)
ctx.addEllipse(in: hl); ctx.clip()
ctx.scaleBy(x: 1, y: 0.55)
ctx.drawRadialGradient(gradient([c(0xFFFFFF, 0.8), c(0xFFFFFF, 0.35), c(0xFFFFFF, 0)], [0, 0.45, 1]),
                       startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 64, options: [.drawsBeforeStartLocation])
ctx.restoreGState()

// Navel dimple at the top
let top = CGPoint(x: center.x + 6, y: fruit.maxY - 16)
ctx.setFillColor(c(0xC0560B, 0.55))
ctx.fillEllipse(in: CGRect(x: top.x - 13, y: top.y - 7, width: 26, height: 14))

// Stem
ctx.saveGState()
ctx.setLineCap(.round)
ctx.setStrokeColor(c(0x5B3A1E)); ctx.setLineWidth(14)
ctx.move(to: CGPoint(x: top.x, y: top.y)); ctx.addQuadCurve(to: CGPoint(x: top.x + 6, y: top.y + 46), control: CGPoint(x: top.x - 8, y: top.y + 22))
ctx.strokePath()
ctx.restoreGState()

// Leaf
ctx.saveGState()
let base = CGPoint(x: top.x + 8, y: top.y + 40)
let tip = CGPoint(x: base.x + 190, y: base.y + 92)
let leaf = CGMutablePath()
leaf.move(to: base)
leaf.addCurve(to: tip, control1: CGPoint(x: base.x + 40, y: base.y + 120), control2: CGPoint(x: tip.x - 70, y: tip.y + 40))
leaf.addCurve(to: base, control1: CGPoint(x: tip.x - 40, y: tip.y - 70), control2: CGPoint(x: base.x + 80, y: base.y - 30))
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 16, color: c(0x1F4D14, 0.35))
ctx.addPath(leaf); ctx.setFillColor(c(0x3E8E2E)); ctx.fillPath()
ctx.setShadow(offset: .zero, blur: 0)
ctx.addPath(leaf); ctx.clip()
ctx.drawLinearGradient(gradient([c(0x8BD35A), c(0x4CA83A), c(0x2D7A24)], [0, 0.5, 1]),
                       start: CGPoint(x: base.x + 60, y: base.y + 110), end: CGPoint(x: base.x + 120, y: base.y), options: [])
// Midrib
ctx.setStrokeColor(c(0xD8F5B8, 0.7)); ctx.setLineWidth(5); ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: base.x + 10, y: base.y + 6))
ctx.addQuadCurve(to: CGPoint(x: tip.x - 18, y: tip.y - 6), control: CGPoint(x: base.x + 100, y: base.y + 70))
ctx.strokePath()
ctx.restoreGState()

// MARK: Write
let img = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(out as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
print("Wrote \(out.path)")
