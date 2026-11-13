import Foundation
import CoreGraphics

struct SpatialKey:Codable,Equatable,Identifiable {
    var id=UUID()
    var time:Double
    var point:NormalizedPoint
    /// Tangents are offsets from the node, so moving a node preserves its shape.
    var incoming=NormalizedPoint(x:-0.1,y:0)
    var outgoing=NormalizedPoint(x:0.1,y:0)
    var easing=Easing.linear
}
struct SpatialAnimation:Codable,Equatable {
    var keys:[SpatialKey]
    var orientToPath=false
    var orientationAspect:Double?
    func sample(at time:Double,aspectRatio:Double?=nil)->(point:NormalizedPoint,angle:Double) {
        let keys=keys.sorted{$0.time<$1.time}
        guard let first=keys.first else{return (NormalizedPoint(x:0.5,y:0.5),0)}
        guard keys.count>1 else{return(first.point,0)}
        let index=keys.firstIndex{$0.time>time} ?? keys.count-1,a=keys[max(0,index-1)],b=keys[index]
        let u=a.easing.value((time-a.time)/max(0.000001,b.time-a.time)),t=min(1,max(0,u)),v=1-t
        let p0=a.point,p1=NormalizedPoint(x:a.point.x+a.outgoing.x,y:a.point.y+a.outgoing.y),p2=NormalizedPoint(x:b.point.x+b.incoming.x,y:b.point.y+b.incoming.y),p3=b.point
        let p=NormalizedPoint(x:v*v*v*p0.x+3*v*v*t*p1.x+3*v*t*t*p2.x+t*t*t*p3.x,y:v*v*v*p0.y+3*v*v*t*p1.y+3*v*t*t*p2.y+t*t*t*p3.y)
        let dx=3*v*v*(p1.x-p0.x)+6*v*t*(p2.x-p1.x)+3*t*t*(p3.x-p2.x),dy=3*v*v*(p1.y-p0.y)+6*v*t*(p2.y-p1.y)+3*t*t*(p3.y-p2.y)
        return(p,atan2(dy,dx*(aspectRatio ?? orientationAspect ?? 1))*180 / .pi)
    }
    func validated()throws {
        guard orientationAspect.map({$0.isFinite && (0.01...100).contains($0)}) ?? true else{throw VMMError.message("移動パスの画面比率が不正です。") }
        guard keys.count>=2,keys.count<=500,Set(keys.map(\.id)).count==keys.count,Set(keys.map(\.time)).count==keys.count,
              keys.allSatisfy({k in k.time.isFinite && (0...86400).contains(k.time) && [k.point,k.incoming,k.outgoing].allSatisfy{p in p.x.isFinite && p.y.isFinite && (-4...4).contains(p.x) && (-4...4).contains(p.y)}}) else{throw VMMError.message("移動パスの設定が不正です。")}
    }
}
extension Clip {
    /// Normalized canvas coordinates; the legacy center pivot is (0.5, 0.5).
    var anchorOffset:NormalizedPoint {NormalizedPoint(x:(anchorPoint?.x ?? 0.5)-0.5,y:(anchorPoint?.y ?? 0.5)-0.5)}
    func objectMatrix(project:Project,canvasInput:Bool)->CGAffineTransform {
        let t=transform ?? Transform2D(),angle=(rotation ?? 0)*Double.pi/180,c=cos(angle),s=sin(angle)
        let sx=scale*t.scaleX*(flipX == true ? -1:1),sy=scale*t.scaleY*(flipY == true ? -1:1),kx=tan(t.skewX*Double.pi/180),ky=tan(t.skewY*Double.pi/180)
        let a=sx*(c-s*ky),b=sx*(s+c*ky),cc=sy*(c*kx-s),d=sy*(s*kx+c)
        let ax=anchorOffset.x*Double(project.width),ay=anchorOffset.y*Double(project.height)
        let ox=canvasInput ? Double(project.width)/2:0,oy=canvasInput ? Double(project.height)/2:0
        return CGAffineTransform(a:a,b:b,c:cc,d:d,tx:x*Double(project.width)+ax-a*(ox+ax)-cc*(oy+ay),ty:y*Double(project.height)+ay-b*(ox+ax)-d*(oy+ay))
    }
}

extension SpatialAnimation {
    /// Split a cubic segment instead of introducing arbitrary handles into tracked paths.
    @discardableResult mutating func insertPoint(at time:Double)->UUID {
        if let key=keys.first(where:{abs($0.time-time)<0.000001}){return key.id}
        keys.sort{$0.time<$1.time}
        let zero=NormalizedPoint(x:0,y:0)
        guard let first=keys.first,let last=keys.last else{let k=SpatialKey(time:time,point:NormalizedPoint(x:0.5,y:0.5));keys=[k];return k.id}
        if time<first.time{keys[0].incoming=zero;let key=SpatialKey(time:time,point:first.point,incoming:zero,outgoing:zero);keys.insert(key,at:0);return key.id}
        if time>last.time{keys[keys.count-1].outgoing=zero;let key=SpatialKey(time:time,point:last.point,incoming:zero,outgoing:zero);keys.append(key);return key.id}
        let i=keys.firstIndex{$0.time>time}!,a=keys[i-1],b=keys[i],u=min(1,max(0,a.easing.value((time-a.time)/(b.time-a.time))))
        func add(_ p:NormalizedPoint,_ q:NormalizedPoint)->NormalizedPoint{NormalizedPoint(x:p.x+q.x,y:p.y+q.y)}
        func sub(_ p:NormalizedPoint,_ q:NormalizedPoint)->NormalizedPoint{NormalizedPoint(x:p.x-q.x,y:p.y-q.y)}
        func mix(_ p:NormalizedPoint,_ q:NormalizedPoint)->NormalizedPoint{NormalizedPoint(x:p.x+(q.x-p.x)*u,y:p.y+(q.y-p.y)*u)}
        let p0=a.point,p1=add(a.point,a.outgoing),p2=add(b.point,b.incoming),p3=b.point,q0=mix(p0,p1),q1=mix(p1,p2),q2=mix(p2,p3),r0=mix(q0,q1),r1=mix(q1,q2),point=mix(r0,r1)
        keys[i-1].outgoing=sub(q0,p0);keys[i].incoming=sub(q2,p3)
        let key=SpatialKey(time:time,point:point,incoming:sub(r0,point),outgoing:sub(r1,point),easing:a.easing);keys.insert(key,at:i);return key.id
    }
}
