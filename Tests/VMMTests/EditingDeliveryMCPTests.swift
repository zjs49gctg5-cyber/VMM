import XCTest
import AVFoundation
@testable import VMM

final class EditingDeliveryMCPTests:XCTestCase {
    @MainActor func testNewEditingAndDeliveryCommandsThroughMCP()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-delivery-mcp-\(UUID())"),store=EditorStore(preferencesDirectory:root),commands=EditorCommands(),session=MCPSession(),protocolTests=MCPTests()
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{store.pause();try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        store.autoSpeech=false;store.project=try AudioDeliveryTests().fixture(store.directory);commands.store=store
        try protocolTests.initialize(session,commands)
        func call(_ name:String,_ args:[String:Any]=[:])throws->[String:Any] {
            let result=try XCTUnwrap(try protocolTests.send(session,commands,"tools/call",["name":"vmm."+name,"arguments":args])?["result"] as? [String:Any])
            XCTAssertEqual(result["isError"] as? Bool,false,String(describing:result));return try XCTUnwrap(result["structuredContent"] as? [String:Any])
        }
        let original=store.project,asset=original.assets[0]
        let placed=try call("media.placeRange",["assetID":asset.id.uuidString,"sourceIn":0.2,"sourceOut":0.7,"start":1.4,"track":2,"mode":"append"])
        let id=try XCTUnwrap(placed["clipID"] as? String)
        _=try call("clip.slip",["clipID":id,"delta":0.01]);XCTAssertEqual(store.selected?.sourceOffset ?? 0,0.21,accuracy:1e-8)
        _=try call("undo");_=try call("undo");XCTAssertEqual(store.project,original)
        for (name,path) in [("export.audio",root.appendingPathComponent("sound.wav")),("export.interchange",root.appendingPathComponent("handoff"))] {
            let result=try call(name,["path":path.path]),job=try XCTUnwrap(result["jobID"] as? String)
            for _ in 0..<1000 where commands.jobs[job]?["state"] as? String=="running" {try await Task.sleep(nanoseconds:10_000_000)}
            XCTAssertEqual(commands.jobs[job]?["state"] as? String,"completed",String(describing:commands.jobs[job]));XCTAssertTrue(FileManager.default.fileExists(atPath:path.path))
        }
        XCTAssertEqual(store.project,original)
    }
}
