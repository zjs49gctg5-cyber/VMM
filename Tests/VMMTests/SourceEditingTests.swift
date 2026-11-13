import XCTest
@testable import VMM

final class SourceEditingTests:XCTestCase {
    func fixture()->(Project,MediaAsset,Clip) {
        var p=Project();let a=MediaAsset(name:"source",file:"source.mp4",kind:.video,duration:20)
        var c=Clip(kind:.video,name:"old",track:0,start:0,duration:10);c.assetID=a.id;c.sourceOffset=2
        p.assets=[a];p.clips=[c];return(p,a,c)
    }
    func testInsertionSplitsSourceAndMovesAllTracksMarkersRange()throws {
        var (p,a,c)=fixture();var later=c;later.id=UUID();later.track=1;later.start=12;p.clips.append(later)
        p.markers=[TimelineMarker(time:12,name:"cue")];p.timelineRange=TimelineRange(start:3,end:14)
        let (result,id)=try SourceEditing.place(project:p,assetID:a.id,sourceIn:5,sourceOut:7,start:4,track:0,mode:.insert)
        let pieces=result.clips.filter{$0.name=="old" && $0.track==0}.sorted{$0.start<$1.start}
        XCTAssertEqual(pieces.map(\.start),[0,6]);XCTAssertEqual(pieces.map(\.duration),[4,6]);XCTAssertEqual(pieces.map(\.sourceOffset),[2,6]);XCTAssertEqual(pieces[1].animationTimeOffset,4)
        XCTAssertEqual(result.clips.first{$0.id==later.id}?.start,14);XCTAssertEqual(result.markers?.first?.time,14);XCTAssertEqual(result.timelineRange?.end,16)
        XCTAssertEqual(result.clips.first{$0.id==id}?.sourceOffset,5)
    }
    func testOverwriteKeepsOutsideSourceAndProtectsLinksLocks()throws {
        var (p,a,c)=fixture();let (r,_)=try SourceEditing.place(project:p,assetID:a.id,sourceIn:0,sourceOut:2,start:4,track:0,mode:.overwrite)
        let fragments=r.clips.filter{$0.name=="old"}.sorted{$0.start<$1.start}
        XCTAssertEqual(fragments.map(\.start),[0,6]);XCTAssertEqual(fragments.map(\.sourceOffset),[2,8]);XCTAssertEqual(fragments.map(\.duration),[4,4])
        c.linkID=UUID();p.clips=[c];XCTAssertThrowsError(try SourceEditing.place(project:p,assetID:a.id,sourceIn:0,sourceOut:2,start:4,track:0,mode:.overwrite))
        p.tracks[0].locked=true;XCTAssertThrowsError(try SourceEditing.slip(project:p,clipID:c.id,delta:0.1))
    }
    func testSlipAndRollPreserveTimingAndTotalSpan()throws {
        var (p,_,c)=fixture();c.duration=4;var b=c;b.id=UUID();b.start=4;b.sourceOffset=10;p.clips=[c,b]
        let slipped=try SourceEditing.slip(project:p,clipID:c.id,delta:0.0000208333333)
        XCTAssertEqual(slipped.clips[0].start,c.start);XCTAssertEqual(slipped.clips[0].sourceOffset,2.0000208333333,accuracy:1e-12)
        let r=try SourceEditing.roll(project:p,clipID:c.id,delta:1)
        XCTAssertEqual(r.clips.map(\.duration),[5,3]);XCTAssertEqual(r.clips[1].sourceOffset,11);XCTAssertEqual(r.clips[1].end,b.end)
        XCTAssertThrowsError(try SourceEditing.roll(project:p,clipID:c.id,delta:4));XCTAssertThrowsError(try SourceEditing.slip(project:p,clipID:c.id,delta:20))
    }
    @MainActor func testPlacementOneUndoAndMCPNumericSchema()throws {
        let prefs=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-source-test-\(UUID())")
        let s=EditorStore(preferencesDirectory:prefs);defer{try? FileManager.default.removeItem(at:s.directory);try? FileManager.default.removeItem(at:prefs)}
        let (p,a,_)=fixture();s.project=p;try s.placeSource(a.id,sourceIn:0,sourceOut:1,start:4,mode:.overwrite);s.undo();XCTAssertEqual(s.project,p)
        try MCPTools.validate(["assetID":a.id.uuidString,"sourceIn":0.0,"sourceOut":1.25],command:"media.placeRange")
        XCTAssertThrowsError(try MCPTools.validate(["clipID":UUID().uuidString,"delta":"1"],command:"clip.slip"))
    }
}
