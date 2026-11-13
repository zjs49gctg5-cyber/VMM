import XCTest
import AppKit
import AVFoundation
@testable import VMM

private final class ProgressRecorder:@unchecked Sendable {
    private let lock=NSLock();private var phaseValues:[ExportPhase]=[];private var numbers:[Double]=[]
    func phase(_ phase:ExportPhase){lock.lock();defer{lock.unlock()};phaseValues.append(phase)}
    func progress(_ value:Double){lock.lock();defer{lock.unlock()};numbers.append(value)}
    func snapshot()->([ExportPhase],[Double]){lock.lock();defer{lock.unlock()};return (phaseValues,numbers)}
}
final class ExportProgressTests:XCTestCase {
    func testRealExportReportsStagesAndMuxProgress()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-progress-"+UUID().uuidString);try FileManager.default.createDirectory(at:root.appendingPathComponent("Media"),withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let format=AVAudioFormat(standardFormatWithSampleRate:48000,channels:1)!,buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:96000)!;buffer.frameLength=96000
        for i in 0..<Int(buffer.frameLength){buffer.floatChannelData![0][i]=Float(sin(Double(i)*2*Double.pi*440/48000)*0.2)}
        var file:AVAudioFile?=try AVAudioFile(forWriting:root.appendingPathComponent("Media/tone.wav"),settings:format.settings);try file?.write(from:buffer);file=nil
        var project=Project();project.width=640;project.height=360;let asset=MediaAsset(name:"tone",file:"tone.wav",kind:.audio,duration:2);project.assets=[asset]
        var audio=Clip(kind:.audio,name:"tone",track:0,start:0,duration:2);audio.assetID=asset.id
        project.clips=[Clip(kind:.shape,name:"image",track:1,start:0,duration:2),audio]
        for explicit in [true,false] {
            let recorder=ProgressRecorder();var settings=UserSettings();if explicit{settings.exportVideoMbps=4;settings.exportAudioKbps=192}
            let output=root.appendingPathComponent(explicit ? "explicit.mp4":"default.mp4")
            try await MovieExporter.export(project:project,directory:root,destination:output,options:settings,phase:{recorder.phase($0)}){recorder.progress($0)}
            let (phases,values)=recorder.snapshot();XCTAssertEqual(phases,[.preparing,.rendering,.audioPreparing,.muxing,.saving]);XCTAssertEqual(values.last,1);if explicit {XCTAssertTrue(values.contains{$0>0.90 && $0<0.98},"Mux progress must advance: \(values)")};XCTAssertTrue(values.allSatisfy{$0>=0 && $0<=1});XCTAssertTrue(zip(values,values.dropFirst()).allSatisfy{$0 <= $1})
            let movie=AVURLAsset(url:output);let tracks=try await movie.loadTracks(withMediaType:.audio);XCTAssertEqual(tracks.count,1)
        }
    }
}
