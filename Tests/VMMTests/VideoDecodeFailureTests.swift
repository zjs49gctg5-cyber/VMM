import XCTest
import AppKit
@testable import VMM

final class VideoDecodeFailureTests:XCTestCase {
    func testInvalidVideoFailsExportWithoutReplacingDestination() async throws {
        let fm=FileManager.default,root=fm.temporaryDirectory.appendingPathComponent("vmm-invalid-video-\(UUID())")
        let media=root.appendingPathComponent("Media")
        try fm.createDirectory(at:media,withIntermediateDirectories:true)
        defer {try? fm.removeItem(at:root)}
        try Data("invalid video data".utf8).write(to:media.appendingPathComponent("broken.mp4"))
        var project=Project();project.width=320;project.height=180;project.fps=30
        let asset=MediaAsset(name:"broken.mp4",file:"broken.mp4",kind:.video,duration:1)
        var clip=Clip(kind:.video,name:"broken",track:0,start:0,duration:0.5);clip.assetID=asset.id
        project.assets=[asset];project.clips=[clip]
        let ctx=try XCTUnwrap(RasterTools.bitmap(CGSize(width:320,height:180))),renderer=FrameRenderer(useProxies:false)
        renderer.draw(project:project,directory:root,time:0,context:ctx,size:CGSize(width:320,height:180))
        XCTAssertTrue(renderer.videoDecodeFailure?.contains("broken.mp4") == true)
        let destination=root.appendingPathComponent("output.mp4"),original=Data("preserve".utf8)
        try original.write(to:destination)
        do {try await MovieExporter.export(project:project,directory:root,destination:destination,overwrite:true){_ in};XCTFail("Invalid video must not export")}
        catch {XCTAssertTrue(error.localizedDescription.contains("broken.mp4"),"\(error)")}
        XCTAssertEqual(try Data(contentsOf:destination),original)
    }
}
