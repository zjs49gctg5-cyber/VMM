import XCTest
import AVFoundation
import AppKit
@testable import VMM

final class LibraryPreviewRegressionTests:XCTestCase {
    @MainActor func testHoverIsMutedBoundedAndCancelledWhenLeavingOrSwitching()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-hover-\(UUID())")
        try FileManager.default.createDirectory(at:root.appendingPathComponent("Media"),withIntermediateDirectories:true)
        let preview=LibraryHoverPreview()
        defer{preview.stop();try? FileManager.default.removeItem(at:root)}
        var project=Project();project.width=320;project.height=180
        project.clips=[Clip(kind:.text,name:"preview",track:0,start:0,duration:2)]
        try await MovieExporter.export(project:project,directory:root,destination:root.appendingPathComponent("Media/video.mp4")){_ in}
        let first=MediaAsset(name:"first",file:"video.mp4",kind:.video,duration:2)
        let second=MediaAsset(name:"second",file:"video.mp4",kind:.video,duration:2)
        preview.enter(first,directory:root,delay:0.2);preview.exit(first.id)
        try await Task.sleep(nanoseconds:300_000_000)
        XCTAssertNil(preview.player)
        preview.enter(first,directory:root,seconds:1,delay:0)
        for _ in 0..<50 {if (preview.player?.currentTime().seconds ?? 0)>0.1{break};try await Task.sleep(nanoseconds:100_000_000)}
        let old=try XCTUnwrap(preview.player)
        XCTAssertTrue(old.isMuted);XCTAssertGreaterThan(old.currentTime().seconds,0.1)
        XCTAssertEqual(old.currentItem?.forwardPlaybackEndTime.seconds ?? 0,1,accuracy:0.01)
        preview.enter(second,directory:root,seconds:1,delay:0)
        for _ in 0..<20 {if preview.assetID==second.id{break};try await Task.sleep(nanoseconds:50_000_000)}
        XCTAssertNil(old.currentItem);XCTAssertEqual(preview.assetID,second.id)
        for _ in 0..<60 {if preview.player==nil{break};try await Task.sleep(nanoseconds:100_000_000)}
        XCTAssertNil(preview.player)
        preview.enter(second,directory:root,delay:0)
        try await Task.sleep(nanoseconds:100_000_000)
        XCTAssertNil(preview.player,"A completed hover must wait for pointer exit before restarting")
        preview.exit(second.id);preview.enter(second,directory:root,delay:0)
        try await Task.sleep(nanoseconds:100_000_000)
        XCTAssertEqual(preview.assetID,second.id)
        preview.stop();XCTAssertNil(preview.player)
    }
    @MainActor func testThumbnailRecoversAfterMissingFileAndCacheClear()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-thumbnail-retry-\(UUID())")
        try FileManager.default.createDirectory(at:root.appendingPathComponent("Media"),withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let cache=TimelineMediaCache(),asset=MediaAsset(name:"image",file:"image.png",kind:.image,duration:1)
        let failed=expectation(description:"missing file attempted")
        XCTAssertNil(cache.thumbnail(asset:asset,directory:root,time:0,limitMB:16,onReady:{failed.fulfill()}))
        await fulfillment(of:[failed],timeout:5)
        let context=try XCTUnwrap(RasterTools.bitmap(CGSize(width:64,height:64)))
        context.setFillColor(NSColor.green.cgColor);context.fill(CGRect(x:0,y:0,width:64,height:64))
        let rep=NSBitmapImageRep(cgImage:try XCTUnwrap(context.makeImage()))
        try XCTUnwrap(rep.representation(using:.png,properties:[:])).write(to:root.appendingPathComponent("Media/image.png"))
        let recovered=expectation(description:"file restoration retries immediately")
        _=cache.thumbnail(asset:asset,directory:root,time:0,limitMB:16,onReady:{recovered.fulfill()})
        await fulfillment(of:[recovered],timeout:5)
        XCTAssertNotNil(cache.thumbnail(asset:asset,directory:root,time:0,limitMB:16,onReady:{}))
        cache.clear()
        let reload=expectation(description:"cleared cache regenerates")
        _=cache.thumbnail(asset:asset,directory:root,time:0,limitMB:16,onReady:{reload.fulfill()})
        await fulfillment(of:[reload],timeout:5)
        XCTAssertNotNil(cache.thumbnail(asset:asset,directory:root,time:0,limitMB:16,onReady:{}))
    }
    @MainActor func testLibraryPreferencesPersistAndValidate()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-library-settings-\(UUID())")
        let store=EditorStore(preferencesDirectory:root)
        defer{try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        let api=EditorCommands();api.store=store
        XCTAssertEqual(try CommandTests().command(api,["command":"settings.update","properties":["libraryHoverPreview":false,"libraryHoverSeconds":5,"libraryThumbnails":false]]).status,200)
        store.setLibraryThumbnails(true)
        let saved=try JSONDecoder().decode(UserSettings.self,from:Data(contentsOf:root.appendingPathComponent("settings.json")))
        XCTAssertEqual(saved.libraryThumbnails,true);XCTAssertEqual(saved.libraryHoverPreview,false);XCTAssertEqual(saved.libraryHoverSeconds,5)
        XCTAssertEqual(try CommandTests().command(api,["command":"settings.update","properties":["libraryHoverSeconds":0]]).status,400)
        XCTAssertEqual(store.settings.libraryHoverSeconds,5)
    }
}
