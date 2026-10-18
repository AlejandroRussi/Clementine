import AppKit

enum DocumentTools {
    static func load(_ url: URL) throws -> NSAttributedString {
        let ext = url.pathExtension.lowercased()
        if ext == "md" || ext == "markdown" {
            let text = try String(contentsOf: url, encoding: .utf8)
            if let md = try? NSAttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                return md
            }
            return NSAttributedString(string: text)
        }
        var opts: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]
        switch ext {
        case "docx": opts[.documentType] = NSAttributedString.DocumentType.officeOpenXML
        case "doc": opts[.documentType] = NSAttributedString.DocumentType.docFormat
        case "odt": opts[.documentType] = NSAttributedString.DocumentType.openDocument
        case "html", "htm": opts[.documentType] = NSAttributedString.DocumentType.html
        case "txt": opts[.documentType] = NSAttributedString.DocumentType.plain
        default: break
        }
        return try NSAttributedString(url: url, options: opts, documentAttributes: nil)
    }

    static func convert(_ url: URL, to format: OutputFormat) throws -> URL {
        let text = try load(url)
        let dest = Output.beside(url, ext: format.rawValue)
        let range = NSRange(location: 0, length: text.length)
        switch format {
        case .pdf:
            try renderPDF(text, to: dest)
        case .txt:
            try text.string.write(to: dest, atomically: true, encoding: .utf8)
        default:
            let type: NSAttributedString.DocumentType = switch format {
            case .docx: .officeOpenXML
            case .rtf: .rtf
            case .html: .html
            default: throw ToolError("Unsupported document format.")
            }
            let data = try text.data(from: range, documentAttributes: [.documentType: type])
            try data.write(to: dest)
        }
        return dest
    }

    /// Paginates the attributed string onto US Letter pages with 72pt margins.
    static func renderPDF(_ text: NSAttributedString, to dest: URL) throws {
        let pageSize = CGSize(width: 612, height: 792)
        let inset: CGFloat = 72
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)

        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let ctx = CGContext(dest as CFURL, mediaBox: &mediaBox, nil) else { throw ToolError("Could not create the PDF.") }
        let textSize = CGSize(width: pageSize.width - inset * 2, height: pageSize.height - inset * 2)

        var pages = 0
        repeat {
            let container = NSTextContainer(size: textSize)
            layout.addTextContainer(container)
            let glyphs = layout.glyphRange(for: container)
            if glyphs.length == 0 && pages > 0 { break }

            ctx.beginPDFPage(nil)
            let gfx = NSGraphicsContext(cgContext: ctx, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = gfx
            ctx.translateBy(x: 0, y: pageSize.height)
            ctx.scaleBy(x: 1, y: -1)
            layout.drawBackground(forGlyphRange: glyphs, at: CGPoint(x: inset, y: inset))
            layout.drawGlyphs(forGlyphRange: glyphs, at: CGPoint(x: inset, y: inset))
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
            pages += 1
            if NSMaxRange(glyphs) >= layout.numberOfGlyphs { break }
        } while pages < 5000
        ctx.closePDF()
    }
}
