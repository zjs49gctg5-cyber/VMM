import XCTest
import SwiftUI
import AppKit
import AVFoundation
@testable import VMM

final class UnifiedAnimationTests:XCTestCase {
    @MainActor func store()->EditorStore{let s=EditorStore(preferencesDirectory:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString));s.autoSpeech=false;s.settings.autosaveSeconds=0;s.project=Project();return s}
    func clip()->Clip{var c=Clip(kind:.shape,name:"unified",track:0,start:0,duration:2);c.temporalMotion=TemporalMotion();c.shapeStyle=ShapeStyle();c.shapeStyle?.path=AnimatedBezierShape();c.spatialAnimation=SpatialAnimation(keys:[SpatialKey(time:0,point:NormalizedPoint(x:0.2,y:0.5)),SpatialKey(time:2,point:NormalizedPoint(x:0.8,y:0.5))]);var effect=VisualEffect(kind:.glow);effect.keys=[AnimationKeyframe(time:0,value:0,easing:.linear),AnimationKeyframe(time:2,value:10)];c.effects=[effect];var mask=ClipMask();mask.path=AnimatedBezierShape();c.masks=[mask];return c}
    @MainActor func testUnifiedLanesInsertMoveDuplicateDeleteAndUndo()throws {
        let s=store();defer{try? FileManager.default.removeItem(at:s.directory)};s.project.clips=[clip()];let id=s.project.clips[0].id
        let lanes=s.project.clips[0].animationLanes;XCTAssertTrue(lanes.contains(.property(.shutterAngle)));XCTAssertTrue(lanes.contains(.spatial));XCTAssertTrue(lanes.contains(.shape(nil)));XCTAssertTrue(lanes.contains(.shape(s.project.clips[0].masks![0].id)));XCTAssertTrue(lanes.contains(.trim(nil,false)))
        for lane in lanes {
            let before=s.project;let inserted=try s.insertAnimationKey(id,lane:lane,at:1);try s.editAnimationKey(id,lane:lane,keyID:inserted.id,time:1.2)
            let copied=try s.duplicateAnimationKey(id,lane:lane,keyID:inserted.id);XCTAssertNotEqual(copied.id,inserted.id);XCTAssertEqual(copied.easing,lane.keys(s.project.clips[0]).first{$0.id==inserted.id}?.easing)
            try s.deleteAnimationKey(id,lane:lane,keyID:copied.id);s.undo();XCTAssertTrue(lane.keys(s.project.clips[0]).contains{$0.id==copied.id});s.redo();XCTAssertFalse(lane.keys(s.project.clips[0]).contains{$0.id==copied.id});_=try s.project.validated()
            s.project=before
        }
        var c=s.project.clips[0];c.putMotionKey(.shutterAngle,time:0,value:180);c.putMotionKey(.shutterAngle,time:2,value:0);c.animation!.tracks[0].enabled=false;s.project.clips=[c];_=try s.insertAnimationKey(id,lane:.property(.shutterAngle),at:0);XCTAssertTrue(s.project.clips[0].animation!.tracks[0].enabled)
        let original=s.project;XCTAssertThrowsError(try s.editAnimationKey(id,lane:.property(.shutterAngle),keyID:s.project.clips[0].animation!.tracks[0].keys[0].id,time:.nan));XCTAssertEqual(s.project,original)
        s.project.tracks[0].locked=true;XCTAssertThrowsError(try s.insertAnimationKey(id,lane:.trim(nil,true),at:0.5))
    }
    func testAnimatedTemporalEvaluationAndTrimDomain()throws {
        var c=Clip(kind:.shape,name:"temporal",track:0,start:3,duration:2);c.temporalMotion=TemporalMotion();c.putMotionKey(.shutterAngle,time:0,value:0,easing:.linear);c.putMotionKey(.shutterAngle,time:2,value:360);c.putMotionKey(.trailOpacity,time:0,value:0,easing:.linear);c.putMotionKey(.trailOpacity,time:2,value:1);c.putMotionKey(.trailCount,time:0,value:0,easing:.hold);c.putMotionKey(.trailCount,time:2,value:6)
        XCTAssertEqual(c.animated(at:4).temporalMotion?.shutterAngle,180);XCTAssertEqual(c.animated(at:4).temporalMotion?.trailOpacity,0.5);XCTAssertEqual(c.animated(at:4).temporalMotion?.trailCount,0)
        var trimmed=c;trimmed.start=4;trimmed.duration=0.5;trimmed.animationOffset=1;XCTAssertEqual(trimmed.animated(at:4.25).temporalMotion,c.animated(at:4.25).temporalMotion);XCTAssertEqual(trimmed.animationDomain,0...2)
        var p=Project();p.clips=[trimmed];XCTAssertEqual(try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(p)).validated(),p)
        c.temporalMotion=nil;p.clips=[c];XCTAssertThrowsError(try p.validated())
    }
    @MainActor func testNativeTimelineDragSelectionAndDoubleClickAcrossLanes()throws {
        let s=store();defer{try? FileManager.default.removeItem(at:s.directory)};s.project.clips=[clip()];let c=s.project.clips[0];let frame=CGRect(x:0,y:0,width:960,height:400),view=UnifiedAnimationTimelineView(frame:frame);view.store=s;view.clipID=c.id
        let window=NSWindow(contentRect:frame,styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.contentView=view;defer{window.close()}
        func event(_ type:NSEvent.EventType,_ point:CGPoint,count:Int=1)throws->NSEvent{try XCTUnwrap(NSEvent.mouseEvent(with:type,location:view.convert(point,to:nil),modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:count,pressure:1))}
        let lane=AnimationLane.trim(nil,false),index=try XCTUnwrap(c.animationLanes.firstIndex(of:lane)),point=CGPoint(x:view.x(0.8,c),y:view.headerHeight+Double(index)*view.rowHeight+view.rowHeight/2)
        view.mouseDown(with:try event(.leftMouseDown,point,count:2));let updated=s.project.clips[0],key=try XCTUnwrap(lane.keys(updated).first);XCTAssertEqual(key.time,0.8,accuracy:0.000001);XCTAssertEqual(view.selection?.lane,lane)
        let from=CGPoint(x:view.x(key.time,updated),y:point.y),to=CGPoint(x:view.x(1.2,updated),y:point.y);view.mouseDown(with:try event(.leftMouseDown,from));view.mouseDragged(with:try event(.leftMouseDragged,to));view.mouseUp(with:try event(.leftMouseUp,to));XCTAssertEqual(lane.keys(s.project.clips[0]).first?.time,1.2);XCTAssertEqual(view.selection?.keyID,key.id)
    }
    @MainActor func testPSDChannelAndSpatialInsertionPreserveContent()throws {
        let s=store();defer{try? FileManager.default.removeItem(at:s.directory)};let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
        s.project=try PSDAnimationTests().fixture(root);let c=s.project.clips[0],key=try s.insertAnimationKey(c.id,lane:.psd,at:1.5);XCTAssertEqual(s.project.clips[0].psd?.selectionKeys?.first{$0.id==key.id}?.selected,[1]);try s.editAnimationKey(c.id,lane:.psd,keyID:key.id,time:1.6);let copy=try s.duplicateAnimationKey(c.id,lane:.psd,keyID:key.id);XCTAssertEqual(s.project.clips[0].psd?.selectionKeys?.first{$0.id==copy.id}?.selected,[1]);try s.deleteAnimationKey(c.id,lane:.psd,keyID:copy.id);_=try s.project.validated()
        var path=SpatialAnimation(keys:[SpatialKey(time:0,point:NormalizedPoint(x:0.1,y:0.5),outgoing:NormalizedPoint(x:0.2,y:-0.3)),SpatialKey(time:2,point:NormalizedPoint(x:0.9,y:0.5),incoming:NormalizedPoint(x:-0.2,y:0.4))]);let original=path;path.insertPoint(at:0.8);try path.validated()
        for t in stride(from:0.0,through:2.0,by:0.05){XCTAssertEqual(path.sample(at:t).point.x,original.sample(at:t).point.x,accuracy:0.000001);XCTAssertEqual(path.sample(at:t).point.y,original.sample(at:t).point.y,accuracy:0.000001)}
    }
    @MainActor func testTimelineDomainCachedForDenseTrackingAndInvalidated()throws {
        let view=UnifiedAnimationTimelineView(frame:CGRect(x:0,y:0,width:1000,height:17000));var c=clip();c.spatialAnimation=SpatialAnimation(keys:(0..<500).map{SpatialKey(time:Double($0)/250,point:NormalizedPoint(x:Double($0)/500,y:0.5))})
        for lane in c.animationLanes{for key in lane.keys(c){_=view.x(key.time,c)}};XCTAssertEqual(view.domainComputations,1)
        c.spatialAnimation!.keys[499].time=3;XCTAssertEqual(view.domain(c).upperBound,3);XCTAssertEqual(view.domainComputations,2);view.allKeys=false;XCTAssertEqual(view.domain(c),0...2);XCTAssertEqual(view.domainComputations,3)
    }
    @MainActor func testZoomedTimelineDomainAndNearestKey()throws {
        let view=UnifiedAnimationTimelineView(frame:CGRect(x:0,y:0,width:800,height:100))
        var c=Clip(kind:.shape,name:"zoom",track:0,start:0,duration:100)
        c.putMotionKey(.x,time:40,value:0.2);c.putMotionKey(.x,time:41,value:0.3)
        view.allKeys=false;view.zoom=10;view.position=0.5
        XCTAssertEqual(view.domain(c).lowerBound,45,accuracy:0.0001)
        XCTAssertEqual(view.domain(c).upperBound,55,accuracy:0.0001)
        view.zoom=1;view.position=0
        let x=view.x(41,c),y=view.headerHeight+view.rowHeight/2
        XCTAssertEqual(view.key(at:CGPoint(x:x,y:y),c)?.time,41)
    }
    @MainActor func testTemporalKeysPreviewAndMP4AndPersistentLayout()async throws {
        let fm=FileManager.default,root=fm.temporaryDirectory.appendingPathComponent("unified-animation-"+UUID().uuidString);try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
        let keep=ProcessInfo.processInfo.environment["VMM_UNIFIED_QA_ROOT"].map{URL(fileURLWithPath:$0)}
        var p=Project();p.width=640;p.height=360;p.fps=30;var c=Clip(kind:.shape,name:"キーフレームで残像を調整",track:0,start:0,duration:2);c.shapeStyle=ShapeStyle();c.shapeStyle?.width=0.08;c.shapeStyle?.height=0.15;c.color="FF8844";c.temporalMotion=TemporalMotion(shutterAngle:0,trailCount:4);c.putMotionKey(.x,time:0,value:0.15,easing:.linear);c.putMotionKey(.x,time:2,value:0.85);c.putMotionKey(.shutterAngle,time:0,value:0,easing:.linear);c.putMotionKey(.shutterAngle,time:2,value:360);c.putMotionKey(.trailOpacity,time:0,value:0,easing:.linear);c.putMotionKey(.trailOpacity,time:2,value:0.8);c.putMotionKey(.trailDuration,time:0,value:0.05,easing:.linear);c.putMotionKey(.trailDuration,time:2,value:0.5);p.clips=[c];_=try p.validated()
        let movie=root.appendingPathComponent("keyframed-trails.mp4");try await MovieExporter.export(project:p,directory:root,destination:movie){_ in};let generator=AVAssetImageGenerator(asset:AVURLAsset(url:movie));generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero;let renderer=FrameRenderer();let size=CGSize(width:640,height:360)
        for time in [0.0,0.5,1.0,1.8]{let ctx=try XCTUnwrap(RasterTools.bitmap(size));renderer.draw(project:p,directory:root,time:time,context:ctx,size:size);let preview=NSBitmapImageRep(cgImage:try XCTUnwrap(ctx.makeImage())),output=NSBitmapImageRep(cgImage:try generator.copyCGImage(at:CMTime(seconds:time,preferredTimescale:600),actualTime:nil));var error=0.0,count=0.0
            for y in stride(from:0,to:360,by:4){for x in stride(from:0,to:640,by:4){let a=try XCTUnwrap(preview.colorAt(x:x,y:y)),b=try XCTUnwrap(output.colorAt(x:x,y:y));error+=abs(a.redComponent-b.redComponent)+abs(a.greenComponent-b.greenComponent)+abs(a.blueComponent-b.blueComponent);count+=3}};XCTAssertLessThan(error/count,0.02)
            if let keep{try fm.createDirectory(at:keep,withIntermediateDirectories:true);try XCTUnwrap(preview.representation(using:.png,properties:[:])).write(to:keep.appendingPathComponent("preview-\(time).png"))}
        }
        if let keep{try fm.copyItem(at:movie,to:keep.appendingPathComponent("keyframed-trails.mp4"));let s=store();s.project=p;s.directory=root;s.selectedID=c.id;s.seek(1);var rich=clip();rich.id=c.id;rich.kind = .text;rich.text="共通キーフレーム";rich.temporalMotion=c.temporalMotion;rich.animation=c.animation;rich.textAnimation=CharacterAnimation();s.project.clips=[rich]
            for (name,tab,size) in [("blur-large","ブラー・残像",CGSize(width:1320,height:880)),("shape-small","図形・マスク",CGSize(width:840,height:620)),("text-small","文字",CGSize(width:900,height:650)),("keys-large","キーフレーム",CGSize(width:1320,height:880)),("effects","エフェクト",CGSize(width:1100,height:800))] {
                let host=NSHostingView(rootView:AnimationWorkspace(store:s,onClose:{},initialTab:tab));host.frame=CGRect(origin:.zero,size:size);let window=NSWindow(contentRect:host.frame,styleMask:[.titled,.resizable],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.contentView=host;window.orderBack(nil);host.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:200_000_000);host.layoutSubtreeIfNeeded();let rep=try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds));host.cacheDisplay(in:host.bounds,to:rep);try XCTUnwrap(rep.representation(using:.png,properties:[:])).write(to:keep.appendingPathComponent(name+".png"));XCTAssertEqual(timelines(host).count,2);XCTAssertTrue(timelines(host).contains{$0.rulerOnly});XCTAssertTrue(timelines(host).contains{!$0.rulerOnly && !$0.showRuler});window.close()
            }
        }
    }
    @MainActor private func timelines(_ view:NSView)->[UnifiedAnimationTimelineView]{(view as? UnifiedAnimationTimelineView).map{[$0]} ?? view.subviews.flatMap{timelines($0)}}
}
