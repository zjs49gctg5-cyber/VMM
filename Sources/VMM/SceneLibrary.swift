import SwiftUI

@MainActor extension EditorStore {
    var sceneFolder:URL {sharedFolder.appendingPathComponent("Scenes")}
    func sceneSelection()->Set<UUID> {
        var ids=selection,previous:Set<UUID>=[]
        while ids != previous {
            previous=ids;ids=LinkedMedia.expanded(ids,in:project)
            for clip in project.clips where ids.contains(clip.id) {
                if let parent=clip.parentID {ids.insert(parent)}
                ids.formUnion(project.descendants(of:clip.id))
            }
            for owner in project.clips where (owner.sceneMembers ?? []).contains(where:ids.contains) {ids.insert(owner.id)}
        }
        return ids
    }
    func sceneProject(name:String)throws->Project {
        let ids=sceneSelection(),clips=project.clips.filter{ids.contains($0.id)}
        guard !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,name.count<=200,!clips.isEmpty,clips.count<=20000,let start=clips.map(\.start).min() else{throw VMMError.message("シーン名を指定し、保存するアイテムを選択してください。")}
        let layers=Set(clips.map(\.track)).sorted(),mapping=Dictionary(uniqueKeysWithValues:layers.enumerated().map{($0.element,$0.offset)})
        var result=project;result.name=name;result.markers=nil;result.timelineRange=nil
        let characterIDs=Set(clips.compactMap(\.characterPresetID));result.characters=project.characters?.filter{characterIDs.contains($0.id)}
        result.clips=clips.map{var c=$0;c.start-=start;c.track=mapping[c.track]!;return c}
        result.tracks=layers.map{project.tracks[$0]};result.assets=project.assets.filter{result.usedAssetIDs.contains($0.id)}
        _=try result.validated();return result
    }
    func saveScene(name:String,to destination:URL?=nil)async throws->URL {
        guard !busy else{throw VMMError.message("処理中です。")}
        let snapshot=try sceneProject(name:name),source=directory
        let folder=destination?.deletingLastPathComponent() ?? sceneFolder
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let target=destination ?? folder.appendingPathComponent("Scene-\(UUID()).vmm")
        guard target.pathExtension=="vmm",!FileManager.default.fileExists(atPath:target.path) else{throw VMMError.message("シーンの保存先には新しい.vmmを指定してください。")}
        busy=true;retainSession(source);defer{releaseSession(source);busy=false}
        try await Task.detached(priority:.utility){try ProjectPackage.write(snapshot,media:source.appendingPathComponent("Media"),to:target)}.value
        status="シーンを素材込みで保存しました。";return target
    }
    @discardableResult func insertScene(_ url:URL,at start:Double?=nil)async throws->UUID {
        guard !busy else{throw VMMError.message("処理中です。")}
        let insertion=start ?? playhead;guard insertion.isFinite,insertion>=0 else{throw VMMError.message("配置時刻が不正です。")}
        busy=true;defer{busy=false}
        let (source,stage)=try await Task.detached(priority:.utility){try ProjectIO.read(url)}.value
        defer{try? FileManager.default.removeItem(at:stage)}
        guard !source.clips.isEmpty,source.clips.count<=20000,project.tracks.count+source.tracks.count+1<=32 else{throw VMMError.message("シーンが空、アイテムが多すぎる、またはレイヤーが足りません。")}
        let compositionIDs=Dictionary(uniqueKeysWithValues:(source.precompositions ?? []).map{($0.id,UUID())})
        let assetIDs=Dictionary(uniqueKeysWithValues:source.assets.map{($0.id,UUID())}),clipIDs=Dictionary(uniqueKeysWithValues:source.clips.map{($0.id,UUID())}),characterIDs=Dictionary(uniqueKeysWithValues:(source.characters ?? []).map{($0.id,UUID())})
        let sequences=Dictionary(uniqueKeysWithValues:Set(source.clips.compactMap(\.scriptSequenceID)).map{($0,UUID())})
        let files=Dictionary(uniqueKeysWithValues:Set(source.assets.flatMap(\.files)).map{($0,"\(UUID()).\(URL(fileURLWithPath:$0).pathExtension)")})
        var candidate=project
        let base=candidate.tracks.count,groupID=UUID()
        var assets=source.assets
        for i in assets.indices {assets[i].id=assetIDs[assets[i].id]!;assets[i].file=files[assets[i].file]!;assets[i].proxyFile=assets[i].proxyFile.flatMap{files[$0]};if assets[i].psd != nil {for j in assets[i].psd!.layers.indices {assets[i].psd!.layers[j].file=assets[i].psd!.layers[j].file.flatMap{files[$0]}}}}
        var characters=source.characters ?? []
        var names=Set(availableCharacters.map(\.name))
        for i in characters.indices {
            characters[i].id=characterIDs[characters[i].id]!;characters[i].portraitAssetID=characters[i].portraitAssetID.flatMap{assetIDs[$0]};characters[i].portraitMouthID=characters[i].portraitMouthID.flatMap{assetIDs[$0]}
            let original=characters[i].name;var number=2;while names.contains(characters[i].name){characters[i].name="\(original) (\(number))";number+=1};names.insert(characters[i].name)
        }
        var inserted=LinkedMedia.remap(source.clips)
        for i in inserted.indices {
            let old=inserted[i];inserted[i].id=clipIDs[old.id]!;inserted[i].start+=insertion;inserted[i].track+=base
            inserted[i].parentID=old.parentID.flatMap{clipIDs[$0]} ?? ([.transition,.adjustment].contains(old.kind) ? nil:groupID)
            inserted[i].precompositionID=old.precompositionID.flatMap{compositionIDs[$0]}
            inserted[i].sceneMembers=old.sceneMembers?.compactMap{clipIDs[$0]}
            inserted[i].assetID=old.assetID.flatMap{assetIDs[$0]};inserted[i].mouthAssetID=old.mouthAssetID.flatMap{assetIDs[$0]};inserted[i].audioReactive?.assetID=old.audioReactive?.assetID.flatMap{assetIDs[$0]};inserted[i].tracking?.assetID=old.tracking?.assetID.flatMap{assetIDs[$0]}
            inserted[i].characterPresetID=old.characterPresetID.flatMap{characterIDs[$0]};inserted[i].scriptSequenceID=old.scriptSequenceID.flatMap{sequences[$0]}
            if old.masks != nil {for j in old.masks!.indices {inserted[i].masks?[j].assetID=old.masks![j].assetID.flatMap{assetIDs[$0]}}}
        }
        let compositions=(source.precompositions ?? []).map{original -> Precomposition in
            var c=original;c.id=compositionIDs[original.id]!
            let ids=Dictionary(uniqueKeysWithValues:c.clips.map{($0.id,UUID())})
            c.clips=LinkedMedia.remap(c.clips).map{old in
                var clip=old;clip.id=ids[old.id]!;clip.parentID=old.parentID.flatMap{ids[$0]};clip.sceneMembers=old.sceneMembers?.compactMap{ids[$0]};clip.precompositionID=old.precompositionID.flatMap{compositionIDs[$0]}
                clip.assetID=old.assetID.flatMap{assetIDs[$0]};clip.mouthAssetID=old.mouthAssetID.flatMap{assetIDs[$0]};clip.audioReactive?.assetID=old.audioReactive?.assetID.flatMap{assetIDs[$0]};clip.tracking?.assetID=old.tracking?.assetID.flatMap{assetIDs[$0]};clip.characterPresetID=old.characterPresetID.flatMap{characterIDs[$0]};clip.scriptSequenceID=nil
                if clip.masks != nil {for i in clip.masks!.indices{clip.masks![i].assetID=clip.masks![i].assetID.flatMap{assetIDs[$0]}}};return clip
            };return c
        }
        candidate.precompositions=(candidate.precompositions ?? [])+compositions
        var group=Clip(kind:.group,name:source.name,track:base+source.tracks.count,start:insertion,duration:source.duration);group.id=groupID;group.sceneMembers=inserted.map(\.id)
        candidate.assets+=assets;candidate.characters=(candidate.characters ?? [])+characters
        candidate.tracks+=source.tracks.map{var t=$0;t.id=UUID();t.locked=false;return t};candidate.tracks.append(Track(name:L("シーン制御")))
        candidate.clips+=inserted+[group];_=try candidate.validated()
        let target=directory.appendingPathComponent("Media"),pairs=files.map{(stage.appendingPathComponent("Media").appendingPathComponent($0.key),target.appendingPathComponent($0.value))}
        try await Task.detached(priority:.utility){
            var copied:[URL]=[]
            do {for (source,target) in pairs {try ProjectIO.copy(source,to:target);copied.append(target)}}catch{for file in copied{try? FileManager.default.removeItem(at:file)};throw error}
        }.value
        pause();checkpoint();project=candidate;selectedIDs=[];selectedID=groupID;selectedTrack=group.track;scheduleDirtySpeech()
        status="シーンを編集可能なグループとして配置しました。";return groupID
    }
    func dissolveScene(_ id:UUID)throws {
        guard !busy,let group=project.clips.first(where:{$0.id==id}),let members=group.sceneMembers else{throw VMMError.message("シーン制御を選択してください。")}
        guard group.animation==nil,group.spatialAnimation==nil,group.anchorPoint==nil,group.scale==1,group.x==0.5,group.y==0.5,(group.rotation ?? 0)==0,group.opacity==1,group.volume==1,(group.effects ?? []).isEmpty,(group.masks ?? []).isEmpty,group.transform == nil || group.transform == Transform2D(),group.flipX != true,group.flipY != true,group.blendMode == nil || group.blendMode == .normal else{throw VMMError.message("変形やアニメーションのあるシーンは解除できません。設定を初期状態へ戻してください。")}
        let contained=project.clips.filter{Set(members).contains($0.id)},track=project.tracks[group.track]
        guard group.parentID==nil,contained.allSatisfy({$0.start>=group.start-0.000001 && $0.start+$0.duration<=group.start+group.duration+0.000001}),(track.effects ?? []).isEmpty,(track.opacity ?? 1)==1,track.blendMode == nil || track.blendMode == .normal,track.visible,!track.muted else{throw VMMError.message("範囲・親子・レイヤー効果を初期状態へ戻してからシーンを解除してください。")}
        guard project.clips.filter({Set(members+[id]).contains($0.id)}).allSatisfy({!project.tracks[$0.track].locked}) else{throw VMMError.message("シーンにロックされたアイテムがあります。")}
        var candidate=project;candidate.clips.removeAll{$0.id==id};for i in candidate.clips.indices where candidate.clips[i].parentID==id {candidate.clips[i].parentID=nil}
        for i in candidate.clips.indices where candidate.clips[i].sceneMembers != nil {candidate.clips[i].sceneMembers?.removeAll{$0==id}}
        _=try candidate.validated();pause();checkpoint();project=candidate;selectedID=nil;selectedIDs=Set(members)
    }
}
struct SceneEntry:Identifiable {let url:URL;let name:String;let duration:Double;var id:String{url.path}}
struct SceneLibraryView:View {
    @ObservedObject var store:EditorStore
    @State private var name=""
    @State private var refresh=0
    @State private var entries:[SceneEntry]=[]
    var body:some View {VStack(alignment:.leading,spacing:10){
        PrecompositionLibrary(store:store)
        Divider()
        Text(L("シーンライブラリ")).bold()
        HStack{TextField(L("シーン名"),text:$name);Button(L("選択をシーンに保存")){Task{do{_=try await store.saveScene(name:name);refresh+=1}catch{store.error=error.localizedDescription}}}.disabled(store.selection.isEmpty || name.isEmpty || store.busy);Button(L("更新")){refresh+=1}}
        ScrollView {VStack(alignment:.leading){ForEach(entries){entry in HStack {Text(entry.name);Spacer();Text(String(format:"%.2f s",entry.duration));Button(L("現在位置に配置")){Task{do{_=try await store.insertScene(entry.url)}catch{store.error=error.localizedDescription}}}.disabled(store.busy)}}}}.frame(maxHeight:170)
        Text(L("選択した親・子・リンク素材を保存し、新しいレイヤーへ配置します。シーン制御を動かすと全アイテムが移動します。")).foregroundColor(.secondary)
    }.task(id:refresh){let folder=store.sceneFolder;entries=await Task.detached {
        ((try? FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil)) ?? []).filter{$0.pathExtension=="vmm"}.compactMap{url -> SceneEntry? in guard let reader=try? PackageMediaReader(url),let data=try? reader.projectData(),let project=try? JSONDecoder().decode(Project.self,from:data) else{return nil};return SceneEntry(url:url,name:project.name,duration:project.duration)}.sorted{$0.name.localizedStandardCompare($1.name) == .orderedAscending}
    }.value}}
}

extension Project {
    func validateSceneOwnership()throws {
        guard clips.contains(where:{$0.sceneMembers != nil}) else{return}
        let table=Dictionary(uniqueKeysWithValues:clips.map{($0.id,$0)})
        let parents=Dictionary(grouping:clips.filter{$0.parentID != nil},by:{$0.parentID!})
        var cache:[UUID:Int]=[:],visiting:Set<UUID>=[]
        func height(_ id:UUID)throws->Int {
            if let value=cache[id]{return value}
            guard visiting.insert(id).inserted else{throw VMMError.message("シーンが循環しています。")}
            defer{visiting.remove(id)}
            let children=Set((table[id]?.sceneMembers ?? [])+(parents[id] ?? []).map(\.id))
            var result=1
            for child in children {result=max(result,1+(try height(child)));guard result<=16 else{throw VMMError.message("シーンの入れ子は15段までにしてください。")}}
            cache[id]=result;return result
        }
        for clip in clips where clip.sceneMembers != nil {_=try height(clip.id)}
    }
}
