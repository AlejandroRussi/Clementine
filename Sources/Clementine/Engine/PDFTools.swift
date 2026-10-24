import AppKit
import PDFKit
import Quartz

enum PDFTools {
    static func open(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url), doc.pageCount > 0 else {
            throw ToolError("The PDF cannot be read, is empty, or is password-protected.")
        }
        if doc.isLocked { throw ToolError("\(url.lastPathComponent) is password-protected.") }
        return doc
    }

    /// Combines images and PDFs (in the order given) into one PDF.
    static func combine(_ urls: [URL], destination: URL? = nil) throws -> URL {
        let out = PDFDocument()
        for url in urls {
            if FileKind.of(url) == .pdf {
                let doc = try open(url)
                for i in 0..<doc.pageCount {
                    if let page = doc.page(at: i)?.copy() as? PDFPage { out.insert(page, at: out.pageCount) }
                }
            } else {
                let cg = try ImageTools.cgImage(url)
                let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                guard let page = PDFPage(image: image) else { throw ToolError("Could not create a PDF page from \(url.lastPathComponent).") }
                out.insert(page, at: out.pageCount)
            }
        }
        let first = urls[0]
        let dest = destination ?? (urls.count == 1
            ? Output.beside(first, ext: "pdf")
            : Output.unique(in: first.deletingLastPathComponent(), base: "Combined", ext: "pdf"))
        guard out.write(to: dest) else { throw ToolError("PDFKit could not write the combined PDF.") }
        return dest
    }

    /// One PDF per page (all by default), in a folder beside the original.
    static func split(_ url: URL, pages: [Int]? = nil) throws -> [URL] {
        let doc = try open(url)
        let base = url.deletingPathExtension().lastPathComponent
        if let pages, pages.count == 1 {
            let single = PDFDocument()
            if let page = doc.page(at: pages[0])?.copy() as? PDFPage { single.insert(page, at: 0) }
            let dest = Output.beside(url, ext: "pdf", suffix: " – page \(pages[0] + 1)")
            guard single.write(to: dest) else { throw ToolError("Could not write page \(pages[0] + 1).") }
            return [dest]
        }
        let folder = Output.beside(url, ext: "", suffix: " pages")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for i in pages ?? Array(0..<doc.pageCount) {
            let single = PDFDocument()
            if let page = doc.page(at: i)?.copy() as? PDFPage { single.insert(page, at: 0) }
            let dest = folder.appendingPathComponent("\(base) – page \(i + 1).pdf")
            guard single.write(to: dest) else { throw ToolError("Could not write page \(i + 1).") }
        }
        return [folder]
    }

    /// Saves the chosen pages (0-based, in the order given) as one PDF, one PDF per page, or images.
    static func extract(_ url: URL, pages: [Int], as output: PageOutput) throws -> [URL] {
        let doc = try open(url)
        let pages = pages.filter { $0 >= 0 && $0 < doc.pageCount }
        guard !pages.isEmpty else { throw ToolError("No pages were selected.") }
        switch output {
        case .png, .jpg: return try toImages(url, format: output == .png ? .png : .jpg, pages: pages)
        case .pdf:
            let out = PDFDocument()
            for i in pages { if let page = doc.page(at: i)?.copy() as? PDFPage { out.insert(page, at: out.pageCount) } }
            let label = pages.count == 1 ? "page" : "pages"
            let dest = Output.beside(url, ext: "pdf", suffix: " – \(label) \(PageRange.describe(pages))")
            guard out.write(to: dest) else { throw ToolError("PDFKit could not write the extracted pages.") }
            return [dest]
        case .pdfs:
            return try split(url, pages: pages)
        }
    }

    /// Renders pages (all by default) to images at 2x (144 dpi).
    static func toImages(_ url: URL, format: OutputFormat = .png, scale: CGFloat = 2, pages: [Int]? = nil) throws -> [URL] {
        let doc = try open(url)
        let base = url.deletingPathExtension().lastPathComponent
        let indices = pages ?? Array(0..<doc.pageCount)
        let single = indices.count == 1
        let folder = single ? url.deletingLastPathComponent() : Output.beside(url, ext: "", suffix: " \(format.label)")
        if !single { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }

        var results: [URL] = []
        for i in indices {
            guard let page = doc.page(at: i) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
            guard w > 0, h > 0, w < 20000, h < 20000,
                  let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw ToolError("PDF page \(i + 1) has invalid dimensions.")
            }
            ctx.setFillColor(.white)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: ctx)
            guard let img = ctx.makeImage() else { throw ToolError("Could not render PDF page \(i + 1).") }

            let dest = single ? Output.beside(url, ext: format.rawValue, suffix: doc.pageCount == 1 ? "" : " – page \(i + 1)")
                              : folder.appendingPathComponent("\(base) – page \(i + 1).\(format.rawValue)")
            guard let out = CGImageDestinationCreateWithURL(dest as CFURL, format.utType!.identifier as CFString, 1, nil) else {
                throw ToolError("Could not save the PDF page image.")
            }
            CGImageDestinationAddImage(out, img, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            guard CGImageDestinationFinalize(out) else { throw ToolError("Could not save the PDF page image.") }
            results.append(dest)
        }
        return single ? results : [folder]
    }

    static func text(_ url: URL) throws -> String {
        try open(url).string ?? ""
    }

    /// Uses the system "Reduce File Size" Quartz filter.
    static func compress(_ url: URL) throws -> URL {
        let doc = try open(url)
        let dest = Output.beside(url, ext: "pdf", suffix: " compressed")
        let filterURL = URL(fileURLWithPath: "/System/Library/Filters/Reduce File Size.qfilter")
        guard let filter = QuartzFilter(url: filterURL) else { throw ToolError("The macOS PDF compression filter is unavailable.") }
        let ok = doc.write(to: dest, withOptions: [PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter])
        guard ok else { throw ToolError("Could not create the compressed PDF.") }
        try ImageTools.ensureSmaller(dest, than: url)
        return dest
    }

    static func stripMetadata(_ url: URL) throws -> URL {
        let doc = try open(url)
        doc.documentAttributes = [:]
        let dest = Output.beside(url, ext: "pdf", suffix: " clean")
        guard doc.write(to: dest) else { throw ToolError("PDFKit could not write the cleaned PDF.") }
        return dest
    }
}

/// What to save the pages picked from a PDF as.
enum PageOutput: String, CaseIterable, Identifiable {
    case pdf, pdfs, png, jpg
    var id: String { rawValue }
    var label: String {
        switch self {
        case .pdf: return "One PDF"
        case .pdfs: return "PDF per Page"
        case .png: return "PNG Images"
        case .jpg: return "JPEG Images"
        }
    }
}

/// Page lists written the way people type them: "1-3, 5, 8-" (1-based, inclusive; open ends allowed).
enum PageRange {
    /// 0-based page indices in the order written, without duplicates; nil if the text is malformed or out of range.
    static func parse(_ text: String, pageCount: Int) -> [Int]? {
        var result: [Int] = [], seen = Set<Int>()
        let parts = text.split(whereSeparator: { $0 == "," || $0 == ";" })
        for raw in parts {
            let part = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "–", with: "-")
            guard !part.isEmpty else { continue }
            let bounds = part.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            let lo: Int?, hi: Int?
            switch bounds.count {
            case 1: lo = Int(bounds[0]); hi = lo
            case 2: lo = bounds[0].isEmpty ? 1 : Int(bounds[0]); hi = bounds[1].isEmpty ? pageCount : Int(bounds[1])
            default: return nil
            }
            guard let lo, let hi, lo >= 1, hi <= pageCount, lo <= hi else { return nil }
            for p in lo...hi where seen.insert(p - 1).inserted { result.append(p - 1) }
        }
        return result
    }

    /// "1–3, 5" for 0-based indices [0, 1, 2, 4].
    static func describe(_ pages: [Int]) -> String {
        var runs: [String] = [], i = 0
        while i < pages.count {
            var j = i
            while j + 1 < pages.count, pages[j + 1] == pages[j] + 1 { j += 1 }
            runs.append(j > i ? "\(pages[i] + 1)–\(pages[j] + 1)" : "\(pages[i] + 1)")
            i = j + 1
        }
        return runs.joined(separator: ", ")
    }
}
