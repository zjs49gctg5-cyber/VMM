import XCTest
import Foundation
import AppKit
@testable import VMM

final class AntigravityMCPIntegrationTests: XCTestCase {
    @MainActor func testInstalledSkillPlacesSubtitleAndImage() async throws {
        guard let binary=ProcessInfo.processInfo.environment["VMM_AGY_CLI"] else {throw XCTSkip("Set VMM_AGY_CLI for the authenticated Antigravity integration test")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-agy-media-\(UUID())")
        let agents=root.appendingPathComponent(".agents")
        try FileManager.default.createDirectory(at:agents,withIntermediateDirectories:true)
        let store=EditorStore(preferencesDirectory:root.appendingPathComponent("prefs"))
        let mcp=VMMControlMCP(connectionURL:root.appendingPathComponent("connection.json"))
        store.autoSpeech=false;store.project=Project()
        defer{mcp.stop();try? FileManager.default.removeItem(at:store.directory);try? FileManager.default.removeItem(at:root)}
        let bitmap=try XCTUnwrap(RasterTools.bitmap(CGSize(width:96,height:64)))
        bitmap.setFillColor(NSColor.systemGreen.cgColor);bitmap.fill(CGRect(x:0,y:0,width:96,height:64))
        let source=root.appendingPathComponent("test-image.png")
        let png=try XCTUnwrap(NSBitmapImageRep(cgImage:try XCTUnwrap(bitmap.makeImage())).representation(using:.png,properties:[:]))
        try png.write(to:source)
        let helper=try MCPTests().helperPath()
        let exposed=["vmm_state","vmm_capabilities","vmm_catalog","vmm_media_import","vmm_job","vmm_clip_add"]
        let config:[String:Any]=["mcpServers":["vmm":["command":helper.path,"args":["--connection",mcp.connectionURL.path],"tools":Dictionary(uniqueKeysWithValues:exposed.map{($0,["eager":true])})]]]
        try JSONSerialization.data(withJSONObject:config).write(to:agents.appendingPathComponent("mcp_config.json"))
        mcp.start(store:store);XCTAssertTrue(mcp.running,mcp.status)
        let settingsData=try JSONSerialization.data(withJSONObject:["permissions":["allow":exposed.map{"mcp(vmm/\($0))"}]])
        let settings=try XCTUnwrap(String(data:settingsData,encoding:.utf8))
        let result:(Int32,String)=try await Task.detached {
            let process=Process();process.executableURL=URL(fileURLWithPath:binary);process.currentDirectoryURL=root
            process.arguments=["--print-timeout","150s","--settings",settings,"--output-format","stream-json","-p","/vmm-control テスト用プロジェクトで、画像 \(source.path) を素材ライブラリに読み込み、タイムラインの0秒に5秒間配置してください。字幕として「字幕テストです」のテキストアイテムも0秒から5秒間配置してください。合成音声・保存・書き出しは不要です。"]
            let pipe=Pipe();process.standardOutput=pipe;process.standardError=pipe
            try process.run();let data=pipe.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
            return(process.terminationStatus,String(decoding:data,as:UTF8.self))
        }.value
        XCTAssertEqual(result.0,0,result.1)
        let events=result.1.split(separator:"\n").compactMap{try? JSONSerialization.jsonObject(with:Data($0.utf8)) as? [String:Any]}
        let initEvent=events.first{($0["event"] as? String)=="init"}?["init"] as? [String:Any]
        let expanded=initEvent?["expanded_commands"] as? [[String:Any]] ?? []
        XCTAssertTrue(expanded.contains{($0["name"] as? String)=="vmm-control"},"Installed skill was not expanded")
        let calls=events.compactMap{$0["step_update"] as? [String:Any]}.filter{($0["step_type"] as? String)=="tool" && ($0["state"] as? String)=="DONE"}.compactMap{$0["tool_name"] as? String}
        XCTAssertTrue(calls.contains{$0.contains("vmm_media_import")},"Media import was not called: \(calls)")
        let asset=try XCTUnwrap(store.project.assets.first)
        XCTAssertTrue(store.project.clips.contains{$0.kind == .image && $0.assetID == asset.id && abs($0.start)<0.01 && abs($0.duration-5)<0.01})
        XCTAssertTrue(store.project.clips.contains{$0.kind == .text && $0.text=="字幕テストです" && abs($0.start)<0.01 && abs($0.duration-5)<0.01})
    }
    @MainActor func testAntigravityReadsAndEditsIsolatedProject() async throws {
        guard let binary = ProcessInfo.processInfo.environment["VMM_AGY_CLI"] else { throw XCTSkip("Set VMM_AGY_CLI for the authenticated Antigravity integration test") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vmm-agy-\(UUID())")
        let agents = root.appendingPathComponent(".agents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let store = EditorStore(preferencesDirectory: root.appendingPathComponent("prefs"))
        let mcp = VMMControlMCP(connectionURL: root.appendingPathComponent("connection.json"))
        store.autoSpeech = false; store.project = Project()
        defer { mcp.stop(); try? FileManager.default.removeItem(at: store.directory); try? FileManager.default.removeItem(at: root) }
        let helper = try MCPTests().helperPath()
        let skill=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("skills/vmm-control")
        try FileManager.default.createDirectory(at:agents.appendingPathComponent("skills"),withIntermediateDirectories:true)
        try FileManager.default.copyItem(at:skill,to:agents.appendingPathComponent("skills/vmm-control"))
        let config: [String: Any] = ["mcpServers": ["vmm": ["command": helper.path, "args": ["--connection", mcp.connectionURL.path], "tools": ["vmm_state": ["eager": true], "vmm_capabilities": ["eager": true], "vmm_catalog": ["eager": true], "vmm_clip_add": ["eager": true]]]]]
        try JSONSerialization.data(withJSONObject: config).write(to: agents.appendingPathComponent("mcp_config.json"))
        mcp.start(store: store); XCTAssertTrue(mcp.running, mcp.status)
        let settings = #"{"permissions":{"allow":["mcp(vmm/vmm_state)","mcp(vmm/vmm_capabilities)","mcp(vmm/vmm_catalog)","mcp(vmm/vmm_clip_add)"]}}"#
        let result: (Int32, String) = try await Task.detached {
            let process = Process(); process.executableURL = URL(fileURLWithPath: binary); process.currentDirectoryURL = root
            process.arguments = ["--print-timeout", "100s", "--settings", settings, "--output-format", "stream-json", "-p", "/vmm-control テスト用VMMプロジェクトに文字 AGY_MCP_TEST のテキストアイテムを1つ追加し、結果を確認してください。保存や書き出しは不要です。"]
            let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
            try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
        XCTAssertEqual(result.0, 0, result.1)
        let events = result.1.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        let initEvent=events.first{($0["event"] as? String)=="init"}?["init"] as? [String:Any]
        let expanded=initEvent?["expanded_commands"] as? [[String:Any]] ?? []
        XCTAssertTrue(expanded.contains{($0["name"] as? String)=="vmm-control"},"The vmm-control skill was not expanded")
        let calls = events.compactMap { $0["step_update"] as? [String: Any] }.filter { ($0["step_type"] as? String) == "tool" && ($0["state"] as? String) == "DONE" }.compactMap { $0["tool_name"] as? String }
        XCTAssertTrue(calls.contains { $0.contains("vmm_state") }, "No completed state call: \(calls)")
        XCTAssertTrue(calls.contains { $0.contains("vmm_clip_add") }, "No completed clip call: \(calls)")
        XCTAssertEqual(store.project.clips.first?.text, "AGY_MCP_TEST")
    }
}
