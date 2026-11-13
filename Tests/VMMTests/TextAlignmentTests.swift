import XCTest
import AppKit
import AVFoundation
@testable import VMM

final class TextAlignmentTests:XCTestCase {
    func project(_ alignment:TextAlignment?)->Project {
        var p=Project();p.width=640;p.height=360;p.fps=30;p.background="000000"
        var c=Clip(kind:.text,name:"配置",track:0,start:0,duration:0.3)
        c.text="あいうえお";c.fontSize=40;c.color="FFFFFF";c.textStyle=TextStyle();c.textStyle?.outline=false;c.textStyle?.captionWidth=0.8;c.textStyle?.alignment=alignment;p.clips=[c];return p
    }
    func testAlignmentBoundsLegacyAndCacheInvalidation()throws {
        let painter=TextPainter()
        let left=painter.bounds(project(.left).clips[0],projectWidth:640),center=painter.bounds(project(.center).clips[0],projectWidth:640),right=painter.bounds(project(.right).clips[0],projectWidth:640),spread=painter.bounds(project(.distributed).clips[0],projectWidth:640)
        XCTAssertGreaterThan(center.minX,left.minX+100);XCTAssertGreaterThan(right.minX,center.minX+100)
        XCTAssertEqual(left.width,center.width,accuracy:0.01);XCTAssertEqual(center.width,right.width,accuracy:0.01)
        XCTAssertEqual(spread.minX,left.minX,accuracy:0.01);XCTAssertEqual(spread.maxX,right.maxX,accuracy:1)
        XCTAssertEqual(painter.bounds(project(nil).clips[0],projectWidth:640),center)
        let p=project(.distributed);XCTAssertEqual(try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(p)).validated(),p)
        let legacy=try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(project(nil)));XCTAssertNil(legacy.clips[0].textStyle?.alignment)
        var clip=project(.left).clips[0]
        func image()->CGImage?{let c=RasterTools.bitmap(CGSize(width:640,height:360))!;painter.draw(clip,projectWidth:640,center:CGPoint(x:320,y:180),context:c);return c.makeImage()}
        let a=NSBitmapImageRep(cgImage:try XCTUnwrap(image())).representation(using:.png,properties:[:])
        clip.textStyle?.alignment = .right
        XCTAssertNotEqual(a,NSBitmapImageRep(cgImage:try XCTUnwrap(image())).representation(using:.png,properties:[:]))
        clip.text="あ\nいうえお";clip.textStyle?.alignment = .distributed
        XCTAssertFalse(painter.bounds(clip,projectWidth:640).isNull)
        clip.text="あ";XCTAssertLessThan(painter.bounds(clip,projectWidth:640).width,50)
    }
    func testPreviewAndMP4Alignment()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("VMM-alignment-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        for mode in TextAlignment.allCases {
            let p=project(mode),context=try XCTUnwrap(RasterTools.bitmap(CGSize(width:640,height:360)))
            FrameRenderer().draw(project:p,directory:root,time:0,context:context,size:CGSize(width:640,height:360))
            let preview=try XCTUnwrap(context.makeImage())
            let url=root.appendingPathComponent(mode.rawValue+".mp4")
            try await MovieExporter.export(project:p,directory:root,destination:url){_ in}
            let generator=AVAssetImageGenerator(asset:AVURLAsset(url:url));generator.appliesPreferredTrackTransform=true
            let frame=try generator.copyCGImage(at:.zero,actualTime:nil)
            func extent(_ image:CGImage)->(Int,Int){let bitmap=NSBitmapImageRep(cgImage:image);var lo=640,hi=0;for y in 0..<360 {for x in 0..<640 {if let c=bitmap.colorAt(x:x,y:y)?.usingColorSpace(.sRGB),c.redComponent>0.7{lo=min(lo,x);hi=max(hi,x)}}};return(lo,hi)}
            let a=extent(preview),b=extent(frame);XCTAssertLessThan(a.0,a.1);XCTAssertEqual(a.0,b.0,accuracy:3);XCTAssertEqual(a.1,b.1,accuracy:3)
            if let folder=testArtifactDirectory(){let out=URL(fileURLWithPath:folder);try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true);try XCTUnwrap(NSBitmapImageRep(cgImage:preview).representation(using:.png,properties:[:])).write(to:out.appendingPathComponent("alignment-"+mode.rawValue+".png"));try FileManager.default.copyItem(at:url,to:out.appendingPathComponent("alignment-"+mode.rawValue+".mp4"))}
        }
    }
}
