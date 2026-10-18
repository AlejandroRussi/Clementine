import AVFoundation
import AppKit
import SwiftUI

/// Opens and retains editor windows (one per file).
@MainActor
enum MediaEditorController {
    private static var windows: [NSWindow] = []

    static func open(_ url: URL, tool op: FileOperation) {
        guard let tool = EditorTool(op) else { return }
        let model = MediaEditorModel(url: url, tool: tool)
        present(NSHostingController(rootView: MediaEditorView(model: model)),
                title: url.lastPathComponent, size: NSSize(width: 820, height: 620)) { model.teardown() }
    }

    static func openImage(_ urls: [URL], tool op: FileOperation) {
        guard let tool = ImageTool(op) else { return }
        let model = ImageEditorModel(urls: urls, tool: tool)
        present(NSHostingController(rootView: ImageEditorView(model: model)),
                title: urls[0].lastPathComponent, size: NSSize(width: 860, height: 680)) {}
    }

    static func openCollage(_ urls: [URL]) {
        let model = CollageModel(urls: OperationRunner.finderOrder(urls))
        present(NSHostingController(rootView: CollageView(model: model)),
                title: "Collage of \(urls.count) Images", size: NSSize(width: 920, height: 640)) {}
    }

    static func openJoin(_ urls: [URL]) {
        let model = JoinModel(urls: OperationRunner.finderOrder(urls))
        present(NSHostingController(rootView: JoinEditorView(model: model)),
                title: "Join \(urls.count) Videos", size: NSSize(width: 520, height: 460)) {}
    }

    private static func present(_ controller: NSViewController, title: String, size: NSSize, onClose: @escaping () -> Void) {
        let window = NSWindow(contentViewController: controller)
        window.title = title
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        window.center()
        windows.append(window)
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated {
                onClose()
                windows.removeAll { $0 === window }
                if let token { NotificationCenter.default.removeObserver(token) }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Join

@MainActor
final class JoinModel: ObservableObject {
    struct Clip: Identifiable {
        let url: URL
        var id: URL { url }
        var thumbnail: CGImage?
        var duration: Double = 0
    }
    @Published var clips: [Clip]

    init(urls: [URL]) {
        clips = urls.map { Clip(url: $0) }
        Task { await load() }
    }

    private func load() async {
        for i in clips.indices {
            let asset = AVURLAsset(url: clips[i].url)
            clips[i].duration = (try? await asset.load(.duration).seconds) ?? 0
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 160, height: 160)
            clips[i].thumbnail = try? await gen.image(at: CMTime(seconds: min(1, clips[i].duration / 2), preferredTimescale: 600)).image
        }
    }

    var total: Double { clips.reduce(0) { $0 + $1.duration } }

    func export() {
        let urls = clips.map(\.url)
        OperationRunner.shared.runTask("Join – \(urls.count) videos") { [try await VideoEdit.join(urls)] }
    }
}

struct JoinEditorView: View {
    @ObservedObject var model: JoinModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Drag to reorder. Clips are joined top to bottom and fitted to the first clip's frame.")
                .font(.callout).foregroundStyle(.secondary)
            List {
                ForEach(model.clips) { clip in
                    HStack(spacing: 10) {
                        Group {
                            if let t = clip.thumbnail { Image(decorative: t, scale: 1).resizable().aspectRatio(contentMode: .fill) }
                            else { Color.gray.opacity(0.3) }
                        }
                        .frame(width: 72, height: 44).clipShape(RoundedRectangle(cornerRadius: 4))
                        Text(clip.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(formatTime(clip.duration)).monospacedDigit().foregroundStyle(.secondary)
                        Button { model.clips.removeAll { $0.id == clip.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .disabled(model.clips.count <= 2)
                    }
                }
                .onMove { model.clips.move(fromOffsets: $0, toOffset: $1) }
            }
            HStack {
                Text("Total \(formatTime(model.total))").monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Button("Save Joined Video") { model.export() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.clips.count < 2)
            }
        }
        .padding(16)
        .frame(minWidth: 460, minHeight: 360)
    }
}
