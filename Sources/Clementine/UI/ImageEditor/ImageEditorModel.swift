import AppKit
import SwiftUI

enum ImageTool: String, CaseIterable, Identifiable {
    case annotate, redact, crop, background
    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    init?(_ op: FileOperation) {
        switch op {
        case .annotate: self = .annotate
        case .redact: self = .redact
        case .crop: self = .crop
        case .background: self = .background
        default: return nil
        }
    }
}

@MainActor
final class ImageEditorModel: ObservableObject {
    static let previewMax: CGFloat = 1800

    let urls: [URL]
    var url: URL { urls[0] }
    @Published var tool: ImageTool { didSet { if tool == .background { renderFrame() } } }
    @Published var preview: CGImage?           // downscaled, upright
    @Published var imageSize = CGSize.zero     // full-resolution pixels
    @Published var errorMessage: String?

    // Annotate
    @Published var annotations: [Annotation] = []
    @Published var draft: Annotation?
    @Published var kind: Annotation.Kind = .arrow
    @Published var color: RGBA = .red
    @Published var strokeWidth = 0.006
    @Published var textSize = 0.05
    @Published var magnifierZoom = 2.0
    @Published var newText = "Text"
    @Published var selectedID: UUID?

    // Redact
    @Published var redactions: [CGRect] = []
    @Published var redactionStyle: RedactionStyle = .blur { didSet { refreshObscured() } }
    @Published var selectedRedaction: Int?
    @Published var draftRedaction: CGRect?
    @Published var obscuredPreview: CGImage?
    @Published var isDetecting = false

    // Crop
    @Published var cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    @Published var cropAspect: CropAspect = .free {
        didSet { if let r = cropAspect.centeredRect(for: imageSize) { cropRect = r } }
    }
    @Published var cropAll = true

    // Background
    @Published var frame = FrameOptions() { didSet { renderFrame() } }
    @Published var framePreview: CGImage?
    @Published var backgroundImage: CGImage?
    private var frameTask: Task<Void, Never>?

    init(urls: [URL], tool: ImageTool) {
        self.urls = urls
        self.tool = tool
        do {
            preview = try ImageEdit.load(urls[0], maxDimension: Self.previewMax)
            let full = ImageTools.pixelSize(urls[0]) ?? .zero
            // Pixel size as displayed (orientation applied) follows the preview's shape.
            if let p = preview, full != .zero {
                let longSide = max(full.width, full.height)
                imageSize = p.width >= p.height
                    ? CGSize(width: longSide, height: (longSide * CGFloat(p.height) / CGFloat(p.width)).rounded())
                    : CGSize(width: (longSide * CGFloat(p.width) / CGFloat(p.height)).rounded(), height: longSide)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        refreshObscured()
        if tool == .background { renderFrame() }
    }

    // MARK: Annotate

    var selected: Annotation? {
        get { annotations.first { $0.id == selectedID } }
        set {
            guard let newValue, let i = annotations.firstIndex(where: { $0.id == newValue.id }) else { return }
            annotations[i] = newValue
        }
    }

    func newAnnotation(at p: CGPoint) -> Annotation {
        var a = Annotation(kind: kind, points: [p, p], color: color, width: strokeWidth)
        switch kind {
        case .text: a.points = [p]; a.text = newText; a.fontSize = textSize
        case .magnifier: a.points = [p]; a.zoom = magnifierZoom; a.color = .white
        case .draw: a.points = [p]
        default: break
        }
        return a
    }

    /// Topmost annotation whose bounds (plus a small margin) contain `p`.
    func hitTest(_ p: CGPoint) -> Annotation? {
        let size = CGSize(width: 1, height: 1)
        return annotations.reversed().first { a in
            let margin = max(0.015, a.width * 2)
            return a.rect(in: size).insetBy(dx: -margin, dy: -margin).contains(p)
        }
    }

    func move(_ id: UUID, from original: Annotation, by d: CGSize) {
        guard let i = annotations.firstIndex(where: { $0.id == id }) else { return }
        annotations[i].points = original.points.map {
            CGPoint(x: min(max(0, $0.x + d.width), 1), y: min(max(0, $0.y + d.height), 1))
        }
    }

    func commitDraft() {
        guard let d = draft else { return }
        draft = nil
        let r = d.rect(in: CGSize(width: 1, height: 1))
        switch d.kind {
        case .draw where d.points.count < 3 || max(r.width, r.height) < 0.01:
            errorMessage = "Draw a slightly longer freehand line."; return
        case .arrow, .highlight, .rectangle:
            if max(r.width, r.height) < 0.01 { return }
        case .text where d.text.trimmingCharacters(in: .whitespaces).isEmpty:
            errorMessage = "Enter text for the text box."; return
        default: break
        }
        annotations.append(d)
        selectedID = d.id
    }

    func undo() {
        guard !annotations.isEmpty else { return }
        annotations.removeLast()
        selectedID = nil
    }

    func deleteSelected() {
        if tool == .annotate, let id = selectedID {
            annotations.removeAll { $0.id == id }; selectedID = nil
        } else if tool == .redact, let i = selectedRedaction, redactions.indices.contains(i) {
            redactions.remove(at: i); selectedRedaction = nil
        }
    }

    // MARK: Redact

    private func refreshObscured() {
        guard let preview else { return }
        let style = redactionStyle
        Task.detached(priority: .userInitiated) {
            let img = ImageEdit.obscured(preview, style: style)
            await MainActor.run { self.obscuredPreview = img }
        }
    }

    func detectRegions() {
        guard let preview else { return }
        isDetecting = true
        Task.detached(priority: .userInitiated) {
            let found = (try? ImageEdit.detectSensitiveRegions(preview)) ?? []
            await MainActor.run {
                self.isDetecting = false
                if found.isEmpty { self.errorMessage = "No faces or text were found." }
                self.redactions += found
            }
        }
    }

    // MARK: Background

    func renderFrame() {
        guard let preview else { return }
        frameTask?.cancel()
        let options = frame, bg = backgroundImage, url = url
        frameTask = Task.detached(priority: .userInitiated) {
            // Render small for responsiveness; export re-renders at full size.
            let small = (try? ImageEdit.load(url, maxDimension: 900)) ?? preview
            do {
                let img = try ImageEdit.frame(small, options: options, backgroundImage: bg)
                if Task.isCancelled { return }
                await MainActor.run { self.framePreview = img }
            } catch {
                await MainActor.run { self.errorMessage = error.localizedDescription; self.frame.liftSubject = false }
            }
        }
    }

    func chooseBackgroundImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose a background image"
        guard panel.runModal() == .OK, let u = panel.url else { return }
        backgroundImage = try? ImageEdit.load(u, maxDimension: 4096)
        frame.background = .image(u)
    }

    // MARK: Export

    var exportTitle: String {
        switch tool {
        case .annotate: "Save Annotated Copy"
        case .redact: "Save Redacted Copy"
        case .crop: urls.count > 1 && cropAll ? "Crop \(urls.count) Images" : "Save Cropped Copy"
        case .background: "Save with Background"
        }
    }

    var canExport: Bool {
        switch tool {
        case .annotate: !annotations.isEmpty
        case .redact: !redactions.isEmpty
        case .crop: cropRect != CGRect(x: 0, y: 0, width: 1, height: 1)
        case .background: preview != nil
        }
    }

    func export() {
        let urls = tool == .crop && cropAll ? urls : [url]
        let (marks, rects, style, crop, options, bg) = (annotations, redactions, redactionStyle, cropRect, frame, backgroundImage)
        let tool = tool
        OperationRunner.shared.runTask("\(tool.label) – \(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) images")") {
            try urls.map { u in
                let base = try ImageEdit.load(u)
                switch tool {
                case .annotate: return try ImageEdit.write(ImageEdit.annotate(base, with: marks), beside: u, suffix: " annotated")
                case .redact: return try ImageEdit.write(ImageEdit.redact(base, rects: rects, style: style), beside: u, suffix: " redacted")
                case .crop: return try ImageEdit.write(ImageEdit.crop(base, to: crop), beside: u, suffix: " cropped")
                case .background:
                    return try ImageEdit.write(ImageEdit.frame(base, options: options, backgroundImage: bg),
                                               beside: u, suffix: " framed", forcePNG: true)
                }
            }
        }
    }
}
