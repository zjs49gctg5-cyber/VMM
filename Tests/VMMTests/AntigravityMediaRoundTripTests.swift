import XCTest
import Foundation
@testable import VMM

final class AntigravityMediaRoundTripTests: XCTestCase {
    @MainActor func testVideoAudioPlacementThenSaveAndReopen() async throws {
        let env=ProcessInfo.processInfo.environment
        guard let agy=env["VMM_AGY_CLI"],let ffmpeg=env["VMM_TEST_FFMPEG"] else {throw XCTSkip("Set VMM_AGY_CLI and VMM_TEST_FFMPEG for this authenticated integration test")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-agy-roundtrip-\(UUID())")
        let agents=root.appendingPathComponent(".agents")
        try FileManager.default.createDirectory(at:agents,withIntermediateDirectories:true)
        let store=EditorStore(preferencesDirectory:root.appendingPathComponent("prefs"))
        let mcp=VMMControlMCP(connectionURL:root.appendingPathComponent("connection.json"))
        store.autoSpeech=false;store.project=Project()
        defer{mcp.stop();try? FileManager.default.removeItem(at:store.directory);try? FileManager.default.removeItem(at:root)}
        let video=root.appendingPathComponent("test-video.mp4"),audio=root.appendingPathComponent("test-audio.wav"),package=root.appendingPathComponent("roundtrip.vmm")
        func makeFixture(_ arguments:[String]) throws {
            let process=Process();process.executableURL=URL(fileURLWithPath:ffmpeg);process.arguments=["-hide_banner","-loglevel","error","-nostdin"]+arguments
            let output=Pipe();process.standardOutput=output;process.standardError=output
            try process.run();let data=output.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus,0,String(decoding:data,as:UTF8.self))
        }
        try makeFixture(["-f","lavfi","-i","testsrc2=size=160x90:rate=12:duration=3","-c:v","mpeg4","-pix_fmt","yuv420p",video.path])
        try makeFixture(["-f","lavfi","-i","sine=frequency=440:sample_rate=48000:duration=3","-c:a","pcm_s16le",audio.path])
        let helper=try MCPTests().helperPath()
        let exposed=["vmm_state","vmm_capabilities","vmm_catalog","vmm_media_import","vmm_job","vmm_clip_add","vmm_project_save","vmm_project_open"]
        let config:[String:Any]=["mcpServers":["vmm":["command":helper.path,"args":["--connection",mcp.connectionURL.path],"tools":Dictionary(uniqueKeysWithValues:exposed.map{($0,["eager":true])})]]]
        try JSONSerialization.data(withJSONObject:config).write(to:agents.appendingPathComponent("mcp_config.json"))
        mcp.start(store:store);XCTAssertTrue(mcp.running,mcp.status)
        let settingsData=try JSONSerialization.data(withJSONObject:["permissions":["allow":exposed.map{"mcp(vmm/\($0))"}]])
        let settings=try XCTUnwrap(String(data:settingsData,encoding:.utf8))
        let prompt="""
        /vmm-control これは一時テスト用プロジェクトです。動画 \(video.path) と音声 \(audio.path) を読み込み、動画と音声を別レイヤーに0秒から2秒ずつ配置し、字幕「保存の確認」も0秒から2秒配置してください。生成音声は不要です。まず配置を確認し、その後 \(package.path) にプロジェクトを保存して保存完了を確認し、同じプロジェクトを読み込み直し、動画・音声・字幕が残っているか確認してください。動画の書き出しは不要です。
        """
        let result:(Int32,String)=try await Task.detached {
            let process=Process();process.executableURL=URL(fileURLWithPath:agy);process.currentDirectoryURL=root
            process.arguments=["--print-timeout","300s","--settings",settings,"--output-format","stream-json","-p",prompt]
            let output=Pipe();process.standardOutput=output;process.standardError=output
            try process.run();let data=output.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
            return(process.terminationStatus,String(decoding:data,as:UTF8.self))
        }.value
        XCTAssertEqual(result.0,0,result.1)
        let events=result.1.split(separator:"\n").compactMap{try? JSONSerialization.jsonObject(with:Data($0.utf8)) as? [String:Any]}
        let initEvent=events.first{($0["event"] as? String)=="init"}?["init"] as? [String:Any]
        XCTAssertTrue((initEvent?["expanded_commands"] as? [[String:Any]] ?? []).contains{($0["name"] as? String)=="vmm-control"})
        let calls=events.compactMap{$0["step_update"] as? [String:Any]}.filter{($0["step_type"] as? String)=="tool" && ($0["state"] as? String)=="DONE"}.compactMap{$0["tool_name"] as? String}
        for name in ["vmm_media_import","vmm_clip_add","vmm_project_save","vmm_project_open"] {XCTAssertTrue(calls.contains{$0.contains(name)},"Missing \(name): \(calls)")}
        let importedVideo=try XCTUnwrap(store.project.assets.first{$0.kind == .video})
        let importedAudio=try XCTUnwrap(store.project.assets.first{$0.kind == .audio})
        let videoClip=try XCTUnwrap(store.project.clips.first{$0.kind == .video && $0.assetID==importedVideo.id})
        let audioClip=try XCTUnwrap(store.project.clips.first{$0.kind == .audio && $0.assetID==importedAudio.id})
        let caption=try XCTUnwrap(store.project.clips.first{$0.kind == .text && $0.text=="保存の確認"})
        for clip in [videoClip,audioClip,caption] {XCTAssertEqual(clip.start,0,accuracy:0.01);XCTAssertEqual(clip.duration,2,accuracy:0.01)}
        XCTAssertNotEqual(videoClip.track,audioClip.track)
        XCTAssertTrue(FileManager.default.fileExists(atPath:package.path))
        XCTAssertEqual(store.savedURL?.standardizedFileURL,package.standardizedFileURL)
        let saved=try ProjectIO.read(package);defer{try? FileManager.default.removeItem(at:saved.1)}
        XCTAssertEqual(saved.0,store.project,"Reopened project must match the saved project")
        for asset in [importedVideo,importedAudio] {XCTAssertTrue(FileManager.default.fileExists(atPath:store.directory.appendingPathComponent("Media").appendingPathComponent(asset.file).path))}
    }
}
