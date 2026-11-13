import XCTest
import AppKit
import AVFoundation
@testable import VMM

final class AdvancedMotionTests:XCTestCase {
    func testSpatialCurveTimingOrientationAndOldProject()throws {
        var path=SpatialAnimation(keys:[SpatialKey(time:0,point:NormalizedPoint(x:0.2,y:0.6),outgoing:NormalizedPoint(x:0.2,y:-0.4)),SpatialKey(time:2,point:NormalizedPoint(x:0.8,y:0.6),incoming:NormalizedPoint(x:-0.2,y:-0.4))],orientToPath:true,orientationAspect:16/9)
        try path.validated();XCTAssertEqual(path.sample(at:1).point.x,0.5,accuracy:0.00001);XCTAssertEqual(path.sample(at:1).point.y,0.3,accuracy:0.00001)
        XCTAssertEqual(path.sample(at:0).angle,atan2(-0.4,0.2*16/9)*180 / .pi,accuracy:0.0001)
        var c=Clip(kind:.shape,name:"curve",track:0,start:2,duration:2);c.spatialAnimation=path;c.anchorPoint=NormalizedPoint(x:0.6,y:0.5)
        var p=Project();p.clips=[c];XCTAssertEqual(try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(p)).validated(),p)
        var old=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(p)) as? [String:Any]);var clips=try XCTUnwrap(old["clips"] as? [[String:Any]]);clips[0].removeValue(forKey:"spatialAnimation");clips[0].removeValue(forKey:"anchorPoint");clips[0].removeValue(forKey:"textAnimation");old["clips"]=clips
        let decoded=try JSONDecoder().decode(Project.self,from:JSONSerialization.data(withJSONObject:old));XCTAssertNil(decoded.clips[0].spatialAnimation);XCTAssertNil(decoded.clips[0].anchorPoint)
        path.keys[1].time=0;XCTAssertThrowsError(try path.validated())
        c.animation=ClipAnimation(entrance:Entrance(kind:.slideLeft,duration:0.5,easing:.linear));XCTAssertLessThan(c.animated(at:2.1).x,c.spatialAnimation!.sample(at:0.1).point.x)
    }
    @MainActor func testAnchorMatrixMatchesRasterAndParentGeometry()throws {
        var p=Project();p.width=640;p.height=360
        var c=Clip(kind:.shape,name:"pivot",track:0,start:0,duration:1);c.x=0.4;c.y=0.4;c.rotation=90;c.scale=0.5;c.anchorPoint=NormalizedPoint(x:0.6,y:0.4)
        let anchor=CGPoint(x:64,y:-36),matrix=c.objectMatrix(project:p,canvasInput:false),pivot=anchor.applying(matrix)
        XCTAssertEqual(pivot.x,320,accuracy:0.000001);XCTAssertEqual(pivot.y,108,accuracy:0.000001)
        let render=CGPoint(x:320+anchor.x,y:180+anchor.y).applying(NodeRasterGeometry.affine(c,project:p));XCTAssertEqual(render.x,pivot.x,accuracy:0.000001);XCTAssertEqual(render.y,pivot.y,accuracy:0.000001)
        let preview=anchor.applying(PreviewGeometry.matrix(c,project:p,canvasInput:false));XCTAssertEqual(preview.x,pivot.x);XCTAssertEqual(preview.y,pivot.y)
    }
    @MainActor func testPathPreviewMoveAutoKeySplitTrimAndUndo()throws {
        let s=EditorStore(preferencesDirectory:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString));defer{try? FileManager.default.removeItem(at:s.directory)};s.autoSpeech=false;s.settings.autosaveSeconds=0
        var c=Clip(kind:.shape,name:"curve",track:0,start:0,duration:2);c.spatialAnimation=SpatialAnimation(keys:[SpatialKey(time:0,point:NormalizedPoint(x:0.2,y:0.5)),SpatialKey(time:2,point:NormalizedPoint(x:0.8,y:0.5))]);s.project.clips=[c];s.selectedID=c.id
        var moved=c;moved.previewOffset(.x,by:0.1);let keyed=c.recordingPreviewChange(moved,at:1);XCTAssertEqual(keyed.animated(at:1).x,0.6,accuracy:0.00001);XCTAssertEqual(keyed.animated(at:0).x,c.animated(at:0).x)
        let trimmed=s.timelineChange(c,delta:0.5,track:0,edge:-1);XCTAssertEqual(trimmed.animationOffset,0.5);XCTAssertEqual(trimmed.animated(at:0.9).x,c.animated(at:0.9).x)
        s.seek(1);s.splitSelected();XCTAssertEqual(s.project.clips.count,2);let right=s.project.clips.first{$0.start==1}!;XCTAssertEqual(right.animated(at:1.5).x,c.animated(at:1.5).x);s.undo();XCTAssertEqual(s.project.clips,[c])
    }
    @MainActor func testNativeAnchorDragPreservesAppearanceAndUndo()throws {
        let s=EditorStore(preferencesDirectory:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString));defer{try? FileManager.default.removeItem(at:s.directory)};s.autoSpeech=false;s.settings.autosaveSeconds=0;s.project.width=640;s.project.height=360
        var c=Clip(kind:.shape,name:"支点",track:0,start:0,duration:1);c.rotation=35;c.scale=0.6;s.project.clips=[c];s.selectedID=c.id
        let view=ObjectEditingView(frame:CGRect(x:0,y:0,width:640,height:360));view.store=s;view.targetID=c.id;view.editAnchor=true
        let window=NSWindow(contentRect:view.frame,styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.contentView=view;defer{window.close()}
        let geometry=try XCTUnwrap(view.geometry(c)),pivot=geometry.pivot
        XCTAssertEqual(view.cursorKind(at:pivot),.crosshair)
        func event(_ type:NSEvent.EventType,_ point:CGPoint)throws->NSEvent {try XCTUnwrap(NSEvent.mouseEvent(with:type,location:view.convert(point,to:nil),modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1))}
        view.mouseDown(with:try event(.leftMouseDown,pivot));view.mouseDragged(with:try event(.leftMouseDragged,CGPoint(x:pivot.x+40,y:pivot.y+20)));view.mouseUp(with:try event(.leftMouseUp,CGPoint(x:pivot.x+40,y:pivot.y+20)))
        let changed=s.project.clips[0];XCTAssertNotNil(changed.anchorPoint)
        for point in [CGPoint.zero,CGPoint(x:100,y:60)]{let a=point.applying(c.objectMatrix(project:s.project,canvasInput:false)),b=point.applying(changed.objectMatrix(project:s.project,canvasInput:false));XCTAssertEqual(a.x,b.x,accuracy:0.00001);XCTAssertEqual(a.y,b.y,accuracy:0.00001)}
        s.undo();XCTAssertEqual(s.project.clips,[c])
    }
    func testCharacterRangeReverseAndUnicodeTiming()throws {
        var a=CharacterAnimation(kind:.rise,delay:0.1,duration:0.5,distance:50);try a.validated()
        XCTAssertEqual(a.pose(index:1,count:3,time:0.05).opacity,0);XCTAssertEqual(a.pose(index:0,count:3,time:2),CharacterPose())
        a.reverse=true;XCTAssertEqual(a.pose(index:0,count:3,time:0.15).opacity,0);XCTAssertGreaterThan(a.pose(index:2,count:3,time:0.15).opacity,0)
        a.kind = .blur;XCTAssertGreaterThan(a.pose(index:2,count:3,time:0.15).blur,0);XCTAssertEqual(a.pose(index:2,count:3,time:2).blur,0)
        a.first=1;a.last=1;XCTAssertEqual(a.pose(index:0,count:3,time:0),CharacterPose());a.duration=0;XCTAssertThrowsError(try a.validated())
    }
    func testPreviewAndActualMP4ForPathsAnchorsAndCharacters()async throws {
        let fm=FileManager.default,root=fm.temporaryDirectory.appendingPathComponent("advanced-motion-"+UUID().uuidString);try fm.createDirectory(at:root,withIntermediateDirectories:true)
        let keep=ProcessInfo.processInfo.environment["VMM_MOTION_QA_ROOT"].map{URL(fileURLWithPath:$0)};defer{try? fm.removeItem(at:root)}
        var p=Project();p.name="高度なアニメーション検証";p.width=640;p.height=360;p.fps=30;p.background="121620"
        var c=Clip(kind:.shape,name:"曲線と支点",track:0,start:0,duration:2);c.shapeStyle=ShapeStyle();c.shapeStyle?.width=0.10;c.shapeStyle?.height=0.12;c.color="FF8833";c.anchorPoint=NormalizedPoint(x:0.53,y:0.5);c.spatialAnimation=SpatialAnimation(keys:[SpatialKey(time:0,point:NormalizedPoint(x:0.15,y:0.3),outgoing:NormalizedPoint(x:0.2,y:-0.1)),SpatialKey(time:2,point:NormalizedPoint(x:0.85,y:0.3),incoming:NormalizedPoint(x:-0.2,y:0.2))],orientToPath:true,orientationAspect:640/360)
        c.putMotionKey(.scale,time:0,value:0.8,easing:.backOut);c.putMotionKey(.scale,time:2,value:1.4)
        var text=Clip(kind:.text,name:"文字アニメーション",track:1,start:0,duration:2);text.text="VMM 文字が跳ねる\nか\u{3099}・👩‍👩‍👧‍👦";text.fontSize=32;text.y=0.65;text.textAnimation=CharacterAnimation(kind:.bounce,delay:0.04,duration:0.6,distance:30);text.textStyle=TextStyle();text.textStyle?.shadow=true;text.textStyle?.fillGradient=TextGradient(enabled:true,endColor:"55AAFF",angle:0)
        var blurred=text;blurred.id=UUID();blurred.text="ぼかしから登場";blurred.y=0.85;blurred.fontSize=24;blurred.textAnimation=CharacterAnimation(kind:.blur,delay:0.03,duration:0.6)
        p.clips=[c,text,blurred];_=try p.validated()
        let movie=root.appendingPathComponent("motion.mp4");try await MovieExporter.export(project:p,directory:root,destination:movie){_ in}
        let generator=AVAssetImageGenerator(asset:AVURLAsset(url:movie));generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
        let renderer=FrameRenderer();var first:Data?
        for time in [0.0,0.3,0.9,1.8]{
            let ctx=try XCTUnwrap(RasterTools.bitmap(CGSize(width:640,height:360)));renderer.draw(project:p,directory:root,time:time,context:ctx,size:CGSize(width:640,height:360));let image=try XCTUnwrap(ctx.makeImage()),preview=NSBitmapImageRep(cgImage:image),frame=NSBitmapImageRep(cgImage:try generator.copyCGImage(at:CMTime(seconds:time,preferredTimescale:600),actualTime:nil))
            var error=0.0
            for y in stride(from:0,to:360,by:3){for x in stride(from:0,to:640,by:3){let a=try XCTUnwrap(preview.colorAt(x:x,y:y)?.usingColorSpace(.sRGB)),b=try XCTUnwrap(frame.colorAt(x:x,y:y)?.usingColorSpace(.sRGB));error+=abs(a.redComponent-b.redComponent)+abs(a.greenComponent-b.greenComponent)+abs(a.blueComponent-b.blueComponent)}}
            XCTAssertLessThan(error/(214*120*3),0.04)
            let data=try XCTUnwrap(preview.representation(using:.png,properties:[:]));if time==0{first=data}else{XCTAssertNotEqual(data,first)}
            if let keep{try fm.createDirectory(at:keep,withIntermediateDirectories:true);try data.write(to:keep.appendingPathComponent("preview-\(time).png"));try XCTUnwrap(frame.representation(using:.png,properties:[:])).write(to:keep.appendingPathComponent("output-\(time).png"))}
        }
        if let keep{try fm.copyItem(at:movie,to:keep.appendingPathComponent("motion.mp4"));let package=keep.appendingPathComponent("Animation-QA.vmm");try fm.createDirectory(at:package.appendingPathComponent("Media"),withIntermediateDirectories:true);try JSONEncoder().encode(p).write(to:package.appendingPathComponent("project.json"));print("Animation QA: \(keep.path)")}
    }
}
