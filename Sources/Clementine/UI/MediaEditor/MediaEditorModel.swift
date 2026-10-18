import AVFoundation
import AppKit

enum EditorTool: String, CaseIterable, Identifiable {
    case trim, split, speed, crop, normalize, channels
    var id: String { rawValue }

    var label: String {
        switch self {
        case .trim: "Trim"
        case .split: "Split"
        case .speed: "Speed"
        case .crop: "Crop"
        case .normalize: "Normalize"
        case .channels: "Channels"
        }
    }

    static let video: [EditorTool] = [.trim, .split, .speed, .crop]
    static let audio: [EditorTool] = [.trim, .normalize, .channels]

    init?(_ op: FileOperation) {
        switch op {
        case .trim: self = .trim
        case .split: self = .split
        case .changeSpeed: self = .speed
        case .crop: self = .crop
        case .normalizeAudio: self = .normalize
        case .audioChannels: self = .channels
        default: return nil
        }
    }
}

enum CropAspect: String, CaseIterable, Identifiable {
    case free, original, square, wide, tall, classic
    var id: String { rawValue }
    var label: String {
        switch self {
        case .free: "Free"
        case .original: "Original"
        case .square: "1:1"
        case .wide: "16:9"
        case .tall: "9:16"
        case .classic: "4:3"
        }
    }
    /// Width / height in pixels; nil means unconstrained.
    func ratio(videoSize: CGSize) -> CGFloat? {
        switch self {
        case .free: nil
        case .original: videoSize.height > 0 ? videoSize.width / videoSize.height : nil
        case .square: 1
        case .wide: 16 / 9
        case .tall: 9 / 16
        case .classic: 4 / 3
        }
    }
}

@MainActor
final class MediaEditorModel: ObservableObject {
    let url: URL
    let isVideo: Bool
    let tools: [EditorTool]
    let player = AVPlayer()

    @Published var tool: EditorTool { didSet { toolChanged(from: oldValue) } }
    @Published var duration = 0.0
    @Published var currentTime = 0.0
    @Published var isPlaying = false
    @Published var thumbnails: [CGImage] = []
    @Published var waveform: [[Float]] = []
    @Published var loadError: String?

    // Trim
    @Published var trimStart = 0.0
    @Published var trimEnd = 0.0
    @Published var silenceThreshold = -50.0

    // Split
    @Published var splitPoints: [Double] = []      // kept sorted
    @Published var removedClips: Set<Int> = []
    @Published var selectedClip: Int?
    @Published var splitMode: VideoEdit.SplitExportMode = .separate

    // Speed
    @Published var speed = 2.0 { didSet { if isPlaying { player.rate = Float(speed) } } }

    // Crop (normalized rect, top-left origin)
    @Published var videoSize = CGSize.zero
    @Published var cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    @Published var cropAspect: CropAspect = .free { didSet { applyAspect() } }
    @Published var frameImage: CGImage?

    // Normalize
    @Published var targetLUFS = -16.0
    @Published var peakCeiling = -1.0
    @Published var loudness: AudioEdit.Loudness?
    @Published var isMeasuring = false

    // Channels
    @Published var channelLayout: AudioEdit.ChannelLayout = .stereo
    @Published var leftVolume = 1.0
    @Published var rightVolume = 1.0

    private var timeObserver: Any?

    init(url: URL, tool: EditorTool) {
        self.url = url
        isVideo = FileKind.of(url) == .video
        tools = isVideo ? EditorTool.video : EditorTool.audio
        self.tool = tools.contains(tool) ? tool : tools[0]
        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .spectral
        player.replaceCurrentItem(with: item)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t.seconds) }
        }
        Task { await load() }
    }

    func teardown() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
    }

    // MARK: Loading

    private func load() async {
        do {
            duration = try await VideoEdit.duration(url)
            trimEnd = duration
            if isVideo {
                videoSize = try await VideoEdit.displaySize(url)
                await loadThumbnails()
                await refreshFrame()
            } else {
                let url = url
                waveform = try await Task.detached { try AudioEdit.waveform(url) }.value
                channelLayout = waveform.count == 1 ? .stereo : .mono
            }
            if tool == .normalize { measureLoudness() }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func loadThumbnails() async {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 240, height: 240)
        let count = 14
        var images: [CGImage] = []
        for i in 0..<count {
            let t = CMTime(seconds: duration * (Double(i) + 0.5) / Double(count), preferredTimescale: 600)
            if let img = try? await gen.image(at: t).image { images.append(img) }
        }
        thumbnails = images
    }

    func refreshFrame() async {
        guard isVideo else { return }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        frameImage = try? await gen.image(at: CMTime(seconds: currentTime, preferredTimescale: 600)).image
    }

    func measureLoudness() {
        guard loudness == nil, !isMeasuring else { return }
        isMeasuring = true
        let url = url
        Task {
            let result = try? await Task.detached { try AudioEdit.measure(url) }.value
            loudness = result
            isMeasuring = false
        }
    }

    // MARK: Playback

    func togglePlay() {
        if isPlaying { pause(); return }
        if tool == .trim, currentTime < trimStart || currentTime >= trimEnd - 0.05 { seek(trimStart) }
        if currentTime >= duration - 0.05 { seek(0) }
        player.rate = tool == .speed ? Float(speed) : 1
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
        if tool == .crop { Task { await refreshFrame() } }
    }

    func seek(_ t: Double) {
        currentTime = min(max(0, t), duration)
        player.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func tick(_ t: Double) {
        guard t.isFinite else { return }
        currentTime = t
        guard isPlaying else { return }
        if player.rate == 0 { isPlaying = false; return }
        switch tool {
        case .trim where t >= trimEnd:
            pause(); seek(trimEnd)
        case .split:
            // Play the result: skip removed clips.
            let clips = self.clips
            if let i = clips.firstIndex(where: { $0.contains(t) }), removedClips.contains(i) {
                if let next = clips.indices.first(where: { $0 > i && !removedClips.contains($0) }) {
                    seek(clips[next].lowerBound)
                } else {
                    pause()
                }
            }
        default: break
        }
    }

    private func toolChanged(from old: EditorTool) {
        pause()
        player.rate = 0
        if tool == .crop { Task { await refreshFrame() } }
        if tool == .normalize { measureLoudness() }
    }

    // MARK: Split

    var clips: [ClosedRange<Double>] { VideoEdit.clips(splitPoints: splitPoints, duration: duration) }

    func addSplitAtPlayhead() {
        let t = currentTime
        guard t > VideoEdit.minimumSplitGap, t < duration - VideoEdit.minimumSplitGap,
              !splitPoints.contains(where: { abs($0 - t) < VideoEdit.minimumSplitGap }) else { NSSound.beep(); return }
        // Keep "removed" marks attached to the same clips after the insert.
        let index = splitPoints.filter { $0 < t }.count
        removedClips = Set(removedClips.map { $0 > index ? $0 + 1 : $0 })
        splitPoints = (splitPoints + [t]).sorted()
    }

    func removeSplit(at index: Int) {
        guard splitPoints.indices.contains(index) else { return }
        splitPoints.remove(at: index)
        removedClips = Set(removedClips.compactMap { $0 == index + 1 ? nil : ($0 > index + 1 ? $0 - 1 : $0) })
    }

    func moveSplit(_ index: Int, to t: Double) {
        let lo = index > 0 ? splitPoints[index - 1] + VideoEdit.minimumSplitGap : VideoEdit.minimumSplitGap
        let hi = index < splitPoints.count - 1 ? splitPoints[index + 1] - VideoEdit.minimumSplitGap : duration - VideoEdit.minimumSplitGap
        guard lo <= hi else { return }
        splitPoints[index] = min(max(t, lo), hi)
    }

    func selectClip(at t: Double) {
        selectedClip = clips.firstIndex { $0.contains(t) }
    }

    func toggleSelectedClip() {
        guard let i = selectedClip else { return }
        if removedClips.contains(i) { removedClips.remove(i) }
        else if removedClips.count < clips.count - 1 { removedClips.insert(i) }
        else { NSSound.beep() }
    }

    // MARK: Crop

    var cropPixels: CGRect {
        CGRect(x: cropRect.minX * videoSize.width, y: cropRect.minY * videoSize.height,
               width: cropRect.width * videoSize.width, height: cropRect.height * videoSize.height)
    }

    /// Largest centered rect of the chosen aspect inside the frame.
    private func applyAspect() {
        guard let ratio = cropAspect.ratio(videoSize: videoSize), videoSize.width > 0 else { return }
        let frameRatio = videoSize.width / videoSize.height
        var w: CGFloat = 1, h: CGFloat = 1
        if ratio > frameRatio { h = frameRatio / ratio } else { w = ratio / frameRatio }
        cropRect = CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }

    // MARK: Normalize

    var normalizationGain: Double? {
        loudness.flatMap { AudioEdit.normalizationGain($0, targetLUFS: targetLUFS, peakCeilingDB: peakCeiling) }
    }

    // MARK: Export

    var exportTitle: String {
        switch tool {
        case .trim: "Save Trimmed Copy"
        case .split: splitMode == .separate ? "Export Clips" : "Export One Video"
        case .speed: "Save at \(String(format: "%g", speed))×"
        case .crop: "Save Cropped Copy"
        case .normalize: "Save Normalized Copy"
        case .channels: "Save \(channelLayout.label) Copy"
        }
    }

    var canExport: Bool {
        guard duration > 0 else { return false }
        switch tool {
        case .split:
            return splitMode == .separate ? !splitPoints.isEmpty : !removedClips.isEmpty
        case .trim: return trimEnd - trimStart >= VideoEdit.minimumSplitGap
        case .normalize: return normalizationGain != nil
        default: return true
        }
    }

    func trimSilence() {
        let url = url, threshold = silenceThreshold
        Task {
            do {
                let r = try await Task.detached { try AudioEdit.nonSilentRange(url, thresholdDB: threshold) }.value
                trimStart = r.lowerBound
                trimEnd = r.upperBound
                seek(trimStart)
            } catch {
                loadError = error.localizedDescription
            }
        }
    }

    func export() {
        pause()
        let url = url, isVideo = isVideo
        let (start, end) = (trimStart, trimEnd)
        let (points, removed, mode) = (splitPoints, removedClips, splitMode)
        let (speed, crop) = (speed, cropPixels)
        let (target, ceiling) = (targetLUFS, peakCeiling)
        let (layout, lv, rv) = (channelLayout, leftVolume, rightVolume)
        let tool = tool
        OperationRunner.shared.runTask("\(tool.label) – \(url.lastPathComponent)") {
            switch tool {
            case .trim:
                return [isVideo ? try await VideoEdit.trim(url, start: start, end: end) : try AudioEdit.trim(url, start: start, end: end)]
            case .split: return try await VideoEdit.split(url, at: points, removing: removed, mode: mode)
            case .speed: return [try await VideoEdit.changeSpeed(url, speed: speed)]
            case .crop: return [try await VideoEdit.crop(url, to: crop)]
            case .normalize: return [try AudioEdit.normalize(url, targetLUFS: target, peakCeilingDB: ceiling)]
            case .channels: return [try AudioEdit.convertChannels(url, layout: layout, leftVolume: lv, rightVolume: rv)]
            }
        }
    }
}

func formatTime(_ t: Double) -> String {
    guard t.isFinite else { return "0:00.0" }
    let m = Int(t) / 60, s = t - Double(m * 60)
    return String(format: "%d:%04.1f", m, s)
}
