import AVFoundation
import ImageIO
import UniformTypeIdentifiers

enum MediaTools {
    // MARK: Export helpers

    private static func export(_ asset: AVAsset, preset: String, to dest: URL, type: AVFileType,
                               configure: ((AVAssetExportSession) -> Void)? = nil) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ToolError("This file cannot be exported with AVFoundation.")
        }
        session.outputURL = dest
        session.outputFileType = type
        session.shouldOptimizeForNetworkUse = true
        configure?(session)
        await session.export()
        if session.status != .completed {
            try? FileManager.default.removeItem(at: dest)
            throw ToolError(session.error?.localizedDescription ?? "The export did not finish.")
        }
    }

    private static func ffmpeg(_ args: [String]) throws {
        guard let ff = ExternalTools.ffmpeg else {
            throw ToolError("This format needs ffmpeg (brew install ffmpeg).")
        }
        try Shell.run(ff, ["-hide_banner", "-loglevel", "error", "-y"] + args)
    }

    // MARK: Conversion

    static func convert(_ url: URL, to format: OutputFormat) async throws -> URL {
        let dest = Output.beside(url, ext: format.rawValue)
        let native = ["mp4", "mov", "m4v", "m4a", "mp3", "wav", "aif", "aiff", "caf", "aac"].contains(url.pathExtension.lowercased())

        // Anything AVFoundation can't read, or can't write, goes to ffmpeg when present.
        if !native || [.mp3, .flac].contains(format) {
            var args = ["-i", url.path]
            switch format {
            case .mp3: args += ["-vn", "-codec:a", "libmp3lame", "-q:a", "2"]
            case .flac: args += ["-vn", "-codec:a", "flac"]
            case .m4a: args += ["-vn", "-codec:a", "aac", "-b:a", "192k"]
            case .wav: args += ["-vn"]
            case .aiff: args += ["-vn"]
            case .mp4, .mov: args += ["-c:v", "libx264", "-crf", "20", "-pix_fmt", "yuv420p", "-c:a", "aac"]
            default: throw ToolError("Unsupported media format.")
            }
            try ffmpeg(args + [dest.path])
            return dest
        }

        let asset = AVURLAsset(url: url)
        switch format {
        case .mp4:
            try await export(asset, preset: AVAssetExportPresetHighestQuality, to: dest, type: .mp4)
        case .mov:
            try await export(asset, preset: AVAssetExportPresetHighestQuality, to: dest, type: .mov)
        case .m4a:
            try await export(asset, preset: AVAssetExportPresetAppleM4A, to: dest, type: .m4a)
        case .wav, .aiff:
            try pcm(url, to: dest, aiff: format == .aiff)
        default:
            throw ToolError("Unsupported media format.")
        }
        return dest
    }

    /// Decodes the audio track to uncompressed 16-bit PCM.
    private static func pcm(_ url: URL, to dest: URL, aiff: Bool) throws {
        let input = try AVAudioFile(forReading: url)
        let fmt = input.processingFormat
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: fmt.sampleRate,
            AVNumberOfChannelsKey: fmt.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: aiff,
        ]
        if aiff { settings[AVLinearPCMIsNonInterleaved] = false }
        let output = try AVAudioFile(forWriting: dest, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 65536) else { throw ToolError("Audio buffer failed.") }
        while input.framePosition < input.length {
            try input.read(into: buffer)
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
        }
    }

    // MARK: Tools

    static func compressVideo(_ url: URL, strength: CompressionStrength) async throws -> URL {
        let dest = Output.beside(url, ext: "mp4", suffix: " compressed")
        let preset: String = switch strength {
        case .light: AVAssetExportPresetHEVCHighestQuality
        case .balanced: AVAssetExportPresetHEVC1920x1080
        case .strong: AVAssetExportPreset1280x720
        }
        try await export(AVURLAsset(url: url), preset: preset, to: dest, type: .mp4)
        try ImageTools.ensureSmaller(dest, than: url)
        return dest
    }

    static func extractAudio(_ url: URL) async throws -> URL {
        let dest = Output.beside(url, ext: "m4a")
        try await export(AVURLAsset(url: url), preset: AVAssetExportPresetAppleM4A, to: dest, type: .m4a)
        return dest
    }

    static func mute(_ url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let comp = AVMutableComposition()
        let duration = try await asset.load(.duration)
        for track in try await asset.loadTracks(withMediaType: .video) {
            let t = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            try t?.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
            t?.preferredTransform = try await track.load(.preferredTransform)
        }
        let dest = Output.beside(url, ext: url.pathExtension.lowercased() == "mov" ? "mov" : "mp4", suffix: " muted")
        try await export(comp, preset: AVAssetExportPresetPassthrough, to: dest, type: dest.pathExtension == "mov" ? .mov : .mp4)
        return dest
    }

    static func stripMetadata(_ url: URL) async throws -> URL {
        let ext = url.pathExtension.lowercased()
        let type: AVFileType = switch ext { case "mov": .mov; case "m4a": .m4a; default: .mp4 }
        let dest = Output.beside(url, ext: ext == "mov" || ext == "m4a" ? ext : "mp4", suffix: " clean")
        try await export(AVURLAsset(url: url), preset: AVAssetExportPresetPassthrough, to: dest, type: type) {
            $0.metadata = []
            $0.metadataItemFilter = .forSharing()
        }
        return dest
    }

    /// Animated GIF at 10 fps, max 480px wide, first 15 seconds.
    static func gif(_ url: URL, fps: Double = 10, maxWidth: CGFloat = 480, maxSeconds: Double = 15) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let duration = min(try await asset.load(.duration).seconds, maxSeconds)
        guard duration > 0 else { throw ToolError("This file has no playable duration.") }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxWidth, height: maxWidth * 4)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)

        let count = max(1, Int(duration * fps))
        let dest = Output.beside(url, ext: "gif")
        guard let out = CGImageDestinationCreateWithURL(dest as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw ToolError("Could not create the GIF.")
        }
        CGImageDestinationSetProperties(out, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / fps]] as CFDictionary
        for i in 0..<count {
            let time = CMTime(seconds: Double(i) / fps, preferredTimescale: 600)
            let img = try await gen.image(at: time).image
            CGImageDestinationAddImage(out, img, frameProps)
        }
        guard CGImageDestinationFinalize(out) else { throw ToolError("Could not finish the GIF.") }
        return dest
    }
}
