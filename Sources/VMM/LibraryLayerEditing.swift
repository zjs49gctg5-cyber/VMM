import AppKit

@MainActor extension EditorStore {
    func deletionClosure(_ roots:Set<UUID>)->Set<UUID> {
        LinkedMedia.expandedHierarchy(roots,in:project)
    }
    func mediaDeletionIDs(_ id:UUID)->Set<UUID> {
        deletionClosure(Set(project.clips.filter{c in c.assetID==id || c.mouthAssetID==id || c.audioReactive?.assetID==id || c.tracking?.assetID==id || (c.masks ?? []).contains{$0.assetID==id}}.map(\.id)))
    }
    func reconcileEditingSelection() {
        selectedTrack=min(max(0,selectedTrack),max(0,project.tracks.count-1))
        let ids=Set(project.clips.map(\.id));selectedIDs.formIntersection(ids)
        if let id=selectedID,!ids.contains(id){selectedID=nil}
        let hidden=Set(project.clips.filter{clip in project.tracks[clip.track].folderID.map{collapsedTrackFolders.contains($0)} ?? false}.map(\.id))
        selectedIDs.subtract(hidden);if let id=selectedID,hidden.contains(id){selectedID=selectedIDs.first}
        let layout=TrackFolderLayout(project:project,collapsed:collapsedTrackFolders)
        if layout.row(forTrack:selectedTrack)==nil,let first=layout.rows.compactMap({if case .track(let i)=$0{return i};return nil}).first {selectedTrack=first}
    }
    func deleteMedia(_ id:UUID,deleteItems:Bool=false)throws {
        guard !busy,project.assets.contains(where:{$0.id==id}) else{throw VMMError.message("素材がないか、処理中です。")}
        let ids=mediaDeletionIDs(id)
        guard ids.isEmpty || deleteItems else{throw VMMError.message("使用中の素材です。使用アイテムの削除を指定してください。")}
        guard !project.clips.contains(where:{ids.contains($0.id) && project.tracks[$0.track].locked}) else{throw VMMError.message("削除対象にロックされたアイテムがあります。")}
        var candidate=project;candidate.removeClips(ids);candidate.assets.removeAll{$0.id==id}
        _=try candidate.validated();pause();checkpoint();cancelSpeech();project=candidate;reconcileEditingSelection();scheduleDirtySpeech()
        status=L("素材をライブラリから削除しました。ファイルは保持されています。")
    }
    func confirmDeleteMedia(_ asset:MediaAsset) {
        let count=mediaDeletionIDs(asset.id).count
        if count>0 {
            let alert=NSAlert();alert.messageText=L("素材を削除")
            alert.informativeText=asset.name+"\n"+(VMMLocalization.language == .english ? "Delete \(count) referencing items and descendants as well? Files are retained. Undo restores the edit.":"使用しているアイテムと子アイテム計\(count)個も削除します。ファイルは保持され、Undoで戻せます。")
            alert.addButton(withTitle:L("削除"));alert.addButton(withTitle:L("キャンセル"))
            guard alert.runModal() == .alertFirstButtonReturn else{return}
        }
        reportEditing{try deleteMedia(asset.id,deleteItems:true)}
    }
    func revealMedia(_ asset:MediaAsset) {
        let url=directory.appendingPathComponent("Media").appendingPathComponent(asset.file)
        guard FileManager.default.fileExists(atPath:url.path) else{error=L("素材ファイルが見つかりません。");return}
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    func deleteTrack(_ index:Int,deleteItems:Bool=false)throws {
        guard !busy,project.tracks.indices.contains(index) else{throw VMMError.message("レイヤーがないか、処理中です。")}
        guard project.tracks.count>1 else{throw VMMError.message("最後のレイヤーは削除できません。")}
        guard !project.tracks[index].locked else{throw VMMError.message("レイヤーがロックされています。")}
        let ids=deletionClosure(Set(project.clips.filter{$0.track==index}.map(\.id)))
        guard ids.isEmpty || deleteItems else{throw VMMError.message("配置済みアイテムがあります。アイテムの削除を指定してください。")}
        guard !project.clips.contains(where:{ids.contains($0.id) && project.tracks[$0.track].locked}) else{throw VMMError.message("削除対象にロックされたアイテムがあります。")}
        var candidate=project;candidate.tracks.remove(at:index);candidate.removeClips(ids)
        for i in candidate.clips.indices where candidate.clips[i].track>index{candidate.clips[i].track-=1}
        _=try candidate.validated();pause();checkpoint();cancelSpeech();project=candidate
        if selectedTrack>index{selectedTrack-=1};reconcileEditingSelection();scheduleDirtySpeech()
    }
    func confirmDeleteTrack(_ index:Int) {
        guard project.tracks.indices.contains(index) else{return}
        let id=project.tracks[index].id,count=deletionClosure(Set(project.clips.filter{$0.track==index}.map(\.id))).count
        if count>0 {
            let alert=NSAlert();alert.messageText=L("レイヤーを削除")
            alert.informativeText=project.tracks[index].name+"\n"+(VMMLocalization.language == .english ? "Delete \(count) items and descendants as well? Undo restores the edit.":"配置済みアイテムと子アイテム計\(count)個も削除します。Undoで戻せます。")
            alert.addButton(withTitle:L("削除"));alert.addButton(withTitle:L("キャンセル"))
            guard alert.runModal() == .alertFirstButtonReturn else{return}
        }
        if let current=project.tracks.firstIndex(where:{$0.id==id}){reportEditing{try deleteTrack(current,deleteItems:true)}}
    }
}
