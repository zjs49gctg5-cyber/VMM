import XCTest
import AppKit
import AVFoundation
@testable import VMM

final class GlitchEffectsTests:XCTestCase {
    func source()throws->CGImage {
        let c=try XCTUnwrap(RasterTools.bitmap(CGSize(width:160,height:90)))
        c.setFillColor(NSColor.gray.cgColor);c.fill(CGRect(x:10,y:10,width:140,height:70))
        c.setFillColor(NSColor.red.cgColor);c.fill(CGRect(x:35,y:20,width:40,height:45))
        c.setFillColor(NSColor.blue.cgColor);c.fill(CGRect(x:90,y:25,width:30,height:30))
        return try XCTUnwrap(c.makeImage())
    }
    func pixels(_ image:CGImage)throws->[UInt8] {
        let c=try XCTUnwrap(RasterTools.bitmap(CGSize(width:image.width,height:image.height)))
        c.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height));return try AdvancedTests().pixels(c)
    }
    func testNewEffectsDeterministicAndTransparent()throws {
        let source=try source(),engine=EffectRenderer(),original=try pixels(source)
        for kind in [EffectKind.glitch,.chromaticAberration,.filmGrain] {
            var effect=VisualEffect(kind:kind);effect.id=UUID(uuidString:"B7233D31-36AA-4576-9937-4BFF75641C2A")!;effect.amount=kind == .chromaticAberration ? 8:0.8
            let first=engine.apply(source,effects:[effect],time:0.25,pixelScale:1)
            let repeatImage=engine.apply(source,effects:[effect],time:0.25,pixelScale:1)
            XCTAssertTrue(try pixels(first)==pixels(repeatImage),"\(kind)")
            XCTAssertTrue(try pixels(first) != original,"Effect should change the image: \(kind)")
            let data=try pixels(first);XCTAssertEqual(data[3],0,"Transparent corner should remain transparent: \(kind)")
            if kind.timeVarying {XCTAssertTrue(try data != pixels(engine.apply(source,effects:[effect],time:0.5,pixelScale:1)),"\(kind)")}
            effect.amount=0;XCTAssertTrue(try pixels(engine.apply(source,effects:[effect],time:0.25,pixelScale:1)) == original)
        }
    }
    func testFrameCacheSeekPartialAndKeyframes()throws {
        var p=Project();p.width=320;p.height=180;p.background="000000"
        var shape=Clip(kind:.shape,name:"source",track:0,start:0,duration:2);shape.color="808080";shape.scale=3
        var grain=VisualEffect(kind:.filmGrain);grain.amount=0.8;shape.effects=[grain];p.clips=[shape]
        let renderer=FrameRenderer()
        func render(_ project:Project,_ time:Double,_ renderer:FrameRenderer)throws->[UInt8] {
            let c=try XCTUnwrap(RasterTools.bitmap(CGSize(width:320,height:180)));renderer.draw(project:project,directory:FileManager.default.temporaryDirectory,time:time,context:c,size:CGSize(width:320,height:180));return try AdvancedTests().pixels(c)
        }
        let first=try render(p,0.25,renderer),next=try render(p,0.5,renderer);XCTAssertTrue(first != next);XCTAssertTrue(try first == render(p,0.25,renderer))
        shape.effects=nil;p.clips=[shape];var adjustment=Clip(kind:.adjustment,name:"partial",track:1,start:0,duration:2)
        grain.keys=[AnimationKeyframe(time:0,value:0,easing:.linear),AnimationKeyframe(time:1,value:0.8,easing:.linear)]
        adjustment.effects=[grain];adjustment.adjustmentRegion=AdjustmentRegion(width:0.4,height:0.4);p.clips.append(adjustment)
        let fast=FrameRenderer(),slow=FrameRenderer();slow.partialAdjustments=false
        let optimized=try render(p,0.5,fast),reference=try render(p,0.5,slow)
        let maxError=zip(optimized,reference).map{abs(Int($0)-Int($1))}.max() ?? 0
        XCTAssertLessThanOrEqual(maxError,2,"Partial region must match full rendering")
        XCTAssertTrue(try render(p,0,fast) != render(p,1,fast),"Keyframed strength must affect output")
        XCTAssertEqual(try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(p)).validated(),p)
        p.clips.removeLast();p.tracks[0].effects=[VisualEffect(kind:.filmGrain)]
        XCTAssertTrue(try render(p,0.25,renderer) != render(p,0.5,renderer))
    }
    func testNoiseActualMP4()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-grain-export-\(UUID())");try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        var p=Project();p.width=320;p.height=180;p.background="000000"
        var shape=Clip(kind:.shape,name:"source",track:0,start:0,duration:0.5);shape.color="808080";shape.scale=3;var grain=VisualEffect(kind:.filmGrain);grain.amount=0.8;shape.effects=[grain];p.clips=[shape]
        let output=root.appendingPathComponent("grain.mp4");try await MovieExporter.export(project:p,directory:root,destination:output){_ in}
        let generator=AVAssetImageGenerator(asset:AVURLAsset(url:output));generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
        let first=try generator.copyCGImage(at:CMTime(seconds:0.1,preferredTimescale:600),actualTime:nil),second=try generator.copyCGImage(at:CMTime(seconds:0.3,preferredTimescale:600),actualTime:nil)
        XCTAssertTrue(try pixels(first) != pixels(second))
    }
    func testEveryEffectActualMP4()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-effects-export-\(UUID())");try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        var p=Project();p.width=320;p.height=180;p.background="000000"
        var shape=Clip(kind:.shape,name:"source",track:0,start:0,duration:0.5);shape.color="FFAA88";shape.scale=1;p.clips=[shape]
        // Glitch deliberately displaces only selected bands, so a given frame
        // can legitimately be unchanged. Compare several times in the actual
        // movie against a static baseline, with a fixed effect seed.
        func frames(_ p:Project,_ name:String) async throws ->[[UInt8]] {
            let url=root.appendingPathComponent(name+".mp4");try await MovieExporter.export(project:p,directory:root,destination:url){_ in}
            let generator=AVAssetImageGenerator(asset:AVURLAsset(url:url));generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
            return try [0.1,0.2,0.3,0.4].map {try pixels(generator.copyCGImage(at:CMTime(seconds:$0,preferredTimescale:600),actualTime:nil))}
        }
        let baseline=try await frames(p,"baseline")
        let unchanged=try await frames(p,"unchanged")
        func maximumMeanDifference(_ a:[[UInt8]],_ b:[[UInt8]])->Double {
            XCTAssertEqual(a.count,b.count)
            return zip(a,b).map { left,right in
                XCTAssertEqual(left.count,right.count)
                guard left.count==right.count,!left.isEmpty else{return Double.infinity}
                return Double(zip(left,right).reduce(0){$0+abs(Int($1.0)-Int($1.1))})/Double(left.count)
            }.max() ?? .infinity
        }
        // AVFoundation's H.264 output is not byte deterministic. A small mean
        // difference is allowed, but effect signals must exceed both a fixed
        // floor and the measured noise of two unchanged exports.
        let baselineNoise=maximumMeanDifference(unchanged,baseline)
        XCTAssertLessThanOrEqual(baselineNoise,0.25,"Unchanged exports should remain visually equivalent")
        for kind in [EffectKind.glitch,.chromaticAberration,.filmGrain] {
            var effect=VisualEffect(kind:kind);effect.id=UUID(uuidString:"B7233D31-36AA-4576-9937-4BFF75641C2A")!;effect.amount=kind == .chromaticAberration ? 12:1
            effect.enabled=false;p.clips[0].effects=[effect]
            let disabled=try await frames(p,kind.rawValue+"-disabled")
            let disabledNoise=maximumMeanDifference(disabled,baseline)
            XCTAssertLessThanOrEqual(disabledNoise,0.25,"Disabled \(kind) must match the baseline within encoding tolerance")
            effect.enabled=true;p.clips[0].effects=[effect]
            let processed=try await frames(p,kind.rawValue)
            let signal=maximumMeanDifference(processed,baseline),threshold=max(0.5,5*max(baselineNoise,disabledNoise))
            XCTAssertGreaterThan(signal,threshold,"\(kind) must change the movie beyond encoding noise")
        }
    }
    func testOptional1080pPerformance()throws {
        guard ProcessInfo.processInfo.environment["VMM_GLITCH_BENCHMARK"]=="1" else{throw XCTSkip("Opt-in effect benchmark")}
        var p=Project();p.width=1920;p.height=1080;p.background="000000"
        var shape=Clip(kind:.shape,name:"performance",track:0,start:0,duration:3);shape.color="808080";shape.scale=3;p.clips=[shape]
        func run(_ project:Project)throws->Double {
            let renderer=FrameRenderer(),size=CGSize(width:1920,height:1080)
            func draw(_ t:Double)throws {let c=try XCTUnwrap(RasterTools.bitmap(size));renderer.draw(project:project,directory:FileManager.default.temporaryDirectory,time:t,context:c,size:size);_=c.makeImage()}
            try draw(0);let start=ProcessInfo.processInfo.systemUptime
            for i in 1...5 {try draw(Double(i)/30)}
            return (ProcessInfo.processInfo.systemUptime-start)/5*1000
        }
        let baseline=try run(p);p.clips[0].effects=[VisualEffect(kind:.glitch),VisualEffect(kind:.chromaticAberration),VisualEffect(kind:.filmGrain)]
        let all=try run(p);print(String(format:"GLITCH BENCHMARK 1080p baseline %.1f ms/frame, three effects %.1f ms/frame",baseline,all))
    }
}
