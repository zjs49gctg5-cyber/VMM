import XCTest
import AppKit
import AVFoundation
@testable import VMM

final class ExportTrackBenchmarkTests:XCTestCase {
    func testManyLayerExportBenchmark()async throws {
        guard let output=ProcessInfo.processInfo.environment["VMM_TRACK_EXPORT_BENCHMARK"] else{throw XCTSkip("Opt-in export benchmark")}
        let root=URL(fileURLWithPath:output);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        var p=Project();p.width=640;p.height=360;p.fps=30;p.tracks=(0..<32).map{Track(name:"Layer \($0)")};p.clips=[]
        for i in 0..<160 {var c=Clip(kind:.shape,name:"shape \(i)",track:i%31,start:0,duration:2);c.color=i%2==0 ? "336699":"FFCC77";c.shapeStyle=ShapeStyle();c.shapeStyle?.width=0.05;c.shapeStyle?.height=0.05;c.x=Double(i%20)/20;c.y=Double(i/20)/8;p.clips.append(c)}
        var moving=Clip(kind:.shape,name:"moving",track:31,start:0,duration:2);moving.putMotionKey(.x,time:0,value:0.2,easing:.linear);moving.putMotionKey(.x,time:2,value:0.8);p.clips.append(moving)
        var settings=UserSettings();settings.exportWidth=640;settings.exportHeight=360;settings.exportFPS=30;settings.exportVideoMbps=4;settings.exportAudioKbps=192
        let renderer=FrameRenderer(),size=CGSize(width:640,height:360);var draw:[Double]=[]
        for frame in 0..<35 {let ctx=try XCTUnwrap(RasterTools.bitmap(size));let t=ProcessInfo.processInfo.systemUptime;renderer.draw(project:p,directory:root,time:Double(frame)/30,context:ctx,size:size);if frame>=5 {draw.append((ProcessInfo.processInfo.systemUptime-t)*1000)}}
        var exports:[Double]=[]
        for i in 0..<3 {let t=ProcessInfo.processInfo.systemUptime;try await MovieExporter.export(project:p,directory:root,destination:root.appendingPathComponent("test-\(i).mp4"),options:settings){_ in};exports.append(ProcessInfo.processInfo.systemUptime-t)}
        let a=AVURLAsset(url:root.appendingPathComponent("test-0.mp4"));let duration=try await a.load(.duration);XCTAssertEqual(duration.seconds,2,accuracy:0.1)
        print("TRACK_BENCH drawMedianMS=\(draw.sorted()[draw.count/2]) exportSeconds=\(exports)")
    }
}
