import AppKit
import XCTest
@testable import VMM

final class SceneMetadataPerformanceTests:XCTestCase {
    func testCachedSceneMembershipMatchesReferenceAndInvalidates() throws {
        let size=CGSize(width:320,height:180),directory=FileManager.default.temporaryDirectory
        var project=Project();project.width=320;project.height=180
        var shape=Clip(kind:.shape,name:"shape",track:0,start:0,duration:2);shape.color="FF0000"
        var group=Clip(kind:.group,name:"group",track:1,start:0,duration:2);group.sceneMembers=[shape.id]
        project.clips=[shape,group]
        let cached=FrameRenderer(),reference=FrameRenderer();reference.reuseSceneMetadata=false
        func pixels(_ renderer:FrameRenderer,_ project:Project)throws->[UInt8] {
            let context=try XCTUnwrap(RasterTools.bitmap(size));renderer.draw(project:project,directory:directory,time:0.5,context:context,size:size)
            return Array(UnsafeBufferPointer(start:try XCTUnwrap(context.data).assumingMemoryBound(to:UInt8.self),count:context.bytesPerRow*context.height))
        }
        XCTAssertEqual(try pixels(cached,project),try pixels(reference,project))
        project.clips[1].sceneMembers=[]
        XCTAssertEqual(try pixels(cached,project),try pixels(reference,project))
    }
    func testOptInMetadataTiming() throws {
        guard ProcessInfo.processInfo.environment["VMM_SCENE_METADATA_BENCHMARK"]=="1" else {throw XCTSkip("Opt-in performance measurement")}
        var project=Project();project.width=320;project.height=180
        project.clips=(0..<5000).map{Clip(kind:.shape,name:"clip\($0)",track:0,start:Double($0)*2,duration:1)}
        let size=CGSize(width:320,height:180),ctx=try XCTUnwrap(RasterTools.bitmap(size))
        func run(_ cached:Bool)throws->Double {
            let renderer=FrameRenderer();renderer.reuseSceneMetadata=cached
            renderer.draw(project:project,directory:FileManager.default.temporaryDirectory,time:0,context:ctx,size:size)
            let start=ProcessInfo.processInfo.systemUptime
            for _ in 0..<30 {autoreleasepool{renderer.draw(project:project,directory:FileManager.default.temporaryDirectory,time:0,context:ctx,size:size)}}
            return (ProcessInfo.processInfo.systemUptime-start)*1000/30
        }
        let a=try run(false),b=try run(true)
        print("SCENE_METADATA_BENCH uncached_ms=\(a) cached_ms=\(b)")
    }
}
