import XCTest
import AppKit
import AVFoundation
@testable import VMM

final class MotionEditingTests:XCTestCase {
    @MainActor func setupStore()->EditorStore {let s=EditorStore(preferencesDirectory:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString));s.autoSpeech=false;s.settings.autosaveSeconds=0
        var c=Clip(kind:.shape,name:"移動",track:0,start:2,duration:4);c.animationOffset=1;c.animation=ClipAnimation(tracks:[AnimationTrack(property:.x,keys:[AnimationKeyframe(time:0,value:0.1,easing:.linear),AnimationKeyframe(time:1,value:0.2,easing:.linear),AnimationKeyframe(time:3,value:0.5,easing:.linear),AnimationKeyframe(time:5,value:0.8)])]);s.project.clips=[c];s.selectedID=c.id;return s}
    @MainActor func testIntervalsPreserveOffsetsIndependentKeysAndUndo()throws {
        let s=setupStore();defer{try? FileManager.default.removeItem(at:s.directory)};let c=s.project.clips[0],id=c.id
        XCTAssertEqual(c.motionBoundaries,[1,3,5]);let original=s.project
        try s.setMotionValue(id,property:.y,time:5,value:0.8)
        XCTAssertEqual(s.project.clips[0].motionValue(.y,at:1),0.5);XCTAssertEqual(s.project.clips[0].motionValue(.y,at:5),0.8)
        XCTAssertEqual(s.project.clips[0].animation?.tracks[0],c.animation?.tracks[0]);s.undo();XCTAssertEqual(s.project,original);s.redo()
        let point=try s.insertMotionPoint(id,at:2.37);XCTAssertEqual(point,2.3666666667,accuracy:0.000001)
        XCTAssertEqual(s.project.clips[0].motionValue(.x,at:point),c.motionValue(.x,at:point),accuracy:0.000001)
        let before=s.project;try s.moveMotionPoint(id,from:point,to:2.5);XCTAssertFalse(s.project.clips[0].motionBoundaries.contains(point));s.undo();XCTAssertEqual(s.project,before)
        XCTAssertThrowsError(try s.moveMotionPoint(id,from:point,to:3));XCTAssertEqual(s.project,before)
        XCTAssertThrowsError(try s.deleteMotionPoint(id,at:1));XCTAssertEqual(s.project,before)
        let duplicate=try s.duplicateMotionPoint(id,at:point);XCTAssertGreaterThan(duplicate,point)
        try s.deleteMotionPoint(id,at:duplicate);XCTAssertEqual(s.project.clips[0].animation?.tracks.map(\.keys).flatMap{$0}.filter{abs($0.time-duplicate)<0.000001}.count,0)
        let locked=s.project;s.project.tracks[0].locked=true;let b=s.project;XCTAssertThrowsError(try s.setMotionValue(id,property:.x,time:1,value:0.9));XCTAssertEqual(s.project,b);s.project=locked
        XCTAssertEqual(try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(s.project)).validated(),s.project)
    }
    @MainActor func testAutoKeyRecordsOnlyChangedPropertiesAndLoopIsTransient()throws {
        let s=setupStore();defer{try? FileManager.default.removeItem(at:s.directory)};let base=s.project.clips[0];var moved=base;moved.previewOffset(.x,by:0.1);moved.previewOffset(.y,by:0.2)
        let recorded=base.recordingPreviewChange(moved,at:2)
        XCTAssertEqual(recorded.motionValue(.x,at:2),moved.motionValue(.x,at:2),accuracy:0.000001)
        XCTAssertEqual(recorded.motionValue(.x,at:1),base.motionValue(.x,at:1));XCTAssertEqual(recorded.motionValue(.x,at:5),base.motionValue(.x,at:5))
        XCTAssertEqual(recorded.motionValue(.y,at:1),base.y);XCTAssertEqual(recorded.motionValue(.y,at:5),base.y)
        XCTAssertNil(recorded.animation?.tracks.first{$0.property == .rotation})
        try recorded.validateAnimation()
        s.project.timelineRange=TimelineRange(start:0,end:10,loop:true);let saved=s.project
        s.animationPlaybackRange=TimelineRange(start:2,end:4,loop:true);s.advancePlayback(to:4.5,clockTime:100);XCTAssertEqual(s.playhead,2.5,accuracy:0.000001);XCTAssertEqual(s.project,saved)
        s.animationPlaybackRange=TimelineRange(start:2,end:4,loop:false);s.advancePlayback(to:4.5);XCTAssertEqual(s.playhead,4);XCTAssertNil(s.animationPlaybackRange)
    }
    @MainActor func testDisablingAnimationLoopUpdatesLiveRangeWithoutProjectFallback()throws {
        let s=setupStore();defer{s.pause();try? FileManager.default.removeItem(at:s.directory)}
        s.project.timelineRange=TimelineRange(start:0,end:6,loop:true);let saved=s.project
        s.toggleMotionPlayback(s.project.clips[0].id,from:1,to:3,loop:true)
        XCTAssertTrue(s.playing);XCTAssertEqual(s.animationPlaybackRange?.loop,true)
        s.setMotionPlaybackLoop(false,clipID:s.project.clips[0].id,from:1,to:3);XCTAssertTrue(s.playing);XCTAssertEqual(s.animationPlaybackRange?.loop,false)
        s.advancePlayback(to:4.1);XCTAssertEqual(s.playhead,4.1);XCTAssertTrue(s.playing);s.advancePlayback(to:6.1);XCTAssertEqual(s.playhead,6);XCTAssertFalse(s.playing);XCTAssertNil(s.animationPlaybackRange);XCTAssertEqual(s.project,saved)
        s.seek(5.5);s.toggleMotionPlayback(s.project.clips[0].id,from:1,to:3,loop:false);XCTAssertEqual(s.playhead,5.5);XCTAssertEqual(s.animationPlaybackRange?.end,6);s.setMotionPlaybackLoop(true,clipID:s.project.clips[0].id,from:1,to:3)
        s.advancePlayback(to:4.2,clockTime:100);XCTAssertTrue(s.playing);XCTAssertEqual(s.playhead,2.2,accuracy:0.000001)
    }
    @MainActor func testIndependentKeyMoveAndLimitAreAtomic()throws {
        let s=setupStore();defer{try? FileManager.default.removeItem(at:s.directory)};let id=s.project.clips[0].id
        try s.setMotionValue(id,property:.y,time:2,value:0.3);let y=s.project.clips[0].animation?.tracks.first{$0.property == .y}
        try s.moveMotionPoint(id,from:3,to:2,property:.x);XCTAssertEqual(s.project.clips[0].animation?.tracks.first{$0.property == .y},y)
        let before=s.project;XCTAssertThrowsError(try s.setMotionValue(id,property:.opacity,time:2,value:2));XCTAssertEqual(s.project,before)
        var c=s.project.clips[0];c.animation?.tracks[0].keys=(0..<500).map{AnimationKeyframe(time:Double($0)/100,value:0.5)};s.project.clips=[c]
        let full=s.project;XCTAssertThrowsError(try s.insertMotionPoint(id,at:4.993333));XCTAssertEqual(s.project,full)
    }
    func testRecordedMotionPreviewAndMP4()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("motion-ui-"+UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        var p=Project();p.width=320;p.height=180;p.fps=30;p.background="000000";var c=Clip(kind:.shape,name:"動く四角",track:0,start:0,duration:1);c.color="FF0000";c.scale=0.1;c.x=0.2;c.animation=ClipAnimation(tracks:[AnimationTrack(property:.x,keys:[AnimationKeyframe(time:0,value:0.2,easing:.linear),AnimationKeyframe(time:1,value:0.8)])]);var moved=c;moved.previewOffset(.y,by:0.2);c=c.recordingPreviewChange(moved,at:0.5);p.clips=[c]
        let output=root.appendingPathComponent("motion.mp4");try await MovieExporter.export(project:p,directory:root,destination:output){_ in}
        let generator=AVAssetImageGenerator(asset:AVURLAsset(url:output));generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
        for time in [0.0,0.5,0.9] {let ctx=try XCTUnwrap(RasterTools.bitmap(CGSize(width:320,height:180)));FrameRenderer().draw(project:p,directory:root,time:time,context:ctx,size:CGSize(width:320,height:180));let preview=NSBitmapImageRep(cgImage:try XCTUnwrap(ctx.makeImage())),frame=NSBitmapImageRep(cgImage:try generator.copyCGImage(at:CMTime(seconds:time,preferredTimescale:600),actualTime:nil));let shown=c.animated(at:time),x=Int(shown.x*320),y=Int(shown.y*180);XCTAssertGreaterThan(try XCTUnwrap(preview.colorAt(x:x,y:y)?.usingColorSpace(.sRGB)).redComponent,0.8);XCTAssertGreaterThan(try XCTUnwrap(frame.colorAt(x:x,y:y)?.usingColorSpace(.sRGB)).redComponent,0.7)}
    }
}
