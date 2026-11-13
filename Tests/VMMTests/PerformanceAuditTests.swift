import XCTest
import AppKit
import AVFoundation
@testable import VMM

final class PerformanceAuditTests:XCTestCase {
    @MainActor func testMediaWorkIsBoundedAndClearRejectsStaleResults()async throws {
        let cache=TimelineMediaCache(),folder=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-cache-audit-\(UUID())")
        var callbacks=0
        for i in 0..<1000 {
            let asset=MediaAsset(name:"Missing \(i)",file:"\(i).wav",kind:.audio,duration:10)
            XCTAssertNil(cache.envelope(asset:asset,directory:folder,onReady:{callbacks+=1}))
        }
        XCTAssertEqual(cache.pendingRequests,64);XCTAssertEqual(cache.activeRequests,2)
        cache.clear();XCTAssertEqual(cache.pendingRequests,0)
        let limit=ProcessInfo.processInfo.systemUptime+10
        while cache.activeRequests>0 && ProcessInfo.processInfo.systemUptime<limit {try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertEqual(cache.activeRequests,0);XCTAssertEqual(cache.revision,1);XCTAssertEqual(callbacks,0)
        XCTAssertEqual(cache.peakConcurrentRequests,2)
        let asset=MediaAsset(name:"Retry",file:"retry.wav",kind:.audio,duration:1)
        let ready=expectation(description:"new generation completes")
        XCTAssertNil(cache.envelope(asset:asset,directory:folder,onReady:{ready.fulfill()}))
        await fulfillment(of:[ready],timeout:10)
        XCTAssertEqual(cache.envelope(asset:asset,directory:folder,onReady:{}),[])
        XCTAssertEqual(cache.pendingRequests,0)
    }
    @MainActor func testPSDProjectSwitchMatchesActualExport()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-psd-cache-\(UUID())")
        defer{try? FileManager.default.removeItem(at:root)}
        let folders=[root.appendingPathComponent("Red"),root.appendingPathComponent("Blue")]
        for (folder,color) in zip(folders,[NSColor.red,NSColor.blue]) {
            try FileManager.default.createDirectory(at:folder.appendingPathComponent("Media"),withIntermediateDirectories:true)
            let context=try XCTUnwrap(RasterTools.bitmap(CGSize(width:64,height:64)))
            context.setFillColor(color.cgColor);context.fill(CGRect(x:0,y:0,width:64,height:64))
            let rep=NSBitmapImageRep(cgImage:try XCTUnwrap(context.makeImage()))
            try XCTUnwrap(rep.representation(using:.png,properties:[:])).write(to:folder.appendingPathComponent("Media/base.png"))
            try Data().write(to:folder.appendingPathComponent("Media/portrait.psd"))
        }
        let document=PSDDocument(width:64,height:64,layers:[PSDLayer(id:0,name:"Base",group:false,visible:true,opacity:1,x:0,y:0,width:64,height:64,file:"base.png")])
        let asset=MediaAsset(name:"Portrait",file:"portrait.psd",kind:.image,duration:1,psd:document)
        var project=Project();project.width=64;project.height=64;project.assets=[asset]
        var clip=Clip(kind:.image,name:"Portrait",track:0,start:0,duration:0.2);clip.assetID=asset.id;project.clips=[clip]
        let renderer=FrameRenderer(),psd=PSDRenderer(),state=PSDState.initial(document)
        for (folder,blue) in zip(folders,[false,true]) {
            let composite=try XCTUnwrap(psd.image(asset:asset,state:state,directory:folder,speaking:false,time:0))
            let pixel=try XCTUnwrap(NSBitmapImageRep(data:try XCTUnwrap(composite.tiffRepresentation))?.colorAt(x:32,y:32)?.usingColorSpace(.sRGB))
            XCTAssertGreaterThan(blue ? pixel.blueComponent:pixel.redComponent,0.9)
            let context=try XCTUnwrap(RasterTools.bitmap(CGSize(width:64,height:64)))
            renderer.draw(project:project,directory:folder,time:0,context:context,size:CGSize(width:64,height:64))
            let frame=NSBitmapImageRep(cgImage:try XCTUnwrap(context.makeImage()))
            let color=try XCTUnwrap(frame.colorAt(x:32,y:32)?.usingColorSpace(.sRGB))
            XCTAssertGreaterThan(blue ? color.blueComponent:color.redComponent,0.9)
            if blue,let output=testArtifactDirectory() {
                try FileManager.default.createDirectory(atPath:output,withIntermediateDirectories:true)
                try XCTUnwrap(frame.representation(using:.png,properties:[:])).write(to:URL(fileURLWithPath:output).appendingPathComponent("psd-switch-preview.png"))
            }
        }
        let movie=root.appendingPathComponent("switch.mp4")
        try await MovieExporter.export(project:project,directory:folders[1],destination:movie){_ in}
        let generator=AVAssetImageGenerator(asset:AVURLAsset(url:movie));generator.appliesPreferredTrackTransform=true
        let decoded=NSBitmapImageRep(cgImage:try generator.copyCGImage(at:.zero,actualTime:nil))
        let color=try XCTUnwrap(decoded.colorAt(x:32,y:32)?.usingColorSpace(.sRGB));XCTAssertGreaterThan(color.blueComponent,0.85);XCTAssertLessThan(color.redComponent,0.1)
        if let output=testArtifactDirectory() {try FileManager.default.copyItem(at:movie,to:URL(fileURLWithPath:output).appendingPathComponent("psd-switch-export.mp4"))}
    }
    @MainActor func testLargeProjectDiagnostic()throws {
        guard let output=ProcessInfo.processInfo.environment["VMM_AUDIT_BENCHMARK"] else{throw XCTSkip("Opt-in large project benchmark")}
        var project=Project();project.tracks=(0..<32).map{Track(name:"Layer \($0)")}
        project.clips=(0..<1000).map{Clip(kind:.text,name:"字幕 \($0)",track:$0%32,start:Double($0),duration:2,text:"字幕 \($0)")}
        let library=(0..<5000).map{MediaAsset(name:"素材 \($0)",file:"\($0).png",kind:.image,duration:1)}
        func measure(_ work:()->Void)->Double {let start=ProcessInfo.processInfo.systemUptime;for _ in 0..<30{work()};return (ProcessInfo.processInfo.systemUptime-start)*1000/30}
        let lookup=measure{XCTAssertEqual(project.visibleClips(at:500).count,2)}
        let search=measure{XCTAssertFalse(LibraryQuery.assets(library,search:"素材 12",filter:.all,sort:.name,descending:false).isEmpty)}
        let encoded=try JSONEncoder().encode(project)
        let roundtrip=measure{XCTAssertEqual((try? JSONDecoder().decode(Project.self,from:encoded))?.clips.count,1000)}
        let prefs=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-timeline-audit-\(UUID())")
        let store=EditorStore(preferencesDirectory:prefs)
        defer{try? FileManager.default.removeItem(at:prefs);try? FileManager.default.removeItem(at:store.directory)}
        store.project=project;store.zoom=72;store.playhead=500
        let scroll=NSScrollView(frame:NSRect(x:0,y:0,width:1280,height:600)),canvas=TimelineNSView(frame:NSRect(x:0,y:0,width:74000,height:1600))
        canvas.store=store;scroll.documentView=canvas;scroll.contentView.scroll(to:NSPoint(x:36000,y:0))
        let context=try XCTUnwrap(RasterTools.bitmap(CGSize(width:1280,height:600)))
        let timeline=measure{RasterTools.appKit(context){canvas.draw(canvas.visibleRect)}}
        if let output=testArtifactDirectory() {
            try FileManager.default.createDirectory(atPath:output,withIntermediateDirectories:true)
            try XCTUnwrap(NSBitmapImageRep(cgImage:try XCTUnwrap(context.makeImage())).representation(using:.png,properties:[:])).write(to:URL(fileURLWithPath:output).appendingPathComponent("large-timeline.png"))
        }
        let report:[String:Any]=["clips":1000,"assets":5000,"visibleLookupMS":lookup,"librarySearchSortMS":search,"projectDecodeMS":roundtrip,"projectJSONBytes":encoded.count,"timelineRedrawMS":timeline]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:output))
        print("LARGE PROJECT AUDIT \(report)")
    }
}
