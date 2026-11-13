import Foundation

enum AnimationOperator:String,Codable {
    case constant,parameter,time,seconds,base,add,subtract,multiply,divide,sin,cos,min,max,clamp,lerp,curve
    var arity:Int {switch self {case .constant,.parameter,.time,.seconds,.base:return 0;case .sin,.cos,.curve:return 1;case .clamp,.lerp:return 3;default:return 2}}
}
struct AnimationExpression:Codable,Equatable {
    var op:AnimationOperator
    var value:Double?
    var parameter:String?
    var args:[AnimationExpression]?
    var curve:EasingCurve?
    func validate(parameters:Set<String>,depth:Int=0,nodes:inout Int)throws {
        nodes+=1
        guard depth<=12,nodes<=256,(args ?? []).count==op.arity else{throw VMMError.message("アニメーション式の深さ・命令数・引数が不正です。")}
        if op == .constant {guard let value,value.isFinite,abs(value)<=10000 else{throw VMMError.message("式の定数が不正です。")}}
        if op == .parameter {guard let parameter,parameters.contains(parameter) else{throw VMMError.message("式が参照するパラメータがありません。")}}
        if op == .curve {guard let curve,curve.isValid else{throw VMMError.message("式のカーブが不正です。")}}
        for child in args ?? [] {try child.validate(parameters:parameters,depth:depth+1,nodes:&nodes)}
    }
    func evaluate(time:Double,seconds:Double,base:Double,parameters:[String:Double])throws->Double {
        let a=try (args ?? []).map{try $0.evaluate(time:time,seconds:seconds,base:base,parameters:parameters)}
        let result:Double
        switch op {
        case .constant:result=value ?? .nan
        case .parameter:result=parameters[parameter ?? ""] ?? .nan
        case .time:result=time
        case .seconds:result=seconds
        case .base:result=base
        case .add:result=a[0]+a[1]
        case .subtract:result=a[0]-a[1]
        case .multiply:result=a[0]*a[1]
        case .divide:guard abs(a[1])>1e-12 else{throw VMMError.message("アニメーション式でゼロ除算が発生しました。")};result=a[0]/a[1]
        case .sin:result=Foundation.sin(a[0])
        case .cos:result=Foundation.cos(a[0])
        case .min:result=Swift.min(a[0],a[1])
        case .max:result=Swift.max(a[0],a[1])
        case .clamp:guard a[1]<=a[2] else{throw VMMError.message("clampの範囲が不正です。")};result=Swift.min(a[2],Swift.max(a[1],a[0]))
        case .lerp:result=a[0]+(a[1]-a[0])*a[2]
        case .curve:result=curve?.value(a[0]) ?? .nan
        }
        guard result.isFinite,abs(result)<=1e9 else{throw VMMError.message("アニメーション式の結果が範囲外です。")};return result
    }
}
struct AnimationParameter:Codable,Equatable,Identifiable {
    var id:String;var title:String
    var minimum:Double;var maximum:Double;var defaultValue:Double
    var unit:String?
}
struct DefinedAnimationTrack:Codable,Equatable {
    var property:AnimatedProperty
    /// Offset adds the expression to the item's base value. Absolute replaces it.
    var offset:Bool
    var expression:AnimationExpression
}
struct ScriptAnimationOutput:Codable,Equatable {var property:AnimatedProperty;var offset:Bool}
struct AnimationDefinition:Codable,Equatable,Identifiable {
    var id:String;var name:String;var description:String?
    var parameters:[AnimationParameter];var tracks:[DefinedAnimationTrack]
    var script:String?
    var scriptOutputs:[ScriptAnimationOutput]?
    /// Shared script settings; absent in older packages/projects.
    var scriptSeed:UInt32?
    var targetProperties:[AnimatedProperty] {script == nil ? tracks.map(\.property):(scriptOutputs ?? []).map(\.property)}
    @discardableResult func validated()throws->AnimationDefinition {
        guard DataExtensionPackage.validID(id),!name.isEmpty,name.count<=120,(description?.count ?? 0)<=1000,
              parameters.count<=12,Set(parameters.map(\.id)).count==parameters.count,
              !targetProperties.isEmpty,targetProperties.count<=12,Set(targetProperties).count==targetProperties.count else{throw VMMError.message("アニメーション定義が不正です。")}
        if let script {guard !script.isEmpty,script.utf8.count<=65536,tracks.isEmpty,scriptOutputs != nil else{throw VMMError.message("JavaScript定義が不正です。")}}
        else {guard scriptOutputs == nil else{throw VMMError.message("JavaScriptの出力定義が不正です。")}}
        for p in parameters {guard DataExtensionPackage.validID(p.id),!p.title.isEmpty,p.title.count<=120,[p.minimum,p.maximum,p.defaultValue].allSatisfy({$0.isFinite && abs($0)<=10000}),p.minimum<p.maximum,(p.minimum...p.maximum).contains(p.defaultValue),[nil,"%","°","秒","回"].contains(p.unit) else{throw VMMError.message("アニメーションのパラメータが不正です。")}}
        var nodes=0
        for t in tracks {try t.expression.validate(parameters:Set(parameters.map(\.id)),nodes:&nodes)}
        return self
    }
    func resolved(_ input:[String:Double])throws->[String:Double] {
        guard Set(input.keys).isSubset(of:Set(parameters.map(\.id))) else{throw VMMError.message("未知のアニメーションパラメータです。")}
        var output:[String:Double]=[:]
        for p in parameters {let v=input[p.id] ?? p.defaultValue;guard v.isFinite,(p.minimum...p.maximum).contains(v) else{throw VMMError.message("アニメーションパラメータが範囲外です。")};output[p.id]=v}
        return output
    }
    /// Bake on the project frame grid, then reduce linear keys to measured tolerance.
    /// Persisting ordinary tracks keeps rendering independent of installed extensions.
    func bake(clip:Clip,fps:Int,values:[String:Double])throws->[AnimationTrack] {
        _=try validated();guard script == nil else{throw VMMError.message("JavaScriptは別プロセスで生成してください。")};let values=try resolved(values)
        guard (1...60).contains(fps),clip.duration.isFinite,clip.duration>0,clip.duration<=86400,tracks.allSatisfy({clip.availableAnimatedProperties.contains($0.property)}) else{throw VMMError.message("このアイテムにはアニメーションを適用できません。")}
        let count=Int(ceil(clip.duration*Double(fps)))
        var nodes=0;for t in tracks {try t.expression.validate(parameters:Set(parameters.map(\.id)),nodes:&nodes)}
        guard count<=20000,(count+1)*nodes<=2_000_000 else{throw VMMError.message("アニメーション生成の上限です。アイテムを短い区間に分割してください。")}
        return try tracks.map {track in
            let base=track.property.get(clip)
            let samples=try (0...count).map {i -> AnimationKeyframe in
                let local=min(clip.duration,Double(i)/Double(fps))
                let result=try track.expression.evaluate(time:local/clip.duration,seconds:local,base:base,parameters:values)+(track.offset ? base:0)
                let value=min(track.property.range.upperBound,max(track.property.range.lowerBound,result))
                return AnimationKeyframe(time:clip.animationTimeOffset+local,value:value,easing:.linear)
            }
            return try Self.reduce(samples,property:track.property)
        }
    }
    static func reduce(_ samples:[AnimationKeyframe],property:AnimatedProperty)throws->AnimationTrack {
        let count=samples.count-1
        var retained:Set<Int>=[0,count],pending=[(0,count)]
            let tolerance=property.percent ? 0.0001:0.05
            while let (a,b)=pending.popLast() {
                try Task.checkCancellation()
                if b-a<=1 {continue}
                var worst=0.0,index=a
                for i in (a+1)..<b {
                    let t=(samples[i].time-samples[a].time)/(samples[b].time-samples[a].time)
                    let error=abs(samples[i].value-(samples[a].value+(samples[b].value-samples[a].value)*t))
                    if error>worst{worst=error;index=i}
                }
                if worst>tolerance {
                    retained.insert(index)
                    guard retained.count<=500 else{throw VMMError.message("500キー以内で精度を保てません。振動数を下げるかアイテムを分割してください。")}
                    pending.append((a,index));pending.append((index,b))
                }
            }
            return AnimationTrack(property:property,keys:retained.sorted().map{samples[$0]})
    }

}
struct CustomAnimationInstance:Codable,Equatable {
    var packageID:String
    var definition:AnimationDefinition
    var values:[String:Double]
    var seed:UInt32?
    func validate()throws {guard DataExtensionPackage.validID(packageID) else{throw VMMError.message("拡張IDが不正です。")};_=try definition.validated();_=try definition.resolved(values)}
}
struct DataExtensionPackage:Codable,Equatable,Identifiable {
    var version=1
    var id:String;var name:String;var author:String;var revision:String
    var animations:[AnimationDefinition]
    var presets:[EffectPreset]
    static func validID(_ id:String)->Bool {!id.isEmpty && id.count<=100 && id.unicodeScalars.allSatisfy{CharacterSet(charactersIn:"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0)}}
    func validated()throws->DataExtensionPackage {
        guard (version==1 || version==2),(version==2 || animations.allSatisfy{$0.script == nil}),Self.validID(id),!name.isEmpty,name.count<=120,author.count<=120,!revision.isEmpty,revision.count<=40,animations.count<=16,presets.count<=32,!animations.isEmpty || !presets.isEmpty,Set(animations.map(\.id)).count==animations.count,Set(presets.map(\.name)).count==presets.count else{throw VMMError.message("拡張パッケージの形式・バージョン・内容が不正です。")}
        for a in animations{_=try a.validated()};for p in presets{_=try p.validated()};return self
    }
    static func decode(_ data:Data)throws->DataExtensionPackage {
        guard data.count<=1_048_576 else{throw VMMError.message("拡張JSONは1MB以内にしてください。")}
        let json=try JSONSerialization.jsonObject(with:data)
        var work:[(Any,Int)]=[(json,0)],count=0
        while let (value,depth)=work.popLast() {
            count+=1;guard depth<=40,count<=20000 else{throw VMMError.message("拡張JSONの構造が大きすぎます。")}
            if let d=value as? [String:Any] {work += d.values.map{($0,depth+1)}}
            else if let a=value as? [Any] {work += a.map{($0,depth+1)}}
        }
        return try JSONDecoder().decode(Self.self,from:data).validated()
    }
    static var sample:DataExtensionPackage {
        func number(_ n:Double)->AnimationExpression {AnimationExpression(op:.constant,value:n)}
        func param(_ id:String)->AnimationExpression {AnimationExpression(op:.parameter,parameter:id)}
        func op(_ op:AnimationOperator,_ args:AnimationExpression...)->AnimationExpression {AnimationExpression(op:op,args:args)}
        let phase=op(.multiply,op(.multiply,AnimationExpression(op:.time),param("cycles")),number(2*Double.pi))
        let amplitude=AnimationParameter(id:"amplitude",title:"振幅",minimum:0,maximum:0.5,defaultValue:0.08,unit:"%")
        let cycles=AnimationParameter(id:"cycles",title:"繰り返し回数",minimum:0.25,maximum:10,defaultValue:2,unit:"回")
        let wave=AnimationDefinition(id:"wave",name:"上下に揺れる",description:"振幅と繰り返し回数を調整できる波です。",parameters:[amplitude,cycles],tracks:[DefinedAnimationTrack(property:.y,offset:true,expression:op(.multiply,param("amplitude"),op(.sin,phase)))])
        let orbit=AnimationDefinition(id:"orbit",name:"周回運動",description:"アイテムの基準位置を中心に周回します。",parameters:[amplitude,cycles],tracks:[DefinedAnimationTrack(property:.x,offset:true,expression:op(.multiply,param("amplitude"),op(.cos,phase))),DefinedAnimationTrack(property:.y,offset:true,expression:op(.multiply,param("amplitude"),op(.sin,phase)))])
        return DataExtensionPackage(id:"vmm.sample.motion",name:"基本モーション",author:"VMM",revision:"1.0",animations:[wave,orbit],presets:Array(EffectPreset.builtins.prefix(3)))
    }
}
