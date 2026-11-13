import XCTest
import AVFoundation
@testable import VMM

final class LiveSpeechTests:XCTestCase {
    func exercise(_ engine:SpeechEngine,_ flag:String)async throws {
        guard ProcessInfo.processInfo.environment[flag]=="1" else{throw XCTSkip("Set \(flag)=1 with the real engine/model running.")}
        var configuration=SpeechConfiguration.defaults(engine)
        if let endpoint=ProcessInfo.processInfo.environment[flag+"_URL"]{configuration.endpoint=endpoint}
        let service=SpeechService(),voices=try await service.speakers(configuration)
        let voice=try XCTUnwrap(voices.first);configuration=try XCTUnwrap(voice.configuration)
        let data=try await service.synthesize(text:"これは音声と動画出力の動作確認です。",speaker:voice.id,speed:1,configuration:configuration)
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-live-\(engine.rawValue)-\(UUID())")
        try FileManager.default.createDirectory(at:root.appendingPathComponent("Media"),withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let wav=root.appendingPathComponent("Media/speech.wav");try data.write(to:wav)
        let file=try AVAudioFile(forReading:wav),duration=Double(file.length)/file.processingFormat.sampleRate
        XCTAssertGreaterThan(duration,0.2)
        var clip=Clip(kind:.speech,name:engine.title,track:0,start:0,duration:duration,text:"音声エンジン実検証")
        clip.speechConfiguration=configuration;let asset=MediaAsset(name:engine.title,file:"speech.wav",kind:.audio,duration:duration,generatedSpeech:true);clip.assetID=asset.id
        let player=try ClipAudioPlayer(url:wav,clip:clip,time:0,volume:0.05);try await Task.sleep(nanoseconds:150_000_000);player.pause()
        var project=Project();project.width=320;project.height=180;project.assets=[asset];project.clips=[clip]
        let output=root.appendingPathComponent("speech.mp4");try await MovieExporter.export(project:project,directory:root,destination:output){_ in}
        let audio=try await AVURLAsset(url:output).loadTracks(withMediaType:.audio);XCTAssertEqual(audio.count,1)
        let decoded=root.appendingPathComponent("decoded.caf");let exists=try await AudioProcessor.decode(source:output,destination:decoded);XCTAssertTrue(exists)
        XCTAssertGreaterThan(try LoudnessAnalyzer.analyze(decoded).samplePeak,0.001)
        if let artifact=testArtifactDirectory(){let target=URL(fileURLWithPath:artifact).appendingPathComponent(engine.rawValue);try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true);try FileManager.default.copyItem(at:output,to:target.appendingPathComponent("speech.mp4"));try data.write(to:target.appendingPathComponent("speech.wav"))}
    }
    func testLiveAivisSpeech()async throws {try await exercise(.aivisSpeech,"VMM_LIVE_AIVIS")}
    func testLiveStyleBertVITS2()async throws {try await exercise(.styleBertVITS2,"VMM_LIVE_STYLE_BERT")}
    func testLiveQwen3TTS()async throws {try await exercise(.qwen3TTS,"VMM_LIVE_QWEN")}
    func testWrongServiceIsDiagnosed()async throws {
        // Reuse the existing injectable URL protocol rather than binding a real service.
        let configuration=URLSessionConfiguration.ephemeral;configuration.protocolClasses=[SpeechProtocol.self]
        let service=SpeechService(session:URLSession(configuration:configuration))
        SpeechProtocol.handler={_ in (200,Data("not JSON".utf8))};defer{SpeechProtocol.handler=nil}
        do {_=try await service.speakers(.defaults(.styleBertVITS2));XCTFail("Expected diagnostic")}catch{XCTAssertTrue(error.localizedDescription.contains("JSON"))}
    }
}
