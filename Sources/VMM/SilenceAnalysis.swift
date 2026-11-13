import AVFoundation

struct SilenceCutRange: Equatable, Identifiable {
    var start: Double
    var end: Double
    var id: Double { start }
}

enum SilenceAnalysis {
    /// Convert frame-aligned RMS values into removable spans, leaving a margin at each edge.
    static func ranges(rms: [Double], fps: Int, thresholdDB: Double, minimum: Double, margin: Double) throws -> [SilenceCutRange] {
        guard (1...240).contains(fps), thresholdDB.isFinite, (-90...0).contains(thresholdDB),
              minimum.isFinite, (0.05...60).contains(minimum), margin.isFinite, (0...5).contains(margin),
              rms.count <= fps * 3600, rms.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw VMMError.message("無音解析の設定が不正です。")
        }
        let threshold = pow(10, thresholdDB / 20)
        let minimumFrames = max(1, Int(ceil(minimum * Double(fps))))
        let marginFrames = Int(ceil(margin * Double(fps)))
        var result: [SilenceCutRange] = [], first: Int?
        func finish(_ end: Int) {
            guard let start = first, end - start >= minimumFrames else { first = nil; return }
            let a = start + marginFrames, b = end - marginFrames
            if b > a { result.append(SilenceCutRange(start: Double(a) / Double(fps), end: Double(b) / Double(fps))) }
            first = nil
        }
        for (index, value) in rms.enumerated() {
            if value <= threshold { if first == nil { first = index } }
            else if first != nil { finish(index) }
        }
        finish(rms.count)
        return result
    }

    /// Analyze the actually used source range without mixing opposite-phase channels.
    static func analyze(url: URL, clip: Clip, fps: Int, thresholdDB: Double, minimum: Double, margin: Double) async throws -> [SilenceCutRange] {
        guard !clip.hasTimeWarp else {throw VMMError.message("逆再生・可変速度の素材は無音解析に対応していません。")}
        guard clip.duration.isFinite, clip.duration > 0, clip.duration <= 3600,
              clip.sourceOffset.isFinite, clip.sourceOffset >= 0, clip.mediaRate.isFinite, clip.mediaRate > 0,
              (1...240).contains(fps) else { throw VMMError.message("無音解析の対象が不正です。") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vmm-silence-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let decoded = root.appendingPathComponent("source.wav")
        guard try await AudioProcessor.decode(source: url, destination: decoded) else { throw VMMError.message("選択した素材に音声がありません。") }
        let file = try AVAudioFile(forReading: decoded), format = file.processingFormat, sampleRate = format.sampleRate
        let sourceStart = Int64((clip.sourceOffset * sampleRate).rounded())
        let frameCount = Int(floor(clip.duration * Double(fps) + 0.000001))
        let samplesPerFrame = sampleRate * clip.mediaRate / Double(fps)
        let sourceEnd = sourceStart + Int64((Double(frameCount) * samplesPerFrame).rounded())
        guard frameCount > 0, sourceStart >= 0, sourceEnd <= file.length,
              samplesPerFrame.isFinite, samplesPerFrame > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(ceil(samplesPerFrame) + 1)) else {
            throw VMMError.message("無音解析の素材範囲が不正です。")
        }
        file.framePosition = sourceStart
        var rms: [Double] = []; rms.reserveCapacity(frameCount)
        for frame in 0..<frameCount {
            try Task.checkCancellation()
            let a = Int64((Double(frame) * samplesPerFrame).rounded())
            let b = Int64((Double(frame + 1) * samplesPerFrame).rounded())
            let count = AVAudioFrameCount(b - a)
            try file.read(into: buffer, frameCount: count)
            guard buffer.frameLength == count, let channels = buffer.floatChannelData, format.channelCount > 0 else { throw VMMError.message("無音解析の音声を読み込めません。") }
            var sum = 0.0
            for channel in 0..<Int(format.channelCount) { for i in 0..<Int(count) { let sample = Double(channels[channel][i]); sum += sample * sample } }
            rms.append(sqrt(sum / Double(Int(count) * Int(format.channelCount))))
        }
        return try ranges(rms: rms, fps: fps, thresholdDB: thresholdDB, minimum: minimum, margin: margin)
    }
}
