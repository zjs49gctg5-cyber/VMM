import XCTest
import AppKit
@testable import VMM

final class TimelineThumbnailContinuityTests:XCTestCase {
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
