import XCTest
import AppKit
import AVFoundation
@testable import VMM

final class KaraokePartsTests:XCTestCase {
    @MainActor func testTimedRubyPartsSurviveSaveReloadAndExport()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-karaoke-roundtrip-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let store=EditorStore(preferencesDirectory:root);store.autoSpeech=false
        defer{try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        store.project=Project();store.project.width=320;store.project.height=180;store.project.fps=30;store.project.background="000000"
        let first=KaraokePartSpec(text:"@Ruby1=漢字,か[00:00:50]んじ\n[00:01:00]漢字[00:03:00]",track:0,beforeColor:"FFFFFF",afterColor:"FF0000",topY:0.25,bottomY:0.35)
        let second=KaraokePartSpec(text:"[00:01:00]A[00:02:00]BC[00:03:00]",track:1,beforeColor:"FFFFFF",afterColor:"00FF00",topY:0.7,bottomY:0.8)
        store.project=try KaraokePartsPlanner.make([first,second],project:store.project).0
        let expected=store.project.clips
        let package=root.appendingPathComponent("Karaoke.vmm")
        let saved=await store.saveProject(to:package);XCTAssertTrue(saved,store.error ?? "")
        let loaded=await store.loadProjectAsync(package);XCTAssertTrue(loaded,store.error ?? "")
        XCTAssertEqual(store.project.clips,expected)
        XCTAssertEqual(store.project.clips.count,2)
        XCTAssertEqual(try XCTUnwrap(store.project.clips.first).lyricRuby?.first?.timings?.first?.offset,0.5)
        XCTAssertEqual(try XCTUnwrap(store.project.clips.last).lyricWipe?.segments?.count,2)
        func colors(_ image:CGImage)->(Int,Int) {
            let rep=NSBitmapImageRep(cgImage:image);var red=0,green=0
            for y in 0..<rep.pixelsHigh {for x in 0..<rep.pixelsWide {if let c=rep.colorAt(x:x,y:y)?.usingColorSpace(.sRGB) {if c.redComponent>0.7 && c.greenComponent<0.3{red+=1};if c.greenComponent>0.7 && c.redComponent<0.3{green+=1}}}}
            return(red,green)
        }
        let context=try XCTUnwrap(RasterTools.bitmap(CGSize(width:320,height:180)))
        FrameRenderer().draw(project:store.project,directory:store.directory,time:2,context:context,size:CGSize(width:320,height:180))
        let preview=colors(try XCTUnwrap(context.makeImage()));XCTAssertGreaterThan(preview.0,5);XCTAssertGreaterThan(preview.1,5)
        let movie=root.appendingPathComponent("karaoke.mp4")
        try await MovieExporter.export(project:store.project,directory:store.directory,destination:movie){_ in}
        let generator=AVAssetImageGenerator(asset:AVURLAsset(url:movie));generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
        let frame=colors(try generator.copyCGImage(at:CMTime(seconds:2,preferredTimescale:600),actualTime:nil));XCTAssertGreaterThan(frame.0,5);XCTAssertGreaterThan(frame.1,5)
    }
    func testTwoPartsInPreviewAndMovie()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-parts-\(UUID())");try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        var project=Project();project.width=320;project.height=180;project.fps=30;project.background="000000"
        let a=KaraokePartSpec(text:"[00:01]AAA\n[00:03]",track:0,beforeColor:"FFFFFF",afterColor:"FF0000",topY:0.25,bottomY:0.35)
        let b=KaraokePartSpec(text:"[00:01]BBB\n[00:03]",track:1,beforeColor:"FFFFFF",afterColor:"00FF00",topY:0.7,bottomY:0.8)
        project=try KaraokePartsPlanner.make([a,b],project:project).0
        func colors(_ image:CGImage)->(Int,Int) {let rep=NSBitmapImageRep(cgImage:image);var red=0,green=0;for y in 0..<rep.pixelsHigh {for x in 0..<rep.pixelsWide {if let c=rep.colorAt(x:x,y:y)?.usingColorSpace(.sRGB) {if c.redComponent>0.7 && c.greenComponent<0.3{red+=1};if c.greenComponent>0.7 && c.redComponent<0.3{green+=1}}}};return(red,green)}
        let context=try XCTUnwrap(RasterTools.bitmap(CGSize(width:320,height:180)));FrameRenderer().draw(project:project,directory:root,time:2,context:context,size:CGSize(width:320,height:180))
        let preview=colors(try XCTUnwrap(context.makeImage()));XCTAssertGreaterThan(preview.0,20);XCTAssertGreaterThan(preview.1,20)
        let url=root.appendingPathComponent("parts.mp4");try await MovieExporter.export(project:project,directory:root,destination:url){_ in}
        let generator=AVAssetImageGenerator(asset:AVURLAsset(url:url));generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
        let movie=colors(try generator.copyCGImage(at:CMTime(seconds:2,preferredTimescale:600),actualTime:nil));XCTAssertGreaterThan(movie.0,20);XCTAssertGreaterThan(movie.1,20)
    }
    func testSimultaneousPartsAndLockedTrackAreAtomic()throws {
        var project=Project()
        let a=KaraokePartSpec(text:"[00:01]あ\n[00:03]",track:0,beforeColor:"FFFFFF",afterColor:"FF0000",topY:0.2,bottomY:0.3)
        let b=KaraokePartSpec(text:"[00:01]い\n[00:03]",track:1,beforeColor:"FFFFFF",afterColor:"00FF00",topY:0.7,bottomY:0.8)
        let (result,clips)=try KaraokePartsPlanner.make([a,b],project:project)
        XCTAssertEqual(clips.count,2);XCTAssertEqual(clips.map(\.track),[0,1]);XCTAssertEqual(clips.map(\.y),[0.2,0.7]);XCTAssertEqual(clips.map{$0.lyricWipe?.color},["FF0000","00FF00"])
        XCTAssertEqual(clips[0].start,clips[1].start);XCTAssertEqual(result.clips.count,2);XCTAssertTrue(project.clips.isEmpty)
        project.tracks[1].locked=true;XCTAssertThrowsError(try KaraokePartsPlanner.make([a,b],project:project));XCTAssertTrue(project.clips.isEmpty)
    }
}
