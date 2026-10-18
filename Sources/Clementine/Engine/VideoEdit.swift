import AVFoundation

/// Timeline edits for video: trim, split, join, speed and crop.
enum VideoEdit {
    static let minimumSplitGap = 0.05
    static let speedRange: ClosedRange<Double> = 0.25...4

    // MARK: Helpers

    private static func fileType(for url: URL) -> (AVFileType, String) {
        switch url.pathExtension.lowercased() {
        case "mov": return (.mov, "mov")
        case "m4v": return (.m4v, "m4v")
        default: return (.mp4, "mp4")
        }
    }

    private static func export(_ asset: AVAsset, to dest: URL, type: AVFileType, preset: String,
                               timeRange: CMTimeRange? = nil, videoComposition: AVVideoComposition? = nil,
                               spectralPitch: Bool = false) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ToolError("This video cannot be exported.")
        }
        session.outputURL = dest
        session.outputFileType = type
        session.shouldOptimizeForNetworkUse = true
        if let timeRange { session.timeRange = timeRange }
        if let videoComposition { session.videoComposition = videoComposition }
        if spectralPitch { session.audioTimePitchAlgorithm = .spectral }
        await session.export()
        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: dest)
            throw ToolError(session.error?.localizedDescription ?? "The export did not finish.")
        }
    }

    static func cmTime(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }

    static func duration(_ url: URL) async throws -> Double {
        let d = try await AVURLAsset(url: url).load(.duration).seconds
        guard d.isFinite, d > 0 else { throw ToolError("This file has no playable duration.") }
        return d
    }

    /// Copies the given source ranges, back to back, into a new composition.
    private static func composition(of asset: AVAsset, ranges: [CMTimeRange]) async throws -> AVMutableComposition {
        let comp = AVMutableComposition()
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let sourceVideo = videoTracks.first else { throw ToolError("This file has no playable video track.") }
        let v = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        v?.preferredTransform = try await sourceVideo.load(.preferredTransform)
        let a = audioTracks.isEmpty ? nil : comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        var cursor = CMTime.zero
        for r in ranges {
            try v?.insertTimeRange(r, of: sourceVideo, at: cursor)
            if let a, let src = audioTracks.first { try a.insertTimeRange(r, of: src, at: cursor) }
            cursor = cursor + r.duration
        }
        return comp
    }

    // MARK: Trim

    static func trim(_ url: URL, start: Double, end: Double) async throws -> URL {
        let total = try await duration(url)
        guard start >= 0, end <= total + 0.01, end - start >= minimumSplitGap else {
            throw ToolError("Set a start and end within the file.")
        }
        let (type, ext) = fileType(for: url)
        let dest = Output.beside(url, ext: ext, suffix: " trimmed")
        try await export(AVURLAsset(url: url), to: dest, type: type, preset: AVAssetExportPresetPassthrough,
                         timeRange: CMTimeRange(start: cmTime(start), end: cmTime(end)))
        return dest
    }

    // MARK: Split

    enum SplitExportMode: String, CaseIterable, Identifiable {
        case separate, joined
        var id: String { rawValue }
        var label: String { self == .separate ? "Separate clips" : "One video" }
    }

    /// Clip ranges produced by split points across a duration.
    static func clips(splitPoints: [Double], duration: Double) -> [ClosedRange<Double>] {
        let cuts = [0] + splitPoints.sorted().filter { $0 > 0 && $0 < duration } + [duration]
        return zip(cuts, cuts.dropFirst()).map { $0...$1 }
    }

    static func validateSplitPoints(_ points: [Double], duration: Double) throws {
        let sorted = points.sorted()
        guard !sorted.isEmpty else { throw ToolError("Add split points inside the video.") }
        for p in sorted where p < minimumSplitGap || p > duration - minimumSplitGap {
            throw ToolError("Add split points inside the video, at least 0.05 seconds from either end.")
        }
        for (a, b) in zip(sorted, sorted.dropFirst()) where b - a < minimumSplitGap {
            throw ToolError("Split points must be at least 0.05 seconds apart.")
        }
    }

    /// Separate: one file per kept clip, in a folder. Joined: kept clips back to back in one file.
    static func split(_ url: URL, at points: [Double], removing removed: Set<Int> = [],
                      mode: SplitExportMode) async throws -> [URL] {
        let total = try await duration(url)
        if !(points.isEmpty && !removed.isEmpty) { try validateSplitPoints(points, duration: total) }
        let all = clips(splitPoints: points, duration: total)
        let kept = all.enumerated().filter { !removed.contains($0.offset) }
        guard !kept.isEmpty else { throw ToolError("Keep at least one clip.") }
        let asset = AVURLAsset(url: url)
        let (type, ext) = fileType(for: url)

        switch mode {
        case .separate:
            let folder = Output.beside(url, ext: "", suffix: " clips")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let base = url.deletingPathExtension().lastPathComponent
            for (index, clip) in kept {
                let dest = folder.appendingPathComponent("\(base) – clip \(index + 1).\(ext)")
                try await export(asset, to: dest, type: type, preset: AVAssetExportPresetPassthrough,
                                 timeRange: CMTimeRange(start: cmTime(clip.lowerBound), end: cmTime(clip.upperBound)))
            }
            return [folder]
        case .joined:
            guard kept.count < all.count else { throw ToolError("Remove a clip to join the rest into one video.") }
            let ranges = kept.map { CMTimeRange(start: cmTime($0.element.lowerBound), end: cmTime($0.element.upperBound)) }
            let comp = try await composition(of: asset, ranges: ranges)
            let dest = Output.beside(url, ext: ext, suffix: " edited")
            try await export(comp, to: dest, type: type, preset: AVAssetExportPresetHighestQuality)
            return [dest]
        }
    }

    // MARK: Join

    /// Concatenates videos in order. Every clip is fitted (letterboxed) into the first clip's frame.
    static func join(_ urls: [URL]) async throws -> URL {
        guard urls.count >= 2 else { throw ToolError("Select at least two videos to join.") }
        let comp = AVMutableComposition()
        guard let video = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audio = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ToolError("Could not prepare the joined video.")
        }
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: video)
        var renderSize: CGSize?
        var frameRate: Float = 30
        var cursor = CMTime.zero

        for url in urls {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            guard let src = try await asset.loadTracks(withMediaType: .video).first else {
                throw ToolError("Every selected file must contain a video track. \(url.lastPathComponent) does not.")
            }
            let (natural, transform, rate) = try await src.load(.naturalSize, .preferredTransform, .nominalFrameRate)
            let oriented = CGRect(origin: .zero, size: natural).applying(transform).standardized.size
            let range = CMTimeRange(start: .zero, duration: duration)
            try video.insertTimeRange(range, of: src, at: cursor)
            if let a = try await asset.loadTracks(withMediaType: .audio).first {
                try audio.insertTimeRange(range, of: a, at: cursor)
            }

            if renderSize == nil { renderSize = oriented; frameRate = max(rate, 1) }
            let target = renderSize!
            let scale = min(target.width / oriented.width, target.height / oriented.height)
            // Orient, move the oriented frame to the origin, scale to fit, then center.
            let orientedRect = CGRect(origin: .zero, size: natural).applying(transform)
            var t = transform.concatenating(CGAffineTransform(translationX: -orientedRect.minX, y: -orientedRect.minY))
            t = t.concatenating(CGAffineTransform(scaleX: scale, y: scale))
            t = t.concatenating(CGAffineTransform(translationX: (target.width - oriented.width * scale) / 2,
                                                  y: (target.height - oriented.height * scale) / 2))
            layer.setTransform(t, at: cursor)
            cursor = cursor + duration
        }
        if audio.segments.isEmpty { comp.removeTrack(audio) }

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: cursor)
        instruction.layerInstructions = [layer]
        let vc = AVMutableVideoComposition()
        vc.renderSize = CGSize(width: (renderSize!.width / 2).rounded() * 2, height: (renderSize!.height / 2).rounded() * 2)
        vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate.rounded()))
        vc.instructions = [instruction]

        let (type, ext) = fileType(for: urls[0])
        let dest = Output.unique(in: urls[0].deletingLastPathComponent(), base: "Joined Video", ext: ext)
        try await export(comp, to: dest, type: type, preset: AVAssetExportPresetHighestQuality, videoComposition: vc)
        return dest
    }

    // MARK: Speed

    static func changeSpeed(_ url: URL, speed: Double) async throws -> URL {
        guard speedRange.contains(speed) else { throw ToolError("Choose a speed between 0.25× and 4×.") }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let comp = try await composition(of: asset, ranges: [CMTimeRange(start: .zero, duration: duration)])
        comp.scaleTimeRange(CMTimeRange(start: .zero, duration: duration),
                            toDuration: CMTimeMultiplyByFloat64(duration, multiplier: 1 / speed))
        let (type, ext) = fileType(for: url)
        let label = speed.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(speed)) : String(format: "%g", speed)
        let dest = Output.beside(url, ext: ext, suffix: " \(label)x")
        try await export(comp, to: dest, type: type, preset: AVAssetExportPresetHighestQuality, spectralPitch: true)
        return dest
    }

    // MARK: Crop

    /// Pixel size of the video as displayed (after rotation).
    static func displaySize(_ url: URL) async throws -> CGSize {
        guard let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first else {
            throw ToolError("This file has no playable video track.")
        }
        let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
        return CGRect(origin: .zero, size: natural).applying(transform).standardized.size
    }

    /// `rect` is in displayed-pixel coordinates with a top-left origin.
    static func crop(_ url: URL, to rect: CGRect) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ToolError("This file has no playable video track.")
        }
        let (natural, transform, rate) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let oriented = CGRect(origin: .zero, size: natural).applying(transform)
        let frame = CGRect(origin: .zero, size: oriented.standardized.size)
        // Even dimensions keep H.264/HEVC encoders happy.
        var crop = rect.integral.intersection(frame)
        crop.size.width = floor(crop.width / 2) * 2
        crop.size.height = floor(crop.height / 2) * 2
        guard crop.width >= 2, crop.height >= 2 else { throw ToolError("Keep the crop inside the video frame.") }

        let duration = try await asset.load(.duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(transform.concatenating(CGAffineTransform(translationX: -oriented.minX - crop.minX,
                                                                     y: -oriented.minY - crop.minY)), at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layer]
        let vc = AVMutableVideoComposition()
        vc.renderSize = crop.size
        vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(rate, 1).rounded()))
        vc.instructions = [instruction]

        let (type, ext) = fileType(for: url)
        let dest = Output.beside(url, ext: ext, suffix: " cropped")
        try await export(asset, to: dest, type: type, preset: AVAssetExportPresetHighestQuality, videoComposition: vc)
        return dest
    }
}
