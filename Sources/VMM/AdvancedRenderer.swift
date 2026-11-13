import AppKit
import CoreImage

struct RasterTools {
    static func bitmap(_ size: CGSize) -> CGContext? {
        let w=max(1,Int(size.width.rounded())),h=max(1,Int(size.height.rounded()))
        return CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)
    }
    static func composite(_ image: CGImage, into context: CGContext, mode: CompositeMode = .normal, opacity: Double = 1, rect:CGRect?=nil) {
        context.saveGState(); defer { context.restoreGState() }
        context.setBlendMode(mode.cg); context.setAlpha(opacity)
        context.draw(image,in:rect ?? CGRect(x:0,y:0,width:context.width,height:context.height))
    }
    /// Resolve a per-item blend against the scene while retaining a transparent
    /// layer buffer, so subsequent layer effects never modify the backdrop.
    static func blend(_ image:CGImage,into layer:CGContext,backdrop:CGContext,mode:CompositeMode) {
        guard let base=backdrop.makeImage(),let existing=layer.makeImage(),
              let combined=bitmap(CGSize(width:layer.width,height:layer.height)),
              let coverage=bitmap(CGSize(width:layer.width,height:layer.height)) else {return}
        composite(base,into:combined);composite(existing,into:combined);composite(image,into:combined,mode:mode)
        composite(existing,into:coverage);composite(image,into:coverage)
        combined.flush();coverage.flush();backdrop.flush();layer.flush()
        guard let destination=layer.data?.assumingMemoryBound(to:UInt8.self),let output=combined.data?.assumingMemoryBound(to:UInt8.self),let background=backdrop.data?.assumingMemoryBound(to:UInt8.self),let alpha=coverage.data?.assumingMemoryBound(to:UInt8.self) else {return}
        for y in 0..<layer.height {for x in 0..<layer.width {
            let i=y*layer.bytesPerRow+x*4,a=Int(alpha[i+3])
            for channel in 0..<3 {destination[i+channel]=UInt8(min(a,max(0,Int(output[i+channel])-(Int(background[i+channel])*(255-a)+127)/255)))}
            destination[i+3]=UInt8(a)
        }}
    }
    static func topCoordinates(_ c: CGContext, project: Project, size: CGSize) {
        c.scaleBy(x:size.width/CGFloat(project.width),y:size.height/CGFloat(project.height))
        c.translateBy(x:0,y:CGFloat(project.height));c.scaleBy(x:1,y:-1)
    }
    static func appKit(_ context: CGContext, _ action: () -> Void) {
        let previous=NSGraphicsContext.current;NSGraphicsContext.current=NSGraphicsContext(cgContext:context,flipped:true)
        defer { NSGraphicsContext.current=previous };action()
    }
    static func image(_ image: CGImage, project: Project, opacity:Double = 1) {
        NSImage(cgImage:image,size:NSSize(width:project.width,height:project.height)).draw(in:CGRect(x:0,y:0,width:project.width,height:project.height),from:.zero,operation:.sourceOver,fraction:opacity,respectFlipped:true,hints:nil)
    }
}
final class MaskRenderer {
    private let ci = CIContext(options:[.cacheIntermediates:false])
    private let images=RenderCache<NSImage>(budget:64*1024*1024)
    var cacheBytes:Int {images.bytes}
    func setCacheBudget(_ bytes:Int){images.budget=bytes}
    func clearCache(){images.clear()}
    func apply(_ source: CGImage, masks: [ClipMask], project: Project, directory: URL, time:Double=0) -> CGImage {
        guard masks.contains(where:{$0.enabled}) else {return source}
        let size=CGSize(width:source.width,height:source.height),extent=CGRect(origin:.zero,size:size)
        var result=CIImage(cgImage:source)
        for mask in masks where mask.enabled {
            guard let c=RasterTools.bitmap(size) else { continue }
            RasterTools.topCoordinates(c,project:project,size:size)
            let rect=CGRect(x:(mask.x-mask.width/2)*Double(project.width),y:(mask.y-mask.height/2)*Double(project.height),width:mask.width*Double(project.width),height:mask.height*Double(project.height))
            c.setFillColor(NSColor.white.cgColor)
            if let path=mask.path {c.addPath(path.path(in:rect,time:time));c.fillPath()} else {switch mask.kind {
            case .rectangle: c.fill(rect)
            case .ellipse: c.fillEllipse(in:rect)
            case .polygon:
                if let first=mask.points.first {
                    c.move(to:CGPoint(x:rect.minX+first.x*rect.width,y:rect.minY+first.y*rect.height))
                    for point in mask.points.dropFirst() { c.addLine(to:CGPoint(x:rect.minX+point.x*rect.width,y:rect.minY+point.y*rect.height)) }
                    c.closePath();c.fillPath()
                }
            case .image:
                guard let asset=project.assets.first(where:{$0.id==mask.assetID}) else { continue }
                let path=directory.appendingPathComponent("Media").appendingPathComponent(asset.file).path
                let cached=images.value(path) ?? NSImage(contentsOfFile:path)
                if let cached {images.insert(cached,key:path,bytes:cached.renderCacheBytes)}
                if let image=cached { RasterTools.appKit(c) { image.draw(in:rect,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil) } }
            }
            }
            guard let cg=c.makeImage() else {continue}
            var maskImage=CIImage(cgImage:cg)
            if mask.feather>0 { maskImage=maskImage.applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:mask.feather*Double(source.width)/Double(project.width)]) }
            if mask.inverted { maskImage=maskImage.applyingFilter("CIColorMatrix",parameters:["inputAVector":CIVector(x:0,y:0,z:0,w:-1),"inputBiasVector":CIVector(x:0,y:0,z:0,w:1)]) }
            result=result.applyingFilter("CIBlendWithAlphaMask",parameters:[kCIInputBackgroundImageKey:CIImage(color:.clear).cropped(to:extent),kCIInputMaskImageKey:maskImage.cropped(to:extent)]).cropped(to:extent)
        }
        return ci.createCGImage(result,from:extent) ?? source
    }
    func regionMask(clip:Clip,project:Project,size:CGSize)->CGImage? {
        guard let region=clip.adjustmentRegion, let c=RasterTools.bitmap(size) else{return nil}
        RasterTools.topCoordinates(c,project:project,size:size)
        c.translateBy(x:clip.x*Double(project.width),y:clip.y*Double(project.height))
        c.rotate(by:(clip.rotation ?? 0)*Double.pi/180)
        let w=region.width*Double(project.width),h=region.height*Double(project.height)
        let rect=CGRect(x:-w/2,y:-h/2,width:w,height:h)
        c.setFillColor(NSColor.white.cgColor)
        switch region.shape {
        case .rectangle: c.fill(rect)
        case .ellipse: c.fillEllipse(in:rect)
        case .roundedRectangle: c.addPath(CGPath(roundedRect:rect,cornerWidth:min(w,h)*0.15,cornerHeight:min(w,h)*0.15,transform:nil));c.fillPath()
        }
        return c.makeImage()
    }
    func applyRegion(_ source:CGImage,clip:Clip,project:Project)->CGImage {
        guard let region=clip.adjustmentRegion,let mask=regionMask(clip:clip,project:project,size:CGSize(width:source.width,height:source.height)) else{return source}
        let extent=CGRect(x:0,y:0,width:source.width,height:source.height)
        var image=CIImage(cgImage:mask)
        if region.feather>0 {image=image.applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:region.feather*Double(source.width)/Double(project.width)])}
        let result=CIImage(cgImage:source).applyingFilter("CIBlendWithAlphaMask",parameters:[kCIInputBackgroundImageKey:CIImage(color:.clear).cropped(to:extent),kCIInputMaskImageKey:image.cropped(to:extent)]).cropped(to:extent)
        return ci.createCGImage(result,from:extent) ?? source
    }
    func perspective(_ source: CGImage, settings: Transform2D?) -> CGImage {
        guard let settings,settings.perspective,settings.corners.count==4 else {return source}
        let p=settings.corners,w=Double(source.width),h=Double(source.height)
        func vector(_ i:Int) -> CIVector {CIVector(x:p[i].x*w,y:(1-p[i].y)*h)}
        let extent=CGRect(x:0,y:0,width:source.width,height:source.height)
        let result=CIImage(cgImage:source).applyingFilter("CIPerspectiveTransform",parameters:["inputTopLeft":vector(0),"inputTopRight":vector(1),"inputBottomRight":vector(2),"inputBottomLeft":vector(3)]).cropped(to:extent)
        return ci.createCGImage(result,from:extent) ?? source
    }
}
enum ParticleRenderer {
    // A stable hash, independent of frame order and process-local Swift hashing.
    static func random(_ seed: UInt64, _ index: Int, _ channel: UInt64) -> Double {
        var x=seed &+ UInt64(max(0,index)) &* 0x9E3779B97F4A7C15 &+ channel &* 0xBF58476D1CE4E5B9
        x=(x ^ (x >> 30)) &* 0xBF58476D1CE4E5B9;x=(x ^ (x >> 27)) &* 0x94D049BB133111EB;x=x ^ (x >> 31)
        return Double(x >> 11)/Double(UInt64(1)<<53)
    }
    private static let starPoints=(0..<10).map {n->CGPoint in
        let angle=Double(n)*Double.pi/5-Double.pi/2,r=n%2==0 ? 0.5:0.22
        return CGPoint(x:cos(angle)*r,y:sin(angle)*r)
    }
    static func draw(_ clip: Clip, project: Project, time: Double, context: CGContext,detail:Double=1) {
        let s=clip.particles ?? ParticleSettings(),local=clip.motionTime(at:time)
        let from=NSColor(hex:clip.color).usingColorSpace(.sRGB)!,to=NSColor(hex:s.endColor).usingColorSpace(.sRGB)!
        let fraction=max(0.05,min(1,detail))
        let bounds=context.boundingBoxOfClipPath,colorSpace=CGColorSpace(name:CGColorSpace.sRGB)!
        for i in 0..<min(1000,s.count) {
            guard fraction==1 || random(s.seed,i,7)<fraction else {continue}
            let phase=s.burst ? 0 : random(s.seed,i,1)*s.lifetime
            let cycle=floor((local-phase)/s.lifetime)
            guard cycle>=0, !s.burst || cycle==0 else {continue}
            let age=local-(cycle*s.lifetime+phase),p=age/s.lifetime
            guard p>=0,p<1 else {continue}
            let seed=s.seed &+ UInt64(cycle)*101
            let angle=(s.angle+(random(seed,i,2)-0.5)*s.spread)*Double.pi/180
            let velocity=s.velocity*(0.5+random(seed,i,3))
            let x=0.5+(random(seed,i,4)-0.5)*s.emitterWidth+cos(angle)*velocity*age
            let y=0.5+(random(seed,i,5)-0.5)*s.emitterHeight+sin(angle)*velocity*age+s.gravity*age*age/2
            let size=s.size*(0.5+random(seed,i,6))*(1-p*0.4)
            let rect=CGRect(x:x*Double(project.width)-size/2,y:y*Double(project.height)-size/2,width:size,height:size)
            guard bounds.intersects(rect) else {continue}
            if let color=CGColor(colorSpace:colorSpace,components:[from.redComponent+(to.redComponent-from.redComponent)*p,from.greenComponent+(to.greenComponent-from.greenComponent)*p,from.blueComponent+(to.blueComponent-from.blueComponent)*p,1-p]) {context.setFillColor(color)}
            switch s.shape {
            case .circle:context.fillEllipse(in:rect)
            case .square:context.fill(rect)
            case .star:
                for n in 0..<10 {
                    let unit=starPoints[n]
                    let point=CGPoint(x:rect.midX+unit.x*size,y:rect.midY+unit.y*size)
                    if n==0 {context.move(to:point)} else {context.addLine(to:point)}
                }
                context.closePath();context.fillPath()
            }
        }
    }
}
