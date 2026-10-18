import AVFoundation
import Accelerate

/// Sample-level audio edits: trim, silence trimming, loudness normalization and channel mixing.
enum AudioEdit {
    // MARK: Pipeline

    /// Output keeps WAV/AIFF as 16-bit PCM; everything else becomes AAC in .m4a.
    private static func outputSettings(for url: URL, sampleRate: Double, channels: AVAudioChannelCount) -> (String, [String: Any]) {
        switch url.pathExtension.lowercased() {
        case "wav":
            return ("wav", [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
                            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
        case "aif", "aiff":
            return ("aiff", [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
                             AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: true])
        default:
            return ("m4a", [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
                            AVEncoderBitRateKey: channels == 1 ? 128_000 : 256_000])
        }
    }

    static func open(_ url: URL) throws -> AVAudioFile {
        do { return try AVAudioFile(forReading: url) }
        catch { throw ToolError("This file has no playable audio.") }
    }

    /// Streams `frames` of the input through `process`, writing `outChannels` channels.
    /// `process(input, output, frameCount)` receives deinterleaved float channel pointers.
    private static func render(_ url: URL, suffix: String, frames: Range<AVAudioFramePosition>? = nil,
                               outChannels: AVAudioChannelCount? = nil,
                               process: ([UnsafeMutablePointer<Float>], [UnsafeMutablePointer<Float>], Int) -> Void) throws -> URL {
        let input = try open(url)
        let inFormat = input.processingFormat
        let channels = outChannels ?? inFormat.channelCount
        guard let outFormat = AVAudioFormat(standardFormatWithSampleRate: inFormat.sampleRate, channels: channels) else {
            throw ToolError("Choose valid audio channel settings.")
        }
        let (ext, settings) = outputSettings(for: url, sampleRate: inFormat.sampleRate, channels: channels)
        let dest = Output.beside(url, ext: ext, suffix: suffix)
        do {
            let output = try AVAudioFile(forWriting: dest, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let range = frames ?? 0..<input.length
            input.framePosition = range.lowerBound
            let chunk: AVAudioFrameCount = 65536
            guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: chunk),
                  let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: chunk) else { throw ToolError("Audio buffer failed.") }
            while input.framePosition < range.upperBound {
                let want = AVAudioFrameCount(min(Int64(chunk), range.upperBound - input.framePosition))
                try input.read(into: inBuf, frameCount: want)
                let n = Int(inBuf.frameLength)
                if n == 0 { break }
                let ins = (0..<Int(inFormat.channelCount)).map { inBuf.floatChannelData![$0] }
                let outs = (0..<Int(channels)).map { outBuf.floatChannelData![$0] }
                process(ins, outs, n)
                outBuf.frameLength = AVAudioFrameCount(n)
                try output.write(from: outBuf)
            }
        } catch {
            try? FileManager.default.removeItem(at: dest)
            throw error
        }
        return dest
    }

    private static func copy(_ ins: [UnsafeMutablePointer<Float>], _ outs: [UnsafeMutablePointer<Float>], _ n: Int, gain: Float = 1) {
        for (i, out) in outs.enumerated() {
            let src = ins[min(i, ins.count - 1)]
            var g = gain
            vDSP_vsmul(src, 1, &g, out, 1, vDSP_Length(n))
        }
    }

    // MARK: Trim

    static func trim(_ url: URL, start: Double, end: Double) throws -> URL {
        let file = try open(url)
        let sr = file.processingFormat.sampleRate
        let a = AVAudioFramePosition(max(0, start) * sr), b = min(file.length, AVAudioFramePosition(end * sr))
        guard b - a > Int64(0.05 * sr) else { throw ToolError("Choose a positive time range within the file.") }
        return try render(url, suffix: " trimmed", frames: a..<b) { copy($0, $1, $2) }
    }

    /// Range between the first and last samples louder than `thresholdDB`, padded by 50 ms.
    static func nonSilentRange(_ url: URL, thresholdDB: Double = -50) throws -> ClosedRange<Double> {
        let file = try open(url)
        let sr = file.processingFormat.sampleRate
        let threshold = Float(pow(10, thresholdDB / 20))
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65536) else { throw ToolError("Audio buffer failed.") }
        var first: Int64?, last: Int64?
        var position: Int64 = 0
        while file.framePosition < file.length {
            try file.read(into: buf)
            let n = Int(buf.frameLength)
            if n == 0 { break }
            for f in 0..<n {
                for c in 0..<Int(buf.format.channelCount) where abs(buf.floatChannelData![c][f]) > threshold {
                    if first == nil { first = position + Int64(f) }
                    last = position + Int64(f)
                    break
                }
            }
            position += Int64(n)
        }
        guard let first, let last else {
            throw ToolError("The selected range is silent at this threshold. Lower the threshold or turn off automatic trimming.")
        }
        let duration = Double(file.length) / sr
        return max(0, Double(first) / sr - 0.05)...min(duration, Double(last) / sr + 0.05)
    }

    static func trimSilence(_ url: URL, thresholdDB: Double = -50) throws -> URL {
        let r = try nonSilentRange(url, thresholdDB: thresholdDB)
        return try trim(url, start: r.lowerBound, end: r.upperBound)
    }

    // MARK: Loudness (ITU-R BS.1770 / EBU R128)

    struct Loudness {
        var integratedLUFS: Double   // -inf when silent
        var samplePeakDB: Double
    }

    private struct Biquad {
        var b0, b1, b2, a1, a2: Double
        var z1 = 0.0, z2 = 0.0
        mutating func run(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    /// K-weighting filters for any sample rate (coefficients per pyloudnorm / BS.1770 reference design).
    private static func kWeighting(sampleRate fs: Double) -> [Biquad] {
        // Stage 1: +4 dB high shelf at ~1.7 kHz
        let A = pow(10, 3.999843853973347 / 40)
        var w0 = 2 * .pi * 1681.974450955533 / fs, cw = cos(w0)
        var alpha = sin(w0) / (2 * 0.7071752369554196)
        var a0 = (A + 1) - (A - 1) * cw + 2 * sqrt(A) * alpha
        let shelf = Biquad(b0: A * ((A + 1) + (A - 1) * cw + 2 * sqrt(A) * alpha) / a0,
                           b1: -2 * A * ((A - 1) + (A + 1) * cw) / a0,
                           b2: A * ((A + 1) + (A - 1) * cw - 2 * sqrt(A) * alpha) / a0,
                           a1: 2 * ((A - 1) - (A + 1) * cw) / a0,
                           a2: ((A + 1) - (A - 1) * cw - 2 * sqrt(A) * alpha) / a0)
        // Stage 2: high pass at ~38 Hz
        w0 = 2 * .pi * 38.13547087602444 / fs; cw = cos(w0)
        alpha = sin(w0) / (2 * 0.5003270373238773)
        a0 = 1 + alpha
        let highpass = Biquad(b0: (1 + cw) / 2 / a0, b1: -(1 + cw) / a0, b2: (1 + cw) / 2 / a0,
                              a1: -2 * cw / a0, a2: (1 - alpha) / a0)
        return [shelf, highpass]
    }

    static func measure(_ url: URL) throws -> Loudness {
        let file = try open(url)
        let fmt = file.processingFormat
        let channels = Int(fmt.channelCount)
        let segment = Int(fmt.sampleRate * 0.1)      // 100 ms; a gating block is 4 segments
        var filters = (0..<channels).map { _ in kWeighting(sampleRate: fmt.sampleRate) }
        var segments: [Double] = []                  // channel-summed mean square per 100 ms
        var acc = 0.0, inSegment = 0
        var peak: Float = 0

        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 65536) else { throw ToolError("Audio buffer failed.") }
        while file.framePosition < file.length {
            try file.read(into: buf)
            let n = Int(buf.frameLength)
            if n == 0 { break }
            for c in 0..<channels {
                var m: Float = 0
                vDSP_maxmgv(buf.floatChannelData![c], 1, &m, vDSP_Length(n))
                peak = max(peak, m)
            }
            for f in 0..<n {
                for c in 0..<channels {
                    var x = Double(buf.floatChannelData![c][f])
                    x = filters[c][0].run(x)
                    x = filters[c][1].run(x)
                    acc += x * x
                }
                inSegment += 1
                if inSegment == segment {
                    segments.append(acc / Double(segment))
                    acc = 0; inSegment = 0
                }
            }
        }

        // 400 ms blocks with 75% overlap.
        let blocks = segments.count >= 4 ? (0...(segments.count - 4)).map { i in segments[i..<i + 4].reduce(0, +) / 4 } : []
        let lufs = { (z: Double) in -0.691 + 10 * log10(z) }
        let absGated = blocks.filter { lufs($0) > -70 }
        var integrated = -Double.infinity
        if !absGated.isEmpty {
            let relative = lufs(absGated.reduce(0, +) / Double(absGated.count)) - 10
            let gated = absGated.filter { lufs($0) > relative }
            if !gated.isEmpty { integrated = lufs(gated.reduce(0, +) / Double(gated.count)) }
        }
        return Loudness(integratedLUFS: integrated, samplePeakDB: peak > 0 ? 20 * log10(Double(peak)) : -.infinity)
    }

    /// Gain needed to hit `targetLUFS` without the (sample) peak exceeding `peakCeilingDB`.
    static func normalizationGain(_ m: Loudness, targetLUFS: Double, peakCeilingDB: Double) -> Double? {
        guard m.integratedLUFS.isFinite else { return nil }
        var gain = targetLUFS - m.integratedLUFS
        if m.samplePeakDB.isFinite { gain = min(gain, peakCeilingDB - m.samplePeakDB) }
        return gain
    }

    static func normalize(_ url: URL, targetLUFS: Double = -16, peakCeilingDB: Double = -1) throws -> URL {
        guard (-70...(-5)).contains(targetLUFS), (-9...0).contains(peakCeilingDB) else {
            throw ToolError("Choose a target from -70 to -5 LUFS and a peak ceiling from -9 to 0 dB.")
        }
        guard let gainDB = normalizationGain(try measure(url), targetLUFS: targetLUFS, peakCeilingDB: peakCeilingDB) else {
            throw ToolError("This file has no playable audio.")
        }
        let gain = Float(pow(10, gainDB / 20))
        return try render(url, suffix: " normalized") { copy($0, $1, $2, gain: gain) }
    }

    // MARK: Channels

    enum ChannelLayout: String, CaseIterable, Identifiable {
        case mono, stereo
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    /// Mixes to mono or stereo with independent left/right volume (0…2).
    /// Mono sums both sides at half level; a mono source feeds both stereo sides.
    static func convertChannels(_ url: URL, layout: ChannelLayout, leftVolume: Double = 1, rightVolume: Double = 1) throws -> URL {
        guard (0...2).contains(leftVolume), (0...2).contains(rightVolume) else { throw ToolError("Choose valid audio channel settings.") }
        let lv = Float(leftVolume), rv = Float(rightVolume)
        return try render(url, suffix: " \(layout.rawValue)", outChannels: layout == .mono ? 1 : 2) { ins, outs, n in
            let l = ins[0], r = ins.count > 1 ? ins[1] : ins[0]
            if layout == .mono {
                for i in 0..<n { outs[0][i] = 0.5 * (l[i] * lv + r[i] * rv) }
            } else {
                for i in 0..<n { outs[0][i] = l[i] * lv; outs[1][i] = r[i] * rv }
            }
        }
    }

    // MARK: Waveform

    /// Peak envelope per channel, `bins` values in 0…1.
    static func waveform(_ url: URL, bins: Int = 600) throws -> [[Float]] {
        let file = try open(url)
        let channels = Int(file.processingFormat.channelCount)
        let perBin = max(1, Int(file.length) / bins)
        var result = Array(repeating: [Float](), count: channels)
        var current = Array(repeating: Float(0), count: channels)
        var count = 0
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65536) else { return [] }
        while file.framePosition < file.length {
            try file.read(into: buf)
            let n = Int(buf.frameLength)
            if n == 0 { break }
            for f in 0..<n {
                for c in 0..<channels { current[c] = max(current[c], abs(buf.floatChannelData![c][f])) }
                count += 1
                if count == perBin {
                    for c in 0..<channels { result[c].append(min(1, current[c])); current[c] = 0 }
                    count = 0
                }
            }
        }
        return result
    }
}
