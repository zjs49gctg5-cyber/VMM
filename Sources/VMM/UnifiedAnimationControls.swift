import SwiftUI

@MainActor extension EditorStore {
    func setAnimationValue(_ id:UUID,lane:AnimationLane,at time:Double,value:Double)throws {
        try mutateMotion(id){c in
            guard lane.numeric,time.isFinite,value.isFinite,lane.range(c).contains(value) else{throw VMMError.message("キーフレームの値が不正です。")}
            let t=c.motionStart+min(c.duration,max(0,((time-c.motionStart)*Double(project.fps)).rounded()/Double(project.fps)))
            func put(_ keys:inout [AnimationKeyframe]){if let i=keys.firstIndex(where:{abs($0.time-t)<0.000001}){keys[i].value=value}else{keys.append(AnimationKeyframe(time:t,value:value))};keys.sort{$0.time<$1.time}}
            switch lane{
            case .property(let p):guard c.availableAnimatedProperties.contains(p) else{throw VMMError.message("設定項目を追加してください。")};if c.animation?.tracks.first(where:{$0.property==p})==nil{c.putMotionKey(p,time:c.motionStart,value:p.get(c));c.putMotionKey(p,time:c.motionEnd,value:p.get(c))};c.putMotionKey(p,time:t,value:value);if let i=c.animation?.tracks.firstIndex(where:{$0.property==p}){c.animation!.tracks[i].enabled=true}
            case .effect(let id):guard let i=c.effects?.firstIndex(where:{$0.id==id}) else{throw VMMError.message("エフェクトが見つかりません。")};put(&c.effects![i].keys)
            case .trim(let id,let start):try c.editBezier(id){if start{put(&$0.trimStart)}else{put(&$0.trimEnd)}}
            default:break
            }
        }
    }
}
struct UnifiedKeyControls:View {
    @ObservedObject var store:EditorStore;let clip:Clip;let lane:AnimationLane
    @Binding var selection:MotionSelection?
    var showValue=true;var compact=false
    @State private var curveOpen=false
    private var key:AnimationKeyframe?{let keys=lane.keys(clip);if let id=selection?.keyID{return keys.first{$0.id==id}};return keys.first{abs($0.time-(selection?.time ?? -1))<0.000001}}
    private var now:Double{min(clip.motionEnd,max(clip.motionStart,clip.motionTime(at:store.playhead)))}
    private func attempt(_ body:()throws->Void){do{try body()}catch{store.error=error.localizedDescription}}
    private func select(_ key:AnimationKeyframe){selection=MotionSelection(time:key.time,property:{if case .property(let p)=lane{return p};return nil}(),psdKeyID:lane == .psd ? key.id:nil,lane:lane,keyID:key.id)}
    private func fresh(_ id:UUID){if let c=store.project.clips.first(where:{$0.id==clip.id}),let k=lane.keys(c).first(where:{$0.id==id}){select(k);store.seek(min(c.end-0.000001,max(c.start,c.start+k.time-c.motionStart)))}}
    var body:some View{VStack(alignment:.leading,spacing:10){
        if !compact{HStack{Text(lane.title(clip)).fontWeight(.semibold);Spacer();if lane.canToggle(clip){Toggle(L("有効"),isOn:Binding(get:{lane.enabled(clip)},set:{v in attempt{try store.mutateMotion(clip.id){c in switch lane{case .property(let p):if let i=c.animation?.tracks.firstIndex(where:{$0.property==p}){c.animation!.tracks[i].enabled=v};case .effect(let id):if let i=c.effects?.firstIndex(where:{$0.id==id}){c.effects![i].enabled=v};case .shape(let id),.trim(let id,_):if let i=c.masks?.firstIndex(where:{$0.id==id}){c.masks![i].enabled=v};default:break}}}}))};Button(L("現在位置にキーを追加")){attempt{let k=try store.insertAnimationKey(clip.id,lane:lane,at:now);select(k)}}}}
        if lane.numeric && showValue {
            NumberInput(title:key == nil ? "現在時刻の値":"選択したキーの値",value:Binding(get:{key?.value ?? lane.value(clip,at:now)},set:{v in attempt{if let key{try store.editAnimationKey(clip.id,lane:lane,keyID:key.id,value:v)}else{try store.setAnimationValue(clip.id,lane:lane,at:now,value:v)}}}),range:lane.range(clip),unit:lane.unit(clip),percent:lane.percent(clip))
        }
        if let key {
            NumberInput(title:"キーの時刻",value:Binding(get:{key.time-clip.motionStart},set:{v in attempt{try store.editAnimationKey(clip.id,lane:lane,keyID:key.id,time:clip.motionStart+v);fresh(key.id)}}),range:(clip.animationDomain.lowerBound-clip.motionStart)...(clip.animationDomain.upperBound-clip.motionStart),unit:"秒")
            if lane != .psd {
                VMMMenuPicker(L("次のキーまでの補間"),selection:Binding(get:{key.easing},set:{v in attempt{try store.editAnimationKey(clip.id,lane:lane,keyID:key.id,easing:v)}})){VMMOptions(Easing.allCases,id:\.self){VMMChoice(text:L($0.title),value:$0)}}
            }
            if lane.numeric,key.time<clip.motionEnd {
                HStack{Button(L("カーブ編集…")){curveOpen=true}.popover(isPresented:$curveOpen){EasingCurveEditor(curve:key.customCurve ?? EasingCurve(),onApply:{curve in attempt{try store.editAnimationKey(clip.id,lane:lane,keyID:key.id,curve:.some(curve));curveOpen=false}},onCancel:{curveOpen=false}).vmmAppearance(store.settings)};if key.customCurve != nil{Button(L("標準補間に戻す")){attempt{try store.editAnimationKey(clip.id,lane:lane,keyID:key.id,curve:.some(nil))}}}}
            }
            if !compact{HStack{Button(L("複製")){attempt{select(try store.duplicateAnimationKey(clip.id,lane:lane,keyID:key.id))}};Button(L("削除")){attempt{try store.deleteAnimationKey(clip.id,lane:lane,keyID:key.id);selection=MotionSelection(time:now,property:selection?.property,lane:lane)}};Spacer();Button(L("現在位置を編集")){selection=MotionSelection(time:now,property:selection?.property,lane:lane)}}}
        }else{Text(L("下の◆を選択すると、値・時刻・補間を編集できます。")).foregroundColor(.secondary)}
    }.padding(compact ? 0:12).background(Color.orange.opacity(compact ? 0:0.07)).cornerRadius(8)}
}
