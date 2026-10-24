import AppKit

/// A radial overlay of drop targets that appears under the cursor mid-drag.
/// Each target accepts the dragged files (or a click, when opened from the menu bar).
@MainActor
final class ConversionWheel {
    static let shared = ConversionWheel()

    private var panel: NSPanel?
    private var pendingURLs: [URL] = []
    private var clickMonitor: Any?
    private var keyMonitor: Any?

    var isVisible: Bool { panel?.isVisible == true }
    private(set) var isSticky = false

    /// - Parameter sticky: keep open until a target is clicked (used after dropping on the menu bar icon).
    func show(for urls: [URL], at point: NSPoint, sticky: Bool = false) {
        hide()
        pendingURLs = urls
        isSticky = sticky
        let conversions = OperationCatalog.conversions(for: urls).map(FileOperation.convert)
        let tools = OperationCatalog.tools(for: urls)

        let size: CGFloat = 470
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let root = WheelView(frame: NSRect(x: 0, y: 0, width: size, height: size),
                             count: urls.count, conversions: conversions, tools: tools) { [weak self] op, dropped in
            guard let self else { return }
            let files = dropped.isEmpty ? self.pendingURLs : dropped
            self.hide()
            OperationRunner.shared.run(op, on: files)
        }
        panel.contentView = root

        // Center on the cursor but keep fully on screen.
        var origin = NSPoint(x: point.x - size / 2, y: point.y - size / 2)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main {
            let f = screen.visibleFrame
            origin.x = min(max(origin.x, f.minX), f.maxX - size)
            origin.y = min(max(origin.y, f.minY), f.maxY - size)
        }
        panel.setFrameOrigin(origin)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        self.panel = panel

        if sticky {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.hide() }
            }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                if e.keyCode == 53 { self?.hide(); return nil }
                return e
            }
        }
    }

    /// Writes the current wheel rendering to a PNG (debugging without screen-recording access).
    func snapshot(to url: URL) {
        guard let view = panel?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    func hide() {
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        panel?.orderOut(nil)
        panel = nil
    }
}

// MARK: - Views

private final class WheelView: NSView {
    init(frame: NSRect, count: Int, conversions: [FileOperation], tools: [FileOperation],
         action: @escaping (FileOperation, [URL]) -> Void) {
        super.init(frame: frame)
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let disc = GlassSurface.backdrop(cornerRadius: 228, tint: NSColor.windowBackgroundColor.withAlphaComponent(0.25))
        disc.frame = NSRect(x: center.x - 228, y: center.y - 228, width: 456, height: 456)
        addSubview(disc)
        addSubview(HubView(frame: NSRect(x: center.x - 44, y: center.y - 44, width: 88, height: 88), count: count))
        place(conversions, radius: 100, around: center, accent: true, action: action)
        place(tools, radius: 185, around: center, accent: false, action: action)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func place(_ ops: [FileOperation], radius: CGFloat, around c: NSPoint, accent: Bool,
                       action: @escaping (FileOperation, [URL]) -> Void) {
        guard !ops.isEmpty else { return }
        let d: CGFloat = accent ? 62 : 58
        for (i, op) in ops.enumerated() {
            let angle = CGFloat.pi / 2 - 2 * .pi * CGFloat(i) / CGFloat(ops.count)
            let p = NSPoint(x: c.x + radius * cos(angle) - d / 2, y: c.y + radius * sin(angle) - d / 2)
            let target = WheelTargetView(frame: NSRect(x: p.x, y: p.y, width: d, height: d), op: op, accent: accent)
            target.onAction = { action(op, $0) }
            addSubview(target)
        }
    }
}

/// The orange center disc showing how many files are in play.
private final class HubView: NSView {
    private let count: Int

    init(frame: NSRect, count: Int) {
        self.count = count
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let hub = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
        NSGradient(starting: .systemOrange.blended(withFraction: 0.25, of: .white) ?? .systemOrange,
                   ending: .systemOrange)?.draw(in: hub, angle: -90)
        NSColor.white.withAlphaComponent(0.45).setStroke()
        hub.stroke()
        let text = "\(count)\n\(count == 1 ? "file" : "files")" as NSString
        let para = NSMutableParagraphStyle(); para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .bold),
                                                    .foregroundColor: NSColor.white, .paragraphStyle: para]
        let size = text.boundingRect(with: bounds.size, options: .usesLineFragmentOrigin, attributes: attrs).size
        text.draw(in: NSRect(x: 0, y: bounds.midY - size.height / 2, width: bounds.width, height: size.height), withAttributes: attrs)
    }
}

private final class WheelTargetView: NSView {
    let op: FileOperation
    let accent: Bool
    var onAction: (([URL]) -> Void)?
    private var highlighted = false { didSet { needsDisplay = true } }

    init(frame: NSRect, op: FileOperation, accent: Bool) {
        self.op = op
        self.accent = accent
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        toolTip = op.title
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        // Translucent bubble with a bright rim, so the glass disc shows through.
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        let hot: NSColor = op.isDestructive ? .systemRed : .systemOrange
        let base: NSColor = accent ? .systemOrange.withAlphaComponent(0.22) : NSColor.labelColor.withAlphaComponent(0.06)
        (highlighted ? hot : base).setFill()
        circle.fill()
        NSGradient(starting: NSColor.white.withAlphaComponent(highlighted ? 0.6 : 0.5),
                   ending: NSColor.white.withAlphaComponent(0.08))?.draw(in: rim(), angle: -90)

        let fg: NSColor = highlighted ? .white : (op.isDestructive ? .systemRed : .labelColor)
        let para = NSMutableParagraphStyle(); para.alignment = .center
        if case .convert(let f) = op {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .bold),
                                                        .foregroundColor: fg, .paragraphStyle: para]
            (f.label as NSString).draw(in: NSRect(x: 0, y: bounds.midY - 9, width: bounds.width, height: 18), withAttributes: attrs)
            return
        }
        if let img = NSImage(systemSymbolName: op.symbol, accessibilityDescription: op.title)?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .medium).applying(.init(paletteColors: [fg]))) {
            let s = img.size
            img.draw(in: NSRect(x: bounds.midX - s.width / 2, y: bounds.midY - 2, width: s.width, height: s.height))
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9, weight: .medium),
                                                    .foregroundColor: fg, .paragraphStyle: para]
        (op.title as NSString).draw(in: NSRect(x: 2, y: bounds.midY - 18, width: bounds.width - 4, height: 13), withAttributes: attrs)
    }

    /// A 1pt ring path, filled with a gradient to fake a lit glass edge.
    private func rim() -> NSBezierPath {
        let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
        ring.append(NSBezierPath(ovalIn: bounds.insetBy(dx: 1.5, dy: 1.5)).reversed)
        return ring
    }

    // Drop handling
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { highlighted = true; return .copy }
    override func draggingExited(_ sender: NSDraggingInfo?) { highlighted = false }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        highlighted = false
        guard !urls.isEmpty else { return false }
        DispatchQueue.main.async { self.onAction?(urls) }
        return true
    }

    // Click handling (sticky mode)
    override func mouseEntered(with event: NSEvent) { highlighted = true }
    override func mouseExited(with event: NSEvent) { highlighted = false }
    override func mouseUp(with event: NSEvent) { onAction?([]) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
