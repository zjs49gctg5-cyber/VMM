import XCTest
import AppKit
@testable import VMM

final class TimelineTests: XCTestCase {
    @MainActor func testTrimBoundsAndUndoMove() throws {
        let store = EditorStore(); store.autoSpeech = false; store.snapping = false
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let asset = MediaAsset(name: "video", file: "video.mp4", kind: .video, duration: 10)
        var c = Clip(kind: .video, name: "video", track: 0, start: 3, duration: 4)
        c.sourceOffset = 2; c.assetID = asset.id
        store.project.assets = [asset]; store.project.clips = [c]; store.selectedID = c.id
        let left = store.timelineChange(c, delta: 1, track: 0, edge: -1)
        XCTAssertEqual(left.start, 4); XCTAssertEqual(left.duration, 3); XCTAssertEqual(left.sourceOffset, 3); XCTAssertEqual(left.end, c.end)
        let extend = store.timelineChange(c, delta: -100, track: 0, edge: -1)
        XCTAssertEqual(extend.start, 1); XCTAssertEqual(extend.sourceOffset, 0)
        let right = store.timelineChange(c, delta: 100, track: 0, edge: 1)
        XCTAssertEqual(right.duration, 8)
        let minimal = store.timelineChange(c, delta: -100, track: 0, edge: 1)
        XCTAssertEqual(minimal.duration, 1 / 30.0)
        let moved = store.timelineChange(c, delta: 2, track: 2, edge: 0)
        XCTAssertEqual(moved.start, 5); XCTAssertEqual(moved.sourceOffset, 2); XCTAssertEqual(moved.track, 2)
        store.edit(c.id) { $0 = moved }; store.undo(); XCTAssertEqual(store.project.clips, [c])
        store.project.tracks[2].locked = true
        XCTAssertEqual(store.timelineChange(c, delta: 0, track: 2, edge: 0).track, 0)
    }
    @MainActor func testLayerReorderKeepsClipsWithTheirLayerAndUndo() {
        let store = EditorStore(); store.autoSpeech = false
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let before = store.project
        let identities = before.clips.map { before.tracks[$0.track].id }
        store.moveTrack(from: 0, to: 3)
        XCTAssertEqual(store.project.tracks[3].id, before.tracks[0].id)
        XCTAssertEqual(store.project.clips.map { store.project.tracks[$0.track].id }, identities)
        store.undo(); XCTAssertEqual(store.project, before)
    }
    @MainActor func testSnapBothClipEdgesWithoutChangingDuration() {
        let store = EditorStore(); store.autoSpeech = false
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let a = Clip(kind: .text, name: "a", track: 0, start: 1, duration: 2)
        let b = Clip(kind: .text, name: "b", track: 1, start: 6, duration: 1)
        store.project.clips = [a, b]; store.selectedID = a.id
        let result = store.timelineChange(a, delta: 2.95, track: 0, edge: 0)
        XCTAssertEqual(result.end, 6); XCTAssertEqual(result.duration, 2)
        store.playhead = 2.007
        XCTAssertEqual(store.snapped(2.007), 2)
    }
    @MainActor func testGeneratedSpeechHiddenAndStyleBackwardCompatibility() throws {
        let store = EditorStore(); store.autoSpeech = false
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let hidden = MediaAsset(name: "speech", file: "speech.wav", kind: .audio, duration: 1, generatedSpeech: true)
        let music = MediaAsset(name: "music", file: "music.wav", kind: .audio, duration: 2)
        store.project.assets = [hidden, music]
        XCTAssertEqual(store.libraryAssets, [music])
        var project = Project.demo(); var style = TextStyle(); style.shadow = true; style.outlineColor = "FF0000"
        project.clips[1].textStyle = style
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project)).validated(), project)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any])
        var clips = try XCTUnwrap(json["clips"] as? [[String: Any]])
        for i in clips.indices { clips[i].removeValue(forKey: "textStyle") }; json["clips"] = clips
        let legacy = try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: json)).validated()
        XCTAssertNil(legacy.clips[1].textStyle)
        project.clips[1].textStyle?.shadowBlur = -1; XCTAssertThrowsError(try project.validated())
    }
    func testOutlineAndShadowChangeRenderedPixels() throws {
        var project = Project()
        project.width = 640; project.height = 360; project.background = "303030"
        var clip = Clip(kind: .text, name: "style", track: 0, start: 0, duration: 1)
        clip.text = "縁取りと影"; clip.fontSize = 60
        var style = TextStyle(); style.outline = false
        clip.textStyle = style; project.clips = [clip]
        func render(_ p: Project) throws -> Data {
            let context = try XCTUnwrap(CGContext(data: nil, width: 640, height: 360, bitsPerComponent: 8, bytesPerRow: 640 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            FrameRenderer().draw(project: p, directory: FileManager.default.temporaryDirectory, time: 0, context: context, size: CGSize(width: 640, height: 360))
            return Data(bytes: try XCTUnwrap(context.data), count: 640 * 360 * 4)
        }
        let plain = try render(project)
        style.outline = true; style.outlineColor = "FF0000"; style.outlineWidth = 8
        project.clips[0].textStyle = style
        let outline = try render(project)
        XCTAssertNotEqual(plain, outline)
        style.shadow = true; style.shadowX = 15; style.shadowY = 15; style.shadowBlur = 8
        project.clips[0].textStyle = style
        XCTAssertNotEqual(try render(project), outline)
    }
    @MainActor func testAutomaticSpeechDebouncesAndPersistsWithoutLibraryEntry() async throws {
        guard ProcessInfo.processInfo.environment["VMM_LIVE_VOICEVOX"] == "1" else { throw XCTSkip("Live engine required") }
        let store = EditorStore()
        defer { store.cancelSpeech(); try? FileManager.default.removeItem(at: store.directory) }
        store.project = Project(); store.voices = try await Voicevox().speakers()
        store.add(.speech)
        let id = try XCTUnwrap(store.selectedID)
        store.edit(id) { $0.text = "古い文章です。" }
        store.edit(id) { $0.text = "新しい音声です。" }
        for _ in 0..<300 where !store.generatingSpeech.isEmpty { try await Task.sleep(nanoseconds: 100_000_000) }
        let clip = try XCTUnwrap(store.selected)
        XCTAssertFalse(clip.speechDirty, store.status)
        XCTAssertEqual(clip.text, "新しい音声です。")
        XCTAssertEqual(store.project.assets.count, 1)
        XCTAssertTrue(store.libraryAssets.isEmpty)
        XCTAssertGreaterThan(clip.duration, 0)
        let asset = try XCTUnwrap(store.project.asset(for: clip))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("Media").appendingPathComponent(asset.file).path))
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("vmm-auto-test-\(UUID()).vmm")
        defer { try? FileManager.default.removeItem(at: destination) }
        store.savedURL = destination; XCTAssertTrue(store.save()); store.loadProject(destination)
        XCTAssertTrue(store.libraryAssets.isEmpty); XCTAssertFalse(store.project.clips[0].speechDirty)
    }
}
