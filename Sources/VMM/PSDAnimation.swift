import SwiftUI

extension EditorStore {
    func toggleAnimationPlayback(_ clipID:UUID) {
        guard !busy,let clip=project.clips.first(where:{$0.id==clipID}) else{return}
        if !playing && (playhead<clip.start || playhead>=clip.end) {seek(clip.start)}
        togglePlayback()
    }
    func addPSDSelectionKey(_ clipID:UUID,favorite:PSDFavorite? = nil) {
        do {_ = try insertPSDPoint(clipID,at:project.clips.first{$0.id==clipID}.map{$0.motionTime(at:playhead)} ?? 0,favorite:favorite)}
        catch {self.error=error.localizedDescription}
    }
    @discardableResult func insertPSDPoint(_ clipID:UUID,at time:Double,favorite:PSDFavorite?=nil)throws->UUID {
        var id=UUID()
        try mutateMotion(clipID){c in
            guard time.isFinite,let doc=project.asset(for:c)?.psd,let state=c.psd else{throw VMMError.message("立ち絵の設定が不正です。")}
            let t=c.motionStart+min(c.duration,max(0,((time-c.motionStart)*Double(project.fps)).rounded()/Double(project.fps)))
            let selected=try favorite.map{try doc.applying($0,to:state.selection(at:t))} ?? state.selection(at:t)
            var keys=state.selectionKeys ?? []
            if let i=keys.firstIndex(where:{abs($0.time-t)<0.000001}) {id=keys[i].id;keys[i].name=favorite?.name ?? keys[i].name;keys[i].selected=selected}
            else {guard keys.count<1024 else{throw VMMError.message("切り替えは1024個まで追加できます。")};keys.append(PSDSelectionKeyframe(id:id,time:t,name:favorite?.name ?? "レイヤー切り替え",selected:selected))}
            c.psd?.selectionKeys=keys.sorted{$0.time<$1.time}
        };return id
    }
    func editPSDSelectionKey(_ clipID:UUID,_ keyID:UUID,_ change:(inout PSDSelectionKeyframe)->Void) {
        do {try mutateMotion(clipID){c in
            guard var keys=c.psd?.selectionKeys,let i=keys.firstIndex(where:{$0.id==keyID}) else{return}
            change(&keys[i])
            guard keys[i].time.isFinite,(0...86400).contains(keys[i].time),!keys.contains(where:{$0.id != keyID && abs($0.time-keys[i].time)<0.000001}) else{throw VMMError.message("同じ時刻には切り替えを1つだけ配置できます。")}
            c.psd?.selectionKeys=keys.sorted{$0.time<$1.time}
        }}catch{self.error=error.localizedDescription}
    }
    @discardableResult func movePSDPoint(_ clipID:UUID,keyID:UUID,to time:Double)throws->Double {
        var moved=time
        try mutateMotion(clipID){c in
            guard time.isFinite,time>=c.motionStart,time<=c.motionEnd,var keys=c.psd?.selectionKeys,let i=keys.firstIndex(where:{$0.id==keyID}) else{throw VMMError.message("切り替え時刻が不正です。")}
            guard !keys.contains(where:{$0.id != keyID && abs($0.time-time)<0.000001}) else{throw VMMError.message("同じ時刻には切り替えを1つだけ配置できます。") }
            moved=c.motionStart+min(c.duration,max(0,((time-c.motionStart)*Double(project.fps)).rounded()/Double(project.fps)))
            guard !keys.contains(where:{$0.id != keyID && abs($0.time-moved)<0.000001}) else{throw VMMError.message("同じ時刻には切り替えを1つだけ配置できます。")}
            keys[i].time=moved;c.psd?.selectionKeys=keys.sorted{$0.time<$1.time}
        };return moved
    }
    @discardableResult func duplicatePSDPoint(_ clipID:UUID,keyID:UUID)throws->UUID {
        let id=UUID()
        try mutateMotion(clipID){c in
            guard var keys=c.psd?.selectionKeys,let key=keys.first(where:{$0.id==keyID}),keys.count<1024 else{throw VMMError.message("切り替えを複製できません。")}
            let fps=Double(project.fps),frame=((key.time-c.motionStart)*fps).rounded()
            let candidates=(1...1025).map{c.motionStart+(frame+Double($0))/fps}+(1...1025).map{c.motionStart+(frame-Double($0))/fps}
            guard let t=candidates.first(where:{t in t>=c.motionStart && t<=c.motionEnd && !keys.contains(where:{abs($0.time-t)<0.000001})}) else{throw VMMError.message("中間点を配置する空きがありません。")}
            keys.append(PSDSelectionKeyframe(id:id,time:t,name:key.name,selected:key.selected));c.psd?.selectionKeys=keys.sorted{$0.time<$1.time}
        };return id
    }
    func deletePSDPoint(_ clipID:UUID,keyID:UUID)throws {try mutateMotion(clipID){$0.psd?.selectionKeys?.removeAll{$0.id==keyID}}}

}

struct PSDAnimationControls:View {
    @ObservedObject var store:EditorStore
    let clip:Clip
    var selection:Binding<MotionSelection?>?=nil
    var body:some View {
        if let doc=store.project.asset(for:clip)?.psd {
            VStack(alignment:.leading,spacing:12) {
                Text(L("指定時刻でレイヤーの組み合わせを切り替え、次の指定時刻まで保持します。最初の指定より前は基本設定のレイヤーを表示します。")).foregroundColor(.secondary)
                HStack {
                    Button(L("現在位置に追加")){add()}
                    Menu(L("表情を現在位置に追加")) {ForEach(clip.psd?.favorites ?? []) {favorite in Button(favorite.name){add(favorite)}}}.disabled(clip.psd?.favorites.isEmpty ?? true)
                }
                if selection != nil,selection?.wrappedValue?.psdKeyID == nil {Text(L("下の時間軸で表情の中間点を選択してください。"))}
                Text(L("口パク・目パチが有効な場合、口と目は自動切り替えが優先されます。")).foregroundColor(.secondary)
                ForEach((clip.psd?.selectionKeys ?? []).filter{selection == nil || $0.id==selection?.wrappedValue?.psdKeyID}.sorted{$0.time<$1.time}) {key in
                    PSDSelectionKeyRow(store:store,clip:clip,document:doc,key:key)
                }
            }
        }
    }
    private func add(_ favorite:PSDFavorite?=nil){do{let id=try store.insertPSDPoint(clip.id,at:clip.motionTime(at:store.playhead),favorite:favorite);if let key=store.project.clips.first(where:{$0.id==clip.id})?.psd?.selectionKeys?.first(where:{$0.id==id}){selection?.wrappedValue=MotionSelection(time:key.time,property:nil,psdKeyID:id)}}catch{store.error=error.localizedDescription}}

}
private struct PSDSelectionKeyRow:View {
    @ObservedObject var store:EditorStore
    let clip:Clip;let document:PSDDocument;let key:PSDSelectionKeyframe
    @State private var expanded=false
    @State private var search=""
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            HStack {
                Button(String(format:"◆ %.3f秒へ",key.time-clip.animationTimeOffset)){store.seek(clip.start+key.time-clip.animationTimeOffset)}
                Spacer()
                Button(L("削除")){do{try store.deletePSDPoint(clip.id,keyID:key.id)}catch{store.error=error.localizedDescription}}
            }
            NumberInput(title:"切り替え時刻",value:Binding(get:{key.time-clip.animationTimeOffset},set:{value in store.editPSDSelectionKey(clip.id,key.id){$0.time=value+clip.animationTimeOffset}}),range:-clip.animationTimeOffset...clip.duration,step:1/Double(store.project.fps),unit:"秒")
            TextField(L("名前"),text:Binding(get:{key.name},set:{value in store.editPSDSelectionKey(clip.id,key.id){$0.name=value}})).textFieldStyle(.roundedBorder)
            Menu(L("登録した表情を適用")) {ForEach(clip.psd?.favorites ?? []) {favorite in Button(favorite.name){do {
                let selected=try document.applying(favorite,to:key.selected)
                store.editPSDSelectionKey(clip.id,key.id){$0.selected=selected;$0.name=favorite.name}
            } catch {store.error=error.localizedDescription}}}}
            PanelDisclosure(L("レイヤーを選択"),isExpanded:$expanded) {
                TextField(L("レイヤーを検索"),text:$search).textFieldStyle(.roundedBorder)
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:6) {
                        ForEach(document.layers.filter{!document.isFlipVariant($0) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search))}) {layer in
                            Toggle(layer.label,isOn:Binding(get:{key.selected.contains(layer.id)},set:{enabled in store.editPSDSelectionKey(clip.id,key.id){$0.selected=document.selecting(layer.id,enabled:enabled,in:$0.selected)}}))
                                .disabled(layer.forced).padding(.leading,CGFloat(min(6,document.depth(layer)))*10)
                        }
                    }
                }.frame(height:220)
            }
            if key.time<clip.animationTimeOffset || key.time>clip.animationTimeOffset+clip.duration {Text(L("表示区間の外にある切り替えです。トリムや分割前の状態を保持します。")).foregroundColor(.secondary)}
        }.padding(10).background(Color.primary.opacity(0.04)).cornerRadius(6)
    }
}
