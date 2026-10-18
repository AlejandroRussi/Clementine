import Foundation
import ImageIO

struct ToolError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum ExternalTools {
    private static func find(_ name: String) -> URL? {
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }
    static let ffmpeg = find("ffmpeg")
    static let cwebp = find("cwebp")
    static let canWriteWebP = cwebp != nil
        || ((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []).contains("org.webmproject.webp")
}

enum Output {
    /// A non-colliding URL beside `source`: "name.ext", then "name 2.ext", ...
    static func beside(_ source: URL, ext: String, suffix: String = "") -> URL {
        let dir = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent + suffix
        return unique(in: dir, base: base, ext: ext)
    }

    static func unique(in dir: URL, base: String, ext: String) -> URL {
        let fm = FileManager.default
        func make(_ n: Int) -> URL {
            let name = n == 1 ? base : "\(base) \(n)"
            return ext.isEmpty ? dir.appendingPathComponent(name) : dir.appendingPathComponent(name).appendingPathExtension(ext)
        }
        var n = 1
        while fm.fileExists(atPath: make(n).path) { n += 1 }
        return make(n)
    }
}

enum Shell {
    /// Runs a process and throws with its stderr on non-zero exit.
    @discardableResult
    static func run(_ exe: URL, _ args: [String], cwd: URL? = nil) throws -> String {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ToolError("\(exe.lastPathComponent) failed: \(msg.suffix(300))")
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }
}
