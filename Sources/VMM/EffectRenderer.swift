import AppKit
import CoreImage

final class EffectRenderer {
    typealias GlitchFilter = (CIImage,EffectKind,Double,Double,Double,UUID,CGRect,GlitchFailureSignal) throws -> CIImage
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var keyCubes: [String: Data] = [:]
    private let glitchFilter:GlitchFilter
    private let cpuGlitchFilter:GlitchFilter
    private let rasterizeOverride:((CIImage,CGRect)->CGImage?)?
    private(set) var failure:String?
    init(glitchFilter:@escaping GlitchFilter = {image,kind,amount,time,scale,id,extent,signal in try GlitchEffects.apply(image,kind:kind,amount:amount,time:time,pixelScale:scale,id:id,extent:extent,failureSignal:signal)},cpuGlitchFilter:@escaping GlitchFilter = {image,kind,amount,time,scale,id,extent,signal in try GlitchEffects.apply(image,kind:kind,amount:amount,time:time,pixelScale:scale,id:id,extent:extent,backend:.cpu,failureSignal:signal)},rasterizeOverride:((CIImage,CGRect)->CGImage?)?=nil) {self.glitchFilter=glitchFilter;self.cpuGlitchFilter=cpuGlitchFilter;self.rasterizeOverride=rasterizeOverride}
    func beginFrame() {failure=nil}
    private func record(_ error:Error) {if failure == nil {failure=error.localizedDescription}}
    private func rasterize(_ image:CIImage,from rect:CGRect,checked:Bool)->CGImage? {
        if let rasterizeOverride{return rasterizeOverride(image,rect)}
        guard checked else{return context.createCGImage(image,from:rect)}
        // createCGImage may return a blank image after a deferred processor error.
        // CIRenderTask reports that error and permits a reliable CPU retry.
        guard rect.width>0,rect.height>0,let bitmap=RasterTools.bitmap(rect.size),let data=bitmap.data else{return nil}
        let destination=CIRenderDestination(bitmapData:data,width:bitmap.width,height:bitmap.height,bytesPerRow:bitmap.bytesPerRow,format:.RGBA8)
        destination.colorSpace=CGColorSpaceCreateDeviceRGB();destination.alphaMode = .premultiplied
        do {let task=try context.startTask(toRender:image,from:rect,to:destination,at:.zero);_ = try task.waitUntilCompleted();return bitmap.makeImage()}catch{return nil}
    }
    private func hasGlitch(_ effects:[VisualEffect])->Bool {effects.contains{$0.enabled && [.glitch,.chromaticAberration,.filmGrain].contains($0.kind)}}
    func apply(_ image: CGImage, effects: [VisualEffect], time: Double, pixelScale: Double) -> CGImage {
        guard effects.contains(where:{$0.enabled}) else {return image}
        let extent=CGRect(x:0,y:0,width:image.width,height:image.height)
        do {
            let signal=GlitchFailureSignal(),result=try filtered(image,effects:effects,time:time,pixelScale:pixelScale,signal:signal)
            let output=rasterize(result,from:extent,checked:hasGlitch(effects))
            if let output,signal.error == nil {return output}
            if hasGlitch(effects) {
                let retrySignal=GlitchFailureSignal(),retry=try filtered(image,effects:effects,time:time,pixelScale:pixelScale,signal:retrySignal,forceCPU:true)
                let output=rasterize(retry,from:extent,checked:true)
                if let output,retrySignal.error == nil {return output}
                if let error=retrySignal.error {throw error}
            }
            if let error=signal.error {throw error}
            throw VMMError.message(L("エフェクトの描画結果を作成できませんでした。"))
        } catch {record(error);return image}
    }
    func partial(_ image:CGImage,effects:[VisualEffect],time:Double,pixelScale:Double,mask:CGImage,bounds:CGRect)->CGImage? {
        do {
            func masked(_ image:CIImage)->CIImage {image.applyingFilter("CIBlendWithAlphaMask",parameters:[kCIInputBackgroundImageKey:CIImage(color:.clear).cropped(to:bounds),kCIInputMaskImageKey:CIImage(cgImage:mask)])}
            let signal=GlitchFailureSignal(),result=try filtered(image,effects:effects,time:time,pixelScale:pixelScale,signal:signal)
            let output=rasterize(masked(result),from:bounds,checked:hasGlitch(effects))
            if let output,signal.error == nil {return output}
            if hasGlitch(effects) {
                let retrySignal=GlitchFailureSignal(),retry=try filtered(image,effects:effects,time:time,pixelScale:pixelScale,signal:retrySignal,forceCPU:true)
                let output=rasterize(masked(retry),from:bounds,checked:true)
                if let output,retrySignal.error == nil {return output}
                if let error=retrySignal.error {throw error}
            }
            if let error=signal.error {throw error}
            throw VMMError.message(L("エフェクトの描画結果を作成できませんでした。"))
        } catch {record(error);return nil}
    }
    private func filtered(_ image:CGImage,effects:[VisualEffect],time:Double,pixelScale:Double,signal:GlitchFailureSignal,forceCPU:Bool=false)throws->CIImage {
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        var result = CIImage(cgImage: image)
        for effect in effects where effect.enabled {
            let value = min(effect.kind.range.upperBound, max(effect.kind.range.lowerBound, interpolate(effect.keys, at: time, fallback: effect.amount)))
            func filter(_ name: String, _ parameters: [String: Any] = [:]) -> CIImage {
                result.applyingFilter(name, parameters: parameters)
            }
            switch effect.kind {
            case .blur: result = filter("CIGaussianBlur", [kCIInputRadiusKey: value * pixelScale])
            case .pixelate: result = filter("CIPixellate", [kCIInputScaleKey: max(1, value * pixelScale), kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY)])
            case .brightness: result = filter("CIColorControls", [kCIInputBrightnessKey: value])
            case .contrast: result = filter("CIColorControls", [kCIInputContrastKey: value])
            case .saturation: result = filter("CIColorControls", [kCIInputSaturationKey: value])
            case .hue: result = filter("CIHueAdjust", [kCIInputAngleKey: value * .pi / 180])
            case .sepia: result = filter("CISepiaTone", [kCIInputIntensityKey: value])
            case .invert:
                let inverted = filter("CIColorInvert")
                result = inverted.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: result, kCIInputTimeKey: 1 - value])
            case .glow: result = filter("CIBloom", [kCIInputRadiusKey: value * pixelScale, kCIInputIntensityKey: 1])
            case .vignette: result = filter("CIVignette", [kCIInputIntensityKey: value * 2, kCIInputRadiusKey: min(extent.width, extent.height) * 0.4])
            case .chromaKey:
                result = filter("CIColorCube", ["inputCubeDimension": 32, "inputCubeData": cube(color: effect.color, tolerance: value)])
            case .glitch,.chromaticAberration,.filmGrain:
                do {result=try (forceCPU ? cpuGlitchFilter:glitchFilter)(result,effect.kind,value,time,pixelScale,effect.id,extent,signal)}
                catch {throw VMMError.message(String(format:L("エフェクト「%@」の描画に失敗しました。\n%@"),L(effect.kind.title),error.localizedDescription))}
            case .colorLUT:
                if let cube=effect.lut,value>0,let space=CGColorSpace(name:CGColorSpace.sRGB) {
                    let graded=result.applyingFilter("CIColorCubeWithColorSpace",parameters:["inputCubeDimension":cube.size,"inputCubeData":cube.data,"inputColorSpace":space])
                    result=result.applyingFilter("CIDissolveTransition",parameters:[kCIInputTargetImageKey:graded,kCIInputTimeKey:value])
                }
            }
            result = result.cropped(to: extent)
        }
        return result
    }
    func cube(color: String, tolerance: Double) -> Data {
        let key = color + ":" + String(tolerance.bitPattern)
        if let hit = keyCubes[key] { return hit }
        let target = NSColor(hex: color).usingColorSpace(.sRGB)!
        var values = [Float](); values.reserveCapacity(32 * 32 * 32 * 4)
        for b in 0..<32 { for g in 0..<32 { for r in 0..<32 {
            let red = Double(r) / 31, green = Double(g) / 31, blue = Double(b) / 31
            let distance = sqrt(pow(red - target.redComponent, 2) + pow(green - target.greenComponent, 2) + pow(blue - target.blueComponent, 2)) / sqrt(3)
            let alpha = min(1, max(0, (distance - tolerance) / 0.06))
            values.append(contentsOf: [Float(red * alpha), Float(green * alpha), Float(blue * alpha), Float(alpha)])
        } } }
        let data = values.withUnsafeBytes { Data($0) }
        if keyCubes.count > 32 { keyCubes.removeAll() }; keyCubes[key] = data
        return data
    }
}

enum TransitionRenderer {
    static func draw(old: CGImage, new: CGImage, kind: SceneTransitionKind, progress: Double, context: CGContext, size: CGSize) {
        let p = min(1, max(0, progress)), frame = CGRect(origin: .zero, size: size)
        context.saveGState(); defer { context.restoreGState() }
        // Preserve the affected layers’ alpha over unrelated upper rows.
            switch kind {
            case .dissolve:
                context.setBlendMode(.plusLighter);context.setAlpha(1-p);context.draw(old,in:frame)
                context.setAlpha(p);context.draw(new,in:frame)
            case .fadeBlack,.fadeWhite:
                context.draw(p<0.5 ? old:new,in:frame)
                context.setBlendMode(.sourceAtop);context.setFillColor((kind == .fadeBlack ? NSColor.black:NSColor.white).cgColor)
                context.setAlpha(1-abs(p*2-1));context.fill(frame)
            case .wipeLeft,.wipeRight,.wipeUp,.wipeDown,.iris:
                context.draw(old,in:frame)
                switch kind {
                case .wipeLeft:context.clip(to:CGRect(x:0,y:0,width:size.width*p,height:size.height))
                case .wipeRight:context.clip(to:CGRect(x:size.width*(1-p),y:0,width:size.width*p,height:size.height))
                case .wipeUp:context.clip(to:CGRect(x:0,y:0,width:size.width,height:size.height*p))
                case .wipeDown:context.clip(to:CGRect(x:0,y:size.height*(1-p),width:size.width,height:size.height*p))
                default:let radius=hypot(size.width,size.height)/2*p;context.addEllipse(in:CGRect(x:size.width/2-radius,y:size.height/2-radius,width:radius*2,height:radius*2));context.clip()
                }
                context.clear(frame);context.draw(new,in:frame)
            case .slideLeft,.slideRight:
                let sign=kind == .slideLeft ? -1.0:1.0
                context.draw(old,in:frame.offsetBy(dx:sign*size.width*p,dy:0))
                context.draw(new,in:frame.offsetBy(dx:-sign*size.width*(1-p),dy:0))
            case .zoom:
                let scale=0.4+0.6*p
                let rect=CGRect(x:size.width*(1-scale)/2,y:size.height*(1-scale)/2,width:size.width*scale,height:size.height*scale)
                context.setAlpha(1-p);context.draw(old,in:frame);context.setAlpha(p);context.draw(new,in:rect)
            }
    }
}
