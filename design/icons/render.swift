// Renders Isle app icon concepts. `swift render.swift <outDir>`
import AppKit
import CoreGraphics

let S: CGFloat = 1024
func rgb(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((h >> 16) & 255) / 255, green: CGFloat((h >> 8) & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: a)
}
func gradient(_ c: [CGColor], _ l: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: c as CFArray, locations: l)!
}
func capsule(_ r: CGRect) -> CGPath { CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil) }

/// Waveform bars centred in rect, heights in 0…1.
func bars(_ ctx: CGContext, in r: CGRect, heights: [CGFloat], colors: [CGColor]) {
    let n = CGFloat(heights.count)
    let w = r.width / (n * 1.7)
    let gap = (r.width - w * n) / (n - 1)
    ctx.saveGState()
    let path = CGMutablePath()
    for (i, h) in heights.enumerated() {
        let bh = max(w, r.height * h)
        path.addPath(capsule(CGRect(x: r.minX + CGFloat(i) * (w + gap), y: r.midY - bh / 2, width: w, height: bh)))
    }
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(gradient(colors), start: CGPoint(x: r.minX, y: r.midY), end: CGPoint(x: r.maxX, y: r.midY), options: [])
    ctx.restoreGState()
}

/// Concave-eared notch hanging from the top edge (same shape as Isle's island).
func notchPath(_ r: CGRect, ear: CGFloat, bottom b: CGFloat) -> CGPath {
    // CG coordinates: y up, so the "top" edge is maxY.
    let p = CGMutablePath()
    p.move(to: CGPoint(x: r.minX, y: r.maxY))
    p.addQuadCurve(to: CGPoint(x: r.minX + ear, y: r.maxY - ear), control: CGPoint(x: r.minX + ear, y: r.maxY))
    p.addLine(to: CGPoint(x: r.minX + ear, y: r.minY + b))
    p.addQuadCurve(to: CGPoint(x: r.minX + ear + b, y: r.minY), control: CGPoint(x: r.minX + ear, y: r.minY))
    p.addLine(to: CGPoint(x: r.maxX - ear - b, y: r.minY))
    p.addQuadCurve(to: CGPoint(x: r.maxX - ear, y: r.minY + b), control: CGPoint(x: r.maxX - ear, y: r.minY))
    p.addLine(to: CGPoint(x: r.maxX - ear, y: r.maxY - ear))
    p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY), control: CGPoint(x: r.maxX - ear, y: r.maxY))
    p.closeSubpath()
    return p
}

let wave: [CGFloat] = [0.35, 0.75, 1.0, 0.55, 0.85, 0.4]
let warm = [rgb(0xFF9A3C), rgb(0xFF4F8B)]

// MARK: - Concepts (drawn full-bleed 1024×1024, y up)

func nightIsland(_ c: CGContext) {
    c.drawLinearGradient(gradient([rgb(0x0B0B2A), rgb(0x2A1658), rgb(0x5B2A86)], [0, 0.55, 1]),
                         start: CGPoint(x: 0, y: S), end: CGPoint(x: S, y: 0), options: [])
    // soft glow behind the island
    c.drawRadialGradient(gradient([rgb(0xFF5FA2, 0.45), rgb(0xFF5FA2, 0)]), startCenter: CGPoint(x: S / 2, y: S * 0.52), startRadius: 0,
                         endCenter: CGPoint(x: S / 2, y: S * 0.52), endRadius: S * 0.48, options: [])
    let island = CGRect(x: S * 0.17, y: S * 0.42, width: S * 0.66, height: S * 0.2)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -18), blur: 50, color: rgb(0x000000, 0.6))
    c.addPath(capsule(island)); c.setFillColor(rgb(0x000000)); c.fillPath()
    c.restoreGState()
    // album art dot + waveform inside
    let art = CGRect(x: island.minX + island.height * 0.2, y: island.minY + island.height * 0.2, width: island.height * 0.6, height: island.height * 0.6)
    c.saveGState()
    c.addPath(CGPath(roundedRect: art, cornerWidth: art.width * 0.28, cornerHeight: art.width * 0.28, transform: nil)); c.clip()
    c.drawLinearGradient(gradient(warm), start: CGPoint(x: art.minX, y: art.maxY), end: CGPoint(x: art.maxX, y: art.minY), options: [])
    c.restoreGState()
    bars(c, in: CGRect(x: island.maxX - island.height * 1.55, y: island.minY + island.height * 0.25, width: island.height * 1.2, height: island.height * 0.5),
         heights: wave, colors: warm)
}

func glassIsland(_ c: CGContext) {
    c.drawLinearGradient(gradient([rgb(0x8EC5FF), rgb(0xB9A7FF), rgb(0xFFC1E3)], [0, 0.55, 1]),
                         start: CGPoint(x: 0, y: S), end: CGPoint(x: S, y: 0), options: [])
    // big frosted glass slab
    let slab = CGRect(x: S * 0.12, y: S * 0.3, width: S * 0.76, height: S * 0.4)
    let slabPath = CGPath(roundedRect: slab, cornerWidth: slab.height * 0.42, cornerHeight: slab.height * 0.42, transform: nil)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -24), blur: 60, color: rgb(0x3B2A7A, 0.35))
    c.addPath(slabPath); c.setFillColor(rgb(0xFFFFFF, 0.28)); c.fillPath()
    c.restoreGState()
    c.saveGState()
    c.addPath(slabPath); c.clip()
    c.drawLinearGradient(gradient([rgb(0xFFFFFF, 0.55), rgb(0xFFFFFF, 0.08)]), start: CGPoint(x: 0, y: slab.maxY), end: CGPoint(x: 0, y: slab.midY), options: [])
    c.restoreGState()
    c.addPath(slabPath); c.setStrokeColor(rgb(0xFFFFFF, 0.75)); c.setLineWidth(5); c.strokePath()
    // black island inside the glass
    let island = CGRect(x: slab.midX - S * 0.22, y: slab.midY - S * 0.065, width: S * 0.44, height: S * 0.13)
    c.addPath(capsule(island)); c.setFillColor(rgb(0x0A0A12)); c.fillPath()
    bars(c, in: CGRect(x: island.midX - island.height * 0.95, y: island.minY + island.height * 0.27, width: island.height * 1.9, height: island.height * 0.46),
         heights: wave + [0.6, 0.3], colors: [rgb(0x7FD3FF), rgb(0xC08BFF)])
}

func sunsetNotch(_ c: CGContext) {
    c.drawLinearGradient(gradient([rgb(0xFFB25B), rgb(0xFF5E7E), rgb(0x7B3FE4)], [0, 0.5, 1]),
                         start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: S), options: [])
    c.drawRadialGradient(gradient([rgb(0xFFE7A8, 0.9), rgb(0xFFE7A8, 0)]), startCenter: CGPoint(x: S / 2, y: S * 0.22), startRadius: 0,
                         endCenter: CGPoint(x: S / 2, y: S * 0.22), endRadius: S * 0.42, options: [])
    let notch = CGRect(x: S * 0.16, y: S * 0.5, width: S * 0.68, height: S * 0.5)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -20), blur: 60, color: rgb(0x2A0A3A, 0.55))
    c.addPath(notchPath(notch, ear: S * 0.05, bottom: S * 0.13)); c.setFillColor(rgb(0x050507)); c.fillPath()
    c.restoreGState()
    bars(c, in: CGRect(x: S * 0.34, y: S * 0.6, width: S * 0.32, height: S * 0.14), heights: wave, colors: [rgb(0xFFD36E), rgb(0xFF6FA0)])
}

func mono(_ c: CGContext) {
    c.drawLinearGradient(gradient([rgb(0x3A3A40), rgb(0x16161A), rgb(0x0B0B0D)], [0, 0.45, 1]),
                         start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0), options: [])
    // top sheen
    c.drawRadialGradient(gradient([rgb(0xFFFFFF, 0.12), rgb(0xFFFFFF, 0)]), startCenter: CGPoint(x: S / 2, y: S * 1.05), startRadius: 0,
                         endCenter: CGPoint(x: S / 2, y: S * 1.05), endRadius: S * 0.7, options: [])
    let island = CGRect(x: S * 0.14, y: S * 0.4, width: S * 0.72, height: S * 0.2)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -16), blur: 46, color: rgb(0x000000, 0.7))
    c.addPath(capsule(island)); c.setFillColor(rgb(0x000000)); c.fillPath()
    c.restoreGState()
    c.addPath(capsule(island.insetBy(dx: 2, dy: 2))); c.setStrokeColor(rgb(0xFFFFFF, 0.16)); c.setLineWidth(4); c.strokePath()
    bars(c, in: CGRect(x: island.minX + island.height * 0.45, y: island.minY + island.height * 0.28, width: island.height * 1.5, height: island.height * 0.44),
         heights: [0.45, 0.85, 1.0, 0.6, 0.8], colors: [rgb(0xFFFFFF, 0.95), rgb(0xFFFFFF, 0.7)])
    // one warm accent: a glowing dot like a live activity
    let d = island.height * 0.36
    let dot = CGRect(x: island.maxX - island.height * 0.5 - d / 2, y: island.midY - d / 2, width: d, height: d)
    c.saveGState()
    c.setShadow(offset: .zero, blur: 46, color: rgb(0xFF7A3D, 1))
    c.addEllipse(in: dot); c.setFillColor(rgb(0xFF7A3D)); c.fillPath()
    c.restoreGState()
}

// MARK: - Output

func render(_ size: CGFloat, mac: Bool, _ draw: (CGContext) -> Void) -> Data {
    let px = Int(size)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = size / S
    ctx.scaleBy(x: scale, y: scale)
    if mac {
        // Apple macOS grid: 824×824 body centred in 1024, radius ≈ 185, soft shadow.
        let body = CGRect(x: 100, y: 100 + 6, width: 824, height: 824)
        let path = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: rgb(0x000000, 0.35))
        ctx.addPath(path); ctx.setFillColor(rgb(0x000000)); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        ctx.translateBy(x: body.minX, y: body.minY)
        ctx.scaleBy(x: body.width / S, y: body.height / S)
        draw(ctx)
        ctx.restoreGState()
    } else {
        draw(ctx)
    }
    let image = ctx.makeImage()!
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let concepts: [(String, (CGContext) -> Void)] = [
    ("1-night-island", nightIsland), ("2-glass", glassIsland), ("3-sunset-notch", sunsetNotch), ("4-mono", mono),
]
for (name, draw) in concepts {
    try! render(1024, mac: true, draw).write(to: out.appendingPathComponent("\(name)-mac.png"))
    try! render(1024, mac: false, draw).write(to: out.appendingPathComponent("\(name)-ios.png"))
}
print("ok")
