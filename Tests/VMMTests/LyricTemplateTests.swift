import XCTest
import AVFoundation
@testable import VMM

final class LyricTemplateTests:XCTestCase {
    @MainActor func testBeatSpacingPlaceUndoLocksAndFrameBounds() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-lyrics-\(UUID())"),store=EditorStore(preferencesDirectory:root)
        defer{store.pause();try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        store.project=Project();store.selectedTrack=1;let fps=store.project.fps,trackID=store.project.tracks[1].id
        let lines=try LyricTemplatePlanner.distribute("一行目\n二行目\n三行目",start:1,interval:4*60/120,fps:fps)
        XCTAssertEqual(lines.map(\.start),[1,3,5]);XCTAssertEqual(lines.map(\.end),[3,5,7])
        let sample=LyricTemplatePlanner.previewTime(lines[0],fps:fps);XCTAssertGreaterThanOrEqual(sample,lines[0].start);XCTAssertLessThan(sample,lines[0].end)
        XCTAssertEqual(sample*Double(fps),(sample*Double(fps)).rounded(),accuracy:0.000001)
        for size in [(7680,256),(256,7680),(3840,2160)] {let bounds=LyricTemplatePlanner.previewSize(width:size.0,height:size.1);XCTAssertGreaterThan(bounds.width,0);XCTAssertGreaterThan(bounds.height,0);XCTAssertLessThanOrEqual(max(bounds.width,bounds.height),640)}
        XCTAssertThrowsError(try LyricTemplatePlanner.distribute("",start:0,interval:1,fps:fps))
        XCTAssertThrowsError(try LyricTemplatePlanner.distribute("a",start:0,interval:.nan,fps:fps))
        let original=store.project
        store.project.tracks[1].locked=true;XCTAssertThrowsError(try store.placeLyricTemplate(lines:lines,trackID:trackID,fps:fps,motion:.bounce));store.project.tracks[1].locked=false
        XCTAssertEqual(store.project,original)
        var bad=lines;bad[1].start=bad[0].start
        XCTAssertThrowsError(try store.placeLyricTemplate(lines:bad,trackID:trackID,fps:fps,motion:.bounce));XCTAssertEqual(store.project,original)
        XCTAssertThrowsError(try store.placeLyricTemplate(lines:lines,trackID:trackID,fps:fps+1,motion:.bounce));XCTAssertEqual(store.project,original)
        try store.placeLyricTemplate(lines:lines,trackID:trackID,fps:fps,motion:.bounce)
        XCTAssertEqual(store.project.clips.count,3);XCTAssertEqual(store.project.clips.map(\.text),lines.map(\.text));XCTAssertTrue(store.project.clips.allSatisfy{$0.kind == .text && $0.textAnimation?.kind == .bounce})
        XCTAssertEqual(try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(store.project)),store.project)
        XCTAssertEqual(store.selection.count,3);store.undo();XCTAssertEqual(store.project,original)
    }
    @MainActor func testPreviewAndMovieFramesForSeparateLines() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-lyrics-render-\(UUID())"),store=EditorStore(preferencesDirectory:root)
        defer{store.pause();try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        store.project=Project();store.project.width=320;store.project.height=180;store.project.background="000000";store.selectedTrack=1
        let lines=try LyricTemplatePlanner.distribute("第一行\n第二行",start:0,interval:1,fps:store.project.fps)
        let trackID=store.project.tracks[1].id,helper=AdvancedTests()
        let (candidate,clips)=try store.lyricCandidate(lines:lines,trackID:trackID,fps:store.project.fps,motion:.fade)
        XCTAssertTrue(store.project.clips.isEmpty);XCTAssertEqual(clips.count,2)
        let a=try helper.pixels(helper.render(candidate,0.6,directory:store.directory)),b=try helper.pixels(helper.render(candidate,1.6,directory:store.directory))
        XCTAssertNotEqual(a,b)
        try store.placeLyricTemplate(lines:lines,trackID:trackID,fps:store.project.fps,motion:.fade)
        let first=try XCTUnwrap(store.project.clips.first);store.snapping=false
        let shortened=store.timelineChange(first,delta:0.2,track:first.track,edge:-1)
        var trimmed=store.project;trimmed.clips[0]=shortened
        XCTAssertEqual(try helper.pixels(helper.render(trimmed,0.6,directory:store.directory)),a)
        store.selectedIDs=[];store.selectedID=first.id;store.playhead=0.5;store.splitSelected()
        XCTAssertEqual(try helper.pixels(helper.render(store.project,0.6,directory:store.directory)),a)
        store.undo()
        let movie=root.appendingPathComponent("lyrics.mp4");try await MovieExporter.export(project:store.project,directory:store.directory,destination:movie){_ in}
        let generator=AVAssetImageGenerator(asset:AVURLAsset(url:movie));generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
        func pixelsAt(_ seconds:Double)throws->[UInt8] {
            let image=try generator.copyCGImage(at:CMTime(seconds:seconds,preferredTimescale:600),actualTime:nil),context=try XCTUnwrap(RasterTools.bitmap(CGSize(width:320,height:180)))
            context.draw(image,in:CGRect(x:0,y:0,width:320,height:180));return try helper.pixels(context)
        }
        let frameA=try pixelsAt(0.6),frameB=try pixelsAt(1.6)
        XCTAssertGreaterThan(frameA.enumerated().filter{$0.offset%4 != 3 && $0.element>40}.count,30);XCTAssertNotEqual(frameA,frameB)
    }
}
