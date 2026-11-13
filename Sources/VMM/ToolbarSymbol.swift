import SwiftUI
import AppKit

/// Align the visible lower edge, including symbols with unequal transparent margins.
struct ToolbarSymbol:View {
    let systemName:String
    let points:Double
    var body:some View {
        let image=Self.images[systemName] ?? Self.trimmedSymbol(systemName)
        let size=image.size,extent=max(1,max(size.width,size.height))
        Image(nsImage:image).renderingMode(.template).resizable()
            .frame(width:points*size.width/extent,height:points*size.height/extent)
            .frame(width:points,height:points,alignment:.bottom)
            .accessibilityHidden(true)
    }

    // Rasterize once at high resolution so SwiftUI can tint and resize the toolbar
    // symbols without rescanning their alpha bounds during editor updates.
    private static let images:[String:NSImage]=Dictionary(uniqueKeysWithValues:
        ["doc.badge.plus","folder","square.and.arrow.down","diamond.fill","waveform","list.bullet.rectangle","books.vertical","gearshape"].map { ($0,trimmedSymbol($0)) })

    private static func trimmedSymbol(_ name:String)->NSImage {
        guard let symbol=NSImage(systemSymbolName:name,accessibilityDescription:nil),
              let configured=symbol.withSymbolConfiguration(.init(pointSize:128,weight:.regular)),
              let source=configured.cgImage(forProposedRect:nil,context:nil,hints:nil) else {return NSImage()}
        let width=source.width,height=source.height
        guard let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
                                    space:CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let data=context.data else {return configured}
        context.draw(source,in:CGRect(x:0,y:0,width:width,height:height))
        let pixels=data.assumingMemoryBound(to:UInt8.self)
        var left=width,right = -1,top=height,bottom = -1
        for y in 0..<height {for x in 0..<width where pixels[y*width*4+x*4+3]>0 {
            left=min(left,x);right=max(right,x);top=min(top,y);bottom=max(bottom,y)
        }}
        guard right>=left,bottom>=top,let raster=context.makeImage(),
              let cropped=raster.cropping(to:CGRect(x:left,y:top,width:right-left+1,height:bottom-top+1)) else {return configured}
        return NSImage(cgImage:cropped,size:NSSize(width:cropped.width,height:cropped.height))
    }
}
