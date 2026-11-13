import CoreImage
import Foundation

/// A separate signal per render attempt: Core Image may swallow processor throws.
final class GlitchFailureSignal:NSObject {
    private let lock=NSLock()
    private var recorded:Error?
    var error:Error? {lock.lock();defer{lock.unlock()};return recorded}
    func record(_ error:Error) {lock.lock();if recorded == nil {recorded=error};lock.unlock()}
}

/// A Core Image image processor usable without Metal dynamic-library support.
/// Time and image coordinates are explicit so separate tiles and seeks are deterministic.
enum GlitchCPUProcessor {
    static func apply(image:CIImage,kind:EffectKind,amount:Double,scale:Double,seed:Int,extent:CGRect,failureSignal:GlitchFailureSignal?=nil)throws->CIImage {
        guard amount>0,[.filmGrain,.chromaticAberration,.glitch].contains(kind) else{return image}
        var args:[String:Any] = ["kind":kind.rawValue,"amount":amount,"scale":max(0.01,scale),"seed":seed]
        if let failureSignal {args["failureSignal"]=failureSignal}
        return try GlitchCPUImageKernel.apply(withExtent:extent,inputs:[image],arguments:args)
    }
    #if DEBUG
    static func failureForTesting(image:CIImage,extent:CGRect,signal:GlitchFailureSignal)throws->CIImage {
        try GlitchCPUImageKernel.apply(withExtent:extent,inputs:[image],arguments:["kind":"invalid","amount":1.0,"scale":1.0,"seed":0,"failureSignal":signal])
    }
    #endif
}

private final class GlitchCPUImageKernel:CIImageProcessorKernel {
    override class var outputFormat:CIFormat {.RGBAf}
    override class func formatForInput(at index:Int32)->CIFormat {.RGBAf}
    override class func roi(forInput index:Int32,arguments:[String:Any]?,outputRect:CGRect)->CGRect {
        let amount=arguments?["amount"] as? Double ?? 0,scale=arguments?["scale"] as? Double ?? 1
        switch arguments?["kind"] as? String {
        case EffectKind.glitch.rawValue:return outputRect.insetBy(dx:-(ceil(amount*42*scale)+2),dy:0)
        case EffectKind.chromaticAberration.rawValue:return outputRect.insetBy(dx:-(ceil(amount*scale)+2),dy:0)
        default:return outputRect
        }
    }
    override class func process(with inputs:[CIImageProcessorInput]?,arguments:[String:Any]?,output:CIImageProcessorOutput)throws {
        do {try render(with:inputs,arguments:arguments,output:output)}
        catch { (arguments?["failureSignal"] as? GlitchFailureSignal)?.record(error);throw error }
    }
    private class func render(with inputs:[CIImageProcessorInput]?,arguments:[String:Any]?,output:CIImageProcessorOutput)throws {
        guard let input=inputs?.first,let args=arguments,let kind=args["kind"] as? String,
              let amountValue=args["amount"] as? Double,let scaleValue=args["scale"] as? Double,
              let seedValue=args["seed"] as? Int,amountValue.isFinite,scaleValue.isFinite,scaleValue>0 else {throw VMMError.message("エフェクトのCPU描画に失敗しました。")}
        let src=input.baseAddress.assumingMemoryBound(to:Float.self),dst=output.baseAddress.assumingMemoryBound(to:Float.self)
        let srcRow=input.bytesPerRow/MemoryLayout<Float>.size,dstRow=output.bytesPerRow/MemoryLayout<Float>.size
        let inputRect=input.region.integral,rect=output.region.integral
        let srcWidth=Int(inputRect.width),srcHeight=Int(inputRect.height),outWidth=Int(rect.width),outHeight=Int(rect.height)
        guard srcWidth>0,srcHeight>0,outWidth>0,outHeight>0,srcRow>=srcWidth*4,dstRow>=outWidth*4 else{throw VMMError.message("エフェクトのCPU描画領域が不正です。")}
        let amount=Float(amountValue),scale=Float(scaleValue),seed=Float(seedValue)
        func fract(_ x:Float)->Float {x-floor(x)}
        @inline(__always) func pixel(_ x:Int,_ y:Int,_ c:Int)->Float {
            guard x>=0,y>=0,x<srcWidth,y<srcHeight else{return 0}
            return src[y*srcRow+x*4+c]
        }
        @inline(__always) func sample(_ x:Float,_ y:Int,_ c:Int)->Float {
            let x0=Int(floor(x)),weight=x-Float(x0)
            return pixel(x0,y,c)*(1-weight)+pixel(x0+1,y,c)*weight
        }
        for y in 0..<outHeight {
            let globalY=Float(rect.maxY)-Float(y)-0.5
            let sy=Int(inputRect.maxY-rect.maxY)+y
            var delta:Float=0
            if kind==EffectKind.glitch.rawValue {
                let band=floor(globalY/max(1,18*scale))
                let random=fract(sin(band*12.9898+seed*0.713)*43758.5453)
                let direction=fract(sin(band*78.233+seed*0.117)*12345.678)*2-1
                delta=(random>=0.58 ? 1:0)*direction*amount*42*scale
            }
            for x in 0..<outWidth {
                let sx=Int(rect.minX-inputRect.minX)+x,offset=y*dstRow+x*4
                switch kind {
                case EffectKind.filmGrain.rawValue:
                    let alpha=pixel(sx,sy,3)
                    guard alpha>=0.0001 else {dst[offset]=0;dst[offset+1]=0;dst[offset+2]=0;dst[offset+3]=0;continue}
                    let gx=Float(rect.minX)+Float(x)+0.5
                    let px=floor(gx/scale),py=floor(globalY/scale)
                    let n=fract(sin(px*12.9898+py*78.233+seed*0.137)*43758.5453)-0.5
                    for c in 0..<3 {dst[offset+c]=min(1,max(0,pixel(sx,sy,c)/alpha+n*amount))*alpha}
                    dst[offset+3]=alpha
                case EffectKind.chromaticAberration.rawValue:
                    let centerAlpha=pixel(sx,sy,3)
                    guard centerAlpha>=0.0001 else {dst[offset]=0;dst[offset+1]=0;dst[offset+2]=0;dst[offset+3]=0;continue}
                    let redX=Float(sx)-amount*scale,blueX=Float(sx)+amount*scale
                    let redAlpha=sample(redX,sy,3),blueAlpha=sample(blueX,sy,3)
                    dst[offset]=(redAlpha>0.0001 ? sample(redX,sy,0)/redAlpha:0)*centerAlpha
                    dst[offset+1]=pixel(sx,sy,1)
                    dst[offset+2]=(blueAlpha>0.0001 ? sample(blueX,sy,2)/blueAlpha:0)*centerAlpha
                    dst[offset+3]=centerAlpha
                case EffectKind.glitch.rawValue:
                    for c in 0..<4 {dst[offset+c]=sample(Float(sx)+delta,sy,c)}
                default:throw VMMError.message("未対応のCPUエフェクトです。")
                }
            }
        }
    }
}
