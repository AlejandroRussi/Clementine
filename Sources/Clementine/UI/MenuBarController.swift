import AppKit

/// Status item with a menu, which also accepts file drops to open the wheel.
@MainActor
final class MenuBarController: NSObject, NSMenuItemValidation {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    override init() {
        super.init()
        guard let button = item.button else { return }
        button.image = NSImage(systemSymbolName: "circle.hexagongrid.circle", accessibilityDescription: "Clementine")
        let drop = StatusDropView(frame: button.bounds)
        drop.autoresizingMask = [.width, .height]
        drop.onDrop = { urls in ConversionWheel.shared.show(for: urls, at: NSEvent.mouseLocation, sticky: true) }
        drop.onClick = { [weak self] in self?.item.button?.performClick(nil) }
        button.addSubview(drop)
        item.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Choose Files…", action: #selector(chooseFiles), keyEquivalent: "o").target = self
        menu.addItem(withTitle: "Create a New Float", action: #selector(newFloat), keyEquivalent: "f").target = self
        menu.addItem(withTitle: "Undo Shred", action: #selector(undoShred), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Getting Started", action: #selector(welcome), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(settings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Clementine", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    @objc private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let screen = NSScreen.main?.visibleFrame ?? .zero
        ConversionWheel.shared.show(for: panel.urls, at: NSPoint(x: screen.midX, y: screen.midY), sticky: true)
    }

    @objc private func newFloat() { FloatController.shared.show() }
    @objc private func undoShred() { Shredder.shared.undo() }
    @objc private func welcome() { Windows.showWelcome() }
    @objc private func settings() { Windows.showSettings() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(undoShred) ? Shredder.shared.canUndo : true
    }
}

/// Transparent overlay on the status button that receives dragged files
/// and forwards clicks to the button so the menu still opens.
private final class StatusDropView: NSView {
    var onDrop: (([URL]) -> Void)?
    var onClick: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { return false }
        DispatchQueue.main.async { self.onDrop?(urls) }
        return true
    }
}
