import SwiftUI
import AppKit

enum BatchKey:Codable,Identifiable {
    case property(AnimatedProperty,AnimationKeyframe)
    case effect(UUID,EffectKind,AnimationKeyframe)
    case psd(PSDSelectionKeyframe)
    var id:UUID {switch self {case .property(_,let k),.effect(_,_,let k):return k.id;case .psd(let k):return k.id}}
    var time:Double {switch self {case .property(_,let k),.effect(_,_,let k):return k.time;case .psd(let k):return k.time}}
    var title:String {switch self {case .property(let p,let k):return "\(L(p.title)) · \(k.value)";case .effect(_,let effect,let k):return "\(L(effect.title)) · \(k.value)";case .psd(let k):return "PSD · \(k.name)"}}
    func transformed(anchor:Double,offset:Double,scale:Double,copy:Bool)->BatchKey {
        let t=anchor+(time-anchor)*scale+offset
        switch self {
        case .property(let p,var k):k.time=t;if copy{k.id=UUID()};return .property(p,k)
        case .effect(let id,let e,var k):k.time=t;if copy{k.id=UUID()};return .effect(id,e,k)
        case .psd(var k):k.time=t;if copy{k.id=UUID()};return .psd(k)
        }
    }
}
struct KeyframePacket:Codable {var keys:[BatchKey];var psdAsset:UUID?}
extension Clip {
    var batchKeys:[BatchKey] {
        ((animation?.tracks ?? []).flatMap{track in track.keys.map{BatchKey.property(track.property,$0)}}+(effects ?? []).flatMap{effect in effect.keys.map{BatchKey.effect(effect.id,effect.kind,$0)}}+(psd?.selectionKeys ?? []).map{BatchKey.psd($0)}).sorted{$0.time<$1.time}
    }
    mutating func removeBatchKeys(_ ids:Set<UUID>) {
        if animation != nil{for i in animation!.tracks.indices{animation!.tracks[i].keys.removeAll{ids.contains($0.id)}}}
        if effects != nil{for i in effects!.indices{effects![i].keys.removeAll{ids.contains($0.id)}}}
        psd?.selectionKeys?.removeAll{ids.contains($0.id)}
    }
    mutating func insertBatchKeys(_ keys:[BatchKey])throws {
        for key in keys {
            switch key {
            case .property(let property,let value):
                guard availableAnimatedProperties.contains(property) else{throw VMMError.message("このアイテムには貼り付けられないキー項目があります。")}
                var a=animation ?? ClipAnimation()
                if let i=a.tracks.firstIndex(where:{$0.property==property}){a.tracks[i].keys.append(value);a.tracks[i].keys.sort{$0.time<$1.time}}
                else{a.tracks.append(AnimationTrack(property:property,keys:[value]))};animation=a
            case .effect(let id,let kind,let value):
                let sameKind=(effects ?? []).indices.filter{effects![$0].kind==kind}
                guard let i=effects?.firstIndex(where:{$0.id==id}) ?? (sameKind.count==1 ? sameKind.first:nil) else{throw VMMError.message("貼り付け先に同じエフェクトを1つ追加してください。")}
                effects![i].keys.append(value);effects![i].keys.sort{$0.time<$1.time}
            case .psd(let value):
                guard psd != nil else{throw VMMError.message("立ち絵の切り替えキーは同じPSDに貼り付けてください。")}
                var list=psd?.selectionKeys ?? [];list.append(value);psd?.selectionKeys=list.sorted{$0.time<$1.time}
            }
        }
    }
}
@MainActor extension EditorStore {
    static var keyframePasteboard:NSPasteboard.PasteboardType {NSPasteboard.PasteboardType("app.vmm.keyframes.v1")}
    func changeKeyframeTimes(_ clipID:UUID,selection:Set<UUID>,offset:Double,scale:Double)throws {
        guard offset.isFinite,scale.isFinite,(0.001...1000).contains(scale),let c=project.clips.first(where:{$0.id==clipID}) else{throw VMMError.message("キーの移動・伸縮が不正です。")}
        let keys=c.batchKeys.filter{selection.contains($0.id)}
        guard let anchor=keys.map(\.time).min(),!busy,!project.tracks[c.track].locked else{return}
        var candidate=c;candidate.removeBatchKeys(selection)
        try candidate.insertBatchKeys(keys.map{$0.transformed(anchor:anchor,offset:offset,scale:scale,copy:false)})
        var p=project;p.clips[p.clips.firstIndex{$0.id==clipID}!]=candidate;_=try p.validated()
        edit(clipID){$0=candidate}
    }
    func copyKeyframes(_ clip:Clip,selection:Set<UUID>,pasteboard:NSPasteboard = .general)throws {
        let keys=clip.batchKeys.filter{selection.contains($0.id)};guard !keys.isEmpty else{return}
        let data=try JSONEncoder().encode(KeyframePacket(keys:keys,psdAsset:clip.assetID))
        pasteboard.clearContents();pasteboard.setData(data,forType:Self.keyframePasteboard)
    }
    func pasteKeyframes(_ clipID:UUID,pasteboard:NSPasteboard = .general)throws {
        guard let data=pasteboard.data(forType:Self.keyframePasteboard),data.count<=8*1024*1024,let c=project.clips.first(where:{$0.id==clipID}),!busy,!project.tracks[c.track].locked else{return}
        let packet=try JSONDecoder().decode(KeyframePacket.self,from:data)
        guard packet.keys.count<=20000,let anchor=packet.keys.map(\.time).min() else{throw VMMError.message("キーの貼り付けデータが不正です。")}
        if packet.keys.contains(where:{if case .psd=$0{return true};return false}),packet.psdAsset != c.assetID {throw VMMError.message("立ち絵の切り替えキーは同じPSDに貼り付けてください。")}
        var candidate=c
        try candidate.insertBatchKeys(packet.keys.map{$0.transformed(anchor:anchor,offset:c.motionTime(at:playhead)-anchor,scale:1,copy:true)})
        var p=project;p.clips[p.clips.firstIndex{$0.id==clipID}!]=candidate;_=try p.validated()
        edit(clipID){$0=candidate}
    }
}
struct KeyframeBatchControls:View {
    @ObservedObject var store:EditorStore
    let clip:Clip
    @State private var selected:Set<UUID>=[]
    @State private var offset=0.0
    @State private var scale=1.0
    @State private var error:String?
    var body:some View {
        PanelDisclosure(L("キーの一括編集")) {
            VStack(alignment:.leading,spacing:10) {
                HStack {Button(L("すべて選択")){selected=Set(clip.batchKeys.map(\.id))};Button(L("選択解除")){selected=[]};Spacer();Text("\(selected.count)")}
                ScrollView {LazyVStack(alignment:.leading){ForEach(clip.batchKeys){key in
                    Toggle(isOn:Binding(get:{selected.contains(key.id)},set:{if $0{selected.insert(key.id)}else{selected.remove(key.id)}})){Text(String(format:"%.3f s · %@",key.time-clip.animationTimeOffset,key.title)).vmmFont(size:12)}
                }}}.frame(maxHeight:180)
                HStack {Button(L("コピー")){attempt{try store.copyKeyframes(clip,selection:selected)}}.disabled(selected.isEmpty);Button(L("現在位置に貼り付け")){attempt{try store.pasteKeyframes(clip.id)}}}
                NumberInput(title:"時間移動",value:$offset,range:-86400...86400,unit:"秒")
                NumberInput(title:"時間伸縮",value:$scale,range:0.001...1000,percent:true)
                Button(L("選択キーに適用")){attempt{try store.changeKeyframeTimes(clip.id,selection:selected,offset:offset,scale:scale)}}.disabled(selected.isEmpty)
                Text(L("選択キーの先頭を基準に伸縮します。同時刻の衝突は適用せず知らせます。")).foregroundColor(.secondary).vmmFont(size:12)
            }.padding(.top,8)
        }.onChange(of:clip.id){_ in selected=[]}
        .onChange(of:clip.batchKeys.map(\.id)){ids in selected.formIntersection(ids)}
        .alert(L("確認してください"),isPresented:Binding(get:{error != nil},set:{if !$0{error=nil}})){Button("OK"){error=nil}}message:{Text(L(error ?? ""))}
    }
    private func attempt(_ action:()throws->Void){do{try action()}catch{self.error=error.localizedDescription}}
}
