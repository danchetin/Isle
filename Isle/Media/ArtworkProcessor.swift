import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

/// Album art plus everything derived from it once per track:
/// a blurred backdrop, the foreground subject cut out (for Clock Depth) and an accent color.
struct ProcessedArtwork: Equatable {
    let url: URL
    let image: NSImage
    let blurred: NSImage
    let subject: NSImage?
    let accent: NSColor

    static func == (a: ProcessedArtwork, b: ProcessedArtwork) -> Bool {
        a.url == b.url && (a.subject == nil) == (b.subject == nil)
    }
}

enum ArtworkProcessor {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func process(url: URL, screenAspect: CGFloat) async -> ProcessedArtwork? {
        guard let (data, response) = try? await URLSession.shared.data(from: url) else { return nil }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { return nil }
        return await Task.detached(priority: .userInitiated) {
            make(data: data, url: url, screenAspect: screenAspect)
        }.value
    }

    static func make(data: Data, url: URL, screenAspect: CGFloat) -> ProcessedArtwork? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return make(cgImage: cg, url: url, screenAspect: screenAspect)
    }

    static func make(cgImage cg: CGImage, url: URL, screenAspect: CGFloat) -> ProcessedArtwork? {
        let ci = CIImage(cgImage: cg)
        let extent = ci.extent
        let blurredCI = ci.clampedToExtent()
            .applyingGaussianBlur(sigma: Double(extent.width) * 0.05)
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.3,
                kCIInputBrightnessKey: -0.04,
            ])
            .cropped(to: extent)
        guard let blurredCG = context.createCGImage(blurredCI, from: extent) else { return nil }

        let size = NSSize(width: cg.width, height: cg.height)
        return ProcessedArtwork(
            url: url,
            image: NSImage(cgImage: cg, size: size),
            blurred: NSImage(cgImage: blurredCG, size: size),
            subject: subjectCutout(cg, screenAspect: screenAspect).map { NSImage(cgImage: $0, size: size) },
            accent: accentColor(cg)
        )
    }

    // MARK: - Subject (Clock Depth)

    /// Where the large lock-screen clock sits, as fractions of the screen (top-left origin).
    static let clockRegion = CGRect(x: 0.3, y: 0.07, width: 0.4, height: 0.2)

    /// Cuts the foreground subject out of the cover on-device.
    /// Returns nil when there is no clear subject, or when it would hide too much
    /// of the clock: depth should overlap the clock, not swallow it.
    static func subjectCutout(_ cg: CGImage, screenAspect: CGFloat) -> CGImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else { return nil }

        guard let mask = try? observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler) else { return nil }
        let maskImage = CIImage(cvPixelBuffer: mask)
        let total = coverage(of: maskImage, in: maskImage.extent)
        guard total > 0.04 else { return nil }
        let clockRect = imageRect(forScreenFraction: clockRegion, imageExtent: maskImage.extent, screenAspect: screenAspect)
        let overClock = coverage(of: maskImage, in: clockRect)
        let forced = ProcessInfo.processInfo.environment["ISLE_FORCE_DEPTH"] == "1" // debug: skip the guard
        guard overClock < 0.35 || forced else { return nil }

        guard let buffer = try? observation.generateMaskedImage(
            ofInstances: observation.allInstances, from: handler, croppedToInstancesExtent: false
        ) else { return nil }
        let masked = CIImage(cvPixelBuffer: buffer)
        return context.createCGImage(masked, from: masked.extent)
    }

    /// Maps a screen-fraction rect (top-left origin) to image pixels (Core Image, bottom-left
    /// origin), mirroring `.scaledToFill()` + center crop used by the lock screen.
    static func imageRect(forScreenFraction r: CGRect, imageExtent e: CGRect, screenAspect: CGFloat) -> CGRect {
        let imageAspect = e.width / max(e.height, 1)
        var visible = CGRect(x: 0, y: 0, width: 1, height: 1) // fraction of the image that is on screen
        if screenAspect > imageAspect {
            visible.size.height = imageAspect / screenAspect
            visible.origin.y = (1 - visible.height) / 2
        } else {
            visible.size.width = screenAspect / imageAspect
            visible.origin.x = (1 - visible.width) / 2
        }
        let fx = visible.minX + r.minX * visible.width
        let fyTop = visible.minY + r.minY * visible.height
        let fw = r.width * visible.width
        let fh = r.height * visible.height
        return CGRect(
            x: e.minX + fx * e.width,
            y: e.minY + (1 - fyTop - fh) * e.height,
            width: fw * e.width,
            height: fh * e.height
        )
    }

    private static func coverage(of ci: CIImage, in rect: CGRect) -> Double {
        let filter = CIFilter.areaAverage()
        filter.inputImage = ci
        filter.extent = rect
        guard let out = filter.outputImage else { return 0 }
        var px = [Float](repeating: 0, count: 4)
        context.render(out, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        return Double(px[0])
    }

    // MARK: - Accent

    /// Most vivid color of a 12x12 thumbnail, brightened so it reads on black.
    static func accentColor(_ cg: CGImage) -> NSColor {
        let side = 12
        var px = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(
            data: &px, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return .systemPink }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))

        var best: (score: CGFloat, color: NSColor)?
        for i in stride(from: 0, to: px.count, by: 4) {
            let c = NSColor(srgbRed: CGFloat(px[i]) / 255, green: CGFloat(px[i + 1]) / 255, blue: CGFloat(px[i + 2]) / 255, alpha: 1)
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            guard b > 0.2 else { continue }
            let score = s * 0.75 + b * 0.25
            if best == nil || score > best!.score { best = (score, c) }
        }
        guard let chosen = best?.color else { return .systemPink }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        chosen.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        if s < 0.12 { return NSColor(white: 0.92, alpha: 1) }
        return NSColor(hue: h, saturation: min(max(s, 0.45), 0.85), brightness: max(b, 0.88), alpha: 1)
    }
}
