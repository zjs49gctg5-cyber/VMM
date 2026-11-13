import XCTest
@testable import VMM

final class ArrangeAtomicityTests:XCTestCase {
    @MainActor private func makeStore()->EditorStore {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-arrange-\(UUID())")
        let store=EditorStore(preferencesDirectory:root);store.autoSpeech=false;store.settings.autosaveSeconds=0
        return store
    }
    @MainActor func testLockedSelectionRejectsWithoutUndoAndMCPReportsError()throws {
        let store=makeStore();defer{try? FileManager.default.removeItem(at:store.preferencesDirectory);try? FileManager.default.removeItem(at:store.directory)}
        let a=Clip(kind:.text,name:"a",track:0,start:0,duration:1),b=Clip(kind:.text,name:"b",track:1,start:2,duration:1)
        store.project.clips=[a,b];store.project.tracks[1].locked=true;store.selectedID=a.id;store.selectedIDs=[a.id,b.id]
        let original=store.project
        store.arrange("開始揃え")
        XCTAssertEqual(store.project,original);XCTAssertNotNil(store.error);XCTAssertFalse(store.canUndo)
        let commands=EditorCommands();commands.store=store
        let result=commands.execute(body:try JSONSerialization.data(withJSONObject:["command":"selection.arrange","mode":"開始揃え"]))
        XCTAssertEqual(result.status,400);XCTAssertEqual(store.project,original);XCTAssertFalse(store.canUndo)
    }
    @MainActor func testBulkStyleRejectsLockedSubtitleWithoutPartialChanges() {
        let store=makeStore();defer{try? FileManager.default.removeItem(at:store.preferencesDirectory);try? FileManager.default.removeItem(at:store.directory)}
        var a=Clip(kind:.text,name:"a",track:0,start:0,duration:1),b=Clip(kind:.text,name:"b",track:1,start:1,duration:1)
        a.color="FF0000";b.color="0000FF";store.project.clips=[a,b];store.project.tracks[1].locked=true
        store.selectedID=a.id;store.selectedIDs=[a.id,b.id];let before=store.project
        store.bulkStyle();XCTAssertEqual(store.project,before);XCTAssertNotNil(store.error);XCTAssertFalse(store.canUndo)
        store.project.tracks[1].locked=false;let unlocked=store.project;store.bulkStyle()
        XCTAssertEqual(store.project.clips[1].color,"FF0000");store.undo();XCTAssertEqual(store.project,unlocked)
    }
    @MainActor func testLinkedLockedPeerDoesNotApplyEarlierClip()throws {
        let store=makeStore();defer{try? FileManager.default.removeItem(at:store.preferencesDirectory);try? FileManager.default.removeItem(at:store.directory)}
        let first=Clip(kind:.text,name:"first",track:0,start:0,duration:1),middle=Clip(kind:.text,name:"middle",track:0,start:1,duration:1)
        var video=Clip(kind:.video,name:"video",track:1,start:2,duration:1),audio=Clip(kind:.audio,name:"audio",track:2,start:2,duration:1)
        video.linkID=UUID();audio.linkID=video.linkID;video.audioDisabled=true
        store.project.clips=[first,middle,video,audio];store.project.tracks[2].locked=true;store.selectedID=first.id;store.selectedIDs=[first.id,middle.id,video.id]
        let original=store.project
        XCTAssertThrowsError(try store.arrangeValidated("開始揃え"));XCTAssertEqual(store.project,original);XCTAssertFalse(store.canUndo)
    }
    @MainActor func testSequentialLinkedSelectionRejectsIncompatibleDestinations()throws {
        let store=makeStore();defer{try? FileManager.default.removeItem(at:store.preferencesDirectory);try? FileManager.default.removeItem(at:store.directory)}
        var video=Clip(kind:.video,name:"video",track:0,start:0,duration:1),audio=Clip(kind:.audio,name:"audio",track:1,start:0,duration:1)
        video.linkID=UUID();audio.linkID=video.linkID;video.audioDisabled=true
        store.project.clips=[video,audio];store.selectedID=video.id;store.selectedIDs=[video.id,audio.id]
        let original=store.project
        XCTAssertThrowsError(try store.arrangeValidated("順番"));XCTAssertEqual(store.project,original);XCTAssertFalse(store.canUndo)
    }
    @MainActor func testSuccessfulArrangeMovesLinkedPeerAndUndoesOnce()throws {
        let store=makeStore();defer{try? FileManager.default.removeItem(at:store.preferencesDirectory);try? FileManager.default.removeItem(at:store.directory)}
        let first=Clip(kind:.text,name:"first",track:0,start:0,duration:1)
        var video=Clip(kind:.video,name:"video",track:1,start:2,duration:1),audio=Clip(kind:.audio,name:"audio",track:2,start:2,duration:1)
        video.linkID=UUID();audio.linkID=video.linkID;video.audioDisabled=true
        store.project.clips=[first,video,audio];store.selectedID=first.id;store.selectedIDs=[first.id,video.id]
        let original=store.project
        try store.arrangeValidated("開始揃え")
        XCTAssertEqual(store.project.clips.map(\.start),[0,0,0]);XCTAssertTrue(store.canUndo)
        store.undo();XCTAssertEqual(store.project,original);XCTAssertFalse(store.canUndo)
    }
}
