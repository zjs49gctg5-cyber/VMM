import Foundation

enum PartialAdjustment {
    static func bounds(_ clip:Clip,size:CGSize)->CGRect? {
        guard let region=clip.adjustmentRegion,region.feather==0 else{return nil}
        let w=region.width*size.width,h=region.height*size.height,angle = -(clip.rotation ?? 0)*Double.pi/180
        let width=abs(w*cos(angle))+abs(h*sin(angle)),height=abs(w*sin(angle))+abs(h*cos(angle))
        let rect=CGRect(x:clip.x*size.width-width/2,y:(1-clip.y)*size.height-height/2,width:width,height:height).insetBy(dx:-2,dy:-2).integral.intersection(CGRect(origin:.zero,size:size))
        return rect.isEmpty ? nil:rect
    }
}
