import AppKit
import SwiftUI

struct ExportIssue:Codable,Identifiable,Equatable {
    enum Severity:String,Codable {case error,warning}
    let id:String
    let severity:Severity
    let message:String
    var clipID:UUID?
}
struct ExportPreflight:Codable,Equatable {
    var issues:[ExportIssue]=[]
    var estimatedBytes:Int64=0
    var canExport:Bool {!issues.contains{$0.severity == .error}}
    static func inspect(project:Project,directory:URL,options:UserSettings,destination:URL?=nil,generating:Set<UUID>=[],metalKernelsAvailable:Bool?=nil) -> Self {
        var report=Self()
        func add(_ code:String,_ severity:ExportIssue.Severity,_ message:String,_ clip:UUID?=nil){report.issues.append(ExportIssue(id:code,severity:severity,message:message,clipID:clip))}
        do {_=try project.validated();_=try options.validated()}catch {add("model",.error,error.localizedDescription);return report}
        let project=project.audioRenderingProject
        let start=options.rangeStart,end=options.rangeEnd>0 ? min(options.rangeEnd,project.duration):project.duration
        if end<=start {add("range",.error,"書き出し範囲が空です。開始・終了を確認してください。")}
        let dimensions=options.exportDimensions(project)
        let mbps=options.exportCodec == "ProRes 422" ? 147*Double(dimensions.width*dimensions.height)/Double(1920*1080)*Double(dimensions.fps)/30 : options.exportVideoMbps ?? max(0.2,Double(dimensions.width*dimensions.height*dimensions.fps)*(0.025+options.exportQuality*0.2)/1_000_000)
        report.estimatedBytes=Int64(max(0,end-start)*(mbps*1_000_000+Double(options.exportAudioKbps ?? 192)*1000)/8*1.2)+1_048_576
        let scope=ExportScope(project:project,options:options),referenced=scope.assetIDs(in:project)
        let relevantVisual=project.clips.filter{scope.visual.contains($0.id)}
        let glitchKinds:Set<EffectKind>=[.glitch,.chromaticAberration,.filmGrain]
        func usesGlitch(_ effects:[VisualEffect]?,from:Double,to:Double)->Bool {
            (effects ?? []).contains { effect in
                guard effect.enabled,glitchKinds.contains(effect.kind) else{return false}
                if effect.keys.isEmpty {return effect.amount>0}
                return interpolate(effect.keys,at:from,fallback:effect.amount)>0 || interpolate(effect.keys,at:to,fallback:effect.amount)>0 || effect.keys.contains{$0.time>=from && $0.time<=to && $0.value>0}
            }
        }
        let byID=Dictionary(uniqueKeysWithValues:project.clips.map{($0.id,$0)})
        func rootTrack(_ clip:Clip)->Int {
            var root=clip,visited:Set<UUID>=[]
            while let parent=root.parentID,visited.insert(parent).inserted,let next=byID[parent] {root=next}
            return root.track
        }
        // Transitions also render the lower layers at the frame immediately before
        // the transition. Its keyframed effects can differ from the export interval.
        let outgoingSamples=relevantVisual.filter{$0.kind == .transition}.map{transition in
            (track:transition.track,time:max(0,transition.start-1/Double(project.fps)))
        }
        func outgoingTimes(for clip:Clip)->[Double] {
            outgoingSamples.compactMap { sample in
                rootTrack(clip)>sample.track && clip.active(at:sample.time) ? sample.time:nil
            }
        }
        let itemUsesGlitch=relevantVisual.contains{clip in
            let first=max(start,clip.start),last=min(end,clip.end)
            if first<last && usesGlitch(clip.effects,from:clip.motionTime(at:first),to:clip.motionTime(at:last)) {return true}
            return outgoingTimes(for:clip).contains{time in let t=clip.motionTime(at:time);return usesGlitch(clip.effects,from:t,to:t)}
        }
        let trackUsesGlitch=Set(relevantVisual.map(\.track)).contains{index in
            guard project.tracks.indices.contains(index) else{return false}
            let effects=project.tracks[index].effects
            if relevantVisual.contains(where:{$0.track==index && max(start,$0.start)<min(end,$0.end)}) && usesGlitch(effects,from:start,to:end) {return true}
            return relevantVisual.filter{$0.track==index && $0.parentID == nil}.contains{clip in outgoingTimes(for:clip).contains{usesGlitch(effects,from:$0,to:$0)}}
        }
        if (itemUsesGlitch || trackUsesGlitch) && !(metalKernelsAvailable ?? (GlitchEffects.metalKernels != nil)) {
            add("glitch-cpu",.warning,L("グリッチ系エフェクトはCPUで描画します。処理に時間がかかり、粒子や乱れの模様がGPUと異なる場合があります。"))
        }
        var fontNames:Set<String>=[]
        for clip in project.clips where scope.all.contains(clip.id) {
            if scope.visual.contains(clip.id),clip.nineSlice?.exceedsCanvas == true {add("nine-slice-\(clip.id)",.warning,String(format:L("%@：9スライスの表示幅または高さが100%を超えています。画像が切れる場合があります。"),clip.name),clip.id)}
            if scope.visual.contains(clip.id) {for effect in clip.effects ?? [] where effect.enabled && effect.kind == .colorLUT && effect.lut == nil {add("lut-\(effect.id)",.warning,"\(clip.name)：LUTが未選択のため色調整は適用されません。",clip.id)}}
            if scope.audio.contains(clip.id) && clip.kind == .speech && (clip.speechDirty || clip.assetID == nil || generating.contains(clip.id)) {add("speech-\(clip.id)",.error,"\(clip.name)：音声が未生成・変更済み、または生成中です。",clip.id)}
            if scope.visual.contains(clip.id) && (clip.masks ?? []).contains(where:{$0.enabled && $0.kind == .image && $0.assetID == nil}) {add("mask-\(clip.id)",.error,"\(clip.name)：画像マスクの素材が未指定です。",clip.id)}
            if scope.visual.contains(clip.id),[.text,.speech].contains(clip.kind),let font=clip.textStyle?.fontName,fontNames.insert(font).inserted,NSFont(name:font,size:12)==nil {add("font-\(font)",.warning,"フォント「\(font)」が見つかりません。代替フォントで出力されます。",clip.id)}
            if scope.visual.contains(clip.id),[.text,.speech].contains(clip.kind) {
                for font in (clip.textRuns ?? []).compactMap({$0.style.fontName}) where fontNames.insert(font).inserted && NSFont(name:font,size:12)==nil {add("font-\(font)",.warning,"フォント「\(font)」が見つかりません。代替フォントで出力されます。",clip.id)}
            }
            if [.audio,.video].contains(clip.kind),let asset=project.asset(for:clip),clip.sourceOffset+clip.sourceDuration>asset.duration+1/Double(project.fps) {add("trim-\(clip.id)",.warning,"\(clip.name)：素材の末尾を超えています。映像は最終フレーム、音声は無音になります。",clip.id)}
        }
        for index in Set(project.clips.filter{scope.visual.contains($0.id)}.map(\.track)) where project.tracks.indices.contains(index) {
            for effect in project.tracks[index].effects ?? [] where effect.enabled && effect.kind == .colorLUT && effect.lut == nil {add("lut-\(effect.id)",.warning,"\(project.tracks[index].name)：LUTが未選択のため色調整は適用されません。")}
        }
        for asset in project.assets where referenced.contains(asset.id) {
            let missing=asset.files.filter{$0 != asset.proxyFile && !FileManager.default.fileExists(atPath:directory.appendingPathComponent("Media").appendingPathComponent($0).path)}
            if !missing.isEmpty {add("media-\(asset.id)",.error,"素材「\(asset.name)」が見つかりません（\(missing.count)ファイル）。",project.clips.first{$0.assetID==asset.id || $0.mouthAssetID==asset.id}?.id)}
        }
        if let destination {
            let parent=destination.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath:parent.path) {add("destination",.error,"書き出し先フォルダがありません。")}
            else if let capacity=(try? FileManager.default.attributesOfFileSystem(forPath:parent.path)[.systemFreeSize] as? NSNumber)?.int64Value,capacity<report.estimatedBytes {add("capacity",.error,"書き出し先の空き容量が不足しています。推定必要容量：約\(report.estimatedBytes/1_048_576) MB")}
            if destination.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path+"/") {add("session",.error,"書き出し先には作業用フォルダの外を指定してください。")}
        }
        return report
    }
}
@MainActor extension EditorStore {
    func checkExport()async {
        let snapshot=project,source=directory,options=settings,generating=generatingSpeech
        exportChecking=true
        defer{exportChecking=false}
        let report=await Task.detached(priority:.utility){ExportPreflight.inspect(project:snapshot,directory:source,options:options,generating:generating)}.value
        if directory==source,project==snapshot,settings==options {exportReport=report}
    }
}
struct ExportReportView:View {
    @ObservedObject var store:EditorStore
    var body:some View {VStack(alignment:.leading,spacing:8){
        MixLoudnessControls(store:store)
        Divider()
        Button(L("書き出し前チェック")){commitActiveFieldEditing();Task{await store.checkExport()}}.disabled(store.exportChecking)
        if store.exportChecking {ProgressView()}
        if let report=store.exportReport {
            Text(report.canExport ? L("書き出し可能です。警告があれば内容を確認してください。"):L("書き出し前にエラーを解消してください。"))
            Text(String(format:L("推定出力容量：約 %d MB"),report.estimatedBytes/1_048_576)).foregroundColor(.secondary)
            ForEach(report.issues){issue in Button {
                if let id=issue.clipID {store.selectedID=id;store.selectedIDs=[];if let clip=store.selected {store.seek(clip.start)}}
            } label:{Label(L(issue.message),systemImage:issue.severity == .error ? "xmark.octagon":"exclamationmark.triangle").foregroundColor(issue.severity == .error ? .red:.orange).frame(maxWidth:.infinity,alignment:.leading)}.buttonStyle(.plain)}
        }
    }}
}
