import AVKit
import SwiftUI

struct MediaEditorView: View {
    @ObservedObject var model: MediaEditorModel

    var body: some View {
        VStack(spacing: 12) {
            Picker("", selection: $model.tool) {
                ForEach(model.tools) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 420)

            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(model.isVideo ? 1 : 0.04), in: RoundedRectangle(cornerRadius: 10))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            if model.tool != .crop {
                TimelineView(model: model).frame(height: model.isVideo ? 64 : 90)
            }
            controls
            footer
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 540)
        .alert("Clementine", isPresented: Binding(get: { model.loadError != nil }, set: { if !$0 { model.loadError = nil } })) {
            Button("OK") {}
        } message: {
            Text(model.loadError ?? "")
        }
    }

    @ViewBuilder private var preview: some View {
        if model.isVideo {
            if model.tool == .crop { CropOverlayView(model: model) } else { PlayerView(player: model.player) }
        } else {
            WaveformView(channels: model.tool == .channels ? model.waveform : [model.waveform.first ?? []],
                         progress: model.duration > 0 ? model.currentTime / model.duration : 0)
                .padding(12)
        }
    }

    @ViewBuilder private var controls: some View {
        switch model.tool {
        case .trim:
            HStack {
                Text("Drag the ends to trim").foregroundStyle(.secondary)
                Spacer()
                Text("\(formatTime(model.trimStart)) – \(formatTime(model.trimEnd))  (\(formatTime(model.trimEnd - model.trimStart)))")
                    .monospacedDigit()
                if !model.isVideo {
                    Divider().frame(height: 16)
                    Stepper("Silence \(Int(model.silenceThreshold)) dB", value: $model.silenceThreshold, in: -80...(-20), step: 5)
                    Button("Trim Silent Ends") { model.trimSilence() }
                }
            }
        case .split:
            HStack {
                Button("Add Split at Playhead") { model.addSplitAtPlayhead() }
                    .keyboardShortcut("b", modifiers: [])
                Button(model.selectedClip.map { model.removedClips.contains($0) } == true ? "Restore Clip" : "Remove Clip") {
                    model.toggleSelectedClip()
                }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(model.selectedClip == nil || model.clips.count < 2)
                Spacer()
                Text(model.clips.count == 1 ? "1 clip" : "\(model.clips.count) clips").foregroundStyle(.secondary)
                Picker("Export", selection: $model.splitMode) {
                    ForEach(VideoEdit.SplitExportMode.allCases) { Text($0.label).tag($0) }
                }
                .frame(width: 220)
            }
            Text("Press B to split at the playhead. Click a clip in the timeline and press Delete to remove it. Space plays the result.")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        case .speed:
            HStack {
                Text("Speed")
                Slider(value: $model.speed, in: VideoEdit.speedRange)
                Text(String(format: "%.2f×", model.speed)).monospacedDigit().frame(width: 56)
                ForEach([0.5, 1.5, 2, 4], id: \.self) { s in
                    Button(String(format: "%g×", s)) { model.speed = s }
                }
            }
            Text("New duration \(formatTime(model.duration / model.speed)). Pitch is preserved.")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        case .crop:
            HStack {
                Picker("Aspect", selection: $model.cropAspect) {
                    ForEach(CropAspect.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 380)
                Spacer()
                let px = model.cropPixels
                Text("\(Int(px.width)) × \(Int(px.height)) px at \(Int(px.minX)), \(Int(px.minY))").monospacedDigit()
                Button("Reset") { model.cropAspect = .free; model.cropRect = CGRect(x: 0, y: 0, width: 1, height: 1) }
            }
            HStack {
                Text("Frame").foregroundStyle(.secondary)
                Slider(value: Binding(get: { model.currentTime }, set: { model.seek($0) }), in: 0...max(model.duration, 0.1)) { editing in
                    if !editing { Task { await model.refreshFrame() } }
                }
            }
        case .normalize:
            NormalizeControls(model: model)
        case .channels:
            HStack(spacing: 18) {
                Picker("Output", selection: $model.channelLayout) {
                    ForEach(AudioEdit.ChannelLayout.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 200)
                Text("Left").foregroundStyle(.secondary)
                Slider(value: $model.leftVolume, in: 0...2)
                Text("\(Int(model.leftVolume * 100))%").monospacedDigit().frame(width: 44)
                Text("Right").foregroundStyle(.secondary)
                Slider(value: $model.rightVolume, in: 0...2)
                Text("\(Int(model.rightVolume * 100))%").monospacedDigit().frame(width: 44)
            }
            Text(model.waveform.count == 1
                 ? "Source is mono. Stereo copies it to both sides at the chosen volumes."
                 : "Mono mixes both sides together. Stereo keeps them separate with the chosen volumes.")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        HStack {
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 20)
            }
            .keyboardShortcut(.space, modifiers: [])
            .help(model.isPlaying ? "Pause preview (Space)" : "Play preview (Space)")
            Text("\(formatTime(model.currentTime)) / \(formatTime(model.duration))").monospacedDigit().foregroundStyle(.secondary)
            Spacer()
            Text(model.url.lastPathComponent).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button(model.exportTitle) { model.export() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canExport)
        }
    }
}

// MARK: - Normalize

private struct NormalizeControls: View {
    @ObservedObject var model: MediaEditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Target loudness").frame(width: 120, alignment: .leading)
                Slider(value: $model.targetLUFS, in: -23...(-5), step: 1)
                Text("\(Int(model.targetLUFS)) LUFS").monospacedDigit().frame(width: 70)
            }
            HStack {
                Text("Peak ceiling").frame(width: 120, alignment: .leading)
                Slider(value: $model.peakCeiling, in: -9...0, step: 0.5)
                Text(String(format: "%.1f dB", model.peakCeiling)).monospacedDigit().frame(width: 70)
            }
            HStack {
                if model.isMeasuring {
                    ProgressView().controlSize(.small); Text("Measuring loudness…")
                } else if let m = model.loudness {
                    Text(String(format: "Measured %.1f LUFS, peak %.1f dBFS", m.integratedLUFS, m.samplePeakDB))
                    if let g = model.normalizationGain {
                        Text(String(format: "→ gain %+.1f dB", g)).bold()
                        if g < model.targetLUFS - m.integratedLUFS - 0.05 {
                            Text("(limited by peak ceiling)").foregroundStyle(.orange)
                        }
                    } else {
                        Text("This file is silent.").foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .font(.callout)
            Text("-16 LUFS is a balanced default for spoken audio and music. The peak ceiling helps prevent clipping.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Player

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .none
        v.videoGravity = .resizeAspect
        return v
    }
    func updateNSView(_ nsView: AVPlayerView, context: Context) {}
}

// MARK: - Waveform

struct WaveformView: View {
    let channels: [[Float]]
    var progress: Double = 0

    var body: some View {
        VStack(spacing: 6) {
            ForEach(Array(channels.enumerated()), id: \.offset) { i, peaks in
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, size in
                        guard !peaks.isEmpty else { return }
                        let step = size.width / CGFloat(peaks.count)
                        var played = Path(), rest = Path()
                        for (j, p) in peaks.enumerated() {
                            let x = CGFloat(j) * step + step / 2
                            let h = max(1, CGFloat(p) * size.height)
                            let line = Path { $0.move(to: CGPoint(x: x, y: (size.height - h) / 2)); $0.addLine(to: CGPoint(x: x, y: (size.height + h) / 2)) }
                            if Double(j) / Double(peaks.count) < progress { played.addPath(line) } else { rest.addPath(line) }
                        }
                        ctx.stroke(played, with: .color(.orange), lineWidth: max(1, step * 0.7))
                        ctx.stroke(rest, with: .color(.secondary.opacity(0.6)), lineWidth: max(1, step * 0.7))
                    }
                    if channels.count > 1 {
                        Text(i == 0 ? "L" : "R").font(.caption2.bold()).foregroundStyle(.secondary).padding(4)
                    }
                }
            }
        }
    }
}

// MARK: - Timeline

struct TimelineView: View {
    @ObservedObject var model: MediaEditorModel
    @State private var dragOrigin: Double?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let x = { (t: Double) in model.duration > 0 ? CGFloat(t / model.duration) * w : 0 }
            let time = { (px: CGFloat) in min(max(0, Double(px / w) * model.duration), model.duration) }

            ZStack(alignment: .topLeading) {
                background(width: w, height: h)
                    .frame(width: w, height: h)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                if model.tool == .trim {
                    Rectangle().fill(.black.opacity(0.55)).frame(width: x(model.trimStart), height: h)
                    Rectangle().fill(.black.opacity(0.55)).frame(width: max(0, w - x(model.trimEnd)), height: h).offset(x: x(model.trimEnd))
                    RoundedRectangle(cornerRadius: 6).stroke(Color.orange, lineWidth: 3)
                        .frame(width: max(0, x(model.trimEnd) - x(model.trimStart)), height: h).offset(x: x(model.trimStart))
                    handle(at: x(model.trimStart), height: h) { px in
                        model.trimStart = min(time(px), model.trimEnd - VideoEdit.minimumSplitGap)
                        model.seek(model.trimStart)
                    }
                    handle(at: x(model.trimEnd), height: h) { px in
                        model.trimEnd = max(time(px), model.trimStart + VideoEdit.minimumSplitGap)
                        model.seek(model.trimEnd)
                    }
                }

                if model.tool == .split {
                    ForEach(Array(model.clips.enumerated()), id: \.offset) { i, clip in
                        let removed = model.removedClips.contains(i)
                        ZStack {
                            if removed {
                                Rectangle().fill(Color.red.opacity(0.45))
                                Image(systemName: "xmark").font(.title3.bold()).foregroundStyle(.white)
                            }
                            if model.selectedClip == i {
                                RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: 3)
                            }
                        }
                        .frame(width: max(0, x(clip.upperBound) - x(clip.lowerBound)), height: h)
                        .offset(x: x(clip.lowerBound))
                        .allowsHitTesting(false)
                    }
                    ForEach(Array(model.splitPoints.enumerated()), id: \.offset) { i, t in
                        Rectangle().fill(Color.yellow).frame(width: 3, height: h + 10)
                            .overlay(alignment: .top) { Circle().fill(Color.yellow).frame(width: 12, height: 12).offset(y: -6) }
                            .contentShape(Rectangle().inset(by: -6))
                            .offset(x: x(t) - 1.5, y: -5)
                            .gesture(DragGesture(coordinateSpace: .named("timeline")).onChanged { g in
                                model.moveSplit(i, to: time(g.location.x))
                            })
                            .contextMenu { Button("Delete Split") { model.removeSplit(at: i) } }
                    }
                }

                // Playhead
                Rectangle().fill(Color.white).frame(width: 2, height: h + 8)
                    .shadow(radius: 1).offset(x: x(model.currentTime) - 1, y: -4)
                    .allowsHitTesting(false)
            }
            .coordinateSpace(name: "timeline")
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                .onChanged { g in
                    if model.isPlaying { model.pause() }
                    model.seek(time(g.location.x))
                }
                .onEnded { g in
                    if model.tool == .split { model.selectClip(at: time(g.location.x)) }
                })
            .help("Video timeline. Drag to scrub.")
        }
    }

    @ViewBuilder
    private func background(width: CGFloat, height: CGFloat) -> some View {
        if model.isVideo {
            HStack(spacing: 0) {
                ForEach(Array(model.thumbnails.enumerated()), id: \.offset) { _, img in
                    Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: width / CGFloat(max(model.thumbnails.count, 1)), height: height).clipped()
                }
            }
            .background(Color.gray.opacity(0.3))
        } else {
            WaveformView(channels: [model.waveform.first ?? []]).background(Color.primary.opacity(0.05))
        }
    }

    private func handle(at px: CGFloat, height: CGFloat, onDrag: @escaping (CGFloat) -> Void) -> some View {
        RoundedRectangle(cornerRadius: 3).fill(Color.orange)
            .frame(width: 12, height: height)
            .overlay(Capsule().fill(.white).frame(width: 2, height: height * 0.4))
            .contentShape(Rectangle().inset(by: -6))
            .offset(x: px - 6)
            .gesture(DragGesture(coordinateSpace: .named("timeline")).onChanged { onDrag($0.location.x) })
    }
}

// MARK: - Crop

struct CropOverlayView: View {
    @ObservedObject var model: MediaEditorModel
    var body: some View {
        CropSelectionView(image: model.frameImage, imageSize: model.videoSize, rect: $model.cropRect, aspect: model.cropAspect)
    }
}
