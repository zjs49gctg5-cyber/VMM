import XCTest
import AppKit
@testable import VMM

final class TimelineThumbnailContinuityTests:XCTestCase {
    func testThumbnailLayoutPreservesLandscapeAndPortraitProportions() {
        let cell=CGRect(x:20,y:10,width:120,height:60)
        let landscape=TimelineThumbnailLayout.imageRect(size:CGSize(width:160,height:90),in:cell)
        XCTAssertEqual(landscape.width/landscape.height,160.0/90.0,accuracy:0.0001)
        XCTAssertEqual(landscape.midX,cell.midX,accuracy:0.0001)
        XCTAssertEqual(TimelineThumbnailLayout.imageRect(size:CGSize(width:90,height:160),in:cell),CGRect(x:63.125,y:10,width:33.75,height:60))
        XCTAssertEqual(TimelineThumbnailLayout.imageRect(size:.zero,in:cell),.zero)
    }
    @MainActor func testTimelineReceivesCompletionForAlreadyPendingThumbnail()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-thumbnail-waiters-\(UUID())")
        let media=root.appendingPathComponent("Media")
        try FileManager.default.createDirectory(at:media,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let context=try XCTUnwrap(RasterTools.bitmap(CGSize(width:64,height:64)))
        context.setFillColor(NSColor.green.cgColor);context.fill(CGRect(x:0,y:0,width:64,height:64))
        let rep=NSBitmapImageRep(cgImage:try XCTUnwrap(context.makeImage()))
        try XCTUnwrap(rep.representation(using:.png,properties:[:])).write(to:media.appendingPathComponent("image.png"))
        let cache=TimelineMediaCache(),asset=MediaAsset(name:"image",file:"image.png",kind:.image,duration:1)
        let libraryReady=expectation(description:"first requester"),timelineReady=expectation(description:"pending timeline requester")
        let subscriber=NSObject();var timelineCalls=0
        XCTAssertNil(cache.thumbnail(asset:asset,directory:root,time:0,limitMB:16,onReady:{libraryReady.fulfill()}))
        for _ in 0..<5 {
            XCTAssertNil(cache.thumbnail(asset:asset,directory:root,time:0,limitMB:16,subscriber:ObjectIdentifier(subscriber),onReady:{timelineCalls+=1;timelineReady.fulfill()}))
        }
        await fulfillment(of:[libraryReady,timelineReady],timeout:5)
        XCTAssertEqual(timelineCalls,1,"Redrawing while a request is pending must not register duplicate callbacks")
        XCTAssertNotNil(cache.thumbnail(asset:asset,directory:root,time:0,limitMB:16,onReady:{}))
    }
    func testRetentionKeepsOnlyVisibleMatchingSamplesAndHonorsBudget() {
        let retention=TimelineThumbnailRetention(byteLimit:64*64*4)
        let directory=URL(fileURLWithPath:"/tmp/timeline-thumbnail-test")
        let asset=MediaAsset(name:"video",file:"video.mp4",kind:.video,duration:10)
        let first=NSImage(size:NSSize(width:64,height:64)),second=NSImage(size:NSSize(width:64,height:64))
        retention.beginFrame()
        XCTAssertTrue(retention.image(asset:asset,directory:directory,time:1,loaded:first) === first)
        XCTAssertTrue(retention.image(asset:asset,directory:directory,time:2,loaded:second) === second)
        retention.endFrame()
        retention.beginFrame()
        XCTAssertTrue(retention.image(asset:asset,directory:directory,time:1.01,loaded:nil) === first)
        XCTAssertNil(retention.image(asset:asset,directory:directory,time:2,loaded:nil),"Frames beyond the memory budget are not retained")
        var replacement=asset;replacement.file="replacement.mp4"
        XCTAssertNil(retention.image(asset:replacement,directory:directory,time:1,loaded:nil))
        XCTAssertNil(retention.image(asset:asset,directory:directory.appendingPathComponent("other"),time:1,loaded:nil))
        retention.endFrame()
        retention.beginFrame();retention.endFrame()
        retention.beginFrame()
        XCTAssertNil(retention.image(asset:asset,directory:directory,time:1,loaded:nil),"Frames outside the visible area are released")
    }

    @MainActor func testTimelineKeepsImageVisibleWhenCacheIsCleared()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-timeline-thumbnail-\(UUID())")
        let store=EditorStore(preferencesDirectory:root.appendingPathComponent("Preferences"))
        defer{try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        store.settings.autosaveSeconds=0;store.settings.thumbnails=true;store.settings.waveforms=false
        store.layerZoom=2
        let file=store.directory.appendingPathComponent("Media/green.png")
        let source=try XCTUnwrap(RasterTools.bitmap(CGSize(width:64,height:64)))
        source.setFillColor(NSColor.green.cgColor);source.fill(CGRect(x:0,y:0,width:64,height:64))
        let rep=NSBitmapImageRep(cgImage:try XCTUnwrap(source.makeImage()))
        try XCTUnwrap(rep.representation(using:.png,properties:[:])).write(to:file)
        let asset=MediaAsset(name:"green",file:"green.png",kind:.image,duration:3)
        var clip=Clip(kind:.image,name:"image",track:0,start:0,duration:3);clip.assetID=asset.id
        var project=Project();project.assets=[asset];project.clips=[clip];store.project=project
        let cache=TimelineMediaCache(),ready=expectation(description:"timeline thumbnail loaded")
        _=cache.thumbnail(asset:asset,directory:store.directory,time:0,limitMB:16,onReady:{ready.fulfill()})
        await fulfillment(of:[ready],timeout:5)
        let scroll=NSScrollView(frame:NSRect(x:0,y:0,width:500,height:180))
        let canvas=TimelineNSView(frame:NSRect(x:0,y:0,width:500,height:180));canvas.store=store;canvas.mediaCache=cache;scroll.documentView=canvas
        func render()throws->Data {
            let context=try XCTUnwrap(RasterTools.bitmap(CGSize(width:500,height:180)))
            RasterTools.appKit(context){canvas.draw(canvas.bounds)}
            let image=NSBitmapImageRep(cgImage:try XCTUnwrap(context.makeImage()))
            return try XCTUnwrap(image.representation(using:.png,properties:[:]))
        }
        let original=try render()
        cache.clear();try FileManager.default.removeItem(at:file)
        XCTAssertEqual(try render(),original,"A cache miss must not erase a thumbnail that is already on screen")
        store.settings.thumbnails=false
        XCTAssertNotEqual(try render(),original,"The reference frame must actually contain the thumbnail")
        store.settings.thumbnails=true
        XCTAssertNotEqual(try render(),original,"Disabling thumbnails releases the retained image")
    }
}
