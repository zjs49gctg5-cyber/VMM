import XCTest
import AVFoundation
@testable import VMM

final class MixWaveformTests:XCTestCase {
    func testUsesRealMixAndPreservesCancellation() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-mix-wave-test-\(UUID())"),media=root.appendingPathComponent("Media")
        try FileManager.default.createDirectory(at:media,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let format=AVAudioFormat(standardFormatWithSampleRate:48000,channels:1)!
        for (name,sign) in [("plus.wav",Float(1)),("minus.wav",Float(-1))] {
            let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:24000)!;buffer.frameLength=24000
            for i in 0..<24000 {buffer.floatChannelData![0][i]=sign*Float(sin(Double(i)*2*Double.pi*440/48000)*0.2)}
            var file:AVAudioFile?=try AVAudioFile(forWriting:media.appendingPathComponent(name),settings:format.settings);try file!.write(from:buffer);file=nil
        }
        let plus=MediaAsset(name:"plus",file:"plus.wav",kind:.audio,duration:0.5),minus=MediaAsset(name:"minus",file:"minus.wav",kind:.audio,duration:0.5)
        var a=Clip(kind:.audio,name:"plus",track:0,start:0,duration:0.5);a.assetID=plus.id
        var b=Clip(kind:.audio,name:"minus",track:1,start:0,duration:0.5);b.assetID=minus.id
        var project=Project();project.assets=[plus,minus];project.clips=[a]
        let audible=try await MixWaveformAnalyzer.analyze(project:project,directory:root)
        XCTAssertEqual(audible.duration,0.5,accuracy:0.001);XCTAssertGreaterThan(audible.peaks.max() ?? 0,0.1)
        project.clips=[a,b]
        let cancelled=try await MixWaveformAnalyzer.analyze(project:project,directory:root)
        XCTAssertLessThan(cancelled.peaks.max() ?? 1,0.01)
        project.clips[0].duration=3601
        do {_ = try await MixWaveformAnalyzer.analyze(project:project,directory:root);XCTFail("Should reject excessively long analysis")}catch{}
    }
}
