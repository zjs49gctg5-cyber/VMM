import SwiftUI
import AppKit

struct KaraokePartSpec:Decodable {
    var text:String
    var track:Int
    var beforeColor:String?
    var afterColor:String?
    var topY:Double?
    var bottomY:Double?
}
enum KaraokePartsPlanner {
    static func make(_ parts:[KaraokePartSpec],project:Project)throws->(Project,[Clip]) {
        guard !parts.isEmpty,parts.count<=16 else{throw VMMError.message("パートは1〜16個で指定してください。")}
        var candidate=project,created:[Clip]=[]
        for part in parts {
            guard candidate.tracks.indices.contains(part.track),!candidate.tracks[part.track].locked else{throw VMMError.message("パートのレイヤーが不正またはロックされています。")}
            let top=part.topY ?? 0.77,bottom=part.bottomY ?? 0.87
            guard top.isFinite,bottom.isFinite,(0...1).contains(top),(0...1).contains(bottom) else{throw VMMError.message("パートの位置が不正です。")}
            let lines=try LyricLRC.parse(part.text,fps:candidate.fps)
            var clips=try LyricTemplatePlanner.karaokeClips(lines,track:part.track,fps:candidate.fps,lead:1,tail:0.5,beforeColor:part.beforeColor ?? "FFFFFF",afterColor:part.afterColor ?? "FFDD33")
            for i in clips.indices {clips[i].y=i.isMultiple(of:2) ? top:bottom}
            candidate.clips.append(contentsOf:clips);created.append(contentsOf:clips)
        }
        _=try candidate.validated();return(candidate,created)
    }
}
private struct KaraokePartDraft:Identifiable {
    let id=UUID()
    var text=""
    var track:Double
    var beforeColor="FFFFFF"
    var afterColor="FFDD33"
    var topY=0.77
    var bottomY=0.87
    var spec:KaraokePartSpec {KaraokePartSpec(text:text,track:Int(track.rounded()),beforeColor:beforeColor,afterColor:afterColor,topY:topY,bottomY:bottomY)}
}
struct KaraokePartsSheet:View {
    @ObservedObject var store:EditorStore
    @Environment(\.dismiss) private var dismiss
    @State private var parts:[KaraokePartDraft]
    @State private var error:String?
    init(store:EditorStore){self.store=store;_parts=State(initialValue:[KaraokePartDraft(track:Double(store.selectedTrack))])}
    private func apply(){
        NSApp.keyWindow?.makeFirstResponder(nil)
        do {
        guard !store.busy else{throw VMMError.message("処理中です。")}
        let (project,clips)=try KaraokePartsPlanner.make(parts.map(\.spec),project:store.project)
        store.pause();store.checkpoint();store.project=project;store.selectedIDs=Set(clips.map(\.id));store.selectedID=clips.first?.id;dismiss()
    }catch{self.error=error.localizedDescription}}
    var body:some View {
        VStack(alignment:.leading,spacing:10){
            Text(L("複数パートの歌詞")).font(.title2)
            Text(L("パートごとに行単位LRCを入力します。同時刻の歌詞も別パートとして配置できます。レイヤー番号は0から始まります。" )).foregroundColor(.secondary)
            ScrollView {VStack(spacing:12){ForEach($parts){$part in
                VStack(alignment:.leading,spacing:6){
                    HStack{Text(L("パート"));Spacer();Button(L("削除")){parts.removeAll{$0.id==part.id}}.disabled(parts.count<=1)}
                    TextEditor(text:$part.text).frame(minHeight:90).border(Color.gray)
                    HStack{
                        NumberInput(title:"レイヤー",value:$part.track,range:0...Double(max(0,store.project.tracks.count-1)))
                        NumberInput(title:"上段の位置",value:$part.topY,range:0...1,percent:true)
                        NumberInput(title:"下段の位置",value:$part.bottomY,range:0...1,percent:true)
                    }
                    HStack{
                        ColorPicker(L("歌う前の文字色"),selection:Binding(get:{Color(nsColor:NSColor(hex:part.beforeColor))},set:{part.beforeColor=NSColor($0).hex}),supportsOpacity:false)
                        ColorPicker(L("歌った後の文字色"),selection:Binding(get:{Color(nsColor:NSColor(hex:part.afterColor))},set:{part.afterColor=NSColor($0).hex}),supportsOpacity:false)
                    }
                }.padding(10).background(Color(nsColor:.controlBackgroundColor)).cornerRadius(6)
            }}}
            Button(L("パートを追加")){parts.append(KaraokePartDraft(track:Double(store.selectedTrack)))}.disabled(parts.count>=16)
            if let error {Text(error).foregroundColor(.red)}
            HStack{Spacer();Button(L("キャンセル")){dismiss()};Button(L("まとめて配置")){apply()}.keyboardShortcut(.defaultAction)}
        }.padding(20).frame(minWidth:820,minHeight:600)
    }
}
