import XCTest
import AppKit
import AVFoundation
@testable import VMM

final class ExportTests: XCTestCase {
    func testActualMP4ExportWithDelayedAudio() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vmm-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Media"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24000)!
        buffer.frameLength = 24000
        for index in 0..<24000 { buffer.floatChannelData![0][index] = Float(sin(Double(index) * 2 * .pi * 440 / 24000) * 0.2) }
        let toneURL = directory.appendingPathComponent("Media/tone.wav")
        var file: AVAudioFile? = try AVAudioFile(forWriting: toneURL, settings: format.settings)
        try file?.write(from: buffer)
        file = nil // Finalize the WAV header before opening it as an AVURLAsset.
        var project = Project.demo()
        project.width = 640; project.height = 360
        project.clips = [Clip(kind: .text, name: "テスト", track: 1, start: 0, duration: 2, text: "VMM / 書き出しテスト", fontSize: 40)]
        var style = TextStyle(); style.shadow = true; style.outlineColor = "2244FF"; style.outlineWidth = 5
        style.fillGradient = TextGradient(enabled: true, endColor: "FFDD44", angle: 90)
        style.outlineGradient = TextGradient(enabled: true, endColor: "22FFFF", angle: 0)
        project.clips[0].textStyle = style
        let asset = MediaAsset(name: "tone", file: "tone.wav", kind: .audio, duration: 1)
        project.assets = [asset]
        var audio = Clip(kind: .audio, name: "tone", track: 2, start: 0.5, duration: 1)
        audio.assetID = asset.id; audio.volume = 0.5
        audio.audioFade = AudioFade(fadeIn: 0.3, fadeOut: 0.3)
        project.clips.append(audio)
        let output = directory.appendingPathComponent("test.mp4")
        try await MovieExporter.export(project: project, directory: directory, destination: output) { _ in }
        let movie = AVURLAsset(url: output)
        let duration = try await movie.load(.duration)
        XCTAssertEqual(duration.seconds, 2, accuracy: 0.05)
        let video = try await movie.loadTracks(withMediaType: .video)
        let audioTracks = try await movie.loadTracks(withMediaType: .audio)
        XCTAssertEqual(video.count, 1)
        XCTAssertEqual(audioTracks.count, 1)
        let videoTrack = try XCTUnwrap(video.first)
        let audioTrack = try XCTUnwrap(audioTracks.first)
        let size = try await videoTrack.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 640, height: 360))
        // Read the actual muxed samples: first 0.4 s must be silent, then the delayed tone must be audible.
        let reader = try AVAssetReader(asset: movie)
        let samples = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false])
        reader.add(samples); XCTAssertTrue(reader.startReading())
        var earlyPeak: Float = 0, tonePeak: Float = 0, fadeInPeak: Float = 0, fadeOutPeak: Float = 0
        while let sample = samples.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
            if let pointer {
                let description = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
                let format = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(description)).pointee
                let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { p in
                    for index in 0..<(length / 4) {
                        let time = start + Double(index / Int(format.mChannelsPerFrame)) / format.mSampleRate
                        if time < 0.35 { earlyPeak = max(earlyPeak, abs(p[index])) }
                        if time > 0.85 && time < 1.1 { tonePeak = max(tonePeak, abs(p[index])) }
                        if time > 0.51 && time < 0.56 { fadeInPeak = max(fadeInPeak, abs(p[index])) }
                        if time > 1.44 && time < 1.49 { fadeOutPeak = max(fadeOutPeak, abs(p[index])) }
                    }
                }
            }
        }
        XCTAssertLessThan(earlyPeak, 0.01)
        XCTAssertGreaterThan(tonePeak, 0.04)
        XCTAssertLessThan(tonePeak, 0.16)
        XCTAssertLessThan(fadeInPeak, tonePeak * 0.4)
        XCTAssertLessThan(fadeOutPeak, tonePeak * 0.4)
        // The preview/DSP decoder must preserve empty leading/trailing edits in movie audio.
        let decodedURL=directory.appendingPathComponent("decoded.caf")
        let decoded=try await AudioProcessor.decode(source:output,destination:decodedURL);XCTAssertTrue(decoded)
        let decodedFile=try AVAudioFile(forReading:decodedURL)
        XCTAssertEqual(Double(decodedFile.length)/decodedFile.processingFormat.sampleRate,2,accuracy:0.03)
        let pcm=AVAudioPCMBuffer(pcmFormat:decodedFile.processingFormat,frameCapacity:14400)!
        try decodedFile.read(into:pcm)
        let silent=UnsafeBufferPointer(start:pcm.floatChannelData![0],count:Int(pcm.frameLength)).map{abs($0)}.max() ?? 0
        XCTAssertLessThan(silent,0.01)
        if let artifactDirectory = testArtifactDirectory() {
            let target = URL(fileURLWithPath: artifactDirectory)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let artifact = target.appendingPathComponent("export-test.mp4")
            if FileManager.default.fileExists(atPath: artifact.path) { try FileManager.default.removeItem(at: artifact) }
            try FileManager.default.copyItem(at: output, to: artifact)
        }
    }

    @MainActor func testSplitPreservesSourceOffsetAndUndo() throws {
        let store = EditorStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        var clip = Clip(kind: .video, name: "video", track: 0, start: 2, duration: 4)
        clip.sourceOffset = 3
        store.project.clips = [clip]; store.selectedID = clip.id; store.playhead = 4; store.snapping = false
        store.splitSelected()
        XCTAssertEqual(store.project.clips.count, 2)
        XCTAssertEqual(store.project.clips[0].duration, 2)
        XCTAssertEqual(store.project.clips[1].sourceOffset, 5)
        XCTAssertEqual(store.project.clips[1].start, 4)
        store.undo()
        XCTAssertEqual(store.project.clips, [clip])
        store.redo()
        XCTAssertEqual(store.project.clips.count, 2)
        store.project.tracks[0].locked = true
        store.deleteSelected()
        XCTAssertEqual(store.project.clips.count, 2)
    }

    @MainActor func testSaveReplaceAndReopenPreservesMedia() throws {
        let store = EditorStore()
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("vmm-roundtrip-\(UUID()).vmm")
        defer {
            try? FileManager.default.removeItem(at: store.directory)
            try? FileManager.default.removeItem(at: destination)
        }
        let data = Data([1, 2, 3, 4])
        try data.write(to: store.directory.appendingPathComponent("Media/fixture.wav"))
        store.project.assets = [.init(name: "fixture", file: "fixture.wav", kind: .audio, duration: 1)]
        store.savedURL = destination
        XCTAssertTrue(store.save(), store.error ?? "")
        store.project.clips[0].duration = 12
        XCTAssertTrue(store.save(), store.error ?? "")
        let expected = store.project
        store.project = Project()
        store.loadProject(destination)
        XCTAssertNil(store.error)
        XCTAssertEqual(store.project, expected)
        XCTAssertEqual(try Data(contentsOf: store.directory.appendingPathComponent("Media/fixture.wav")), data)
    }

    func testLiveVoicevoxWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["VMM_LIVE_VOICEVOX"] == "1" else {
            throw XCTSkip("Set VMM_LIVE_VOICEVOX=1 with VOICEVOX running to exercise the real engine.")
        }
        let voices = try await Voicevox().speakers()
        let voice = try XCTUnwrap(voices.first)
        let text = "こんにちは。Macで動画を作ってみましょう。"
        let data = try await Voicevox().synthesize(text: text, speaker: voice.id, speed: 1)
        let parent = URL(fileURLWithPath: testArtifactDirectory() ?? FileManager.default.temporaryDirectory.appendingPathComponent("vmm-live-\(UUID())").path)
        let directory = parent.appendingPathComponent("VOICEVOX-demo.vmm")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Media"), withIntermediateDirectories: true)
        let audioURL = directory.appendingPathComponent("Media/voice.wav")
        try data.write(to: audioURL, options: .atomic)
        let duration = try await AVURLAsset(url: audioURL).load(.duration).seconds
        let envelope = try audioEnvelope(url: audioURL)
        XCTAssertGreaterThan(duration, 1)
        XCTAssertGreaterThan(envelope.max() ?? 0, 0.018)
        var project = Project()
        project.name = "VOICEVOX連携サンプル"; project.width = 1280; project.height = 720
        let asset = MediaAsset(name: "voice.wav", file: "voice.wav", kind: .audio, duration: duration, envelope: envelope)
        project.assets = [asset]
        var speech = Clip(kind: .speech, name: "セリフ", track: 1, start: 0, duration: ceil(duration * 30) / 30)
        speech.text = text; speech.assetID = asset.id; speech.speakerID = voice.id; speech.speakerName = voice.name; speech.y = 0.7; speech.fontSize = 42
        var title = Clip(kind: .text, name: "タイトル", track: 0, start: 0, duration: speech.duration)
        title.text = "VMM — Voice Movie Maker"; title.y = 0.4; title.fontSize = 58; title.color = "66CCFA"
        var credit = Clip(kind: .text, name: "クレジット", track: 2, start: 0, duration: speech.duration)
        credit.text = "VOICEVOX:\(voice.name)"; credit.y = 0.9; credit.fontSize = 24
        project.clips = [title, speech, credit]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(project).write(to: directory.appendingPathComponent("project.json"), options: .atomic)
        let output = parent.appendingPathComponent("VOICEVOX-demo.mp4")
        try await MovieExporter.export(project: project, directory: directory, destination: output) { _ in }
        let tracks = try await AVURLAsset(url: output).loadTracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count, 1)
    }
}
