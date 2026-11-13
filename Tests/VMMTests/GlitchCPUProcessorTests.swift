import XCTest
import CoreImage
import AppKit
@testable import VMM

final class GlitchCPUProcessorTests:XCTestCase {
    #if DEBUG
    func testProcessorFailureSignalsAreIsolated()throws {
        let source=try GlitchEffectsTests().source(),image=CIImage(cgImage:source),context=CIContext(options:[.cacheIntermediates:false])
        let failed=GlitchFailureSignal(),ok=GlitchFailureSignal()
        let broken=try GlitchCPUProcessor.failureForTesting(image:image,extent:image.extent,signal:failed)
        _=context.createCGImage(broken,from:image.extent)
        XCTAssertNotNil(failed.error,"Processor failure must be observable even when Core Image returns an image")
        let normal=try GlitchCPUProcessor.apply(image:image,kind:.filmGrain,amount:0.4,scale:1,seed:123,extent:image.extent,failureSignal:ok)
        XCTAssertNotNil(context.createCGImage(normal,from:image.extent));XCTAssertNil(ok.error)
    }
    func testConcurrentProcessorFailureSignalsDoNotMix()throws {
        let source=try GlitchEffectsTests().source(),image=CIImage(cgImage:source),context=CIContext(options:[.cacheIntermediates:false])
        let signals=(0..<12).map{_ in GlitchFailureSignal()},lock=NSLock();var setupErrors:[String]=[]
        DispatchQueue.concurrentPerform(iterations:signals.count) {index in
            do {
                let result:CIImage
                if index%2 == 0 {result=try GlitchCPUProcessor.failureForTesting(image:image,extent:image.extent,signal:signals[index])}
                else {result=try GlitchCPUProcessor.apply(image:image,kind:.chromaticAberration,amount:8,scale:1,seed:index,extent:image.extent,failureSignal:signals[index])}
                _=context.createCGImage(result,from:image.extent)
            } catch {lock.lock();setupErrors.append(error.localizedDescription);lock.unlock()}
        }
        XCTAssertTrue(setupErrors.isEmpty)
        for i in signals.indices {XCTAssertEqual(signals[i].error != nil,i%2 == 0,"render \(i)")}
    }
    #endif
    private func render(_ image:CIImage,kind:EffectKind,amount:Double,seed:Int,extent:CGRect)throws->CGImage {
        let result=try GlitchCPUProcessor.apply(image:image,kind:kind,amount:amount,scale:1,seed:seed,extent:extent)
        return try XCTUnwrap(CIContext(options:[.cacheIntermediates:false]).createCGImage(result,from:extent))
    }
    func testCPUFallbackIsDeterministicAndPreservesAlpha()throws {
        let source=try GlitchEffectsTests().source(),image=CIImage(cgImage:source),extent=image.extent
        for kind in [EffectKind.glitch,.chromaticAberration,.filmGrain] {
            let amount=kind == .chromaticAberration ? 8.0:0.8
            let first=try render(image,kind:kind,amount:amount,seed:139,extent:extent)
            let second=try render(image,kind:kind,amount:amount,seed:139,extent:extent)
            let a=try GlitchEffectsTests().pixels(first),b=try GlitchEffectsTests().pixels(second)
            XCTAssertEqual(a,b,"\(kind)");XCTAssertEqual(a[3],0,"\(kind)")
            XCTAssertNotEqual(a,try GlitchEffectsTests().pixels(source),"\(kind) must alter pixels")
        }
    }
    func testTileAndFullFrameMatch()throws {
        let source=try GlitchEffectsTests().source(),image=CIImage(cgImage:source),extent=image.extent,region=CGRect(x:23,y:14,width:83,height:52)
        for kind in [EffectKind.glitch,.chromaticAberration,.filmGrain] {
            let amount=kind == .chromaticAberration ? 8.0:0.8
            let full=try render(image,kind:kind,amount:amount,seed:139,extent:extent)
            let part=try render(image,kind:kind,amount:amount,seed:139,extent:region)
            let expected=try XCTUnwrap(full.cropping(to:CGRect(x:region.minX,y:extent.height-region.maxY,width:region.width,height:region.height)))
            let p=try GlitchEffectsTests().pixels(part),e=try GlitchEffectsTests().pixels(expected)
            XCTAssertTrue(p==e,"Tile must match full render: \(kind)")
        }
    }
    func testCPUAndMetalProduceComparableFrames()throws {
        guard GlitchEffects.metalKernels != nil else{throw XCTSkip("Stitchable Metal is unavailable on this GPU")}
        let source=try GlitchEffectsTests().source(),image=CIImage(cgImage:source),context=CIContext(options:[.cacheIntermediates:false])
        let id=UUID(uuidString:"A58B4149-77EE-47C5-827C-D8E21A5AB807")!,time=0.5
        let base=id.uuidString.utf8.reduce(0){($0*31+Int($1))%4096},seed=(base+Int(time*24))%65536
        for kind in [EffectKind.glitch,.chromaticAberration,.filmGrain] {
            let amount=kind == .chromaticAberration ? 8.0:0.8
            let cpu=try render(image,kind:kind,amount:amount,seed:seed,extent:image.extent)
            let metalImage=try GlitchEffects.apply(image,kind:kind,amount:amount,time:time,pixelScale:1,id:id,extent:image.extent,backend:.metal)
            let metal=try XCTUnwrap(context.createCGImage(metalImage,from:image.extent))
            let actual=try GlitchEffectsTests().pixels(cpu),expected=try GlitchEffectsTests().pixels(metal)
            let mean=zip(actual,expected).reduce(0.0){$0+Double(abs(Int($1.0)-Int($1.1)))}/Double(actual.count)
            XCTAssertLessThan(mean,kind == .filmGrain ? 12:2,"CPU vs Metal: \(kind)")
        }
    }
    func testComparePreviousKernelReferenceIfAvailable()throws {
        guard let folder=ProcessInfo.processInfo.environment["VMM_GLITCH_REFERENCE_DIR"] else{throw XCTSkip("Optional reference comparison")}
        let root=URL(fileURLWithPath:folder),source=try GlitchEffectsTests().source(),image=CIImage(cgImage:source)
        let id=UUID(uuidString:"A58B4149-77EE-47C5-827C-D8E21A5AB807")!,base=id.uuidString.utf8.reduce(0){($0*31+Int($1))%4096}
        for kind in [EffectKind.glitch,.chromaticAberration,.filmGrain] {for time in [0.25,0.5] {
            let seed=(base+Int(time*24))%65536,amount=kind == .chromaticAberration ? 8.0:0.8
            let actual=try render(image,kind:kind,amount:amount,seed:seed,extent:image.extent)
            let data=try Data(contentsOf:root.appendingPathComponent("\(kind.rawValue)-\(time).png")),bitmap=try XCTUnwrap(NSBitmapImageRep(data:data)),expected=try XCTUnwrap(bitmap.cgImage)
            let a=try GlitchEffectsTests().pixels(actual),b=try GlitchEffectsTests().pixels(expected)
            let mean=zip(a,b).reduce(0.0){$0+Double(abs(Int($1.0)-Int($1.1)))}/Double(a.count)
            print("CPU MIGRATION \(kind) t=\(time) MAE=\(mean)")
            // Per-pixel sin results differ across CPU/GPU, so test grain's distribution
            // rather than requiring an identical pseudo-random texture.
            if kind == .filmGrain {
                let original=try GlitchEffectsTests().pixels(source)
                var gray:[Int]=[]
                for index in stride(from:0,to:original.count,by:4) {
                    let value=Int(original[index])
                    if original[index+3]==255 && value>=120 && value<=136 && original[index]==original[index+1] && original[index]==original[index+2] {gray.append(index)}
                }
                func stats(_ values:[UInt8])->(Double,Double) {
                    var sum=0.0;for index in gray {sum+=Double(values[index])}
                    let mean=sum/Double(gray.count)
                    var squares=0.0;for index in gray {let delta=Double(values[index])-mean;squares+=delta*delta}
                    let variance=squares/Double(gray.count)
                    return(mean,sqrt(variance))
                }
                XCTAssertFalse(gray.isEmpty);let aStats=stats(a),bStats=stats(b)
                print("CPU GRAIN STATS actual=\(aStats) prior=\(bStats)")
                XCTAssertLessThan(abs(aStats.0-bStats.0),3);XCTAssertLessThan(abs(aStats.1-bStats.1),3)
            } else {XCTAssertLessThan(mean,1,"CPU fallback differs too much: \(kind)")}
        }}
    }
    func testOptionalPerformance1080And4K()throws {
        guard ProcessInfo.processInfo.environment["VMM_GLITCH_CPU_BENCHMARK"]=="1" else{throw XCTSkip("Optional CPU benchmark")}
        let context=CIContext(options:[.cacheIntermediates:false])
        for dimensions in [(1920,1080),(3840,2160)] {
            let extent=CGRect(x:0,y:0,width:dimensions.0,height:dimensions.1),image=CIImage(color:CIColor(red:0.4,green:0.5,blue:0.6,alpha:1)).cropped(to:extent)
            for kind in [EffectKind.glitch,.chromaticAberration,.filmGrain] {
                let amount=kind == .chromaticAberration ? 8.0:0.8
                let start=ProcessInfo.processInfo.systemUptime
                let output=try GlitchCPUProcessor.apply(image:image,kind:kind,amount:amount,scale:1,seed:139,extent:extent)
                _=try XCTUnwrap(context.createCGImage(output,from:extent))
                print("CPU BENCHMARK \(dimensions.0)x\(dimensions.1) \(kind): \((ProcessInfo.processInfo.systemUptime-start)*1000) ms")
            }
        }
    }
}
