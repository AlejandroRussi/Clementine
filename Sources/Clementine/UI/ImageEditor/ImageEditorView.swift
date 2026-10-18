import SwiftUI

struct ImageEditorView: View {
    @ObservedObject var model: ImageEditorModel

    var body: some View {
        VStack(spacing: 12) {
            Picker("", selection: $model.tool) {
                ForEach(ImageTool.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 420)

            Group {
                switch model.tool {
                case .annotate: AnnotationCanvas(model: model)
                case .redact: RedactionCanvas(model: model)
                case .crop: CropSelectionView(image: model.preview, imageSize: model.imageSize, rect: $model.cropRect, aspect: model.cropAspect)
                case .background:
                    if let img = model.framePreview {
                        Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        ProgressView()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))

            controls
            HStack {
                Text(model.urls.count > 1 ? "\(model.url.lastPathComponent) + \(model.urls.count - 1) more" : model.url.lastPathComponent)
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(model.exportTitle) { model.export() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canExport)
            }
        }
        .padding(16)
        .frame(minWidth: 760, minHeight: 600)
        .background(DeleteKeyCatcher { model.deleteSelected() })
        .alert("Clementine", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") {}
        } message: { Text(model.errorMessage ?? "") }
    }

    @ViewBuilder private var controls: some View {
        switch model.tool {
        case .annotate: AnnotateControls(model: model)
        case .redact:
            HStack {
                Picker("Style", selection: $model.redactionStyle) {
                    ForEach(RedactionStyle.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 260)
                Button {
                    model.detectRegions()
                } label: {
                    if model.isDetecting { ProgressView().controlSize(.small) } else { Text("Detect Faces & Text") }
                }
                Button("Delete Redaction") { model.deleteSelected() }.disabled(model.selectedRedaction == nil)
                Spacer()
                Text("\(model.redactions.count) area\(model.redactions.count == 1 ? "" : "s")").foregroundStyle(.secondary)
            }
            Text("Draw rectangles to cover areas. Blur softens details. Use Solid for sensitive information.")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        case .crop:
            HStack {
                Picker("Aspect", selection: $model.cropAspect) {
                    ForEach(CropAspect.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 380)
                Spacer()
                let r = model.cropRect, s = model.imageSize
                Text("\(Int(r.width * s.width)) × \(Int(r.height * s.height)) px").monospacedDigit()
                Button("Reset") { model.cropAspect = .free; model.cropRect = CGRect(x: 0, y: 0, width: 1, height: 1) }
            }
            if model.urls.count > 1 {
                Toggle("Use this crop, as the same share of each image, for every image", isOn: $model.cropAll)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .background: BackgroundControls(model: model)
        }
    }
}

// MARK: - Annotate

private struct AnnotateControls: View {
    @ObservedObject var model: ImageEditorModel

    var body: some View {
        HStack(spacing: 10) {
            Picker("", selection: $model.kind) {
                ForEach(Annotation.Kind.allCases) { Image(systemName: $0.symbol).help($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            ColorPicker("", selection: Binding(get: { Color(nsColor: model.color.nsColor) },
                                               set: { model.color = RGBA(NSColor($0)); recolorSelection() }))
                .labelsHidden().help("Annotation color")
            switch model.kind {
            case .text:
                TextField("Text", text: $model.newText).frame(width: 140)
                Stepper("Size", value: $model.textSize, in: 0.02...0.15, step: 0.01)
            case .magnifier:
                Picker("Zoom", selection: $model.magnifierZoom) {
                    ForEach([1.5, 2, 3, 4], id: \.self) { Text(String(format: "%g×", $0)).tag($0) }
                }
                .frame(width: 110).help("Magnifier zoom level")
            default:
                Text("Width").foregroundStyle(.secondary)
                Slider(value: $model.strokeWidth, in: 0.002...0.02).frame(width: 110)
            }
            Spacer()
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .keyboardShortcut("z").help("Undo last annotation").disabled(model.annotations.isEmpty)
            Button { model.deleteSelected() } label: { Image(systemName: "trash") }
                .help("Delete selected annotation").disabled(model.selectedID == nil)
        }
        if let sel = model.selected, sel.kind == .text {
            HStack {
                Text("Selected text").foregroundStyle(.secondary)
                TextField("Text", text: Binding(get: { sel.text }, set: { var a = sel; a.text = $0; model.selected = a }))
            }
        }
        Text(hint).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hint: String {
        switch model.kind {
        case .arrow: "Drag from the tail toward the arrowhead. Drag an annotation to move it."
        case .draw: "Drag on the image to draw. Drag an annotation to move it."
        case .highlight: "Drag over the image to highlight."
        case .rectangle: "Drag to draw a box."
        case .text: "Type the text above, then click where it should go."
        case .magnifier: "Choose a zoom level, then click the detail to place a magnifier bubble."
        }
    }

    private func recolorSelection() {
        guard var a = model.selected, a.kind != .magnifier else { return }
        a.color = model.color
        model.selected = a
    }
}

/// Shows the preview image with annotations drawn by the same renderer used for export.
private struct AnnotationCanvas: View {
    @ObservedObject var model: ImageEditorModel
    @State private var moving: (id: UUID, original: Annotation)?
    @State private var started = false

    var body: some View {
        GeometryReader { geo in
            let fit = fitRect(model.imageSize, in: geo.size)
            let norm = { (p: CGPoint) in CGPoint(x: min(max(0, (p.x - fit.minX) / fit.width), 1),
                                                 y: min(max(0, (p.y - fit.minY) / fit.height), 1)) }
            ZStack(alignment: .topLeading) {
                if let img = model.preview {
                    Image(decorative: img, scale: 1).resizable().frame(width: fit.width, height: fit.height).offset(x: fit.minX, y: fit.minY)
                }
                Canvas { ctx, _ in
                    let marks = model.annotations + (model.draft.map { [$0] } ?? [])
                    ctx.withCGContext { cg in
                        cg.translateBy(x: fit.minX, y: fit.minY)
                        ImageEdit.drawAnnotations(marks, in: cg, size: fit.size, base: model.preview)
                    }
                    if let sel = model.selected {
                        let r = sel.rect(in: fit.size).offsetBy(dx: fit.minX, dy: fit.minY).insetBy(dx: -6, dy: -6)
                        ctx.stroke(Path(roundedRect: r, cornerRadius: 4), with: .color(.accentColor), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    }
                }
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let start = norm(g.startLocation), p = norm(g.location)
                    if !started {
                        started = true
                        if let hit = model.hitTest(start) {
                            moving = (hit.id, hit); model.selectedID = hit.id
                        } else {
                            model.selectedID = nil
                            model.draft = model.newAnnotation(at: start)
                        }
                    }
                    if let m = moving {
                        model.move(m.id, from: m.original, by: CGSize(width: p.x - start.x, height: p.y - start.y))
                    } else if var d = model.draft {
                        switch d.kind {
                        case .draw: d.points.append(p)
                        case .text, .magnifier: d.points = [p]
                        default: d.points[1] = p
                        }
                        model.draft = d
                    }
                }
                .onEnded { _ in
                    started = false
                    if moving == nil { model.commitDraft() }
                    moving = nil
                })
        }
        .padding(8)
    }
}

// MARK: - Redact

private struct RedactionCanvas: View {
    @ObservedObject var model: ImageEditorModel
    @State private var moving: (index: Int, original: CGRect)?
    @State private var started = false

    var body: some View {
        GeometryReader { geo in
            let fit = fitRect(model.imageSize, in: geo.size)
            let norm = { (p: CGPoint) in CGPoint(x: min(max(0, (p.x - fit.minX) / fit.width), 1),
                                                 y: min(max(0, (p.y - fit.minY) / fit.height), 1)) }
            ZStack(alignment: .topLeading) {
                if let img = model.preview {
                    Image(decorative: img, scale: 1).resizable().frame(width: fit.width, height: fit.height).offset(x: fit.minX, y: fit.minY)
                }
                Canvas { ctx, _ in
                    let rects = model.redactions + (model.draftRedaction.map { [$0] } ?? [])
                    ctx.withCGContext { cg in
                        cg.translateBy(x: fit.minX, y: fit.minY)
                        ImageEdit.drawRedactions(rects, style: model.redactionStyle, obscured: model.obscuredPreview, in: cg, size: fit.size)
                    }
                    for (i, r) in rects.enumerated() {
                        let px = CGRect(x: fit.minX + r.minX * fit.width, y: fit.minY + r.minY * fit.height,
                                        width: r.width * fit.width, height: r.height * fit.height)
                        ctx.stroke(Path(px), with: .color(i == model.selectedRedaction ? .accentColor : .orange.opacity(0.8)),
                                   style: StrokeStyle(lineWidth: i == model.selectedRedaction ? 2.5 : 1, dash: [6, 4]))
                    }
                }
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let start = norm(g.startLocation), p = norm(g.location)
                    if !started {
                        started = true
                        if let i = model.redactions.lastIndex(where: { $0.contains(start) }) {
                            moving = (i, model.redactions[i]); model.selectedRedaction = i
                        } else {
                            model.selectedRedaction = nil
                        }
                    }
                    if let m = moving {
                        var r = m.original.offsetBy(dx: p.x - start.x, dy: p.y - start.y)
                        r.origin.x = min(max(0, r.minX), 1 - r.width); r.origin.y = min(max(0, r.minY), 1 - r.height)
                        model.redactions[m.index] = r
                    } else {
                        model.draftRedaction = CGRect(x: min(start.x, p.x), y: min(start.y, p.y),
                                                      width: abs(p.x - start.x), height: abs(p.y - start.y))
                    }
                }
                .onEnded { _ in
                    started = false
                    if let d = model.draftRedaction, d.width > 0.005, d.height > 0.005 {
                        model.redactions.append(d)
                        model.selectedRedaction = model.redactions.count - 1
                    }
                    model.draftRedaction = nil
                    moving = nil
                })
        }
        .padding(8)
    }
}

// MARK: - Background

private struct BackgroundControls: View {
    @ObservedObject var model: ImageEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(FrameBackground.gradients.indices, id: \.self) { i in
                    let (a, b) = FrameBackground.gradients[i]
                    swatch(selected: model.frame.background == .gradient(i)) {
                        LinearGradient(colors: [Color(nsColor: a.nsColor), Color(nsColor: b.nsColor)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    }
                    .onTapGesture { model.frame.background = .gradient(i) }
                }
                swatch(selected: model.frame.background == .blurred) {
                    Image(systemName: "drop.halffull").frame(maxWidth: .infinity, maxHeight: .infinity).background(.gray.opacity(0.3))
                }
                .onTapGesture { model.frame.background = .blurred }
                .help("Blurred copy of the image")
                ColorPicker("", selection: Binding(
                    get: { if case .solid(let c) = model.frame.background { Color(nsColor: c.nsColor) } else { .white } },
                    set: { model.frame.background = .solid(RGBA(NSColor($0))) }))
                    .labelsHidden().help("Choose a custom background color")
                Button("Image…") { model.chooseBackgroundImage() }.help("Choose a background image")
                Spacer()
                Picker("Canvas", selection: $model.frame.ratio) {
                    ForEach(FrameRatio.allCases) { Text($0.label).tag($0) }
                }
                .frame(width: 150)
            }
            HStack {
                Text("Padding").foregroundStyle(.secondary)
                Slider(value: $model.frame.padding, in: 0...0.3)
                Text("Corners").foregroundStyle(.secondary)
                Slider(value: $model.frame.cornerRadius, in: 0...0.1)
                Toggle("Shadow", isOn: $model.frame.shadow)
                if #available(macOS 14.0, *) {
                    Toggle("Lift subject", isOn: $model.frame.liftSubject).help("Cut out the main subject and place it on the background")
                }
            }
        }
    }

    private func swatch<V: View>(selected: Bool, @ViewBuilder content: () -> V) -> some View {
        content()
            .frame(width: 30, height: 30)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: selected ? 3 : 1))
            .contentShape(Rectangle())
    }
}

// MARK: - Helpers

func fitRect(_ size: CGSize, in box: CGSize) -> CGRect {
    guard size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: box) }
    let s = min(box.width / size.width, box.height / size.height)
    let w = size.width * s, h = size.height * s
    return CGRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h)
}

/// Routes Delete/Backspace to `action` when no text field is editing.
struct DeleteKeyCatcher: NSViewRepresentable {
    let action: () -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            let editing = e.window?.firstResponder is NSTextView
            if !editing, e.window === v.window, e.keyCode == 51 || e.keyCode == 117 { action(); return nil }
            return e
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let m = coordinator.monitor { NSEvent.removeMonitor(m) }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var monitor: Any? }
}
