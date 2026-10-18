import AppKit

/// Detects "user is dragging files and taps the trigger modifiers".
///
/// Polls global mouse/modifier state and the system drag pasteboard instead of
/// installing event taps, so it needs no Accessibility permission.
@MainActor
final class DragGestureMonitor {
    var onTrigger: ((_ urls: [URL], _ location: NSPoint) -> Void)?
    var onDragEnded: (() -> Void)?

    private var timer: Timer?
    private let dragPasteboard = NSPasteboard(name: .drag)
    private var mouseWasDown = false
    private var countAtMouseDown = 0
    private var triggerWasHeld = false
    private var firedThisDrag = false

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func tick() {
        let mouseDown = NSEvent.pressedMouseButtons & 1 == 1
        defer { mouseWasDown = mouseDown }

        if mouseDown && !mouseWasDown {
            countAtMouseDown = dragPasteboard.changeCount
            firedThisDrag = false
            triggerWasHeld = currentFlagsMatch()
        }
        if !mouseDown {
            if mouseWasDown { onDragEnded?() }
            return
        }
        // A new drag session writes to the drag pasteboard after the mouse goes down.
        guard dragPasteboard.changeCount != countAtMouseDown else { return }

        let held = currentFlagsMatch()
        defer { triggerWasHeld = held }
        guard held, !triggerWasHeld, !firedThisDrag else { return }

        let urls = (dragPasteboard.readObjects(forClasses: [NSURL.self],
                                               options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { return }
        firedThisDrag = true
        onTrigger?(urls, NSEvent.mouseLocation)
    }

    private func currentFlagsMatch() -> Bool {
        let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        return NSEvent.modifierFlags.intersection(relevant) == Settings.shared.trigger.flags
    }
}
