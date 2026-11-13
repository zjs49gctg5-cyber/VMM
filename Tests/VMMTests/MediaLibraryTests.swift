import XCTest
import AppKit
import SwiftUI
@testable import VMM

final class MediaLibraryTests:XCTestCase {
    func testSearchFiltersAndNaturalStableSorting() {
        let image=MediaAsset(name:"素材10 ＢＧ 空",file:"a.png",kind:.image,duration:2)
        let second=MediaAsset(name:"素材2 bg 空",file:"b.png",kind:.image,duration:2)
        let video=MediaAsset(name:"BG 動画",file:"v.mp4",kind:.video,duration:8)
        let audio=MediaAsset(name:"BGM",file:"a.wav",kind:.audio,duration:4)
        let psd=MediaAsset(name:"立ち絵",file:"c.psd",kind:.image,duration:2,psd:PSDTests().sample())
        let source=[image,second,video,audio,psd]
        func query(_ search:String="",_ filter:LibraryFilter = .all,_ sort:LibrarySort = .imported,_ descending:Bool=false)->[UUID] {
            LibraryQuery.assets(source,search:search,filter:filter,sort:sort,descending:descending).map(\.id)
        }
        XCTAssertEqual(query("bG　空",.image),[image.id,second.id])
        XCTAssertEqual(query("BG 海"),[])
        XCTAssertEqual(query("",.image,.name),[second.id,image.id])
        XCTAssertEqual(query("",.psd),[psd.id])
        XCTAssertEqual(query("",.video),[video.id]);XCTAssertEqual(query("",.audio),[audio.id])
        XCTAssertEqual(query("",.all,.duration),[image.id,second.id,psd.id,audio.id,video.id])
        XCTAssertEqual(query("",.all,.imported,true),source.reversed().map(\.id))
    }
    @MainActor func testPreferencesLegacyDecodePersistenceAndHiddenGeneratedAudio()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-library-\(UUID())")
        let store=EditorStore(preferencesDirectory:root)
        defer{try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        let old=try JSONDecoder().decode(UserSettings.self,from:JSONEncoder().encode(UserSettings()))
        XCTAssertNil(old.libraryLayout);XCTAssertNil(old.librarySort);XCTAssertNil(old.libraryDescending);XCTAssertNil(old.libraryThumbnails);XCTAssertNil(old.libraryFiltersVisible)
        let api=EditorCommands();api.store=store
        XCTAssertEqual(try CommandTests().command(api,["command":"settings.update","properties":["libraryLayout":"grid","librarySort":"name","libraryDescending":true,"libraryThumbnails":false,"libraryFiltersVisible":false]]).status,200)
        XCTAssertEqual(store.settings.libraryFiltersVisible,false)
        store.settings.libraryLayout = .grid;store.settings.librarySort = .name;store.settings.libraryDescending=true;store.settings.libraryThumbnails=false
        store.persistSettings()
        let saved=try JSONDecoder().decode(UserSettings.self,from:Data(contentsOf:root.appendingPathComponent("settings.json")))
        XCTAssertEqual(saved,store.settings)
        let generated=MediaAsset(name:"speech",file:"speech.wav",kind:.audio,duration:1,generatedSpeech:true)
        let bgm=MediaAsset(name:"BGM",file:"bgm.wav",kind:.audio,duration:2)
        store.project.assets=[generated,bgm]
        XCTAssertEqual(LibraryQuery.assets(store.libraryAssets,search:"",filter:.audio,sort:.name,descending:false).map(\.id),[bgm.id])
        let response=try CommandTests().command(api,["command":"settings.update","properties":["libraryLayout":"list","librarySort":"duration","libraryDescending":false,"libraryThumbnails":true]])
        XCTAssertEqual(response.status,200);XCTAssertEqual(store.settings.libraryLayout,.list)
        XCTAssertEqual(try CommandTests().command(api,["command":"settings.update","properties":["libraryLayout":"invalid"]]).status,400)
        XCTAssertEqual(store.settings.libraryLayout,.list)
    }
    @MainActor func testFilterVisibilityInNativePanel() async throws {
        guard let output=testArtifactDirectory() else {throw XCTSkip("Opt-in media library layout test")}
        try FileManager.default.createDirectory(atPath:output,withIntermediateDirectories:true)
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-library-layout-\(UUID())")
        let store=EditorStore(preferencesDirectory:root)
        store.settings.autosaveSeconds=0;store.autoSpeech=false
        defer{try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        for (visible,width) in [(true,320.0),(false,320.0),(true,190.0),(false,190.0)] {
            store.settings.libraryFiltersVisible=visible
            let host=NSHostingView(rootView:MediaLibraryPanel(store:store).vmmAppearance(store.settings).preferredColorScheme(.dark))
            let window=NSWindow(contentRect:NSRect(x:0,y:0,width:width,height:650),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
            window.isReleasedWhenClosed=false;window.appearance=NSAppearance(named:.darkAqua);window.contentView=host;window.makeKeyAndOrderFront(nil);defer{window.close()}
            host.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:200_000_000)
            let bitmap=try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds));host.cacheDisplay(in:host.bounds,to:bitmap)
            try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:URL(fileURLWithPath:output).appendingPathComponent("library-\(visible ? "expanded":"collapsed")-\(Int(width)).png"))
        }
    }
    @MainActor func testPSDThumbnailAndFullCompositeHaveIndependentSizes()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-thumbnail-\(UUID())")
        try FileManager.default.createDirectory(at:root.appendingPathComponent("Media"),withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let context=try XCTUnwrap(RasterTools.bitmap(CGSize(width:512,height:256)))
        context.setFillColor(NSColor.red.cgColor);context.fill(CGRect(x:0,y:0,width:512,height:256))
        let rep=NSBitmapImageRep(cgImage:try XCTUnwrap(context.makeImage()))
        try XCTUnwrap(rep.representation(using:.png,properties:[:])).write(to:root.appendingPathComponent("Media/base.png"))
        let doc=PSDDocument(width:512,height:256,layers:[PSDLayer(id:0,name:"base",group:false,visible:true,opacity:1,x:0,y:0,width:512,height:256,file:"base.png")])
        let asset=MediaAsset(name:"PSD",file:"document.psd",kind:.image,duration:1,psd:doc)
        let renderer=PSDRenderer(),state=PSDState.initial(doc)
        XCTAssertEqual(renderer.image(asset:asset,state:state,directory:root,speaking:false,time:0,maximumSize:CGSize(width:128,height:128))?.size,CGSize(width:128,height:64))
        XCTAssertEqual(renderer.image(asset:asset,state:state,directory:root,speaking:false,time:0)?.size,CGSize(width:512,height:256))
        let cache=TimelineMediaCache(),ready=expectation(description:"async thumbnail")
        XCTAssertNil(cache.thumbnail(asset:asset,directory:root,time:0,limitMB:16,onReady:{ready.fulfill()}))
        await fulfillment(of:[ready],timeout:10)
        let thumb=try XCTUnwrap(cache.thumbnail(asset:asset,directory:root,time:0,limitMB:16,onReady:{}))
        XCTAssertEqual(thumb.size,CGSize(width:128,height:64));XCTAssertGreaterThan(cache.revision,0)
        let bitmap=try XCTUnwrap(thumb.tiffRepresentation)
        let color=try XCTUnwrap(NSBitmapImageRep(data:bitmap)?.colorAt(x:64,y:32)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(color.redComponent,0.9);XCTAssertLessThan(color.blueComponent,0.1)
    }
}
