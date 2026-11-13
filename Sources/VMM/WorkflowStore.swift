import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers
import Darwin

struct ProjectPackage {
    static func write(_ project:Project,media:URL,to destination:URL,allowMissing:Bool=false,progress:@Sendable (Double)->Void = {_ in})throws {
        let project=project.packageSnapshot
        _=try project.validated()
        let stage=destination.deletingLastPathComponent().appendingPathComponent(".vmm-package-\(UUID())")
        try FileManager.default.createDirectory(at:stage.appendingPathComponent("Media"),withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:stage)}
        let files=Set(project.assets.flatMap(\.files)).sorted()
        try ProjectIO.preflight(files:files.map{media.appendingPathComponent($0)}.filter{!allowMissing || FileManager.default.fileExists(atPath:$0.path)},destination:destination.deletingLastPathComponent())
        for (index,file) in files.enumerated() {
            let source=media.appendingPathComponent(file),target=stage.appendingPathComponent("Media").appendingPathComponent(file)
            if allowMissing && !FileManager.default.fileExists(atPath:source.path){continue}
            try ProjectIO.copy(source,to:target)
            progress(Double(index+1)/Double(max(1,files.count)))
        }
        progress(1)
        try JSONEncoder().encode(project).write(to:stage.appendingPathComponent("project.json"),options:.atomic)
        if FileManager.default.fileExists(atPath:destination.path) {_=try FileManager.default.replaceItemAt(destination,withItemAt:stage)} else {try FileManager.default.moveItem(at:stage,to:destination)}
    }
}
enum EditingTool:String,CaseIterable {case select="選択",blade="分割",text="文字",shape="図形"}
@MainActor extension EditorStore {
    var selection:Set<UUID> {selectedIDs.union(selectedID.map{[$0]} ?? []).intersection(Set(project.clips.map(\.id)))}
    var sharedFolder:URL {settings.libraryPath.map{URL(fileURLWithPath:$0)} ?? VMMPaths.library}
    var recoveryFolder:URL {settings.autosavePath.map{URL(fileURLWithPath:$0)} ?? VMMPaths.recovery}
    func ensurePreferencesWritable(_ file:String)throws {
        guard !protectedPreferences.contains(file) else {
            throw VMMError.message("\(file) は読み込みに失敗したため保存できません。元のファイルを修復または退避してから再起動してください。\n場所: \(preferencesDirectory.path)")
        }
    }
    func writePreferences<T:Encodable>(_ value:T,file:String)throws {
        try ensurePreferencesWritable(file)
        try FileManager.default.createDirectory(at:preferencesDirectory,withIntermediateDirectories:true)
        try JSONEncoder().encode(value).write(to:preferencesDirectory.appendingPathComponent(file),options:.atomic)
    }
    func persistSettings() {
        VMMLocalization.language=settings.uiLanguage ?? .japanese
        workspaceWindows.refreshTitles()
        do {try writePreferences(settings,file:"settings.json")}catch{self.error=error.localizedDescription};startAutosave()}
    func persistCatalog() {do {try writePreferences(catalog,file:"catalog.json")}catch{self.error=error.localizedDescription}}
    func captureCharacter(name:String) {
        guard let c=selected,[.text,.speech].contains(c.kind),!name.trimmingCharacters(in:.whitespaces).isEmpty else {return}
        let preset=CharacterPreset(name:name,speechConfiguration:c.speechConfiguration,speakerName:c.speakerName,speakerID:c.speakerID,color:c.color,fontSize:c.fontSize,x:c.x,y:c.y,style:c.textStyle ?? TextStyle())
        catalog.characters.append(preset);persistCatalog();edit(c.id){$0.characterPresetID=preset.id}
    }
    func applyCharacter(_ id:UUID,to ids:Set<UUID>?=nil) {
        if project.characters?.contains(where:{$0.id==id}) == true {reportEditing{try applyProjectCharacter(id,ids:ids)};return}
        guard let preset=catalog.characters.first(where:{$0.id==id}),!busy else {return}
        let targets=ids ?? selection;guard !targets.isEmpty else {return}
        var candidate=project
        for i in candidate.clips.indices where targets.contains(candidate.clips[i].id) && [.text,.speech].contains(candidate.clips[i].kind) {preset.apply(to:&candidate.clips[i])}
        do {_=try candidate.validated()} catch {self.error=error.localizedDescription;return}
        pause();checkpoint()
        for c in project.clips where targets.contains(c.id) && [.text,.speech].contains(c.kind) && !project.tracks[c.track].locked {edit(c.id,record:false){preset.apply(to:&$0)}}
    }
    func importScript(_ source:String,at start:Double?=nil,track:Int?=nil)throws {
        guard !busy else {throw VMMError.message("処理中です。")}
        let lines=ScriptParser.parse(source),layer=track ?? selectedTrack
        guard !lines.isEmpty,lines.count<=2000,project.tracks.indices.contains(layer),!project.tracks[layer].locked else {throw VMMError.message("脚本が空、長すぎる、またはレイヤーがロックされています。")}
        var candidate=project,time=start ?? playhead;if candidate.pronunciations == nil {candidate.pronunciations=catalog.pronunciations};let sequence=UUID()
        for line in lines {
            let duration=max(1,Double(line.text.count)/6+0.4)
            var c=Clip(kind:.speech,name:line.speaker.isEmpty ? String(line.text.prefix(24)):line.speaker,track:layer,start:time,duration:duration)
            c.text=line.text;c.speechDirty=true;c.y=0.85;c.scriptSequenceID=sequence;setDefaultSpeechVoice(&c)
            if let preset=availableCharacters.first(where:{$0.name==line.speaker}) {preset.apply(to:&c)}
            candidate.clips.append(c);time+=duration+0.15
        }
        _=try candidate.validated();pause();checkpoint();project=candidate;selectedID=candidate.clips.last?.id;selectedIDs=[];scheduleDirtySpeech()
        status="脚本から\(lines.count)行を配置しました。音声生成後に続くセリフの位置を調整します。"
    }
    func importScriptFile() {
        let panel=NSOpenPanel();panel.allowedContentTypes=[.plainText];guard panel.runModal() == .OK,let url=panel.url else {return}
        do {let source=try String(contentsOf:url,encoding:.utf8);try importScript(source)}catch{self.error=error.localizedDescription}
    }
    func setDictionary(_ entries:[PronunciationEntry]) {
        checkpoint();project.pronunciations=entries;catalog.pronunciations=entries;persistCatalog()
        for i in project.clips.indices where project.clips[i].kind == .speech {project.clips[i].speechDirty=true}
        scheduleDirtySpeech()
    }
    func startAutosave() {
        autosaveTimer?.invalidate();autosaveTimer=nil
        guard settings.autosaveSeconds>=10 else {return}
        autosaveTimer=Timer.scheduledTimer(withTimeInterval:settings.autosaveSeconds,repeats:true){[weak self] _ in MainActor.assumeIsolated {guard let self,self.dirty,!self.busy else {return};self.scheduleAutosave()}}
    }
    @discardableResult func autosave(to folder:URL)throws->URL {
        try AutosaveWriter.write(project,media:directory.appendingPathComponent("Media"),folder:folder,keep:settings.recoveryCount,identity:savedURL?.standardizedFileURL.path ?? recoveryIdentity,savedPath:savedURL?.path)
    }
    func scheduleAutosave() {
        guard autosaveTask == nil,!busy,dirty else{return}
        let snapshot=project,source=directory,folder=recoveryFolder,keep=settings.recoveryCount,identity=savedURL?.standardizedFileURL.path ?? recoveryIdentity,savedPath=savedURL?.path
        retainSession(source)
        autosaveTask=Task { [weak self] in
            defer {self?.releaseSession(source);self?.autosaveTask=nil}
            do {
                _ = try await Task.detached(priority:.utility){try AutosaveWriter.write(snapshot,media:source.appendingPathComponent("Media"),folder:folder,keep:keep,identity:identity,savedPath:savedPath)}.value
            } catch {
                if let self,self.directory==source {self.status="自動保存：\(error.localizedDescription)"}
            }
        }
    }
    func saveRecoveryNow()async->Bool {
        guard !busy else{return false}
        if let autosaveTask {await autosaveTask.value}
        let source=directory,snapshot=project,folder=recoveryFolder,keep=settings.recoveryCount,identity=savedURL?.standardizedFileURL.path ?? recoveryIdentity,savedPath=savedURL?.path
        retainSession(source);defer{releaseSession(source)}
        do {_=try await Task.detached(priority:.utility){try AutosaveWriter.write(snapshot,media:source.appendingPathComponent("Media"),folder:folder,keep:keep,identity:identity,savedPath:savedPath)}.value;return true}
        catch{self.error=error.localizedDescription;return false}
    }
    func recoveryFiles()->[URL] {((try? FileManager.default.contentsOfDirectory(at:recoveryFolder,includingPropertiesForKeys:[.contentModificationDateKey])) ?? []).filter{$0.pathExtension=="vmm"}.sorted{$0.lastPathComponent>$1.lastPathComponent}}
    func deleteSelection() {
        guard !busy else {return};let roots=LinkedMedia.expanded(selection,in:project),targets=roots.reduce(roots){ids,id in project.clips.first{$0.id==id}?.sceneMembers == nil ? ids:ids.union(LinkedMedia.expandedHierarchy([id],in:project))}
        guard !targets.isEmpty else {return}
        guard !project.clips.contains(where:{$0.parentID.map(targets.contains)==true && !targets.contains($0.id)}) else {error="選択外の子アイテムが残っています。子も選択してください。";return}
        guard project.clips.filter({targets.contains($0.id)}).allSatisfy({!project.tracks[$0.track].locked}) else {return}
        pause();checkpoint();cancelSpeech();project.removeClips(targets);selectedID=nil;selectedIDs=[];scheduleDirtySpeech()
    }
    func bulkStyle() {
        guard let source=selected,!busy else {return}
        let targets=selection,clips=project.clips.filter{targets.contains($0.id) && [.text,.speech].contains($0.kind)}
        guard !clips.isEmpty else {return}
        guard clips.allSatisfy({project.tracks.indices.contains($0.track) && !project.tracks[$0.track].locked}) else {
            error="選択した字幕のレイヤーがロックされています。";return
        }
        var candidate=project
        for i in candidate.clips.indices where targets.contains(candidate.clips[i].id) && [.text,.speech].contains(candidate.clips[i].kind) {
            candidate.clips[i].textStyle=source.textStyle;candidate.clips[i].fontSize=source.fontSize;candidate.clips[i].color=source.color
        }
        guard candidate != project else{return}
        pause();checkpoint();project=candidate
    }
    func arrange(_ mode:String) { reportEditing { try arrangeValidated(mode) } }
    func arrangeValidated(_ mode:String)throws {
        guard !busy else {throw VMMError.message("処理中です。")}
        guard ["左揃え","上揃え","中央","開始揃え","順番","順に配置"].contains(mode) else {throw VMMError.message("整列方法が不正です。")}
        // Use the original project to derive all destinations before editing. Equal
        // starts retain project order, so sequential placement is deterministic.
        let ids=selection
        let clips=project.clips.enumerated().filter{ids.contains($0.element.id)}.sorted {
            $0.element.start == $1.element.start ? $0.offset < $1.offset : $0.element.start < $1.element.start
        }.map(\.element)
        guard let first=clips.first,clips.count>1 else {throw VMMError.message("2つ以上のアイテムを選択してください。")}
        guard clips.allSatisfy({project.tracks.indices.contains($0.track) && !project.tracks[$0.track].locked}) else {throw VMMError.message("選択したアイテムのレイヤーがロックされています。")}
        var starts:[UUID:Double]=[:],time=first.start
        if mode == "開始揃え" || mode == "順番" || mode == "順に配置" {
            for clip in clips {
                starts[clip.id] = mode == "開始揃え" ? first.start : time
                time += clip.duration+0.15
            }
        }
        var candidate=project
        for original in clips {
            guard let index=candidate.clips.firstIndex(where:{$0.id==original.id}) else {throw VMMError.message("選択したアイテムがありません。")}
            let before=candidate.clips[index];var after=before
            switch mode {
            case "左揃え":after.x=first.x
            case "上揃え":after.y=first.y
            case "中央":after.x=0.5
            default:after.start=starts[original.id]!
            }
            if before.start != after.start {candidate=try LinkedMedia.updated(candidate,from:before,to:after,validate:false)}
            else {candidate.clips[index]=after}
        }
        // A selected linked item or child may have moved along with another item;
        // reject contradictory destinations instead of silently moving it twice.
        for (id,start) in starts {
            guard let clip=candidate.clips.first(where:{$0.id==id}),abs(clip.start-start)<1e-8 else {
                throw VMMError.message("リンクまたは親子関係のあるアイテムを指定の位置に配置できません。選択内容を変更するか、関係を解除してください。")
            }
        }
        _=try candidate.validated()
        guard candidate != project else {return}
        pause();checkpoint();project=candidate
    }
    func relink(_ id:UUID,url:URL)async throws {
        guard !busy,let index=project.assets.firstIndex(where:{$0.id==id}) else {throw VMMError.message("素材がありません。")}
        let old=project.assets[index]
        busy=true;defer{busy=false};pause()
        if old.psd != nil {
            guard ["psd","zip"].contains(url.pathExtension.lowercased()) else {throw VMMError.message("PSDまたはPSD入りZIPを指定してください。")}
            let target=directory.appendingPathComponent("Media")
            let values=try await Task.detached{try Self.importPSD(url,into:target)}.value
            guard var replacement=values.first(where:{$0.name==old.name}) ?? values.first,let document=replacement.psd else {throw VMMError.message("PSDがありません。")}
            replacement.id=old.id;replacement.tags=old.tags;checkpoint();project.assets[index]=replacement
            for i in project.clips.indices where project.clips[i].assetID==id {project.clips[i].psd = .initial(document)}
            status="PSDを再リンクしました。パーツ選択は初期状態に戻りました。";return
        }
        let probed=try await MediaProbe.inspect(url);guard probed.kind==old.kind else {throw VMMError.message("同じ種類の素材を指定してください。")}
        // The user explicitly selected this media; copy its contents, not a link
        // back to an external location in the saved project package.
        let file="\(UUID()).\(url.pathExtension)";try FileManager.default.copyItem(at:url.resolvingSymlinksInPath(),to:directory.appendingPathComponent("Media").appendingPathComponent(file))
        invalidateAudioCache(id);TimelineMediaCache.shared.clear();checkpoint();project.assets[index].file=file;project.assets[index].duration=probed.duration;project.assets[index].proxyFile=nil
        for i in project.clips.indices where project.clips[i].assetID==id {project.clips[i].sourceOffset=min(project.clips[i].sourceOffset,max(0,probed.duration-1/Double(project.fps)))}
        status="素材のリンクを更新しました。"
    }
    func saveTemplate(name:String)throws {
        guard !name.isEmpty,!name.contains("/") else {throw VMMError.message("テンプレート名を指定してください。")}
        let folder=sharedFolder.appendingPathComponent("Templates");try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let target=folder.appendingPathComponent("\(name)-\(UUID()).vmm")
        try ProjectPackage.write(project,media:directory.appendingPathComponent("Media"),to:target);status="テンプレートを保存しました。"
    }
    func templates()->[URL] {((try? FileManager.default.contentsOfDirectory(at:sharedFolder.appendingPathComponent("Templates"),includingPropertiesForKeys:nil)) ?? []).filter{$0.pathExtension=="vmm"}.sorted{$0.lastPathComponent<$1.lastPathComponent}}
    func addSharedAsset(_ id:UUID)throws {
        guard let asset=project.assets.first(where:{$0.id==id}) else {throw VMMError.message("素材がありません。")}
        let folder=sharedFolder.appendingPathComponent("Assets").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder.appendingPathComponent("Media"),withIntermediateDirectories:true)
        for file in asset.files {try FileManager.default.copyItem(at:directory.appendingPathComponent("Media").appendingPathComponent(file),to:folder.appendingPathComponent("Media").appendingPathComponent(file))}
        try JSONEncoder().encode(asset).write(to:folder.appendingPathComponent("asset.json"));status="共有ライブラリへ保存しました。"
    }
    func sharedAssets()->[(URL,MediaAsset)] {
        ((try? FileManager.default.contentsOfDirectory(at:sharedFolder.appendingPathComponent("Assets"),includingPropertiesForKeys:nil)) ?? []).compactMap{folder in guard let asset=try? readSharedAsset(folder) else {return nil};return (folder,asset)}
    }
    func readSharedAsset(_ folder:URL)throws->MediaAsset {
        let reader=try PackageMediaReader(folder)
        return try JSONDecoder().decode(MediaAsset.self,from:reader.metadata("asset.json"))
    }
    func importShared(_ folder:URL,asset:MediaAsset)throws {
        guard !busy else {return};var asset=asset;asset.id=UUID()
        // Imported packages use UUID filenames. Preserve these only if collision contents agree.
        var candidate=project;candidate.assets.append(asset);_=try candidate.validated()
        let reader=try PackageMediaReader(folder),files=Set(asset.files).sorted()
        let stage=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-shared-import-\(UUID())")
        try FileManager.default.createDirectory(at:stage,withIntermediateDirectories:false)
        defer{try? FileManager.default.removeItem(at:stage)}
        for file in files {
            let source=stage.appendingPathComponent(file),target=directory.appendingPathComponent("Media").appendingPathComponent(file)
            guard try reader.copyMedia(file,to:source) else{throw VMMError.message("共有素材のファイルが見つかりません。")}
            if FileManager.default.fileExists(atPath:target.path) {guard try Data(contentsOf:source)==Data(contentsOf:target) else {throw VMMError.message("素材ファイル名が衝突しています。")}}
        }
        var copied:[URL]=[]
        do {
            for file in files {
                let target=directory.appendingPathComponent("Media").appendingPathComponent(file)
                if !FileManager.default.fileExists(atPath:target.path) {try FileManager.default.copyItem(at:stage.appendingPathComponent(file),to:target);copied.append(target)}
            }
        } catch {for target in copied {try? FileManager.default.removeItem(at:target)};throw error}
        checkpoint();project.assets.append(asset)
    }
}

@MainActor extension EditorStore {
    var missingAssets:[MediaAsset] {project.assets.filter{asset in asset.files.filter{$0 != asset.proxyFile}.contains{!FileManager.default.fileExists(atPath:directory.appendingPathComponent("Media").appendingPathComponent($0).path)}}}
    func chooseRelink(_ id:UUID) {
        let panel=NSOpenPanel();guard panel.runModal() == .OK,let url=panel.url else{return}
        Task{do{try await relink(id,url:url)}catch{self.error=error.localizedDescription}}
    }
    func makeProxy(_ id:UUID)async throws {
        guard !busy,let asset=project.assets.first(where:{$0.id==id}),asset.kind == .video else {throw VMMError.message("動画素材を指定してください。")}
        busy=true;defer{busy=false}
        let source=AVURLAsset(url:directory.appendingPathComponent("Media").appendingPathComponent(asset.file))
        guard let session=AVAssetExportSession(asset:source,presetName:AVAssetExportPreset1280x720) else {throw VMMError.message("プロキシを作成できません。")}
        let name="proxy-\(UUID()).mp4",url=directory.appendingPathComponent("Media").appendingPathComponent(name)
        session.outputURL=url;session.outputFileType = .mp4;session.shouldOptimizeForNetworkUse=true
        status="プロキシを生成しています…"
        await session.export()
        guard session.status == .completed else {try? FileManager.default.removeItem(at:url);throw session.error ?? VMMError.message("プロキシ生成に失敗しました。")}
        if let i=project.assets.firstIndex(where:{$0.id==id}) {checkpoint();project.assets[i].proxyFile=name}
        status="プロキシを作成しました。書き出しには元素材を使います。"
    }
}

@MainActor extension EditorStore {
    func importURLs(_ urls:[URL],placement:MediaDropPosition?=nil,maximumFiles:Int=100)async throws->[UUID] {
        guard !busy else {throw VMMError.message("処理中です。")}
        guard !urls.isEmpty,urls.count<=maximumFiles else {throw VMMError.message("1〜\(maximumFiles)ファイルを指定してください。")}
        if let p=placement {guard project.tracks.indices.contains(p.track),!project.tracks[p.track].locked,p.time.isFinite,p.time>=0 else {throw VMMError.message("ドロップ先が不正、またはロックされています。")}}
        busy=true;pause();status="素材を読み込んでいます…";var committed=false;defer{busy=false;if !committed{status="素材の読み込みを中止しました。"}}
        let stage=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-drop-\(UUID())")
        try FileManager.default.createDirectory(at:stage,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:stage)}
        var additions:[MediaAsset]=[]
        for url in urls {
            guard url.isFileURL else {throw VMMError.message("ローカルファイルを指定してください。")}
            let scoped=url.startAccessingSecurityScopedResource();defer{if scoped{url.stopAccessingSecurityScopedResource()}}
            if ["psd","zip"].contains(url.pathExtension.lowercased()) {
                additions+=try await Task.detached{try Self.importPSD(url,into:stage)}.value
            } else {
                let probe=try await MediaProbe.inspect(url),file="\(UUID()).\(url.pathExtension)"
                try FileManager.default.copyItem(at:url.resolvingSymlinksInPath(),to:stage.appendingPathComponent(file))
                additions.append(MediaAsset(name:url.lastPathComponent,file:file,kind:probe.kind,duration:probe.duration))
            }
        }
        var candidate=project;candidate.assets+=additions;var placed:[Clip]=[]
        if let p=placement {
            var time=snapped(p.time)
            for asset in additions {
                var clip=Clip(kind:asset.kind,name:asset.name,track:p.track,start:time,duration:asset.kind == .image ? 5:max(1/Double(project.fps),asset.duration))
                clip.assetID=asset.id;if let document=asset.psd{clip.psd = .initial(document)}
                placed.append(clip);time=clip.end
            }
            candidate.clips+=placed
        }
        _=try candidate.validated()
        var copied:[URL]=[]
        do {for file in Set(additions.flatMap(\.files)) {let target=directory.appendingPathComponent("Media").appendingPathComponent(file);try FileManager.default.copyItem(at:stage.appendingPathComponent(file),to:target);copied.append(target)}}
        catch {for file in copied{try? FileManager.default.removeItem(at:file)};throw error}
        checkpoint();project=candidate;committed=true;status="\(additions.count)個の素材を追加しました。"
        if let p=placement {selectedTrack=p.track;selectedIDs=Set(placed.map(\.id));selectedID=placed.first?.id;playhead=snapped(p.time)}
        return additions.map(\.id)
    }
}

@MainActor extension EditorStore {
    func duplicateSelection() {
        guard !busy,!selection.isEmpty else {return}
        let ids=LinkedMedia.expandedHierarchy(selection,in:project)
        let clips=project.clips.filter{ids.contains($0.id)}
        guard clips.allSatisfy({!project.tracks[$0.track].locked}),let start=clips.map(\.start).min(),let end=clips.map(\.end).max() else{return}
        let mapping=Dictionary(uniqueKeysWithValues:clips.map{($0.id,UUID())}),sequences=Dictionary(uniqueKeysWithValues:Set(clips.compactMap(\.scriptSequenceID)).map{($0,UUID())})
        let copies=LinkedMedia.remap(clips).map{clip->Clip in var c=clip;c.id=mapping[c.id]!;c.start+=end-start;if let parent=c.parentID,let id=mapping[parent]{c.parentID=id};c.scriptSequenceID=c.scriptSequenceID.flatMap{sequences[$0]};c.sceneMembers=c.sceneMembers?.compactMap{mapping[$0]};return c}
        var candidate=project;candidate.clips+=copies;candidate.registerSceneCopies(mapping.mapValues{[$0]})
        do{_=try candidate.validated()}catch{self.error=error.localizedDescription;return}
        pause();checkpoint();project=candidate;selectedIDs=Set(copies.map(\.id));selectedID=copies.first?.id;scheduleDirtySpeech()
    }
}
