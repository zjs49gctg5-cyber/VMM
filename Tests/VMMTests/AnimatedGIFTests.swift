import XCTest
import AppKit
import ImageIO
import AVFoundation
@testable import VMM

final class AnimatedGIFTests: XCTestCase {
    func fixture(loop: Int? = 0) throws -> URL {
        let root = try AdvancedTests().folder()
        let url = root.appendingPathComponent("Media/animation.gif")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, 2, nil))
        if let loop { CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loop]] as CFDictionary) }
        for color in [NSColor.red, NSColor.blue] {
            let context = try XCTUnwrap(RasterTools.bitmap(CGSize(width: 64, height: 64)))
            context.setFillColor(color.cgColor); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.5]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return root
    }
    func pixel(_ context: CGContext) throws -> [UInt8] {
        context.flush(); let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: data + 32 * context.bytesPerRow + 32 * 4, count: 4))
    }
    func project() -> Project {
        var project = Project(); project.width = 64; project.height = 64
        let asset = MediaAsset(name: "animation", file: "animation.gif", kind: .image, duration: 5)
        var clip = Clip(kind: .image, name: "animation", track: 0, start: 0, duration: 2); clip.assetID = asset.id
        project.assets = [asset]; project.clips = [clip]; return project
    }
    func testFramesAdvanceLoopAndSeekWithStaticCachesEnabled() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let sequence = try XCTUnwrap(AnimatedGIF(url: root.appendingPathComponent("Media/animation.gif")))
        XCTAssertEqual([0.1, 0.6, 1.1].map { sequence.frameIndex(at: $0) }, [0, 1, 0])
        let renderer = FrameRenderer(), project = project()
        func frame(_ time: Double) throws -> [UInt8] {
            let context = try XCTUnwrap(RasterTools.bitmap(CGSize(width: 64, height: 64)))
            renderer.draw(project: project, directory: root, time: time, context: context, size: CGSize(width: 64, height: 64))
            return try pixel(context)
        }
        let red = try frame(0.1), blue = try frame(0.6)
        XCTAssertGreaterThan(red[0], red[2]); XCTAssertGreaterThan(blue[2], blue[0]); XCTAssertEqual(try frame(1.1), red)
    }
    func testMP4ContainsBothFrames() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("animation.mp4")
        try await MovieExporter.export(project: project(), directory: root, destination: output) { _ in }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        func frame(_ time: Double) throws -> [UInt8] {
            let image = try generator.copyCGImage(at: CMTime(seconds: time, preferredTimescale: 600), actualTime: nil)
            let context = try XCTUnwrap(RasterTools.bitmap(CGSize(width: 64, height: 64)))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64)); return try pixel(context)
        }
        let red = try frame(0.2), blue = try frame(0.7)
        XCTAssertGreaterThan(Int(red[0]) - Int(red[2]), 100)
        XCTAssertGreaterThan(Int(blue[2]) - Int(blue[0]), 100)
    }
    @MainActor func testLeftTrimPreservesGIFTime() throws {
        let store = EditorStore(); defer { try? FileManager.default.removeItem(at: store.directory) }
        store.project = project(); store.snapping = false
        let clip = store.project.clips[0], trimmed = store.timelineChange(clip, delta: 0.5, track: 0, edge: -1)
        XCTAssertEqual(trimmed.sourceOffset, 0.5, accuracy: 0.001)
        XCTAssertEqual(trimmed.sourceTime(at: 0.6), clip.sourceTime(at: 0.6), accuracy: 0.001)
    }
    func testGIFPartialFrameCompositing() throws {
        let root = try AdvancedTests().folder(); defer { try? FileManager.default.removeItem(at: root) }
        let gif = try XCTUnwrap(Data(base64Encoded: "R0lGODlhAgACAIEAAAAAAP8AAAAA/////yH5BAQyAAAALAAAAAACAAIAAAIEDMMwBQAh+QQFMgAAACwAAAAAAgACAAACBBRBEAUAOw=="))
        let url = root.appendingPathComponent("Media/animation.gif"); try gif.write(to: url)
        let sequence = try XCTUnwrap(AnimatedGIF(url: url))
        let frame = try XCTUnwrap(sequence.image(at: 1)), image = try XCTUnwrap(frame.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let context = try XCTUnwrap(RasterTools.bitmap(CGSize(width: 2, height: 2)))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 2, height: 2)); context.flush()
        let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        // Three pixels must retain the first frame's red background.
        let reds = (0..<4).filter { data[$0 * 4] > 200 && data[$0 * 4 + 2] < 30 }.count
        XCTAssertEqual(reds, 3)
    }
    func testFiniteAndAbsentLoopCountsHoldLastFrame() throws {
        let single = try AdvancedTests().folder(), repeated = try AdvancedTests().folder()
        defer { try? FileManager.default.removeItem(at: single); try? FileManager.default.removeItem(at: repeated) }
        let unlooped = try XCTUnwrap(Data(base64Encoded: "R0lGODlhAgACAIEAAAAAAP8AAAAA/////yH5BAQyAAAALAAAAAACAAIAAAIEDMMwBQAh+QQFMgAAACwAAAAAAgACAAACBBRBEAUAOw=="))
        try unlooped.write(to: single.appendingPathComponent("Media/animation.gif"))
        var looped = unlooped
        looped.insert(contentsOf: [0x21, 0xff, 0x0b] + Array("NETSCAPE2.0".utf8) + [0x03, 0x01, 0x01, 0x00, 0x00], at: 25)
        try looped.write(to: repeated.appendingPathComponent("Media/animation.gif"))
        let once = try XCTUnwrap(AnimatedGIF(url: single.appendingPathComponent("Media/animation.gif")))
        let twice = try XCTUnwrap(AnimatedGIF(url: repeated.appendingPathComponent("Media/animation.gif")))
        XCTAssertNil(once.loopCount)
        XCTAssertEqual(once.frameIndex(at: 1.1), 1)
        XCTAssertEqual(twice.loopCount, 1)
        XCTAssertEqual(twice.frameIndex(at: 1.1), 0)
        XCTAssertEqual(twice.frameIndex(at: 2.1), 1)
    }
}
