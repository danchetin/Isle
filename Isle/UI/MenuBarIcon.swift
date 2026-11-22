import AppKit

/// Menu bar glyph: the app icon's island (notch with flared ears) with the waveform and
/// dot knocked out of it. Drawn as a template image so macOS tints it for light/dark bars.
enum MenuBarIcon {
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 26, height: 16), flipped: true) { rect in
            guard let c = NSGraphicsContext.current?.cgContext else { return false }
            draw(in: c, size: rect.size)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Isle"
        return image
    }

    /// y grows downward (flipped canvas).
    static func draw(in c: CGContext, size: CGSize) {
        let top: CGFloat = 2, bottom: CGFloat = 14
        let x0: CGFloat = 3.5, x1 = size.width - 3.5
        let ear: CGFloat = 2.5, radius: CGFloat = 4.5

        let p = CGMutablePath()
        p.move(to: CGPoint(x: x0 - ear, y: top))
        p.addCurve(to: CGPoint(x: x0, y: top + ear * 1.1),
                   control1: CGPoint(x: x0 - ear * 0.35, y: top),
                   control2: CGPoint(x: x0, y: top + ear * 0.4))
        p.addArc(tangent1End: CGPoint(x: x0, y: bottom), tangent2End: CGPoint(x: x1, y: bottom), radius: radius)
        p.addArc(tangent1End: CGPoint(x: x1, y: bottom), tangent2End: CGPoint(x: x1, y: top), radius: radius)
        p.addLine(to: CGPoint(x: x1, y: top + ear * 1.1))
        p.addCurve(to: CGPoint(x: x1 + ear, y: top),
                   control1: CGPoint(x: x1, y: top + ear * 0.4),
                   control2: CGPoint(x: x1 + ear * 0.35, y: top))
        p.closeSubpath()
        c.setFillColor(NSColor.black.cgColor)
        c.addPath(p)
        c.fillPath()

        // Knock out the waveform (left) and the dot (right), centred on the lower row.
        c.setBlendMode(.clear)
        let mid: CGFloat = 8.6
        let barW: CGFloat = 1.4, gap: CGFloat = 1.1
        var x = x0 + 2.4
        for h: CGFloat in [2.6, 5, 6.4, 3.8] {
            c.addPath(CGPath(roundedRect: CGRect(x: x, y: mid - h / 2, width: barW, height: h),
                             cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil))
            x += barW + gap
        }
        c.fillPath()
        let d: CGFloat = 3.6
        c.fillEllipse(in: CGRect(x: x1 - 2.4 - d, y: mid - d / 2, width: d, height: d))
        c.setBlendMode(.normal)
    }
}
