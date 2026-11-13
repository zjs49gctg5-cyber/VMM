import Foundation

struct EasingCurveSegment:Codable,Equatable,Identifiable {
    var id=UUID()
    var endX:Double;var endY:Double
    var x1:Double;var y1:Double;var x2:Double;var y2:Double
}
/// X is elapsed time and Y is progress.
struct EasingCurve:Codable,Equatable {
    var segments:[EasingCurveSegment]
    static let yRange:ClosedRange<Double> = -3...4
    private static let defaultSegmentID=UUID(uuid:(0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))
    init(x1:Double=0.42,y1:Double=0,x2:Double=0.58,y2:Double=1) {
        segments=[EasingCurveSegment(id:Self.defaultSegmentID,endX:1,endY:1,x1:x1,y1:y1,x2:x2,y2:y2)]
    }
    init(segments:[EasingCurveSegment]) {self.segments=segments}
    var parts:[EasingCurveSegment] {segments}
    var isValid:Bool {
        guard !segments.isEmpty,segments.count<=32,Set(segments.map(\.id)).count==segments.count,segments.last?.endX == 1,segments.last?.endY == 1 else{return false}
        var start=0.0
        for s in segments {
            guard s.endX.isFinite,s.endX-start>=0.000099999,s.endX<=1,
                  [s.x1,s.x2].allSatisfy({$0.isFinite && (start...s.endX).contains($0)}),
                  [s.endY,s.y1,s.y2].allSatisfy({$0.isFinite && Self.yRange.contains($0)}) else{return false}
            start=s.endX
        };return true
    }
    private static func component(_ t:Double,_ start:Double,_ a:Double,_ b:Double,_ end:Double)->Double {let u=1-t;return u*u*u*start+3*u*u*t*a+3*u*t*t*b+t*t*t*end}
    private static func parameter(_ x:Double,start:Double,segment:EasingCurveSegment)->Double {
        var low=0.0,high=1.0
        for _ in 0..<32 {let mid=(low+high)/2;if component(mid,start,segment.x1,segment.x2,segment.endX)<x{low=mid}else{high=mid}}
        return (low+high)/2
    }
    func value(_ progress:Double)->Double {
        guard isValid,progress.isFinite else{return progress.isFinite ? min(1,max(0,progress)):0}
        let x=min(1,max(0,progress));if x == 0 || x == 1{return x}
        var startX=0.0,startY=0.0
        for s in segments {
            if x<=s.endX {return Self.component(Self.parameter(x,start:startX,segment:s),startY,s.y1,s.y2,s.endY)}
            startX=s.endX;startY=s.endY
        };return 1
    }
    mutating func update(_ index:Int,_ edit:(inout EasingCurveSegment)->Void) {
        var list=parts;guard list.indices.contains(index) else{return}
        edit(&list[index]);let start=index==0 ? 0:list[index-1].endX
        if index==list.count-1 {list[index].endX=1;list[index].endY=1}
        else {list[index].endX=min(list[index+1].endX-0.0001,max(start+0.0001,list[index].endX));list[index].endY=min(4,max(-3,list[index].endY))}
        for i in index...min(index+1,list.count-1) {
            let a=i==0 ? 0:list[i-1].endX,b=list[i].endX
            list[i].x1=min(b,max(a,list[i].x1));list[i].x2=min(b,max(a,list[i].x2))
            list[i].y1=min(4,max(-3,list[i].y1));list[i].y2=min(4,max(-3,list[i].y2))
        };segments=list
    }
    @discardableResult mutating func insertPoint(in index:Int)->Bool {
        var list=parts;guard list.count<32,list.indices.contains(index) else{return false}
        let s=list[index],startX=index==0 ? 0:list[index-1].endX,startY=index==0 ? 0:list[index-1].endY
        guard s.endX-startX>=0.0004 else{return false}
        let t=Self.parameter((startX+s.endX)/2,start:startX,segment:s)
        func mix(_ a:(Double,Double),_ b:(Double,Double))->(Double,Double){(a.0+(b.0-a.0)*t,a.1+(b.1-a.1)*t)}
        let a=mix((startX,startY),(s.x1,s.y1)),b=mix((s.x1,s.y1),(s.x2,s.y2)),c=mix((s.x2,s.y2),(s.endX,s.endY))
        let d=mix(a,b),e=mix(b,c),m=mix(d,e)
        list[index]=EasingCurveSegment(id:s.id,endX:m.0,endY:m.1,x1:a.0,y1:a.1,x2:d.0,y2:d.1)
        list.insert(EasingCurveSegment(endX:s.endX,endY:s.endY,x1:e.0,y1:e.1,x2:c.0,y2:c.1),at:index+1)
        segments=list;return true
    }
    @discardableResult mutating func removePoint(after index:Int)->Bool {
        var list=parts;guard index>=0,index<list.count-1 else{return false}
        let next=list[index+1]
        list[index].endX=next.endX;list[index].endY=next.endY;list[index].x2=next.x2;list[index].y2=next.y2
        list.remove(at:index+1);segments=list;return true
    }
    private static func through(_ points:[(Double,Double)])->EasingCurve {
        var list:[EasingCurveSegment]=[]
        for i in 1..<points.count {let a=points[i-1],b=points[i],dx=(b.0-a.0)/3;list.append(EasingCurveSegment(endX:b.0,endY:b.1,x1:a.0+dx,y1:a.1,x2:b.0-dx,y2:b.1))}
        return EasingCurve(segments:list)
    }
    static let presets:[(String,EasingCurve)]=[
        ("直線",EasingCurve(x1:0,y1:0,x2:1,y2:1)),
        ("加速",EasingCurve(x1:0.42,y1:0,x2:1,y2:1)),
        ("減速",EasingCurve(x1:0,y1:0,x2:0.58,y2:1)),("加速・減速",EasingCurve()),
        ("オーバーシュート",EasingCurve(x1:0.34,y1:1.56,x2:0.64,y2:1)),
        ("バウンド",through([(0,0),(0.36,1),(0.54,0.72),(0.72,1),(0.81,0.9),(0.9,1),(0.95,0.97),(1,1)])),
        ("振動",through([(0,0),(0.18,1.45),(0.32,0.65),(0.46,1.25),(0.60,0.82),(0.74,1.10),(0.87,0.96),(1,1)]))
    ]
}
