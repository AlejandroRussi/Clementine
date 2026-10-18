import SwiftUI

@MainActor
final class CollageModel: ObservableObject {
    struct Item: Identifiable {
        let url: URL
        var id: URL { url }
        let thumb: CGImage?
    }
    @Published var items: [Item]
    @Published var options = CollageOptions() { didSet { render() } }
    @Published var preview: CGImage?
    @Published var errorMessage: String?
    private var renderTask: Task<Void, Never>?

    init(urls: [URL]) {
        items = urls.map { Item(url: $0, thumb: try? ImageEdit.load($0, maxDimension: 600)) }
        render()
    }

    func move(from: IndexSet, to: Int) {
        items.move(fromOffsets: from, toOffset: to)
        render()
    }

    func remove(_ item: Item) {
        guard items.count > 2 else { return }
        items.removeAll { $0.id == item.id }
        render()
    }

    /// Previews at 1000px wide with spacing scaled to match.
    func render() {
        renderTask?.cancel()
        var o = options
        o.spacing = options.spacing * 1000 / Double(max(options.width, 1))
        o.width = 1000
        let thumbs = items.compactMap(\.thumb)
        renderTask = Task.detached(priority: .userInitiated) {
            let img = try? ImageEdit.collage(thumbs, options: o)
            if Task.isCancelled { return }
            await MainActor.run { self.preview = img }
        }
    }

    func export() {
        let urls = items.map(\.url), options = options
        OperationRunner.shared.runTask("Creating collage") {
            let images = try urls.map { try ImageEdit.load($0, maxDimension: CGFloat(options.width)) }
            let out = try ImageEdit.collage(images, options: options)
            let dest = Output.unique(in: urls[0].deletingLastPathComponent(), base: "Collage", ext: "png")
            return [try ImageEdit.write(out, beside: dest, suffix: "", forcePNG: true)]
        }
    }
}

struct CollageView: View {
    @ObservedObject var model: CollageModel

    var body: some View {
        HSplitView {
            List {
                ForEach(model.items) { item in
                    HStack {
                        if let t = item.thumb {
                            Image(decorative: t, scale: 1).resizable().aspectRatio(contentMode: .fill)
                                .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { model.remove(item) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).disabled(model.items.count <= 2)
                    }
                }
                .onMove { model.move(from: $0, to: $1) }
            }
            .frame(minWidth: 200, idealWidth: 230, maxWidth: 300)

            VStack(spacing: 12) {
                Group {
                    if let p = model.preview { Image(decorative: p, scale: 1).resizable().aspectRatio(contentMode: .fit) }
                    else { ProgressView() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 10) {
                    Picker("Layout", selection: $model.options.style) {
                        ForEach(CollageStyle.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).fixedSize()
                    HStack {
                        Stepper(model.options.columns == 0
                                ? "Columns: Auto (\(ImageEdit.collageColumns(count: model.items.count, options: model.options)))"
                                : "Columns: \(model.options.columns)",
                                value: $model.options.columns, in: 0...max(1, model.items.count))
                        Spacer()
                        Picker("Cells", selection: $model.options.cellAspect) {
                            Text("1:1").tag(1.0); Text("4:3").tag(4.0 / 3); Text("3:4").tag(3.0 / 4); Text("16:9").tag(16.0 / 9)
                        }
                        .frame(width: 140)
                    }
                    HStack {
                        Text("Spacing")
                        Slider(value: $model.options.spacing, in: 0...80)
                        Text("\(Int(model.options.spacing)) px").monospacedDigit().frame(width: 50)
                    }
                    HStack {
                        ColorPicker("Background", selection: Binding(get: { Color(nsColor: model.options.background.nsColor) },
                                                                     set: { model.options.background = RGBA(NSColor($0)) }))
                        Spacer()
                        Picker("Output width", selection: $model.options.width) {
                            ForEach([1200, 2400, 3600, 4800], id: \.self) { Text("\($0) px").tag($0) }
                        }
                        .frame(width: 220)
                    }
                }

                HStack {
                    Text("Drag images in the list to reorder.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Save Collage") { model.export() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            .frame(minWidth: 520)
        }
        .frame(minWidth: 800, minHeight: 560)
    }
}
