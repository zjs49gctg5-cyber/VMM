import SwiftUI

struct LyricSegmentEditor:View {
    @ObservedObject var store:EditorStore
    @ObservedObject private var clock:PlaybackClock
    @Environment(\.dismiss) private var dismiss
    let original:Clip
    @State private var segments:[LyricWipeSegment]
    @State private var error:String?
    init(store:EditorStore,clip:Clip) {
        self.store=store;self.clock=store.playbackClock;self.original=clip
        let wipe=clip.lyricWipe ?? LyricWipe(end:max(0.001,clip.duration))
        let chars=Array(clip.text),count=max(1,chars.count),length=wipe.end-wipe.start
        let generated=chars.indices.filter{!chars[$0].isNewline}.map{i in LyricWipeSegment(startIndex:i,endIndex:i+1,start:wipe.start+length*Double(i)/Double(count),end:wipe.start+length*Double(i+1)/Double(count))}
        _segments=State(initialValue:wipe.segments ?? generated)
    }
    private func label(_ segment:LyricWipeSegment)->String {
        let chars=Array(original.text),a=max(0,min(chars.count,segment.startIndex)),b=max(a,min(chars.count,segment.endIndex))
        return String(chars[a..<b])
    }
    private func save(){
        NSApp.keyWindow?.makeFirstResponder(nil)
        do {
        guard let current=store.project.clips.first(where:{$0.id==original.id}),current.text==original.text,current.lyricWipe==original.lyricWipe,!store.project.tracks[current.track].locked else{throw VMMError.message("対象が変更またはロックされました。もう一度開いてください。")}
        var wipe=current.lyricWipe ?? LyricWipe(end:max(0.001,current.duration));wipe.segments=segments
        var candidate=current;candidate.lyricWipe=wipe;try candidate.validateAnimation()
        store.edit(current.id){$0.lyricWipe=wipe};dismiss()
    }catch{self.error=error.localizedDescription}}
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            Text(L("歌詞の文字・単語タイミング")).font(.title2)
            Text(L("文字範囲は0から始まり、終了位置は含みません。複数文字を指定すると単語単位でワイプします。時刻はアイテムの先頭からの秒数です。" )).foregroundColor(.secondary)
            HStack {
                Button(store.playing ? L("停止"):L("再生")){if store.playing{store.pause()}else{store.play()}}
                Text(String(format:"%.3f 秒",original.motionTime(at:clock.time))).monospacedDigit()
                Spacer()
                Button(L("区間を追加")){let index=segments.last?.endIndex ?? 0,time=segments.last?.end ?? 0;segments.append(LyricWipeSegment(startIndex:index,endIndex:index+1,start:time,end:time+0.5))}.disabled(segments.count>=2000 || (segments.last?.endIndex ?? 0)>=original.text.count)
            }
            ScrollView {VStack(spacing:8){ForEach($segments){$segment in
                VStack(alignment:.leading,spacing:4) {
                    HStack {Text(label(segment)).lineLimit(1).frame(minWidth:50,alignment:.leading);Spacer();Button(L("削除")){segments.removeAll{$0.id==segment.id}}}
                    HStack {
                        NumberInput(title:"開始文字",value:Binding(get:{Double(segment.startIndex)},set:{segment.startIndex=Int($0.rounded())}),range:0...Double(original.text.count))
                        NumberInput(title:"終了文字",value:Binding(get:{Double(segment.endIndex)},set:{segment.endIndex=Int($0.rounded())}),range:0...Double(original.text.count))
                        NumberInput(title:"開始",value:$segment.start,range:0...86400,unit:"秒")
                        NumberInput(title:"終了",value:$segment.end,range:0...86400,unit:"秒")
                        Button(L("開始を記録")){segment.start=original.motionTime(at:clock.time)}
                        Button(L("終了を記録")){segment.end=original.motionTime(at:clock.time)}
                    }
                }.padding(8).background(Color(nsColor:.controlBackgroundColor)).cornerRadius(6)
            }}}
            if let error {Text(error).foregroundColor(.red)}
            HStack{Spacer();Button(L("キャンセル")){dismiss()};Button(L("適用")){save()}.keyboardShortcut(.defaultAction)}
        }.padding(20).frame(minWidth:1000,minHeight:600)
    }
}
