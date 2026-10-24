import Foundation
import UniformTypeIdentifiers

/// Broad category of a dropped file, used to decide which actions apply.
enum FileKind: Hashable {
    case image, video, audio, pdf, document, presentation, archive, folder, other

    static func of(_ url: URL) -> FileKind {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue,
           !["rtfd", "pages", "key", "numbers"].contains(url.pathExtension.lowercased()) {
            return .folder
        }
        let ext = url.pathExtension.lowercased()
        if ["pptx", "ppt", "key"].contains(ext) { return .presentation }
        if ["md", "markdown", "docx", "doc", "rtf", "rtfd", "txt", "html", "htm", "odt", "webarchive"].contains(ext) {
            return .document
        }
        if ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar"].contains(ext) { return .archive }
        if ["webp", "avif"].contains(ext) { return .image }
        if ["mkv", "webm", "avi"].contains(ext) { return .video }
        if ["flac", "ogg", "opus"].contains(ext) { return .audio }
        guard let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .text) { return .document }
        return .other
    }
}

/// An output format a file can be converted into.
enum OutputFormat: String, CaseIterable, Hashable {
    // Images
    case jpg, png, heic, webp, tiff, gif, bmp
    // Documents
    case pdf, docx, rtf, txt, html, pptx
    // Video
    case mp4, mov
    // Audio
    case m4a, mp3, wav, aiff, flac

    var label: String { rawValue.uppercased() }

    var kind: FileKind {
        switch self {
        case .jpg, .png, .heic, .webp, .tiff, .gif, .bmp: return .image
        case .pdf: return .pdf
        case .docx, .rtf, .txt, .html: return .document
        case .pptx: return .presentation
        case .mp4, .mov: return .video
        case .m4a, .mp3, .wav, .aiff, .flac: return .audio
        }
    }

    var utType: UTType? {
        switch self {
        case .jpg: return .jpeg
        case .png: return .png
        case .heic: return .heic
        case .webp: return .webP
        case .tiff: return .tiff
        case .gif: return .gif
        case .bmp: return .bmp
        case .pdf: return .pdf
        default: return UTType(filenameExtension: rawValue)
        }
    }
}

/// Every action the conversion wheel or Float can run on files.
enum FileOperation: Hashable {
    case convert(OutputFormat)
    case compress
    case removeMetadata
    case resize(maxDimension: Int)
    case extractText          // OCR (images, PDFs)
    case readQRCode
    case combinePDF           // images/PDFs -> one PDF
    case splitPDF             // PDF -> one PDF per page
    case pickPages            // chosen pages of one PDF -> PDF(s) or images
    case pdfToImages
    case videoToGIF
    case extractAudio
    case muteVideo
    // Timeline editors (open an editor window for a single file)
    case trim
    case split
    case changeSpeed
    case crop
    case join                 // 2+ videos
    case normalizeAudio       // editor for one file, defaults for a batch
    case audioChannels
    case trimSilence
    // Image editors
    case annotate
    case redact
    case background
    case collage              // 2+ images
    case zip
    case extractArchive
    case addToFloat
    case airDrop
    case copyPaths
    case shred                // hide now, Undo for 30 s, then overwrite + delete

    var title: String {
        switch self {
        case .convert(let f): return f.label
        case .compress: return "Compress"
        case .removeMetadata: return "Strip Metadata"
        case .resize(let d): return "Resize \(d)px"
        case .extractText: return "Extract Text"
        case .readQRCode: return "Read QR"
        case .combinePDF: return "Combine PDF"
        case .splitPDF: return "Split PDF"
        case .pickPages: return "Pick Pages"
        case .pdfToImages: return "PDF → PNG"
        case .videoToGIF: return "Make GIF"
        case .extractAudio: return "Extract Audio"
        case .muteVideo: return "Mute"
        case .trim: return "Trim"
        case .split: return "Split"
        case .changeSpeed: return "Speed"
        case .crop: return "Crop"
        case .join: return "Join"
        case .normalizeAudio: return "Normalize"
        case .audioChannels: return "Channels"
        case .trimSilence: return "Trim Silence"
        case .annotate: return "Annotate"
        case .redact: return "Redact"
        case .background: return "Background"
        case .collage: return "Collage"
        case .zip: return "Zip"
        case .extractArchive: return "Extract"
        case .addToFloat: return "Float"
        case .airDrop: return "AirDrop"
        case .copyPaths: return "Copy Paths"
        case .shred: return "Shred"
        }
    }

    var symbol: String {
        switch self {
        case .convert: return "arrow.triangle.2.circlepath"
        case .compress: return "arrow.down.right.and.arrow.up.left"
        case .removeMetadata: return "eye.slash"
        case .resize: return "arrow.up.left.and.down.right.magnifyingglass"
        case .extractText: return "text.viewfinder"
        case .readQRCode: return "qrcode.viewfinder"
        case .combinePDF: return "doc.on.doc"
        case .splitPDF: return "scissors"
        case .pickPages: return "square.grid.3x3.topleft.filled"
        case .pdfToImages: return "photo.on.rectangle"
        case .videoToGIF: return "film.stack"
        case .extractAudio: return "waveform"
        case .muteVideo: return "speaker.slash"
        case .trim: return "timeline.selection"
        case .split: return "scissors"
        case .changeSpeed: return "gauge.with.dots.needle.67percent"
        case .crop: return "crop"
        case .join: return "film.stack"
        case .normalizeAudio: return "speaker.wave.2"
        case .audioChannels: return "hifispeaker.2"
        case .trimSilence: return "waveform.badge.minus"
        case .annotate: return "pencil.tip.crop.circle"
        case .redact: return "eye.slash.circle"
        case .background: return "photo.artframe"
        case .collage: return "square.grid.2x2"
        case .zip: return "doc.zipper"
        case .extractArchive: return "archivebox"
        case .addToFloat: return "rectangle.stack"
        case .airDrop: return "dot.radiowaves.left.and.right"
        case .copyPaths: return "link"
        case .shred: return "flame"
        }
    }

    /// Destroys the input files (drawn in red in the wheel).
    var isDestructive: Bool { self == .shred }
}

enum OperationCatalog {
    /// Formats each input kind can be converted into.
    static func formats(for kind: FileKind) -> [OutputFormat] {
        let ffmpeg = ExternalTools.ffmpeg != nil
        switch kind {
        case .image: return [.jpg, .png, .heic] + (ExternalTools.canWriteWebP ? [.webp] : []) + [.tiff, .gif, .pdf]
        case .document: return [.pdf, .docx, .rtf, .txt, .html]
        case .video: return [.mp4, .mov, .m4a] + (ffmpeg ? [.mp3] : [])
        case .audio: return [.m4a, .wav, .aiff] + (ffmpeg ? [.mp3, .flac] : [])
        case .pdf: return [.png, .jpg, .txt, .pptx]
        case .presentation: return [.pdf]
        default: return []
        }
    }

    /// The conversion targets shown in the wheel for a set of files.
    /// Only formats valid for every file are offered.
    static func conversions(for urls: [URL]) -> [OutputFormat] {
        let kinds = Set(urls.map(FileKind.of))
        guard let first = kinds.first else { return [] }
        var common = formats(for: first)
        for k in kinds.dropFirst() { common = common.filter { formats(for: k).contains($0) } }
        // Don't offer "convert to the format it already is" for single-format drops.
        let exts = Set(urls.map { $0.pathExtension.lowercased().replacingOccurrences(of: "jpeg", with: "jpg") })
        if exts.count == 1 { common.removeAll { exts.contains($0.rawValue) } }
        return common
    }

    /// Non-conversion tools available for a set of files.
    static func tools(for urls: [URL]) -> [FileOperation] {
        let kinds = Set(urls.map(FileKind.of))
        var ops: [FileOperation] = []
        let only = { (k: FileKind) in kinds == [k] }

        if kinds.isSubset(of: [.image, .video, .pdf]) { ops.append(.compress) }
        if kinds.isSubset(of: [.image, .video, .audio, .pdf]) { ops.append(.removeMetadata) }
        if only(.image) {
            ops += urls.count == 1 ? [.annotate, .redact, .crop, .background] : [.crop, .collage]
            ops += [.resize(maxDimension: 1600), .readQRCode]
        }
        if kinds.isSubset(of: [.image, .pdf]) {
            ops.append(.extractText)
            if urls.count > 1 || only(.image) { ops.append(.combinePDF) }
        }
        if only(.pdf) { ops += (urls.count == 1 ? [.pickPages] : []) + [.splitPDF, .pdfToImages] }
        if only(.video) {
            if urls.count == 1 { ops += [.trim, .split, .changeSpeed, .crop] } else { ops.append(.join) }
            ops += [.videoToGIF, .extractAudio, .muteVideo]
        }
        if only(.audio) {
            if urls.count == 1 { ops += [.trim, .audioChannels] }
            ops += [.normalizeAudio, .trimSilence]
        }
        if only(.archive) { ops.append(.extractArchive) } else { ops.append(.zip) }
        ops += [.addToFloat, .airDrop, .copyPaths, .shred]
        return ops
    }
}
