import XCTest
import AppKit
import AVFoundation
@testable import VMM

final class LyricWipeTests:XCTestCase {
    func testValidationAndRoundTrip() throws {
        let wipe=LyricWipe(start:0.2,end:1.8,color:"FFDD33")
        XCTAssertEqual(wipe.progress(at:1),0.5,accuracy:0.0001)
        XCTAssertThrowsError(try LyricWipe(start:1,end:1).validate())
        var project=Project();var clip=Clip(kind:.text,name:"lyrics",track:0,start:0,duration:2,text:"TEST");clip.lyricWipe=wipe;project.clips=[clip]
        XCTAssertEqual(try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(project)).validated(),project)
        project.clips[0].kind = .shape;XCTAssertThrowsError(try project.validated())
    }
    func testTimedCharacterSegmentsValidateAndRoundTrip()throws {
        var project=Project();var clip=Clip(kind:.text,name:"lyrics",track:0,start:0,duration:3,text:"ABC")
        var wipe=LyricWipe();wipe.segments=[LyricWipeSegment(startIndex:0,endIndex:1,start:0,end:1),LyricWipeSegment(startIndex:1,endIndex:3,start:1,end:2)]
        clip.lyricWipe=wipe;project.clips=[clip]
        XCTAssertEqual(try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(project)).validated(),project)
        project.clips[0].lyricWipe?.segments?[1].startIndex=0;XCTAssertThrowsError(try project.validated())
        project.clips[0]=clip;project.clips[0].text="A\nC";project.clips[0].lyricWipe?.segments?[1].startIndex=1
        XCTAssertThrowsError(try project.validated())
    }
    func testPreviewAndExportProgress() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-lyric-wipe-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        var project=Project();project.width=320;project.height=180;project.fps=30;project.background="000000"
        var clip=Clip(kind:.text,name:"lyrics",track:0,start:0,duration:2,text:"KARAOKE");clip.fontSize=45;clip.color="FFFFFF"
        var wipe=LyricWipe(start:0.1,end:1.9);wipe.segments=[LyricWipeSegment(startIndex:0,endIndex:3,start:0.1,end:0.5),LyricWipeSegment(startIndex:3,endIndex:7,start:1.5,end:1.9)];clip.lyricWipe=wipe;project.clips=[clip]
        let output=root.appendingPathComponent("test.mp4");try await MovieExporter.export(project:project,directory:root,destination:output){_ in}
        let generator=AVAssetImageGenerator(asset:AVURLAsset(url:output));generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
        func yellow(_ image:CGImage)->Int {
            let rep=NSBitmapImageRep(cgImage:image);var count=0
            for y in 0..<rep.pixelsHigh {for x in 0..<rep.pixelsWide {if let c=rep.colorAt(x:x,y:y)?.usingColorSpace(.sRGB),c.redComponent>0.65,c.greenComponent>0.55,c.blueComponent<0.4 {count += 1}}}
            return count
        }
        var previewCounts:[Int]=[],exportCounts:[Int]=[]
        for time in [0.2,1.0,1.8] {
            let context=try XCTUnwrap(RasterTools.bitmap(CGSize(width:320,height:180)))
            FrameRenderer().draw(project:project,directory:root,time:time,context:context,size:CGSize(width:320,height:180))
            previewCounts.append(yellow(try XCTUnwrap(context.makeImage())))
            exportCounts.append(yellow(try generator.copyCGImage(at:CMTime(seconds:time,preferredTimescale:600),actualTime:nil)))
        }
        XCTAssertLessThan(previewCounts[0],previewCounts[1]);XCTAssertLessThan(previewCounts[1],previewCounts[2])
        XCTAssertLessThan(exportCounts[0],exportCounts[1]);XCTAssertLessThan(exportCounts[1],exportCounts[2])
    }
}
