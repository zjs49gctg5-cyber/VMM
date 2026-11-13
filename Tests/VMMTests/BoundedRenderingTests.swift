import XCTest
import AppKit
import AVFoundation
@testable import VMM

final class BoundedRenderingTests:XCTestCase {
    func raster(_ renderer:FrameRenderer,_ project:Project,_ time:Double,directory:URL=FileManager.default.temporaryDirectory,size:CGSize?=nil)throws->CGContext {
        let size=size ?? CGSize(width:project.width,height:project.height)
        let context=try XCTUnwrap(RasterTools.bitmap(size))
        renderer.draw(project:project,directory:directory,time:time,context:context,size:size)
        return context
    }
    func bytes(_ context:CGContext)throws->[UInt8] {
        context.flush()
        return Array(UnsafeBufferPointer(start:try XCTUnwrap(context.data).assumingMemoryBound(to:UInt8.self),count:context.height*context.bytesPerRow))
    }
    func compare(_ project:Project,time:Double=0.3,directory:URL=FileManager.default.temporaryDirectory,size:CGSize?=nil,file:StaticString=#filePath,line:UInt=#line)throws {
        let fast=FrameRenderer(),reference=FrameRenderer();reference.boundedNodes=false;reference.reuseStaticBackgrounds=false
        let expected=try bytes(raster(reference,project,time,directory:directory,size:size)),actual=try bytes(raster(fast,project,time,directory:directory,size:size))
        let error=zip(expected,actual).map{abs(Int($0)-Int($1))}
        XCTAssertLessThanOrEqual(error.max() ?? 0,2,"\(project.clips.last?.name ?? "") size=\(String(describing:size)) mean=\(Double(error.reduce(0,+))/Double(error.count))",file:file,line:line)
    }
    func testAffineMatchesTheOriginalContextOperations()throws {
        var p=Project();p.width=400;p.height=300
        var c=Clip(kind:.shape,name:"affine",track:0,start:0,duration:1)
        c.x=0.63;c.y=0.27;c.rotation=37;c.scale=0.7;c.flipX=true;c.transform=Transform2D(scaleX:1.2,scaleY:0.8,skewX:12,skewY:-7)
        let ctx=try XCTUnwrap(RasterTools.bitmap(CGSize(width:1,height:1)))
        ctx.translateBy(x:c.x*400,y:c.y*300);ctx.rotate(by:37*Double.pi/180)
        ctx.concatenate(CGAffineTransform(a:1,b:tan(-7*Double.pi/180),c:tan(12*Double.pi/180),d:1,tx:0,ty:0))
        ctx.scaleBy(x:-0.7*1.2,y:0.7*0.8);ctx.translateBy(x:-200,y:-150)
        let actual=NodeRasterGeometry.affine(c,project:p),expected=ctx.ctm
        for (a,b) in zip([actual.a,actual.b,actual.c,actual.d,actual.tx,actual.ty],[expected.a,expected.b,expected.c,expected.d,expected.tx,expected.ty]) {XCTAssertEqual(a,b,accuracy:1e-9)}
    }
    func testBoundsPreserveShapeShadowsTransformsAndFrameClipping()throws {
        var p=Project();p.width=400;p.height=300;p.background="536877"
        for kind in ShapeKind.allCases {
            for configuration in 0..<4 {
                var c=Clip(kind:.shape,name:"\(kind)-\(configuration)",track:0,start:0,duration:1)
                var style=ShapeStyle();style.kind=kind;style.width=0.31;style.height=0.24;style.cornerRadius=4
                style.outline=true;style.outlineWidth=9;style.shadow=true;style.shadowBlur=8;style.shadowX = -19;style.shadowY=27;c.shapeStyle=style;c.color="CC7844"
                c.scale=[1,0.48,1.8,0.72][configuration];c.rotation=Double(configuration)*33.7;c.opacity=0.63
                c.x=[0.5,0.21,0.98,-0.08][configuration];c.y=[0.5,0.27,0.86,0.62][configuration]
                c.flipX=configuration==1;c.flipY=configuration==2;c.transform=Transform2D(scaleX:1.13,scaleY:0.86,skewX:12,skewY:-7)
                p.clips=[c];try compare(p);try compare(p,size:CGSize(width:220,height:165))
            }
        }
    }
    func testBoundsPreserveGlyphsGradientsOutlineShadowAndReveal()throws {
        var p=Project();p.width=480;p.height=300;p.background="516342"
        for alignment in TextAlignment.allCases {
            var c=Clip(kind:.text,name:alignment.rawValue,track:0,start:0,duration:2)
            c.text="日本語 ABC\nカーブと影";c.fontSize=39;c.color="FFEE99";c.scale=0.73;c.rotation=17;c.x=0.63;c.y=0.61
            var style=TextStyle();style.alignment=alignment;style.outline=true;style.outlineWidth=15;style.shadow=true;style.shadowBlur=11;style.shadowX=18;style.shadowY = -29
            style.fillGradient=TextGradient(enabled:true,endColor:"EE4488",angle:72);style.outlineGradient=TextGradient(enabled:true,endColor:"33CCEE",angle:112);c.textStyle=style
            p.clips=[c];try compare(p);try compare(p,size:CGSize(width:240,height:150))
            c.textRevealRate=8;c.animation=ClipAnimation(entrance:Entrance(kind:.wipeRight,duration:1));p.clips=[c]
            for time in [0.1,0.5,1.2] {try compare(p,time:time)}
        }
    }
    func testImageSamplingBoundsAndParentFallback()throws {
        let root=try AdvancedTests().folder();defer{try? FileManager.default.removeItem(at:root)}
        let source=try XCTUnwrap(RasterTools.bitmap(CGSize(width:83,height:121)))
        source.setFillColor(NSColor.orange.cgColor);source.fill(CGRect(x:4,y:8,width:75,height:105))
        source.setFillColor(NSColor.blue.cgColor);source.fillEllipse(in:CGRect(x:17,y:24,width:39,height:47))
        let png=NSBitmapImageRep(cgImage:try XCTUnwrap(source.makeImage())).representation(using:.png,properties:[:])
        try XCTUnwrap(png).write(to:root.appendingPathComponent("Media/image.png"))
        var p=Project();p.width=400;p.height=300
        let asset=MediaAsset(name:"image",file:"image.png",kind:.image,duration:0);p.assets=[asset]
        var c=Clip(kind:.image,name:"image",track:0,start:0,duration:1);c.assetID=asset.id;c.scale=0.42;c.x=0.77;c.y=0.37;c.rotation = -31;c.opacity=0.76;p.clips=[c]
        try compare(p,directory:root);try compare(p,directory:root,size:CGSize(width:200,height:150))
        var child=Clip(kind:.shape,name:"child",track:0,start:0,duration:1);child.parentID=c.id;child.scale=0.25;p.clips.append(child)
        try compare(p,directory:root)
        p.clips[0].masks=[ClipMask()];p.clips[0].effects=[VisualEffect(kind:.glow)];try compare(p,directory:root)
    }
    func testStaticBackgroundInvalidatesAtCutsEditsSizesAndAnimatedLayerEffects()throws {
        var p=Project();p.width=320;p.height=180
        var background=Clip(kind:.shape,name:"base",track:0,start:0,duration:2);background.scale=1.6
        var card=Clip(kind:.text,name:"card",track:1,start:0,duration:0.5);card.text="背景";card.fontSize=26
        var other=card;other.id=UUID();other.start=0.5;other.duration=1.5;other.text="切り替え"
        var motion=Clip(kind:.shape,name:"motion",track:2,start:0,duration:2);motion.scale=0.3
        motion.animation=ClipAnimation(tracks:[AnimationTrack(property:.x,keys:[AnimationKeyframe(time:0,value:0.2),AnimationKeyframe(time:2,value:0.8)])])
        p.clips=[background,card,other,motion]
        let fast=FrameRenderer(),reference=FrameRenderer();reference.boundedNodes=false;reference.reuseStaticBackgrounds=false
        for time in [0.1,0.2,0.4,0.5,0.8,0.1] {
            let a=try bytes(raster(fast,p,time)),b=try bytes(raster(reference,p,time))
            XCTAssertLessThanOrEqual(zip(a,b).map{abs(Int($0)-Int($1))}.max() ?? 0,2)
        }
        XCTAssertGreaterThan(fast.backgroundHits,0);XCTAssertGreaterThan(fast.boundedNodeRenders,0)
        let beforeEdit=try bytes(raster(fast,p,0.2))
        p.clips[0].color="EEFFCC";try compare(p,time:0.2)
        let actual=try bytes(raster(fast,p,0.2)),expected=try bytes(raster(reference,p,0.2));XCTAssertTrue(actual != beforeEdit,"Background edit did not invalidate the raster");XCTAssertLessThanOrEqual(zip(actual,expected).map{abs(Int($0)-Int($1))}.max() ?? 0,2)
        _=try raster(fast,p,0.2,size:CGSize(width:160,height:90));XCTAssertLessThanOrEqual(fast.cacheUsage.bytes,fast.cacheUsage.budget)
        var effect=VisualEffect(kind:.brightness);effect.keys=[AnimationKeyframe(time:0,value:-0.5),AnimationKeyframe(time:1,value:0.5)];p.tracks[0].effects=[effect]
        for time in [0.1,0.8] {try compare(p,time:time)}
    }
    func testDiscretePSDStatesReuseAndSeekWithoutFreezingExpressions()throws {
        let root=try AdvancedTests().folder();defer{try? FileManager.default.removeItem(at:root)}
        var p=try PSDAnimationTests().fixture(root);p.clips[0].scale=0.67;p.clips[0].x=0.61;p.clips[0].y=0.37
        let fast=FrameRenderer(),reference=FrameRenderer();reference.boundedNodes=false;reference.reuseStaticBackgrounds=false
        var colors:[[UInt8]]=[]
        for time in [0.2,0.3,1.1,1.2,2.1,1.1,0.2] {
            let a=try bytes(raster(fast,p,time,directory:root)),b=try bytes(raster(reference,p,time,directory:root))
            XCTAssertLessThanOrEqual(zip(a,b).map{abs(Int($0)-Int($1))}.max() ?? 0,2);colors.append(a)
        }
        XCTAssertGreaterThanOrEqual(fast.staticHits,5);XCTAssertTrue(colors[0] != colors[2]);XCTAssertTrue(colors[2]==colors[5]);XCTAssertTrue(colors[0]==colors[6])
        fast.setCacheBudget(megabytes:16);XCTAssertLessThanOrEqual(fast.cacheUsage.bytes,fast.cacheUsage.budget)
    }
    func testBoundedMP4MatchesPreview()async throws {
        let root=try AdvancedTests().folder();defer{try? FileManager.default.removeItem(at:root)}
        var p=Project();p.width=320;p.height=180
        var bg=Clip(kind:.shape,name:"background",track:0,start:0,duration:1);bg.color="647893";bg.scale=2
        var text=Clip(kind:.text,name:"caption",track:1,start:0,duration:1);text.text="描画の最適化";text.fontSize=22;text.scale=0.83;text.x=0.58;text.rotation=12
        text.animation=ClipAnimation(tracks:[AnimationTrack(property:.y,keys:[AnimationKeyframe(time:0,value:0.3),AnimationKeyframe(time:1,value:0.7)])]);p.clips=[bg,text]
        let output=root.appendingPathComponent("bounded.mp4");try await MovieExporter.export(project:p,directory:root,destination:output){_ in}
        let generator=AVAssetImageGenerator(asset:AVURLAsset(url:output));generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
        let image=try generator.copyCGImage(at:CMTime(seconds:0.4,preferredTimescale:600),actualTime:nil)
        let movie=try XCTUnwrap(RasterTools.bitmap(CGSize(width:320,height:180)));movie.draw(image,in:CGRect(x:0,y:0,width:320,height:180))
        let actual=try bytes(movie),preview=try bytes(raster(FrameRenderer(),p,0.4,directory:root))
        let mean=zip(actual,preview).reduce(0.0){$0+Double(abs(Int($1.0)-Int($1.1)))}/Double(actual.count)
        XCTAssertLessThan(mean,10)
    }
}
