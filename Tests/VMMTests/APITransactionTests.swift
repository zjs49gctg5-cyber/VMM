import XCTest
@testable import VMM
@MainActor final class APITransactionTests:XCTestCase {
    func testAtomicFailureOneUndoAliasesDryRunAndRevision()throws {
        let s=EditorStore(preferencesDirectory:FileManager.default.temporaryDirectory.appendingPathComponent("vmm-transaction-\(UUID())")),api=EditorCommands();api.store=s;s.autoSpeech=false;s.project=Project()
        defer{try? FileManager.default.removeItem(at:s.directory)}
        func command(_ operations:[[String:Any]],extra:[String:Any]=[:])throws->ControlResult {
            var request:[String:Any]=["command":"project.transaction","operations":operations];for (key,v) in extra{request[key]=v}
            return api.execute(body:try JSONSerialization.data(withJSONObject:request))
        }
        let before=s.project,revision=s.projectRevision
        let operations:[[String:Any]]=[
            ["command":"clip.add","kind":"group","ref":"parent","track":0,"properties":["start":0,"duration":2]],
            ["command":"clip.add","kind":"text","ref":"caption","track":1,"properties":["parentID":"$parent","text":"$literal remains text","start":0,"duration":2]],
            ["command":"clip.update","clipID":"$caption","properties":["color":"FF0000"]]
        ]
        XCTAssertEqual(try command(operations,extra:["dryRun":true]).status,200);XCTAssertEqual(s.project,before);XCTAssertEqual(s.projectRevision,revision)
        XCTAssertEqual(try command(operations+[["command":"clip.update","clipID":"$caption","properties":["duration":-1]]]).status,400);XCTAssertEqual(s.project,before);XCTAssertFalse(s.canUndo)
        XCTAssertEqual(try command(operations,extra:["expectedRevision":revision-1]).status,409);XCTAssertEqual(s.project,before)
        XCTAssertEqual(try command(operations,extra:["expectedRevision":revision]).status,200);XCTAssertEqual(s.project.clips.count,2);XCTAssertEqual(s.project.clips[1].text,"$literal remains text");XCTAssertEqual(s.project.clips[1].parentID,s.project.clips[0].id)
        s.undo();XCTAssertEqual(s.project,before);XCTAssertFalse(s.canUndo);s.redo();XCTAssertEqual(s.project.clips.count,2)
        let ready=s.project;XCTAssertEqual(try command([["command":"project.save","path":"/tmp/no.vmm"]]).status,400);XCTAssertEqual(s.project,ready)
    }
    func testNewTracksAndLinkedLockedUpdatesAreAtomic()throws {
        let s=EditorStore(),api=EditorCommands();api.store=s;s.autoSpeech=false;s.project=Project()
        defer{try? FileManager.default.removeItem(at:s.directory)}
        func send(_ operations:[[String:Any]])throws->ControlResult {api.execute(body:try JSONSerialization.data(withJSONObject:["command":"project.transaction","operations":operations]))}
        let index=s.project.tracks.count
        XCTAssertEqual(try send([["command":"track.add","name":"New"],["command":"clip.add","kind":"text","track":index,"properties":["text":"New layer"]]]).status,200)
        XCTAssertEqual(s.project.clips.last?.track,index)
        var v=Clip(kind:.video,name:"video",track:0,start:0,duration:1);v.linkID=UUID()
        var a=Clip(kind:.audio,name:"audio",track:1,start:0,duration:1);a.linkID=v.linkID;s.project.clips=[v,a];s.project.tracks[1].locked=true
        let before=s.project
        XCTAssertEqual(try send([["command":"clip.add","kind":"text","track":0,"properties":["track":1]]]).status,400);XCTAssertEqual(s.project,before)
        XCTAssertEqual(try send([["command":"clip.update","clipID":v.id.uuidString,"properties":["start":10]]]).status,400);XCTAssertEqual(s.project,before)
    }
}
