import AppKit
import Vision

enum VisionTools {
    static func qrCodes(in url: URL) throws -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr, .aztec, .dataMatrix, .pdf417]
        try VNImageRequestHandler(cgImage: try ImageTools.cgImage(url)).perform([request])
        return (request.results ?? []).compactMap(\.payloadStringValue)
    }

    static func recognizeText(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    /// Writes recognized text beside the file. PDFs use embedded text first, then OCR.
    static func extractText(_ url: URL) throws -> URL {
        var text: String
        if FileKind.of(url) == .pdf {
            text = try PDFTools.text(url)
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let tmp = try PDFTools.toImages(url)
                defer { tmp.forEach { try? FileManager.default.removeItem(at: $0) } }
                let images = tmp.flatMap { u -> [URL] in
                    FileKind.of(u) == .folder
                        ? ((try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? [])
                            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                        : [u]
                }
                text = try images.map { try recognizeText(ImageTools.cgImage($0)) }.joined(separator: "\n\n")
            }
        } else {
            text = try recognizeText(ImageTools.cgImage(url))
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError("No text found in \(url.lastPathComponent).")
        }
        let dest = Output.beside(url, ext: "txt")
        try text.write(to: dest, atomically: true, encoding: .utf8)
        return dest
    }
}
