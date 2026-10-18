import Foundation

enum ArchiveTools {
    static func zip(_ urls: [URL]) throws -> URL {
        let first = urls[0]
        let dir = first.deletingLastPathComponent()
        if urls.count == 1 {
            let dest = Output.unique(in: dir, base: first.lastPathComponent, ext: "zip")
            try Shell.run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-c", "-k", "--sequesterRsrc", "--keepParent", first.path, dest.path])
            return dest
        }
        let dest = Output.unique(in: dir, base: "Archive", ext: "zip")
        try Shell.run(URL(fileURLWithPath: "/usr/bin/zip"), ["-r", "-q", "-y", dest.path] + urls.map(\.lastPathComponent), cwd: dir)
        return dest
    }

    /// bsdtar reads zip, tar(.gz/.bz2/.xz), 7z and most rar files.
    static func extract(_ url: URL) throws -> URL {
        var base = url.deletingPathExtension()
        if base.pathExtension.lowercased() == "tar" { base = base.deletingPathExtension() }
        let dest = Output.unique(in: url.deletingLastPathComponent(), base: base.lastPathComponent, ext: "")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        do {
            try Shell.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-xf", url.path, "-C", dest.path])
        } catch {
            try? FileManager.default.removeItem(at: dest)
            throw error
        }
        return dest
    }
}
