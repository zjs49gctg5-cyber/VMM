import XCTest
import AVFoundation
@testable import VMM

final class AudioEnvelopeSafetyTests:XCTestCase {
    @MainActor func testLiveVoicevoxGeneratedWaveformPlaybackAndExport()async throws {
        guard let endpoint=ProcessInfo.processInfo.environment["VMM_LIVE_VOICEVOX_URL"] else {throw XCTSkip("Set VMM_LIVE_VOICEVOX_URL to exercise a real local engine")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-waveform-voicevox-\(UUID())")
        let store=EditorStore(preferencesDirectory:root)
        defer{store.cancelSpeech();store.pause();try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        store.settings.autosaveSeconds=0;store.autoSpeech=false;store.project=Project();store.project.width=320;store.project.height=180
        var configuration=SpeechConfiguration.defaults(.voicevox);configuration.endpoint=endpoint
        let choices=try await store.speechService.speakers(configuration),voice=try XCTUnwrap(choices.first)
        var speech=Clip(kind:.speech,name:"voice",track:0,start:0,duration:1,text:"これは音声波形の動作確認です。")
        speech.speakerID=voice.id;speech.speechConfiguration=configuration;speech.speechDirty=true
        store.project.clips=[speech];store.selectedID=speech.id;store.generateSpeech()
        for _ in 0..<600 where !store.generatingSpeech.isEmpty {try await Task.sleep(nanoseconds:50_000_000)}
        let generated=try XCTUnwrap(store.selected);XCTAssertFalse(generated.speechDirty,store.status)
        let asset=try XCTUnwrap(store.project.asset(for:generated)),envelope=try XCTUnwrap(asset.envelope)
        XCTAssertGreaterThan(envelope.count,1);XCTAssertGreaterThan(envelope.max() ?? 0,0.001)
        let url=store.directory.appendingPathComponent("Media").appendingPathComponent(asset.file)
        let player=try ClipAudioPlayer(url:url,clip:generated,time:0,volume:0);try await Task.sleep(nanoseconds:100_000_000);player.pause()
        let output=root.appendingPathComponent("voice.mp4")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try await MovieExporter.export(project:store.project,directory:store.directory,destination:output){_ in}
        let decoded=root.appendingPathComponent("voice.caf")
        let decodedAudio=try await AudioProcessor.decode(source:output,destination:decoded);XCTAssertTrue(decodedAudio)
        XCTAssertGreaterThan(try audioEnvelope(url:decoded).max() ?? 0,0.001)
    }
    func testWaveformPreservesFirstChannelAndPartialWindow()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-waveform-pcm-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let format=try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate:44100,channels:2))
        let buffer=try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:5000));buffer.frameLength=5000
        let data=try XCTUnwrap(buffer.floatChannelData)
        for i in 0..<5000 {data[0][i]=0.5;data[1][i]=0.1}
        for suffix in ["wav","caf"] {
            let file=root.appendingPathComponent("stereo.\(suffix)")
            do {let writer=try AVAudioFile(forWriting:file,settings:format.settings);try writer.write(from:buffer)}
            let values=try audioEnvelope(url:file)
            XCTAssertEqual(values.count,4,suffix)
            for value in values {XCTAssertEqual(value,0.5,accuracy:0.0001,suffix)}
        }
    }
    func testInvalidAndMissingMediaReturnAnError()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-waveform-invalid-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let invalid=root.appendingPathComponent("broken.wav")
        try Data([0x52,0x49,0x46,0x46,0,0,0,0]).write(to:invalid)
        XCTAssertThrowsError(try audioEnvelope(url:invalid))
        XCTAssertThrowsError(try audioEnvelope(url:root.appendingPathComponent("missing.wav")))
    }
    @MainActor func testVideoWithAudioProducesWaveform()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-waveform-aac-\(UUID())")
        let media=root.appendingPathComponent("Media")
        try FileManager.default.createDirectory(at:media,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let format=try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate:48000,channels:2))
        let buffer=try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:24000));buffer.frameLength=24000
        let data=try XCTUnwrap(buffer.floatChannelData)
        for i in 0..<24000 {let sample=Float(sin(Double(i)*2*Double.pi*440/48000)*0.4);data[0][i]=sample;data[1][i]=sample}
        do {let writer=try AVAudioFile(forWriting:media.appendingPathComponent("tone.wav"),settings:format.settings);try writer.write(from:buffer)}
        let audio=MediaAsset(name:"tone",file:"tone.wav",kind:.audio,duration:0.5)
        var sound=Clip(kind:.audio,name:"tone",track:1,start:0,duration:0.5);sound.assetID=audio.id
        var project=Project();project.width=320;project.height=180;project.assets=[audio]
        project.clips=[Clip(kind:.shape,name:"frame",track:0,start:0,duration:0.5),sound]
        let url=media.appendingPathComponent("with-audio.mp4")
        try await MovieExporter.export(project:project,directory:root,destination:url){_ in}
        let asset=MediaAsset(name:"movie",file:"with-audio.mp4",kind:.video,duration:0.5)
        let cache=TimelineMediaCache(),ready=expectation(description:"waveform request completes")
        XCTAssertNil(cache.envelope(asset:asset,directory:root,onReady:{ready.fulfill()}))
        await fulfillment(of:[ready],timeout:10)
        let values=try XCTUnwrap(cache.envelope(asset:asset,directory:root,onReady:{}))
        XCTAssertGreaterThan(values.count,10);XCTAssertGreaterThan(values.max() ?? 0,0.1)
    }
    @MainActor func testVideoWithoutAudioDoesNotCrashWaveformGeneration()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-waveform-silent-video-\(UUID())")
        let media=root.appendingPathComponent("Media")
        try FileManager.default.createDirectory(at:media,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        var project=Project();project.width=320;project.height=180
        project.clips=[Clip(kind:.shape,name:"frame",track:0,start:0,duration:0.2)]
        try await MovieExporter.export(project:project,directory:root,destination:media.appendingPathComponent("silent.mp4")){_ in}
        let asset=MediaAsset(name:"silent",file:"silent.mp4",kind:.video,duration:0.2)
        let cache=TimelineMediaCache(),ready=expectation(description:"waveform request completes")
        XCTAssertNil(cache.envelope(asset:asset,directory:root,onReady:{ready.fulfill()}))
        await fulfillment(of:[ready],timeout:10)
        XCTAssertEqual(cache.envelope(asset:asset,directory:root,onReady:{}),[])
    }
}
