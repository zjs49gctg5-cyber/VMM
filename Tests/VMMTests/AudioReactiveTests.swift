import XCTest
import AVFoundation
@testable import VMM
final class AudioReactiveTests:XCTestCase {
    func testNativeAnalysisBassOnsetAndStereo()throws {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("reactive-"+UUID().uuidString+".wav");defer{try? FileManager.default.removeItem(at:url)}
        let format=try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate:48000,channels:2)),buffer=try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:96000));buffer.frameLength=96000
        for i in 0..<96000{let time=Double(i)/48000,frequency=time<0.8 ? 100.0:2000.0,volume=(0.4..<1.2).contains(time) ? 0.4:0.0,sample=Float(sin(time*2 * .pi*frequency)*volume);buffer.floatChannelData![0][i]=sample;buffer.floatChannelData![1][i] = -sample}
        var settings=format.settings;settings[AVLinearPCMIsNonInterleaved]=false;var file:AVAudioFile?=try AVAudioFile(forWriting:url,settings:settings);try file?.write(from:buffer);file=nil
        let data=try ReactiveAudioAnalyzer.analyzePCM(url:url);try data.validated();XCTAssertEqual(data.amplitude.count,60);XCTAssertGreaterThan(data.amplitude[18],0.9);XCTAssertGreaterThan(data.bass[18],data.bass[30]*3);XCTAssertGreaterThan(data.onset.max() ?? 0,0.9)
        let a=AudioReactive(data:data,sourceOffset:0.4,timelineOffset:1,sourceDuration:0.8);XCTAssertEqual(a.value(at:0.9),0);XCTAssertGreaterThan(a.value(at:1.2),0.9);XCTAssertEqual(a.value(at:1.9),0)
    }
    func testReactiveAnimationTrimAndOldProjectCompatibility()throws {
        let data=ReactiveAudioData(amplitude:[0,1,0],bass:[0,0,0],onset:[0,1,0]);var c=Clip(kind:.shape,name:"pulse",track:0,start:3,duration:1);c.audioReactive=AudioReactive(data:data,sourceDuration:1,scaleAmount:1,shakeAmount:0.5);XCTAssertEqual(c.animated(at:3).scale,1);XCTAssertEqual(c.animated(at:3+1/30.0).scale,2,accuracy:0.000001)
        var trimmed=c;trimmed.start+=1/30.0;trimmed.animationOffset=1/30.0;XCTAssertEqual(trimmed.animated(at:trimmed.start).scale,2,accuracy:0.000001)
        var p=Project();p.clips=[c];XCTAssertEqual(try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(p)).validated(),p);c.audioReactive?.data.amplitude[0] = .nan;p.clips=[c];XCTAssertThrowsError(try p.validated())
    }
}
