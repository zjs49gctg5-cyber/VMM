import Foundation

/// UI identity only: existing models remain the source of truth for every lane.
enum AnimationLane:Hashable,Identifiable {
    case property(AnimatedProperty),effect(UUID),spatial,shape(UUID?),trim(UUID?,Bool),psd,timing(AnimationTiming)
    var canKeyframe:Bool{if case .timing=self{return false};return true}
    var id:String{switch self{case .property(let p):return "property:"+p.rawValue;case .effect(let id):return "effect:"+id.uuidString;case .spatial:return "spatial";case .shape(let id):return "shape:"+(id?.uuidString ?? "object");case .trim(let id,let start):return "trim:"+(id?.uuidString ?? "object")+":"+String(start);case .psd:return "psd";case .timing(let t):return "timing:"+t.rawValue}}
    func title(_ clip:Clip)->String{switch self{case .property(let p):return p.isTemporal ? L("ブラー・残像")+" · "+L(p.title):L(p.title);case .effect(let id):return L("エフェクト")+" · "+L(clip.effects?.first{$0.id==id}?.kind.title ?? "");case .spatial:return L("移動パス");case .shape(let id):return (id == nil ? L("図形"):L("マスク")+" "+String(id!.uuidString.prefix(4)))+" · "+L("形");case .trim(let id,let start):return (id == nil ? L("線"):L("マスク"))+" · "+L(start ? "開始":"終了");case .psd:return L("立ち絵・表情");case .timing(let t):return L(t.title)}}
    func enabled(_ c:Clip)->Bool{switch self{case .property(let p):return c.animation?.tracks.first{$0.property==p}?.enabled ?? true;case .effect(let id):return c.effects?.first{$0.id==id}?.enabled ?? true;case .shape(let id),.trim(let id,_):return id.flatMap{id in c.masks?.first{$0.id==id}?.enabled} ?? true;default:return true}}
    func canToggle(_ c:Clip)->Bool{switch self{case .property(let p):return c.animation?.tracks.contains{$0.property==p} ?? false;case .effect:return true;case .shape(let id),.trim(let id,_):return id != nil;default:return false}}
    func keys(_ c:Clip)->[AnimationKeyframe]{switch self{
    case .property(let p):return c.animation?.tracks.first{$0.property==p}?.keys ?? []
    case .effect(let id):return c.effects?.first{$0.id==id}?.keys ?? []
    case .spatial:return (c.spatialAnimation?.keys ?? []).map{AnimationKeyframe(id:$0.id,time:$0.time,value:0,easing:$0.easing)}
    case .shape(let id):return (c.bezierShape(id)?.keys ?? []).map{AnimationKeyframe(id:$0.id,time:$0.time,value:0,easing:$0.easing)}
    case .trim(let id,let start):return start ? c.bezierShape(id)?.trimStart ?? []:c.bezierShape(id)?.trimEnd ?? []
    case .timing:return []
    case .psd:return (c.psd?.selectionKeys ?? []).map{AnimationKeyframe(id:$0.id,time:$0.time,value:0,easing:.hold)}
    }}
    var numeric:Bool{switch self{case .property,.effect,.trim:return true;default:return false}}
    func range(_ c:Clip)->ClosedRange<Double>{switch self{case .property(let p):return p.range;case .effect(let id):return c.effects?.first{$0.id==id}?.kind.range ?? 0...1;default:return 0...1}}
    func percent(_ c:Clip)->Bool{switch self{case .property(let p):return p.percent;case .effect(let id):return c.effects?.first{$0.id==id}?.kind.percent ?? false;case .trim:return true;default:return false}}
    func unit(_ c:Clip)->String{switch self{case .property(let p):return p.unit;case .effect(let id):return c.effects?.first{$0.id==id}?.kind.unit ?? "";default:return ""}}
    func value(_ c:Clip,at time:Double)->Double{switch self{
    case .property(let p):return c.animation?.tracks.first{$0.property==p}?.enabled==false ? p.get(c):c.motionValue(p,at:time)
    case .effect(let id):return interpolate(keys(c),at:time,fallback:c.effects?.first{$0.id==id}?.amount ?? 0)
    case .trim(_,let start):return interpolate(keys(c),at:time,fallback:start ? 0:1)
    default:return 0
    }}
}
extension Clip {
    func bezierShape(_ maskID:UUID?)->AnimatedBezierShape?{maskID.flatMap{id in masks?.first{$0.id==id}?.path} ?? (maskID==nil ? shapeStyle?.path:nil)}
    mutating func editBezier(_ id:UUID?,_ change:(inout AnimatedBezierShape)throws->Void)throws {
        if let id {guard let i=masks?.firstIndex(where:{$0.id==id}),var path=masks?[i].path else{throw VMMError.message("パスが見つかりません。")};try change(&path);masks![i].path=path}
        else{guard var path=shapeStyle?.path else{throw VMMError.message("パスが見つかりません。")};try change(&path);shapeStyle?.path=path}
    }
    var animationLanes:[AnimationLane] {
        var result=(animation?.tracks ?? []).map{AnimationLane.property($0.property)}
        if temporalMotion != nil {for p in [AnimatedProperty.shutterAngle,.blurSamples,.trailCount,.trailDuration,.trailOpacity] where !result.contains(.property(p)){result.append(.property(p))}}
        result += (effects ?? []).map{.effect($0.id)}
        if spatialAnimation != nil{result.append(.spatial)}
        if shapeStyle?.path != nil{result += [.shape(nil),.trim(nil,true),.trim(nil,false)]}
        for mask in masks ?? [] where mask.path != nil{result.append(.shape(mask.id));if !(mask.path?.trimStart.isEmpty ?? true) || !(mask.path?.trimEnd.isEmpty ?? true){result += [.trim(mask.id,true),.trim(mask.id,false)]}}
        if psd != nil{result.append(.psd)}
        if (animation?.entrance.kind ?? .none) != .none{result.append(.timing(.entrance))}
        if (animation?.exit.kind ?? .none) != .none{result.append(.timing(.exit))}
        if textAnimation != nil{result.append(.timing(.characters))}
        if !(animation?.motions ?? []).isEmpty{result.append(.timing(.motions))}
        if (audioFade?.fadeIn ?? 0)>0{result.append(.timing(.audioIn))}
        if (audioFade?.fadeOut ?? 0)>0{result.append(.timing(.audioOut))}
        if kind == .transition{result.append(.timing(.transition))}
        return result
    }
    var animationDomain:ClosedRange<Double>{let times=animationLanes.flatMap{$0.keys(self).map(\.time)};return min(motionStart,times.min() ?? motionStart)...max(motionEnd,times.max() ?? motionEnd)}
    var allAnimationBoundaries:[Double]{Array(Set([motionStart,motionEnd]+animationLanes.flatMap{$0.keys(self).map(\.time)}.filter{$0>motionStart && $0<motionEnd})).sorted()}
}
@MainActor extension EditorStore {
    @discardableResult func insertAnimationKey(_ id:UUID,lane:AnimationLane,at time:Double)throws->AnimationKeyframe {
        var inserted:AnimationKeyframe?
        try mutateMotion(id){c in
            guard lane.canKeyframe,time.isFinite,c.animationLanes.contains(lane) || {if case .property(let p)=lane{return c.availableAnimatedProperties.contains(p)};return false}() else{throw VMMError.message("設定項目が見つかりません。")}
            let t=min(86400,max(0,c.motionStart+((time-c.motionStart)*Double(project.fps)).rounded()/Double(project.fps)))
            let sampled=lane.value(c,at:t)
            if let key=lane.keys(c).first(where:{abs($0.time-t)<0.000001}){if case .property(let p)=lane,let i=c.animation?.tracks.firstIndex(where:{$0.property==p}){c.animation!.tracks[i].enabled=true};inserted=key;return}
            switch lane {
            case .property(let p):
                if c.animation?.tracks.first(where:{$0.property==p})==nil {c.putMotionKey(p,time:c.motionStart,value:p.get(c));c.putMotionKey(p,time:c.motionEnd,value:p.get(c))}
                let value=lane.value(c,at:t);c.putMotionKey(p,time:t,value:value,easing:[.blurSamples,.trailCount].contains(p) ? .hold:nil)
                if let i=c.animation?.tracks.firstIndex(where:{$0.property==p}){c.animation!.tracks[i].enabled=true}
            case .effect(let id):guard let i=c.effects?.firstIndex(where:{$0.id==id}) else{return};c.effects![i].keys.append(AnimationKeyframe(time:t,value:sampled))
            case .spatial:c.spatialAnimation?.insertPoint(at:t)
            case .shape(let id):try c.editBezier(id){p in p.keys.append(BezierShapeKey(time:t,vertices:p.vertices(at:t)))}
            case .trim(let id,let start):let key=AnimationKeyframe(time:t,value:sampled,easing:.linear);try c.editBezier(id){if start{$0.trimStart.append(key)}else{$0.trimEnd.append(key)}}
            case .timing:throw VMMError.message("この項目は設定欄で開始時刻・継続時間を編集してください。")
            case .psd:guard let state=c.psd else{return};var keys=state.selectionKeys ?? [];keys.append(PSDSelectionKeyframe(time:t,name:L("レイヤー切り替え"),selected:state.selection(at:t)));c.psd?.selectionKeys=keys.sorted{$0.time<$1.time}
            }
            inserted=lane.keys(c).first{abs($0.time-t)<0.000001}
        }
        guard let inserted else{throw VMMError.message("キーフレームを追加できません。")};return inserted
    }
    /// One validated mutation shared by timeline dragging, numeric time editing and shortcuts.
    func editAnimationKey(_ id:UUID,lane:AnimationLane,keyID:UUID,time:Double?=nil,value:Double?=nil,easing:Easing?=nil,curve:EasingCurve??=nil)throws {
        try mutateMotion(id){c in
            let keys=lane.keys(c);guard let key=keys.first(where:{$0.id==keyID}) else{throw VMMError.message("キーフレームが見つかりません。")}
            guard time.map({$0.isFinite}) ?? true else{throw VMMError.message("時刻が不正です。")}
            let t=time.map{min(86400,max(0,c.motionStart+(($0-c.motionStart)*Double(project.fps)).rounded()/Double(project.fps)))} ?? key.time
            guard t.isFinite,t>=0,t<=86400,!keys.contains(where:{$0.id != keyID && abs($0.time-t)<0.000001}),value.map({$0.isFinite && lane.range(c).contains($0)}) ?? true else{throw VMMError.message("時刻・値が不正か、同じ時刻にキーがあります。")}
            func edit(_ key:inout AnimationKeyframe){key.time=t;if let value{key.value=value};if let easing{key.easing=easing;key.customCurve=nil};if let curve{key.customCurve=curve}}
            switch lane {
            case .property(let p):if let i=c.animation?.tracks.firstIndex(where:{$0.property==p}),let j=c.animation?.tracks[i].keys.firstIndex(where:{$0.id==keyID}){edit(&c.animation!.tracks[i].keys[j]);c.animation!.tracks[i].keys.sort{$0.time<$1.time}}
            case .effect(let id):if let i=c.effects?.firstIndex(where:{$0.id==id}),let j=c.effects?[i].keys.firstIndex(where:{$0.id==keyID}){edit(&c.effects![i].keys[j]);c.effects![i].keys.sort{$0.time<$1.time}}
            case .spatial:if let i=c.spatialAnimation?.keys.firstIndex(where:{$0.id==keyID}){c.spatialAnimation!.keys[i].time=t;if let easing{c.spatialAnimation!.keys[i].easing=easing};c.spatialAnimation!.keys.sort{$0.time<$1.time}}
            case .shape(let id):try c.editBezier(id){p in if let i=p.keys.firstIndex(where:{$0.id==keyID}){p.keys[i].time=t;if let easing{p.keys[i].easing=easing};p.keys.sort{$0.time<$1.time}}}
            case .trim(let id,let start):try c.editBezier(id){p in var keys=start ? p.trimStart:p.trimEnd;if let i=keys.firstIndex(where:{$0.id==keyID}){edit(&keys[i])};keys.sort{$0.time<$1.time};if start{p.trimStart=keys}else{p.trimEnd=keys}}
            case .timing:throw VMMError.message("この項目は設定欄で開始時刻・継続時間を編集してください。")
            case .psd:if let i=c.psd?.selectionKeys?.firstIndex(where:{$0.id==keyID}){c.psd!.selectionKeys![i].time=t;c.psd!.selectionKeys!.sort{$0.time<$1.time}}
            }
        }
    }
    func deleteAnimationKey(_ id:UUID,lane:AnimationLane,keyID:UUID)throws {
        try mutateMotion(id){c in
            guard lane.keys(c).contains(where:{$0.id==keyID}) else{throw VMMError.message("キーフレームが見つかりません。")}
            switch lane{
            case .property(let p):if let i=c.animation?.tracks.firstIndex(where:{$0.property==p}){let key=c.animation!.tracks[i].keys.first{$0.id==keyID}!;if c.animation!.tracks[i].keys.count==1{p.set(key.value,on:&c)};c.animation!.tracks[i].keys.removeAll{$0.id==keyID}}
            case .effect(let id):if let i=c.effects?.firstIndex(where:{$0.id==id}){c.effects![i].keys.removeAll{$0.id==keyID}}
            case .spatial:guard c.spatialAnimation!.keys.count>2 else{throw VMMError.message("移動パスには2点以上必要です。")};c.spatialAnimation!.keys.removeAll{$0.id==keyID}
            case .shape(let id):try c.editBezier(id){p in guard p.keys.count>1 else{throw VMMError.message("形には1つ以上のキーが必要です。")};p.keys.removeAll{$0.id==keyID}}
            case .trim(let id,let start):try c.editBezier(id){if start{$0.trimStart.removeAll{$0.id==keyID}}else{$0.trimEnd.removeAll{$0.id==keyID}}}
            case .timing:throw VMMError.message("この項目は設定欄で開始時刻・継続時間を編集してください。")
            case .psd:c.psd?.selectionKeys?.removeAll{$0.id==keyID}
            }
        }
    }
    @discardableResult func duplicateAnimationKey(_ id:UUID,lane:AnimationLane,keyID:UUID)throws->AnimationKeyframe {
        var duplicated:AnimationKeyframe?
        try mutateMotion(id){c in
            let keys=lane.keys(c);guard let key=keys.first(where:{$0.id==keyID}) else{throw VMMError.message("キーフレームが見つかりません。")}
            let step=1/Double(project.fps),candidates=(1...1025).map{key.time+Double($0)*step}+(1...1025).map{key.time-Double($0)*step}
            // Find a free time in this lane, retaining the complete key payload.
            guard let free=candidates.first(where:{candidate in candidate>=c.motionStart && candidate<=c.motionEnd && !keys.contains(where:{abs($0.time-candidate)<0.000001})}) else{throw VMMError.message("キーの配置先がありません。")}
            let newID=UUID()
            switch lane {
            case .property(let p):if let i=c.animation?.tracks.firstIndex(where:{$0.property==p}){var copy=key;copy.id=newID;copy.time=free;c.animation!.tracks[i].keys.append(copy)}
            case .effect(let id):if let i=c.effects?.firstIndex(where:{$0.id==id}){var copy=key;copy.id=newID;copy.time=free;c.effects![i].keys.append(copy)}
            case .spatial:if var copy=c.spatialAnimation?.keys.first(where:{$0.id==keyID}){copy.id=newID;copy.time=free;c.spatialAnimation?.keys.append(copy)}
            case .shape(let id):try c.editBezier(id){p in if var copy=p.keys.first(where:{$0.id==keyID}){copy.id=newID;copy.time=free;p.keys.append(copy)}}
            case .trim(let id,let start):var copy=key;copy.id=newID;copy.time=free;try c.editBezier(id){if start{$0.trimStart.append(copy)}else{$0.trimEnd.append(copy)}}
            case .timing:throw VMMError.message("この項目は設定欄で開始時刻・継続時間を編集してください。")
            case .psd:if var copy=c.psd?.selectionKeys?.first(where:{$0.id==keyID}){copy.id=newID;copy.time=free;c.psd?.selectionKeys?.append(copy)}
            }
            duplicated=lane.keys(c).first{$0.id==newID}
        };guard let duplicated else{throw VMMError.message("キーを複製できません。")};return duplicated
    }
}


enum AnimationTiming:String,Hashable {
    case entrance,exit,characters,motions,audioIn,audioOut,transition
    var title:String{switch self{case .entrance:return "登場";case .exit:return "退場";case .characters:return "文字アニメーション";case .motions:return "反復モーション";case .audioIn:return "音声フェードイン";case .audioOut:return "音声フェードアウト";case .transition:return "場面切替"}}
    func interval(_ c:Clip)->(Double,Double){switch self{
    case .entrance:return(0,c.animation?.entrance.duration ?? 0.5)
    case .exit:let span=c.animation?.span ?? c.duration;return(span-(c.animation?.exit.duration ?? 0.5),span)
    case .characters:guard let a=c.textAnimation else{return(0,0)};if a.kind == .wave{return(a.start,c.motionEnd)};return(a.start,a.start+a.duration+Double(max(0,min(c.text.count-1,a.last)-a.first))*a.delay)
    case .audioIn:return(c.motionStart,c.motionStart+(c.audioFade?.fadeIn ?? 0))
    case .audioOut:return(c.motionEnd-(c.audioFade?.fadeOut ?? 0),c.motionEnd)
    default:return(c.motionStart,c.motionEnd)
    }}
}
