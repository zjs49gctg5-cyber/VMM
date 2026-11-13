import SwiftUI
import AppKit

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
}
enum LyricTemplatePlanner {
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
}
@MainActor extension EditorStore {
    func lyricCandidate(lines:[LyricDraftLine],trackID:UUID,fps:Int,motion:LyricMotion)throws->(Project,[Clip]) {
        guard !busy,project.fps==fps,let track=project.tracks.firstIndex(where:{$0.id==trackID}),!project.tracks[track].locked else {throw VMMError.message("配置先のレイヤーまたはFPSが変更されています。")}
        let clips=try LyricTemplatePlanner.clips(lines,track:track,fps:fps,motion:motion)
        var candidate=project;candidate.clips.append(contentsOf:clips);_=try candidate.validated();return(candidate,clips)
    }
    func placeLyricTemplate(lines:[LyricDraftLine],trackID:UUID,fps:Int,motion:LyricMotion)throws {
        let (candidate,clips)=try lyricCandidate(lines:lines,trackID:trackID,fps:fps,motion:motion)
        pause();checkpoint();project=candidate;selectedIDs=Set(clips.map(\.id));selectedID=clips.first?.id
    }
}

struct LyricTemplateSheet:View {
    @ObservedObject var store:EditorStore
    @Environment(\.dismiss) private var dismiss
    let trackID:UUID
    let fps:Int
    @State private var source=""
    @State private var start:Double
    @State private var interval=2.0
    @State private var beats=4.0
    @State private var useBeats=true
    @State private var motion=LyricMotion.bounce
    @State private var lines:[LyricDraftLine]=[]
    @State private var selected:UUID?
    @State private var preview:NSImage?
    @State private var error:String?
    @State private var previewRevision=0
    @State private var rendering=false
    init(store:EditorStore){self.store=store;trackID=store.project.tracks[store.selectedTrack].id;fps=store.project.fps;_start=State(initialValue:store.playhead)}
    private func prepare(){do {
        let seconds=useBeats ? beats*60/(store.project.rhythm ?? RhythmSettings()).bpm:interval
        lines=try LyricTemplatePlanner.distribute(source,start:start,interval:seconds,fps:fps);selected=lines.first?.id;invalidatePreview();error=nil
    }catch{self.error=error.localizedDescription}}
    private func invalidatePreview(){preview=nil;previewRevision+=1}
    private func updatePreview(){do {
        guard !rendering else{return}
        let (project,_)=try store.lyricCandidate(lines:lines,trackID:trackID,fps:fps,motion:motion)
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
                NumberInput(title:"開始",value:$start,range:0...86400,unit:"秒")
                Toggle(L("BPMの拍で間隔を指定"),isOn:$useBeats)
                if useBeats {NumberInput(title:"1行の拍数",value:$beats,range:0.125...64);Text(String(format:"BPM %.1f",(store.project.rhythm ?? RhythmSettings()).bpm)).foregroundColor(.secondary)}
                else {NumberInput(title:"1行の長さ",value:$interval,range:(1/Double(fps))...3600,unit:"秒")}
                VMMMenuPicker(L("文字の演出"),selection:$motion){VMMOptions(LyricMotion.allCases,id:\.self){VMMChoice(text:L($0.title),value:$0)}}.onChange(of:motion){_ in invalidatePreview()}
                Button(L("歌詞を時間に配置")){prepare()}
                Text(L("再配置すると、調整済みの行は入力欄の内容で置き換わります。")).foregroundColor(.secondary)
                Spacer()
            }.padding(6).frame(minWidth:280,idealWidth:350)
            VStack(alignment:.leading,spacing:8) {
                HStack{Text(L("配置候補"));Spacer();if rendering {ProgressView().controlSize(.small)};Button(L("プレビュー更新")){updatePreview()}.disabled(lines.isEmpty || rendering)}
                if let preview {Image(nsImage:preview).resizable().aspectRatio(contentMode:.fit).frame(maxWidth:.infinity,maxHeight:180).background(Color.black)}
                else {Text(L("行を選択してプレビュー更新を押してください。")).foregroundColor(.secondary).frame(maxWidth:.infinity,minHeight:100)}
                ScrollView {VStack(alignment:.leading,spacing:8){ForEach($lines){$line in
                    VStack(alignment:.leading,spacing:4){
                        HStack{Button{selected=line.id;invalidatePreview();updatePreview()}label:{Image(systemName:selected==line.id ? "largecircle.fill.circle":"circle")}.buttonStyle(.borderless).disabled(rendering);TextField(L("歌詞"),text:Binding(get:{line.text},set:{line.text=$0;invalidatePreview()}))}
                        HStack {
                            NumberInput(title:"開始フレーム",value:Binding(get:{line.start*Double(fps)},set:{line.start=$0.rounded()/Double(fps);invalidatePreview()}),range:0...Double(fps)*86400)
                            NumberInput(title:"終了フレーム",value:Binding(get:{line.end*Double(fps)},set:{line.end=$0.rounded()/Double(fps);invalidatePreview()}),range:0...Double(fps)*86400)
                        }
                        Text(String(format:"%.3f – %.3f s",line.start,line.end)).foregroundColor(.secondary)
                    }.padding(8).background(Color(nsColor:.controlBackgroundColor)).cornerRadius(6)
                }}}
            }.padding(6).frame(minWidth:440,maxWidth:.infinity)
        }
        if let error {Text(error).foregroundColor(.red)}
        HStack {Spacer();Button(L("キャンセル")){dismiss()};Button(L("タイムラインに配置")){do{try store.placeLyricTemplate(lines:lines,trackID:trackID,fps:fps,motion:motion);dismiss()}catch{self.error=error.localizedDescription}}.disabled(lines.isEmpty).keyboardShortcut(.defaultAction)}
    }.padding(20).frame(minWidth:900,minHeight:600).onChange(of:store.projectRevision){_ in invalidatePreview()}}
}
