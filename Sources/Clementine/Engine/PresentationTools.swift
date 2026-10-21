import AppKit
import PDFKit
import QuickLookThumbnailing
import WebKit

/// PowerPoint (.pptx) ⇄ PDF.
///
/// PDF → PPTX writes a minimal Office Open XML package with one slide per page, each holding a
/// full-bleed render of the page, with the page's text placed behind it so the deck stays searchable.
/// PPTX → PDF asks Quick Look's built-in Office previewer for HTML, then prints it with WebKit,
/// one PDF page per slide. Keynote is used as a fallback when Quick Look can't read the deck.
enum PresentationTools {
    // MARK: - Writing PPTX

    struct Slide {
        enum Element {
            case image(png: Data, frame: CGRect)                       // frame in points, top-left origin
            case text(String, frame: CGRect, size: CGFloat, color: String = "000000")
        }
        var elements: [Element]
    }

    /// Writes slides of `size` points to `dest` as a .pptx package.
    static func writePPTX(_ slides: [Slide], size: CGSize, title: String, to dest: URL) throws {
        guard !slides.isEmpty else { throw ToolError("The presentation has no slides.") }
        let emu = { (pt: CGFloat) in Int((pt * 12700).rounded()) }   // 1 pt = 12,700 EMU
        let cx = emu(size.width), cy = emu(size.height)
        guard (914_400...51_206_400).contains(cx), (914_400...51_206_400).contains(cy) else {
            throw ToolError("PowerPoint slides must be between 1 and 56 inches on each side.")
        }

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("clementine-pptx-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        func put(_ path: String, _ text: String) throws {
            let url = work.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        func putData(_ path: String, _ data: Data) throws {
            let url = work.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let xml = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
        let ns = #"xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main""#
        let rels = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

        // Package plumbing
        var overrides = """
        <Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>
        <Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>
        <Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>
        <Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>
        <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
        <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
        """
        for i in 1...slides.count {
            overrides += #"<Override PartName="/ppt/slides/slide\#(i).xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>"#
        }
        try put("[Content_Types].xml", """
        \(xml)<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/>\(overrides)</Types>
        """)
        try put("_rels/.rels", """
        \(xml)<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="\(rels)/officeDocument" Target="ppt/presentation.xml"/>\
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>\
        <Relationship Id="rId3" Type="\(rels)/extended-properties" Target="docProps/app.xml"/></Relationships>
        """)
        let now = ISO8601DateFormatter().string(from: Date())
        try put("docProps/core.xml", """
        \(xml)<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" \
        xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" \
        xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:title>\(escape(title))</dc:title>\
        <dcterms:created xsi:type="dcterms:W3CDTF">\(now)</dcterms:created>\
        <dcterms:modified xsi:type="dcterms:W3CDTF">\(now)</dcterms:modified></cp:coreProperties>
        """)
        try put("docProps/app.xml", """
        \(xml)<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties">\
        <Application>Clementine</Application><Slides>\(slides.count)</Slides></Properties>
        """)

        // Presentation
        var slideIds = "", presRels = """
        <Relationship Id="rId1" Type="\(rels)/slideMaster" Target="slideMasters/slideMaster1.xml"/>\
        <Relationship Id="rId2" Type="\(rels)/theme" Target="theme/theme1.xml"/>
        """
        for i in 1...slides.count {
            slideIds += #"<p:sldId id="\#(255 + i)" r:id="rId\#(i + 2)"/>"#
            presRels += #"<Relationship Id="rId\#(i + 2)" Type="\#(rels)/slide" Target="slides/slide\#(i).xml"/>"#
        }
        try put("ppt/presentation.xml", """
        \(xml)<p:presentation \(ns) saveSubsetFonts="1"><p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>\
        <p:sldIdLst>\(slideIds)</p:sldIdLst><p:sldSz cx="\(cx)" cy="\(cy)"/><p:notesSz cx="6858000" cy="9144000"/>\
        <p:defaultTextStyle><a:defPPr><a:defRPr lang="en-US"/></a:defPPr></p:defaultTextStyle></p:presentation>
        """)
        try put("ppt/_rels/presentation.xml.rels", "\(xml)<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(presRels)</Relationships>")

        // Master, layout, theme (minimal but complete enough for PowerPoint and Keynote)
        let emptyTree = #"<p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/></p:spTree></p:cSld>"#
        try put("ppt/slideMasters/slideMaster1.xml", """
        \(xml)<p:sldMaster \(ns)>\(emptyTree)<p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" \
        accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>\
        <p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst>\
        <p:txStyles><p:titleStyle/><p:bodyStyle/><p:otherStyle/></p:txStyles></p:sldMaster>
        """)
        try put("ppt/slideMasters/_rels/slideMaster1.xml.rels", """
        \(xml)<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="\(rels)/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>\
        <Relationship Id="rId2" Type="\(rels)/theme" Target="../theme/theme1.xml"/></Relationships>
        """)
        try put("ppt/slideLayouts/slideLayout1.xml", "\(xml)<p:sldLayout \(ns) type=\"blank\" preserve=\"1\">\(emptyTree.replacingOccurrences(of: "<p:cSld>", with: "<p:cSld name=\"Blank\">"))<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>")
        try put("ppt/slideLayouts/_rels/slideLayout1.xml.rels", """
        \(xml)<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="\(rels)/slideMaster" Target="../slideMasters/slideMaster1.xml"/></Relationships>
        """)
        try put("ppt/theme/theme1.xml", theme)

        // Slides
        for (index, slide) in slides.enumerated() {
            let n = index + 1
            var shapes = "", slideRels = #"<Relationship Id="rId1" Type="\#(rels)/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>"#
            var shapeID = 2, imageRel = 2
            for element in slide.elements {
                switch element {
                case .image(let png, let f):
                    let name = "image\(n)_\(imageRel).png"
                    try putData("ppt/media/\(name)", png)
                    slideRels += #"<Relationship Id="rId\#(imageRel)" Type="\#(rels)/image" Target="../media/\#(name)"/>"#
                    shapes += """
                    <p:pic><p:nvPicPr><p:cNvPr id="\(shapeID)" name="Page \(n)"/><p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>\
                    <p:blipFill><a:blip r:embed="rId\(imageRel)"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>\
                    <p:spPr><a:xfrm><a:off x="\(emu(f.minX))" y="\(emu(f.minY))"/><a:ext cx="\(emu(f.width))" cy="\(emu(f.height))"/></a:xfrm>\
                    <a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic>
                    """
                    imageRel += 1
                case .text(let string, let f, let size, let color):
                    let paragraphs = string.split(separator: "\n", omittingEmptySubsequences: false).map { line in
                        #"<a:p><a:r><a:rPr lang="en-US" sz="\#(Int((size * 100).rounded()))" dirty="0"><a:solidFill><a:srgbClr val="\#(color)"/></a:solidFill></a:rPr><a:t>\#(escape(String(line)))</a:t></a:r></a:p>"#
                    }.joined()
                    shapes += """
                    <p:sp><p:nvSpPr><p:cNvPr id="\(shapeID)" name="Text \(shapeID)"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>\
                    <p:spPr><a:xfrm><a:off x="\(emu(f.minX))" y="\(emu(f.minY))"/><a:ext cx="\(emu(max(f.width, 1)))" cy="\(emu(max(f.height, 1)))"/></a:xfrm>\
                    <a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/></p:spPr>\
                    <p:txBody><a:bodyPr wrap="none" lIns="0" tIns="0" rIns="0" bIns="0" rtlCol="0"><a:noAutofit/></a:bodyPr><a:lstStyle/>\(paragraphs)</p:txBody></p:sp>
                    """
                }
                shapeID += 1
            }
            try put("ppt/slides/slide\(n).xml", """
            \(xml)<p:sld \(ns)><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>\
            <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>\
            \(shapes)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>
            """)
            try put("ppt/slides/_rels/slide\(n).xml.rels", "\(xml)<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(slideRels)</Relationships>")
        }

        // Zip with [Content_Types].xml first, as Office expects.
        try? FileManager.default.removeItem(at: dest)
        let zip = URL(fileURLWithPath: "/usr/bin/zip")
        try Shell.run(zip, ["-X", "-q", dest.path, "[Content_Types].xml"], cwd: work)
        try Shell.run(zip, ["-X", "-q", "-r", dest.path, ".", "-x", "[Content_Types].xml"], cwd: work)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .unicodeScalars.filter { $0.value >= 0x20 || $0 == "\t" }.map(String.init).joined()
    }

    private static let theme = #"""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?><a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Clementine"><a:themeElements><a:clrScheme name="Office"><a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1><a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1><a:dk2><a:srgbClr val="44546A"/></a:dk2><a:lt2><a:srgbClr val="E7E6E6"/></a:lt2><a:accent1><a:srgbClr val="F28C28"/></a:accent1><a:accent2><a:srgbClr val="ED7D31"/></a:accent2><a:accent3><a:srgbClr val="A5A5A5"/></a:accent3><a:accent4><a:srgbClr val="FFC000"/></a:accent4><a:accent5><a:srgbClr val="5B9BD5"/></a:accent5><a:accent6><a:srgbClr val="70AD47"/></a:accent6><a:hlink><a:srgbClr val="0563C1"/></a:hlink><a:folHlink><a:srgbClr val="954F72"/></a:folHlink></a:clrScheme><a:fontScheme name="Office"><a:majorFont><a:latin typeface="Helvetica Neue"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont><a:minorFont><a:latin typeface="Helvetica Neue"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont></a:fontScheme><a:fmtScheme name="Office"><a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst><a:lnStyleLst><a:ln w="6350"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="12700"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="19050"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln></a:lnStyleLst><a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst><a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>
    """#

    // MARK: - PDF → PPTX

    /// One slide per page: the page rendered at 2× as a full-bleed picture. The page's text sits
    /// underneath it, line by line, so the deck can be searched and copied from without showing twice.
    /// (Text transparency isn't honored by every renderer, but z-order is.)
    static func pdfToPPTX(_ url: URL) throws -> URL {
        let doc = try PDFTools.open(url)
        guard let first = doc.page(at: 0) else { throw ToolError("This PDF has no pages.") }
        let size = first.bounds(for: .cropBox).size
        var slides: [Slide] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let bounds = page.bounds(for: .cropBox)
            // Pages of a different shape are fitted into the deck's slide size.
            let fit = ImageEdit.aspectFit(bounds.size, in: CGRect(origin: .zero, size: size))
            let scale = fit.width / bounds.width
            let png = try render(page, scale: 2 * scale)
            var elements: [Slide.Element] = []
            for line in textLines(of: page) {
                let r = line.bounds
                let frame = CGRect(x: fit.minX + (r.minX - bounds.minX) * scale,
                                   y: fit.minY + (bounds.maxY - r.maxY) * scale,
                                   width: r.width * scale, height: r.height * scale)
                elements.append(.text(line.text, frame: frame, size: max(1, r.height * scale * 0.8)))
            }
            elements.append(.image(png: png, frame: fit))
            slides.append(Slide(elements: elements))
        }
        let dest = Output.beside(url, ext: "pptx")
        try writePPTX(slides, size: size, title: url.deletingPathExtension().lastPathComponent, to: dest)
        return dest
    }

    private static func render(_ page: PDFPage, scale: CGFloat) throws -> Data {
        let bounds = page.bounds(for: .cropBox)
        let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
        guard w > 0, h > 0, w <= 8192, h <= 8192,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ToolError("A PDF page has invalid dimensions.")
        }
        ctx.setFillColor(.white); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: ctx)
        guard let img = ctx.makeImage(),
              let data = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else {
            throw ToolError("A PDF page could not be rendered.")
        }
        return data
    }

    private static func textLines(of page: PDFPage) -> [(text: String, bounds: CGRect)] {
        guard let all = page.selection(for: page.bounds(for: .cropBox)) else { return [] }
        return all.selectionsByLine().compactMap { sel in
            guard let t = sel.string?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return (t, sel.bounds(for: page))
        }
    }

    // MARK: - PPTX → PDF

    static func pptxToPDF(_ url: URL) async throws -> URL {
        let dest = Output.beside(url, ext: "pdf")
        do {
            try await QuickLookRenderer.render(url, to: dest)
        } catch let quickLookError {
            // Fall back to Keynote, which reads PowerPoint decks natively.
            guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iWork.Keynote") != nil else {
                throw quickLookError
            }
            try keynoteExport(url, to: dest)
        }
        guard let pdf = PDFDocument(url: dest), pdf.pageCount > 0 else {
            try? FileManager.default.removeItem(at: dest)
            throw ToolError("The converted PDF could not be verified.")
        }
        return dest
    }

    private static func keynoteExport(_ url: URL, to dest: URL) throws {
        let script = """
        on run argv
            set src to POSIX file (item 1 of argv)
            set out to POSIX file (item 2 of argv)
            tell application "Keynote"
                set doc to open src
                export doc to out as PDF with properties {PDF image quality:Best}
                close doc saving no
            end tell
        end run
        """
        try Shell.run(URL(fileURLWithPath: "/usr/bin/osascript"), ["-e", script, url.path, dest.path])
    }
}

// MARK: - Quick Look → WebKit renderer

/// Quick Look's Office generator turns a .pptx into an HTML preview (one positioned block per slide).
/// That HTML is loaded in an offscreen WKWebView and printed, one slide per PDF page.
@MainActor
private final class QuickLookRenderer: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private let webView: WKWebView

    private override init() {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = true
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 720), configuration: config)
        super.init()
        webView.navigationDelegate = self
    }

    nonisolated static func render(_ source: URL, to dest: URL) async throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("clementine-ql-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        // qlmanage writes <name>.qlpreview/Preview.html plus its images and fonts.
        _ = try? Shell.run(URL(fileURLWithPath: "/usr/bin/qlmanage"), ["-p", "-o", work.path, source.path])
        let bundle = try FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "qlpreview" }
        // Some generators (e.g. Keynote's) hand back a finished PDF instead of HTML.
        if let pdf = bundle?.appendingPathComponent("Preview.pdf"), FileManager.default.fileExists(atPath: pdf.path) {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: pdf, to: dest)
            return
        }
        let preview = bundle?.appendingPathComponent("Preview.html")
        guard let preview, FileManager.default.fileExists(atPath: preview.path) else {
            throw ToolError("Quick Look could not read this presentation.")
        }
        try await MainActor.run { QuickLookRenderer() }.print(preview, readAccess: work, to: dest)
    }

    private func print(_ html: URL, readAccess: URL, to dest: URL) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            continuation = c
            webView.loadFileURL(html, allowingReadAccessTo: readAccess)
        }
        // Quick Look's markup puts each slide in a fixed-size `div.slide`. Drop the preview chrome
        // (grey page, gaps, drop shadows, lazy-loading placeholders), then measure each slide.
        let js = """
        (() => {
          const style = document.createElement('style');
          style.textContent = 'body{margin:0!important;background:#fff!important}' +
            'div.slide{margin:0!important;-webkit-box-shadow:none!important;box-shadow:none!important}' +
            'div.loading-slide{display:none!important}';
          document.head.appendChild(style);
          const slides = [...document.querySelectorAll('div.slide')].map(e => {
            const r = e.getBoundingClientRect();
            return {left: r.left + scrollX, top: r.top + scrollY, width: r.width, height: r.height};
          }).filter(r => r.width > 0 && r.height > 0);
          return JSON.stringify({slides, width: document.body.scrollWidth, height: document.body.scrollHeight,
                                 pending: document.querySelectorAll('div.loading-slide').length});
        })()
        """
        struct Layout: Decodable {
            struct Box: Decodable { let left, top, width, height: Double }
            let slides: [Box]; let width, height: Double; let pending: Int
        }
        let json = try await webView.evaluateJavaScript(js) as? String ?? "{}"
        let layout = try JSONDecoder().decode(Layout.self, from: Data(json.utf8))
        guard !layout.slides.isEmpty, layout.pending == 0 else {
            throw ToolError("Quick Look produced an incomplete preview of this presentation.")
        }

        // Grow the view so every slide is laid out, then snapshot each slide box into a PDF page.
        webView.frame = CGRect(x: 0, y: 0, width: max(layout.width, 640), height: max(layout.height, 480))
        let out = PDFDocument()
        for box in layout.slides {
            let config = WKPDFConfiguration()
            config.rect = CGRect(x: box.left, y: box.top, width: box.width, height: box.height)
            let data = try await webView.pdf(configuration: config)
            guard let page = PDFDocument(data: data)?.page(at: 0) else { continue }
            out.insert(page, at: out.pageCount)
        }
        guard out.pageCount > 0, out.write(to: dest) else { throw ToolError("Could not create the PDF.") }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume(); continuation = nil
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error); continuation = nil
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error); continuation = nil
    }
}
