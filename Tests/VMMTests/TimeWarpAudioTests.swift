import AVFoundation
import XCTest
@testable import VMM

final class TimeWarpAudioTests: XCTestCase {
    func testOptionalWarpPipelineBenchmark() throws {
        guard ProcessInfo.processInfo.environment["VMM_WARP_BENCHMARK"] == "1" else {throw XCTSkip("Opt-in audio benchmark")}
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-warp-bench-\(UUID())")
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:dir)}
        let format=try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate:48000,channels:2))
        let buffer=try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:480000));buffer.frameLength=480000
        for i in 0..<480000 {let value=Float(sin(Double(i)*0.07))*0.3;buffer.floatChannelData![0][i]=value;buffer.floatChannelData![1][i]=value}
        let input=dir.appendingPathComponent("input.caf"),warp=dir.appendingPathComponent("warp.caf"),processed=dir.appendingPathComponent("processed.caf")
        var file:AVAudioFile?=try AVAudioFile(forWriting:input,settings:format.settings);try file!.write(from:buffer);file=nil
        let curve=try SpeedCurve(points:[.init(time:0,rate:0.5),.init(time:10,rate:1.5)])
        let start=ProcessInfo.processInfo.systemUptime
        try TimeWarpAudio.render(input:input,output:warp,curve:curve,sourceStart:0,sourceEnd:10,duration:10,reversed:true)
        let warpSeconds=ProcessInfo.processInfo.systemUptime-start
        var clip=Clip(kind:.audio,name:"benchmark",track:0,start:0,duration:10);clip.playbackRate=1
        let graphStart=ProcessInfo.processInfo.systemUptime
        _=try AudioProcessor.process(decoded:warp,clip:clip,destination:processed)
        let graphSeconds=ProcessInfo.processInfo.systemUptime-graphStart
        print(String(format:"WARP_BENCH warp=%.4fs old_extra_graph=%.4fs old_total=%.4fs new_total=%.4fs",warpSeconds,graphSeconds,warpSeconds+graphSeconds,warpSeconds))
    }
    func testWarpedAudioExportAndPlayer() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let media = dir.appendingPathComponent("Media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = media.appendingPathComponent("source.caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000))
        buffer.frameLength = 48000
        for i in 0..<48000 { for channel in 0..<2 { buffer.floatChannelData![channel][i] = Float(i) / 96000 } }
        var writer: AVAudioFile? = try AVAudioFile(forWriting: source, settings: format.settings)
        try writer!.write(from: buffer); writer = nil
        var project = Project()
        let asset = MediaAsset(name: "source", file: "source.caf", kind: .audio, duration: 1)
        var clip = Clip(kind: .audio, name: "warp", track: 0, start: 0, duration: 1)
        clip.assetID = asset.id; clip.reversed = true
        clip.speedPoints = [.init(time: 0, rate: 0.5), .init(time: 1, rate: 1.5)]
        project.assets = [asset]; project.clips = [clip]
        let output = dir.appendingPathComponent("out.wav")
        try await AudioOnlyExporter.export(project: project, directory: dir, destination: output, floatPCM: true) { _ in }
        let file = try AVAudioFile(forReading: output)
        let result = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48000))
        try file.read(into: result)
        XCTAssertEqual(result.frameLength, 48000)
        XCTAssertGreaterThan(result.floatChannelData![0][4000], result.floatChannelData![0][40000] + 0.2)
        let warped = dir.appendingPathComponent("preview.caf")
        try TimeWarpAudio.render(input: source, output: warped, curve: clip.timeWarpCurve, sourceStart: 0, sourceEnd: 1, duration: 1, reversed: true)
        let previewFile=try AVAudioFile(forReading:warped)
        let previewSamples=try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:previewFile.processingFormat,frameCapacity:48000))
        try previewFile.read(into:previewSamples)
        let oldPath=dir.appendingPathComponent("previous-graph.caf")
        _=try AudioProcessor.process(decoded:warped,clip:AudioProcessor.warpedPlaybackClip(clip),destination:oldPath)
        let oldFile=try AVAudioFile(forReading:oldPath)
        let oldSamples=try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:oldFile.processingFormat,frameCapacity:48000))
        try oldFile.read(into:oldSamples)
        for i in [1000,8000,24000,40000,47000] {
            for channel in 0..<2 {
                XCTAssertEqual(result.floatChannelData![channel][i],previewSamples.floatChannelData![channel][i],accuracy:0.0001)
                XCTAssertEqual(result.floatChannelData![channel][i],oldSamples.floatChannelData![channel][i],accuracy:0.0001)
            }
        }
        // Non-default pan/volume still use the graph after the warp.
        project.clips[0].pan = -1;project.clips[0].volume = 0.5
        let panned = dir.appendingPathComponent("panned.wav")
        try await AudioOnlyExporter.export(project: project, directory: dir, destination: panned, floatPCM: true) { _ in }
        let pannedFile=try AVAudioFile(forReading:panned)
        let pannedSamples=try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:pannedFile.processingFormat,frameCapacity:48000))
        try pannedFile.read(into:pannedSamples)
        for i in [8000,24000,40000] {
            XCTAssertEqual(pannedSamples.floatChannelData![0][i],previewSamples.floatChannelData![0][i]*0.5,accuracy:0.01)
            XCTAssertEqual(pannedSamples.floatChannelData![1][i],0,accuracy:0.001)
        }
        let player = try ClipAudioPlayer(url: warped, clip: AudioProcessor.warpedPlaybackClip(clip), time: 0.5, volume: 0.01)
        player.pause()
    }
    func testReverseAndVariableSpeedRender() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("input.caf")
        let output = dir.appendingPathComponent("output.caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000))
        buffer.frameLength = 16000
        for i in 0..<16000 {
            buffer.floatChannelData![0][i] = Float(i) / 16000
            buffer.floatChannelData![1][i] = -Float(i) / 16000
        }
        var writer: AVAudioFile? = try AVAudioFile(forWriting: input, settings: format.settings)
        try writer!.write(from: buffer)
        writer = nil
        let curve = try SpeedCurve(points: [.init(time: 0, rate: 0.5), .init(time: 1, rate: 1.5)])
        try TimeWarpAudio.render(input: input, output: output, curve: curve, sourceStart: 0.5, sourceEnd: 1.5, duration: 1, reversed: true)
        let result = try AVAudioFile(forReading: output)
        XCTAssertEqual(result.length, 8000)
        let samples = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: result.processingFormat, frameCapacity: 8000))
        try result.read(into: samples)
        for i in [0, 1000, 4000, 7999] {
            let frame = 11999.0 - curve.distance(at: Double(i) / 8000) * 8000
            XCTAssertEqual(samples.floatChannelData![0][i], Float(frame / 16000), accuracy: 0.00001)
            XCTAssertEqual(samples.floatChannelData![1][i], -Float(frame / 16000), accuracy: 0.00001)
        }
        XCTAssertThrowsError(try TimeWarpAudio.render(input: input, output: output, curve: curve, sourceStart: 0.5, sourceEnd: 1.5, duration: 1, reversed: true))
    }
}
