import AppKit
import ImageIO
import UniformTypeIdentifiers

enum ImageTools {
    static func source(_ url: URL) throws -> CGImageSource {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0 else {
            throw ToolError("Could not read the image \(url.lastPathComponent).")
        }
        return src
    }

    /// Re-encodes an image into `format`, optionally downscaling and changing quality.
    static func convert(_ url: URL, to format: OutputFormat, quality: Double = 0.9,
                        maxDimension: CGFloat? = nil, stripMetadata: Bool = false,
                        destination: URL? = nil) throws -> URL {
        let dest = destination ?? Output.beside(url, ext: format.rawValue)

        if format == .webp, let out = try? writeImageIO(url, type: .webP, to: dest, quality: quality,
                                                         maxDimension: maxDimension, strip: stripMetadata) {
            return out
        }
        if format == .webp {
            guard let cwebp = ExternalTools.cwebp else {
                throw ToolError("WebP encoding needs macOS WebP support or cwebp (brew install webp).")
            }
            var input = url
            // cwebp can't read HEIC; hand it a PNG.
            if !["png", "jpg", "jpeg", "tif", "tiff"].contains(url.pathExtension.lowercased()) {
                input = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
                _ = try writeImageIO(url, type: .png, to: input, quality: 1, maxDimension: maxDimension, strip: true)
            }
            defer { if input != url { try? FileManager.default.removeItem(at: input) } }
            var args = ["-q", String(Int(quality * 100)), input.path, "-o", dest.path]
            if !stripMetadata { args.insert(contentsOf: ["-metadata", "all"], at: 0) }
            try Shell.run(cwebp, args)
            return dest
        }
        if format == .pdf { return try PDFTools.combine([url], destination: dest) }
        guard let type = format.utType else { throw ToolError("Unsupported image format.") }
        return try writeImageIO(url, type: type, to: dest, quality: quality, maxDimension: maxDimension, strip: stripMetadata)
    }

    @discardableResult
    static func writeImageIO(_ url: URL, type: UTType, to dest: URL, quality: Double,
                             maxDimension: CGFloat?, strip: Bool) throws -> URL {
        let src = try source(url)
        // Animated GIF → GIF keeps all frames; everything else writes the first frame.
        let frameCount = (type == .gif) ? CGImageSourceGetCount(src) : 1
        guard let out = CGImageDestinationCreateWithURL(dest as CFURL, type.identifier as CFString, frameCount, nil) else {
            throw ToolError("ImageIO cannot write \(type.preferredFilenameExtension ?? "this format").")
        }
        for i in 0..<frameCount {
            var props: [CFString: Any] = [:]
            if !strip, let p = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any] { props = p }
            props[kCGImageDestinationLossyCompressionQuality] = quality
            // Pixel data is already rotated below when downscaling, so reset orientation then.
            if let maxDimension {
                let opts: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxDimension,
                ]
                guard let img = CGImageSourceCreateThumbnailAtIndex(src, i, opts as CFDictionary) else {
                    throw ToolError("Could not resize the image.")
                }
                props[kCGImagePropertyOrientation] = 1
                CGImageDestinationAddImage(out, img, props as CFDictionary)
            } else {
                guard let img = CGImageSourceCreateImageAtIndex(src, i, nil) else { throw ToolError("Could not decode the image.") }
                CGImageDestinationAddImage(out, img, props as CFDictionary)
            }
        }
        guard CGImageDestinationFinalize(out) else { throw ToolError("ImageIO could not finish the image.") }
        return dest
    }

    /// Lossy re-encode in the same format (PNG becomes downscaled PNG; others lower quality).
    static func compress(_ url: URL, strength: CompressionStrength, keepMetadata: Bool) throws -> URL {
        let ext = url.pathExtension.lowercased()
        let format: OutputFormat = switch ext {
        case "png": .png
        case "heic", "heif": .heic
        case "webp": .webp
        case "gif": .gif
        default: .jpg
        }
        let dest = Output.beside(url, ext: format.rawValue, suffix: " compressed")
        var maxDim: CGFloat?
        if let limit = strength.maxImageDimension, let s = pixelSize(url), max(s.width, s.height) > limit { maxDim = limit }
        let out = try convert(url, to: format, quality: strength.jpegQuality, maxDimension: maxDim,
                              stripMetadata: !keepMetadata, destination: dest)
        try ensureSmaller(out, than: url)
        return out
    }

    static func resize(_ url: URL, maxDimension: Int) throws -> URL {
        let ext = url.pathExtension.lowercased()
        let format = OutputFormat(rawValue: ext == "jpeg" ? "jpg" : ext).flatMap { $0.kind == .image ? $0 : nil } ?? .png
        let dest = Output.beside(url, ext: format.rawValue, suffix: " \(maxDimension)px")
        return try convert(url, to: format, quality: 0.9, maxDimension: CGFloat(maxDimension), destination: dest)
    }

    /// Writes a copy with EXIF/GPS/TIFF/IPTC/XMP removed. Pixels are re-encoded at high quality.
    static func stripMetadata(_ url: URL) throws -> URL {
        let src = try source(url)
        let dest = Output.beside(url, ext: url.pathExtension, suffix: " clean")
        guard let type = CGImageSourceGetType(src),
              let out = CGImageDestinationCreateWithURL(dest as CFURL, type, 1, nil) else {
            throw ToolError("This image format cannot be rewritten.")
        }
        let remove: [CFString: Any] = [
            kCGImagePropertyExifDictionary: kCFNull!, kCGImagePropertyGPSDictionary: kCFNull!,
            kCGImagePropertyTIFFDictionary: kCFNull!, kCGImagePropertyIPTCDictionary: kCFNull!,
            kCGImagePropertyMakerAppleDictionary: kCFNull!, kCGImageMetadataShouldExcludeXMP: true,
            kCGImageMetadataShouldExcludeGPS: true,
        ]
        var error: Unmanaged<CFError>?
        if !CGImageDestinationCopyImageSource(out, src, remove as CFDictionary, &error) {
            // Fallback: decode/re-encode without any properties.
            try? FileManager.default.removeItem(at: dest)
            return try writeImageIO(url, type: UTType(type as String) ?? .jpeg, to: dest, quality: 0.95,
                                    maxDimension: nil, strip: true)
        }
        return dest
    }

    static func pixelSize(_ url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? CGFloat, let h = p[kCGImagePropertyPixelHeight] as? CGFloat else { return nil }
        return CGSize(width: w, height: h)
    }

    static func cgImage(_ url: URL) throws -> CGImage {
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: 8192]
        guard let img = CGImageSourceCreateThumbnailAtIndex(try source(url), 0, opts as CFDictionary) else {
            throw ToolError("Could not decode \(url.lastPathComponent).")
        }
        return img
    }

    static func ensureSmaller(_ out: URL, than original: URL) throws {
        let size = { (u: URL) in (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        if size(out) >= size(original) {
            try? FileManager.default.removeItem(at: out)
            throw ToolError("\(original.lastPathComponent) is already well compressed.")
        }
    }
}
