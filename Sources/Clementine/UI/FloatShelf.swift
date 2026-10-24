import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// "Float": an always-on-top shelf that holds file references for later dragging.
final class FloatModel: ObservableObject {
    @Published var items: [URL] = []
    @Published var selection: Set<URL> = []

    func add(_ urls: [URL]) {
        for u in urls where !items.contains(u) { items.append(u) }
    }
    func remove(_ urls: [URL]) {
        items.removeAll { urls.contains($0) }
        selection.subtract(urls)
    }
    /// Files the context menu should act on: the selection if it includes the clicked item.
    func targets(for url: URL) -> [URL] {
        selection.contains(url) ? items.filter(selection.contains) : [url]
    }
}

@MainActor
final class FloatController: NSObject, NSWindowDelegate {
    static let shared = FloatController()
    private var panel: NSPanel?
    let model = FloatModel()

    func add(_ urls: [URL]) {
        model.add(urls)
        show()
    }

    func show() {
        if panel == nil { makePanel() }
        panel?.orderFrontRegardless()
    }

    func close() {
        panel?.orderOut(nil)
        model.items.removeAll()
        model.selection.removeAll()
    }

    private func makePanel() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 320),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel, .fullSizeContentView],
                        backing: .buffered, defer: false)
        p.title = "Float"
        p.titlebarAppearsTransparent = true
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = true
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.delegate = self
        p.isOpaque = false
        p.backgroundColor = .clear
        let host = NSHostingView(rootView: FloatView(model: model, onClose: { [weak self] in self?.close() }))
        p.contentView = GlassSurface.backdrop(cornerRadius: 16, content: host)
        if let f = NSScreen.main?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: f.maxX - 260, y: f.midY - 160))
        }
        panel = p
    }

    func windowWillClose(_ notification: Notification) {
        model.items.removeAll()
        model.selection.removeAll()
    }
}

private struct FloatView: View {
    @ObservedObject var model: FloatModel
    let onClose: () -> Void
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 0) {
            if model.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Drop files here").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(model.items, id: \.self) { url in
                            FloatRow(url: url, selected: model.selection.contains(url))
                                .onTapGesture {
                                    if NSEvent.modifierFlags.contains(.command) {
                                        model.selection.formSymmetricDifference([url])
                                    } else {
                                        model.selection = [url]
                                    }
                                }
                                .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
                                .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
                                .contextMenu { menu(for: url) }
                        }
                    }
                    .padding(8)
                }
                HStack {
                    Text("\(model.items.count) item\(model.items.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear", action: onClose).buttonStyle(.borderless).font(.caption)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
            }
        }
        .padding(.top, 22)
        .frame(minWidth: 200, minHeight: 200)
        .background(targeted ? Color.orange.opacity(0.15) : Color.clear)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { model.add([url]) } }
                }
            }
            return true
        }
    }

    @ViewBuilder
    private func menu(for url: URL) -> some View {
        let urls = model.targets(for: url)
        Button("Open") { urls.forEach { NSWorkspace.shared.open($0) } }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        Button("Quick Look") { QuickLook.shared.preview(urls) }
        Divider()
        Button("Copy") { Task { @MainActor in OperationRunner.shared.copyFiles(urls) } }
        Button("Copy Path") { Task { @MainActor in OperationRunner.shared.copyPaths(urls) } }
        Button("AirDrop…") { Task { @MainActor in OperationRunner.shared.share(urls) } }
        Button("Move To…") { FileActions.move(urls) { moved in model.remove(urls); model.add(moved) } }
        Button("Open Terminal Here") { FileActions.openTerminal(at: url) }
        Menu("Tools") {
            ForEach(OperationCatalog.conversions(for: urls), id: \.self) { f in
                Button("Convert to \(f.label)") { Task { @MainActor in OperationRunner.shared.run(.convert(f), on: urls) } }
            }
            Divider()
            ForEach(OperationCatalog.tools(for: urls).filter { $0 != .addToFloat }, id: \.self) { op in
                Button(op.title) { Task { @MainActor in OperationRunner.shared.run(op, on: urls) } }
            }
        }
        Divider()
        Button("Remove from Float") { model.remove(urls) }
        Button("Shred", role: .destructive) {
            Task { @MainActor in
                model.remove(urls)
                Shredder.shared.shred(urls)
            }
        }
    }
}

private struct FloatRow: View {
    let url: URL
    let selected: Bool
    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                Text(sizeText).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .background(selected ? Color.accentColor.opacity(0.3) : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
    }
    private var sizeText: String {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return FileKind.of(url) == .folder ? "Folder" : ""
        }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

// MARK: - File actions

enum FileActions {
    static func move(_ urls: [URL], completion: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Move Here"
        panel.message = "Move \(urls.count) item\(urls.count == 1 ? "" : "s") to a chosen folder"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        var moved: [URL] = []
        for u in urls {
            let dest = Output.unique(in: dir, base: u.deletingPathExtension().lastPathComponent, ext: u.pathExtension)
            if (try? FileManager.default.moveItem(at: u, to: dest)) != nil { moved.append(dest) }
        }
        if moved.count < urls.count { NSSound.beep() }
        completion(moved)
    }

    static func openTerminal(at url: URL) {
        let dir = FileKind.of(url) == .folder ? url : url.deletingLastPathComponent()
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([dir], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }
}
