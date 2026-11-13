import XCTest
import AppKit
import CoreImage
@testable import VMM

final class GlitchBackendTests:XCTestCase {
    func testOptionalCPUCombinedPerformance()throws {
        guard ProcessInfo.processInfo.environment["VMM_GLITCH_CPU_CHAIN"]=="1" else {throw XCTSkip("Optional CPU chain benchmark")}
        let context=CIContext(options:[.cacheIntermediates:false]),id=UUID(uuidString:"A58B4149-77EE-47C5-827C-D8E21A5AB807")!
        for size in [CGSize(width:1920,height:1080),CGSize(width:3840,height:2160)] {
            let extent=CGRect(origin:.zero,size:size),source=CIImage(color:CIColor(red:0.4,green:0.5,blue:0.6,alpha:1)).cropped(to:extent)
            let start=ProcessInfo.processInfo.systemUptime,signal=GlitchFailureSignal();var image=source
            for kind in [EffectKind.glitch,.chromaticAberration,.filmGrain] {
                image=try GlitchEffects.apply(image,kind:kind,amount:kind == .chromaticAberration ? 8:0.8,time:0.25,pixelScale:1,id:id,extent:extent,backend:.cpu,failureSignal:signal)
            }
            _=try XCTUnwrap(context.createCGImage(image,from:extent));XCTAssertNil(signal.error)
            print(String(format:"GLITCH CPU CHAIN %.0fx%.0f %.1f ms",size.width,size.height,(ProcessInfo.processInfo.systemUptime-start)*1000))
            let bitmap=try XCTUnwrap(RasterTools.bitmap(size));bitmap.setFillColor(NSColor.gray.cgColor);bitmap.fill(extent)
            let sourceImage=try XCTUnwrap(bitmap.makeImage())
            let renderer=EffectRenderer(glitchFilter:{ image,kind,amount,time,scale,id,extent,signal in
                try GlitchEffects.apply(image,kind:kind,amount:amount,time:time,pixelScale:scale,id:id,extent:extent,backend:.cpu,failureSignal:signal)
            })
            let effects=[VisualEffect(kind:.glitch),VisualEffect(kind:.chromaticAberration),VisualEffect(kind:.filmGrain)]
            let fullStart=ProcessInfo.processInfo.systemUptime
            _=renderer.apply(sourceImage,effects:effects,time:0.25,pixelScale:1);XCTAssertNil(renderer.failure)
            print(String(format:"GLITCH CPU RENDERER %.0fx%.0f %.1f ms",size.width,size.height,(ProcessInfo.processInfo.systemUptime-fullStart)*1000))
        }
    }
    func testExplicitCPUBackendPreservesTransparencyAndChangesPixels()throws {
        let source=try GlitchEffectsTests().source(),input=CIImage(cgImage:source),context=CIContext(options:[.cacheIntermediates:false])
        let original=try GlitchEffectsTests().pixels(source)
        for kind in [EffectKind.glitch,.chromaticAberration,.filmGrain] {
            let signal=GlitchFailureSignal(),amount=kind == .chromaticAberration ? 8.0:0.8
            let result=try GlitchEffects.apply(input,kind:kind,amount:amount,time:0.25,pixelScale:1,id:UUID(uuidString:"A58B4149-77EE-47C5-827C-D8E21A5AB807")!,extent:input.extent,backend:.cpu,failureSignal:signal)
            let output=try XCTUnwrap(context.createCGImage(result,from:input.extent));XCTAssertNil(signal.error)
            let pixels=try GlitchEffectsTests().pixels(output)
            XCTAssertNotEqual(pixels,original);XCTAssertEqual(pixels[3],0)
        }
    }
    func testExplicitMetalBackendIfSupported()throws {
        guard GlitchEffects.metalKernels != nil else {throw XCTSkip("Device lacks stitchable Metal CI kernels")}
        let source=try GlitchEffectsTests().source(),input=CIImage(cgImage:source),context=CIContext()
        for kind in [EffectKind.glitch,.chromaticAberration,.filmGrain] {
            let result=try GlitchEffects.apply(input,kind:kind,amount:0.8,time:0.25,pixelScale:1,id:UUID(),extent:input.extent,backend:.metal)
            XCTAssertNotNil(context.createCGImage(result,from:input.extent))
        }
    }
}
