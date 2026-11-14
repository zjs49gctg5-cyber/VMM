import SwiftUI

struct LyricRubyEditor:View {
    @ObservedObject var store:EditorStore
    @Environment(\.dismiss) private var dismiss
    let original:Clip
    @State private var ruby:[LyricRuby]
    @State private var error:String?
    init(store:EditorStore,clip:Clip){self.store=store;original=clip;_ruby=State(initialValue:clip.lyricRuby ?? [])}
    private func label(_ item:LyricRuby)->String {
        let chars=Array(original.text),a=max(0,min(chars.count,item.startIndex)),b=max(a,min(chars.count,item.endIndex))
        return String(chars[a..<b])
    }
    private func save(){
        NSApp.keyWindow?.makeFirstResponder(nil)
        do {
        guard let current=store.project.clips.first(where:{$0.id==original.id}),current.text==original.text,current.lyricRuby==original.lyricRuby,!store.project.tracks[current.track].locked else{throw VMMError.message("対象が変更またはロックされました。もう一度開いてください。")}
        var candidate=current;candidate.lyricRuby=ruby.isEmpty ? nil:ruby;try candidate.validateAnimation()
        store.edit(current.id){$0.lyricRuby=candidate.lyricRuby};dismiss()
    }catch{self.error=error.localizedDescription}}
    var body:some View {
        VStack(alignment:.leading,spacing:10){
            Text(L("歌詞のルビ")).font(.title2)
            Text(L("文字範囲は0から始まり、終了位置は含みません。範囲は順番に指定し、改行をまたがないようにしてください。" )).foregroundColor(.secondary)
            Button(L("ルビを追加")){let start=ruby.last?.endIndex ?? 0;ruby.append(LyricRuby(startIndex:start,endIndex:start+1,text:""))}.disabled((ruby.last?.endIndex ?? 0)>=original.text.count || ruby.count>=200)
            ScrollView {VStack(spacing:8){ForEach($ruby){$item in
                HStack {
                    Text(label(item)).frame(minWidth:60,alignment:.leading)
                    NumberInput(title:"開始文字",value:Binding(get:{Double(item.startIndex)},set:{item.startIndex=Int($0.rounded())}),range:0...Double(original.text.count))
                    NumberInput(title:"終了文字",value:Binding(get:{Double(item.endIndex)},set:{item.endIndex=Int($0.rounded())}),range:0...Double(original.text.count))
                    TextField(L("読み"),text:$item.text).textFieldStyle(.roundedBorder)
                    Button(L("削除")){ruby.removeAll{$0.id==item.id}}
                }.padding(8).background(Color(nsColor:.controlBackgroundColor)).cornerRadius(6)
            }}}
            if let error {Text(error).foregroundColor(.red)}
            HStack{Spacer();Button(L("キャンセル")){dismiss()};Button(L("適用")){save()}.keyboardShortcut(.defaultAction)}
        }.padding(20).frame(minWidth:760,minHeight:500)
    }
}
