import XCTest
import Foundation
import AppKit
@testable import VMM

@MainActor
final class CommandTests:XCTestCase {
    func command(_ api:EditorCommands,_ value:[String:Any])throws->ControlResult {
        api.execute(body:try JSONSerialization.data(withJSONObject:value))
    }
    func object(_ result:ControlResult)throws->[String:Any] {try XCTUnwrap(JSONSerialization.jsonObject(with:result.body) as? [String:Any])}
    func testNewMCPProjectCanBeResavedWithoutExplicitOverwrite()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-mcp-resave-\(UUID())")
        let store=EditorStore(preferencesDirectory:root),api=EditorCommands();api.store=store;store.autoSpeech=false
        defer{try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        let url=URL(fileURLWithPath:root.appendingPathComponent("new.vmm").path,isDirectory:false)
        func save()async throws {
            let result=try command(api,["command":"project.save","path":url.path,"async":true])
            XCTAssertEqual(result.status,202)
            let id=try XCTUnwrap(try object(result)["jobID"] as? String)
            for _ in 0..<200 where api.jobs[id]?["state"] as? String == "running" {try await Task.sleep(nanoseconds:10_000_000)}
            XCTAssertEqual(api.jobs[id]?["state"] as? String,"completed",String(describing:api.jobs[id]))
        }
        try await save()
        XCTAssertNotEqual(store.savedURL,URL(fileURLWithPath:url.path))
        store.project.clips[0].name="updated after first save"
        try await save()
        let saved=try JSONDecoder().decode(Project.self,from:Data(contentsOf:url.appendingPathComponent("project.json")))
        XCTAssertEqual(saved.clips[0].name,"updated after first save")
        let foreign=root.appendingPathComponent("unrelated.vmm",isDirectory:true)
        try FileManager.default.createDirectory(at:foreign,withIntermediateDirectories:true)
        let marker=foreign.appendingPathComponent("do-not-replace.txt"),data=Data("keep".utf8);try data.write(to:marker)
        XCTAssertEqual(try command(api,["command":"project.save","path":foreign.path,"async":true]).status,400)
        XCTAssertEqual(try Data(contentsOf:marker),data)
    }
    func testAsyncProjectIOJobsReserveEditorAndPreserveSyncContract()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-api-io-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let store=EditorStore(preferencesDirectory:root),api=EditorCommands();api.store=store;store.autoSpeech=false
        defer{try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        let url=root.appendingPathComponent("API.vmm")
        for cmd in ["project.save","project.open"] {
            let response=try command(api,["command":cmd,"path":url.path,"async":true,"discardChanges":true])
            XCTAssertEqual(response.status,202);XCTAssertTrue(store.busy)
            XCTAssertEqual(try command(api,["command":"project.new","discardChanges":true]).status,409)
            let job=try XCTUnwrap(try object(response)["jobID"] as? String)
            for _ in 0..<200 where api.jobs[job]?["state"] as? String == "running" {try await Task.sleep(nanoseconds:10_000_000)}
            XCTAssertEqual(api.jobs[job]?["state"] as? String,"completed",String(describing:api.jobs[job]));XCTAssertFalse(store.busy)
        }
        XCTAssertEqual(store.project.name,"API")
        XCTAssertEqual(try command(api,["command":"project.save","path":url.path]).status,200)
        XCTAssertEqual(try command(api,["command":"speech.cancel"]).status,200)
        let state=try object(api.read("state"))
        XCTAssertNotNil(state["speechFailures"]);XCTAssertNotNil(state["projectIOProgress"])
    }
    func testEditingCommandsValidateBeforeMutationAndSupportUndo()throws {
        let store=EditorStore(),api=EditorCommands();api.store=store;store.autoSpeech=false
        defer{try? FileManager.default.removeItem(at:store.directory)}
        let count=store.project.clips.count
        let added=try command(api,["command":"clip.add","kind":"text","properties":["text":"APIから追加","x":0.2,"duration":2]])
        XCTAssertEqual(added.status,200);let id=try XCTUnwrap(try object(added)["clipID"] as? String)
        XCTAssertEqual(store.project.clips.count,count+1)
        XCTAssertEqual(store.selected?.text,"APIから追加")
        XCTAssertEqual(try command(api,["command":"clip.update","clipID":id,"properties":["duration":-1]]).status,400)
        XCTAssertEqual(store.selected?.duration,2)
        XCTAssertEqual(try command(api,["command":"clip.update","clipID":id,"properties":["id":UUID().uuidString]]).status,400)
        XCTAssertEqual(try command(api,["command":"clip.update","clipID":id,"properties":["track":1000]]).status,400)
        XCTAssertEqual(try command(api,["command":"clip.update","clipID":id,"properties":["text":"更新後"]]).status,200)
        XCTAssertEqual(store.selected?.text,"更新後")
        XCTAssertEqual(try command(api,["command":"undo"]).status,200)
        XCTAssertEqual(store.selected?.text,"APIから追加")
        store.project.tracks[store.selected!.track].locked=true
        XCTAssertEqual(try command(api,["command":"clip.delete","clipID":id]).status,400)
        XCTAssertEqual(store.project.clips.count,count+1)
        store.busy=true;XCTAssertEqual(try command(api,["command":"seek","time":1]).status,409)
        store.busy=false;XCTAssertEqual(try command(api,["command":"seek","time":1]).status,200)
        XCTAssertEqual(store.playhead,1)
        let state=try object(api.read("state"))
        XCTAssertNotNil(state["project"]);XCTAssertNil(state["token"])
    }

}

extension CommandTests {
    func testWorkflowCommandsSelectionDictionarySettingsAndAtomicValidation()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-api-workflow-\(UUID())")
        let store=EditorStore(preferencesDirectory:root),api=EditorCommands();api.store=store;store.autoSpeech=false;store.project.clips=[]
        defer{try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        XCTAssertEqual(try command(api,["command":"script.import","text":"A：こんにちは\nB：APIの説明","start":0,"track":1]).status,200)
        let ids=store.project.clips.map{ $0.id.uuidString }
        XCTAssertEqual(try command(api,["command":"selection.set","clipIDs":ids]).status,200)
        XCTAssertEqual(try command(api,["command":"selection.update","properties":["color":"33AAFF","reading":"よみ","textRevealRate":10,"textStyle":["fontName":"Menlo-Regular","outline":true,"outlineColor":"000000","outlineWidth":3,"shadow":false,"shadowColor":"000000","shadowOpacity":0.5,"shadowBlur":3,"shadowX":3,"shadowY":3]]]).status,200)
        XCTAssertTrue(store.project.clips.allSatisfy{$0.color=="33AAFF" && $0.reading=="よみ"})
        let before=store.project
        XCTAssertEqual(try command(api,["command":"selection.update","properties":["textRevealRate":0]]).status,400);XCTAssertEqual(store.project,before)
        XCTAssertEqual(try command(api,["command":"settings.update","properties":["uiScale":10]]).status,400);XCTAssertEqual(store.settings.uiScale,1)
        XCTAssertEqual(try command(api,["command":"settings.update","properties":["uiScale":1.2,"exportContainer":"MOV","adaptivePreview":false,"previewMinimumLongEdge":1080]]).status,200)
        let saved=try JSONDecoder().decode(UserSettings.self,from:Data(contentsOf:root.appendingPathComponent("settings.json")));XCTAssertEqual(saved.uiScale,1.2);XCTAssertEqual(saved.adaptivePreview,false);XCTAssertEqual(saved.previewMinimumLongEdge,1080)
        let entry=["id":UUID().uuidString,"word":"API","reading":"エーピーアイ"]
        XCTAssertEqual(try command(api,["command":"dictionary.set","entries":[entry]]).status,200)
        XCTAssertEqual(store.project.pronunciations?.first?.reading,"エーピーアイ")
        XCTAssertEqual(try command(api,["command":"selection.delete"]).status,200);XCTAssertTrue(store.project.clips.isEmpty)
        XCTAssertEqual(try command(api,["command":"undo"]).status,200);XCTAssertEqual(store.project.clips.count,2)
        XCTAssertEqual(api.read("catalog").status,200)
    }

}

extension CommandTests {
    func testP2CommandsAndNewOptionalFieldsValidateAtomically()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-p2-api-\(UUID())"),s=EditorStore(preferencesDirectory:root),api=EditorCommands();api.store=s;s.project=Project();s.project.clips=[]
        defer{try? FileManager.default.removeItem(at:s.directory)}
        XCTAssertEqual(try command(api,["command":"project.update","properties":["masterVolume":0.5,"markers":[["id":UUID().uuidString,"time":1,"name":"cue"]],"timelineRange":["start":0,"end":2,"loop":true]]]).status,200)
        let snapshot=s.project
        XCTAssertEqual(try command(api,["command":"project.update","properties":["masterVolume":-1]]).status,400);XCTAssertEqual(s.project,snapshot)
        XCTAssertEqual(try command(api,["command":"caption.import","format":"srt","text":"1\n00:00:01,000 --> 00:00:02,000\nAPI字幕"]).status,200)
        let result=try object(try command(api,["command":"caption.export","format":"vtt"]));XCTAssertTrue((result["text"] as? String)?.hasPrefix("WEBVTT")==true)
        XCTAssertEqual(try command(api,["command":"clip.update","clipID":s.project.clips[0].id.uuidString,"properties":["normalizationGain":-1]]).status,400)
        let asset=MediaAsset(name:"unused",file:"unused.png",kind:.image,duration:3);s.project.assets=[asset]
        XCTAssertEqual(try command(api,["command":"media.tags","assetID":asset.id.uuidString,"tags":["background"]]).status,200);XCTAssertEqual(s.project.assets[0].tags,["background"])
        XCTAssertEqual(try command(api,["command":"media.cleanupUnused"]).status,200);XCTAssertTrue(s.project.assets.isEmpty);s.undo();XCTAssertEqual(s.project.assets.count,1)
    }
}
