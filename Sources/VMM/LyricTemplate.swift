import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum LyricMotion:String,CaseIterable {
    case none,fade,bounce,zoom,wave
    var title:String {switch self {case .none:return "動きなし";case .fade:return "フェード";case .bounce:return "バウンド";case .zoom:return "拡大";case .wave:return "波打つ文字"}}
    var animation:CharacterAnimation? {
        guard self != .none else{return nil}
        var result=CharacterAnimation()
        switch self {case .none:break;case .fade:result.kind = .fade;case .bounce:result.kind = .bounce;case .zoom:result.kind = .zoom;case .wave:result.kind = .wave}
        result.delay=0.04;result.duration=0.4;return result
    }
}
struct LyricDraftLine:Identifiable,Equatable {
    var id=UUID()
    var text:String
    var start:Double
    var end:Double
    /// Segment times are relative to the line's singing start.
    var segments:[LyricWipeSegment]?
    var ruby:[LyricRuby]?
    /// File-level tags retained on the first line for a lossless draft export.
    var lrcMetadata:[String]?
}
enum LyricTemplatePlanner {
    static func shifted(_ lines:[LyricDraftLine],by offset:Double,fps:Int)throws->[LyricDraftLine] {
        guard fps>0,offset.isFinite,!lines.isEmpty else{throw VMMError.message("歌詞の時刻が不正です。")}
        let shift=(offset*Double(fps)).rounded()/Double(fps)
        let changed=lines.map{line in var result=line;result.start+=shift;result.end+=shift;return result}
        _=try clips(changed,track:0,fps:fps,motion:.none)
        return changed
    }
    static func record(_ lines:inout [LyricDraftLine],index:Int,time:Double,fps:Int)throws {
        guard fps>0,lines.indices.contains(index),time.isFinite,time>=0,time<=86400 else{throw VMMError.message("歌詞の時刻が不正です。")}
        let frame=1/Double(fps),value=(time*Double(fps)).rounded()/Double(fps)
        guard value<=86400-frame,index==0 || value>=lines[index-1].start+frame else{throw VMMError.message("前の行より後の時刻を記録してください。")}
        var candidate=lines
        if index>0 {
            let previous=candidate[index-1]
            guard previous.segments?.allSatisfy({$0.end<=value-previous.start+0.0001}) ?? true else {
                throw VMMError.message("前の行の文字タイミングが終了するより後を記録してください。")
            }
            candidate[index-1].end=value
        }
        let required=candidate[index].segments?.map(\.end).max() ?? 0
        candidate[index].start=value;candidate[index].end=max(candidate[index].end,value+max(frame,required))
        guard candidate[index].end<=86400 else{throw VMMError.message("歌詞の時刻が不正です。")}
        lines=candidate
    }
    static func previewSize(width:Int,height:Int)->CGSize {
        let factor=640/Double(max(1,width,height))
        return CGSize(width:max(1,round(Double(width)*factor)),height:max(1,round(Double(height)*factor)))
    }
    static func previewTime(_ line:LyricDraftLine,fps:Int)->Double {
        let scale=Double(fps),first=Int((line.start*scale).rounded()),last=Int((line.end*scale).rounded())
        return Double(min(last-1,first+Int(min(0.35,(line.end-line.start)*0.5)*scale)))/scale
    }
    static func distribute(_ source:String,start:Double,interval:Double,fps:Int)throws->[LyricDraftLine] {
        guard fps>0,start.isFinite,interval.isFinite,start>=0,start<=86400,interval>=1/Double(fps),interval<=3600,source.utf8.count<=1024*1024 else {throw VMMError.message("歌詞の開始位置または間隔が不正です。")}
        let lines=source.components(separatedBy:.newlines).map{$0.trimmingCharacters(in:.whitespacesAndNewlines)}.filter{!$0.isEmpty}
        guard !lines.isEmpty,lines.count<=200,lines.allSatisfy({$0.count<=10000}) else {throw VMMError.message("歌詞は1〜200行で入力してください。")}
        let scale=Double(fps)
        return try lines.enumerated().map { index,text in
            let first=((start+Double(index)*interval)*scale).rounded()/scale
            let last=((start+Double(index+1)*interval)*scale).rounded()/scale
            guard first>=0,last>first,last<=86400 else {throw VMMError.message("歌詞の時間がプロジェクトの範囲外です。")}
            return LyricDraftLine(text:text,start:first,end:last)
        }
    }
    static func clips(_ lines:[LyricDraftLine],track:Int,fps:Int,motion:LyricMotion)throws->[Clip] {
        guard fps>0,!lines.isEmpty,lines.count<=200 else {throw VMMError.message("歌詞は1〜200行で入力してください。")}
        let scale=Double(fps),epsilon=1e-7
        var previous=0.0
        return try lines.map { line in
            guard !line.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,line.text.count<=10000,
                  line.start.isFinite,line.end.isFinite,line.start>=previous-epsilon,line.end<=86400,
                  line.end-line.start>=1/scale-epsilon,
                  abs(line.start*scale-(line.start*scale).rounded())<epsilon,abs(line.end*scale-(line.end*scale).rounded())<epsilon else {throw VMMError.message("歌詞の文章・時刻・順序を確認してください。")}
            previous=line.end
            var clip=Clip(kind:.text,name:String(line.text.prefix(40)),track:track,start:line.start,duration:line.end-line.start,text:line.text)
            clip.textAnimation=motion.animation;return clip
        }
    }
    static func karaokeClips(_ lines:[LyricDraftLine],track:Int,fps:Int,lead:Double,tail:Double,beforeColor:String="FFFFFF",afterColor:String="FFDD33")throws->[Clip] {
        guard lead.isFinite,tail.isFinite,(0...10).contains(lead),(0...10).contains(tail) else{throw VMMError.message("歌詞の表示時間が不正です。")}
        guard beforeColor.count==6,beforeColor.allSatisfy({$0.isASCII && $0.isHexDigit}) else{throw VMMError.message("歌詞の色が不正です。")}
        var result=try clips(lines,track:track,fps:fps,motion:.none)
        let scale=Double(fps)
        let starts=lines.indices.map {i -> Double in
            let previous=i>=2 ? lines[i-2].end:0
            return min(lines[i].start,max(previous,((lines[i].start-lead)*scale).rounded()/scale))
        }
        for i in lines.indices {
            let start=starts[i],limit=i+2<lines.count ? starts[i+2]:86400
            let end=min(limit,86400,max(lines[i].end,((lines[i].end+tail)*scale).rounded()/scale))
            guard lines[i].segments?.allSatisfy({$0.start>=0 && $0.end<=lines[i].end-lines[i].start+0.0001}) ?? true else{throw VMMError.message("文字タイミングが歌詞行の範囲外です。")}
            result[i].start=start;result[i].duration=end-start;result[i].y=i.isMultiple(of:2) ? 0.77:0.87
            result[i].color=beforeColor
            result[i].lyricWipe=LyricWipe(start:lines[i].start-start,end:lines[i].end-start,color:afterColor)
            result[i].lyricWipe?.segments=lines[i].segments?.map{segment in var item=segment;item.start+=lines[i].start-start;item.end+=lines[i].start-start;return item}
            result[i].lyricRuby=lines[i].ruby
            try result[i].validateAnimation()
        }
        return result
    }
}
@MainActor extension EditorStore {
    func lyricCandidate(lines:[LyricDraftLine],trackID:UUID,fps:Int,motion:LyricMotion,karaoke:Bool=false,lead:Double=1,tail:Double=0.5,beforeColor:String="FFFFFF",afterColor:String="FFDD33")throws->(Project,[Clip]) {
        guard !busy,project.fps==fps,let track=project.tracks.firstIndex(where:{$0.id==trackID}),!project.tracks[track].locked else {throw VMMError.message("配置先のレイヤーまたはFPSが変更されています。")}
        guard karaoke || lines.allSatisfy({$0.segments == nil && $0.ruby == nil}) else{throw VMMError.message("文字タイミングやルビを保持するにはカラオケ字幕を有効にしてください。")}
        let clips=try karaoke ? LyricTemplatePlanner.karaokeClips(lines,track:track,fps:fps,lead:lead,tail:tail,beforeColor:beforeColor,afterColor:afterColor):LyricTemplatePlanner.clips(lines,track:track,fps:fps,motion:motion)
        var candidate=project;candidate.clips.append(contentsOf:clips);_=try candidate.validated();return(candidate,clips)
    }
    func placeLyricTemplate(lines:[LyricDraftLine],trackID:UUID,fps:Int,motion:LyricMotion,karaoke:Bool=false,lead:Double=1,tail:Double=0.5,beforeColor:String="FFFFFF",afterColor:String="FFDD33")throws {
        let (candidate,clips)=try lyricCandidate(lines:lines,trackID:trackID,fps:fps,motion:motion,karaoke:karaoke,lead:lead,tail:tail,beforeColor:beforeColor,afterColor:afterColor)
        pause();checkpoint();project=candidate;selectedIDs=Set(clips.map(\.id));selectedID=clips.first?.id
    }
}

struct LyricTemplateSheet:View {
    @ObservedObject var store:EditorStore
    @ObservedObject private var clock:PlaybackClock
    @Environment(\.dismiss) private var dismiss
    let trackID:UUID
    let fps:Int
    @State private var source=""
    @State private var start:Double
    @State private var interval=2.0
    @State private var beats=4.0
    @State private var useBeats=true
    @State private var motion=LyricMotion.bounce
    @State private var karaoke=false
    @State private var lead=1.0
    @State private var tail=0.5
    @State private var timingOffset=0.0
    @State private var beforeColor="FFFFFF"
    @State private var afterColor="FFDD33"
    @State private var showParts=false
    @State private var alignTask:Task<Void,Never>?
    @State private var alignmentMethod="speech"
    @AppStorage(LocalVocalSeparation.pythonKey) private var alignmentPython=""
    @AppStorage(LocalVocalSeparation.modelsKey) private var alignmentModels=""
    @State private var alignment:[LyricAlignmentMatch]=[]
    @State private var lines:[LyricDraftLine]=[]
    @State private var selected:UUID?
    @State private var preview:NSImage?
    @State private var error:String?
    @State private var previewRevision=0
    @State private var rendering=false
    init(store:EditorStore){self.store=store;self.clock=store.playbackClock;trackID=store.project.tracks[store.selectedTrack].id;fps=store.project.fps;_start=State(initialValue:store.playhead)}
    private func prepare(){do {
        let seconds=useBeats ? beats*60/(store.project.rhythm ?? RhythmSettings()).bpm:interval
        lines=try LyricTemplatePlanner.distribute(source,start:start,interval:seconds,fps:fps);selected=lines.first?.id;alignment=[];invalidatePreview();error=nil
    }catch{self.error=error.localizedDescription}}
    private func invalidatePreview(){preview=nil;previewRevision+=1}
    private func importLRC(){
        let panel=NSOpenPanel();panel.allowedContentTypes=[UTType(filenameExtension:"lrc") ?? .plainText,UTType(filenameExtension:"kra") ?? .plainText,.plainText];guard panel.runModal() == .OK,let url=panel.url else{return}
        do {
            let size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
            guard size<=1_048_576 else{throw VMMError.message("歌詞ファイルが大きすぎます。")}
            let data=try Data(contentsOf:url)
            guard let text=String(data:data,encoding:.utf8) ?? String(data:data,encoding:.shiftJIS) else{throw VMMError.message("歌詞はUTF-8またはShift-JISで保存してください。")}
            let parsed=try LyricLRC.parse(text,fps:fps)
            lines=parsed;source=parsed.map(\.text).joined(separator:"\n");selected=parsed.first?.id;karaoke=true;alignment=[];error=nil;invalidatePreview()
        } catch {self.error=error.localizedDescription}
    }
    private func exportLRC(){
        do {
            let text=try LyricLRC.encode(lines,fps:fps)
            let panel=NSSavePanel();panel.nameFieldStringValue="lyrics.lrc";panel.allowedContentTypes=[UTType(filenameExtension:"lrc") ?? .plainText]
            guard panel.runModal() == .OK,let url=panel.url else{return}
            try text.write(to:url,atomically:true,encoding:.utf8);error=nil
        } catch {self.error=error.localizedDescription}
    }
    private func recordTiming(){
        guard let selected,let index=lines.firstIndex(where:{$0.id==selected}) else{return}
        do {try LyricTemplatePlanner.record(&lines,index:index,time:clock.time,fps:fps)
            if index+1<lines.count {self.selected=lines[index+1].id}
            error=nil;invalidatePreview()
        } catch {self.error=error.localizedDescription}
    }
    private func alignFromAudio(){do {
        guard alignTask==nil,!lines.isEmpty,let sourceClip=store.selected,store.selection == Set([sourceClip.id]) else{throw VMMError.message("歌詞を配置候補にしてから音声・動画を１つ選択してください。")}
        let snapshot=store.project,directory=store.directory,asset=try TranscriptPlanner.validateSource(sourceClip,project:snapshot,maximumSeconds:LyricAlignment.maximumSeconds)
        let url=directory.appendingPathComponent("Media").appendingPathComponent(asset.file)
        guard FileManager.default.fileExists(atPath:url.path) else{throw VMMError.message("音声素材が見つかりません。")}
        let text=lines.map(\.text).joined(separator:"\n"),method=alignmentMethod,python=alignmentPython,models=alignmentModels
        error=nil;alignment=[]
        alignTask=Task {
            do {
                let matches:[LyricAlignmentMatch]
                if method=="separated" {matches=try await LocalVocalSeparation.align(source:url,clip:sourceClip,text:text,language:"ja-JP",fps:fps,python:python,models:models,recognizer:{url,clip,language,hints in try await LocalTranscription.recognize(source:url,clip:clip,language:language,hints:hints)})}
                else {matches=try await LyricAlignment.recognize(text:text,source:url,clip:sourceClip,language:"ja-JP",fps:fps,using:{url,clip,language,hints in try await LocalTranscription.recognize(source:url,clip:clip,language:language,hints:hints)})}
                try Task.checkCancellation()
                guard store.project==snapshot,store.directory==directory,store.selectedID==sourceClip.id,lines.map(\.text).joined(separator:"\n")==text else{throw VMMError.message("解析中に対象または歌詞が変更されました。もう一度実行してください。")}
                alignment=matches
            }catch is CancellationError {} catch {self.error=error.localizedDescription}
            alignTask=nil
        }
    }catch{self.error=error.localizedDescription}}
    private func separateOnly(){do {
        guard alignTask==nil,let clip=store.selected,store.selection == Set([clip.id]) else{throw VMMError.message("分離する音声・動画を１つ選択してください。")}
        let snapshot=store.project,directory=store.directory,asset=try TranscriptPlanner.validateSource(clip,project:snapshot,maximumSeconds:LyricAlignment.maximumSeconds)
        let url=directory.appendingPathComponent("Media").appendingPathComponent(asset.file),python=alignmentPython,models=alignmentModels
        guard FileManager.default.fileExists(atPath:url.path) else{throw VMMError.message("音声素材が見つかりません。")}
        error=nil
        alignTask=Task {
            do {try await LocalVocalSeparation.withVocals(source:url,clip:clip,python:python,models:models) {vocals,_ in
                try Task.checkCancellation()
                guard store.project==snapshot,store.directory==directory,store.selectedID==clip.id else{throw VMMError.message("処理中に対象が変更されました。もう一度実行してください。")}
                _=try await store.importURLs([vocals]);store.status=L("分離した歌声を素材ライブラリに追加しました。")
            }}catch is CancellationError {} catch {self.error=error.localizedDescription};alignTask=nil
        }
    }catch{self.error=error.localizedDescription}}
    private func selectAlignmentPath(directory:Bool){
        let panel=NSOpenPanel();panel.canChooseFiles = !directory;panel.canChooseDirectories=directory;panel.allowsMultipleSelection=false;panel.resolvesAliases=false
        if panel.runModal() == .OK,let url=panel.url {if directory {alignmentModels=url.path} else {alignmentPython=url.path}}
    }
    private func applyAlignment(){
        do {lines=try LyricAlignment.applying(alignment,to:lines,fps:fps);error=nil;invalidatePreview()}
        catch {self.error=error.localizedDescription}
    }
    private func applyAlignmentLine(_ match:LyricAlignmentMatch){
        do {lines=try LyricAlignment.applying([match],to:lines,fps:fps);error=nil;invalidatePreview()}
        catch {self.error=error.localizedDescription}
    }
    private func updatePreview(){do {
        guard !rendering else{return}
        let (project,_)=try store.lyricCandidate(lines:lines,trackID:trackID,fps:fps,motion:motion,karaoke:karaoke,lead:lead,tail:tail,beforeColor:beforeColor,afterColor:afterColor)
        guard let line=lines.first(where:{$0.id==selected}) ?? lines.first else{return}
        let sample=LyricTemplatePlanner.previewTime(line,fps:fps)
        let size=LyricTemplatePlanner.previewSize(width:project.width,height:project.height)
        let folder=store.directory,revision=previewRevision,projectRevision=store.projectRevision;rendering=true;error=nil
        Task {
            let result=await Task.detached(priority:.userInitiated) { () -> CGImage? in
                guard let context=RasterTools.bitmap(size) else{return nil}
                let renderer=FrameRenderer();renderer.draw(project:project,directory:folder,time:sample,context:context,size:size)
                guard renderer.renderingFailure == nil else{return nil}
                return context.makeImage()
            }.value
            rendering=false
            guard revision==previewRevision,projectRevision==store.projectRevision else{return}
            if let image=result {preview=NSImage(cgImage:image,size:size)} else{error=L("プレビューを作成できません。")}
        }
    }catch{self.error=error.localizedDescription}}
    var body:some View {VStack(alignment:.leading,spacing:10){
        Text(L("歌詞・MADテキストを作成")).font(.title2)
        Text(L("1行を1アイテムとして配置します。時刻と文章は配置前後に編集できます。")).foregroundColor(.secondary)
        HSplitView {
            VStack(alignment:.leading,spacing:8) {
                Text(L("歌詞（1行ずつ）"));TextEditor(text:$source).frame(minHeight:100,idealHeight:140).border(Color.gray)
                Button(L("複数パートを編集…")){showParts=true}.sheet(isPresented:$showParts){KaraokePartsSheet(store:store)}
                HStack{Button(L("LRCを読み込む…")){importLRC()};Button(L("LRCを書き出す…")){exportLRC()}.disabled(lines.isEmpty)}
                Text(L("LRC/KRAの文字タイミング・ルビを読み込みます。配置時はカラオケ字幕を有効にしてください。" )).foregroundColor(.secondary)
                NumberInput(title:"開始",value:$start,range:0...86400,unit:"秒")
                Toggle(L("BPMの拍で間隔を指定"),isOn:$useBeats)
                if useBeats {NumberInput(title:"1行の拍数",value:$beats,range:0.125...64);Text(String(format:"BPM %.1f",(store.project.rhythm ?? RhythmSettings()).bpm)).foregroundColor(.secondary)}
                else {NumberInput(title:"1行の長さ",value:$interval,range:(1/Double(fps))...3600,unit:"秒")}
                Toggle(L("カラオケ字幕（上下２段）"),isOn:$karaoke).onChange(of:karaoke){_ in invalidatePreview()}
                if karaoke {
                    NumberInput(title:"歌う前に表示",value:$lead,range:0...10,unit:"秒").onChange(of:lead){_ in invalidatePreview()}
                    NumberInput(title:"歌った後に表示",value:$tail,range:0...10,unit:"秒").onChange(of:tail){_ in invalidatePreview()}
                    ColorPicker(L("歌う前の文字色"),selection:Binding(get:{Color(nsColor:NSColor(hex:beforeColor))},set:{beforeColor=NSColor($0).hex;invalidatePreview()}),supportsOpacity:false)
                    ColorPicker(L("歌った後の文字色"),selection:Binding(get:{Color(nsColor:NSColor(hex:afterColor))},set:{afterColor=NSColor($0).hex;invalidatePreview()}),supportsOpacity:false)
                } else {VMMMenuPicker(L("文字の演出"),selection:$motion){VMMOptions(LyricMotion.allCases,id:\.self){VMMChoice(text:L($0.title),value:$0)}}.onChange(of:motion){_ in invalidatePreview()}}
                Button(L("歌詞を等間隔に仮配置")){prepare()}
                Text(L("仮配置は音声に同期しません。再配置すると調整済みの行は置き換わります。")).foregroundColor(.secondary)
                Spacer()
            }.padding(6).frame(minWidth:280,idealWidth:350)
            VStack(alignment:.leading,spacing:8) {
                HStack{Text(L("配置候補"));Spacer();if rendering {ProgressView().controlSize(.small)};Button(L("プレビュー更新")){updatePreview()}.disabled(lines.isEmpty || rendering)}
                HStack {
                    Button(store.playing ? L("停止") : L("再生")){if store.playing {store.pause()} else {store.play()}}
                    Text(String(format:"%.3f 秒",clock.time)).monospacedDigit()
                    Button(L("この行の開始を記録して次へ")){recordTiming()}.disabled(selected == nil)
                }
                HStack {
                    Picker(L("同期方法"),selection:$alignmentMethod){Text(L("音声認識")).tag("speech");Text(L("歌声分離して音声認識")).tag("separated")}.labelsHidden().disabled(alignTask != nil)
                    Button(L("選択音声から同期候補を作成")){alignFromAudio()}.disabled(lines.isEmpty || alignTask != nil)
                    if alignTask != nil {ProgressView().controlSize(.small);Button(L("中止")){alignTask?.cancel()}}
                    if !alignment.isEmpty {Button(L("候補を反映")){applyAlignment()};Text("\(alignment.filter(\.matched).count)/\(alignment.count) \(L("行の候補"))")}
                }
                if alignmentMethod=="separated" {
                    HStack {Button(L("Pythonを選択…")){selectAlignmentPath(directory:false)};Text(alignmentPython.isEmpty ? L("未設定"):URL(fileURLWithPath:alignmentPython).lastPathComponent).lineLimit(1);Button(L("モデルフォルダを選択…")){selectAlignmentPath(directory:true)};Text(alignmentModels.isEmpty ? L("未設定"):URL(fileURLWithPath:alignmentModels).lastPathComponent).lineLimit(1)}.disabled(alignTask != nil)
                    Button(L("歌声を分離して素材に追加")){separateOnly()}.disabled(alignTask != nil)
                    Text(L("歌声をローカルで分離し、macOSの音声認識で候補を作ります。精度は音声により異なります。" )).foregroundColor(.secondary)
                }
                if !alignment.isEmpty {Text(L("元の歌詞は変更しません。未一致行は現在の時刻を維持します。認識のずれを確認して修正してください。" )).foregroundColor(.secondary)}
                HStack {NumberInput(title:"一括移動",value:$timingOffset,range:-86400...86400,unit:"秒");Button(L("全行に適用")){do{lines=try LyricTemplatePlanner.shifted(lines,by:timingOffset,fps:fps);timingOffset=0;error=nil;invalidatePreview()}catch{self.error=error.localizedDescription}}.disabled(lines.isEmpty)}
                Text(L("音声を再生し、各行の歌い始めで記録します。前の行の終了も更新されます。最後の行の終了は手動で調整してください。" )).foregroundColor(.secondary)
                if let preview {Image(nsImage:preview).resizable().aspectRatio(contentMode:.fit).frame(maxWidth:.infinity,maxHeight:180).background(Color.black)}
                else {Text(L("行を選択してプレビュー更新を押してください。")).foregroundColor(.secondary).frame(maxWidth:.infinity,minHeight:100)}
                ScrollView {VStack(alignment:.leading,spacing:8){ForEach($lines){$line in
                    VStack(alignment:.leading,spacing:4){
                        HStack{Button{selected=line.id;invalidatePreview();updatePreview()}label:{Image(systemName:selected==line.id ? "largecircle.fill.circle":"circle")}.buttonStyle(.borderless).disabled(rendering);TextField(L("歌詞"),text:Binding(get:{line.text},set:{line.text=$0;alignment=[];invalidatePreview()}));if let index=lines.firstIndex(where:{$0.id==line.id}),let match=alignment.first(where:{$0.index==index}) {Text(L(match.matched ? "一致":"未一致")).foregroundColor(match.matched ? .green:.orange)}}
                        if let index=lines.firstIndex(where:{$0.id==line.id}),let match=alignment.first(where:{$0.index==index}),let a=match.start,let b=match.end {HStack{Text(String(format:"%@ %.3f – %.3f s",L("同期候補"),a,b)).foregroundColor(.secondary).monospacedDigit();Button(L("候補を再生")){store.seek(max(0,a-0.3));store.play()}.buttonStyle(.borderless);Button(L("この行に反映")){applyAlignmentLine(match)}.buttonStyle(.borderless)}}
                        HStack {
                            NumberInput(title:"開始フレーム",value:Binding(get:{line.start*Double(fps)},set:{line.start=$0.rounded()/Double(fps);invalidatePreview()}),range:0...Double(fps)*86400)
                            NumberInput(title:"終了フレーム",value:Binding(get:{line.end*Double(fps)},set:{line.end=$0.rounded()/Double(fps);invalidatePreview()}),range:0...Double(fps)*86400)
                        }
                        Text(String(format:"%.3f – %.3f s",line.start,line.end)).foregroundColor(.secondary)
                    }.padding(8).background(Color(nsColor:.controlBackgroundColor)).cornerRadius(6)
                }}}
            }.padding(6).frame(minWidth:440,maxWidth:.infinity)
        }
        if let error {Text(L(error)).foregroundColor(.red)}
        HStack {Spacer();Button(L("キャンセル")){dismiss()};Button(L("タイムラインに配置")){do{try store.placeLyricTemplate(lines:lines,trackID:trackID,fps:fps,motion:motion,karaoke:karaoke,lead:lead,tail:tail,beforeColor:beforeColor,afterColor:afterColor);dismiss()}catch{self.error=error.localizedDescription}}.disabled(lines.isEmpty).keyboardShortcut(.defaultAction)}
    }.padding(20).frame(minWidth:900,minHeight:600).onChange(of:store.projectRevision){_ in alignment=[];alignTask?.cancel();invalidatePreview()}.onDisappear{alignTask?.cancel()}}
}
