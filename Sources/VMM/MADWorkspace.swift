import SwiftUI
import AppKit

struct MADWorkspace:View {
    @ObservedObject var store:EditorStore
    @State private var page=0
    @State private var strength=1.0
    @State private var beats=0.5
    @State private var gate=0.9
    @State private var pattern="0 0 - 7 0 12 7 -"
    @State private var selectedStep=0
    @State private var taps:[Double]=[]
    @State private var showLyrics=false
    init(store:EditorStore,initialPage:Int=0){self.store=store;_page=State(initialValue:initialPage)}
    private func perform(_ action:()throws->Void){do{try action()}catch{store.error=error.localizedDescription}}
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Toggle(L("音MADモード"),isOn:Binding(get:{store.project.rhythmEnabled},set:{v in store.editRhythm{$0.enabled=v}}))
                Spacer()
                Button(store.playing ? L("停止"):L("再生")){store.togglePlayback()}
                Button(L("ワークスペース設定…")){store.workspaceWindows.show(.workspaceSettings)}
            }
            if !store.project.rhythmEnabled {Text(L("有効にすると拍グリッドと音程編集が使えます。設定と素材はプロジェクトに保存します。")).foregroundColor(.secondary)}
            HSplitView {
                ScrollView {
                    VStack(alignment:.leading,spacing:12) {
                        RhythmProjectControls(store:store,inMADMode:true)
                        Button(L("歌詞演出を作成…")){showLyrics=true}
                        Button(L("タップでBPMを合わせる")) {
                            let now=ProcessInfo.processInfo.systemUptime
                            if let last=taps.last,now-last>2 {taps=[]}
                            taps.append(now);taps=Array(taps.suffix(8))
                            if taps.count>=2 {let bpm=60*Double(taps.count-1)/(taps.last!-taps.first!);if (30...300).contains(bpm){store.editRhythm{$0.bpm=bpm}}}
                        }
                        Text(L("タイムラインの選択と連動します。通常のUndo／Redoで戻せます。")).foregroundColor(.secondary)
                    }.padding(12)
                }.frame(minWidth:260,idealWidth:300,maxWidth:400)
                VStack(alignment:.leading,spacing:12) {
                    Picker(L("編集"),selection:$page){Text(L("拍合わせ")).tag(0);Text(L("音程パターン")).tag(1);Text(L("音楽モーション")).tag(2)}.pickerStyle(.segmented)
                    ScrollView {
                        VStack(alignment:.leading,spacing:14) {
                            if page==0 {timing}
                            else if page==1 {patternEditor}
                            else {MusicMotionPanel(store:store)}
                            Divider()
                            Text("\(L("選択中"))：\(store.selection.count)").foregroundColor(.secondary)
                            ForEach(store.project.clips.filter{store.selection.contains($0.id)}) {clip in
                                HStack {Text(clip.name).lineLimit(1);Spacer();Text(String(format:"%.3fs / %+.1f",clip.duration,clip.pitchSemitones ?? 0)).monospacedDigit()}
                            }
                            if let clip=store.selected,[.audio,.video,.speech].contains(clip.kind) {RhythmClipControls(store:store,clip:clip)}
                        }.padding(12)
                    }
                }.padding(12).frame(minWidth:440,maxWidth:.infinity).disabled(!store.project.rhythmEnabled)
            }
            Text(L(store.status)).foregroundColor(.secondary).lineLimit(2)
        }.padding(16).disabled(store.busy).sheet(isPresented:$showLyrics){LyricTemplateSheet(store:store)}
    }
    private var timing:some View {
        VStack(alignment:.leading,spacing:12) {
            Text(L("選択した音声・動画をまとめて編集")).vmmFont(size:16,weight:.semibold)
            NumberInput(title:"拍合わせの強さ",value:$strength,range:0...1,percent:true)
            Button(L("開始位置を拍に合わせる")){perform{try store.quantizeMAD(store.selection,strength:strength)}}.disabled(store.selection.isEmpty)
            NumberInput(title:"音符の長さ",value:$beats,range:0.125...64,unit:"拍")
            Button(L("音程を保って音符長に伸縮")){perform{try store.fitMAD(store.selection,beats:beats)}}.disabled(store.selection.isEmpty)
            Text(L("1拍＝4分音符。切り出し範囲を保ち、速度25〜400%で伸縮します。リンク・子・ロックのある素材は解除してから編集してください。")).foregroundColor(.secondary)
        }
    }
    private var patternEditor:some View {
        VStack(alignment:.leading,spacing:12) {
            Text(L("選択素材から音程パターンを作成")).vmmFont(size:16,weight:.semibold)
            TextField(L("半音を空白区切りで入力"),text:$pattern).textFieldStyle(.roundedBorder)
            HStack {Button(L("反復")){pattern="0 0 0 0 0 0 0 0"};Button(L("上昇")){pattern="0 2 4 5 7 9 11 12"};Button(L("跳躍")){pattern="0 - 12 - 7 7 0 -"}}
            if let notes=try? MADArrangement.pitches(pattern) {
                LazyVGrid(columns:Array(repeating:GridItem(.flexible(minimum:44)),count:8),spacing:8) {
                    ForEach(notes.indices,id:\.self) {i in
                        Button {selectedStep=i} label:{VStack {Text("\(i+1)").foregroundColor(.secondary);Text(notes[i].map{String(format:"%+.0f",$0)} ?? "—")}.frame(maxWidth:.infinity).padding(6).background(selectedStep==i ? Color.accentColor.opacity(0.3):Color.gray.opacity(0.12)).cornerRadius(5)}.buttonStyle(.plain)
                    }
                }
                if notes.indices.contains(selectedStep) {
                    NumberInput(title:"選択ステップの音程",value:Binding(get:{notes[selectedStep] ?? 0},set:{v in var updated=notes;updated[selectedStep]=v;pattern=updated.map{$0.map{String($0)} ?? "-"}.joined(separator:" ")}),range:-24...24,unit:"半音")
                    Toggle(L("休符"),isOn:Binding(get:{notes[selectedStep]==nil},set:{v in var updated=notes;updated[selectedStep]=v ? nil:0;pattern=updated.map{$0.map{String($0)} ?? "-"}.joined(separator:" ")}))
                }
            }
            NumberInput(title:"ゲート",value:$gate,range:0.05...1,percent:true)
            Text(L("0＝素材の音程、12＝1オクターブ上、-＝休符。拍グリッドの音符間隔で、現在位置に追加します。元の素材は残します。")).foregroundColor(.secondary)
            Button(L("現在位置にパターンを配置")){perform{guard let id=store.selectedID else{throw VMMError.message("素材を選択してください。")};_=try store.patternMAD(id,pitches:MADArrangement.pitches(pattern),at:store.playhead,gate:gate)}}.disabled(store.selectedID==nil)
        }
    }
}
