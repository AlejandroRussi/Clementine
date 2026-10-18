import AppKit
import SwiftUI

final class HUDModel: ObservableObject {
    @Published var title: String
    @Published var detail = ""
    @Published var done = false
    init(title: String) { self.title = title }
}

private struct HUDView: View {
    @ObservedObject var model: HUDModel
    var body: some View {
        HStack(spacing: 12) {
            if model.done {
                Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.orange)
            } else {
                ProgressView().controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if !model.detail.isEmpty {
                    Text(model.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

/// Small non-activating panel in the top-right corner showing operation progress.
@MainActor
final class ProgressHUD {
    private let panel: NSPanel
    private let model: HUDModel

    private init(title: String) {
        model = HUDModel(title: title)
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: HUDView(model: model))
        host.frame.size = host.fittingSize
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: f.maxX - panel.frame.width - 16, y: f.maxY - 12))
        }
        panel.orderFrontRegardless()
    }

    static func show(title: String) -> ProgressHUD { ProgressHUD(title: title) }

    static func flash(_ message: String) {
        let hud = ProgressHUD(title: message)
        hud.complete(message: message)
    }

    func update(detail: String) { model.detail = detail }

    func complete(message: String) {
        model.title = message
        model.detail = ""
        model.done = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { self.close() }
    }

    func close() { panel.orderOut(nil) }
}
