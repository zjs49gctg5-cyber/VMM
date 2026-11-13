import XCTest
import Foundation
@testable import VMM

final class GeminiMCPIntegrationTests:XCTestCase {
    @MainActor func testGeminiDiscoversVMMAndSkill() async throws {
        guard let binary=ProcessInfo.processInfo.environment["VMM_GEMINI_CLI"] else {throw XCTSkip("Set VMM_GEMINI_CLI to the Gemini executable")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-gemini-\(UUID())")
        let config=root.appendingPathComponent(".gemini"),skills=config.appendingPathComponent("skills")
        try FileManager.default.createDirectory(at:skills,withIntermediateDirectories:true)
        let store=EditorStore(preferencesDirectory:root.appendingPathComponent("prefs"))
        let mcp=VMMControlMCP(connectionURL:root.appendingPathComponent("connection.json"))
        store.autoSpeech=false;store.project=Project()
        defer{mcp.stop();try? FileManager.default.removeItem(at:store.directory);try? FileManager.default.removeItem(at:root)}
        let helper=try MCPTests().helperPath()
        let configuration:[String:Any]=["security":["folderTrust":["enabled":false]],"mcpServers":["vmm":["command":helper.path,"args":["--connection",mcp.connectionURL.path]]]]
        try JSONSerialization.data(withJSONObject:configuration).write(to:config.appendingPathComponent("settings.json"))
        try FileManager.default.copyItem(at:URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("skills/vmm-control"),to:skills.appendingPathComponent("vmm-control"))
        mcp.start(store:store);XCTAssertTrue(mcp.running,mcp.status)
        func run(_ arguments:[String]) async throws -> String {
            try await Task.detached {
                let process=Process();process.executableURL=URL(fileURLWithPath:binary);process.arguments=arguments;process.currentDirectoryURL=root
                var env=ProcessInfo.processInfo.environment;env["GEMINI_CLI_HOME"]=root.path;env["NO_COLOR"]="1";process.environment=env
                let output=Pipe();process.standardOutput=output;process.standardError=output
                try process.run();let data=output.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
                let text=String(decoding:data,as:UTF8.self);XCTAssertEqual(process.terminationStatus,0,text);return text
            }.value
        }
        let list=try await run(["mcp","list"])
        XCTAssertTrue(list.lowercased().contains("vmm"),list)
        XCTAssertTrue(list.contains(" - Connected"),list)
        let skill=try await run(["skills","list"])
        XCTAssertTrue(skill.contains("vmm-control"),skill)
        XCTAssertTrue(store.project.clips.isEmpty)
    }
}
