import XCTest
import AppKit
@testable import VMM

final class TextRenderingTests: XCTestCase {
    func project() -> Project {
        var p = Project(); p.width = 640; p.height = 360; p.background = "FFFFFF"
        var c = Clip(kind: .text, name: "文字装飾の確認", track: 0, start: 0, duration: 2)
        c.text = "文字色と縁取り\nGradient TEXT"; c.fontSize = 54; c.color = "FF3300"
        var style = TextStyle(); style.outlineWidth = 10; style.outlineColor = "0044FF"
        c.textStyle = style; p.clips = [c]; return p
    }
    func render(_ p: Project) throws -> CGContext {
        let context = try XCTUnwrap(CGContext(data: nil, width: p.width, height: p.height, bitsPerComponent: 8, bytesPerRow: p.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        FrameRenderer().draw(project: p, directory: FileManager.default.temporaryDirectory, time: 0, context: context, size: CGSize(width: p.width, height: p.height))
        return context
    }
    func bytes(_ p: Project) throws -> [UInt8] {
        let context = try render(p)
        return Array(UnsafeBufferPointer(start: try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self), count: p.width * p.height * 4))
    }
    func testShadowCannotCoverForegroundGlyphs() throws {
        var p = project(); p.clips[0].color = "FFFFFF"; p.background = "303030"
        let plain = try bytes(p)
        p.clips[0].textStyle?.shadow = true; p.clips[0].textStyle?.shadowX = -24
        p.clips[0].textStyle?.shadowY = 20; p.clips[0].textStyle?.shadowBlur = 15
        let shadow = try bytes(p)
        var opaqueWhite = 0
        for i in stride(from: 0, to: plain.count, by: 4) where plain[i] == 255 && plain[i+1] == 255 && plain[i+2] == 255 {
            opaqueWhite += 1
            XCTAssertEqual(Array(shadow[i..<i+3]), [255, 255, 255])
        }
        XCTAssertGreaterThan(opaqueWhite, 500)
        XCTAssertNotEqual(plain, shadow)
    }
    func testPositiveShadowOffsetAppearsBelowText() throws {
        var p = project(); let plain = try bytes(p)
        p.clips[0].textStyle?.shadow = true; p.clips[0].textStyle?.shadowY = 24
        p.clips[0].textStyle?.shadowX = 0; p.clips[0].textStyle?.shadowBlur = 0
        let shadow = try bytes(p)
        var glyphY = 0.0, glyphCount = 0.0, shadowY = 0.0, shadowCount = 0.0
        for i in stride(from: 0, to: plain.count, by: 4) {
            let y = Double(i / 4 / p.width)
            if plain[i] < 250 || plain[i+1] < 250 || plain[i+2] < 250 { glyphY += y; glyphCount += 1 }
            else if shadow[i] < 200 && shadow[i+1] < 200 && shadow[i+2] < 200 { shadowY += y; shadowCount += 1 }
        }
        XCTAssertGreaterThan(shadowCount, 100)
        XCTAssertGreaterThan(shadowY / shadowCount, glyphY / glyphCount + 10)
    }
    func testIndependentGradientsAndLegacyStyleDecoding() throws {
        var p = project(); let solid = try bytes(p)
        p.clips[0].textStyle?.fillGradient = TextGradient(enabled: true, endColor: "FFDD00", angle: 90)
        let fill = try bytes(p); XCTAssertNotEqual(fill, solid)
        p.clips[0].textStyle?.outlineGradient = TextGradient(enabled: true, endColor: "00DDEE", angle: 90)
        let outline = try bytes(p); XCTAssertNotEqual(outline, fill)
        p.clips[0].textStyle?.shadow = true; p.clips[0].textStyle?.shadowY = 16
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(p)).validated(), p)
        let legacy = Data("{\"outline\":true,\"outlineColor\":\"000000\",\"outlineWidth\":3,\"shadow\":false,\"shadowColor\":\"000000\",\"shadowOpacity\":0.7,\"shadowBlur\":4,\"shadowX\":4,\"shadowY\":4}".utf8)
        XCTAssertNil(try JSONDecoder().decode(TextStyle.self, from: legacy).fillGradient)
        if let folder = testArtifactDirectory() {
            let root = URL(fileURLWithPath: folder)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let image = try XCTUnwrap(try render(p).makeImage())
            try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])).write(to: root.appendingPathComponent("text-gradient.png"))
            let package = root.appendingPathComponent("Text-Style.vmm")
            try FileManager.default.createDirectory(at: package.appendingPathComponent("Media"), withIntermediateDirectories: true)
            try JSONEncoder().encode(p).write(to: package.appendingPathComponent("project.json"))
        }
    }
}
