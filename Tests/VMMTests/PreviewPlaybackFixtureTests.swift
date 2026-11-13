import XCTest
import Foundation
@testable import VMM

final class PreviewPlaybackFixtureTests: XCTestCase {
    @MainActor func testCreatePreviewFixture() async throws {
        guard let path=ProcessInfo.processInfo.environment["VMM_PREVIEW_FIXTURE_DIR"] else {throw XCTSkip("Set VMM_PREVIEW_FIXTURE_DIR to generate an isolated UI fixture")}
        let root=URL(fileURLWithPath:path),store=EditorStore(preferencesDirectory:root.appendingPathComponent("prefs"))
        defer{try? FileManager.default.removeItem(at:store.directory)}
        store.autoSpeech=false;store.project=Project();store.project.width=640;store.project.height=360;store.project.fps=24
        let ids=try await store.importURLs([root.appendingPathComponent("motion.mp4"),root.appendingPathComponent("tone.wav")])
        XCTAssertEqual(ids.count,2)
        let video=try XCTUnwrap(store.project.assets.first{$0.kind == .video}),audio=try XCTUnwrap(store.project.assets.first{$0.kind == .audio})
        var v=Clip(kind:.video,name:"Test video",track:0,start:0,duration:8);v.assetID=video.id
        var a=Clip(kind:.audio,name:"Test audio",track:1,start:0,duration:8);a.assetID=audio.id
        var t=Clip(kind:.text,name:"Test subtitle",track:2,start:0,duration:8);t.text="再生・書き出しテスト"
        store.project.clips=[v,a,t]
        let destination=root.appendingPathComponent("preview.vmm")
        guard !FileManager.default.fileExists(atPath:destination.path) else{throw VMMError.message("Fixture destination already exists")}
        try ProjectPackage.write(store.project,media:store.directory.appendingPathComponent("Media"),to:destination)
    }
}
