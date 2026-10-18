import Foundation

/// Headless entry point for scripting and testing:
///   Clementine --cli <operation> <file>...
/// Operations: convert:<fmt>, compress, strip, resize:<px>, ocr, qr, combine, split, pdf2png, gif, audio, mute, zip, extract,
///   trim:<start>-<end>, cut:<t1>,<t2>[:joined:<removed idx>,...], join, speed:<x>, crop:<x>,<y>,<w>,<h>,
///   normalize[:<lufs>[:<ceiling dB>]], channels:<mono|stereo>[:<left>,<right>], silence[:<dB>], loudness,
///   annotate:<marks.json>, redact:<x>,<y>,<w>,<h>[;…][:blur|pixelate|solid], redact-auto[:style],
///   background[:<preset 0-5|blurred|#rrggbb>[:<padding>[:<ratio>[:lift]]]], collage[:<columns>[:fill|fit]]
/// Image rects for crop/redact are normalized 0…1 with a top-left origin.
enum CLI {
    static func operation(_ name: String) -> FileOperation? {
        let parts = name.split(separator: ":").map(String.init)
        switch parts[0] {
        case "convert": return parts.count > 1 ? OutputFormat(rawValue: parts[1]).map(FileOperation.convert) : nil
        case "compress": return .compress
        case "strip": return .removeMetadata
        case "resize": return .resize(maxDimension: Int(parts.count > 1 ? parts[1] : "1600") ?? 1600)
        case "ocr": return .extractText
        case "qr": return .readQRCode
        case "combine": return .combinePDF
        case "split": return .splitPDF
        case "pdf2png": return .pdfToImages
        case "gif": return .videoToGIF
        case "audio": return .extractAudio
        case "mute": return .muteVideo
        case "zip": return .zip
        case "extract": return .extractArchive
        default: return nil
        }
    }

    /// Parameterized timeline edits, which the GUI drives through editor windows.
    static func edit(_ spec: String, _ urls: [URL]) async throws -> [URL]? {
        let parts = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let nums = { (i: Int, sep: Character) -> [Double] in
            parts.count > i ? parts[i].split(separator: sep).compactMap { Double($0) } : []
        }
        let url = urls[0]
        let isAudio = FileKind.of(url) == .audio
        switch parts[0] {
        case "trim":
            let r = nums(1, "-")
            guard r.count == 2 else { throw ToolError("trim:<start>-<end>") }
            return [isAudio ? try AudioEdit.trim(url, start: r[0], end: r[1]) : try await VideoEdit.trim(url, start: r[0], end: r[1])]
        case "cut":
            let joined = parts.count > 2 && parts[2] == "joined"
            let removed = Set(nums(3, ",").map(Int.init))
            return try await VideoEdit.split(url, at: nums(1, ","), removing: removed, mode: joined ? .joined : .separate)
        case "join": return [try await VideoEdit.join(urls)]
        case "speed": return [try await VideoEdit.changeSpeed(url, speed: nums(1, ",").first ?? 2)]
        case "crop":
            let r = nums(1, ",")
            guard r.count == 4 else { throw ToolError("crop:<x>,<y>,<w>,<h>") }
            let rect = CGRect(x: r[0], y: r[1], width: r[2], height: r[3])
            if FileKind.of(url) == .image {
                return try urls.map { try ImageEdit.write(ImageEdit.crop(ImageEdit.load($0), to: rect), beside: $0, suffix: " cropped") }
            }
            return [try await VideoEdit.crop(url, to: rect)]
        case "annotate":
            guard parts.count > 1 else { throw ToolError("annotate:<marks.json>") }
            let marks = try JSONDecoder().decode([Annotation].self, from: Data(contentsOf: URL(fileURLWithPath: parts[1])))
            return [try ImageEdit.write(ImageEdit.annotate(ImageEdit.load(url), with: marks), beside: url, suffix: " annotated")]
        case "redact", "redact-auto":
            let auto = parts[0] == "redact-auto"
            let styleName = auto ? (parts.count > 1 ? parts[1] : "blur") : (parts.count > 2 ? parts[2] : "blur")
            let style = RedactionStyle(rawValue: styleName) ?? .blur
            let base = try ImageEdit.load(url)
            let rects: [CGRect] = auto ? try ImageEdit.detectSensitiveRegions(base)
                : (parts.count > 1 ? parts[1] : "").split(separator: ";").compactMap { spec in
                    let v = spec.split(separator: ",").compactMap { Double($0) }
                    return v.count == 4 ? CGRect(x: v[0], y: v[1], width: v[2], height: v[3]) : nil
                }
            return [try ImageEdit.write(ImageEdit.redact(base, rects: rects, style: style), beside: url, suffix: " redacted")]
        case "background":
            var o = FrameOptions()
            if parts.count > 1 {
                let b = parts[1]
                if b == "blurred" { o.background = .blurred }
                else if b.hasPrefix("#"), b.count == 7, let v = Int(b.dropFirst(), radix: 16) {
                    o.background = .solid(RGBA(r: Double(v >> 16 & 255) / 255, g: Double(v >> 8 & 255) / 255, b: Double(v & 255) / 255))
                } else if let i = Int(b) { o.background = .gradient(i) }
            }
            if let p = nums(2, ",").first { o.padding = p }
            if parts.count > 3, let r = FrameRatio(rawValue: parts[3]) { o.ratio = r }
            o.liftSubject = parts.count > 4 && parts[4] == "lift"
            return [try ImageEdit.write(ImageEdit.frame(ImageEdit.load(url), options: o), beside: url, suffix: " framed", forcePNG: true)]
        case "collage":
            var o = CollageOptions()
            o.columns = Int(nums(1, ",").first ?? 0)
            if parts.count > 2, let s = CollageStyle(rawValue: parts[2]) { o.style = s }
            let images = try OperationRunner.finderOrder(urls).map { try ImageEdit.load($0, maxDimension: CGFloat(o.width)) }
            let dest = Output.unique(in: url.deletingLastPathComponent(), base: "Collage", ext: "png")
            return [try ImageEdit.write(ImageEdit.collage(images, options: o), beside: dest, suffix: "", forcePNG: true)]
        case "normalize":
            return try urls.map { try AudioEdit.normalize($0, targetLUFS: nums(1, ",").first ?? -16, peakCeilingDB: nums(2, ",").first ?? -1) }
        case "channels":
            let layout = AudioEdit.ChannelLayout(rawValue: parts.count > 1 ? parts[1] : "mono") ?? .mono
            let v = nums(2, ",")
            return [try AudioEdit.convertChannels(url, layout: layout, leftVolume: v.first ?? 1, rightVolume: v.count > 1 ? v[1] : 1)]
        case "silence": return try urls.map { try AudioEdit.trimSilence($0, thresholdDB: nums(1, ",").first ?? -50) }
        case "loudness":
            for u in urls {
                let m = try AudioEdit.measure(u)
                print(String(format: "%@: %.2f LUFS, peak %.2f dBFS", u.lastPathComponent, m.integratedLUFS, m.samplePeakDB))
            }
            return []
        default: return nil
        }
    }

    static func run(_ args: [String]) async -> Int32 {
        if args.count >= 2 {
            do {
                if let outs = try await edit(args[0], args.dropFirst().map { URL(fileURLWithPath: $0).standardizedFileURL }) {
                    outs.forEach { print($0.path) }
                    return 0
                }
            } catch {
                FileHandle.standardError.write("\(error.localizedDescription)\n".data(using: .utf8)!)
                return 1
            }
        }
        guard args.count >= 2, let op = operation(args[0]) else {
            FileHandle.standardError.write("usage: Clementine --cli <operation> <file>...\n".data(using: .utf8)!)
            return 2
        }
        let urls = args.dropFirst().map { URL(fileURLWithPath: $0).standardizedFileURL }
        let s = Settings.shared
        var failed = false
        do {
            switch op {
            case .readQRCode:
                for u in urls { print(try VisionTools.qrCodes(in: u).joined(separator: "\n")) }
            case .zip: print(try ArchiveTools.zip(urls).path)
            case .combinePDF: print(try PDFTools.combine(OperationRunner.finderOrder(urls)).path)
            default:
                for u in urls {
                    do {
                        for out in try await OperationRunner.perform(op, on: u, strength: s.compression, keepMetadata: s.preserveMetadata) {
                            print(out.path)
                        }
                    } catch {
                        failed = true
                        FileHandle.standardError.write("\(u.lastPathComponent): \(error.localizedDescription)\n".data(using: .utf8)!)
                    }
                }
            }
        } catch {
            FileHandle.standardError.write("\(error.localizedDescription)\n".data(using: .utf8)!)
            return 1
        }
        return failed ? 1 : 0
    }
}
