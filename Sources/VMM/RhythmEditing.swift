import SwiftUI

struct RhythmSettings:Codable,Equatable {
    var enabled:Bool?
    var bpm=120.0
    var division=4
    var offset=0.0
    var snap=false
    var visible=true
    var interval:Double {60/bpm/Double(division)}
    func nearest(_ time:Double)->Double {time<offset ? time:max(0,offset+((time-offset)/interval).rounded()*interval)}
    func validate()throws {
        guard bpm.isFinite,(30...300).contains(bpm),[1,2,3,4,8].contains(division),offset.isFinite,(0...86400).contains(offset) else {throw VMMError.message("BPM・拍グリッドの設定が不正です。")}
    }
}
extension Project {
    var rhythmEnabled:Bool {rhythm.map{$0.enabled ?? true} ?? false}
    func audioProcessingClip(_ clip:Clip)->Clip {
        var c=clip;if !rhythmEnabled {c.pitchSemitones=nil};return c
    }
}
extension EditorStore {
    func editRhythm(_ change:(inout RhythmSettings)->Void) {
        guard !busy else{return}
        var rhythm=project.rhythm ?? RhythmSettings();change(&rhythm)
        do {try rhythm.validate();pause();checkpoint();project.rhythm=rhythm} catch {self.error=error.localizedDescription}
    }
    func repeatAudio(_ id:UUID,count:Int,onGrid:Bool) {
        guard !busy,project.rhythmEnabled,(2...64).contains(count),let clip=project.clips.first(where:{$0.id==id}),[.audio,.video,.speech].contains(clip.kind),!project.tracks[clip.track].locked else{return}
        guard !clip.hasTimeWarp else {error="逆再生・可変速度の素材は反復配置に対応していません。";return}
        guard !clip.speechDirty,project.clips.allSatisfy({$0.parentID != id}) else {error="音声生成済みで、子を持たないアイテムを選択してください。";return}
        let rhythm=project.rhythm ?? RhythmSettings(),frame=1/Double(project.fps)
        let interval=onGrid ? rhythm.interval:clip.duration
        guard interval>=frame else {error="間隔が1フレームより短いため、FPSか音符の間隔を変更してください。";return}
        var template=clip
        if onGrid {template.duration=min(clip.duration,interval)}
        let sampleDuration=template.duration
        if onGrid {template.duration=min(clip.duration,((clip.start+sampleDuration)*Double(project.fps)).rounded()/Double(project.fps)-clip.start)}
        var copies:[Clip]=[]
        for i in 1..<count {
            var copy=template;copy.id=UUID();copy.start=((clip.start+Double(i)*interval)*Double(project.fps)).rounded()/Double(project.fps)
            // Quantize the end separately so fractional BPMs do not drift.
            copy.duration=((clip.start+Double(i)*interval+sampleDuration)*Double(project.fps)).rounded()/Double(project.fps)-copy.start
            copies.append(copy)
        }
        var candidate=project
        candidate.clips[candidate.clips.firstIndex(where:{$0.id==id})!]=template;candidate.clips+=copies;candidate.registerSceneCopies([id:copies.map(\.id)])
        do {candidate=try candidate.validated();pause();checkpoint();project=candidate;selectedID=id;selectedIDs=Set([id]+copies.map(\.id));status="\(count)回の反復を配置しました。"} catch {self.error=error.localizedDescription}
    }
    func sliceAudioOnGrid(_ id:UUID) {
        guard !busy,project.rhythmEnabled,let clip=project.clips.first(where:{$0.id==id}),[.audio,.video,.speech].contains(clip.kind),!project.tracks[clip.track].locked else{return}
        guard !clip.hasTimeWarp else {error="逆再生・可変速度の素材は拍グリッドでの分割に対応していません。";return}
        guard !clip.speechDirty,project.clips.allSatisfy({$0.parentID != id}) else {error="音声生成済みで、子を持たないアイテムを選択してください。";return}
        let rhythm=project.rhythm ?? RhythmSettings(),fps=Double(project.fps),frame=1/fps
        let first=max(0,Int(floor((clip.start-rhythm.offset)/rhythm.interval))+1)
        let last=Int(ceil((clip.end-rhythm.offset)/rhythm.interval))-1
        guard last>=first else{return}
        guard last-first<511 else {error="一度の分割は512区間までです。選択区間を短くしてください。";return}
        var cuts=[clip.start]
        for n in first...last {
            let t=((rhythm.offset+Double(n)*rhythm.interval)*fps).rounded()/fps
            if t-cuts.last!>=frame-0.000001,clip.end-t>=frame-0.000001 {cuts.append(t)}
        }
        cuts.append(clip.end)
        guard cuts.count>2 else{return}
        var base=clip;base.preserveAnimationDomain()
        let parts=(0..<cuts.count-1).map {i->Clip in
            var c=base;c.id=i==0 ? clip.id:UUID();c.start=cuts[i];c.duration=cuts[i+1]-cuts[i]
            c.sourceOffset=clip.sourceOffset+(c.start-clip.start)*clip.mediaRate
            c.animationOffset=clip.animationTimeOffset+c.start-clip.start
            return c
        }
        var candidate=project;candidate.clips.removeAll{$0.id==id};candidate.clips+=parts;candidate.registerSceneCopies([id:parts.dropFirst().map(\.id)])
        do {candidate=try candidate.validated();pause();checkpoint();project=candidate;selectedID=id;selectedIDs=Set(parts.map(\.id));status="拍グリッドで\(parts.count)区間に分割しました。"} catch {self.error=error.localizedDescription}
    }
}
struct RhythmProjectControls:View {
    @ObservedObject var store:EditorStore
    var inMADMode=false
    @State private var expanded=false
    init(store:EditorStore,inMADMode:Bool=false){self.store=store;self.inMADMode=inMADMode;_expanded=State(initialValue:inMADMode)}
    var settings:RhythmSettings {store.project.rhythm ?? RhythmSettings()}
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
        if !inMADMode {Toggle(L("音MAD設定を有効にする"),isOn:Binding(get:{store.project.rhythmEnabled},set:{v in store.editRhythm{$0.enabled=v}}))
        Button(L("音MADモードを開く…")){store.workspaceWindows.show(.mad)}}
        if inMADMode {PanelDisclosure(L("BPM・拍グリッド"),isExpanded:$expanded) {
            NumberInput(title:"BPM",value:Binding(get:{settings.bpm},set:{v in store.editRhythm{$0.bpm=v}}),range:30...300)
            VMMMenuPicker(L("音符"),selection:Binding(get:{settings.division},set:{v in store.editRhythm{$0.division=v}})) {
                VMMChoice(text:L("4分音符"),value:1);VMMChoice(text:L("8分音符"),value:2);VMMChoice(text:L("3連符"),value:3);VMMChoice(text:L("16分音符"),value:4);VMMChoice(text:L("32分音符"),value:8)
            }
            NumberInput(title:"拍の開始位置",value:Binding(get:{settings.offset},set:{v in store.editRhythm{$0.offset=v}}),range:0...86400,unit:"秒")
            Toggle(L("拍グリッドを表示"),isOn:Binding(get:{settings.visible && store.project.rhythm != nil},set:{v in store.editRhythm{$0.visible=v}}))
            Toggle(L("拍にスナップ"),isOn:Binding(get:{settings.snap},set:{v in store.editRhythm{$0.snap=v}}))
            Button(L("現在位置を拍の開始にする")){store.editRhythm{$0.offset=store.playhead}}
            Text(L("拍の位置はプロジェクトのフレームに合わせます。スナップをオフにすると通常の編集に戻ります。")).foregroundColor(.secondary)
        }.disabled(!store.project.rhythmEnabled)}
        Text(L("オフでも設定値と配置済みアイテムを保持します。拍グリッド・スナップ・ピッチ補正は停止します。")).foregroundColor(.secondary)
        }.disabled(store.busy)
    }
}
struct RhythmClipControls:View {
    @ObservedObject var store:EditorStore
    let clip:Clip
    @State private var count=8.0
    @State private var onGrid=false
    var body:some View {
        if store.project.rhythmEnabled {
        PanelDisclosure(L("音MAD・リズム編集")) {
            NumberInput(title:"ピッチ",value:Binding(get:{clip.pitchSemitones ?? 0},set:{v in store.edit(clip.id){$0.pitchSemitones=v}}),range:-24...24,unit:"半音")
            Text(L("＋12で1オクターブ上、−12で1オクターブ下。再生速度とは独立して調整できます。")).foregroundColor(.secondary)
            NumberInput(title:"反復回数",value:$count,range:2...64,unit:"回")
            Toggle(L("拍グリッド間隔で反復"),isOn:$onGrid)
            Text(onGrid ? "選択区間の先頭を1グリッド以内に切り詰め、拍の間隔で配置します。":"素材の選択区間を連続して配置します。").foregroundColor(.secondary)
            Button(L("選択区間を反復")){store.repeatAudio(clip.id,count:Int(count.rounded()),onGrid:onGrid)}
            Button(L("拍グリッドで分割")){store.sliceAudioOnGrid(clip.id)}
            Text(L("BPM・音符・拍の開始位置は、音MADモードで指定します。分割・反復は1回のUndoで戻せます。")).foregroundColor(.secondary)
        }
        }
    }
}
