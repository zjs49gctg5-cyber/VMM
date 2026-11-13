import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct MusicMotionPanel:View {
    @ObservedObject var store:EditorStore
    @State private var kind=MusicMotionKind.pulse
    @State private var strength=0.5
    @State private var midi:MIDISequence?
    @State private var filename=""
    @State private var channel=0
    @State private var useMIDI=false
    @State private var loading=false
    private func loadMIDI(){
        let panel=NSOpenPanel();panel.allowedContentTypes=[UTType(filenameExtension:"mid") ?? .data,UTType(filenameExtension:"midi") ?? .data];panel.allowsMultipleSelection=false
        guard panel.runModal() == .OK,let url=panel.url else{return}
        loading=true;midi=nil;filename="";useMIDI=true
        Task {
            do {
                let parsed=try await Task.detached(priority:.userInitiated) { () throws -> MIDISequence in
                    let values=try url.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey]),size=values.fileSize ?? 0
                    guard values.isRegularFile == true,size>0,size<=2*1024*1024 else{throw VMMError.message("MIDIファイルは2 MiBまでです。")}
                    let file=try FileHandle(forReadingFrom:url);defer{try? file.close()}
                    let data=try file.read(upToCount:2*1024*1024+1) ?? Data()
                    guard !data.isEmpty,data.count<=2*1024*1024 else{throw VMMError.message("MIDIファイルは2 MiBまでです。")}
                    return try MIDIReader.parse(data)
                }.value
                midi=parsed;filename=url.lastPathComponent;useMIDI=true
            }catch{store.error=error.localizedDescription}
            loading=false
        }
    }
    var body:some View {VStack(alignment:.leading,spacing:12){
        Text(L("BPM・MIDIに合わせたモーション")).vmmFont(size:16,weight:.semibold)
        Text(L("選択アイテムへ編集可能なキーフレームを追加します。対象項目の既存キーは上書きしません。")).foregroundColor(.secondary)
        VMMMenuPicker(L("動き"),selection:$kind){VMMOptions(MusicMotionKind.allCases,id:\.self){VMMChoice(text:L($0.title),value:$0)}}
        NumberInput(title:"動きの強さ",value:$strength,range:0...1,percent:true)
        Toggle(L("MIDIの音符に同期"),isOn:$useMIDI)
        HStack {Button(L("MIDIを読み込む…")){loadMIDI()}.disabled(loading);if loading {ProgressView().controlSize(.small)};if !filename.isEmpty {Text(filename).lineLimit(1)}}
        if useMIDI {
            if let midi {Text(String(format:L("%dトラック・%d音符・テンポ変更%d件"),midi.tracks,midi.notes.count,midi.tempoChanges)).foregroundColor(.secondary)
                VMMMenuPicker(L("MIDIチャンネル"),selection:$channel){VMMChoice(text:L("すべて"),value:0);VMMOptions(Array(1...16),id:\.self){VMMChoice(text:String($0),value:$0)}}
            } else {Text(L("先にMIDIを読み込んでください。")).foregroundColor(.secondary)}
            Text(L("MIDIの先頭を現在の再生位置に合わせます。音符の強さを動きに反映します。")).foregroundColor(.secondary)
        } else {Text(L("プロジェクトのBPMと拍の開始位置に合わせ、現在位置以降の拍に同期します。")).foregroundColor(.secondary)}
        Button(L("キーフレームを作成")) {
            do {
                guard let id=store.selectedID else{throw VMMError.message("映像アイテムを選択してください。")}
                let source:MusicMotionSource
                if useMIDI {guard let midi else{throw VMMError.message("先にMIDIを読み込んでください。")} ;source = .midi(midi,from:store.playhead,channel:channel)}
                else {source = .bpm(store.project.rhythm ?? RhythmSettings(),from:store.playhead)}
                try store.applyMusicMotion(id:id,kind:kind,strength:strength,source:source);store.status="音楽に合わせたキーフレームを作成しました。"
            }catch{store.error=error.localizedDescription}
        }.disabled(loading || store.selectedID == nil || (useMIDI && midi == nil))
        Text(L("SMF形式0/1・PPQNに対応。テンポ変更を反映します。同じフレームの音符は1つにまとめ、選択アイテム内の最大249点までです。")).foregroundColor(.secondary)
    }}
}
