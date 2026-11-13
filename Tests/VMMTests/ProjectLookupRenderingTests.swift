import AppKit
import AVFoundation
import XCTest
@testable import VMM

final class ProjectLookupRenderingTests:XCTestCase {
    func testIndexedAssetsRenderInPreviewAndMP4() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-lookups-movie-\(UUID())")
        let media=root.appendingPathComponent("Media")
        try FileManager.default.createDirectory(at:media,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let source=try XCTUnwrap(RasterTools.bitmap(CGSize(width:40,height:40)))
        source.setFillColor(NSColor.red.cgColor);source.fill(CGRect(x:0,y:0,width:40,height:40))
        let png=NSBitmapImageRep(cgImage:try XCTUnwrap(source.makeImage()))
        try XCTUnwrap(png.representation(using:.png,properties:[:])).write(to:media.appendingPathComponent("red.png"))
        var p=Project();p.width=160;p.height=90;p.fps=30
        p.assets=(0..<200).map{MediaAsset(name:"asset\($0)",file:"red.png",kind:.image,duration:1)}
        var clip=Clip(kind:.image,name:"animated",track:0,start:0,duration:0.5)
        clip.assetID=p.assets.last!.id;clip.scale=0.5
        clip.animation=ClipAnimation(tracks:[AnimationTrack(property:.x,keys:[AnimationKeyframe(time:0,value:0.4),AnimationKeyframe(time:0.5,value:0.6)])])
        p.clips=[clip]
        let size=CGSize(width:160,height:90),preview=try XCTUnwrap(RasterTools.bitmap(size))
        FrameRenderer(useProxies:false).draw(project:p,directory:root,time:0.2,context:preview,size:size)
        let output=root.appendingPathComponent("result.mp4")
        try await MovieExporter.export(project:p,directory:root,destination:output){_ in}
        let generator=AVAssetImageGenerator(asset:AVURLAsset(url:output))
        generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
        let image=try generator.copyCGImage(at:CMTime(seconds:0.2,preferredTimescale:600),actualTime:nil)
        let movie=try XCTUnwrap(RasterTools.bitmap(size));movie.draw(image,in:CGRect(origin:.zero,size:size))
        func pixels(_ context:CGContext)throws->[UInt8] {
            Array(UnsafeBufferPointer(start:try XCTUnwrap(context.data).assumingMemoryBound(to:UInt8.self),count:context.bytesPerRow*context.height))
        }
        let a=try pixels(preview),b=try pixels(movie)
        let mean=zip(a,b).reduce(0.0){$0+Double(abs(Int($1.0)-Int($1.1)))}/Double(a.count)
        XCTAssertLessThan(mean,10)
    }
    func testIndexedLookupsMatchScanningAfterAssetAndParentEdits() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-lookups-\(UUID())")
        let media=root.appendingPathComponent("Media")
        try FileManager.default.createDirectory(at:media,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        for (name,color) in [("red",NSColor.red),("blue",NSColor.blue)] {
            let ctx=try XCTUnwrap(RasterTools.bitmap(CGSize(width:40,height:40)))
            ctx.setFillColor(color.cgColor);ctx.fill(CGRect(x:0,y:0,width:40,height:40))
            let bitmap=NSBitmapImageRep(cgImage:try XCTUnwrap(ctx.makeImage()))
            try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:media.appendingPathComponent("\(name).png"))
        }
        var p=Project();p.width=160;p.height=90
        p.assets=(0..<200).map{MediaAsset(name:"asset\($0)",file:"red.png",kind:.image,duration:1)}
        var image=Clip(kind:.image,name:"image",track:0,start:0,duration:2)
        image.assetID=p.assets.last!.id
        var child=Clip(kind:.shape,name:"child",track:0,start:0.5,duration:0.5)
        child.parentID=image.id;child.color="00FF00";child.scale=0.25
        p.clips=[image,child]
        let optimized=FrameRenderer(),reference=FrameRenderer();reference.reuseProjectLookups=false
        func pixels(_ renderer:FrameRenderer,_ time:Double)throws->[UInt8] {
            let size=CGSize(width:p.width,height:p.height),ctx=try XCTUnwrap(RasterTools.bitmap(size))
            renderer.draw(project:p,directory:root,time:time,context:ctx,size:size)
            return Array(UnsafeBufferPointer(start:try XCTUnwrap(ctx.data).assumingMemoryBound(to:UInt8.self),count:ctx.bytesPerRow*ctx.height))
        }
        for time in [0.25,0.75,1.25] {XCTAssertEqual(try pixels(optimized,time),try pixels(reference,time))}
        let before=try pixels(optimized,1.25)
        p.assets[p.assets.count-1].file="blue.png"
        XCTAssertNotEqual(before,try pixels(optimized,1.25))
        XCTAssertEqual(try pixels(optimized,1.25),try pixels(reference,1.25))
        p.clips[1].parentID=nil
        XCTAssertEqual(try pixels(optimized,0.75),try pixels(reference,0.75))
        p.clips[1].parentID=image.id
        XCTAssertEqual(try pixels(optimized,0.75),try pixels(reference,0.75))
    }
}
