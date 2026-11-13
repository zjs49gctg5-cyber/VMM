import XCTest
import AppKit
@testable import VMM

@MainActor final class MediaImportButtonTests:XCTestCase {
    func testPickerImportIsAtomicAndReportsFailure() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-picker-import-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let store=EditorStore(preferencesDirectory:root);store.autoSpeech=false
        defer{try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        let image=try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:8,pixelsHigh:8,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
        let good=root.appendingPathComponent("good.png"),bad=root.appendingPathComponent("bad.png")
        try XCTUnwrap(image.representation(using:.png,properties:[:])).write(to:good);try Data("invalid".utf8).write(to:bad)
        let before=store.project,media=store.directory.appendingPathComponent("Media")
        await store.importMediaURLs([good,bad])
        XCTAssertEqual(store.project,before);XCTAssertNotNil(store.error);XCTAssertFalse(store.busy)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:media.path).isEmpty)
        XCTAssertFalse(store.canUndo)
        store.error=nil
        await store.importMediaURLs([good])
        XCTAssertNil(store.error);XCTAssertEqual(store.libraryAssets.map(\.name),["good.png"])
        XCTAssertEqual(store.project.clips,before.clips);XCTAssertTrue(store.canUndo)
        XCTAssertTrue(store.status.contains("1個"));store.undo();XCTAssertEqual(store.project,before)
    }
}
