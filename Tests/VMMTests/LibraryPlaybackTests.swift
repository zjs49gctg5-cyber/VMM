import XCTest
import AVFoundation
@testable import VMM

final class LibraryPlaybackTests:XCTestCase {
    @MainActor func testAudioVideoPlaybackSeekSwitchAndStop()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-library-playback-\(UUID())")
        let media=root.appendingPathComponent("Media")
        try FileManager.default.createDirectory(at:media,withIntermediateDirectories:true)
        let playback=LibraryPlayback()
        defer{playback.stop();try? FileManager.default.removeItem(at:root)}
        let format=try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate:44100,channels:1))
        let buffer=try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:132300));buffer.frameLength=132300
        let samples=try XCTUnwrap(buffer.floatChannelData)[0]
        for i in 0..<Int(buffer.frameLength) {samples[i]=Float(sin(Double(i)*2*Double.pi*440/44100)*0.01)}
        let audioURL=media.appendingPathComponent("tone.wav")
        try AVAudioFile(forWriting:audioURL,settings:format.settings).write(from:buffer)
        let audio=MediaAsset(name:"音声",file:"tone.wav",kind:.audio,duration:3)
        playback.open(audio,directory:root)
        for _ in 0..<50 {if playback.position>0.15 {break};try await Task.sleep(nanoseconds:100_000_000)}
        XCTAssertTrue(playback.playing);XCTAssertGreaterThan(playback.position,0.15);XCTAssertNil(playback.error)
        playback.toggle()
        for _ in 0..<10 {if !playback.playing {break};try await Task.sleep(nanoseconds:50_000_000)}
        XCTAssertFalse(playback.playing)
        playback.seek(1.5);XCTAssertEqual(playback.position,1.5,accuracy:0.001)
        var project=Project();project.width=320;project.height=180
        project.clips=[Clip(kind:.text,name:"動画",track:0,start:0,duration:1)]
        try await MovieExporter.export(project:project,directory:root,destination:media.appendingPathComponent("sample.mp4")){_ in}
        let video=MediaAsset(name:"動画",file:"sample.mp4",kind:.video,duration:1)
        playback.open(video,directory:root)
        for _ in 0..<50 {if playback.position>0.1 {break};try await Task.sleep(nanoseconds:100_000_000)}
        XCTAssertEqual(playback.asset?.id,video.id);XCTAssertGreaterThan(playback.position,0.1);XCTAssertNil(playback.error)
        playback.stop();try await Task.sleep(nanoseconds:200_000_000)
        XCTAssertNil(playback.asset);XCTAssertNil(playback.player);XCTAssertFalse(playback.playing);XCTAssertEqual(playback.position,0)
    }
}
