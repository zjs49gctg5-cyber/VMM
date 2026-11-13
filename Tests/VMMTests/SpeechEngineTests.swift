import XCTest
import AVFoundation
@testable import VMM

final class SpeechProtocol:URLProtocol {
    static var handler:((URLRequest)throws->(Int,Data))?
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {
        do {let (code,data)=try Self.handler!(request)
            client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:code,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
        } catch {client?.urlProtocol(self,didFailWithError:error)}
    }
    override func stopLoading() {}
}
final class SpeechEngineTests:XCTestCase {
    func service()->SpeechService {let c=URLSessionConfiguration.ephemeral;c.protocolClasses=[SpeechProtocol.self];return SpeechService(session:URLSession(configuration:c))}
    func json(_ v:Any)throws->Data {try JSONSerialization.data(withJSONObject:v)}
    func query(_ r:URLRequest)->[String:String] {Dictionary(uniqueKeysWithValues:URLComponents(url:r.url!,resolvingAgainstBaseURL:false)!.queryItems!.map{($0.name,$0.value ?? "")})}
    func body(_ r:URLRequest)throws->[String:Any] {
        let data:Data
        if let b=r.httpBody {data=b} else if let stream=r.httpBodyStream {stream.open();defer{stream.close()};var b=[UInt8](repeating:0,count:4096);var all=Data();while stream.hasBytesAvailable {let n=stream.read(&b,maxLength:b.count);if n<=0 {break};all.append(contentsOf:b.prefix(n))};data=all} else {throw VMMError.message("Missing body")}
        return try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
    }
    func wave()throws->Data {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-speech-\(UUID()).wav");defer{try? FileManager.default.removeItem(at:url)}
        let format=AVAudioFormat(standardFormatWithSampleRate:24000,channels:1)!,buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:24000)!
        buffer.frameLength=24000
        for i in 0..<24000 {buffer.floatChannelData![0][i]=Float(sin(Double(i)*2 * .pi*440/24000)*0.2)}
        var file:AVAudioFile?=try AVAudioFile(forWriting:url,settings:format.settings);try file!.write(from:buffer);file=nil
        return try Data(contentsOf:url)
    }
    override func tearDown(){SpeechProtocol.handler=nil;VMMLocalization.language = .japanese;super.tearDown()}
    func testVoicevoxAndAivisRetainQueryFieldsAndSignedStyles()async throws {
        let wav=try wave()
        for engine in [SpeechEngine.voicevox,.aivisSpeech] {
            let config=SpeechConfiguration.defaults(engine)
            SpeechProtocol.handler={r in
                switch r.url!.path {
                case "/speakers":return (200,try self.json([["name":"Voice","styles":[["name":"Normal","id":-123456]]]]))
                case "/audio_query":XCTAssertEqual(r.httpMethod,"POST");XCTAssertEqual(self.query(r)["speaker"],"-123456");XCTAssertEqual(self.query(r)["text"],"テスト & text");return (200,try self.json(["speedScale":1,"engineSpecific":"keep","accent_phrases":[]]))
                case "/synthesis":let b=try self.body(r);XCTAssertEqual(b["engineSpecific"] as? String,"keep");XCTAssertEqual(b["speedScale"] as? Double,1.25);return (200,wav)
                default:throw VMMError.message("Unexpected route")
                }
            }
            let voices=try await service().speakers(config);XCTAssertEqual(voices.first?.id,-123456);XCTAssertEqual(voices.first?.configuration?.engine,engine)
            let result=try await service().synthesize(text:"テスト & text",speaker:-123456,speed:1.25,configuration:config);XCTAssertEqual(result,wav)
        }
    }
    func testStyleBertModelsAndQueryContractStableAcrossOrdering()async throws {
        let wav=try wave(),config=SpeechConfiguration.defaults(.styleBertVITS2)
        var modelID="0"
        SpeechProtocol.handler={r in
            if r.url!.path=="/models/info" {return (200,try self.json([modelID:["model_path":"/models/A/model.safetensors","spk2id":["Alice":0],"style2id":["Neutral":0,"Happy":1]]]))}
            XCTAssertEqual(r.url!.path,"/voice");XCTAssertEqual(r.httpMethod,"POST");XCTAssertNil(r.httpBody)
            let q=self.query(r);XCTAssertEqual(q["model_name"],"A");XCTAssertEqual(q["speaker_name"],"Alice");XCTAssertEqual(q["style"],"Happy");XCTAssertEqual(q["language"],"EN");XCTAssertEqual(Double(q["length"]!),0.8);return (200,wav)
        }
        let first=try await service().speakers(config);XCTAssertEqual(first.count,2);modelID="4"
        let second=try await service().speakers(config);XCTAssertEqual(first.map(\.id),second.map(\.id))
        var c=try XCTUnwrap(second.first?.configuration);c.language="EN";XCTAssertEqual(c.style,"Happy")
        let result=try await service().synthesize(text:"Hello",speaker:second[0].id,speed:1.25,configuration:c);XCTAssertEqual(result,wav)
    }
    func testQwenBridgeContractAndPitchPreservingSpeed()async throws {
        let wav=try wave(),config=SpeechConfiguration.defaults(.qwen3TTS)
        SpeechProtocol.handler={r in
            if r.url!.path=="/speakers" {return (200,try self.json(["speakers":["Ryan","Ono_Anna"]]))}
            XCTAssertNil(r.url!.query);let b=try self.body(r);XCTAssertEqual(b["speaker"] as? String,"Ono_Anna");XCTAssertEqual(b["language"] as? String,"English");XCTAssertEqual(b["instruct"] as? String,"Speak softly");return (200,wav)
        }
        let voices=try await service().speakers(config);var c=try XCTUnwrap(voices.last?.configuration);c.language="English";c.instruction="Speak softly"
        let data=try await service().synthesize(text:"Hello",speaker:voices[1].id,speed:1.25,configuration:c)
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-qwen-rate-\(UUID()).wav");defer{try? FileManager.default.removeItem(at:url)};try data.write(to:url)
        let file=try AVAudioFile(forReading:url);XCTAssertEqual(Double(file.length)/file.processingFormat.sampleRate,0.8,accuracy:0.03)
        let helper=AdvancedTests();XCTAssertGreaterThan(try helper.energy(url,frequency:440),0.01);XCTAssertLessThan(try helper.energy(url,frequency:550),0.01)
    }
    func testInvalidEndpointsAndResponses()async throws {
        for endpoint in ["https://example.com","http://127.0.0.1@evil.com","file:///tmp/a","http://localhost:0","http://localhost?token=x"] {var c=SpeechConfiguration();c.endpoint=endpoint;XCTAssertThrowsError(try c.validated())}
        SpeechProtocol.handler={_ in (200,Data("not a wav".utf8))}
        var c=SpeechConfiguration.defaults(.qwen3TTS);c.speaker="Ryan"
        do {_ = try await service().synthesize(text:"Hi",speaker:1,speed:1,configuration:c);XCTFail("Must reject non-WAV")}catch{}
        SpeechProtocol.handler={_ in (503,Data("engine offline".utf8))}
        do {_ = try await service().speakers(c);XCTFail("Must report failure")}catch{XCTAssertTrue(error.localizedDescription.contains("503"))}
    }
    @MainActor func testDirtyBatchFailureRetryAndLibraryExclusion()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-batch-test-\(UUID())"),store=EditorStore(preferencesDirectory:root)
        store.autoSpeech=false;store.project=Project();store.speechService=service()
        defer{store.cancelSpeech();try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        let wav=try wave();var failed=true
        let cleanAsset=MediaAsset(name:"clean",file:"clean.wav",kind:.audio,duration:1,generatedSpeech:true)
        try wav.write(to:store.directory.appendingPathComponent("Media/clean.wav"));store.project.assets=[cleanAsset]
        SpeechProtocol.handler={request in
            let text=try self.body(request)["text"] as? String
            return text=="fail" && failed ? (503,Data()):(200,wav)
        }
        var config=SpeechConfiguration.defaults(.qwen3TTS);config.speaker="Ryan"
        for text in ["ok","fail","clean"] {
            var clip=Clip(kind:.speech,name:text,track:1,start:0,duration:1,text:text)
            clip.speechConfiguration=config;clip.speechDirty=text != "clean"
            if text=="clean" {clip.assetID=cleanAsset.id}
            store.project.clips.append(clip)
        }
        store.generateDirtySpeech();XCTAssertEqual(store.speechBatchTotal,2)
        for _ in 0..<100 where !store.generatingSpeech.isEmpty {try await Task.sleep(nanoseconds:20_000_000)}
        XCTAssertTrue(store.generatingSpeech.isEmpty);XCTAssertEqual(store.speechFailures.count,1)
        XCTAssertEqual(store.speechBatchCompleted,2);XCTAssertEqual(store.project.assets.count,2)
        XCTAssertNil(store.error);XCTAssertTrue(store.libraryAssets.isEmpty)
        failed=false;store.retryFailedSpeech()
        for _ in 0..<100 where !store.generatingSpeech.isEmpty {try await Task.sleep(nanoseconds:20_000_000)}
        XCTAssertTrue(store.speechFailures.isEmpty);XCTAssertEqual(store.project.assets.count,3)
        XCTAssertTrue(store.project.clips.allSatisfy{!$0.speechDirty});XCTAssertTrue(store.libraryAssets.isEmpty)
        store.generateDirtySpeech();XCTAssertTrue(store.generatingSpeech.isEmpty);XCTAssertEqual(store.speechBatchTotal,0)
    }
    @MainActor func testStoredConfigurationGenerationPlaybackAndMP4()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-engine-test-\(UUID())"),store=EditorStore(preferencesDirectory:root)
        defer{store.cancelSpeech();store.pause();try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        store.autoSpeech=false;store.project=Project();store.project.width=640;store.project.height=360
        let wav=try wave();SpeechProtocol.handler={r in XCTAssertEqual(r.url!.port,8001);return (200,wav)};store.speechService=service()
        var c=Clip(kind:.speech,name:"Qwen",track:1,start:0,duration:1,text:"Speech test",fontSize:36)
        var config=SpeechConfiguration.defaults(.qwen3TTS);config.speaker="Ryan";c.speechConfiguration=config
        store.project.clips=[c];store.selectedID=c.id
        store.updateSpeechConnection(.defaults(.aivisSpeech));store.generateSpeech()
        for _ in 0..<100 where !store.generatingSpeech.isEmpty {try await Task.sleep(nanoseconds:50_000_000)}
        let generated=try XCTUnwrap(store.selected);XCTAssertFalse(generated.speechDirty,store.status);XCTAssertTrue(store.libraryAssets.isEmpty)
        let asset=try XCTUnwrap(store.project.asset(for:generated)),url=store.directory.appendingPathComponent("Media").appendingPathComponent(asset.file)
        let player=try ClipAudioPlayer(url:url,clip:generated,time:0,volume:0.01);player.pause()
        let package=root.appendingPathComponent("sample.vmm");try ProjectPackage.write(store.project,media:store.directory.appendingPathComponent("Media"),to:package)
        let decoded=try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(store.project));XCTAssertEqual(decoded.clips[0].speechConfiguration,config)
        let preview=try AdvancedTests().render(store.project,0.2,directory:store.directory);XCTAssertEqual(preview.width,640)
        let output=root.appendingPathComponent("speech.mp4");try await MovieExporter.export(project:store.project,directory:store.directory,destination:output){_ in}
        let tracks=try await AVURLAsset(url:output).loadTracks(withMediaType:.audio);XCTAssertEqual(tracks.count,1)
    }
    @MainActor func testConvertedCaptionKeepsTimingAfterSynthesis() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-caption-speech-\(UUID())"),store=EditorStore(preferencesDirectory:root)
        defer{store.cancelSpeech();store.pause();try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        store.autoSpeech=false;store.project=Project();store.project.width=640;store.project.height=360;store.selectedTrack=1
        var config=SpeechConfiguration.defaults(.qwen3TTS);config.speaker="Ryan";store.settings.speechConfiguration=config
        let wav=try wave();SpeechProtocol.handler={_ in (200,wav)};store.speechService=service()
        try store.importCaptions("1\n00:00:00,000 --> 00:00:00,500\nSpeech",format:.srt)
        try store.convertSelectedTextToSpeech();store.generateSpeech()
        for _ in 0..<100 where !store.generatingSpeech.isEmpty {try await Task.sleep(nanoseconds:50_000_000)}
        let clip=try XCTUnwrap(store.selected);XCTAssertFalse(clip.speechDirty,store.status);XCTAssertEqual(clip.duration,0.5,accuracy:0.001)
        let decoded=try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(store.project));XCTAssertEqual(decoded.clips[0].preserveSpeechDuration,true)
        let asset=try XCTUnwrap(store.project.asset(for:clip)),url=store.directory.appendingPathComponent("Media").appendingPathComponent(asset.file)
        let player=try ClipAudioPlayer(url:url,clip:clip,time:0,volume:0.01);player.pause()
        let output=root.appendingPathComponent("caption-speech.mp4");try await MovieExporter.export(project:store.project,directory:store.directory,destination:output){_ in}
        let tracks=try await AVURLAsset(url:output).loadTracks(withMediaType:.audio);XCTAssertEqual(tracks.count,1)
    }
    @MainActor func testSettingsAPILanguageAndVoiceConfigurationCompatibility()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-language-test-\(UUID())"),store=EditorStore(preferencesDirectory:root),api=EditorCommands();api.store=store
        defer{store.pause();try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        let request:[String:Any]=["command":"settings.update","properties":["uiLanguage":"en","speechConfiguration":["engine":"aivisSpeech","endpoint":"http://127.0.0.1:10101"]]]
        XCTAssertEqual(api.execute(body:try json(request)).status,200)
        XCTAssertEqual(L("音声エンジン"),"Speech Engine");XCTAssertEqual(L("素材ライブラリ"),"Media Library")
        let saved=try JSONDecoder().decode(UserSettings.self,from:Data(contentsOf:root.appendingPathComponent("settings.json")));XCTAssertEqual(saved.uiLanguage,.english);XCTAssertEqual(saved.speechConfiguration?.engine,.aivisSpeech)
        let legacy=try JSONDecoder().decode(UserSettings.self,from:JSONEncoder().encode(UserSettings()));XCTAssertNil(legacy.uiLanguage);XCTAssertNil(legacy.speechConfiguration)
        let clip=try JSONDecoder().decode(Clip.self,from:JSONEncoder().encode(Clip(kind:.speech,name:"素材ライブラリ",track:0,start:0,duration:1,text:"日本語")));XCTAssertNil(clip.speechConfiguration);XCTAssertEqual(clip.name,"素材ライブラリ");XCTAssertEqual(clip.text,"日本語")
    }
    @MainActor func testScriptAndAPIDialogueUseSelectedEngine()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-script-engine-\(UUID())"),store=EditorStore(preferencesDirectory:root),api=EditorCommands();api.store=store
        defer{store.pause();try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        store.autoSpeech=false;store.project=Project()
        var config=SpeechConfiguration.defaults(.qwen3TTS);config.speaker="Ryan"
        store.settings.speechConfiguration=config;let id=SpeechService.voiceID("Ryan")
        store.voices=[VoiceChoice(id:id,name:"Ryan",configuration:config)]
        try store.importScript("字幕を読み上げます。")
        XCTAssertEqual(store.project.clips.last?.speechConfiguration,config);XCTAssertEqual(store.project.clips.last?.speakerID,id)
        let response=api.execute(body:try json(["command":"clip.add","kind":"speech","properties":["text":"API dialogue"]]))
        XCTAssertEqual(response.status,200);XCTAssertEqual(store.project.clips.last?.speechConfiguration,config)
        XCTAssertEqual(store.project.clips.last?.speakerName,"Ryan")
    }
    func testLipSyncDoesNotMixEnginesAndPresetRetainsVoice()throws {
        var p=Project(),config=SpeechConfiguration.defaults(.aivisSpeech)
        config.endpoint="http://localhost:10101"
        let asset=MediaAsset(name:"speech",file:"test.wav",kind:.audio,duration:1,generatedSpeech:true,envelope:[0.2,0.2,0.2,0.2])
        var speech=Clip(kind:.speech,name:"Speech",track:1,start:0,duration:1);speech.speakerID=5;speech.speechConfiguration=config;speech.assetID=asset.id;speech.speechDirty=false
        var character=Clip(kind:.image,name:"Character",track:0,start:0,duration:1);character.characterSpeakerID=5
        p.assets=[asset];p.clips=[speech,character]
        XCTAssertFalse(p.mouthIsOpen(for:character,at:0.05));character.characterSpeechEngine = .aivisSpeech
        XCTAssertTrue(p.mouthIsOpen(for:character,at:0.05))
        let preset=CharacterPreset(name:"Alice",speechConfiguration:config,speakerName:"Alice / Happy",speakerID:5)
        let restored=try JSONDecoder().decode(CharacterPreset.self,from:JSONEncoder().encode(preset));var target=speech;restored.apply(to:&target)
        XCTAssertEqual(target.speechConfiguration,config);XCTAssertEqual(target.speakerName,"Alice / Happy")
        var legacy=CharacterPreset(name:"Legacy");legacy.speakerID=0;legacy.apply(to:&target);XCTAssertNil(target.speechConfiguration);XCTAssertEqual(target.speakerName,"")
    }
    func testStyleBertFallbackOmitsMissingModelName()async throws {
        var config=SpeechConfiguration.defaults(.styleBertVITS2);config.modelID=3;config.speaker="Alice";config.style="Neutral"
        let wav=try wave()
        SpeechProtocol.handler={request in XCTAssertNil(self.query(request)["model_name"]);XCTAssertEqual(self.query(request)["model_id"],"3");return (200,wav)}
        _ = try await service().synthesize(text:"テスト",speaker:1,speed:1,configuration:config)
    }
    func testNewClientLiveVoicevoxWhenRequested()async throws {
        guard ProcessInfo.processInfo.environment["VMM_LIVE_VOICEVOX"]=="1" else{throw XCTSkip("Live engine required")}
        let c=SpeechConfiguration.defaults(.voicevox),service=SpeechService();let voices=try await service.speakers(c)
        let data=try await service.synthesize(text:"新しい音声エンジン接続のテストです。",speaker:try XCTUnwrap(voices.first?.id),speed:1,configuration:c);XCTAssertGreaterThan(data.count,1000)
    }
}
