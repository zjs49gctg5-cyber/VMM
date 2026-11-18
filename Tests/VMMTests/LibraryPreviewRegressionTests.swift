import XCTest
import AVFoundation
import AppKit
@testable import VMM

private actor ThumbnailLoadGate {
    private var released=false
    private var continuation:CheckedContinuation<Void,Never>?
    func wait() async {
        if released {return}
        await withCheckedContinuation {continuation=$0}
    }
    func release() {
        released=true;continuation?.resume();continuation=nil
    }
}

final class LibraryPreviewRegressionTests:XCTestCase {
    @MainActor func testThumbnailDiscardsOutdatedSuccessWhenFileIsReplacedDuringLoad()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-thumbnail-success-race-\(UUID())")
        let media=root.appendingPathComponent("Media"),url=media.appendingPathComponent("image.png")
        try FileManager.default.createDirectory(at:media,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        func png(_ color:NSColor)throws->Data {
            let context=try XCTUnwrap(RasterTools.bitmap(CGSize(width:64,height:64)))
            context.setFillColor(color.cgColor);context.fill(CGRect(x:0,y:0,width:64,height:64))
            return try XCTUnwrap(NSBitmapImageRep(cgImage:try XCTUnwrap(context.makeImage())).representation(using:.png,properties:[:]))
        }
        let red=try png(.red),green=try png(.green);try red.write(to:url)
        let started=expectation(description:"old image read"),finished=expectation(description:"old request completed"),gate=ThumbnailLoadGate()
        defer{Task{await gate.release()}}
        let cache=TimelineMediaCache(imageLoader:{url in
            let data=try? Data(contentsOf:url)
            if data == red {started.fulfill();await gate.wait()}
            return data.flatMap{NSImage(data:$0)}
        })
        let asset=MediaAsset(name:"image",file:"image.png",kind:.image,duration:1)
        _=cache.thumbnail(asset:asset,directory:root,time:0,limitMB:16,onReady:{finished.fulfill()})
        await fulfillment(of:[started],timeout:5)
        try green.write(to:url,options:.atomic);await gate.release()
        await fulfillment(of:[finished],timeout:5)
        let refreshed=expectation(description:"replacement loaded")
        XCTAssertNil(cache.thumbnail(asset:asset,directory:root,time:0,limitMB:16,onReady:{refreshed.fulfill()}),"An image decoded from the replaced file must not enter the cache")
        await fulfillment(of:[refreshed],timeout:5)
        let image=try XCTUnwrap(cache.thumbnail(asset:asset,directory:root,time:0,limitMB:16,onReady:{}))
        let color=try XCTUnwrap(NSBitmapImageRep(data:try XCTUnwrap(image.tiffRepresentation))?.colorAt(x:32,y:32)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(color.greenComponent,0.9);XCTAssertLessThan(color.redComponent,0.1)
    }
    @MainActor func testThumbnailRetriesWhenFileIsReplacedDuringFailedLoad()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-thumbnail-inflight-\(UUID())")
        let media=root.appendingPathComponent("Media"),url=media.appendingPathComponent("image.png")
        try FileManager.default.createDirectory(at:media,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        try Data("invalid".utf8).write(to:url)
        let started=expectation(description:"first load has read the old file")
        let failed=expectation(description:"first load has completed")
        let gate=ThumbnailLoadGate()
        defer{Task{await gate.release()}}
        let cache=TimelineMediaCache(imageLoader:{url in
            let data=try? Data(contentsOf:url)
            if data == Data("invalid".utf8) {started.fulfill();await gate.wait();return nil}
            return data.flatMap{NSImage(data:$0)}
        })
        let asset=MediaAsset(name:"image",file:"image.png",kind:.image,duration:1)
        XCTAssertNil(cache.thumbnail(asset:asset,directory:root,time:0,limitMB:16,onReady:{failed.fulfill()}))
        await fulfillment(of:[started],timeout:5)
        let context=try XCTUnwrap(RasterTools.bitmap(CGSize(width:64,height:64)))
        context.setFillColor(NSColor.green.cgColor);context.fill(CGRect(x:0,y:0,width:64,height:64))
        let png=try XCTUnwrap(NSBitmapImageRep(cgImage:try XCTUnwrap(context.makeImage())).representation(using:.png,properties:[:]))
        try png.write(to:url)
        await gate.release()
        await fulfillment(of:[failed],timeout:5)
        let recovered=expectation(description:"changed file is retried immediately")
        var image:NSImage?
        XCTAssertNil(cache.thumbnail(asset:asset,directory:root,time:0,limitMB:16,onReady:{
            image=cache.thumbnail(asset:asset,directory:root,time:0,limitMB:16,onReady:{})
            recovered.fulfill()
        }))
        XCTAssertEqual(cache.pendingRequests,1,"the previous failure must not be attributed to the replacement")
        await fulfillment(of:[recovered],timeout:5)
        XCTAssertNotNil(image)
    }
    @MainActor func testThumbnailRetriesWhenSameSizeFileChangesWithinOneSecond()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-thumbnail-subsecond-\(UUID())")
        let media=root.appendingPathComponent("Media"),url=media.appendingPathComponent("image.png")
        try FileManager.default.createDirectory(at:media,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let context=try XCTUnwrap(RasterTools.bitmap(CGSize(width:64,height:64)))
        context.setFillColor(NSColor.green.cgColor);context.fill(CGRect(x:0,y:0,width:64,height:64))
        let rep=NSBitmapImageRep(cgImage:try XCTUnwrap(context.makeImage()))
        let valid=try XCTUnwrap(rep.representation(using:.png,properties:[:]))
        try Data(repeating:0,count:valid.count).write(to:url)
        let base=1_700_000_000.0
        try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:base+0.1)],ofItemAtPath:url.path)
        let cache=TimelineMediaCache(),asset=MediaAsset(name:"image",file:"image.png",kind:.image,duration:1)
        let failed=expectation(description:"invalid image attempted")
        XCTAssertNil(cache.thumbnail(asset:asset,directory:root,time:0,limitMB:16,onReady:{failed.fulfill()}))
        await fulfillment(of:[failed],timeout:5)
        try valid.write(to:url)
        try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:base+0.6)],ofItemAtPath:url.path)
        let recovered=expectation(description:"replacement is retried without backoff")
        var recoveredImage:NSImage?
        XCTAssertNil(cache.thumbnail(asset:asset,directory:root,time:0,limitMB:16,onReady:{
            recoveredImage=cache.thumbnail(asset:asset,directory:root,time:0,limitMB:16,onReady:{})
            recovered.fulfill()
        }))
        XCTAssertEqual(cache.pendingRequests,1,"same-size replacement must be retried immediately")
        await fulfillment(of:[recovered],timeout:5)
        XCTAssertNotNil(recoveredImage)
    }

    @MainActor func testThumbnailKeepsCompletedImageDuringCacheReloadButNotForOtherSources()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-thumbnail-continuity-\(UUID())")
        let media=root.appendingPathComponent("Media"),file=media.appendingPathComponent("image.png")
        try FileManager.default.createDirectory(at:media,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let context=try XCTUnwrap(RasterTools.bitmap(CGSize(width:64,height:64)))
        context.setFillColor(NSColor.green.cgColor);context.fill(CGRect(x:0,y:0,width:64,height:64))
        let rep=NSBitmapImageRep(cgImage:try XCTUnwrap(context.makeImage()))
        try XCTUnwrap(rep.representation(using:.png,properties:[:])).write(to:file)
        let evictable=NSCache<NSString,NSImage>(),cache=TimelineMediaCache(images:evictable),presentation=LibraryThumbnailPresentation()
        let asset=MediaAsset(name:"image",file:"image.png",kind:.image,duration:1)
        let ready=expectation(description:"initial image")
        _=cache.thumbnail(asset:asset,directory:root,time:0,limitMB:16,onReady:{ready.fulfill()})
        await fulfillment(of:[ready],timeout:5)
        presentation.refresh(asset:asset,directory:root,limitMB:16,enabled:true,cache:cache)
        let original=try XCTUnwrap(presentation.image)
        evictable.removeAllObjects()
        XCTAssertTrue(cache.thumbnail(asset:asset,directory:root,time:0,limitMB:16,onReady:{}) === original,"A freshly generated image must survive immediate NSCache eviction")
        cache.clear()
        try FileManager.default.removeItem(at:file)
        presentation.refresh(asset:asset,directory:root,limitMB:16,enabled:true,cache:cache)
        XCTAssertTrue(presentation.image === original,"An incomplete reload must not replace the visible thumbnail with a placeholder")
        var replacement=asset;replacement.file="other.png"
        presentation.refresh(asset:replacement,directory:root,limitMB:16,enabled:true,cache:cache)
        XCTAssertNil(presentation.image,"The previous source must not be displayed for a different file")
        presentation.refresh(asset:asset,directory:root,limitMB:16,enabled:false,cache:cache)
        XCTAssertNil(presentation.image)
    }
    @MainActor func testWaveformRemainsVisibleWhileCacheReloads()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-waveform-continuity-\(UUID())")
        let media=root.appendingPathComponent("Media"),file=media.appendingPathComponent("tone.wav")
        try FileManager.default.createDirectory(at:media,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let format=try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate:44100,channels:1))
        let buffer=try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:4410));buffer.frameLength=4410
        let samples=try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<Int(buffer.frameLength) {samples[index]=Float(sin(Double(index)*0.1)*0.5)}
        do {let audio=try AVAudioFile(forWriting:file,settings:format.settings);try audio.write(from:buffer)}
        let cache=TimelineMediaCache(),presentation=LibraryThumbnailPresentation()
        let asset=MediaAsset(name:"tone",file:"tone.wav",kind:.audio,duration:0.1)
        let ready=expectation(description:"initial waveform")
        _=cache.envelope(asset:asset,directory:root,onReady:{ready.fulfill()})
        await fulfillment(of:[ready],timeout:5)
        presentation.refresh(asset:asset,directory:root,limitMB:16,enabled:true,cache:cache)
        let original=try XCTUnwrap(presentation.waveform);XCTAssertFalse(original.isEmpty)
        cache.clear();try FileManager.default.removeItem(at:file)
        presentation.refresh(asset:asset,directory:root,limitMB:16,enabled:true,cache:cache)
        XCTAssertEqual(presentation.waveform,original)
        presentation.refresh(asset:asset,directory:root,limitMB:16,enabled:false,cache:cache)
        XCTAssertNil(presentation.waveform)
    }
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
        var recoveredImage:NSImage?
        _=cache.thumbnail(asset:asset,directory:root,time:0,limitMB:16,onReady:{
            recoveredImage=cache.thumbnail(asset:asset,directory:root,time:0,limitMB:16,onReady:{})
            recovered.fulfill()
        })
        await fulfillment(of:[recovered],timeout:5)
        XCTAssertNotNil(recoveredImage)
        cache.clear()
        let reload=expectation(description:"cleared cache regenerates")
        var reloadedImage:NSImage?
        _=cache.thumbnail(asset:asset,directory:root,time:0,limitMB:16,onReady:{
            reloadedImage=cache.thumbnail(asset:asset,directory:root,time:0,limitMB:16,onReady:{})
            reload.fulfill()
        })
        await fulfillment(of:[reload],timeout:5)
        XCTAssertNotNil(reloadedImage)
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
