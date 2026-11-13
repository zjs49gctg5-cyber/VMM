import XCTest
@testable import VMM
final class LinkedMediaTests:XCTestCase {
    @MainActor func store()->EditorStore {
        let store=EditorStore(preferencesDirectory:FileManager.default.temporaryDirectory.appendingPathComponent("vmm-link-\(UUID())"));store.autoSpeech=false;store.project=Project()
        var v=Clip(kind:.video,name:"video",track:0,start:2,duration:4);v.audioDisabled=true;v.linkID=UUID()
        var a=Clip(kind:.audio,name:"audio",track:1,start:2,duration:4);a.linkID=v.linkID
        store.project.clips=[v,a];store.selectedID=v.id;return store
    }
    @MainActor func testMoveTrimSplitDeleteAndUndo()throws {
        let s=store();defer{try? FileManager.default.removeItem(at:s.directory)}
        let video=s.project.clips[0].id,original=s.project
        s.edit(video){$0.start=3};XCTAssertEqual(s.project.clips.map(\.start),[3,3]);s.undo();XCTAssertEqual(s.project,original)
        s.edit(video){$0.start=3;$0.duration=3;$0.sourceOffset=1}
        XCTAssertEqual(s.project.clips.map(\.sourceOffset),[1,1]);XCTAssertEqual(s.project.clips.map(\.duration),[3,3])
        s.playhead=4.5;s.splitSelected();XCTAssertEqual(s.project.clips.count,4)
        let right=s.project.clips.filter{$0.start==4.5};XCTAssertEqual(right.count,2);XCTAssertEqual(Set(right.compactMap(\.linkID)).count,1)
        XCTAssertNotEqual(right[0].linkID,s.project.clips[0].linkID);XCTAssertEqual(right.map(\.sourceOffset),[2.5,2.5])
        s.selectedIDs=[];s.selectedID=right[0].id;s.deleteSelected();XCTAssertEqual(s.project.clips.count,2);s.undo();XCTAssertEqual(s.project.clips.count,4)
        let roundTrip=try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(s.project));XCTAssertEqual(roundTrip,s.project)
    }
    @MainActor func testLocksRejectWholeEditAndUnlinkRestoresIndependentEditing()throws {
        let s=store();defer{try? FileManager.default.removeItem(at:s.directory)}
        s.project.tracks[1].locked=true;let before=s.project
        s.edit(s.project.clips[0].id){$0.start=10};XCTAssertEqual(s.project,before);XCTAssertNotNil(s.error)
        let api=EditorCommands();api.store=s
        let request:[String:Any]=["command":"clip.update","clipID":s.project.clips[0].id.uuidString,"properties":["start":10]]
        XCTAssertEqual(api.execute(body:try JSONSerialization.data(withJSONObject:request)).status,400)
        s.project.tracks[1].locked=false;try s.unlinkSelection();s.edit(s.project.clips[0].id){$0.start=10}
        XCTAssertEqual(s.project.clips.map(\.start),[10,2])
    }
    @MainActor func testCopiesGetIndependentLinkGroupAndLegacyDecodes()throws {
        let s=store();defer{try? FileManager.default.removeItem(at:s.directory)}
        s.duplicateSelection();XCTAssertEqual(s.project.clips.count,4)
        XCTAssertEqual(Set(s.project.clips.compactMap(\.linkID)).count,2)
        s.selectedIDs=[];s.selectedID=s.project.clips[2].id;s.edit(s.project.clips[2].id){$0.start=20}
        XCTAssertEqual(s.project.clips.prefix(2).map(\.start),[2,2]);XCTAssertEqual(s.project.clips.suffix(2).map(\.start),[20,20])
        var json=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(s.project)) as? [String:Any]);var clips=json["clips"] as! [[String:Any]]
        for i in clips.indices {clips[i].removeValue(forKey:"linkID")};json["clips"]=clips
        let legacy=try JSONDecoder().decode(Project.self,from:JSONSerialization.data(withJSONObject:json));XCTAssertTrue(legacy.clips.allSatisfy{$0.linkID==nil})
    }
}
