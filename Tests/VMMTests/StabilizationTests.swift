import XCTest
import AVFoundation
import AppKit
@testable import VMM

final class StabilizationTests:XCTestCase {
    func testSmoothedTranslationParentRotationAndUnsafeCases()throws {
        var project=Project();project.width=640;project.height=360;project.fps=30
        let asset=MediaAsset(name:"video",file:"fixture.mp4",kind:.video,duration:2)
        var parent=Clip(kind:.group,name:"parent",track:2,start:0,duration:2);parent.rotation=30
        var source=Clip(kind:.video,name:"video",track:1,start:0,duration:2);source.assetID=asset.id;source.parentID=parent.id
        project.assets=[asset];project.clips=[source,parent]
        let samples=(0..<12).map{i in TrackingSample(time:Double(i)/30*3,x:0.4+(i%2==0 ? -0.04:0.04),y:0.4,width:0.2,height:0.2,confidence:1)}
        let result=MotionTrackingResult(assetID:asset.id,samples:samples,frameWidth:640,frameHeight:360)
        let corrected=try VideoStabilizer.applying(result,to:source,project:project,strength:1,smoothing:0.45,zoom:1)
        let before=samples.map{$0.rect.midX},after=samples.map{sample in Double(sample.rect.midX)+corrected.animated(at:sample.time,aspectRatio:640/360.0).x-source.x}
        XCTAssertLessThan((after.max() ?? 0)-(after.min() ?? 0),(before.max() ?? 0)-(before.min() ?? 0))
        XCTAssertEqual(corrected.parentID,parent.id);XCTAssertEqual(corrected.scale,source.scale);XCTAssertNotNil(corrected.animation?.tracks.first{$0.property == .x});XCTAssertNotNil(corrected.animation?.tracks.first{$0.property == .y})
        var rotated=source;rotated.rotation=90
        let rotationResult=try VideoStabilizer.applying(result,to:rotated,project:project,strength:1,smoothing:0.45,zoom:1)
        XCTAssertEqual(rotationResult.animated(at:0.3,aspectRatio:640/360.0).x,rotated.x,accuracy:1e-8)
        XCTAssertNotEqual(rotationResult.animated(at:0.3,aspectRatio:640/360.0).y,rotated.y)
        let zoomed=try VideoStabilizer.applying(result,to:source,project:project,strength:0.5,smoothing:0.45,zoom:1.2);XCTAssertEqual(zoomed.scale,1.2,accuracy:1e-9)
        var failed=result;failed.lostAt=0.4;XCTAssertThrowsError(try VideoStabilizer.applying(failed,to:source,project:project,strength:1,smoothing:0.45,zoom:1))
        var keyed=source;keyed.putMotionKey(.x,time:0,value:0.5);XCTAssertThrowsError(try VideoStabilizer.applying(result,to:keyed,project:project,strength:1,smoothing:0.45,zoom:1))
        keyed=source;keyed.putMotionKey(.scale,time:0,value:1);XCTAssertThrowsError(try VideoStabilizer.applying(result,to:keyed,project:project,strength:1,smoothing:0.45,zoom:1.1))
        var unrelated=result;unrelated.assetID=UUID();XCTAssertThrowsError(try VideoStabilizer.applying(unrelated,to:source,project:project,strength:1,smoothing:0.45,zoom:1))
    }
    @MainActor func testTrackingUndoSplitTrimPreviewAndMP4()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-stabilization-\(UUID())"),store=EditorStore(preferencesDirectory:root)
        defer{store.pause();try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        store.autoSpeech=false;store.settings.autosaveSeconds=0
        var fixture=Project();fixture.width=320;fixture.height=180;fixture.fps=30;fixture.background="172330"
        var object=Clip(kind:.shape,name:"subject",track:0,start:0,duration:2);object.shapeStyle=ShapeStyle();object.shapeStyle?.width=0.3;object.shapeStyle?.height=0.35;object.color="DD7744"
        var text=Clip(kind:.text,name:"texture",track:1,start:0,duration:2,text:"TRACK",fontSize:20)
        for i in 0...10 {let t=Double(i)*0.2,x=0.5+(i%2==0 ? -0.025:0.025);object.putMotionKey(.x,time:t,value:x,easing:.linear);text.putMotionKey(.x,time:t,value:x,easing:.linear)}
        fixture.clips=[object,text]
        let file=store.directory.appendingPathComponent("Media/stabilization-source.mp4")
        try await MovieExporter.export(project:fixture,directory:store.directory,destination:file){_ in}
        let asset=MediaAsset(name:"source",file:"stabilization-source.mp4",kind:.video,duration:2)
        var source=Clip(kind:.video,name:"source",track:1,start:0,duration:2);source.assetID=asset.id
        store.project=Project();store.project.width=320;store.project.height=180;store.project.background="172330";store.project.assets=[asset];store.project.clips=[source];store.selectedID=source.id
        let before=store.project
        let result=try await store.stabilizeVideo(clipID:source.id,region:CGRect(x:0.33,y:0.30,width:0.34,height:0.4),from:0,duration:1.8,sampleRate:15,strength:1,smoothing:0.4,zoom:1)
        XCTAssertNil(result.lostAt);XCTAssertGreaterThan(result.samples.count,10)
        source=try XCTUnwrap(store.selected);XCTAssertNotNil(source.animation?.tracks.first{$0.property == .x});let corrected=store.project
        store.undo();XCTAssertEqual(store.project,before);store.redo();XCTAssertEqual(store.project,corrected)
        let oldAt=source.animated(at:1.2,aspectRatio:320/180.0)
        let trimmed=store.timelineChange(source,delta:0.5,track:source.track,edge:-1)
        XCTAssertEqual(trimmed.animated(at:1.2,aspectRatio:320/180.0).x,oldAt.x,accuracy:1e-8)
        store.playhead=1;store.snapping=false;store.splitSelected();let right=try XCTUnwrap(store.selected)
        XCTAssertEqual(right.animated(at:1.2,aspectRatio:320/180.0).x,oldAt.x,accuracy:1e-8)
        store.undo()
        let output=root.appendingPathComponent("stabilized.mp4");try await MovieExporter.export(project:store.project,directory:store.directory,destination:output){_ in}
        let generator=AVAssetImageGenerator(asset:AVURLAsset(url:output));generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
        for time in [0.3,1.2] {
            let context=try XCTUnwrap(RasterTools.bitmap(CGSize(width:320,height:180)));FrameRenderer().draw(project:store.project,directory:store.directory,time:time,context:context,size:CGSize(width:320,height:180))
            let preview=NSBitmapImageRep(cgImage:try XCTUnwrap(context.makeImage())),video=NSBitmapImageRep(cgImage:try generator.copyCGImage(at:CMTime(seconds:time,preferredTimescale:600),actualTime:nil))
            var difference=0.0,count=0.0
            for y in stride(from:0,to:180,by:4){for x in stride(from:0,to:320,by:4){let a=try XCTUnwrap(preview.colorAt(x:x,y:y)),b=try XCTUnwrap(video.colorAt(x:x,y:y));difference+=abs(a.redComponent-b.redComponent)+abs(a.greenComponent-b.greenComponent)+abs(a.blueComponent-b.blueComponent);count+=3}}
            XCTAssertLessThan(difference/count,0.04)
        }
    }
}
