import XCTest
import AppKit
import AVFoundation
@testable import VMM

final class LyricRubyTests:XCTestCase {
    func testValidationAndBounds()throws {
        var project=Project();var clip=Clip(kind:.text,name:"ruby",track:0,start:0,duration:1,text:"漢字")
        clip.fontSize=60;let plain=TextPainter().bounds(clip,projectWidth:1920)
        clip.lyricRuby=[LyricRuby(startIndex:0,endIndex:2,text:"かんじ")];project.clips=[clip]
        XCTAssertEqual(try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(project)).validated(),project)
        let annotated=TextPainter().bounds(clip,projectWidth:1920);XCTAssertLessThan(annotated.minY,plain.minY)
        project.clips[0].lyricRuby?[0].endIndex=3;XCTAssertThrowsError(try project.validated())
    }
    func testRubyPreviewAndMP4()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-ruby-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        var project=Project();project.width=320;project.height=180;project.fps=30;project.background="000000"
        var clip=Clip(kind:.text,name:"ruby",track:0,start:0,duration:1,text:"漢字");clip.fontSize=55;clip.color="FFFFFF";project.clips=[clip]
        func white(_ image:CGImage)->Int {let rep=NSBitmapImageRep(cgImage:image);var n=0;for y in 0..<rep.pixelsHigh {for x in 0..<rep.pixelsWide {if let c=rep.colorAt(x:x,y:y)?.usingColorSpace(.sRGB),c.redComponent>0.7,c.greenComponent>0.7,c.blueComponent>0.7 {n += 1}}};return n}
        func render(_ p:Project)throws->Int {let c=try XCTUnwrap(RasterTools.bitmap(CGSize(width:320,height:180)));FrameRenderer().draw(project:p,directory:root,time:0.5,context:c,size:CGSize(width:320,height:180));return white(try XCTUnwrap(c.makeImage()))}
        let before=try render(project)
        let plain=root.appendingPathComponent("plain.mp4");try await MovieExporter.export(project:project,directory:root,destination:plain){_ in}
        project.clips[0].lyricRuby=[LyricRuby(startIndex:0,endIndex:2,text:"かんじ")]
        XCTAssertGreaterThan(try render(project),before+20)
        let ruby=root.appendingPathComponent("ruby.mp4");try await MovieExporter.export(project:project,directory:root,destination:ruby){_ in}
        func frame(_ url:URL)throws->Int {let g=AVAssetImageGenerator(asset:AVURLAsset(url:url));g.requestedTimeToleranceBefore = .zero;g.requestedTimeToleranceAfter = .zero;return white(try g.copyCGImage(at:CMTime(seconds:0.5,preferredTimescale:600),actualTime:nil))}
        XCTAssertGreaterThan(try frame(ruby),try frame(plain)+20)
    }
    func testRubyTimingChangesPreviewAndExport()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-ruby-timing-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        var project=Project();project.width=320;project.height=180;project.fps=30;project.background="000000"
        var clip=Clip(kind:.text,name:"ruby",track:0,start:0,duration:2,text:"漢字");clip.fontSize=55;clip.color="FFFFFF"
        var wipe=LyricWipe(start:0,end:2);wipe.segments=[LyricWipeSegment(startIndex:0,endIndex:2,start:0,end:2)];clip.lyricWipe=wipe
        clip.lyricRuby=[LyricRuby(startIndex:0,endIndex:2,text:"かんじ",timings:[LyricRubyTiming(index:1,offset:0.1)])];project.clips=[clip]
        func yellow(_ image:CGImage)->Int {let rep=NSBitmapImageRep(cgImage:image);var n=0;for y in 0..<rep.pixelsHigh {for x in 0..<rep.pixelsWide {if let c=rep.colorAt(x:x,y:y)?.usingColorSpace(.sRGB),c.redComponent>0.65,c.greenComponent>0.55,c.blueComponent<0.4 {n += 1}}};return n}
        func preview(_ p:Project)throws->Int {let c=try XCTUnwrap(RasterTools.bitmap(CGSize(width:320,height:180)));FrameRenderer().draw(project:p,directory:root,time:0.5,context:c,size:CGSize(width:320,height:180));return yellow(try XCTUnwrap(c.makeImage()))}
        func exported(_ p:Project,_ name:String)async throws->Int {let url=root.appendingPathComponent(name);try await MovieExporter.export(project:p,directory:root,destination:url){_ in};let g=AVAssetImageGenerator(asset:AVURLAsset(url:url));g.requestedTimeToleranceBefore = .zero;g.requestedTimeToleranceAfter = .zero;return yellow(try g.copyCGImage(at:CMTime(seconds:0.5,preferredTimescale:600),actualTime:nil))}
        let timedPreview=try preview(project),timedExport=try await exported(project,"timed.mp4")
        project.clips[0].lyricRuby?[0].timings=nil
        XCTAssertGreaterThan(timedPreview,try preview(project))
        let plainExport=try await exported(project,"plain.mp4");XCTAssertGreaterThan(timedExport,plainExport)
    }
}
