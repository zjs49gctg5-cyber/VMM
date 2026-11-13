import XCTest
import Foundation
@testable import VMM

final class MCPProjectProtectionTests: XCTestCase {
    @MainActor func testAntigravityPreservesUnsavedLockedProject() async throws {
        guard let agy=ProcessInfo.processInfo.environment["VMM_AGY_CLI"] else {throw XCTSkip("Set VMM_AGY_CLI for authenticated Antigravity testing")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-agy-protection-\(UUID())"),agents=root.appendingPathComponent(".agents")
        try FileManager.default.createDirectory(at:agents,withIntermediateDirectories:true)
        let store=EditorStore(preferencesDirectory:root.appendingPathComponent("prefs")),mcp=VMMControlMCP(connectionURL:root.appendingPathComponent("connection.json"))
        store.autoSpeech=false;store.project=Project();store.project.clips=[]
        var clip=Clip(kind:.text,name:"Locked",track:0,start:0,duration:3);clip.text="未保存の大切な字幕"
        store.project.clips=[clip];store.project.tracks[0].locked=true;store.dirty=true
        let before=store.project
        defer{mcp.stop();try? FileManager.default.removeItem(at:store.directory);try? FileManager.default.removeItem(at:root)}
        let exposed=["vmm_state","vmm_capabilities","vmm_catalog","vmm_project_new","vmm_clip_update","vmm_clip_delete"]
        let helper=try MCPTests().helperPath()
        let config:[String:Any]=["mcpServers":["vmm":["command":helper.path,"args":["--connection",mcp.connectionURL.path],"enabledTools":exposed,"tools":Dictionary(uniqueKeysWithValues:exposed.map{($0,["eager":true])})]]]
        try JSONSerialization.data(withJSONObject:config).write(to:agents.appendingPathComponent("mcp_config.json"))
        mcp.start(store:store);XCTAssertTrue(mcp.running,mcp.status)
        let settings=try XCTUnwrap(String(data:try JSONSerialization.data(withJSONObject:["permissions":["allow":exposed.map{"mcp(vmm/\($0))"}]]),encoding:.utf8))
        let prompt="/vmm-control 一時テストです。現在のプロジェクトの未保存内容を消さず、保存・破棄せずに新規プロジェクトへ切り替えられるか、またロック中の字幕をロック解除せず変更できるか調べてください。保存、破棄、ロック解除、既存内容の変更はしないでください。"
        let result:(Int32,String)=try await Task.detached {
            let process=Process();process.executableURL=URL(fileURLWithPath:agy);process.currentDirectoryURL=root
            process.arguments=["--print-timeout","150s","--settings",settings,"--output-format","stream-json","-p",prompt]
            let pipe=Pipe();process.standardOutput=pipe;process.standardError=pipe
            try process.run();let data=pipe.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
            return(process.terminationStatus,String(decoding:data,as:UTF8.self))
        }.value
        XCTAssertEqual(result.0,0,result.1)
        let events=result.1.split(separator:"\n").compactMap{try? JSONSerialization.jsonObject(with:Data($0.utf8)) as? [String:Any]}
        let steps=events.compactMap{$0["step_update"] as? [String:Any]}.filter{($0["step_type"] as? String)=="tool" && ($0["state"] as? String)=="DONE"}
        XCTAssertTrue(steps.contains{($0["tool_name"] as? String)?.contains("vmm_state")==true})
        XCTAssertEqual(store.project,before);XCTAssertTrue(store.dirty);XCTAssertNil(store.savedURL)
    }
    @MainActor func testDirtyProjectAndLockedLayerRejectMCPChanges() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-protection-\(UUID())")
        let store=EditorStore(preferencesDirectory:root),commands=EditorCommands(),session=MCPSession(),protocolTest=MCPTests()
        defer{try? FileManager.default.removeItem(at:store.directory);try? FileManager.default.removeItem(at:root)}
        commands.store=store;store.autoSpeech=false;store.project=Project();store.project.clips=[]
        var clip=Clip(kind:.text,name:"Locked",track:0,start:0,duration:3);clip.text="未保存の大切な字幕"
        store.project.clips=[clip];store.project.tracks[0].locked=true;store.dirty=true
        let target=root.appendingPathComponent("other.vmm")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        var other=Project();other.name="別プロジェクト"
        try ProjectPackage.write(other,media:store.directory.appendingPathComponent("Media"),to:target)
        try protocolTest.initialize(session,commands)
        func call(_ name:String,_ args:[String:Any])throws->[String:Any] {
            let response=try XCTUnwrap(try protocolTest.send(session,commands,"tools/call",["name":name,"arguments":args]))
            return try XCTUnwrap(response["result"] as? [String:Any])
        }
        let before=store.project
        let state=try XCTUnwrap(try call("vmm_state",[:])["structuredContent"] as? [String:Any])
        XCTAssertEqual(state["dirty"] as? Bool,true);XCTAssertTrue(state["projectPath"] is NSNull)
        for (name,args) in [("vmm_project_open",["path":target.path]),("vmm_project_new",[:]),("vmm_clip_update",["clipID":clip.id.uuidString,"properties":["text":"変更"]]),("vmm_clip_delete",["clipID":clip.id.uuidString])] as [(String,[String:Any])] {
            let result=try call(name,args)
            XCTAssertEqual(result["isError"] as? Bool,true,"\(name) must be rejected")
            XCTAssertEqual(store.project,before,"\(name) must not change the project")
            XCTAssertTrue(store.dirty)
        }
        store.savedURL=root.appendingPathComponent("original.vmm")
        let savedState=try XCTUnwrap(try call("vmm_state",[:])["structuredContent"] as? [String:Any])
        XCTAssertEqual(savedState["dirty"] as? Bool,true)
        XCTAssertEqual(savedState["projectPath"] as? String,store.savedURL?.path)
    }
}
