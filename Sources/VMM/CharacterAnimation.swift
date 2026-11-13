import Foundation

enum CharacterMotion:String,Codable,CaseIterable {
    case rise,bounce,rotate,zoom,fade,wave,blur
    var title:String {switch self{case .rise:return "下から登場";case .bounce:return "一文字ずつバウンド";case .rotate:return "一文字ずつ回転";case .zoom:return "一文字ずつ拡大";case .fade:return "一文字ずつフェード";case .blur:return "ぼかしから登場";case .wave:return "波打つ文字"}}
}
struct CharacterPose:Equatable {var y:Double=0,rotation:Double=0,scale:Double=1,opacity:Double=1,blur:Double=0}
struct CharacterAnimation:Codable,Equatable {
    var kind=CharacterMotion.bounce
    var delay:Double=0.06
    var duration:Double=0.4
    var start:Double=0
    var distance:Double=40
    var rotation:Double=90
    var initialScale:Double=0.2
    var reverse=false
    var first:Int=0
    var last:Int=10000
    var easing=Easing.easeOut
    var blurRadius:Double?
    func pose(index:Int,count:Int,time:Double)->CharacterPose {
        guard index>=first,index<=last else{return CharacterPose()}
        let n=reverse ? min(last,count-1)-index:index-first,t=time-start-Double(n)*delay
        if kind == .wave {guard t>=0 else{return CharacterPose()};return CharacterPose(y:sin(t/duration*2 * .pi)*distance)}
        let p=min(1,max(0,t/duration)),v=easing.value(p)
        var result=CharacterPose(opacity:p==0 ? 0:min(1,max(0,p*4)))
        switch kind {
        case .rise:result.y=(1-v)*distance
        case .bounce:result.y = -abs(sin(p * .pi * 3))*(1-p)*distance
        case .rotate:result.rotation=(1-v)*rotation
        case .zoom:result.scale=max(0.001,initialScale+(1-initialScale)*v)
        case .fade:result.opacity=min(1,max(0,v))
        case .blur:result.blur=max(0,1-v)*(blurRadius ?? 12)
        case .wave:break
        }
        return result
    }
    func validated()throws {
        guard blurRadius.map({$0.isFinite && (0...64).contains($0)}) ?? true else{throw VMMError.message("文字のぼかし半径が不正です。") }
        guard [delay,duration,start,distance,rotation,initialScale].allSatisfy(\.isFinite),(0...10).contains(delay),(0.01...60).contains(duration),(0...86400).contains(start),(-2000...2000).contains(distance),(-3600...3600).contains(rotation),(0.01...10).contains(initialScale),(0...10000).contains(first),(first...10000).contains(last) else{throw VMMError.message("文字アニメーションの設定が不正です。")}
    }
}
