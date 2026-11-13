import Foundation

enum LinkedMedia {
    static func expanded(_ ids:Set<UUID>,in project:Project)->Set<UUID> {
        let links=Set(project.clips.filter{ids.contains($0.id)}.compactMap(\.linkID))
        return ids.union(project.clips.filter{$0.linkID.map(links.contains) ?? false}.map(\.id))
    }
    static func expandedHierarchy(_ ids:Set<UUID>,in project:Project)->Set<UUID> {
        var children:[UUID:[UUID]]=[:], links:[UUID:[UUID]]=[:], linkForClip:[UUID:UUID]=[:]
        for clip in project.clips {
            if let parent=clip.parentID {children[parent,default:[]].append(clip.id)}
            if let members=clip.sceneMembers {children[clip.id,default:[]].append(contentsOf:members)}
            if let link=clip.linkID {links[link,default:[]].append(clip.id);linkForClip[clip.id]=link}
        }
        var result=ids,queue=Array(ids),index=0,visitedLinks:Set<UUID>=[]
        while index<queue.count {
            let id=queue[index];index+=1
            var next=children[id] ?? []
            if let link=linkForClip[id],visitedLinks.insert(link).inserted {next.append(contentsOf:links[link] ?? [])}
            for child in next where result.insert(child).inserted {queue.append(child)}
        }
        return result
    }
    static func updated(_ project:Project,from before:Clip,to after:Clip,validate:Bool=true)throws->Project {
        var result=project
        guard let index=result.clips.firstIndex(where:{$0.id==before.id}),result.tracks.indices.contains(after.track),!result.tracks[after.track].locked else{throw VMMError.message("移動先がないかロックされています。")}
        result.clips[index]=after
        let timing=before.start != after.start || before.duration != after.duration || before.sourceOffset != after.sourceOffset || before.playbackRate != after.playbackRate || before.speedPoints != after.speedPoints || before.reversed != after.reversed
        if timing,let link=before.linkID {
            for i in result.clips.indices where result.clips[i].id != before.id && result.clips[i].linkID==link {
                guard !result.tracks[result.clips[i].track].locked else{throw VMMError.message("リンク先のレイヤーがロックされています。リンクを解除するかロックを解除してください。")}
                var peer=result.clips[i]
                let offsetDelta=(after.sourceOffset-before.sourceOffset)*peer.mediaRate/before.mediaRate
                if after.animationTimeOffset != before.animationTimeOffset {peer.preserveAnimationDomain();peer.animationOffset=peer.animationTimeOffset+after.animationTimeOffset-before.animationTimeOffset}
                peer.start+=after.start-before.start;peer.duration+=after.duration-before.duration;peer.sourceOffset+=offsetDelta
                if before.playbackRate != after.playbackRate {peer.playbackRate=after.playbackRate}
                if before.speedPoints != after.speedPoints {peer.speedPoints=after.speedPoints}
                if before.reversed != after.reversed {peer.reversed=after.reversed}
                result.clips[i]=peer
            }
        }
        if before.start != after.start {
            let roots=expanded([before.id],in:project)
            let children=expandedHierarchy(roots,in:project).subtracting(roots)
            for i in result.clips.indices where children.contains(result.clips[i].id) {
                guard !result.tracks[result.clips[i].track].locked else{throw VMMError.message("子アイテムがロックされています。")}
                result.clips[i].start+=after.start-before.start
            }
        }
        if validate {_=try result.validated()};return result
    }
    static func remap(_ clips:[Clip])->[Clip] {
        let links=Dictionary(uniqueKeysWithValues:Set(clips.compactMap(\.linkID)).map{($0,UUID())})
        return clips.map{var c=$0;c.linkID=c.linkID.flatMap{links[$0]};return c}
    }
}
@MainActor extension EditorStore {
    func linkSelection()throws {
        guard !busy else{throw VMMError.message("処理中です。")}
        let clips=project.clips.filter{selection.contains($0.id)}
        guard clips.count>=2,clips.contains(where:{$0.kind == .video}),clips.contains(where:{$0.kind == .audio}),clips.allSatisfy({[.audio,.video].contains($0.kind) && !project.tracks[$0.track].locked}),let first=clips.first,clips.allSatisfy({abs($0.start-first.start)<1/Double(project.fps) && abs($0.duration-first.duration)<1/Double(project.fps)}) else{throw VMMError.message("開始・長さが同じ映像と音声を選択してください。ロックされたアイテムはリンクできません。")}
        let id=UUID(),targets=LinkedMedia.expanded(selection,in:project)
        guard project.clips.filter({targets.contains($0.id)}).allSatisfy({!project.tracks[$0.track].locked}) else{throw VMMError.message("リンク先がロックされています。")}
        pause();checkpoint()
        for i in project.clips.indices where targets.contains(project.clips[i].id) {project.clips[i].linkID=selection.contains(project.clips[i].id) ? id:nil}
    }
    func unlinkSelection()throws {
        let targets=LinkedMedia.expanded(selection,in:project)
        guard !busy,project.clips.filter({targets.contains($0.id)}).allSatisfy({!project.tracks[$0.track].locked}) else{throw VMMError.message("処理中、またはリンク先がロックされています。")}
        pause();checkpoint();for i in project.clips.indices where targets.contains(project.clips[i].id) {project.clips[i].linkID=nil}
    }
    func splitLinked(_ id:UUID,at cut:Double)throws {
        let ids=LinkedMedia.expanded([id],in:project),members=project.clips.filter{ids.contains($0.id)}
        guard members.count>1 else{return}
        guard !busy,members.allSatisfy({!project.tracks[$0.track].locked && cut>$0.start+1/Double(project.fps) && cut<$0.end-1/Double(project.fps) && project.descendants(of:$0.id).isEmpty}) else{throw VMMError.message("リンクされた全アイテムを同じ位置で分割できません。")}
        var candidate=project,rights:[Clip]=[],copies:[UUID:[UUID]]=[:];let rightLink=UUID()
        for clip in members {
            let index=candidate.clips.firstIndex{$0.id==clip.id}!
            let left=SourceEditing.fragment(clip,start:clip.start,end:cut)
            var right=SourceEditing.fragment(clip,start:cut,end:clip.end,newID:true);right.linkID=rightLink
            candidate.clips[index]=left;rights.append(right);copies[clip.id]=[right.id]
        }
        candidate.clips+=rights;candidate.registerSceneCopies(copies);_=try candidate.validated();pause();checkpoint();project=candidate;selectedIDs=Set(rights.map(\.id));selectedID=rights.first?.id
    }
}
