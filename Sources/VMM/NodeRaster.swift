import AppKit

/// An item raster and its location in the full frame's bottom-left pixel coordinates.
struct NodeRaster {
    let image:CGImage
    let rect:CGRect
    func composite(into context:CGContext,mode:CompositeMode = .normal) {
        RasterTools.composite(image,into:context,mode:mode,rect:rect)
    }
}
enum NodeRasterGeometry {
    static func pixelRect(_ rect:CGRect,project:Project,size:CGSize)->CGRect {
        let sx=size.width/Double(project.width),sy=size.height/Double(project.height)
        return CGRect(x:rect.minX*sx,y:size.height-rect.maxY*sy,width:rect.width*sx,height:rect.height*sy)
    }
    static func projectRect(_ rect:CGRect,project:Project,size:CGSize)->CGRect {
        let sx=size.width/Double(project.width),sy=size.height/Double(project.height)
        return CGRect(x:rect.minX/sx,y:(size.height-rect.maxY)/sy,width:rect.width/sx,height:rect.height/sy)
    }
    static func affine(_ clip:Clip,project:Project)->CGAffineTransform {
        clip.objectMatrix(project:project,canvasInput:true)
    }
}
