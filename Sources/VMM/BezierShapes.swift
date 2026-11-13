import AppKit

struct BezierVertex:Codable,Equatable {
    var point:NormalizedPoint
    var incoming=NormalizedPoint(x:0,y:0)
    var outgoing=NormalizedPoint(x:0,y:0)
}
struct BezierShapeKey:Codable,Equatable,Identifiable {
    var id=UUID();var time:Double;var vertices:[BezierVertex];var easing=Easing.linear
}
/// Vertices use the shape/mask rectangle's coordinates; handles are relative offsets.
struct AnimatedBezierShape:Codable,Equatable {
    var closed=true
    var keys=[BezierShapeKey(time:0,vertices:[BezierVertex(point:NormalizedPoint(x:0,y:0)),BezierVertex(point:NormalizedPoint(x:1,y:0)),BezierVertex(point:NormalizedPoint(x:1,y:1)),BezierVertex(point:NormalizedPoint(x:0,y:1))])]
    var trimStart:[AnimationKeyframe]=[]
    var trimEnd:[AnimationKeyframe]=[]
    func vertices(at time:Double)->[BezierVertex] {
        let ordered=keys.sorted{$0.time<$1.time}
        guard let a=ordered.last(where:{$0.time<=time}) else{return ordered.first?.vertices ?? []}
        guard let b=ordered.first(where:{$0.time>time}) else{return a.vertices}
        let t=a.easing.value((time-a.time)/(b.time-a.time))
        func mix(_ a:NormalizedPoint,_ b:NormalizedPoint)->NormalizedPoint{NormalizedPoint(x:a.x+(b.x-a.x)*t,y:a.y+(b.y-a.y)*t)}
        return zip(a.vertices,b.vertices).map{BezierVertex(point:mix($0.point,$1.point),incoming:mix($0.incoming,$1.incoming),outgoing:mix($0.outgoing,$1.outgoing))}
    }
    func path(in rect:CGRect,time:Double,trim:Bool=false)->CGPath {
        let vertices=vertices(at:time),p=CGMutablePath()
        func point(_ v:NormalizedPoint)->CGPoint{CGPoint(x:rect.minX+v.x*rect.width,y:rect.minY+v.y*rect.height)}
        guard let first=vertices.first else{return p}
        p.move(to:point(first.point))
        var pairs=Array(zip(vertices,vertices.dropFirst()));if closed,let last=vertices.last{pairs.append((last,first))}
        for (a,b) in pairs{p.addCurve(to:point(b.point),control1:point(NormalizedPoint(x:a.point.x+a.outgoing.x,y:a.point.y+a.outgoing.y)),control2:point(NormalizedPoint(x:b.point.x+b.incoming.x,y:b.point.y+b.incoming.y)))}
        if closed{p.closeSubpath()}
        guard trim else{return p}
        let start=min(1,max(0,interpolate(trimStart,at:time,fallback:0))),end=min(1,max(0,interpolate(trimEnd,at:time,fallback:1)))
        if start==0 && end==1{return p}
        guard end>start else{return CGMutablePath()}
        // Arc length in canvas units: unequal segments reveal at a constant speed.
        var points=[point(first.point)]
        for (a,b) in pairs {
            let p0=point(a.point),p1=point(NormalizedPoint(x:a.point.x+a.outgoing.x,y:a.point.y+a.outgoing.y)),p2=point(NormalizedPoint(x:b.point.x+b.incoming.x,y:b.point.y+b.incoming.y)),p3=point(b.point)
            for i in 1...48{let t=Double(i)/48,u=1-t;points.append(CGPoint(x:u*u*u*p0.x+3*u*u*t*p1.x+3*u*t*t*p2.x+t*t*t*p3.x,y:u*u*u*p0.y+3*u*u*t*p1.y+3*u*t*t*p2.y+t*t*t*p3.y))}
        }
        let lengths=zip(points,points.dropFirst()).map{hypot($1.x-$0.x,$1.y-$0.y)},total=lengths.reduce(0,+),result=CGMutablePath();var distance=0.0,started=false
        for (i,length) in lengths.enumerated(){let next=distance+length;defer{distance=next};guard length>0,next>start*total,distance<end*total else{continue};let a=points[i],b=points[i+1],lo=max(0,(start*total-distance)/length),hi=min(1,(end*total-distance)/length);func lerp(_ t:Double)->CGPoint{CGPoint(x:a.x+(b.x-a.x)*t,y:a.y+(b.y-a.y)*t)};if !started{result.move(to:lerp(lo));started=true};result.addLine(to:lerp(hi))}
        return result
    }
    func validated()throws {
        guard (1...128).contains(keys.count),Set(keys.map(\.id)).count==keys.count,Set(keys.map(\.time)).count==keys.count,let count=keys.first?.vertices.count,(2...64).contains(count),keys.allSatisfy({$0.time.isFinite && (0...86400).contains($0.time) && $0.vertices.count==count && $0.vertices.allSatisfy{v in [v.point,v.incoming,v.outgoing].allSatisfy{p in p.x.isFinite && p.y.isFinite && (-4...4).contains(p.x) && (-4...4).contains(p.y)}}}) else{throw VMMError.message("パスの点数・時刻・座標が不正です。形の中間点は同じ点数で作成してください。")}
        for list in [trimStart,trimEnd]{guard list.count<=128,Set(list.map(\.id)).count==list.count,Set(list.map(\.time)).count==list.count,list.allSatisfy({$0.time.isFinite && (0...86400).contains($0.time) && $0.value.isFinite && (0...1).contains($0.value) && ($0.customCurve?.isValid ?? true)}) else{throw VMMError.message("線の開始・終了位置が不正です。")}}
    }
}
