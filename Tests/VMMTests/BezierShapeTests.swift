import XCTest
import AppKit
@testable import VMM

final class BezierShapeTests:XCTestCase {
    func testMorphTrimAndInvalidTopology()throws {
        var path=AnimatedBezierShape();var end=path.keys[0];end.id=UUID();end.time=1;end.vertices[0].point.x=0.5;path.keys.append(end)
        XCTAssertEqual(path.vertices(at:0.5)[0].point.x,0.25,accuracy:0.00001)
        path.closed=false;path.keys=[BezierShapeKey(time:0,vertices:[BezierVertex(point:NormalizedPoint(x:0,y:0.5)),BezierVertex(point:NormalizedPoint(x:1,y:0.5))])];path.trimEnd=[AnimationKeyframe(time:0,value:0.5,easing:.linear)]
        XCTAssertEqual(path.path(in:CGRect(x:0,y:0,width:200,height:100),time:0,trim:true).boundingBoxOfPath.width,100,accuracy:0.01)
        try path.validated();path.keys[0].time = .nan;XCTAssertThrowsError(try path.validated())
        path=AnimatedBezierShape();end.vertices.removeLast();path.keys.append(end);XCTAssertThrowsError(try path.validated())
    }
    func testOptionalPathsAndChangingMaskPixels()throws {
        var p=Project();p.width=640;p.height=360
        var c=Clip(kind:.shape,name:"path",track:0,start:0,duration:1);var m=ClipMask();m.width=0.8;m.height=0.8;m.path=AnimatedBezierShape();var k=m.path!.keys[0];k.time=1;k.id=UUID();k.vertices=k.vertices.map{var v=$0;v.point.x*=0.1;return v};m.path!.keys.append(k);c.masks=[m];p.clips=[c]
        XCTAssertEqual(try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(p)).validated(),p)
        let renderer=FrameRenderer(),size=CGSize(width:640,height:360),dir=FileManager.default.temporaryDirectory;var frames=[Data]()
        for t in [0.0,0.9,0.0]{let ctx=try XCTUnwrap(RasterTools.bitmap(size));renderer.draw(project:p,directory:dir,time:t,context:ctx,size:size);frames.append(try XCTUnwrap(NSBitmapImageRep(cgImage:XCTUnwrap(ctx.makeImage())).representation(using:.png,properties:[:])))}
        XCTAssertNotEqual(frames[0],frames[1]);XCTAssertEqual(frames[0],frames[2])
        c.masks=nil;c.shapeStyle=ShapeStyle();c.shapeStyle?.path=nil;p.clips=[c];_=try p.validated()
        c.masks=[m];c.masks?[0].path?.closed=false;p.clips=[c];XCTAssertThrowsError(try p.validated())
    }
}
