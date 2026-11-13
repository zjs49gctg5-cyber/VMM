import XCTest
import Foundation
import AVFoundation
@testable import VMM

final class AntigravityVoicevoxTests: XCTestCase {
    @MainActor func testLiveVoicevoxGenerationAndExport() async throws {
        let env=ProcessInfo.processInfo.environment
        guard let agy=env["VMM_AGY_CLI"],env["VMM_LIVE_VOICEVOX"]=="1" else {throw XCTSkip("Set VMM_AGY_CLI and VMM_LIVE_VOICEVOX=1 for live integration")}
        let voices=try await Voicevox().speakers()
        let voice=try XCTUnwrap(voices.first)
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-agy-voice-\(UUID())"),agents=root.appendingPathComponent(".agents")
        try FileManager.default.createDirectory(at:agents,withIntermediateDirectories:true)
        let store=EditorStore(preferencesDirectory:root.appendingPathComponent("prefs")),mcp=VMMControlMCP(connectionURL:root.appendingPathComponent("connection.json"))
        store.autoSpeech=false;store.project=Project();store.project.width=320;store.project.height=180;store.project.fps=24
        defer{mcp.stop();try? FileManager.default.removeItem(at:store.directory);try? FileManager.default.removeItem(at:root)}
        let output=root.appendingPathComponent("voice-test.mp4"),helper=try MCPTests().helperPath()
        let exposed=["vmm_state","vmm_capabilities","vmm_catalog","vmm_voice_connect","vmm_clip_add","vmm_speech_generate","vmm_job","vmm_export_preflight","vmm_export_start"]
        let config:[String:Any]=["mcpServers":["vmm":["command":helper.path,"args":["--connection",mcp.connectionURL.path],"tools":Dictionary(uniqueKeysWithValues:exposed.map{($0,["eager":true])})]]]
        try JSONSerialization.data(withJSONObject:config).write(to:agents.appendingPathComponent("mcp_config.json"))
        mcp.start(store:store);XCTAssertTrue(mcp.running,mcp.status)
        let settings=try XCTUnwrap(String(data:try JSONSerialization.data(withJSONObject:["permissions":["allow":exposed.map{"mcp(vmm/\($0))"}]]),encoding:.utf8))
        let prompt="""
        /vmm-control これは隔離されたテスト用プロジェクトです。VOICEVOXに接続し、話者ID \(voice.id) のセリフ「これは音声と動画出力の動作確認です。」を0秒に配置して、音声を生成してください。生成の完了・失敗を状態で確認してから書き出し前チェックを行い、\(output.path) に動画を出力してジョブの完了まで確認してください。既存ファイルの上書きは不要です。
        """
        let result:(Int32,String)=try await Task.detached {
            let process=Process();process.executableURL=URL(fileURLWithPath:agy);process.currentDirectoryURL=root
            process.arguments=["--print-timeout","360s","--settings",settings,"--output-format","stream-json","-p",prompt]
            let pipe=Pipe();process.standardOutput=pipe;process.standardError=pipe
            try process.run();let data=pipe.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
            return(process.terminationStatus,String(decoding:data,as:UTF8.self))
        }.value
        XCTAssertEqual(result.0,0,result.1)
        let events=result.1.split(separator:"\n").compactMap{try? JSONSerialization.jsonObject(with:Data($0.utf8)) as? [String:Any]}
        let calls=events.compactMap{$0["step_update"] as? [String:Any]}.filter{($0["step_type"] as? String)=="tool" && ($0["state"] as? String)=="DONE"}.compactMap{$0["tool_name"] as? String}
        for name in ["vmm_voice_connect","vmm_clip_add","vmm_speech_generate","vmm_export_preflight","vmm_export_start","vmm_job"] {XCTAssertTrue(calls.contains{$0.contains(name)},"Missing \(name): \(calls)")}
        let speech=try XCTUnwrap(store.project.clips.first{$0.kind == .speech})
        XCTAssertEqual(speech.text,"これは音声と動画出力の動作確認です。");XCTAssertEqual(speech.speakerID,voice.id);XCTAssertFalse(speech.speechDirty)
        let id=try XCTUnwrap(speech.assetID),asset=try XCTUnwrap(store.project.assets.first{$0.id==id})
        XCTAssertEqual(asset.generatedSpeech,true)
        let generated=store.directory.appendingPathComponent("Media").appendingPathComponent(asset.file)
        let duration=try await AVURLAsset(url:generated).load(.duration).seconds
        XCTAssertGreaterThan(duration,0.2)
        XCTAssertTrue(FileManager.default.fileExists(atPath:output.path),"Export missing; state=\(store.status), error=\(store.error ?? "none")")
        let audioTracks=try await AVURLAsset(url:output).loadTracks(withMediaType:.audio)
        XCTAssertEqual(audioTracks.count,1)
        let decoded=root.appendingPathComponent("decoded.caf")
        let didDecode=try await AudioProcessor.decode(source:output,destination:decoded)
        XCTAssertTrue(didDecode)
        XCTAssertGreaterThan(try LoudnessAnalyzer.analyze(decoded).samplePeak,0.001)
    }
}
