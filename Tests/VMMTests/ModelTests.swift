import XCTest
@testable import VMM

final class ModelTests: XCTestCase {
    func testProjectRoundTripAndLayerOrder() throws {
        let project = Project.demo()
        let loaded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project)).validated()
        XCTAssertEqual(project, loaded)
        XCTAssertEqual(loaded.duration, 8)
        XCTAssertEqual(loaded.visibleClips(at: 4).map(\.name), ["アクセント", "編集をはじめよう"])
        XCTAssertTrue(loaded.visibleClips(at: 8).isEmpty)
    }
    func testRejectTraversalAndNonFiniteClip() throws {
        var project = Project.demo()
        project.assets = [.init(name: "bad", file: "../private.wav", kind: .audio, duration: 1)]
        XCTAssertThrowsError(try project.validated())
        project.assets = []
        project.clips[0].duration = .infinity
        XCTAssertThrowsError(try project.validated())
    }
    func testVisibilityAndTimecode() {
        var project = Project.demo()
        project.tracks[1].visible = false
        XCTAssertEqual(project.visibleClips(at: 1).count, 2)
        XCTAssertEqual(timecode(3661.5, fps: 30), "01:01:01:15")
    }
    func testMouthFollowsMatchingUnmutedSpeechAndSourceOffset() {
        var project = Project()
        let asset = MediaAsset(name: "voice", file: "voice.wav", kind: .audio, duration: 1, envelope: [0, 0.2, 0, 0.1])
        project.assets = [asset]
        var speech = Clip(kind: .speech, name: "voice", track: 1, start: 1, duration: 1)
        speech.assetID = asset.id; speech.speakerID = 3
        project.clips = [speech]
        var character = Clip(kind: .image, name: "character", track: 0, start: 0, duration: 3)
        character.characterSpeakerID = 3
        XCTAssertFalse(project.mouthIsOpen(for: character, at: 0.5))
        XCTAssertFalse(project.mouthIsOpen(for: character, at: 1))
        XCTAssertTrue(project.mouthIsOpen(for: character, at: 1.05))
        project.clips[0].sourceOffset = 1 / 30
        XCTAssertTrue(project.mouthIsOpen(for: character, at: 1))
        project.tracks[1].muted = true
        XCTAssertFalse(project.mouthIsOpen(for: character, at: 1.05))
    }
}
