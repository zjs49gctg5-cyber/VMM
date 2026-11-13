import XCTest
import AppKit
import AVFoundation
import SwiftUI
@testable import VMM

final class MotionTrackingTests:XCTestCase {
    @MainActor func testTrackingProjectionParentAndEditablePaths()throws {
        var p=Project();p.width=640;p.height=360
        var parent=Clip(kind:.group,name:"parent",track:0,start:0,duration:2);parent.rotation=90
        var source=Clip(kind:.video,name:"video",track:0,start:0,duration:2);source.parentID=parent.id;source.scale=0.5
        var target=Clip(kind:.shape,name:"target",track:1,start:0,duration:2);target.animation=ClipAnimation(entrance:Entrance(kind:.slideLeft,duration:1,easing:.linear));p.clips=[parent,source,target]
        let result=MotionTrackingResult(samples:[TrackingSample(time:0,x:0.2,y:0.4,width:0.2,height:0.2,confidence:1),TrackingSample(time:1,x:0.6,y:0.4,width:0.2,height:0.2,confidence:1)],frameWidth:640,frameHeight:360)
        let tracked=try MotionTracker.applying(result,to:target,source:source,project:p,followScale:false)
        XCTAssertEqual(tracked.spatialAnimation?.keys[0].point.x,0.5);XCTAssertEqual(tracked.animated(at:0).x,target.animated(at:0).x)
        XCTAssertEqual(tracked.animated(at:1).y,0.5+128/360.0,accuracy:0.00001)
        XCTAssertEqual(tracked.spatialAnimation?.keys[1].point.x,0.5);XCTAssertEqual(tracked.tracking,result)
        var mosaic=Clip(kind:.adjustment,name:"mosaic",track:1,start:0,duration:2);mosaic.adjustmentRegion=AdjustmentRegion();var resize=result;resize.samples[1].width=0.3;resize.samples[1].height=0.3
        let followed=try MotionTracker.applying(resize,to:mosaic,source:source,project:p,followScale:true);p.clips.append(followed);_=try p.validated();XCTAssertNotNil(followed.animation?.tracks.first{$0.property == .regionWidth});XCTAssertNotNil(followed.spatialAnimation)
        var invalid=result;invalid.samples[0].confidence = .nan;XCTAssertThrowsError(try invalid.validated())
        XCTAssertThrowsError(try MotionTracker.analyze(url:URL(fileURLWithPath:"/absent.mp4"),source:source,region:CGRect(x:0.9,y:0.4,width:0.5,height:0.3),from:0,duration:1,sampleRate:15))
    }
    @MainActor func testNativeTrackingAndAllFourFeaturesInActualMP4()async throws {
        let fm=FileManager.default,root=fm.temporaryDirectory.appendingPathComponent("motion58-"+UUID().uuidString);try fm.createDirectory(at:root.appendingPathComponent("Media"),withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
        let keep=ProcessInfo.processInfo.environment["VMM_ADVANCED58_QA_ROOT"].map{URL(fileURLWithPath:$0)}
        var p=Project();p.width=640;p.height=360;p.fps=30;p.background="172330";p.name="高度なモーション 5〜8"
        var object=Clip(kind:.shape,name:"tracking subject",track:0,start:0,duration:2);object.shapeStyle=ShapeStyle();object.shapeStyle?.width=0.2;object.shapeStyle?.height=0.3;object.shapeStyle?.cornerRadius=0;object.color="DD7744";object.putMotionKey(.x,time:0,value:0.25,easing:.linear);object.putMotionKey(.x,time:2,value:0.7)
        var label=Clip(kind:.text,name:"texture",track:1,start:0,duration:2);label.text="VMM\n▥ ▦";label.fontSize=22;label.x=0.25;label.putMotionKey(.x,time:0,value:0.25,easing:.linear);label.putMotionKey(.x,time:2,value:0.7);p.clips=[object,label]
        let original=root.appendingPathComponent("Media/source.mp4");try await MovieExporter.export(project:p,directory:root,destination:original){_ in}
        var source=Clip(kind:.video,name:"追跡元",track:0,start:0,duration:2);let asset=MediaAsset(name:"source.mp4",file:"source.mp4",kind:.video,duration:2);source.assetID=asset.id
        let result=try await Task.detached(priority:.userInitiated){try MotionTracker.analyze(url:original,source:source,region:CGRect(x:0.15,y:0.35,width:0.2,height:0.3),from:0,duration:1.8,sampleRate:15)}.value
        XCTAssertGreaterThan(result.samples.count,20);let last=try XCTUnwrap(result.samples.last);XCTAssertEqual(last.rect.midX,0.25+0.45*last.time/2,accuracy:0.05)
        if let keep{try fm.createDirectory(at:keep.appendingPathComponent("Media"),withIntermediateDirectories:true);try fm.copyItem(at:original,to:keep.appendingPathComponent("Media/source.mp4"));try JSONEncoder().encode(result).write(to:keep.appendingPathComponent("tracking.json"))}
        p.clips=[source];p.assets=[asset]
        var attached=Clip(kind:.text,name:"追跡する字幕",track:1,start:0,duration:2);attached.text="TRACKED";attached.fontSize=20;attached.x=0.25;attached.y=0.3
        let jobStore=EditorStore(preferencesDirectory:root.appendingPathComponent("tracking-preferences"));jobStore.autoSpeech=false;jobStore.settings.autosaveSeconds=0;jobStore.directory=root;jobStore.project=p;jobStore.project.clips.append(attached);let commands=EditorCommands();commands.store=jobStore
        let arguments:[String:Any]=["command":"animation.track","clipID":attached.id.uuidString,"sourceClipID":source.id.uuidString,"region":["x":0.15,"y":0.35,"width":0.2,"height":0.3],"sourceIn":0.0,"duration":1.8,"sampleRate":15.0]
        let response=commands.execute(body:try JSONSerialization.data(withJSONObject:arguments));XCTAssertEqual(response.status,202);let job=try XCTUnwrap((JSONSerialization.jsonObject(with:response.body) as? [String:Any])?["jobID"] as? String)
        for _ in 0..<500{if commands.jobs[job]?["state"] as? String != "running"{break};try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertEqual(commands.jobs[job]?["state"] as? String,"completed",commands.jobs[job]?["error"] as? String ?? "");attached=jobStore.project.clips[1];XCTAssertNotNil(attached.spatialAnimation);jobStore.undo();XCTAssertNil(jobStore.project.clips[1].spatialAnimation);jobStore.redo();XCTAssertNotNil(jobStore.project.clips[1].spatialAnimation)
        attached.temporalMotion=TemporalMotion(shutterAngle:270,samples:6,trailCount:3,trailDuration:0.2);p.clips.append(attached)
        var path=Clip(kind:.shape,name:"描画とモーフ",track:2,start:0,duration:2);path.y=0.82;path.shapeStyle=ShapeStyle();path.shapeStyle?.width=0.32;path.shapeStyle?.height=0.2;path.shapeStyle?.fill=false;path.shapeStyle?.outline=true;path.shapeStyle?.outlineColor="66EECC";path.shapeStyle?.outlineWidth=5;var bezier=AnimatedBezierShape();var end=bezier.keys[0];end.time=2;end.id=UUID();end.vertices[0].point.y=0.5;end.vertices[1].point.y=0.5;end.vertices[2].point.x=0.5;end.vertices[3].point.x=0.5;bezier.keys.append(end);bezier.trimEnd=[AnimationKeyframe(time:0,value:0,easing:.linear),AnimationKeyframe(time:1.5,value:1,easing:.linear)];path.shapeStyle?.path=bezier
        let data=ReactiveAudioData(amplitude:(0..<60).map{abs(sin(Double($0)/5))},bass:Array(repeating:0,count:60),onset:Array(repeating:0,count:60));path.audioReactive=AudioReactive(data:data,sourceDuration:2,scaleAmount:0.15,glowAmount:5);p.clips.append(path)
        var masked=Clip(kind:.shape,name:"パスマスク",track:3,start:0,duration:2);masked.color="5588EE";masked.x=0.85;masked.y=0.2;masked.scale=0.2;var mask=ClipMask();mask.width=0.9;mask.height=0.9;mask.path=bezier;mask.path?.trimEnd=[];masked.masks=[mask];p.clips.append(masked);_=try p.validated()
        let movie=root.appendingPathComponent("features.mp4");try await MovieExporter.export(project:p,directory:root,destination:movie){_ in}
        let generator=AVAssetImageGenerator(asset:AVURLAsset(url:movie));generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero;let renderer=FrameRenderer()
        for t in [0.0,0.4,1.0,1.7]{let ctx=try XCTUnwrap(RasterTools.bitmap(CGSize(width:640,height:360)));renderer.draw(project:p,directory:root,time:t,context:ctx,size:CGSize(width:640,height:360));let preview=NSBitmapImageRep(cgImage:try XCTUnwrap(ctx.makeImage())),output=NSBitmapImageRep(cgImage:try generator.copyCGImage(at:CMTime(seconds:t,preferredTimescale:600),actualTime:nil));var error=0.0,count=0.0
            for y in stride(from:0,to:360,by:4){for x in stride(from:0,to:640,by:4){let a=try XCTUnwrap(preview.colorAt(x:x,y:y)),b=try XCTUnwrap(output.colorAt(x:x,y:y));error+=abs(a.redComponent-b.redComponent)+abs(a.greenComponent-b.greenComponent)+abs(a.blueComponent-b.blueComponent);count+=3}}
            XCTAssertLessThan(error/count,0.02)
            if let keep{try XCTUnwrap(preview.representation(using:.png,properties:[:])).write(to:keep.appendingPathComponent("preview-\(t).png"));try XCTUnwrap(output.representation(using:.png,properties:[:])).write(to:keep.appendingPathComponent("output-\(t).png"))}
        }
        if let keep{try fm.copyItem(at:movie,to:keep.appendingPathComponent("features.mp4"));let package=keep.appendingPathComponent("Advanced58-QA.vmm");try fm.createDirectory(at:package,withIntermediateDirectories:true);try fm.copyItem(at:keep.appendingPathComponent("Media"),to:package.appendingPathComponent("Media"));try JSONEncoder().encode(p).write(to:package.appendingPathComponent("project.json"))
            let store=EditorStore(preferencesDirectory:root.appendingPathComponent("preferences"));store.autoSpeech=false;store.settings.autosaveSeconds=0;store.project=p;store.directory=root;store.selectedID=path.id
            for tab in ["図形・マスク","ブラー・残像","音声連動","追跡"]{store.selectedID=["ブラー・残像","追跡"].contains(tab) ? attached.id:path.id;store.seek(0.8);let view=NSHostingView(rootView:AnimationWorkspace(store:store,onClose:{},initialTab:tab));view.frame=CGRect(x:0,y:0,width:1280,height:850);let window=NSWindow(contentRect:view.frame,styleMask:[.titled,.resizable],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.contentView=view;window.orderBack(nil);view.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:400_000_000);view.layoutSubtreeIfNeeded();let bitmap=try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds));view.cacheDisplay(in:view.bounds,to:bitmap);try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:keep.appendingPathComponent("editor-\(tab).png"));window.close()}
        }
    }
}
