import XCTest
import AVFoundation
import AppKit
@testable import VMM

final class Camera3DTests:XCTestCase {
    func testDepthOrderInPreviewAndMP4() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-depth-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        var p=Project();p.width=320;p.height=180
        var camera=Camera3D();camera.enabled=true;p.camera3D=camera
        var near=Clip(kind:.shape,name:"near",track:0,start:0,duration:0.5);near.color="FF0000";near.cameraDepth = -0.5
        var far=Clip(kind:.shape,name:"far",track:1,start:0,duration:0.5);far.color="0000FF";far.cameraDepth=1
        p.clips=[near,far]
        XCTAssertEqual(CameraDepthOrder.sorted([near,far]).map(\.id),[far.id,near.id])
        let context=try XCTUnwrap(RasterTools.bitmap(CGSize(width:320,height:180)))
        FrameRenderer().draw(project:p,directory:root,time:0.2,context:context,size:CGSize(width:320,height:180))
        let preview=NSBitmapImageRep(cgImage:try XCTUnwrap(context.makeImage()))
        let a=try XCTUnwrap(preview.colorAt(x:160,y:90)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(a.redComponent,0.7);XCTAssertLessThan(a.blueComponent,0.2)
        let output=root.appendingPathComponent("depth.mp4")
        try await MovieExporter.export(project:p,directory:root,destination:output){_ in}
        let generator=AVAssetImageGenerator(asset:AVURLAsset(url:output))
        let image=try generator.copyCGImage(at:CMTime(seconds:0.2,preferredTimescale:600),actualTime:nil)
        let movie=NSBitmapImageRep(cgImage:image),b=try XCTUnwrap(movie.colorAt(x:160,y:90)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(b.redComponent,0.7);XCTAssertLessThan(b.blueComponent,0.2)
        near.cameraDepth=1
        XCTAssertEqual(CameraDepthOrder.sorted([near,far]).map(\.id),[near.id,far.id])
    }
    func testSelectionGeometryFollowsCamera() throws {
        var camera=Camera3D();camera.yaw=18;camera.pitch=8;camera.x=0.2
        let geometry=PreviewObjectGeometry(rect:CGRect(x:30,y:40,width:80,height:50),transform:.identity,parent:.identity,own:.identity,camera:camera,cameraDepth:1,canvasSize:CGSize(width:320,height:180))
        for (local,screen) in zip(PreviewObjectGeometry.handles(geometry.rect),geometry.points) {
            let restored=try XCTUnwrap(geometry.unprojected(screen))
            XCTAssertEqual(restored.x,local.x,accuracy:0.00001);XCTAssertEqual(restored.y,local.y,accuracy:0.00001)
        }
    }
    func testProjectionRoundTrip() throws {
        var camera=Camera3D();camera.x=0.3;camera.y = -0.2;camera.z=0.1;camera.yaw=15;camera.pitch = -9;camera.roll=12
        let size=CGSize(width:1920,height:1080)
        for depth in [-0.5,0.0,2.0] {
            for point in [CGPoint(x:100,y:200),CGPoint(x:960,y:540),CGPoint(x:1600,y:800)] {
                let screen=try XCTUnwrap(camera.project(point,depth:depth,size:size))
                let restored=try XCTUnwrap(camera.unproject(screen,depth:depth,size:size))
                XCTAssertEqual(restored.x,point.x,accuracy:0.00001);XCTAssertEqual(restored.y,point.y,accuracy:0.00001)
            }
        }
    }
    func testCameraKeysInterpolateAndValidate() throws {
        var a=Camera3D(),b=Camera3D();b.x=2;b.focalLength=4
        a.keys=[.init(time:0,camera:a),.init(time:2,camera:b)]
        XCTAssertEqual(a.evaluated(at:1).x,1,accuracy:1e-9)
        XCTAssertEqual(a.evaluated(at:1).focalLength,3,accuracy:1e-9)
        try a.validate()
        a.keys?.append(.init(time:1,camera:b));XCTAssertThrowsError(try a.validate())
    }
    func testEditingInterpolatedCameraAddsKeyWithoutChangingOtherProperties() throws {
        var camera=Camera3D(),end=Camera3D();end.x=2;end.yaw=20
        camera.keys=[.init(time:0,camera:camera),.init(time:2,camera:end)]
        camera.setValue(\.yaw,value:30,at:1)
        XCTAssertEqual(camera.evaluated(at:1).x,1,accuracy:1e-9)
        XCTAssertEqual(camera.evaluated(at:1).yaw,30,accuracy:1e-9)
        XCTAssertEqual(camera.evaluated(at:2).yaw,20,accuracy:1e-9)
        XCTAssertEqual(camera.keys?.count,3)
        try camera.validate()
    }
    func testProjectionAndProjectCompatibility() throws {
        let camera=Camera3D(),size=CGSize(width:320,height:180)
        let p=try XCTUnwrap(camera.project(CGPoint(x:240,y:90),depth:0,size:size))
        XCTAssertEqual(p.x,240,accuracy:1e-8);XCTAssertEqual(p.y,90,accuracy:1e-8)
        let far=try XCTUnwrap(camera.project(CGPoint(x:240,y:90),depth:2,size:size))
        XCTAssertEqual(far.x,200,accuracy:1e-8)
        var project=Project();let data=try JSONEncoder().encode(project)
        XCTAssertNil(try JSONDecoder().decode(Project.self,from:data).camera3D)
        project.camera3D=camera;try project.validated()
        project.camera3D?.focalLength = .nan;XCTAssertThrowsError(try project.validated())
    }
    func testCameraPreviewAndMovie() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-camera-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        var p=Project();p.width=320;p.height=180;p.background="182030"
        var camera=Camera3D();camera.enabled=true;camera.x=0.2;camera.yaw=8;p.camera3D=camera
        var shape=Clip(kind:.shape,name:"test",track:0,start:0,duration:0.5);shape.color="FF0000";shape.cameraDepth=0.5;p.clips=[shape]
        let context=try XCTUnwrap(RasterTools.bitmap(CGSize(width:320,height:180)))
        FrameRenderer().draw(project:p,directory:root,time:0.2,context:context,size:CGSize(width:320,height:180))
        let output=root.appendingPathComponent("camera.mp4");try await MovieExporter.export(project:p,directory:root,destination:output){_ in}
        let generator=AVAssetImageGenerator(asset:AVURLAsset(url:output))
        let image=try generator.copyCGImage(at:CMTime(seconds:0.2,preferredTimescale:600),actualTime:nil)
        let movie=try XCTUnwrap(RasterTools.bitmap(CGSize(width:320,height:180)));movie.draw(image,in:CGRect(x:0,y:0,width:320,height:180))
        let n=context.bytesPerRow*context.height
        let a=try XCTUnwrap(context.data).assumingMemoryBound(to:UInt8.self),b=try XCTUnwrap(movie.data).assumingMemoryBound(to:UInt8.self)
        let mean=(0..<n).reduce(0.0){$0+Double(abs(Int(a[$1])-Int(b[$1])))}/Double(n)
        XCTAssertLessThan(mean,10)
    }
}
