import AppKit
import Carbon.HIToolbox

/// Shred: moves files out of sight at once, offers Undo (⌘Z) for 30 seconds,
/// then overwrites their contents with random data and deletes them.
///
/// Staged items live in a per-item "replacement" folder on the same volume, so moving
/// them away and back is an instant rename. Staging folders are remembered in
/// UserDefaults so a crash mid-window still gets them erased on the next launch.
@MainActor
final class Shredder {
    static let shared = Shredder()
    static let undoSeconds = 30

    private struct Item { let original: URL; let staged: URL; let folder: URL }
    private struct Batch { let items: [Item]; let deadline: Date }

    private var batches: [Batch] = []   // oldest first; ⌘Z restores the last
    private var hud: ProgressHUD?
    private var timer: Timer?
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private let defaultsKey = "pendingShredFolders"

    var canUndo: Bool { !batches.isEmpty }

    func shred(_ urls: [URL]) {
        var items: [Item] = [], failures: [String] = []
        for url in urls {
            do { items.append(try stage(url)) }
            catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        if !failures.isEmpty { alert("Some items could not be shredded", failures) }
        guard !items.isEmpty else { return }
        batches.append(Batch(items: items, deadline: Date().addingTimeInterval(TimeInterval(Self.undoSeconds))))
        persist()
        registerHotKey()
        showHUD()
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
                MainActor.assumeIsolated { Shredder.shared.tick() }
            }
        }
    }

    /// Puts the most recent shred back where it came from.
    func undo() {
        guard let batch = batches.popLast() else { return }
        var restored = 0
        for item in batch.items {
            let fm = FileManager.default
            let dir = item.original.deletingLastPathComponent()
            var dest = item.original
            if fm.fileExists(atPath: dest.path) {
                dest = Output.unique(in: dir, base: dest.deletingPathExtension().lastPathComponent, ext: dest.pathExtension)
            }
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try fm.moveItem(at: item.staged, to: dest)
                try? fm.removeItem(at: item.folder)
                restored += 1
            } catch {
                // Couldn't restore: leave it staged so it is still erased later.
                batches.insert(Batch(items: [item], deadline: Date()), at: 0)
            }
        }
        persist()
        hud?.close(); hud = nil
        ProgressHUD.flash("Restored \(restored) item\(restored == 1 ? "" : "s")")
        if batches.isEmpty { stopWaiting() } else { showHUD() }
    }

    /// Erases everything still pending, now (used when the app quits).
    func finalizeAll() {
        let items = batches.flatMap(\.items)
        batches.removeAll()
        stopWaiting()
        _ = Self.erase(items.map(\.folder))
        persist()
    }

    /// Erases staging folders left behind by a crash or forced quit.
    func sweepLeftovers() {
        let folders = (UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []).map { URL(fileURLWithPath: $0) }
        guard !folders.isEmpty else { return }
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        Task.detached(priority: .utility) { _ = Self.erase(folders) }
    }

    // MARK: Staging

    private func stage(_ url: URL) throws -> Item {
        let url = url.standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let isVolume = (try? url.resourceValues(forKeys: [.isVolumeKey]).isVolume) ?? false
        if url.path == "/" || url == home || isVolume { throw ToolError("This location can't be shredded.") }
        guard FileManager.default.fileExists(atPath: url.path) else { throw ToolError("The file no longer exists.") }
        let folder = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                 appropriateFor: url, create: true)
        let staged = folder.appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: url, to: staged)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return Item(original: url, staged: staged, folder: folder)
    }

    private func persist() {
        UserDefaults.standard.set(batches.flatMap(\.items).map(\.folder.path), forKey: defaultsKey)
    }

    // MARK: Countdown

    private func tick() {
        let now = Date()
        let expired = batches.filter { $0.deadline <= now }
        if !expired.isEmpty {
            batches.removeAll { $0.deadline <= now }
            let folders = expired.flatMap(\.items).map(\.folder)
            Task.detached(priority: .utility) {
                let failures = Self.erase(folders)
                await MainActor.run {
                    Shredder.shared.persist()
                    if !failures.isEmpty { Shredder.shared.alert("Some items could not be fully shredded", failures) }
                }
            }
        }
        guard let latest = batches.last else {
            if !expired.isEmpty {
                hud?.complete(message: "Shredded")
                hud = nil
            }
            stopWaiting()
            return
        }
        hud?.setUndoRemaining(max(0, Int(latest.deadline.timeIntervalSince(now).rounded(.up))))
    }

    private func showHUD() {
        guard let latest = batches.last else { return }
        hud?.close()
        let n = latest.items.count
        let title = n == 1 ? "Shredded “\(latest.items[0].original.lastPathComponent)”" : "Shredded \(n) items"
        hud = ProgressHUD.offerUndo(title, detail: "Erased when timer ends",
                                    seconds: max(0, Int(latest.deadline.timeIntervalSinceNow.rounded(.up)))) {
            MainActor.assumeIsolated { Shredder.shared.undo() }
        }
    }

    private func stopWaiting() {
        timer?.invalidate(); timer = nil
        unregisterHotKey()
        if batches.isEmpty { hud?.close(); hud = nil }
    }

    private func alert(_ title: String, _ lines: [String]) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = lines.prefix(8).joined(separator: "\n")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: ⌘Z hot key (registered only while an undo is pending)

    private func registerHotKey() {
        guard hotKey == nil else { return }
        if hotKeyHandler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                MainActor.assumeIsolated { Shredder.shared.undo() }
                return noErr
            }, 1, &spec, nil, &hotKeyHandler)
        }
        let id = EventHotKeyID(signature: OSType(0x434C_4D5A), id: 1) // "CLMZ"
        RegisterEventHotKey(UInt32(kVK_ANSI_Z), UInt32(cmdKey), id, GetApplicationEventTarget(), 0, &hotKey)
    }

    private func unregisterHotKey() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }

    // MARK: Erasing

    /// Overwrites and removes each folder's contents; returns failure messages.
    nonisolated static func erase(_ folders: [URL]) -> [String] {
        var failures: [String] = []
        for folder in folders where FileManager.default.fileExists(atPath: folder.path) {
            do { try erase(item: folder) }
            catch { failures.append("\(folder.lastPathComponent): \(error.localizedDescription)") }
        }
        return failures
    }

    /// Overwrites every regular file under `url` once with random bytes, flushes to disk, then deletes.
    /// Symbolic links are removed, never followed.
    nonisolated static func erase(item url: URL) throws {
        let fm = FileManager.default
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
        if values.isSymbolicLink != true {
            if values.isDirectory == true {
                try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
                for child in try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) { try erase(item: child) }
            } else if values.isRegularFile == true {
                try overwrite(url)
            }
        }
        try fm.removeItem(at: url)
    }

    nonisolated private static func overwrite(_ url: URL) throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600, .immutable: false], ofItemAtPath: url.path)
        let fd = open(url.path, O_WRONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw ToolError("Could not open \(url.lastPathComponent) for erasing.") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw ToolError("Could not read \(url.lastPathComponent).") }
        let size = Int(info.st_size)
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        var offset = 0
        while offset < size {
            let n = min(buffer.count, size - offset)
            let written = buffer.withUnsafeMutableBytes { raw -> Int in
                arc4random_buf(raw.baseAddress, n)
                return pwrite(fd, raw.baseAddress, n, off_t(offset))
            }
            guard written == n else { throw ToolError("Could not overwrite \(url.lastPathComponent).") }
            offset += n
        }
        _ = fcntl(fd, F_FULLFSYNC)
        _ = ftruncate(fd, 0)
    }
}
