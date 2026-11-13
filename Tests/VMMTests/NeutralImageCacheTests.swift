import XCTest
import AppKit
import AVFoundation
@testable import VMM

final class NeutralImageCacheTests:XCTestCase {
    func testLowBudgetDoesNotEvictStaticLayersForAnimatedImages() throws {
        let root=try AdvancedTests().folder();defer{try? FileManager.default.removeItem(at:root)}
        let ctx=try XCTUnwrap(RasterTools.bitmap(CGSize(width:64,height:64)))
        ctx.setFillColor(NSColor.orange.cgColor);ctx.fill(CGRect(x:0,y:0,width:64,height:64))
        try XCTUnwrap(NSBitmapImageRep(cgImage:try XCTUnwrap(ctx.makeImage())).representation(using:.png,properties:[:])).write(to:root.appendingPathComponent("Media/still.png"))
        var p=Project();p.width=1280;p.height=720;p.tracks=(0..<12).map{Track(name:"Layer \($0)")}
        let asset=MediaAsset(name:"still",file:"still.png",kind:.image,duration:2);p.assets=[asset]
        p.clips=(0..<12).map { i in
            var clip=Clip(kind:.image,name:"image \(i)",track:i,start:0,duration:1)
            clip.assetID=asset.id;clip.scale=0.6;clip.x=0.3+Double(i%4)*0.1
            if i>=4 {clip.animation=ClipAnimation(tracks:[AnimationTrack(property:.rotation,keys:[AnimationKeyframe(time:0,value:1),AnimationKeyframe(time:1,value:20)])])}
            return clip
        }
        var movingFirst=p
        movingFirst.clips=movingFirst.clips.map{clip in var changed=clip;changed.track=11-clip.track;return changed}
        for project in [p,movingFirst] {
            let optimized=FrameRenderer(useProxies:false),reference=FrameRenderer(useProxies:false)
            reference.reuseNeutralImages=false
            for r in [optimized,reference] {r.reuseStaticBackgrounds=false;r.setCacheBudget(megabytes:16)}
            for frame in 0..<4 {
                let size=CGSize(width:1280,height:720),a=try XCTUnwrap(RasterTools.bitmap(size)),b=try XCTUnwrap(RasterTools.bitmap(size))
                optimized.draw(project:project,directory:root,time:Double(frame)/30,context:a,size:size)
                reference.draw(project:project,directory:root,time:Double(frame)/30,context:b,size:size)
                let ap=Array(UnsafeBufferPointer(start:try XCTUnwrap(a.data).assumingMemoryBound(to:UInt8.self),count:a.bytesPerRow*a.height))
                let bp=Array(UnsafeBufferPointer(start:try XCTUnwrap(b.data).assumingMemoryBound(to:UInt8.self),count:b.bytesPerRow*b.height))
                XCTAssertEqual(ap,bp)
            }
            XCTAssertGreaterThan(reference.staticHits,0)
            XCTAssertEqual(optimized.staticHits,reference.staticHits)
            XCTAssertLessThanOrEqual(optimized.cacheUsage.bytes,optimized.cacheUsage.budget)
        }
    }

    func testSharedFileCacheAndAnimatedGIFProxy() throws {
        let root=try AnimatedGIFTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        let source=try XCTUnwrap(RasterTools.bitmap(CGSize(width:64,height:64)))
        source.setFillColor(NSColor.green.cgColor);source.fill(CGRect(x:0,y:0,width:64,height:64))
        try XCTUnwrap(NSBitmapImageRep(cgImage:try XCTUnwrap(source.makeImage())).representation(using:.png,properties:[:])).write(to:root.appendingPathComponent("Media/still.png"))
        var project=Project();project.width=64;project.height=64
        let first=MediaAsset(name:"first",file:"still.png",kind:.image,duration:2),second=MediaAsset(name:"second",file:"still.png",kind:.image,duration:2)
        project.assets=[first,second]
        var c=Clip(kind:.image,name:"first",track:0,start:0,duration:2);c.assetID=first.id;c.rotation=13
        c.animation=ClipAnimation(tracks:[AnimationTrack(property:.x,keys:[AnimationKeyframe(time:0,value:0.4),AnimationKeyframe(time:1,value:0.6)])])
        var d=c;d.id=UUID();d.track=1;d.assetID=second.id;project.clips=[c,d]
        func pixels(_ renderer:FrameRenderer,_ p:Project,_ time:Double)throws->[UInt8] {
            let size=CGSize(width:64,height:64),ctx=try XCTUnwrap(RasterTools.bitmap(size))
            renderer.draw(project:p,directory:root,time:time,context:ctx,size:size);ctx.flush()
            return Array(UnsafeBufferPointer(start:try XCTUnwrap(ctx.data).assumingMemoryBound(to:UInt8.self),count:ctx.bytesPerRow*ctx.height))
        }
        let cached=FrameRenderer(),reference=FrameRenderer();reference.reuseNeutralImages=false
        XCTAssertEqual(try pixels(cached,project,0.2),try pixels(reference,project,0.2))
        XCTAssertGreaterThan(cached.neutralImageHits,0) // Distinct assets resolve to the same file.

        project.assets[0].proxyFile="animation.gif";project.clips=[c]
        let proxy=FrameRenderer(useProxies:true),proxyReference=FrameRenderer(useProxies:true);proxyReference.reuseNeutralImages=false
        let early=try pixels(proxy,project,0.2),later=try pixels(proxy,project,0.7)
        XCTAssertEqual(early,try pixels(proxyReference,project,0.2))
        XCTAssertEqual(later,try pixels(proxyReference,project,0.7))
        XCTAssertNotEqual(early,later)
        XCTAssertEqual(proxy.neutralImageHits,0)
    }

    func testCacheInvalidationAndDynamicContentFallback() throws {
        let root=try AdvancedTests().folder();defer{try? FileManager.default.removeItem(at:root)}
        for (name,color) in [("red.png",NSColor.red),("blue.png",NSColor.blue)] {
            let ctx=try XCTUnwrap(RasterTools.bitmap(CGSize(width:40,height:40)))
            ctx.setFillColor(color.cgColor);ctx.fill(CGRect(x:0,y:0,width:40,height:40))
            try XCTUnwrap(NSBitmapImageRep(cgImage:try XCTUnwrap(ctx.makeImage())).representation(using:.png,properties:[:])).write(to:root.appendingPathComponent("Media/\(name)"))
        }
        var project=Project();project.width=160;project.height=90
        let media=MediaAsset(name:"still",file:"red.png",kind:.image,duration:1);project.assets=[media]
        var c=Clip(kind:.image,name:"moving",track:0,start:0,duration:2);c.assetID=media.id;c.rotation=15
        c.animation=ClipAnimation(tracks:[AnimationTrack(property:.x,keys:[AnimationKeyframe(time:0,value:0.4),AnimationKeyframe(time:1,value:0.6)])])
        project.clips=[c]
        func pixels(_ r:FrameRenderer,_ p:Project,_ time:Double,_ size:CGSize)throws->[UInt8] {
            let ctx=try XCTUnwrap(RasterTools.bitmap(size));r.draw(project:p,directory:root,time:time,context:ctx,size:size);ctx.flush()
            return Array(UnsafeBufferPointer(start:try XCTUnwrap(ctx.data).assumingMemoryBound(to:UInt8.self),count:ctx.bytesPerRow*ctx.height))
        }
        let size=CGSize(width:160,height:90),fast=FrameRenderer(),reference=FrameRenderer();reference.reuseNeutralImages=false
        for t in [0.2,0.4] {XCTAssertEqual(try pixels(fast,project,t,size),try pixels(reference,project,t,size))}
        XCTAssertGreaterThan(fast.neutralImageHits,0)
        let before=try pixels(fast,project,0.2,size)
        project.assets[0].file="blue.png"
        XCTAssertNotEqual(before,try pixels(fast,project,0.2,size))
        XCTAssertEqual(try pixels(fast,project,0.2,size),try pixels(reference,project,0.2,size))
        let smaller=CGSize(width:80,height:45)
        XCTAssertEqual(try pixels(fast,project,0.4,smaller),try pixels(reference,project,0.4,smaller))
        fast.setCacheBudget(megabytes:16)
        XCTAssertLessThanOrEqual(fast.cacheUsage.bytes,fast.cacheUsage.budget)

        var excluded:[Project]=[]
        var wipe=project;wipe.clips[0].animation?.entrance=Entrance(kind:.wipeLeft,duration:1);excluded.append(wipe)
        var mask=project;mask.clips[0].masks=[ClipMask()];excluded.append(mask)
        var effect=project;effect.clips[0].effects=[VisualEffect(kind:.blur)];excluded.append(effect)
        var slice=project;slice.clips[0].nineSlice=NineSliceSettings();excluded.append(slice)
        var parent=project;var child=Clip(kind:.shape,name:"child",track:0,start:0,duration:2);child.parentID=parent.clips[0].id;parent.clips.append(child);excluded.append(parent)
        var childProject=project;let group=Clip(kind:.group,name:"parent",track:1,start:0,duration:2);childProject.clips[0].parentID=group.id;childProject.clips.append(group);excluded.append(childProject)
        for candidate in excluded {
            let a=FrameRenderer(),b=FrameRenderer();b.reuseNeutralImages=false
            for t in [0.2,0.4] {XCTAssertEqual(try pixels(a,candidate,t,size),try pixels(b,candidate,t,size))}
            XCTAssertEqual(a.neutralImageHits,0)
        }
    }

    func testGIFAndPSDFallbackRemainAnimated() throws {
        let gifRoot=try AnimatedGIFTests().fixture(),psdRoot=try AdvancedTests().folder()
        defer{try? FileManager.default.removeItem(at:gifRoot);try? FileManager.default.removeItem(at:psdRoot)}
        var gif=AnimatedGIFTests().project(),psd=try PSDAnimationTests().fixture(psdRoot)
        gif.clips[0].rotation=10;gif.clips[0].animation=ClipAnimation(tracks:[AnimationTrack(property:.x,keys:[AnimationKeyframe(time:0,value:0.4),AnimationKeyframe(time:1,value:0.6)])])
        psd.clips[0].rotation=10;psd.clips[0].animation=gif.clips[0].animation
        for (project,root,times) in [(gif,gifRoot,[0.2,0.7]),(psd,psdRoot,[0.2,1.2])] {
            let fast=FrameRenderer(),reference=FrameRenderer();reference.reuseNeutralImages=false
            for time in times {
                let size=CGSize(width:project.width,height:project.height)
                let a=try XCTUnwrap(RasterTools.bitmap(size)),b=try XCTUnwrap(RasterTools.bitmap(size))
                fast.draw(project:project,directory:root,time:time,context:a,size:size);reference.draw(project:project,directory:root,time:time,context:b,size:size)
                let ap=Array(UnsafeBufferPointer(start:try XCTUnwrap(a.data).assumingMemoryBound(to:UInt8.self),count:a.bytesPerRow*a.height))
                let bp=Array(UnsafeBufferPointer(start:try XCTUnwrap(b.data).assumingMemoryBound(to:UInt8.self),count:b.bytesPerRow*b.height))
                XCTAssertEqual(ap,bp)
            }
            XCTAssertEqual(fast.neutralImageHits,0)
        }
    }

    func testTransformAnimatedStillMatchesAndExports() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-neutral-proto-\(UUID())"),media=root.appendingPathComponent("Media")
        try FileManager.default.createDirectory(at:media,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let source=try XCTUnwrap(RasterTools.bitmap(CGSize(width:83,height:121)))
        source.setFillColor(NSColor.orange.withAlphaComponent(0.7).cgColor);source.fill(CGRect(x:4,y:8,width:75,height:105))
        source.setFillColor(NSColor.blue.cgColor);source.fillEllipse(in:CGRect(x:17,y:24,width:39,height:47))
        let png=NSBitmapImageRep(cgImage:try XCTUnwrap(source.makeImage()))
        try XCTUnwrap(png.representation(using:.png,properties:[:])).write(to:media.appendingPathComponent("image.png"))
        var p=Project();p.width=320;p.height=180;p.fps=30
        let asset=MediaAsset(name:"still",file:"image.png",kind:.image,duration:1);p.assets=[asset]
        var c=Clip(kind:.image,name:"still",track:0,start:0,duration:1);c.assetID=asset.id
        c.animation=ClipAnimation(tracks:[
            AnimationTrack(property:.x,keys:[AnimationKeyframe(time:0,value:0.1),AnimationKeyframe(time:1,value:0.8)]),
            AnimationTrack(property:.y,keys:[AnimationKeyframe(time:0,value:0.4),AnimationKeyframe(time:1,value:0.6)]),
            AnimationTrack(property:.scale,keys:[AnimationKeyframe(time:0,value:0.7),AnimationKeyframe(time:1,value:1.5)]),
            AnimationTrack(property:.rotation,keys:[AnimationKeyframe(time:0,value:-36),AnimationKeyframe(time:1,value:44)]),
            AnimationTrack(property:.opacity,keys:[AnimationKeyframe(time:0,value:0.4),AnimationKeyframe(time:1,value:1)])])
        p.clips=[c]
        let optimized=FrameRenderer(useProxies:false),reference=FrameRenderer(useProxies:false);reference.reuseNeutralImages=false
        func pixels(_ r:FrameRenderer,_ t:Double)throws->[UInt8] {
            let ctx=try XCTUnwrap(RasterTools.bitmap(CGSize(width:320,height:180)))
            r.draw(project:p,directory:root,time:t,context:ctx,size:CGSize(width:320,height:180));ctx.flush()
            return Array(UnsafeBufferPointer(start:try XCTUnwrap(ctx.data).assumingMemoryBound(to:UInt8.self),count:ctx.bytesPerRow*ctx.height))
        }
        for frame in 0..<30 {
            let t=Double(frame)/30,a=try pixels(optimized,t),b=try pixels(reference,t)
            XCTAssertLessThanOrEqual(zip(a,b).map{abs(Int($0)-Int($1))}.max() ?? 0,2,"frame \(frame)")
        }
        XCTAssertGreaterThan(optimized.neutralImageHits,10)
        let fileA=root.appendingPathComponent("optimized.mp4"),fileB=root.appendingPathComponent("reference.mp4")
        try await MovieExporter.export(project:p,directory:root,destination:fileA,rendererOverride:optimized){_ in}
        try await MovieExporter.export(project:p,directory:root,destination:fileB,rendererOverride:reference){_ in}
        func frame(_ url:URL)throws->[UInt8] {
            let gen=AVAssetImageGenerator(asset:AVURLAsset(url:url));gen.requestedTimeToleranceBefore = .zero;gen.requestedTimeToleranceAfter = .zero
            let image=try gen.copyCGImage(at:CMTime(seconds:0.4,preferredTimescale:600),actualTime:nil)
            let ctx=try XCTUnwrap(RasterTools.bitmap(CGSize(width:320,height:180)));ctx.draw(image,in:CGRect(x:0,y:0,width:320,height:180));ctx.flush()
            return Array(UnsafeBufferPointer(start:try XCTUnwrap(ctx.data).assumingMemoryBound(to:UInt8.self),count:ctx.bytesPerRow*ctx.height))
        }
        let a=try frame(fileA),b=try frame(fileB)
        let mean=zip(a,b).reduce(0.0){$0+Double(abs(Int($1.0)-Int($1.1)))}/Double(a.count)
        XCTAssertLessThan(mean,1)
    }
}
