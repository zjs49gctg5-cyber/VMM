import AppKit
import AVFoundation

private struct ClipPacket:Codable {var directory:String;var clips:[Clip]}
@MainActor extension EditorStore {
    static var clipPasteboard:NSPasteboard.PasteboardType {NSPasteboard.PasteboardType("app.vmm.clips.v1")}
    func copyClips(pasteboard:NSPasteboard = .general)throws {
        let ids=LinkedMedia.expandedHierarchy(selection,in:project)
        let clips=project.clips.filter{ids.contains($0.id)};guard !clips.isEmpty else{return}
        let data=try JSONEncoder().encode(ClipPacket(directory:directory.path,clips:clips))
        pasteboard.clearContents();pasteboard.setData(data,forType:Self.clipPasteboard)
    }
    func pasteClips(pasteboard:NSPasteboard = .general)throws {
        guard !busy,let data=pasteboard.data(forType:Self.clipPasteboard),data.count<=16*1024*1024 else{return}
        let packet=try JSONDecoder().decode(ClipPacket.self,from:data)
        guard packet.directory==directory.path else{throw VMMError.message("アイテムの貼り付けは同じプロジェクト内で行ってください。")}
        guard !packet.clips.isEmpty,packet.clips.count<=20000,Set(packet.clips.map(\.id)).count==packet.clips.count else{throw VMMError.message("コピーしたアイテムが不正です。")}
        let ids=Dictionary(uniqueKeysWithValues:packet.clips.map{($0.id,UUID())}),start=packet.clips.map(\.start).min()!,track=packet.clips.map(\.track).min()!
        var candidate=project,newClips:[Clip]=[]
        for original in LinkedMedia.remap(packet.clips) {
            var c=original;c.id=ids[original.id]!;c.start=playhead+original.start-start;c.track=selectedTrack+original.track-track;c.parentID=original.parentID.flatMap{ids[$0]};c.sceneMembers=original.sceneMembers?.compactMap{ids[$0]}
            guard (0..<32).contains(c.track) else{throw VMMError.message("貼り付け先のレイヤーが足りません。")}
            while candidate.tracks.count<=c.track{candidate.tracks.append(Track(name:"\(L("レイヤー")) \(candidate.tracks.count+1)"))}
            guard !candidate.tracks[c.track].locked else{throw VMMError.message("貼り付け先のレイヤーがロックされています。")}
            let assets=Set(([c.assetID,c.mouthAssetID]+(c.masks ?? []).map(\.assetID)).compactMap{$0})
            guard assets.isSubset(of:Set(project.assets.map(\.id))) else{throw VMMError.message("コピーした素材がプロジェクトにありません。")}
            newClips.append(c)
        }
        candidate.clips.append(contentsOf:newClips);_=try candidate.validated()
        pause();checkpoint();project=candidate;selectedIDs=Set(newClips.map(\.id));selectedID=newClips.first?.id;scheduleDirtySpeech()
    }
    func rippleDelete()throws {
        guard !busy else{return}
        let ids=LinkedMedia.expandedHierarchy(selection,in:project)
        let selected=project.clips.filter{ids.contains($0.id)};guard !selected.isEmpty else{return}
        guard selected.allSatisfy({!project.tracks[$0.track].locked}) else{throw VMMError.message("ロックされたアイテムはリップル削除できません。")}
        var gaps:[ClosedRange<Double>]=[]
        for c in selected.sorted(by:{$0.start<$1.start}) {
            if let last=gaps.last,c.start<=last.upperBound {gaps[gaps.count-1]=last.lowerBound...max(last.upperBound,c.end)}else{gaps.append(c.start...c.end)}
        }
        func compressed(_ time:Double)->Double {time-gaps.reduce(0.0){$0+max(0,min(time,$1.upperBound)-$1.lowerBound)}}
        let remaining=project.clips.filter{!ids.contains($0.id)}
        guard !remaining.contains(where:{c in gaps.contains{$0.lowerBound<c.end && $0.upperBound>c.start}}) else{throw VMMError.message("削除範囲に選択外のアイテムがあります。全レイヤーの該当アイテムも選択してください。")}
        guard !remaining.contains(where:{project.tracks[$0.track].locked && abs(compressed($0.start)-$0.start)>0.000001}) else{throw VMMError.message("後続のロックされたレイヤーを移動できません。")}
        var candidate=project;candidate.removeClips(ids);candidate.clips=candidate.clips.map{var c=$0;c.start=compressed(c.start);return c}
        candidate.markers=project.markers?.map{var m=$0;m.time=compressed(m.time);return m}
        if let r=candidate.timelineRange {let a=compressed(r.start),b=compressed(r.end);candidate.timelineRange=b>a ? TimelineRange(start:a,end:b,loop:r.loop):nil}
        _=try candidate.validated();pause();checkpoint();cancelSpeech();project=candidate;playhead=compressed(playhead);selectedIDs=[];selectedID=nil;scheduleDirtySpeech()
    }
    func separateAudio(_ clipID:UUID)async throws {
        guard !busy,let c=project.clips.first(where:{$0.id==clipID}),c.kind == .video,c.audioDisabled != true,!project.tracks[c.track].locked,let asset=project.asset(for:c) else{return}
        let folder=directory,source=folder.appendingPathComponent("Media").appendingPathComponent(asset.file)
        guard !(try await AVURLAsset(url:source).loadTracks(withMediaType:.audio)).isEmpty else{throw VMMError.message("音声トラックがありません。")}
        guard directory==folder,project.clips.first(where:{$0.id==clipID})==c,!busy,!project.tracks[c.track].locked else{return}
        var candidate=project
        var track=candidate.tracks.indices.first{index in index != c.track && !candidate.tracks[index].locked && !candidate.clips.contains{$0.track==index && $0.start<c.end && $0.end>c.start}}
        if track==nil,candidate.tracks.count<32{track=candidate.tracks.count;candidate.tracks.append(Track(name:L("分離した音声")))}
        guard let track else{throw VMMError.message("音声を配置する空きレイヤーがありません。")}
        var audio=c;audio.id=UUID();audio.kind = .audio;audio.name=c.name+" · "+L("音声");audio.track=track;audio.audioDisabled=nil;audio.psd=nil;audio.effects=nil;audio.masks=nil;audio.mouthAssetID=nil;audio.characterSpeakerID=nil
        audio.animation?.tracks.removeAll{$0.property != .volume};audio.animation?.motions=[];audio.animation?.entrance=Entrance();audio.animation?.exit=Entrance()
        let link=c.linkID ?? UUID();audio.linkID=link
        candidate.clips[candidate.clips.firstIndex{$0.id==clipID}!].linkID=link
        candidate.clips[candidate.clips.firstIndex{$0.id==clipID}!].audioDisabled=true;candidate.clips.append(audio);candidate.registerSceneCopies([c.id:[audio.id]]);_=try candidate.validated()
        pause();checkpoint();project=candidate;selectedIDs=[];selectedID=audio.id
    }
    func reportEditing(_ action:()throws->Void){do{try action()}catch{self.error=error.localizedDescription}}
}
