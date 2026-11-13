import XCTest
import AppKit
import AVFoundation
@testable import VMM

final class RenderOptimizationTests:XCTestCase {
    func project()->Project {
        var p=Project();p.width=320;p.height=180;p.background="294857"
        for i in 0..<5 {
            var c=Clip(kind:.shape,name:"pattern",track:0,start:0,duration:1)
            c.color=i%2==0 ? "FF4455":"2266EE";c.x=0.1+Double(i)*0.2;c.scale=0.3;c.rotation=Double(i)*20;p.clips.append(c)
        };return p
    }
    func render(_ renderer:FrameRenderer,_ p:Project,_ time:Double=0.2)throws->CGContext {
        let c=try XCTUnwrap(RasterTools.bitmap(CGSize(width:p.width,height:p.height)))
        renderer.draw(project:p,directory:FileManager.default.temporaryDirectory,time:time,context:c,size:CGSize(width:p.width,height:p.height));return c
    }
    func bytes(_ c:CGContext)throws->[UInt8] {Array(UnsafeBufferPointer(start:try XCTUnwrap(c.data).assumingMemoryBound(to:UInt8.self),count:c.bytesPerRow*c.height))}
    func testPartialAdjustmentsMatchFullPipelineIncludingEdges()throws {
        for shape in AdjustmentShape.allCases {for kind in [EffectKind.pixelate,.blur,.vignette,.invert] {for mode in [CompositeMode.normal,.screen,.multiply] {
            var p=project(),a=Clip(kind:.adjustment,name:"region",track:1,start:0,duration:1)
            a.adjustmentRegion=AdjustmentRegion(shape:shape,width:0.37,height:0.44);a.effects=[VisualEffect(kind:kind)];a.rotation=31;a.x=0.8;a.y=0.7;a.opacity=0.65;a.blendMode=mode;p.clips.append(a)
            let optimized=FrameRenderer(),reference=FrameRenderer();reference.partialAdjustments=false
            let actual=try bytes(render(optimized,p)),expected=try bytes(render(reference,p))
            let maxError=zip(actual,expected).map{abs(Int($0)-Int($1))}.max() ?? 0
            XCTAssertLessThanOrEqual(maxError,2,"\(shape) \(kind) \(mode)")
        }}}
    }
    func testStaticReuseInvalidatesOnEditsAndExcludesAnimation()throws {
        var p=project();let renderer=FrameRenderer();renderer.reuseStaticBackgrounds=false
        let first=try bytes(render(renderer,p));_=try render(renderer,p,0.4);XCTAssertEqual(renderer.staticHits,5)
        p.clips[0].color="11FF22";let edited=try bytes(render(renderer,p));XCTAssertNotEqual(first,edited);XCTAssertEqual(renderer.staticHits,5)
        p.clips[0].animation=ClipAnimation(tracks:[AnimationTrack(property:.rotation,keys:[AnimationKeyframe(time:0,value:0),AnimationKeyframe(time:1,value:90)])])
        let a=try bytes(render(renderer,p,0.1)),b=try bytes(render(renderer,p,0.6));XCTAssertNotEqual(a,b);XCTAssertEqual(renderer.staticHits,9)
        renderer.setCacheBudget(megabytes:16);XCTAssertLessThanOrEqual(renderer.cacheUsage.bytes,renderer.cacheUsage.budget)
        let noReuse=FrameRenderer();noReuse.reuseStaticLayers=false
        XCTAssertEqual(b,try bytes(render(noReuse,p,0.6)))
    }
    func testPartialAdjustmentBenchmark()throws {
        guard let output=ProcessInfo.processInfo.environment["VMM_PARTIAL_BENCHMARK"] else{throw XCTSkip("Optional render benchmark")}
        var p=project();p.width=1920;p.height=1080
        for i in 0..<8 {
            var a=Clip(kind:.adjustment,name:"mosaic",track:i+1,start:0,duration:1)
            a.effects=[VisualEffect(kind:.pixelate)];a.adjustmentRegion=AdjustmentRegion(width:0.2,height:0.2);p.clips.append(a)
        }
        p.tracks=(0..<9).map{Track(name:"Layer \($0)")}
        var result:[String:Double]=[:]
        for optimized in [false,true] {
            let renderer=FrameRenderer();renderer.partialAdjustments=optimized;renderer.reuseStaticLayers=optimized
            var samples:[Double]=[]
            for i in 0..<12 {
                let begin=ProcessInfo.processInfo.systemUptime;_=try render(renderer,p,Double(i)/30)
                if i>1{samples.append((ProcessInfo.processInfo.systemUptime-begin)*1000)}
            }
            result[optimized ? "optimizedMedianMS":"referenceMedianMS"]=samples.sorted()[samples.count/2]
        }
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:output),options:.withoutOverwriting)
        print("Partial adjustment benchmark: \(result)")
    }
    func testPartialAdjustmentMP4MatchesPreviewAndVideoPrefetch()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-render-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        var p=project(),a=Clip(kind:.adjustment,name:"region",track:1,start:0,duration:1)
        a.effects=[VisualEffect(kind:.pixelate)];a.adjustmentRegion=AdjustmentRegion(shape:.ellipse,width:0.4,height:0.5);a.rotation=23;p.clips.append(a)
        let output=root.appendingPathComponent("region.mp4");try await MovieExporter.export(project:p,directory:root,destination:output){_ in}
        let generator=AVAssetImageGenerator(asset:AVURLAsset(url:output));generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
        let stamp=CMTime(seconds:0.2,preferredTimescale:600),image=try generator.copyCGImage(at:stamp,actualTime:nil)
        let movie=try XCTUnwrap(RasterTools.bitmap(CGSize(width:320,height:180)));movie.draw(image,in:CGRect(x:0,y:0,width:320,height:180))
        let actual=try bytes(movie),expected=try bytes(render(FrameRenderer(),p))
        let mean=zip(actual,expected).reduce(0.0){$0+Double(abs(Int($1.0)-Int($1.1)))}/Double(actual.count)
        XCTAssertLessThan(mean,10) // H.264 quantization and Rec.709/sRGB conversion
        let prefetch=VideoPrefetch(),size=CGSize(width:320,height:180)
        prefetch.request(path:output,size:size,times:[stamp]);
        for _ in 0..<200 {if prefetch.pendingCount==0{break};try await Task.sleep(nanoseconds:10_000_000)}
        let cached=try XCTUnwrap(prefetch.image(path:output,size:size,time:stamp));XCTAssertEqual(cached.width,image.width)
        XCTAssertNil(prefetch.image(path:output,size:size,time:CMTime(seconds:0.5,preferredTimescale:600)))
        prefetch.clear();XCTAssertEqual(prefetch.bytes,0);XCTAssertNil(prefetch.image(path:output,size:size,time:stamp))
        prefetch.setBudget(1);prefetch.request(path:output,size:size,times:[stamp]);XCTAssertEqual(prefetch.pendingCount,0)
    }
}
