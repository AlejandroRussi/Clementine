import AppKit
import SwiftUI

final class HUDModel: ObservableObject {
    @Published var title: String
    @Published var detail = ""
    @Published var done = false
    /// Seconds left on an undo offer; nil for ordinary progress HUDs.
    @Published var undoRemaining: Int?
    var onUndo: (() -> Void)?
    init(title: String) { self.title = title }
}

private struct HUDView: View {
    @ObservedObject var model: HUDModel
    var body: some View {
        HStack(spacing: 12) {
            if model.undoRemaining != nil {
                Image(systemName: "flame.fill").font(.title2).foregroundStyle(.red)
            } else if model.done {
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
            if let remaining = model.undoRemaining {
                Button { model.onUndo?() } label: {
                    Text("Undo ⌘Z · \(remaining)s").monospacedDigit()
                }
                .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 320)
        .clearGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
        panel.contentView = NSHostingView(rootView: HUDView(model: model))
        resize()
        panel.orderFrontRegardless()
    }

    private func resize() {
        guard let host = panel.contentView else { return }
        host.frame.size = host.fittingSize
        panel.setContentSize(host.fittingSize)
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: f.maxX - panel.frame.width - 16, y: f.maxY - 12))
        }
    }

    static func show(title: String) -> ProgressHUD { ProgressHUD(title: title) }

    /// A clickable HUD that counts down `seconds`, offering Undo until it expires.
    static func offerUndo(_ message: String, detail: String, seconds: Int, onUndo: @escaping () -> Void) -> ProgressHUD {
        let hud = ProgressHUD(title: message)
        hud.panel.ignoresMouseEvents = false
        hud.model.detail = detail
        hud.model.undoRemaining = seconds
        hud.model.onUndo = onUndo
        hud.resize()
        return hud
    }

    /// Updates the countdown shown on an undo HUD.
    func setUndoRemaining(_ seconds: Int) { model.undoRemaining = seconds }

    static func flash(_ message: String) {
        let hud = ProgressHUD(title: message)
        hud.complete(message: message)
    }

    func update(detail: String) { model.detail = detail }

    func complete(message: String) {
        model.title = message
        model.detail = ""
        model.done = true
        model.undoRemaining = nil
        panel.ignoresMouseEvents = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { self.close() }
    }

    func close() { panel.orderOut(nil) }
}
