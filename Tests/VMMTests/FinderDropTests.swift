import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import VMM

@MainActor final class FinderDropTests:XCTestCase {
    func fixture(_ root:URL,name:String)throws->URL {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let image=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:8,pixelsHigh:8,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        let url=root.appendingPathComponent(name);try image.representation(using:.png,properties:[:])!.write(to:url);return url
    }
    func testFinderPasteboardAndSwiftUIProvidersPreserveFileOrder()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-finder-\(UUID())")
        defer{try? FileManager.default.removeItem(at:root)}
        let files=try [fixture(root,name:"日本語 image.png"),fixture(root,name:"second.png")]
        let pasteboard=NSPasteboard.withUniqueName();defer{pasteboard.releaseGlobally()}
        XCTAssertTrue(pasteboard.writeObjects(files as [NSURL]))
        XCTAssertEqual(FinderFiles.urls(pasteboard),files);XCTAssertTrue(FinderFiles.valid(files))
        XCTAssertFalse(FinderFiles.valid([root]));XCTAssertFalse(FinderFiles.valid([URL(string:"https://example.com/image.png")!]))
        let providers=files.map{url->NSItemProvider in
            let provider=NSItemProvider();provider.registerDataRepresentation(forTypeIdentifier:UTType.fileURL.identifier,visibility:.all){completion in completion(url.dataRepresentation,nil);return nil};return provider
        }
        let resolved=try await FinderFiles.resolve(providers);XCTAssertEqual(resolved,files)
    }
    func testLibraryRegistrationAndTimelinePlacementAreUndoableTransactions()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-drop-placement-\(UUID())")
        let store=EditorStore(preferencesDirectory:root);store.project.clips=[];store.autoSpeech=false
        defer{try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        let files=try [fixture(root,name:"first.png"),fixture(root,name:"second.png")]
        _=try await store.importURLs(files);XCTAssertEqual(store.libraryAssets.count,2);XCTAssertTrue(store.project.clips.isEmpty)
        store.undo();XCTAssertTrue(store.project.assets.isEmpty)
        let ids=try await store.importURLs(files,placement:MediaDropPosition(track:2,time:3))
        XCTAssertEqual(ids.count,2);XCTAssertEqual(store.project.clips.map(\.track),[2,2]);XCTAssertEqual(store.project.clips.map(\.start),[3,8])
        XCTAssertEqual(store.project.clips.map(\.assetID),ids.map{Optional($0)});XCTAssertEqual(store.selection.count,2)
        XCTAssertEqual(store.selectedTrack,2);XCTAssertEqual(store.playhead,3)
        for asset in store.project.assets {XCTAssertTrue(FileManager.default.fileExists(atPath:store.directory.appendingPathComponent("Media").appendingPathComponent(asset.file).path))}
        store.undo();XCTAssertTrue(store.project.clips.isEmpty);XCTAssertTrue(store.project.assets.isEmpty)
        store.redo();XCTAssertEqual(store.project.clips.count,2);XCTAssertEqual(store.project.assets.count,2)
    }
    func testInvalidFileAndLockedTrackDoNotPartiallyImport()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-drop-failure-\(UUID())")
        let store=EditorStore(preferencesDirectory:root);store.project.clips=[]
        defer{try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        let valid=try fixture(root,name:"valid.png"),invalid=root.appendingPathComponent("broken.png");try Data("invalid".utf8).write(to:invalid)
        let before=store.project,media=store.directory.appendingPathComponent("Media")
        do{_=try await store.importURLs([valid,invalid],placement:MediaDropPosition(track:1,time:2));XCTFail("Invalid file accepted")}catch{}
        XCTAssertEqual(store.project,before);XCTAssertFalse(store.busy);XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:media.path).isEmpty)
        store.project.tracks[1].locked=true
        XCTAssertFalse(store.acceptFinderDrop([valid],at:MediaDropPosition(track:1,time:2)))
        do{_=try await store.importURLs([valid],placement:MediaDropPosition(track:1,time:2));XCTFail("Locked track accepted")}catch{}
        XCTAssertTrue(store.project.assets.isEmpty);XCTAssertFalse(store.canUndo)
    }
}
