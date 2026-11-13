import XCTest
import AppKit
import SwiftUI
import AVFoundation
@testable import VMM
final class MotionGraphTests:XCTestCase {
    func testDerivativeUsesEasingAndPercentUnits(){
        let c=Clip(kind:.shape,name:"test",track:0,start:0,duration:2)
        let linear=AnimationTrack(property:.x,keys:[AnimationKeyframe(time:0,value:0.1,easing:.linear),AnimationKeyframe(time:2,value:0.9)])
        XCTAssertEqual(MotionGraph.value(linear,clip:c,time:1,speed:true),40,accuracy:0.001)
        let eased=AnimationTrack(property:.x,keys:[AnimationKeyframe(time:0,value:0,easing:.easeIn),AnimationKeyframe(time:2,value:1)])
        XCTAssertGreaterThan(MotionGraph.value(eased,clip:c,time:1.8,speed:true),MotionGraph.value(eased,clip:c,time:0.2,speed:true)*10)
    }
    @MainActor func testGraphDragKeepsIDsEasingBoundsAndUndo()throws {
        let s=EditorStore(preferencesDirectory:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString));defer{try? FileManager.default.removeItem(at:s.directory)};s.autoSpeech=false;s.settings.autosaveSeconds=0
        var c=Clip(kind:.shape,name:"test",track:0,start:0,duration:2);c.putMotionKey(.x,time:0,value:0.2);c.putMotionKey(.x,time:1,value:0.5,easing:.bounceOut);c.putMotionKey(.x,time:2,value:0.8);s.project.clips=[c]
        let k=c.animation!.tracks[0].keys[1]
        try s.editGraphKey(c.id,property:.x,keyID:k.id,time:1.2,value:0.7)
        let edited=s.project.clips[0].animation!.tracks[0].keys[1];XCTAssertEqual(edited.id,k.id);XCTAssertEqual(edited.easing,.bounceOut);XCTAssertEqual(edited.time,1.2,accuracy:0.00001)
        s.undo();XCTAssertEqual(s.project.clips[0],c)
        s.project.tracks[0].locked=true;XCTAssertThrowsError(try s.editGraphKey(c.id,property:.x,keyID:k.id,time:1.2,value:0.7))
    }
    @MainActor func testNativeDragEndpointsOverlapSpeedAndUndo()throws {
        let s=EditorStore(preferencesDirectory:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString));defer{try? FileManager.default.removeItem(at:s.directory)};s.autoSpeech=false;s.settings.autosaveSeconds=0
        var c=Clip(kind:.shape,name:"drag",track:0,start:0,duration:2)
        for p in [AnimatedProperty.x,.y]{c.putMotionKey(p,time:0,value:0.2,easing:.linear);c.putMotionKey(p,time:1,value:0.5,easing:.bounceOut);c.putMotionKey(p,time:2,value:0.8)}
        s.project.clips=[c]
        let view=MotionGraphPlotView(frame:CGRect(x:0,y:0,width:640,height:240));view.store=s;view.domain=0...2;view.low=0;view.high=100;view.activeProperty = .x
        let window=NSWindow(contentRect:view.frame,styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.contentView=view;defer{window.close()}
        func event(_ type:NSEvent.EventType,_ p:CGPoint)throws->NSEvent{try XCTUnwrap(NSEvent.mouseEvent(with:type,location:view.convert(p,to:nil),modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1))}
        for (index,dx) in [(0,60.0),(1,60.0),(2,-60.0)] {
            view.clip=c;view.tracks=c.animation!.tracks;let track=c.animation!.tracks[0],key=track.keys[index],point=view.point(key,track:track),target=CGPoint(x:point.x+dx,y:point.y-24)
            XCTAssertEqual(view.hit(point)?.0.property,.x)
            view.mouseDown(with:try event(.leftMouseDown,point));view.mouseDragged(with:try event(.leftMouseDragged,target));XCTAssertEqual(s.project.clips[0],c)
            view.mouseUp(with:try event(.leftMouseUp,target));let edited=try XCTUnwrap(s.project.clips[0].animation!.tracks[0].keys.first{$0.id==key.id})
            XCTAssertNotEqual(edited.time,key.time);XCTAssertEqual(edited.value,key.value+0.1,accuracy:0.00001);XCTAssertEqual(edited.easing,key.easing);XCTAssertEqual(s.project.clips[0].animation!.tracks[1],c.animation!.tracks[1]);_=try s.project.validated()
            s.undo();XCTAssertEqual(s.project.clips[0],c)
        }
        view.speed=true;view.clip=c;view.tracks=c.animation!.tracks;view.low = -100;view.high=200
        let key=c.animation!.tracks[0].keys[1],point=view.point(key,track:c.animation!.tracks[0]),target=CGPoint(x:point.x+60,y:point.y-50)
        view.mouseDown(with:try event(.leftMouseDown,point));view.mouseDragged(with:try event(.leftMouseDragged,target));view.mouseUp(with:try event(.leftMouseUp,target))
        let edited=s.project.clips[0].animation!.tracks[0].keys[1];XCTAssertNotEqual(edited.time,key.time);XCTAssertEqual(edited.value,key.value)
        s.undo();view.speed=false;view.low=0;view.high=100
        let original=view.point(key,track:c.animation!.tracks[0]);view.mouseDown(with:try event(.leftMouseDown,original));view.mouseDragged(with:try event(.leftMouseDragged,CGPoint(x:original.x+60,y:original.y)));s.project.clips[0].name="concurrent change";view.mouseUp(with:try event(.leftMouseUp,original));XCTAssertEqual(s.project.clips[0].name,"concurrent change");XCTAssertEqual(s.project.clips[0].animation,c.animation);XCTAssertNotNil(s.error)
    }
    @MainActor func testTightlySpacedKeysAllowValueEditingWithoutCrossing()throws {
        let s=EditorStore(preferencesDirectory:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString));defer{try? FileManager.default.removeItem(at:s.directory)};s.autoSpeech=false;s.settings.autosaveSeconds=0
        var c=Clip(kind:.shape,name:"subframe",track:0,start:0,duration:2);for t in [0.0,0.01,0.02]{c.putMotionKey(.x,time:t,value:0.5)};s.project.clips=[c]
        let key=c.animation!.tracks[0].keys[1];try s.editGraphKey(c.id,property:.x,keyID:key.id,time:1,value:0.7)
        XCTAssertEqual(s.project.clips[0].animation!.tracks[0].keys[1].time,key.time);XCTAssertEqual(s.project.clips[0].animation!.tracks[0].keys[1].value,0.7)
    }

    @MainActor func testRetimedGraphPreviewAndMP4()async throws {
        let fm=FileManager.default,root=fm.temporaryDirectory.appendingPathComponent("graph-drag-"+UUID().uuidString);try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
        let keep=ProcessInfo.processInfo.environment["VMM_GRAPH_DRAG_QA_ROOT"].map{URL(fileURLWithPath:$0)}
        let s=EditorStore(preferencesDirectory:root);s.autoSpeech=false;s.settings.autosaveSeconds=0;s.project.width=640;s.project.height=360;s.project.fps=30
        var c=Clip(kind:.shape,name:"graph retiming",track:0,start:0,duration:2);c.shapeStyle=ShapeStyle();c.shapeStyle?.width=0.1;c.shapeStyle?.height=0.2;c.color="FF8844";c.putMotionKey(.x,time:0,value:0.2,easing:.linear);c.putMotionKey(.x,time:1,value:0.5,easing:.linear);c.putMotionKey(.x,time:2,value:0.8);s.project.clips=[c]
        for (i,time,value) in [(0,0.2,0.1),(1,0.8,0.6),(2,1.8,0.9)]{try s.editGraphKey(c.id,property:.x,keyID:c.animation!.tracks[0].keys[i].id,time:time,value:value)}
        let p=try s.project.validated(),movie=root.appendingPathComponent("retimed-graph.mp4");try await MovieExporter.export(project:p,directory:root,destination:movie){_ in}
        let generator=AVAssetImageGenerator(asset:AVURLAsset(url:movie));generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero;let renderer=FrameRenderer(),size=CGSize(width:640,height:360)
        if let keep{try fm.createDirectory(at:keep,withIntermediateDirectories:true);try fm.copyItem(at:movie,to:keep.appendingPathComponent(movie.lastPathComponent))}
        for time in [0.0,0.5,1.0,1.9]{let ctx=try XCTUnwrap(RasterTools.bitmap(size));renderer.draw(project:p,directory:root,time:time,context:ctx,size:size);let preview=NSBitmapImageRep(cgImage:try XCTUnwrap(ctx.makeImage())),output=NSBitmapImageRep(cgImage:try generator.copyCGImage(at:CMTime(seconds:time,preferredTimescale:600),actualTime:nil));var error=0.0,count=0.0
            for y in stride(from:0,to:360,by:4){for x in stride(from:0,to:640,by:4){let a=try XCTUnwrap(preview.colorAt(x:x,y:y)),b=try XCTUnwrap(output.colorAt(x:x,y:y));error+=abs(a.redComponent-b.redComponent)+abs(a.greenComponent-b.greenComponent)+abs(a.blueComponent-b.blueComponent);count+=3}};XCTAssertLessThan(error/count,0.02)
            if let keep{try XCTUnwrap(preview.representation(using:.png,properties:[:])).write(to:keep.appendingPathComponent("preview-\(time).png"))}
        }
        if let keep{for width in [760.0,1100.0]{let host=NSHostingView(rootView:MotionGraphEditor(store:s,clip:p.clips[0]));host.frame=CGRect(x:0,y:0,width:width,height:400);let window=NSWindow(contentRect:host.frame,styleMask:[.titled,.resizable],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.contentView=host;window.orderBack(nil);host.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:200_000_000);let rep=try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds));host.cacheDisplay(in:host.bounds,to:rep);try XCTUnwrap(rep.representation(using:.png,properties:[:])).write(to:keep.appendingPathComponent("graph-\(Int(width)).png"));window.close()}}
    }

}
