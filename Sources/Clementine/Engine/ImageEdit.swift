import AppKit
import CoreImage
import CoreText
import ImageIO
import UniformTypeIdentifiers
import Vision

// MARK: - Model types

struct RGBA: Codable, Hashable {
    var r, g, b, a: Double
    var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

    init(r: Double, g: Double, b: Double, a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? .black
        self.init(r: c.redComponent, g: c.greenComponent, b: c.blueComponent, a: c.alphaComponent)
    }
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }

    static let red = RGBA(r: 1, g: 0.23, b: 0.19)
    static let yellow = RGBA(r: 1, g: 0.84, b: 0.04)
    static let white = RGBA(r: 1, g: 1, b: 1)
    static let black = RGBA(r: 0, g: 0, b: 0)
}

/// A mark drawn over an image. Points are normalized (0…1) with a top-left origin;
/// sizes are fractions of the image's shorter side so marks scale with resolution.
struct Annotation: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case arrow, draw, highlight, rectangle, text, magnifier
        var id: String { rawValue }
        var label: String { rawValue == "draw" ? "Draw" : rawValue.capitalized }
        var symbol: String {
            switch self {
            case .arrow: "arrow.up.right"
            case .draw: "scribble"
            case .highlight: "highlighter"
            case .rectangle: "rectangle"
            case .text: "textformat"
            case .magnifier: "plus.magnifyingglass"
            }
        }
    }

    var id = UUID()
    var kind: Kind
    /// arrow: [tail, head]; draw: path; highlight/rectangle: two corners; text/magnifier: [anchor]
    var points: [CGPoint]
    var color: RGBA = .red
    var width = 0.006
    var text = ""
    var fontSize = 0.05
    var zoom = 2.0
    var radius = 0.12

    init(kind: Kind, points: [CGPoint], color: RGBA = .red, width: Double = 0.006) {
        self.kind = kind; self.points = points; self.color = color; self.width = width
    }

    /// Only `kind` and `points` are required, so hand-written JSON stays short.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        points = try c.decode([CGPoint].self, forKey: .points)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        color = try c.decodeIfPresent(RGBA.self, forKey: .color) ?? (kind == .magnifier ? .white : .red)
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 0.006
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? 0.05
        zoom = try c.decodeIfPresent(Double.self, forKey: .zoom) ?? 2
        radius = try c.decodeIfPresent(Double.self, forKey: .radius) ?? 0.12
        guard !points.isEmpty else { throw ToolError("An annotation needs at least one point.") }
    }

    func rect(in size: CGSize) -> CGRect {
        let ps = points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
        let unit = min(size.width, size.height)
        switch kind {
        case .text:
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let h = fontSize * unit * 1.25 * Double(max(lines.count, 1))
            let w = Double(lines.map(\.count).max() ?? 1) * fontSize * unit * 0.6
            return CGRect(x: ps[0].x, y: ps[0].y, width: w, height: h)
        case .magnifier:
            let r = radius * unit
            return CGRect(x: ps[0].x - r, y: ps[0].y - r, width: 2 * r, height: 2 * r)
        default:
            let xs = ps.map(\.x), ys = ps.map(\.y)
            return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        }
    }
}

enum RedactionStyle: String, CaseIterable, Identifiable {
    case blur, pixelate, solid
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum FrameRatio: String, CaseIterable, Identifiable {
    case auto, square, classic, wide, portrait, story
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: "Auto"
        case .square: "1:1"
        case .classic: "4:3"
        case .wide: "16:9"
        case .portrait: "4:5"
        case .story: "9:16"
        }
    }
    var value: CGFloat? {
        switch self {
        case .auto: nil
        case .square: 1
        case .classic: 4 / 3
        case .wide: 16 / 9
        case .portrait: 4 / 5
        case .story: 9 / 16
        }
    }
}

enum FrameBackground: Hashable {
    case gradient(Int)
    case solid(RGBA)
    case blurred
    case image(URL)

    static let gradients: [(RGBA, RGBA)] = [
        (RGBA(r: 1, g: 0.62, b: 0.2), RGBA(r: 0.98, g: 0.3, b: 0.45)),     // tangerine → pink
        (RGBA(r: 0.33, g: 0.47, b: 1), RGBA(r: 0.64, g: 0.3, b: 0.95)),    // blue → violet
        (RGBA(r: 0.1, g: 0.75, b: 0.7), RGBA(r: 0.45, g: 0.9, b: 0.4)),    // teal → green
        (RGBA(r: 0.98, g: 0.82, b: 0.4), RGBA(r: 0.98, g: 0.55, b: 0.35)), // sunrise
        (RGBA(r: 0.93, g: 0.94, b: 0.96), RGBA(r: 0.8, g: 0.83, b: 0.88)), // silver
        (RGBA(r: 0.1, g: 0.12, b: 0.2), RGBA(r: 0.28, g: 0.18, b: 0.42)),  // night
    ]
}

struct FrameOptions: Hashable {
    var background: FrameBackground = .gradient(0)
    var padding = 0.08          // fraction of the image's longer side
    var cornerRadius = 0.025    // fraction of the image's shorter side
    var shadow = true
    var ratio: FrameRatio = .auto
    var liftSubject = false
}

enum CollageStyle: String, CaseIterable, Identifiable {
    case fill, fit
    var id: String { rawValue }
    var label: String { self == .fill ? "Fill cells (crop edges)" : "Fit whole images" }
}

struct CollageOptions: Hashable {
    var columns = 0             // 0 = automatic
    var style: CollageStyle = .fill
    var spacing = 16.0          // pixels at output width
    var cellAspect = 1.0        // width / height
    var background: RGBA = .white
    var width = 2400
}

// MARK: - Engine

enum ImageEdit {
    static let maxCanvas = 8192

    // MARK: Drawing helpers (contexts use a top-left origin)

    static func context(width: Int, height: Int) throws -> CGContext {
        guard width > 0, height > 0, width <= maxCanvas * 2, height <= maxCanvas * 2,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ToolError("Could not create an image canvas of \(width)×\(height).")
        }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        return ctx
    }

    static func drawImage(_ img: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    static func aspectFill(_ size: CGSize, in box: CGRect) -> CGRect {
        let s = max(box.width / size.width, box.height / size.height)
        return CGRect(x: box.midX - size.width * s / 2, y: box.midY - size.height * s / 2, width: size.width * s, height: size.height * s)
    }

    static func aspectFit(_ size: CGSize, in box: CGRect) -> CGRect {
        let s = min(box.width / size.width, box.height / size.height)
        return CGRect(x: box.midX - size.width * s / 2, y: box.midY - size.height * s / 2, width: size.width * s, height: size.height * s)
    }

    static func size(_ img: CGImage) -> CGSize { CGSize(width: img.width, height: img.height) }

    /// Decodes an image upright, optionally downscaled for previews.
    static func load(_ url: URL, maxDimension: CGFloat? = nil) throws -> CGImage {
        let src = try ImageTools.source(url)
        let full = ImageTools.pixelSize(url).map { max($0.width, $0.height) } ?? 8192
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: min(maxDimension ?? full, CGFloat(maxCanvas))]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw ToolError("Could not read the image \(url.lastPathComponent).")
        }
        return img
    }

    /// Saves beside `source` in its own format when possible (PNG when transparency matters).
    static func write(_ img: CGImage, beside source: URL, suffix: String, forcePNG: Bool = false) throws -> URL {
        let ext = source.pathExtension.lowercased()
        let keep = ["jpg", "jpeg", "png", "heic", "tif", "tiff"].contains(ext) && !forcePNG
        let type: UTType = keep ? (UTType(filenameExtension: ext) ?? .png) : .png
        let dest = Output.beside(source, ext: keep ? ext : "png", suffix: suffix)
        guard let out = CGImageDestinationCreateWithURL(dest as CFURL, type.identifier as CFString, 1, nil) else {
            throw ToolError("Could not save the edited image.")
        }
        CGImageDestinationAddImage(out, img, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(out) else { throw ToolError("Could not save the edited image.") }
        return dest
    }

    // MARK: Annotations

    /// Draws marks into a top-left-origin context covering `size`. `base` feeds the magnifier.
    static func drawAnnotations(_ marks: [Annotation], in ctx: CGContext, size: CGSize, base: CGImage?) {
        let unit = min(size.width, size.height)
        let p = { (pt: CGPoint) in CGPoint(x: pt.x * size.width, y: pt.y * size.height) }
        for m in marks {
            ctx.saveGState()
            let lw = max(1, m.width * unit)
            ctx.setLineWidth(lw)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setStrokeColor(m.color.cg)
            ctx.setFillColor(m.color.cg)
            switch m.kind {
            case .arrow where m.points.count >= 2:
                let tail = p(m.points[0]), head = p(m.points[1])
                let angle: CGFloat = atan2(head.y - tail.y, head.x - tail.x)
                let len: CGFloat = min(lw * 4.5, hypot(head.x - tail.x, head.y - tail.y) * 0.6)
                let base = CGPoint(x: head.x - cos(angle) * len * 0.8, y: head.y - sin(angle) * len * 0.8)
                ctx.move(to: tail); ctx.addLine(to: base); ctx.strokePath()
                ctx.move(to: head)
                ctx.addLine(to: CGPoint(x: head.x - cos(angle - .pi / 6) * len, y: head.y - sin(angle - .pi / 6) * len))
                ctx.addLine(to: CGPoint(x: head.x - cos(angle + .pi / 6) * len, y: head.y - sin(angle + .pi / 6) * len))
                ctx.closePath(); ctx.fillPath()
            case .draw where m.points.count >= 2:
                ctx.addLines(between: m.points.map(p)); ctx.strokePath()
            case .highlight:
                ctx.setBlendMode(.multiply)
                ctx.setFillColor(m.color.cg.copy(alpha: 0.4)!)
                ctx.fill(m.rect(in: size))
            case .rectangle:
                ctx.stroke(m.rect(in: size))
            case .text:
                drawText(m, at: p(m.points[0]), unit: unit, ctx: ctx)
            case .magnifier:
                guard let base else { break }
                let c = p(m.points[0]), r = m.radius * unit
                let circle = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
                ctx.setShadow(offset: .zero, blur: r * 0.15, color: CGColor(gray: 0, alpha: 0.5))
                ctx.setFillColor(.white); ctx.fillEllipse(in: circle.insetBy(dx: -lw, dy: -lw))
                ctx.setShadow(offset: .zero, blur: 0)
                ctx.saveGState()
                ctx.addEllipse(in: circle); ctx.clip()
                let z = m.zoom
                drawImage(base, in: CGRect(x: c.x - c.x * z, y: c.y - c.y * z, width: size.width * z, height: size.height * z), ctx: ctx)
                ctx.restoreGState()
                ctx.setStrokeColor(m.color.cg); ctx.strokeEllipse(in: circle)
            default: break
            }
            ctx.restoreGState()
        }
    }

    private static func drawText(_ m: Annotation, at origin: CGPoint, unit: CGFloat, ctx: CGContext) {
        let size = m.fontSize * unit
        let font = NSFont.systemFont(ofSize: size, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: m.color.nsColor,
                                                    .strokeColor: NSColor.black.withAlphaComponent(0.35), .strokeWidth: -2]
        let lineHeight = size * 1.25
        for (i, line) in m.text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: String(line), attributes: attrs))
            ctx.saveGState()
            ctx.translateBy(x: origin.x, y: origin.y + lineHeight * CGFloat(i + 1) - (lineHeight - size) / 2 - size * 0.2)
            ctx.scaleBy(x: 1, y: -1)
            ctx.textMatrix = .identity
            ctx.textPosition = .zero
            CTLineDraw(ctLine, ctx)
            ctx.restoreGState()
        }
    }

    static func annotate(_ base: CGImage, with marks: [Annotation]) throws -> CGImage {
        let ctx = try context(width: base.width, height: base.height)
        let s = size(base)
        drawImage(base, in: CGRect(origin: .zero, size: s), ctx: ctx)
        drawAnnotations(marks, in: ctx, size: s, base: base)
        guard let out = ctx.makeImage() else { throw ToolError("Could not prepare the annotated image.") }
        return out
    }

    // MARK: Redaction

    /// The whole image blurred or pixelated; regions of it are composited over the original.
    static func obscured(_ base: CGImage, style: RedactionStyle) -> CGImage? {
        guard style != .solid else { return nil }
        let unit = Double(min(base.width, base.height))
        let ci = CIImage(cgImage: base)
        let processed: CIImage = style == .blur
            ? ci.clampedToExtent().applyingGaussianBlur(sigma: max(4, unit * 0.025)).cropped(to: ci.extent)
            : ci.applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: max(6, unit * 0.03),
                                                            kCIInputCenterKey: CIVector(x: 0, y: 0)]).cropped(to: ci.extent)
        return CIContext().createCGImage(processed, from: ci.extent)
    }

    static func drawRedactions(_ rects: [CGRect], style: RedactionStyle, obscured: CGImage?, in ctx: CGContext, size: CGSize) {
        for r in rects {
            let px = CGRect(x: r.minX * size.width, y: r.minY * size.height, width: r.width * size.width, height: r.height * size.height)
            if style == .solid || obscured == nil {
                ctx.setFillColor(.black); ctx.fill(px)
            } else {
                ctx.saveGState(); ctx.clip(to: px)
                drawImage(obscured!, in: CGRect(origin: .zero, size: size), ctx: ctx)
                ctx.restoreGState()
            }
        }
    }

    static func redact(_ base: CGImage, rects: [CGRect], style: RedactionStyle) throws -> CGImage {
        guard !rects.isEmpty else { throw ToolError("Draw a rectangle over the area to hide.") }
        let ctx = try context(width: base.width, height: base.height)
        let s = size(base)
        drawImage(base, in: CGRect(origin: .zero, size: s), ctx: ctx)
        drawRedactions(rects, style: style, obscured: obscured(base, style: style), in: ctx, size: s)
        guard let out = ctx.makeImage() else { throw ToolError("Could not prepare the redacted photo.") }
        return out
    }

    /// Faces and text lines, as padded normalized rects (top-left origin).
    static func detectSensitiveRegions(_ img: CGImage) throws -> [CGRect] {
        let faces = VNDetectFaceRectanglesRequest()
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .fast
        try VNImageRequestHandler(cgImage: img).perform([faces, text])
        let boxes = (faces.results ?? []).map(\.boundingBox) + (text.results ?? []).map(\.boundingBox)
        return boxes.map { b in
            let pad = 0.15 * min(b.width, b.height)
            let r = CGRect(x: b.minX - pad, y: 1 - b.maxY - pad, width: b.width + 2 * pad, height: b.height + 2 * pad)
            return r.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }

    // MARK: Crop

    static func crop(_ base: CGImage, to normalized: CGRect) throws -> CGImage {
        guard CGRect(x: -0.001, y: -0.001, width: 1.002, height: 1.002).contains(normalized) else {
            throw ToolError("Keep the crop inside the image.")
        }
        let r = CGRect(x: normalized.minX * CGFloat(base.width), y: normalized.minY * CGFloat(base.height),
                       width: normalized.width * CGFloat(base.width), height: normalized.height * CGFloat(base.height)).integral
            .intersection(CGRect(origin: .zero, size: size(base)))
        guard r.width >= 1, r.height >= 1, let out = base.cropping(to: r) else { throw ToolError("Keep the crop inside the image.") }
        return out
    }

    // MARK: Background frame

    /// The subject cut out on a transparent background (macOS 14+).
    static func liftSubject(_ img: CGImage) throws -> CGImage {
        guard #available(macOS 14.0, *) else { throw ToolError("Lifting the subject needs macOS 14 or later.") }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: img)
        try handler.perform([request])
        guard let result = request.results?.first, !result.allInstances.isEmpty else {
            throw ToolError("Could not detect a subject in this image.")
        }
        let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: false)
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let out = CIContext().createCGImage(ci, from: ci.extent) else { throw ToolError("Could not prepare the image background.") }
        return out
    }

    static func frame(_ source: CGImage, options o: FrameOptions, backgroundImage: CGImage? = nil) throws -> CGImage {
        let img = o.liftSubject ? try liftSubject(source) : source
        let w = CGFloat(img.width), h = CGFloat(img.height)
        let pad = o.padding * max(w, h)
        var cw = w + 2 * pad, ch = h + 2 * pad
        if let r = o.ratio.value { if cw / ch < r { cw = ch * r } else { ch = cw / r } }
        let scale = min(1, CGFloat(maxCanvas) / max(cw, ch))
        let canvas = CGSize(width: (cw * scale).rounded(), height: (ch * scale).rounded())
        let ctx = try context(width: Int(canvas.width), height: Int(canvas.height))
        let full = CGRect(origin: .zero, size: canvas)

        switch o.background {
        case .gradient(let i):
            let (a, b) = FrameBackground.gradients[i % FrameBackground.gradients.count]
            let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [a.cg, b.cg] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: canvas.width, y: canvas.height), options: [])
        case .solid(let c):
            ctx.setFillColor(c.cg); ctx.fill(full)
        case .blurred:
            let ci = CIImage(cgImage: source).clampedToExtent()
                .applyingGaussianBlur(sigma: Double(max(w, h)) * 0.05)
                .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
            if let blurred = CIContext().createCGImage(ci, from: CGRect(x: 0, y: 0, width: w, height: h)) {
                drawImage(blurred, in: aspectFill(CGSize(width: w, height: h), in: full), ctx: ctx)
            }
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.12)); ctx.fill(full)
        case .image:
            if let bg = backgroundImage { drawImage(bg, in: aspectFill(size(bg), in: full), ctx: ctx) }
            else { ctx.setFillColor(.white); ctx.fill(full) }
        }

        let rect = CGRect(x: (canvas.width - w * scale) / 2, y: (canvas.height - h * scale) / 2, width: w * scale, height: h * scale)
        let radius = o.liftSubject ? 0 : o.cornerRadius * min(rect.width, rect.height)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if o.shadow {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: rect.height * 0.015), blur: max(rect.width, rect.height) * 0.04,
                          color: CGColor(gray: 0, alpha: 0.45))
            if o.liftSubject {
                drawImage(img, in: rect, ctx: ctx)   // shadow follows the subject's alpha
            } else {
                ctx.addPath(path); ctx.setFillColor(.white); ctx.fillPath()
            }
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        drawImage(img, in: rect, ctx: ctx)
        ctx.restoreGState()
        guard let out = ctx.makeImage() else { throw ToolError("Could not finish adding the background.") }
        return out
    }

    // MARK: Collage

    static func collageColumns(count: Int, options: CollageOptions) -> Int {
        options.columns > 0 ? min(options.columns, count) : max(1, Int(ceil(sqrt(Double(count)))))
    }

    static func collage(_ images: [CGImage], options o: CollageOptions) throws -> CGImage {
        guard !images.isEmpty else { throw ToolError("Choose at least one image.") }
        let cols = collageColumns(count: images.count, options: o)
        let rows = Int(ceil(Double(images.count) / Double(cols)))
        let W = CGFloat(min(max(o.width, 64), maxCanvas))
        let gap = CGFloat(o.spacing) * W / CGFloat(max(o.width, 1))
        let cellW = (W - gap * CGFloat(cols + 1)) / CGFloat(cols)
        let cellH = cellW / CGFloat(o.cellAspect)
        let H = (cellH * CGFloat(rows) + gap * CGFloat(rows + 1)).rounded()
        guard cellW >= 8, cellH >= 8, H <= CGFloat(maxCanvas) else {
            throw ToolError("Choose a canvas and spacing that leave at least 8 pixels for each image (maximum canvas: \(maxCanvas) pixels).")
        }
        let ctx = try context(width: Int(W), height: Int(H))
        ctx.setFillColor(o.background.cg); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

        for (i, img) in images.enumerated() {
            let row = i / cols, col = i % cols
            // Center an incomplete last row.
            let inRow = row == rows - 1 ? images.count - row * cols : cols
            let rowOffset = CGFloat(cols - inRow) * (cellW + gap) / 2
            let cell = CGRect(x: gap + CGFloat(col) * (cellW + gap) + rowOffset, y: gap + CGFloat(row) * (cellH + gap),
                              width: cellW, height: cellH)
            ctx.saveGState()
            ctx.clip(to: cell)
            drawImage(img, in: o.style == .fill ? aspectFill(size(img), in: cell) : aspectFit(size(img), in: cell), ctx: ctx)
            ctx.restoreGState()
        }
        guard let out = ctx.makeImage() else { throw ToolError("Could not render the collage.") }
        return out
    }
}
