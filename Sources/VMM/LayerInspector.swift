import SwiftUI

struct LayerInspector:View {
    @ObservedObject var store:EditorStore
    var index:Int {store.selectedTrack}
    var track:Track {store.project.tracks[index]}
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:12) {
                Text(L("レイヤー全体の設定")).vmmFont(size:14,weight:.semibold)
                TextField(L("レイヤー名"),text:Binding(get:{track.name},set:{v in store.editTrack(index){$0.name=v}})).textFieldStyle(.roundedBorder)
                NumberInput(title:"不透明度",value:Binding(get:{track.opacity ?? 1},set:{v in store.editTrack(index){$0.opacity=v}}),range:0...1,percent:true)
                VMMMenuPicker(L("合成モード"),selection:Binding(get:{track.blendMode ?? .normal},set:{v in store.editTrack(index){$0.blendMode=v}})) {VMMOptions(CompositeMode.allCases,id:\.self){VMMChoice(text:L($0.title),value:$0)}}
                Text(L("レイヤー内を合成してからエフェクトを適用します。アイテムの選択を外すと、この設定を表示します。")).vmmFont(size:12).foregroundColor(.secondary)
                Menu(L("レイヤーエフェクトを追加")) {ForEach(EffectKind.allCases,id:\.self) {kind in Button(L(kind.title)){store.editTrack(index){t in var list=t.effects ?? [];if list.count<32 {list.append(VisualEffect(kind:kind))};t.effects=list}}}}
                ForEach(Array((track.effects ?? []).enumerated()),id:\.element.id) {i,effect in
                    LayerEffectRow(store:store,trackIndex:index,effect:effect,index:i)
                }
                Button(L("同じレイヤーをグループ化")) {store.groupSelectedLayer()}
            }.padding(14).vmmFont(size:12).disabled(store.busy || track.locked)
        }
    }
}
struct LayerEffectRow:View {
    @ObservedObject var store:EditorStore;let trackIndex:Int;let effect:VisualEffect;let index:Int
    func binding<T>(_ key:WritableKeyPath<VisualEffect,T>)->Binding<T> {
        Binding(get:{(store.project.tracks[trackIndex].effects?.first{$0.id==effect.id} ?? effect)[keyPath:key]},set:{v in store.editTrack(trackIndex){t in guard let i=t.effects?.firstIndex(where:{$0.id==effect.id}) else{return};t.effects?[i][keyPath:key]=v}})
    }
    func reorder(_ delta:Int) {store.editTrack(trackIndex){t in guard var list=t.effects,let i=list.firstIndex(where:{$0.id==effect.id}),list.indices.contains(i+delta) else{return};list.swapAt(i,i+delta);t.effects=list}}
    var body:some View {
        VStack(spacing:8) {
            HStack {
                Toggle(effect.kind.title,isOn:binding(\.enabled));Spacer()
                Button {reorder(-1)} label:{UIIcon(systemName:"arrow.up")}.disabled(index==0)
                Button {reorder(1)} label:{UIIcon(systemName:"arrow.down")}.disabled(index+1 >= (store.project.tracks[trackIndex].effects?.count ?? 0))
                Button {store.editTrack(trackIndex){$0.effects?.removeAll{$0.id==effect.id}}} label:{UIIcon(systemName:"trash")}
            }.buttonStyle(.borderless)
            NumberInput(title:effect.kind == .chromaKey ? "許容範囲":"強さ",value:binding(\.amount),range:effect.kind.range,unit:effect.kind.unit,percent:effect.kind.percent)
            if effect.kind == .colorLUT {ColorLUTPicker(store:store,cube:binding(\.lut).wrappedValue){[trackID=store.project.tracks[trackIndex].id] cube in try store.setTrackLUT(cube,trackID:trackID,effectID:effect.id)}}
            if effect.kind == .chromaKey {ColorPicker(L("抜く色"),selection:Binding(get:{Color(nsColor:NSColor(hex:binding(\.color).wrappedValue))},set:{binding(\.color).wrappedValue=NSColor($0).hex}),supportsOpacity:false)}
        }.padding(8).background(Color.primary.opacity(0.04)).cornerRadius(5)
    }
}
