import XCTest
import AppKit
@testable import VMM
final class TemporalMotionTests:XCTestCase {
    func testExposureBoundsAndLimits()throws {
        var a=TemporalMotion();let clip=Clip(kind:.shape,name:"test",track:0,start:1,duration:2)
        XCTAssertEqual(a.exposureTimes(at:1,clip:clip,fps:30,playing:false).count,6);XCTAssertTrue(a.exposureTimes(at:1,clip:clip,fps:30,playing:false).allSatisfy{$0>=1});XCTAssertEqual(a.exposureTimes(at:2,clip:clip,fps:30,playing:true).count,4)
        a.shutterAngle=0;XCTAssertEqual(a.exposureTimes(at:2,clip:clip,fps:30,playing:true),[2]);a.samples=17;XCTAssertThrowsError(try a.validated())
    }
    func testTemporalRenderingReproducibleOnSeek()throws {
        var p=Project();p.width=640;p.height=360
        var c=Clip(kind:.shape,name:"moving",track:0,start:0,duration:1);c.shapeStyle=ShapeStyle();c.shapeStyle?.width=0.05;c.shapeStyle?.height=0.1;c.putMotionKey(.x,time:0,value:0.1,easing:.linear);c.putMotionKey(.x,time:1,value:0.9);c.temporalMotion=TemporalMotion(shutterAngle:360,samples:8,trailCount:4,trailDuration:0.3);p.clips=[c];_=try p.validated()
        let renderer=FrameRenderer(),size=CGSize(width:640,height:360)
        func frame(_ p:Project,_ t:Double)throws->Data{let ctx=try XCTUnwrap(RasterTools.bitmap(size));renderer.draw(project:p,directory:FileManager.default.temporaryDirectory,time:t,context:ctx,size:size);return try XCTUnwrap(NSBitmapImageRep(cgImage:XCTUnwrap(ctx.makeImage())).representation(using:.png,properties:[:]))}
        let a=try frame(p,0.6);_=try frame(p,0.2);XCTAssertEqual(a,try frame(p,0.6));p.clips[0].temporalMotion=nil;XCTAssertNotEqual(a,try frame(p,0.6))
    }
    func testCompactTemporalMatchesFullFrameAndMeasurePlayback()throws {
        var p=Project();p.width=1920;p.height=1080;var c=Clip(kind:.shape,name:"blur",track:0,start:0,duration:2);c.shapeStyle=ShapeStyle();c.shapeStyle?.width=0.04;c.shapeStyle?.height=0.06;c.rotation=25;c.putMotionKey(.x,time:0,value:0.1,easing:.linear);c.putMotionKey(.x,time:2,value:0.9);c.temporalMotion=TemporalMotion(shutterAngle:360,samples:8,trailCount:4);p.clips=[c]
        let size=CGSize(width:p.width,height:p.height),fast=FrameRenderer(),reference=FrameRenderer();reference.boundedNodes=false
        func render(_ renderer:FrameRenderer,_ time:Double)throws->CGImage{let ctx=try XCTUnwrap(RasterTools.bitmap(size));renderer.draw(project:p,directory:FileManager.default.temporaryDirectory,time:time,context:ctx,size:size);return try XCTUnwrap(ctx.makeImage())}
        let a=NSBitmapImageRep(cgImage:try render(fast,0.8)),b=NSBitmapImageRep(cgImage:try render(reference,0.8));var error=0.0,count=0.0
        for y in stride(from:0,to:p.height,by:8){for x in stride(from:0,to:p.width,by:8){let ca=try XCTUnwrap(a.colorAt(x:x,y:y)),cb=try XCTUnwrap(b.colorAt(x:x,y:y));error+=abs(ca.redComponent-cb.redComponent)+abs(ca.greenComponent-cb.greenComponent)+abs(ca.blueComponent-cb.blueComponent);count+=3}}
        XCTAssertLessThan(error/count,0.001)
        fast.previewPlaying=true;let start=ProcessInfo.processInfo.systemUptime;for i in 0..<12{_=try render(fast,0.5+Double(i)/30)};print("Temporal 1080p preview, one small shape: \((ProcessInfo.processInfo.systemUptime-start)/12*1000) ms/frame")
    }

}
