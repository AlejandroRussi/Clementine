import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?
    private let monitor = DragGestureMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar = MenuBarController()

        monitor.onTrigger = { urls, point in
            ConversionWheel.shared.show(for: urls, at: point)
        }
        monitor.onDragEnded = {
            // Let a pending drop land on a wheel target before tearing it down.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if !ConversionWheel.shared.isSticky { ConversionWheel.shared.hide() }
            }
        }
        monitor.start()

        // Debug aid: `--show-wheel <file>...` opens the wheel in click mode at screen center.
        if let i = CommandLine.arguments.firstIndex(of: "--show-wheel") {
            let urls = CommandLine.arguments[(i + 1)...].map { URL(fileURLWithPath: $0) }
            let f = NSScreen.main?.visibleFrame ?? .zero
            ConversionWheel.shared.show(for: Array(urls), at: NSPoint(x: f.midX, y: f.midY), sticky: true)
            if let path = ProcessInfo.processInfo.environment["CLEMENTINE_SNAPSHOT"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    ConversionWheel.shared.snapshot(to: URL(fileURLWithPath: path))
                }
            }
        } else if let i = CommandLine.arguments.firstIndex(of: "--open-editor"), CommandLine.arguments.count > i + 2 {
            // Debug aid: `--open-editor <trim|split|speed|crop|normalize|channels|join> <file>...`
            let args = CommandLine.arguments
            let urls = args[(i + 2)...].map { URL(fileURLWithPath: $0) }
            let ops: [String: FileOperation] = ["trim": .trim, "split": .split, "speed": .changeSpeed, "crop": .crop,
                                                "normalize": .normalizeAudio, "channels": .audioChannels, "join": .join,
                                                "annotate": .annotate, "redact": .redact, "background": .background,
                                                "collage": .collage]
            if let op = ops[args[i + 1]] { OperationRunner.shared.run(op, on: Array(urls)) }
            if let path = ProcessInfo.processInfo.environment["CLEMENTINE_SNAPSHOT"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    guard let view = NSApp.windows.first(where: { $0.isVisible && $0.contentViewController != nil })?.contentView,
                          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
            }
        } else if !Settings.shared.hasSeenWelcome {
            Windows.showWelcome()
        }
    }
}
