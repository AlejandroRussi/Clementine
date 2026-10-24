import AppKit

/// Runs a FileOperation on a batch of files, reporting progress and results.
@MainActor
final class OperationRunner {
    static let shared = OperationRunner()
    private let settings = Settings.shared

    func run(_ op: FileOperation, on urls: [URL]) {
        guard !urls.isEmpty else { return }
        switch op {
        case .addToFloat: FloatController.shared.add(urls); return
        case .airDrop: share(urls); return
        case .copyPaths: copyPaths(urls); return
        case .shred: Shredder.shared.shred(urls); return
        case .readQRCode: readQR(urls); return
        case .join: MediaEditorController.openJoin(urls); return
        case .collage: MediaEditorController.openCollage(urls); return
        case .pickPages: MediaEditorController.openPDFPages(urls[0]); return
        case .annotate, .redact, .background: MediaEditorController.openImage(urls, tool: op); return
        case .crop where FileKind.of(urls[0]) == .image: MediaEditorController.openImage(urls, tool: op); return
        case .trim, .split, .changeSpeed, .crop, .audioChannels:
            MediaEditorController.open(urls[0], tool: op); return
        case .normalizeAudio where urls.count == 1:
            MediaEditorController.open(urls[0], tool: op); return
        default: break
        }

        let hud = ProgressHUD.show(title: "\(op.title) – \(urls.count) item\(urls.count == 1 ? "" : "s")")
        let strength = settings.compression
        let keepMeta = settings.preserveMetadata
        Task.detached(priority: .userInitiated) {
            var outputs: [URL] = []
            var failures: [String] = []
            // Batch operations take every file at once; the rest run per file.
            if op == .combinePDF || op == .zip {
                do { outputs.append(try op == .zip ? ArchiveTools.zip(urls) : PDFTools.combine(Self.finderOrder(urls))) }
                catch { failures.append(error.localizedDescription) }
            } else {
                for (i, url) in urls.enumerated() {
                    await MainActor.run { hud.update(detail: "\(i + 1) of \(urls.count): \(url.lastPathComponent)") }
                    do { outputs += try await Self.perform(op, on: url, strength: strength, keepMetadata: keepMeta) }
                    catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
                }
            }
            let results = outputs, errors = failures
            await MainActor.run { self.finish(hud: hud, outputs: results, failures: errors) }
        }
    }

    nonisolated static func perform(_ op: FileOperation, on url: URL,
                                            strength: CompressionStrength, keepMetadata: Bool) async throws -> [URL] {
        let kind = FileKind.of(url)
        switch op {
        case .convert(let format):
            switch kind {
            case .image: return [try ImageTools.convert(url, to: format, stripMetadata: !keepMetadata)]
            case .document: return [try DocumentTools.convert(url, to: format)]
            case .video, .audio: return [try await MediaTools.convert(url, to: format)]
            case .presentation where format == .pdf: return [try await PresentationTools.pptxToPDF(url)]
            case .pdf:
                if format == .pptx { return [try PresentationTools.pdfToPPTX(url)] }
                if format == .txt {
                    let dest = Output.beside(url, ext: "txt")
                    try PDFTools.text(url).write(to: dest, atomically: true, encoding: .utf8)
                    return [dest]
                }
                return try PDFTools.toImages(url, format: format)
            default: throw ToolError("This file type is not supported.")
            }
        case .compress:
            switch kind {
            case .image: return [try ImageTools.compress(url, strength: strength, keepMetadata: keepMetadata)]
            case .video: return [try await MediaTools.compressVideo(url, strength: strength)]
            case .pdf: return [try PDFTools.compress(url)]
            default: throw ToolError("This file type cannot be compressed.")
            }
        case .removeMetadata:
            switch kind {
            case .image: return [try ImageTools.stripMetadata(url)]
            case .video, .audio: return [try await MediaTools.stripMetadata(url)]
            case .pdf: return [try PDFTools.stripMetadata(url)]
            default: throw ToolError("No readable metadata found.")
            }
        case .resize(let d): return [try ImageTools.resize(url, maxDimension: d)]
        case .extractText: return [try VisionTools.extractText(url)]
        case .splitPDF: return try PDFTools.split(url)
        case .pdfToImages: return try PDFTools.toImages(url)
        case .videoToGIF: return [try await MediaTools.gif(url)]
        case .extractAudio: return [try await MediaTools.extractAudio(url)]
        case .muteVideo: return [try await MediaTools.mute(url)]
        case .extractArchive: return [try ArchiveTools.extract(url)]
        case .normalizeAudio: return [try AudioEdit.normalize(url)]
        case .trimSilence: return [try AudioEdit.trimSilence(url)]
        default: return []
        }
    }

    /// Runs a single custom job (used by editor windows) with the same HUD, sound and error handling.
    func runTask(_ title: String, _ work: @escaping @Sendable () async throws -> [URL]) {
        let hud = ProgressHUD.show(title: title)
        Task.detached(priority: .userInitiated) {
            do {
                let outputs = try await work()
                await MainActor.run { self.finish(hud: hud, outputs: outputs, failures: []) }
            } catch {
                let message = error.localizedDescription
                await MainActor.run { self.finish(hud: hud, outputs: [], failures: [message]) }
            }
        }
    }

    nonisolated static func finderOrder(_ urls: [URL]) -> [URL] {
        urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func finish(hud: ProgressHUD, outputs: [URL], failures: [String]) {
        if failures.isEmpty {
            hud.complete(message: "Done – \(outputs.count) result\(outputs.count == 1 ? "" : "s")")
            if settings.playSound { NSSound(named: "Glass")?.play() }
        } else {
            hud.close()
            let alert = NSAlert()
            alert.messageText = outputs.isEmpty ? "The operation failed" : "Some files could not be processed"
            alert.informativeText = failures.prefix(8).joined(separator: "\n")
            alert.alertStyle = .warning
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        if settings.revealResults, !outputs.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(outputs)
        }
    }

    // MARK: Instant actions

    func share(_ urls: [URL]) {
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
            NSSound.beep(); return
        }
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: urls)
    }

    func copyPaths(_ urls: [URL]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        ProgressHUD.flash("Copied \(urls.count) path\(urls.count == 1 ? "" : "s")")
    }

    func copyFiles(_ urls: [URL]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls as [NSURL])
        ProgressHUD.flash("Copied \(urls.count) item\(urls.count == 1 ? "" : "s")")
    }

    func readQR(_ urls: [URL]) {
        var found: [String] = []
        for url in urls { found += (try? VisionTools.qrCodes(in: url)) ?? [] }
        let alert = NSAlert()
        if found.isEmpty {
            alert.messageText = "No QR codes found"
        } else {
            alert.messageText = found.count == 1 ? "QR code" : "\(found.count) QR codes"
            alert.informativeText = found.joined(separator: "\n\n")
            alert.addButton(withTitle: "Copy Text")
            alert.addButton(withTitle: "Close")
            if let link = found.first.flatMap(URL.init(string:)), ["http", "https"].contains(link.scheme ?? "") {
                alert.addButton(withTitle: "Open Link")
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn where !found.isEmpty:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(found.joined(separator: "\n"), forType: .string)
        case .alertThirdButtonReturn:
            if let link = found.first.flatMap(URL.init(string:)) { NSWorkspace.shared.open(link) }
        default: break
        }
    }
}
