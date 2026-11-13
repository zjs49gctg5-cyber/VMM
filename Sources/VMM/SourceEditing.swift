import AppKit
import SwiftUI

@MainActor private final class SourceEditValue:ObservableObject {@Published var seconds=0.0}
private struct SourceDeltaControl:View {
    @ObservedObject var value:SourceEditValue
    var body:some View {NumberInput(title:"移動量",value:$value.seconds,range: -86400...86400,unit:"秒",fractionalDigits:6).padding(8)}
}

enum SourcePlacement:String,CaseIterable {case append,insert,overwrite
    var title:String {switch self {case .append:return "追加";case .insert:return "挿入";case .overwrite:return "上書き"}}
}
enum SourceEditing {
    static func fragment(_ clip:Clip,start:Double,end:Double,newID:Bool=false)->Clip {
        var c=clip;c.preserveAnimationDomain()
        if newID {c.id=UUID()}
        c.animationOffset=c.animationTimeOffset+start-clip.start
        if clip.hasTimeWarp {
            let curve=clip.timeWarpCurve, from=start-clip.start, to=end-clip.start
            let fromDistance=curve.distance(at:from),toDistance=curve.distance(at:to)
            c.sourceOffset += clip.reversed == true ? clip.sourceDuration-toDistance : fromDistance
            if clip.speedPoints != nil {
                c.speedPoints=[.init(time:0,rate:curve.rate(at:from))] + curve.points.filter{$0.time>from && $0.time<to}.map{.init(time:$0.time-from,rate:$0.rate)} + [.init(time:to-from,rate:curve.rate(at:to))]
            }
        } else {c.sourceOffset += (start-clip.start)*clip.mediaRate}
        c.start=start;c.duration=end-start;return c
    }
    static func requireIndependent(_ clip:Clip,in project:Project)throws {
        guard clip.linkID==nil,clip.parentID==nil,clip.sceneMembers==nil,!project.clips.contains(where:{$0.parentID==clip.id || $0.sceneMembers?.contains(clip.id)==true}) else {
            throw VMMError.message("リンク・親子・シーン制御のあるアイテムをまたぐ編集です。先に分割位置を調整するか、関係を解除してください。")
        }
    }
    static func checkSource(_ clip:Clip,in project:Project)throws {
        guard let asset=project.asset(for:clip),[.video,.audio,.speech].contains(clip.kind),clip.sourceOffset>=0,clip.sourceOffset+clip.sourceDuration<=asset.duration+0.000001 else {throw VMMError.message("素材の先頭または末尾を超える編集です。")}
    }
    static func place(project:Project,assetID:UUID,sourceIn:Double,sourceOut:Double,start:Double,track:Int,mode:SourcePlacement)throws->(Project,UUID) {
        guard let asset=project.assets.first(where:{$0.id==assetID}),[.video,.audio].contains(asset.kind),[sourceIn,sourceOut,start].allSatisfy(\.isFinite),sourceIn>=0,sourceOut<=asset.duration,sourceOut>sourceIn,start>=0,project.tracks.indices.contains(track),!project.tracks[track].locked else {throw VMMError.message("素材の範囲または配置先が不正です。")}
        let length=sourceOut-sourceIn,end=start+length
        var candidate=project,result:[Clip]=[]
        for clip in project.clips {
            if mode == .insert,clip.start>=start {
                guard !project.tracks[clip.track].locked else{throw VMMError.message("挿入で移動するレイヤーがロックされています。")}
                var c=clip;c.start += length;result.append(c)
            } else if mode == .insert,clip.start<start,clip.end>start {
                guard !project.tracks[clip.track].locked else{throw VMMError.message("分割するレイヤーがロックされています。")}
                try requireIndependent(clip,in:project)
                result.append(fragment(clip,start:clip.start,end:start))
                var right=fragment(clip,start:start,end:clip.end,newID:true);right.start += length;result.append(right)
            } else if mode == .overwrite,clip.track==track,clip.start<end,clip.end>start {
                try requireIndependent(clip,in:project)
                if clip.start<start {result.append(fragment(clip,start:clip.start,end:start))}
                if clip.end>end {result.append(fragment(clip,start:end,end:clip.end,newID:clip.start<start))}
            } else {result.append(clip)}
        }
        var clip=Clip(kind:asset.kind,name:asset.name,track:track,start:start,duration:length);clip.assetID=asset.id;clip.sourceOffset=sourceIn
        result.append(clip);candidate.clips=result
        if mode == .insert {
            candidate.markers=candidate.markers?.map{var m=$0;if m.time>=start{m.time += length};return m}
            if var range=candidate.timelineRange {if range.start>=start{range.start += length};if range.end>=start{range.end += length};candidate.timelineRange=range}
            // Parent durations must not be silently separated from their children.
            for c in project.clips where c.parentID != nil || c.sceneMembers != nil {
                if c.start<start && c.end>start {throw VMMError.message("親子・シーン制御の区間内へ挿入できません。")}
            }
        }
        _=try candidate.validated();return(candidate,clip.id)
    }
    static func slip(project:Project,clipID:UUID,delta:Double)throws->Project {
        guard delta.isFinite,let before=project.clips.first(where:{$0.id==clipID}),!project.tracks[before.track].locked else{throw VMMError.message("スリップ編集の対象が不正です。")}
        var after=before;after.sourceOffset += delta*before.mediaRate
        let candidate=try LinkedMedia.updated(project,from:before,to:after)
        for c in candidate.clips where c.id==clipID || (before.linkID != nil && c.linkID==before.linkID) {try checkSource(c,in:candidate)}
        return candidate
    }
    static func roll(project:Project,clipID:UUID,delta:Double)throws->Project {
        guard delta.isFinite,let left=project.clips.first(where:{$0.id==clipID}) else{throw VMMError.message("ロール編集の対象が不正です。")}
        let neighbors=project.clips.filter{$0.track==left.track && $0.id != left.id && abs($0.start-left.end)<0.000001}
        guard neighbors.count==1,let right=neighbors.first,left.duration+delta>0,right.duration-delta>0 else{throw VMMError.message("右に隣接するアイテムとの境界を指定してください。")}
        guard !left.hasTimeWarp,!right.hasTimeWarp else {throw VMMError.message("逆再生・可変速度のアイテムはロール編集できません。端をドラッグして調整してください。")}
        try requireIndependent(left,in:project);try requireIndependent(right,in:project)
        guard !project.tracks[left.track].locked else{throw VMMError.message("レイヤーがロックされています。")}
        var candidate=project,a=left,b=right;a.preserveAnimationDomain();b.preserveAnimationDomain()
        a.duration += delta;b.start += delta;b.duration -= delta;b.sourceOffset += delta*b.mediaRate;b.animationOffset=b.animationTimeOffset+delta
        try checkSource(a,in:project);try checkSource(b,in:project)
        candidate.clips[candidate.clips.firstIndex{$0.id==left.id}!]=a;candidate.clips[candidate.clips.firstIndex{$0.id==right.id}!]=b
        _=try candidate.validated();return candidate
    }
}
@MainActor extension EditorStore {
    func promptSourceEdit(_ id:UUID,roll:Bool) {
        let alert=NSAlert();alert.messageText=roll ? "ロール編集":"スリップ編集"
        alert.informativeText=roll ? "境界の移動量（秒）。正の値で右へ移動します。":"素材内の移動量（秒）。正の値で後の部分を使います。音声はサンプル単位の小数を指定できます。"
        let value=SourceEditValue(),field=NSHostingView(rootView:SourceDeltaControl(value:value));field.frame=NSRect(x:0,y:0,width:340,height:42);alert.accessoryView=field
        alert.addButton(withTitle:"適用");alert.addButton(withTitle:"キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn else{return}
        alert.window.makeFirstResponder(nil)
        reportEditing {if roll{try rollSource(id,delta:value.seconds)}else{try slipSource(id,delta:value.seconds)}}
    }
    func commitSourceEdit(_ candidate:Project,selected:UUID?=nil) {
        pause();checkpoint();cancelSpeech();project=candidate
        if let selected {selectedIDs=[];selectedID=selected}
        scheduleDirtySpeech()
    }
    func placeSource(_ assetID:UUID,sourceIn:Double,sourceOut:Double,start:Double?=nil,track:Int?=nil,mode:SourcePlacement)throws {
        guard !busy else{throw VMMError.message("処理が終わってから編集してください。")}
        let (candidate,id)=try SourceEditing.place(project:project,assetID:assetID,sourceIn:sourceIn,sourceOut:sourceOut,start:start ?? snapped(playhead),track:track ?? selectedTrack,mode:mode)
        commitSourceEdit(candidate,selected:id)
    }
    func slipSource(_ id:UUID,delta:Double)throws {guard !busy else{return};commitSourceEdit(try SourceEditing.slip(project:project,clipID:id,delta:delta))}
    func rollSource(_ id:UUID,delta:Double)throws {guard !busy else{return};commitSourceEdit(try SourceEditing.roll(project:project,clipID:id,delta:delta))}
}
