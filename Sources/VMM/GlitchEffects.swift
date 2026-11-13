import CoreImage
import Foundation
import Metal

/// Stateless, time-addressed effects: seeks and export render the same frame.
enum GlitchEffects {
    enum Backend {case automatic,metal,cpu}
    struct MetalKernels {
        let grain:CIColorKernel
        let chromatic:CIColorKernel
        let glitch:CIWarpKernel
    }
    /// Stitchable CI Metal is available only on devices that support dynamic libraries.
    /// Compilation is attempted once, and older devices use the CPU image processor.
    static let metalKernels:MetalKernels? = {
        guard let device=MTLCreateSystemDefaultDevice(),device.supportsDynamicLibraries else{return nil}
        let source="""
        #include <CoreImage/CoreImage.h>
        using namespace metal;
        extern "C" {
            [[stitchable]] float4 vmmGrain(coreimage::sample_t src, float amount, float scale, float seed, coreimage::destination dest) {
                float2 p = floor(dest.coord() / max(scale, 0.01f));
                float n = fract(sin(dot(p, float2(12.9898f,78.233f)) + seed * 0.137f) * 43758.5453f) - 0.5f;
                if (src.a < 0.0001f) return float4(0.0f);
                float3 rgb = clamp(src.rgb / src.a + float3(n * amount), 0.0f, 1.0f);
                return float4(rgb * src.a, src.a);
            }
            [[stitchable]] float4 vmmChromatic(coreimage::sample_t red, coreimage::sample_t center, coreimage::sample_t blue) {
                if (center.a < 0.0001f) return float4(0.0f);
                float r = red.a > 0.0001f ? red.r / red.a : 0.0f;
                float g = center.g / center.a;
                float b = blue.a > 0.0001f ? blue.b / blue.a : 0.0f;
                return float4(float3(r,g,b) * center.a, center.a);
            }
            [[stitchable]] float2 vmmGlitch(float amount, float scale, float seed, coreimage::destination dest) {
                float2 p = dest.coord();
                float band = floor(p.y / max(1.0f, 18.0f * scale));
                float r = fract(sin(band * 12.9898f + seed * 0.713f) * 43758.5453f);
                float enabled = step(0.58f, r);
                float direction = fract(sin(band * 78.233f + seed * 0.117f) * 12345.678f) * 2.0f - 1.0f;
                return p + float2(direction * enabled * amount * 42.0f * scale, 0.0f);
            }
        }
        """
        guard let kernels=try? CIKernel.kernels(withMetalString:source),
              let grain=kernels.first(where:{$0.name=="vmmGrain"}) as? CIColorKernel,
              let chromatic=kernels.first(where:{$0.name=="vmmChromatic"}) as? CIColorKernel,
              let glitch=kernels.first(where:{$0.name=="vmmGlitch"}) as? CIWarpKernel else{return nil}
        return MetalKernels(grain:grain,chromatic:chromatic,glitch:glitch)
    }()
    static func apply(_ image:CIImage,kind:EffectKind,amount:Double,time:Double,pixelScale:Double,id:UUID,extent:CGRect,backend:Backend = .automatic,failureSignal:GlitchFailureSignal? = nil)throws->CIImage {
        guard amount>0,[.filmGrain,.chromaticAberration,.glitch].contains(kind) else{return image}
        let scale=max(0.01,pixelScale)
        let stableSeed=id.uuidString.utf8.reduce(0){($0*31+Int($1))%4096}
        let frame=Int((min(86400,max(0,time))*24).rounded(.down))
        let seed=(stableSeed+frame)%65536
        if backend != .cpu,let kernels=metalKernels {
            let result:CIImage?
            switch kind {
            case .filmGrain:
                result=kernels.grain.apply(extent:extent,arguments:[image,amount,scale,Double(seed)])
            case .chromaticAberration:
                let shift=amount*scale
                let red=image.transformed(by:CGAffineTransform(translationX:shift,y:0)),blue=image.transformed(by:CGAffineTransform(translationX:-shift,y:0))
                result=kernels.chromatic.apply(extent:extent,arguments:[red,image,blue])
            case .glitch:
                let margin=ceil(amount*42*scale)+2
                result=kernels.glitch.apply(extent:extent,roiCallback:{_,rect in rect.insetBy(dx:-margin,dy:0)},image:image,arguments:[amount,scale,Double(seed)])
            default:result=image
            }
            if let result{return result}
        }
        if backend == .metal {throw VMMError.message("Metalエフェクトを使用できません。")}
        return try GlitchCPUProcessor.apply(image:image,kind:kind,amount:amount,scale:scale,seed:seed,extent:extent,failureSignal:failureSignal)
    }
}
