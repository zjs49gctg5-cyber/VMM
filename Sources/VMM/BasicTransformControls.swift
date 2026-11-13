import SwiftUI

@MainActor extension EditorStore {
    /// Static fields stay static; animated fields edit the visible/selected key.
    func setBasicTransformValue(_ id:UUID,property:AnimatedProperty,time:Double,value:Double,keyID:UUID?=nil)throws {
        guard let c=project.clips.first(where:{$0.id==id}),!property.isTemporal,c.availableAnimatedProperties.contains(property),value.isFinite,property.range.contains(value),time.isFinite else{throw VMMError.message("キーフレームの設定が不正です。")}
        if let keyID {try editAnimationKey(id,lane:.property(property),keyID:keyID,value:value)}
        else if let track=c.animation?.tracks.first(where:{$0.property==property}),track.enabled,!track.keys.isEmpty{try setAnimationValue(id,lane:.property(property),at:time,value:value)}
        else{try mutateMotion(id){property.set(value,on:&$0)}}
    }
}

struct BasicTransformControls:View {
    @ObservedObject var store:EditorStore;let clip:Clip
    @Binding var selection:MotionSelection?
    @State private var details=false
    private var now:Double{min(clip.motionEnd,max(clip.motionStart,clip.motionTime(at:store.playhead)))}
    private let main:[AnimatedProperty]=[.x,.y,.scale,.rotation,.opacity,.volume]
    private var extra:[AnimatedProperty]{clip.availableAnimatedProperties.filter{!$0.isTemporal && !main.contains($0)}}
    private func attempt(_ body:()throws->Void){do{try body()}catch{store.error=error.localizedDescription}}
    private func selectedKey(_ p:AnimatedProperty)->AnimationKeyframe?{guard selection?.lane == .property(p) || selection?.property==p else{return nil};return clip.animation?.tracks.first{$0.property==p}?.keys.first{selection?.keyID == $0.id || (selection?.keyID==nil && abs($0.time-(selection?.time ?? -1))<0.000001)}}
    private func select(_ p:AnimatedProperty,_ key:AnimationKeyframe?=nil){selection=MotionSelection(time:key?.time ?? now,property:p,lane:.property(p),keyID:key?.id)}
    var body:some View {VStack(alignment:.leading,spacing:6){
        HStack{Text(L("基本変形")).fontWeight(.semibold);Spacer();Text(L("◆でキーフレームを追加")).font(.caption).foregroundColor(.secondary)}
        ForEach(main.filter{clip.availableAnimatedProperties.contains($0)},id:\.self){row($0)}
        if !extra.isEmpty{PanelDisclosure(L("詳細な変形"),isExpanded:$details){ForEach(extra,id:\.self){row($0)}}}
        if let p=selection?.property,!p.isTemporal,selectedKey(p) != nil{Divider();UnifiedKeyControls(store:store,clip:clip,lane:.property(p),selection:$selection,showValue:false,compact:true)}
        if clip.spatialAnimation != nil{Text(L("移動パスが有効なため、X/Yのキーよりパスが優先されます。")).font(.caption).foregroundColor(.secondary)}
        KeyframeBatchControls(store:store,clip:clip)
    }.onChange(of:selection?.property){p in if let p,extra.contains(p){details=true}}}
    private func row(_ p:AnimatedProperty)->some View {
        let track=clip.animation?.tracks.first{$0.property==p},key=selectedKey(p),atKey=track?.keys.first{abs($0.time-now)<0.000001},animated=track?.enabled==true && !(track?.keys.isEmpty ?? true)
        return HStack(spacing:6){
            NumberInput(title:p.title,value:Binding(get:{key?.value ?? (animated ? clip.motionValue(p,at:now):p.get(clip))},set:{v in attempt{try store.setBasicTransformValue(clip.id,property:p,time:now,value:v,keyID:key?.id);if key==nil{select(p)}}}),range:p.range,unit:p.unit,percent:p.percent)
            Button{attempt{let k=try store.insertAnimationKey(clip.id,lane:.property(p),at:now);select(p,k)}}label:{Image(systemName:atKey != nil && animated ? "diamond.fill":"diamond").foregroundColor(animated ? .cyan:.secondary).frame(width:22,height:22)}.buttonStyle(.borderless).help(L("現在位置にキーを追加")).accessibilityLabel(L(p.title)+" · "+L("現在位置にキーを追加"))
            propertyMenu(p,track:track,atKey:atKey)
        }.padding(.vertical,0).padding(.horizontal,6).background(selection?.property==p ? Color.orange.opacity(0.08):Color.clear).cornerRadius(5)
    }
    private func propertyMenu(_ p:AnimatedProperty,track:AnimationTrack?,atKey:AnimationKeyframe?)->some View {
        Menu {
            Button(L("キーフレームを選択")){select(p,atKey)}
            if let track {
                Button(L(track.enabled ? "無効にする":"有効にする")) {
                    attempt {try store.mutateMotion(clip.id){c in
                        if let i=c.animation?.tracks.firstIndex(where:{$0.id==track.id}){c.animation!.tracks[i].enabled.toggle()}
                    }}
                }
                Button(L("アニメーションを削除")) {
                    attempt {
                        try store.mutateMotion(clip.id){c in
                            p.set(clip.motionValue(p,at:now),on:&c)
                            c.animation?.tracks.removeAll{$0.property==p}
                        }
                        if selection?.property==p{selection=nil}
                    }
                }
            }
        }label:{Image(systemName:"ellipsis")}
        .menuStyle(.borderlessButton).frame(width:22).accessibilityLabel(L(p.title)+" · "+L("操作"))
    }
}
