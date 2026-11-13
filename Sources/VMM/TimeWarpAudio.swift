import AVFoundation

/// Renders a bounded source interval at a varying speed. This is a varispeed
/// operation: pitch changes with speed. It is not a pitch-preserving stretcher.
enum TimeWarpAudio {
    static func render(input: URL, output: URL, curve: SpeedCurve, sourceStart: Double,
                       sourceEnd: Double, duration: Double, reversed: Bool) throws {
        let file = try AVAudioFile(forReading: input)
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw VMMError.message("変換先のファイルは既に存在します。")
        }
        let format = file.processingFormat
        let rate = format.sampleRate
        guard rate.isFinite, rate > 0, sourceStart.isFinite, sourceEnd.isFinite,
              duration.isFinite, duration > 0, duration <= 86400, sourceStart >= 0,
              sourceEnd > sourceStart, sourceEnd <= 172800,
              curve.distance(at: duration) <= sourceEnd - sourceStart + 1e-8,
              format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else {
            throw VMMError.message("音声の時間変換範囲が不正です。")
        }
        let first = Int64((sourceStart * rate).rounded(.up))
        let last = Int64((sourceEnd * rate).rounded(.down)) - 1
        guard first <= last else { throw VMMError.message("音声の時間変換範囲が短すぎます。") }
        let total = Int64((duration * rate).rounded(.down))
        guard total > 0 else { throw VMMError.message("音声の時間変換範囲が短すぎます。") }
        let capacity: AVAudioFrameCount = 4096
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity),
              let cache = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw VMMError.message("音声バッファを確保できません。")
        }
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        var destination: AVAudioFile? = try AVAudioFile(forWriting: output, settings: settings)
        var cacheStart: Int64 = -1
        func sample(_ index: Int64, channel: Int) throws -> Float {
            let frame = min(last, max(first, index))
            guard frame >= 0, frame < file.length else { return 0 }
            if frame < cacheStart || frame >= cacheStart + Int64(cache.frameLength) {
                cacheStart = (frame / Int64(capacity)) * Int64(capacity)
                file.framePosition = cacheStart
                try file.read(into: cache, frameCount: capacity)
                guard cache.frameLength > 0 else { throw VMMError.message("音声の読み込みに失敗しました。") }
            }
            return cache.floatChannelData![channel][Int(frame - cacheStart)]
        }
        do {
            var position: Int64 = 0
            while position < total {
                try Task.checkCancellation()
                let count = Int(min(Int64(capacity), total - position))
                buffer.frameLength = AVAudioFrameCount(count)
                for frame in 0..<count {
                    let time = Double(position + Int64(frame)) / rate
                    let offset = curve.distance(at: time) * rate
                    // Reverse starts at the final actual sample, not the exclusive end.
                    let sourceFrame = reversed ? sourceEnd * rate - 1 - offset : sourceStart * rate + offset
                    let lower = Int64(floor(sourceFrame)), fraction = Float(sourceFrame - floor(sourceFrame))
                    for channel in 0..<Int(format.channelCount) {
                        let a = try sample(lower, channel: channel)
                        let b = try sample(lower + 1, channel: channel)
                        buffer.floatChannelData![channel][frame] = a + (b - a) * fraction
                    }
                }
                try destination?.write(from: buffer)
                position += Int64(count)
            }
            destination = nil
        } catch {
            destination = nil
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }
}
