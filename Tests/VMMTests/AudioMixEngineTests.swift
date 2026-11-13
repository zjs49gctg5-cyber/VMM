import XCTest
import AVFoundation
@testable import VMM

final class AudioMixEngineTests:XCTestCase {
    func testSharedEnginePanAndMasterDelivery()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-shared-engine-\(UUID())")
        try FileManager.default.createDirectory(at:root.appendingPathComponent("Media"),withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let wav=root.appendingPathComponent("Media/tone.wav");let format=PlaybackAudioEngine.format,source=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:144000)!
        source.frameLength=144000
        // A steady signal avoids asserting phase alignment of independently started players.
        for c in 0..<2 {for i in 0..<144000 {source.floatChannelData![c][i]=0.6}}
        var sourceSettings=format.settings;sourceSettings[AVLinearPCMIsNonInterleaved]=false
        var sourceFile:AVAudioFile?=try AVAudioFile(forWriting:wav,settings:sourceSettings);try sourceFile?.write(from:source);sourceFile=nil
        let asset=MediaAsset(name:"tone",file:"tone.wav",kind:.audio,duration:3)
        var c=Clip(kind:.audio,name:"left",track:0,start:0,duration:1),d=c
        c.assetID=asset.id;c.pan = -1;d.id=UUID();d.assetID=asset.id;d.pan = -1
        var p=Project();p.assets=[asset];p.clips=[c,d];p.width=320;p.height=180
        let shared=PlaybackAudioEngine()
        let first=try ClipAudioPlayer(url:wav,clip:c,time:0,volume:1,shared:shared)
        let second=try ClipAudioPlayer(url:wav,clip:d,time:0,volume:1,shared:shared)
        try await Task.sleep(nanoseconds:200_000_000)
        let live=shared.meter.reading
        XCTAssertGreaterThan(live.leftPeak,0.8);XCTAssertLessThan(live.rightPeak,0.002)
        first.pause();XCTAssertTrue(shared.engine.isRunning)
        try await Task.sleep(nanoseconds:100_000_000);XCTAssertGreaterThan(shared.meter.reading.leftPeak,0.5)
        second.pause();shared.stop()
        let float=root.appendingPathComponent("pan.wav")
        try await AudioOnlyExporter.export(project:p,directory:root,destination:float,floatPCM:true){_ in}
        let file=try AVAudioFile(forReading:float),buffer=AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:48000)!
        try file.read(into:buffer);let probe=AudioMeterProbe();probe.accept(buffer)
        XCTAssertGreaterThan(probe.reading.leftPeak,1.1);XCTAssertLessThan(probe.reading.rightPeak,0.002)
        var dynamics=MasterDynamics();dynamics.limiterEnabled=true;dynamics.ceilingDB = -3;p.masterDynamics=dynamics
        let limited=try await MixLoudnessAnalyzer.analyze(project:p,directory:root,options:UserSettings())
        XCTAssertLessThanOrEqual(limited.samplePeak,pow(10,-3/20)+0.02);XCTAssertGreaterThan(limited.samplePeak,0.5)
        let realtime=PlaybackAudioEngine(settings:dynamics)
        let a=try ClipAudioPlayer(url:wav,clip:c,time:0,volume:1,shared:realtime),b=try ClipAudioPlayer(url:wav,clip:d,time:0,volume:1,shared:realtime)
        try await Task.sleep(nanoseconds:200_000_000)
        XCTAssertLessThanOrEqual(realtime.meter.reading.peak,pow(10,-3/20)+0.02)
        XCTAssertGreaterThan(realtime.meter.reading.peak,0.5);a.pause();b.pause();realtime.stop()
        let movie=root.appendingPathComponent("limited.mp4"),decoded=root.appendingPathComponent("limited.caf")
        try await MovieExporter.export(project:p,directory:root,destination:movie){_ in}
        let didDecode=try await AudioProcessor.decode(source:movie,destination:decoded);XCTAssertTrue(didDecode)
        let delivered=try LoudnessAnalyzer.analyze(decoded)
        // AAC can introduce reconstruction overshoot; it is not a true-peak limiter.
        XCTAssertEqual(delivered.samplePeak,limited.samplePeak,accuracy:0.08)
        XCTAssertLessThan(delivered.samplePeak,pow(10,-3/20)+0.03)
        dynamics.limiterEnabled=false;dynamics.compressorEnabled=true;dynamics.thresholdDB = -24;p.masterDynamics=dynamics
        let compressed=try await MixLoudnessAnalyzer.analyze(project:p,directory:root,options:UserSettings())
        XCTAssertLessThan(compressed.samplePeak,0.7)
        let legacy=try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(Project()))
        XCTAssertNil(legacy.masterDynamics);XCTAssertNil(legacy.clips.first?.pan)
        p.clips[0].pan = .nan;XCTAssertThrowsError(try p.validated())
    }
}

extension AudioMixEngineTests {
    func testManyPlayersShareEngineAndReleaseTheirNodes()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-many-audio-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let wav=root.appendingPathComponent("tone.wav");try LoudnessTests().tone(wav,amplitude:0.01,channels:2)
        let shared=PlaybackAudioEngine(),baseline=shared.engine.attachedNodes.count
        var players:[ClipAudioPlayer]=[]
        let start=ProcessInfo.processInfo.systemUptime
        for i in 0..<32 {let c=Clip(kind:.audio,name:"\(i)",track:0,start:0,duration:1);players.append(try ClipAudioPlayer(url:wav,clip:c,time:0,volume:1,shared:shared))}
        print("Shared audio: 32 players prepared in \(ProcessInfo.processInfo.systemUptime-start)s; one hardware engine")
        XCTAssertEqual(shared.engine.attachedNodes.count,baseline+32*3)
        try await Task.sleep(nanoseconds:100_000_000);XCTAssertGreaterThan(shared.meter.reading.peak,0)
        players.forEach{$0.pause()};players=[];XCTAssertEqual(shared.engine.attachedNodes.count,baseline);shared.stop()
    }
}

extension AudioMixEngineTests {
    func testMasterLimiterDoesNotShiftQuietTransient()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-master-transient-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let input=root.appendingPathComponent("input.caf"),output=root.appendingPathComponent("out.caf"),format=PlaybackAudioEngine.format
        let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:48000)!;buffer.frameLength=48000
        for c in 0..<2 {for i in 0..<48000 {buffer.floatChannelData![c][i]=(i==12000 || i==47990) ? 0.1:0}}
        var options=format.settings;options[AVLinearPCMIsNonInterleaved]=false
        var file:AVAudioFile?=try AVAudioFile(forWriting:input,settings:options);try file?.write(from:buffer);file=nil
        var settings=MasterDynamics();settings.limiterEnabled=true
        try PlaybackAudioEngine.process(input,to:output,settings:settings)
        let rendered=try AVAudioFile(forReading:output);XCTAssertEqual(rendered.length,48000)
        try rendered.read(into:buffer);let samples=buffer.floatChannelData![0]
        let peak=(0..<24000).max{abs(samples[$0])<abs(samples[$1])}!
        XCTAssertEqual(peak,12000);XCTAssertEqual(samples[47990],0.1,accuracy:0.002)
    }
}

extension AudioMixEngineTests {
    func testScheduledPlayersPreservePhase()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-phase-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let wav=root.appendingPathComponent("tone.wav");try LoudnessTests().tone(wav,amplitude:0.1,channels:2)
        let shared=PlaybackAudioEngine(),clip=Clip(kind:.audio,name:"tone",track:0,start:0,duration:1)
        let a=try ClipAudioPlayer(url:wav,clip:clip,time:0,volume:1,shared:shared,autoplay:false)
        let b=try ClipAudioPlayer(url:wav,clip:clip,time:0,volume:1,shared:shared,autoplay:false)
        try shared.start()
        let time=AVAudioTime(hostTime:mach_absolute_time()+AVAudioTime.hostTime(forSeconds:0.1))
        try a.start(at:time,timelineTime:0);try b.start(at:time,timelineTime:0)
        try await Task.sleep(nanoseconds:250_000_000)
        XCTAssertEqual(shared.meter.reading.peak,0.2,accuracy:0.005)
        a.pause();b.pause();shared.stop()
    }
}

extension AudioMixEngineTests {
    @MainActor func testEditorSchedulesOverlappingAndUpcomingVoices()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-playback-sync-\(UUID())"),store=EditorStore(preferencesDirectory:root)
        store.autoSpeech=false;store.settings.autosaveSeconds=0
        defer{store.pause();try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        let wav=store.directory.appendingPathComponent("Media/tone.wav");try LoudnessTests().tone(wav,amplitude:0.1,channels:2)
        let asset=MediaAsset(name:"tone",file:"tone.wav",kind:.audio,duration:3)
        var a=Clip(kind:.audio,name:"a",track:0,start:0,duration:1.5),b=a
        a.assetID=asset.id;b.id=UUID();b.assetID=asset.id
        var c=a;c.id=UUID();c.start=0.8;c.duration=0.5;c.track=1
        store.project.assets=[asset];store.project.clips=[a,b,c];store.play()
        try await Task.sleep(nanoseconds:400_000_000)
        XCTAssertEqual(store.playbackAudioEngine?.meter.reading.peak ?? 0,0.2,accuracy:0.01)
        XCTAssertEqual(store.players.count,2)
        try await Task.sleep(nanoseconds:600_000_000)
        XCTAssertEqual(store.players.count,3)
        XCTAssertGreaterThan(store.playbackAudioEngine?.meter.reading.peak ?? 0,0.15)
    }
}
