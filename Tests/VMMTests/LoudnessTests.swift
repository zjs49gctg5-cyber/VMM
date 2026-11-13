import XCTest
import AVFoundation
@testable import VMM

final class LoudnessTests:XCTestCase {
    func tone(_ url:URL,amplitude:Double=0.1,channels:Int=1,silence:Bool=false)throws {
        let format=AVAudioFormat(standardFormatWithSampleRate:48000,channels:AVAudioChannelCount(channels))!,buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:48000*3)!
        buffer.frameLength=48000*3
        for c in 0..<channels {for i in 0..<Int(buffer.frameLength){buffer.floatChannelData![c][i]=Float(silence && i>=48000 ? 0:sin(Double(i)*2*Double.pi*997/48000)*amplitude)}}
        var settings=format.settings;settings[AVLinearPCMIsNonInterleaved]=false
        let file=try AVAudioFile(forWriting:url,settings:settings);try file.write(from:buffer)
    }
    func testKWeightingReferenceAndGatingAndPeakCeiling()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-loudness-\(UUID())");try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let url=root.appendingPathComponent("tone.wav");try tone(url)
        let mono=try LoudnessAnalyzer.analyze(url);XCTAssertEqual(try XCTUnwrap(mono.integratedLUFS),-23.01,accuracy:0.1);XCTAssertEqual(mono.samplePeak,0.1,accuracy:0.001)
        try tone(url,channels:2);let stereo=try LoudnessAnalyzer.analyze(url);XCTAssertEqual(try XCTUnwrap(stereo.integratedLUFS),-20,accuracy:0.1)
        try tone(url,silence:true);let gated=try LoudnessAnalyzer.analyze(url);XCTAssertEqual(try XCTUnwrap(gated.integratedLUFS),-23.01,accuracy:0.9)
        XCTAssertEqual(mono.gain(target:-3),pow(10,-1/20)/0.1,accuracy:0.001)
        try tone(url,amplitude:0);XCTAssertNil(try LoudnessAnalyzer.analyze(url).integratedLUFS)
    }
    func testActualMixCancellationAndOverload()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-real-mix-\(UUID())")
        try FileManager.default.createDirectory(at:root.appendingPathComponent("Media"),withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        try tone(root.appendingPathComponent("Media/positive.wav"),amplitude:0.6,channels:2)
        try tone(root.appendingPathComponent("Media/negative.wav"),amplitude:-0.6,channels:2)
        let a=MediaAsset(name:"positive",file:"positive.wav",kind:.audio,duration:3),b=MediaAsset(name:"negative",file:"negative.wav",kind:.audio,duration:3)
        var p=Project(),c=Clip(kind:.audio,name:"a",track:0,start:0,duration:1),d=Clip(kind:.audio,name:"b",track:1,start:0,duration:1)
        c.assetID=a.id;d.assetID=b.id;p.assets=[a,b];p.clips=[c,d]
        let cancelled=try await MixLoudnessAnalyzer.analyze(project:p,directory:root,options:UserSettings())
        XCTAssertLessThan(cancelled.samplePeak,0.00001);XCTAssertNil(cancelled.integratedLUFS)
        p.clips[1].assetID=a.id
        let overload=try await MixLoudnessAnalyzer.analyze(project:p,directory:root,options:UserSettings())
        XCTAssertEqual(overload.samplePeak,1.2,accuracy:0.005);XCTAssertGreaterThan(overload.clippedFrames,0)
        XCTAssertGreaterThan(try XCTUnwrap(overload.truePeakEstimate),1.19)
        p.masterVolume=0.5
        let attenuated=try await MixLoudnessAnalyzer.analyze(project:p,directory:root,options:UserSettings())
        XCTAssertEqual(attenuated.samplePeak,0.6,accuracy:0.005);XCTAssertEqual(attenuated.clippedFrames,0)
    }
    func testMasterAndNormalizedVolumeParentsAndLegacyValidation()throws {
        var p=Project(),c=Clip(kind:.audio,name:"tone",track:0,start:0,duration:2),g=Clip(kind:.group,name:"parent",track:1,start:0,duration:2)
        c.normalizationGain=3;c.volume=0.5;c.parentID=g.id;g.volume=2;p.clips=[c,g];p.masterVolume=0.25
        XCTAssertEqual(p.effectiveAudioVolume(c,at:0.5),0.75);XCTAssertEqual(p.audioHeadroom(for:c),1)
        p.masterVolume=2;XCTAssertEqual(p.effectiveAudioVolume(c,at:0.5),6);XCTAssertEqual(p.audioHeadroom(for:c),6)
        _=try p.validated();p.clips[0].normalizationGain = .nan;XCTAssertThrowsError(try p.validated())
        var legacy=Project();legacy.clips=[Clip(kind:.shape,name:"legacy",track:0,start:0,duration:1)]
        let decoded=try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(legacy));XCTAssertNil(decoded.masterVolume);XCTAssertNil(decoded.clips[0].normalizationGain)
    }
    func testStereoPeakRMSDrainAndHold()throws {
        let format=AVAudioFormat(standardFormatWithSampleRate:48000,channels:2)!
        let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:4)!;buffer.frameLength=4
        for i in 0..<4{buffer.floatChannelData![0][i]=[1.2,-0.6,0,0][i];buffer.floatChannelData![1][i]=[0.1,-0.1,0.1,-0.1][i]}
        let probe=AudioMeterProbe();probe.accept(buffer)
        let first=probe.drain();XCTAssertEqual(first.leftPeak,1.2,accuracy:0.00001);XCTAssertEqual(first.rightPeak,0.1,accuracy:0.00001)
        XCTAssertEqual(first.leftRMS,sqrt(1.8/4),accuracy:0.00001);XCTAssertEqual(first.rightRMS,0.1,accuracy:0.00001)
        let between=probe.drain();XCTAssertEqual(between.peak,0);XCTAssertEqual(between.leftRMS,first.leftRMS)
        // Polling must retain a transient followed by a quieter buffer.
        probe.accept(buffer);for i in 0..<4{buffer.floatChannelData![0][i]=0;buffer.floatChannelData![1][i]=0};probe.accept(buffer)
        let accumulated=probe.drain();XCTAssertEqual(accumulated.leftPeak,first.leftPeak);XCTAssertEqual(accumulated.leftRMS,sqrt(1.8/8),accuracy:0.00001)
        var display=AudioMeterDisplay();display.update(first,elapsed:0.03);XCTAssertTrue(display.overload)
        display.update(AudioMeterReading(),elapsed:1);XCTAssertLessThan(display.current.peak,0.16);XCTAssertEqual(display.hold.peak,first.peak)
        display.clearCurrent();XCTAssertEqual(display.current,AudioMeterReading());XCTAssertTrue(display.overload)
        display.reset();XCTAssertFalse(display.overload);XCTAssertEqual(display.hold,AudioMeterReading())
        let bound=AudioMeterReading.upperBound([first,first]);XCTAssertEqual(bound.leftPeak,2*first.leftPeak);XCTAssertEqual(bound.rightRMS,0.2,accuracy:0.00001)
        XCTAssertEqual(AudioMeterReading.decibels(0.1),-20,accuracy:0.00001)
        let mono=AVAudioPCMBuffer(pcmFormat:AVAudioFormat(standardFormatWithSampleRate:48000,channels:1)!,frameCapacity:4)!;mono.frameLength=4
        for i in 0..<4{mono.floatChannelData![0][i]=0.5};probe.accept(mono);let duplicated=probe.drain();XCTAssertEqual(duplicated.leftPeak,duplicated.rightPeak)
    }
    func testRealtimeMeterAndExportedMasterNormalization()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-meter-\(UUID())");try FileManager.default.createDirectory(at:root.appendingPathComponent("Media"),withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let wav=root.appendingPathComponent("Media/tone.wav");try tone(wav,channels:2)
        let asset=MediaAsset(name:"tone",file:"tone.wav",kind:.audio,duration:3)
        var p=Project(),c=Clip(kind:.audio,name:"tone",track:0,start:0,duration:1)
        c.assetID=asset.id;c.normalizationGain=4;c.volume=0.5;p.masterVolume=0.5;p.assets=[asset];p.clips=[c];p.width=320;p.height=180
        let player=try ClipAudioPlayer(url:wav,clip:c,time:0,volume:p.effectiveAudioVolume(c,at:0.2));defer{player.pause()}
        var peak=0.0
        for _ in 0..<30 {try await Task.sleep(nanoseconds:20_000_000);peak=max(peak,player.meter.peak)}
        XCTAssertGreaterThan(peak,0.08);XCTAssertLessThan(peak,0.13)
        player.setVolume(0.5)
        try await Task.sleep(nanoseconds:100_000_000)
        var attenuated=0.0
        for _ in 0..<10{try await Task.sleep(nanoseconds:20_000_000);attenuated=max(attenuated,player.meter.reading.leftPeak)}
        XCTAssertEqual(attenuated,0.05,accuracy:0.015)
        player.pause()
        let movie=root.appendingPathComponent("master.mp4");try await MovieExporter.export(project:p,directory:root,destination:movie){_ in}
        let decoded=root.appendingPathComponent("out.caf");let audio=try await AudioProcessor.decode(source:movie,destination:decoded);XCTAssertTrue(audio)
        let measured=try LoudnessAnalyzer.analyze(decoded);XCTAssertEqual(try XCTUnwrap(measured.integratedLUFS),-20,accuracy:0.5);XCTAssertEqual(measured.samplePeak,0.1,accuracy:0.02)
        var explicit=UserSettings();explicit.exportVideoMbps=2;explicit.exportAudioKbps=192;explicit.rangeStart=0.2;explicit.rangeEnd=0.8
        let presetMovie=root.appendingPathComponent("explicit.mp4"),presetAudio=root.appendingPathComponent("explicit.caf")
        try await MovieExporter.export(project:p,directory:root,destination:presetMovie,options:explicit){_ in}
        let didDecode=try await AudioProcessor.decode(source:presetMovie,destination:presetAudio);XCTAssertTrue(didDecode)
        let presetMeasured=try LoudnessAnalyzer.analyze(presetAudio);XCTAssertEqual(try XCTUnwrap(presetMeasured.integratedLUFS),-20,accuracy:0.5);XCTAssertEqual(presetMeasured.samplePeak,0.1,accuracy:0.02)
    }
}
