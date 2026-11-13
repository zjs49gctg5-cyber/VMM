import XCTest
import AppKit
import AVFoundation
@testable import VMM

final class TimeWarpVideoTests: XCTestCase {
    func testReverseVariableSpeedPreviewAndMP4() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vmm-video-warp-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Media"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var source = Project(); source.width = 320; source.height = 180; source.fps = 30
        for (i, color) in ["EE2222", "22EE22", "2222EE", "EEEE22"].enumerated() {
            var shape = Clip(kind: .shape, name: color, track: 0, start: Double(i) * 0.5, duration: 0.5)
            shape.color = color; source.clips.append(shape)
        }
        let input = root.appendingPathComponent("Media/input.mp4")
        try await MovieExporter.export(project: source, directory: root, destination: input) { _ in }
        var p = Project(); p.width = 320; p.height = 180; p.fps = 30
        let asset = MediaAsset(name: "input", file: "input.mp4", kind: .video, duration: 2)
        var clip = Clip(kind: .video, name: "reverse", track: 0, start: 0, duration: 1)
        clip.assetID = asset.id; clip.audioDisabled = true; clip.reversed = true
        clip.speedPoints = [.init(time: 0, rate: 0.5), .init(time: 1, rate: 1.5)]
        p.assets = [asset]; p.clips = [clip]
        let output = root.appendingPathComponent("output.mp4")
        try await MovieExporter.export(project: p, directory: root, destination: output) { _ in }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let renderer = FrameRenderer()
        for time in [0.0, 0.3, 0.8] {
            let context = try XCTUnwrap(RasterTools.bitmap(CGSize(width: 320, height: 180)))
            renderer.draw(project: p, directory: root, time: time, context: context, size: CGSize(width: 320, height: 180))
            let preview = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
            let exported = NSBitmapImageRep(cgImage: try generator.copyCGImage(at: CMTime(seconds: time, preferredTimescale: 600), actualTime: nil))
            let a = try XCTUnwrap(preview.colorAt(x: 160, y: 90)?.usingColorSpace(.sRGB))
            let b = try XCTUnwrap(exported.colorAt(x: 160, y: 90)?.usingColorSpace(.sRGB))
            XCTAssertEqual(a.redComponent, b.redComponent, accuracy: 0.12)
            XCTAssertEqual(a.greenComponent, b.greenComponent, accuracy: 0.12)
            XCTAssertEqual(a.blueComponent, b.blueComponent, accuracy: 0.12)
            if time == 0 { XCTAssertGreaterThan(a.greenComponent, 0.7); XCTAssertLessThan(a.redComponent, 0.3) }
            if time == 0.8 { XCTAssertGreaterThan(a.redComponent, 0.7); XCTAssertLessThan(a.greenComponent, 0.3) }
        }
    }
}
