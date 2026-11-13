import Foundation

@MainActor extension EditorCommands {
    static let workflowCommands=["animation.analyzeAudio","animation.track","export.interchange","export.audio","selection.crossfade","media.placeRange","clip.slip","clip.roll","extension.install","extension.enable","extension.remove","animation.applyDefinition","extension.applyPreset","animation.cancelGeneration","track.delete","media.delete","export.template","selection.copy","selection.paste","selection.rippleDelete","clip.separateAudio","media.tags","media.cleanupUnused","caption.import","caption.export","script.import","dictionary.set","character.capture","character.apply","selection.set","selection.update","selection.duplicate","selection.delete","selection.arrange","settings.update","project.new","project.update","project.save","project.open","project.autosave","media.import","media.relink","media.proxy","library.saveTemplate","library.addAsset","library.importAsset","track.add","track.update","track.move","export.start","export.cancel","export.preflight","selection.link","selection.unlink","character.projectAdd","character.projectUpdate","character.portrait","character.applyAll","character.captionTemplate","character.applyCaptions","character.selectCaptions","character.projectDelete","export.queueAdd","export.queueStart","export.queuePause","export.queueCancel","export.queueRetry","export.queueRemove","export.queueMove","precomposition.create","precomposition.update","precomposition.place","precomposition.makeUnique","precomposition.delete","scene.save","scene.insert","scene.dissolve","project.transaction"]
    func readWorkflow(name:String,jobID:String?,store:EditorStore)->ControlResult? {
        if name == "job",let jobID {return jobs[jobID].map{.json($0)} ?? .error("ジョブがありません。",404)}
        if name == "catalog" {
            let value=(try? JSONSerialization.jsonObject(with:JSONEncoder().encode(store.catalog))) ?? [:]
            return .json(["catalog":value,"templates":store.templates().map(\.path),"assets":store.sharedAssets().map{$0.0.path},"recoveries":store.recoveryFiles().map(\.path)])
        }
        if name == "extensions" {return .json(["packages":(try? JSONSerialization.jsonObject(with:JSONEncoder().encode(store.dataExtensions))) ?? [],"disabled":store.settings.disabledExtensions ?? []])}
        if name == "exportQueue" {return .json(["paused":store.exportQueue.paused,"jobs":(try? JSONSerialization.jsonObject(with:JSONEncoder().encode(store.exportQueue.jobs))) ?? []])}
        if name == "settings" {return .json((try? JSONSerialization.jsonObject(with:JSONEncoder().encode(store.settings))) ?? [:])}
        return nil
    }
    func workflow(_ command:String,request:[String:Any],store:EditorStore)throws->ControlResult? {
        func path(_ key:String="path")throws->URL {
            guard let value=request[key] as? String,value.hasPrefix("/") else {throw VMMError.message("\(key)を絶対パスで指定してください。")}
            return URL(fileURLWithPath:value)
        }
        func uuid(_ key:String)throws->UUID {guard let text=request[key] as? String,let id=UUID(uuidString:text) else {throw VMMError.message("有効な\(key)を指定してください。")};return id}
        func object<T:Decodable>(_ key:String,_ type:T.Type)throws->T {guard let raw=request[key] else {throw VMMError.message("\(key)を指定してください。")};return try JSONDecoder().decode(type,from:JSONSerialization.data(withJSONObject:raw,options:[.fragmentsAllowed]))}
        func overwrite(_ url:URL,allowCurrentProject:Bool=false)throws {
            // A newly created .vmm URL initially looks like a file; once it exists,
            // Foundation identifies it as a directory. Compare paths, not that flag.
            let current=allowCurrentProject && store.savedURL?.standardizedFileURL.path == url.standardizedFileURL.path
            if FileManager.default.fileExists(atPath:url.path),request["overwrite"] as? Bool != true,!current {throw VMMError.message("既存ファイルを置換するにはoverwrite:trueが必要です。")}
        }
        switch command {
        case "project.transaction":return try transaction(request,store:store)
        case "extension.install":
            guard let raw=request["package"] as? [String:Any] else{throw VMMError.message("packageを指定してください。")}
            let package=try DataExtensionPackage.decode(JSONSerialization.data(withJSONObject:raw,options:[.fragmentsAllowed]))
            try store.installDataExtension(package,replace:request["replace"] as? Bool == true)
        case "extension.enable":
            guard let id=request["packageID"] as? String,let enabled=request["enabled"] as? Bool else{throw VMMError.message("packageIDとenabledを指定してください。")}
            try store.setDataExtensionEnabled(id,enabled)
        case "extension.remove":
            guard let id=request["packageID"] as? String,store.dataExtensions.contains(where:{$0.id==id}) else{throw VMMError.message("拡張がありません。")};try store.removeDataExtension(id)
        case "animation.applyDefinition":
            guard let id=request["packageID"] as? String,let definitionID=request["definitionID"] as? String,let definition=store.enabledDataExtensions.first(where:{$0.id==id})?.animations.first(where:{$0.id==definitionID}) else{throw VMMError.message("有効なアニメーション定義がありません。")}
            let values=request["values"] == nil ? [:]:try object("values",[String:Double].self)
            let clipID=try uuid("clipID")
            if definition.script != nil {
                let seed:UInt32=request["seed"] == nil ? definition.scriptSeed ?? 1:try object("seed",UInt32.self)
                return enqueue{let count=try await store.runScriptAnimation(definition,packageID:id,values:values,seed:seed,clipID:clipID,apply:true);return ["keyCount":count]}
            }
            try store.applyDefinedAnimation(definition,packageID:id,values:values,clipID:clipID)
        case "animation.cancelGeneration":store.cancelScriptAnimation()
        case "extension.applyPreset":
            guard let id=request["packageID"] as? String,let name=request["name"] as? String,let preset=store.enabledDataExtensions.first(where:{$0.id==id})?.presets.first(where:{$0.name==name}) else{throw VMMError.message("有効なプリセットがありません。")}
            let clipID=try uuid("clipID");guard let clip=store.project.clips.first(where:{$0.id==clipID}),!store.project.tracks[clip.track].locked else{throw VMMError.message("アイテムが存在しないかロックされています。")}
            store.error=nil;store.applyPreset(preset,clipID:clipID);if let error=store.error{throw VMMError.message(error)}
        case "script.import":guard let text=request["text"] as? String else {throw VMMError.message("脚本textを指定してください。")};try store.importScript(text,at:request["start"] as? Double,track:request["track"] as? Int)
        case "dictionary.set":
            try store.ensurePreferencesWritable("catalog.json")
            let entries=try object("entries",[PronunciationEntry].self);guard entries.count<=2000,entries.allSatisfy({!$0.word.isEmpty && !$0.reading.isEmpty}) else {throw VMMError.message("辞書が不正です。")};store.setDictionary(entries)
        case "character.capture":try store.ensurePreferencesWritable("catalog.json");guard let name=request["name"] as? String,store.selected.map({[.text,.speech].contains($0.kind)}) == true else {throw VMMError.message("字幕を選択してキャラnameを指定してください。")};store.captureCharacter(name:name)
        case "character.projectAdd":let value=try object("character",CharacterPreset.self);let id=try store.addProjectCharacter(name:value.name,preset:value);return .json(["ok":true,"characterID":id.uuidString])
        case "character.projectUpdate":try store.updateProjectCharacter(try object("character",CharacterPreset.self))
        case "character.portrait":let id=try store.placePortrait(try uuid("characterID"));return .json(["ok":true,"clipID":id.uuidString])
        case "character.captionTemplate":
            guard let raw=request["template"] as? String,let template=CharacterCaptionTemplate(rawValue:raw) else{throw VMMError.message("字幕テンプレートがありません。")}
            try store.setCharacterCaptionTemplate(template,characterID:try uuid("characterID"))
        case "character.applyCaptions":try store.applyCharacterCaptions(try uuid("characterID"))
        case "character.selectCaptions":store.selectCharacterCaptions(try uuid("characterID"))
        case "character.applyAll":try store.applyProjectCharacter(try uuid("characterID"),toAll:true)
        case "character.projectDelete":try store.removeProjectCharacter(try uuid("characterID"))
        case "character.apply":let id=try uuid("characterID");guard store.availableCharacters.contains(where:{$0.id==id}) else {throw VMMError.message("キャラがありません。")};store.applyCharacter(id)
        case "selection.link":try store.linkSelection()
        case "selection.unlink":try store.unlinkSelection()
        case "selection.set":
            let values=try object("clipIDs",[UUID].self),ids=Set(values);guard ids.isSubset(of:Set(store.project.clips.map(\.id))) else {throw VMMError.message("選択に存在しないアイテムがあります。")};store.selectedIDs=ids;store.selectedID=values.first
        case "selection.update":
            let ids=store.selection;guard !ids.isEmpty else {throw VMMError.message("アイテムを選択してください。")}
            var candidate=store.project
            for id in store.project.clips.filter({ids.contains($0.id)}).map(\.id) {
                guard let old=candidate.clips.first(where:{$0.id==id}),!candidate.tracks[old.track].locked else {throw VMMError.message("選択にロックされたアイテムがあります。")}
                candidate=try LinkedMedia.updated(candidate,from:old,to:patched(old,request["properties"]))
            }
            for i in candidate.clips.indices where candidate.clips[i].kind == .speech {
                let before=store.project.clips[i],after=candidate.clips[i]
                if before.text != after.text || before.reading != after.reading || before.speakerID != after.speakerID || before.speed != after.speed || before.speechConfiguration != after.speechConfiguration {candidate.clips[i].speechDirty=true}
            }
            _=try candidate.validated();store.pause();store.checkpoint();store.project=candidate;store.scheduleDirtySpeech()
        case "selection.copy":try store.copyClips()
        case "selection.paste":try store.pasteClips()
        case "selection.rippleDelete":try store.rippleDelete()
        case "clip.separateAudio":let id=try uuid("clipID");return enqueue{try await store.separateAudio(id);return ["ok":true]}
        case "media.tags":let id=try uuid("assetID");guard let tags=request["tags"] as? [String] else{throw VMMError.message("tagsは文字列配列で指定してください。")};try store.setMediaTags(id,text:tags.joined(separator:","))
        case "media.cleanupUnused":store.removeUnusedMedia()
        case "caption.import":
            guard let text=request["text"] as? String,let raw=request["format"] as? String,let format=CaptionFormat(rawValue:raw) else{throw VMMError.message("字幕textとformat（srt/vtt）を指定してください。")}
            try store.importCaptions(text,format:format,at:request["start"] as? Double ?? 0)
        case "caption.export":
            guard let raw=request["format"] as? String,let format=CaptionFormat(rawValue:raw) else{throw VMMError.message("formatはsrt/vttで指定してください。")}
            return .json(["text":CaptionCodec.encode(store.project.captionCues,format:format)])
        case "selection.duplicate":store.duplicateSelection()
        case "selection.delete":store.error=nil;store.deleteSelection();if let error=store.error {throw VMMError.message(error)}
        case "selection.arrange":guard let mode=request["mode"] as? String,["左揃え","上揃え","中央","開始揃え","順番"].contains(mode) else {throw VMMError.message("整列modeを指定してください。")};try store.arrangeValidated(mode)
        case "settings.update":
            try store.ensurePreferencesWritable("settings.json")
            var value=try JSONSerialization.jsonObject(with:JSONEncoder().encode(store.settings)) as! [String:Any]
            guard let patch=request["properties"] as? [String:Any],Set(patch.keys).isSubset(of:Set(value.keys).union(["disabledExtensions","detachedTimeline","detachedInspector","detachedPreview","detachedLibrary","detachedAnimation","previewMinimumLongEdge","adaptivePreview","speechConfiguration","uiLanguage","uiTheme","uiFontSize","uiIconSize","autosavePath","libraryPath","libraryLayout","librarySort","libraryDescending","libraryThumbnails","libraryFiltersVisible","libraryHoverPreview","libraryHoverSeconds","toolbarLabels","toolbarIconScale","toolbarDisplayMode","exportTemplate","exportWidth","exportHeight","exportFPS","exportVideoMbps","exportAudioKbps"])) else {throw VMMError.message("settings propertiesが不正です。")}
            if patch["detachedPreview"] != nil && !store.finishPendingPreviewText() {throw VMMError.message("編集中のテキストを確定できません。ロックや処理状態を確認してください。")}
            if patch["toolbarLabels"] != nil,patch["toolbarDisplayMode"] == nil {value["toolbarDisplayMode"]=NSNull()}
            for (key,v) in patch {value[key]=v}
            let previous=store.speechConfiguration
            store.settings=try JSONDecoder().decode(UserSettings.self,from:JSONSerialization.data(withJSONObject:value)).validated()
            if previous != store.speechConfiguration {store.invalidateSpeechConnection()}
            store.persistSettings()
        case "project.new":
            guard store.finishPendingPreviewText() else {throw VMMError.message("編集中のテキストを確定できません。ロックや処理状態を確認してください。")}
            guard !store.dirty || request["discardChanges"] as? Bool == true else {throw VMMError.message("変更が未保存です。")}
            let folder=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-session-\(UUID())")
            try FileManager.default.createDirectory(at:folder.appendingPathComponent("Media"),withIntermediateDirectories:true)
            var project=Project();project.name=request["name"] as? String ?? "名称未設定";store.reset(to:project,directory:folder,savedURL:nil)
        case "project.update":
            var value=try JSONSerialization.jsonObject(with:JSONEncoder().encode(store.project)) as! [String:Any]
            guard let patch=request["properties"] as? [String:Any],Set(patch.keys).isSubset(of:["name","width","height","fps","background","masterVolume","masterDynamics","markers","timelineRange"]) else {throw VMMError.message("project propertiesが不正です。")}
            for (key,v) in patch {value[key]=v};let candidate=try JSONDecoder().decode(Project.self,from:JSONSerialization.data(withJSONObject:value)).validated();store.pause();store.checkpoint();store.project=candidate
        case "project.save":
            guard store.finishPendingPreviewText() else {throw VMMError.message("編集中のテキストを確定できません。ロックや処理状態を確認してください。")}
            let url=try path();guard url.pathExtension=="vmm" else {throw VMMError.message("保存先は.vmmにしてください。")};try overwrite(url,allowCurrentProject:true)
            if request["async"] as? Bool == true {store.busy=true;return enqueue {store.busy=false;guard await store.saveProject(to:url) else {throw VMMError.message(store.error ?? "保存できませんでした。")};return ["path":url.path]}}
            try ProjectPackage.write(store.project,media:store.directory.appendingPathComponent("Media"),to:url);store.savedURL=url;store.dirty=false
        case "project.open":
            guard store.finishPendingPreviewText() else {throw VMMError.message("編集中のテキストを確定できません。ロックや処理状態を確認してください。")}
            let url=try path();guard !store.dirty || request["discardChanges"] as? Bool == true else {throw VMMError.message("変更が未保存です。保存するかdiscardChanges:trueを指定してください。")}
            if request["async"] as? Bool == true {store.busy=true;return enqueue {store.busy=false;guard await store.loadProjectAsync(url) else {throw VMMError.message(store.error ?? "読み込めませんでした。")};return ["path":url.path]}}
            store.error=nil;store.loadProject(url);if let error=store.error {throw VMMError.message(error)}
        case "project.autosave":let url=try store.autosave(to:store.recoveryFolder);return .json(["ok":true,"path":url.path])
        case "media.import":
            let paths=try object("paths",[String].self);guard !paths.isEmpty,paths.count<=100,paths.allSatisfy({$0.hasPrefix("/")}) else {throw VMMError.message("pathsを絶対パスの配列で指定してください。")}
            return enqueue {let ids=try await store.importURLs(paths.map{URL(fileURLWithPath:$0)});return ["assetIDs":ids.map(\.uuidString)]}
        case "animation.analyzeAudio":
            let target=try uuid("clipID"),source=try uuid("sourceClipID");return enqueue{try await store.analyzeReactiveAudio(clipID:target,sourceClipID:source);return ["clipID":target.uuidString]}
        case "animation.track":
            let target=try uuid("clipID"),source=try uuid("sourceClipID")
            guard let r=request["region"] as? [String:Any],Set(r.keys)==Set(["x","y","width","height"]),let x=r["x"] as? Double,let y=r["y"] as? Double,let w=r["width"] as? Double,let h=r["height"] as? Double,let from=request["sourceIn"] as? Double,let duration=request["duration"] as? Double else{throw VMMError.message("region・sourceIn・durationを指定してください。")}
            let region=CGRect(x:x,y:y,width:w,height:h),rate=request["sampleRate"] as? Double ?? 15,scale=request["followScale"] as? Bool ?? false
            return enqueue{let result=try await store.trackMotion(clipID:target,sourceClipID:source,region:region,from:from,duration:duration,sampleRate:rate,followScale:scale);return ["clipID":target.uuidString,"sampleCount":result.samples.count,"lostAt":result.lostAt.map{$0 as Any} ?? NSNull()]}
        case "media.relink":let id=try uuid("assetID"),url=try path();return enqueue {try await store.relink(id,url:url);return [:]}
        case "media.proxy":let id=try uuid("assetID");return enqueue {try await store.makeProxy(id);return [:]}
        case "library.saveTemplate":guard let name=request["name"] as? String else {throw VMMError.message("nameを指定してください。")};try store.saveTemplate(name:name)
        case "library.addAsset":try store.addSharedAsset(try uuid("assetID"))
        case "library.importAsset":let url=try path(),asset=try store.readSharedAsset(url);try store.importShared(url,asset:asset)
        case "track.add":guard store.project.tracks.count<32 else {throw VMMError.message("レイヤーは32個までです。")};store.pause();store.checkpoint();store.project.tracks.append(Track(name:request["name"] as? String ?? "レイヤー"))
        case "track.delete":
            guard let index=request["track"] as? Int else{throw VMMError.message("レイヤー番号を指定してください。")}
            try store.deleteTrack(index,deleteItems:request["deleteItems"] as? Bool == true)
        case "media.delete":try store.deleteMedia(try uuid("assetID"),deleteItems:request["deleteItems"] as? Bool == true)
        case "track.move":guard let from=request["from"] as? Int,let to=request["to"] as? Int,store.project.tracks.indices.contains(from),store.project.tracks.indices.contains(to) else {throw VMMError.message("from/toが不正です。")};store.moveTrack(from:from,to:to)
        case "track.update":
            guard let index=request["track"] as? Int,store.project.tracks.indices.contains(index),let patch=request["properties"] as? [String:Any],Set(patch.keys).isSubset(of:["name","visible","muted","locked","effects","opacity","blendMode"]) else {throw VMMError.message("レイヤー設定が不正です。")}
            var value=try JSONSerialization.jsonObject(with:JSONEncoder().encode(store.project.tracks[index])) as! [String:Any];for (k,v) in patch {value[k]=v}
            var candidate=store.project;candidate.tracks[index]=try JSONDecoder().decode(Track.self,from:JSONSerialization.data(withJSONObject:value));_=try candidate.validated();store.pause();store.checkpoint();store.project=candidate
        case "precomposition.create":guard let name=request["name"] as? String else{throw VMMError.message("名前を指定してください。")};let id=try store.createPrecomposition(name:name);return .json(["clipID":id.uuidString,"compositionID":store.project.clips.first{$0.id==id}!.precompositionID!.uuidString])
        case "precomposition.update":guard let patch=request["properties"] as? [String:Any] else{throw VMMError.message("propertiesを指定してください。")};try store.updatePrecomposition(try uuid("compositionID"),properties:patch)
        case "precomposition.place":
            let oldTime=store.playhead,oldTrack=store.selectedTrack
            defer{store.selectedTrack=oldTrack;store.playhead=oldTime}
            if let time=request["start"] as? Double {guard time.isFinite,time>=0 else{throw VMMError.message("配置時刻が不正です。")};store.playhead=time}
            if let track=request["track"] as? Int {guard store.project.tracks.indices.contains(track) else{throw VMMError.message("レイヤー番号が不正です。")};store.selectedTrack=track}
            try store.placePrecomposition(try uuid("compositionID"))
        case "precomposition.delete":try store.deletePrecomposition(try uuid("compositionID"))
        case "precomposition.makeUnique":try store.makePrecompositionUnique(try uuid("clipID"))
        case "scene.save":guard let name=request["name"] as? String else{throw VMMError.message("シーン名を指定してください。")};let destination=request["path"] == nil ? nil:try path();store.busy=true;return enqueue{store.busy=false;let url=try await store.saveScene(name:name,to:destination);return ["path":url.path]}
        case "scene.insert":let url=try path();store.busy=true;return enqueue{store.busy=false;let id=try await store.insertScene(url,at:request["start"] as? Double);return ["clipID":id.uuidString]}
        case "scene.dissolve":try store.dissolveScene(try uuid("clipID"))
        case "export.queueAdd":let url=try path();try overwrite(url);store.busy=true;return enqueue {store.busy=false;let id=try await store.queueExport(to:url,overwrite:request["overwrite"] as? Bool ?? false);return ["exportID":id.uuidString]}
        case "export.queueStart":store.exportQueue.resume()
        case "export.queuePause":store.exportQueue.pause()
        case "export.queueCancel":store.exportQueue.cancelCurrent()
        case "export.queueRetry":try store.exportQueue.retry(try uuid("exportID"))
        case "export.queueRemove":try store.exportQueue.remove(try uuid("exportID"))
        case "export.queueMove":try store.exportQueue.move(try uuid("exportID"),offset:request["offset"] as? Int ?? 0)
        case "export.preflight":
            let snapshot=store.project,source=store.directory,options=store.settings,generating=store.generatingSpeech,destination=request["path"] == nil ? nil:try path()
            return enqueue {let report=await Task.detached {ExportPreflight.inspect(project:snapshot,directory:source,options:options,destination:destination,generating:generating)}.value;return ["report":try JSONSerialization.jsonObject(with:JSONEncoder().encode(report))]}
        case "export.start","export.audio","export.interchange":
            let url=try path();try overwrite(url);guard store.exportQueue.runningID == nil else{throw VMMError.message("キューの出力が完了してから開始してください。")};guard store.generatingSpeech.isEmpty else {throw VMMError.message("音声生成が完了していません。")}
            try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
            store.error=nil;if command=="export.interchange"{store.beginInterchangeExport(to:url)}else if command=="export.audio"{store.beginAudioExport(to:url,overwrite:request["overwrite"] as? Bool == true)}else{store.beginExport(to:url,overwrite:request["overwrite"] as? Bool == true)}
            return enqueue {
                while store.busy {try await Task.sleep(nanoseconds:100_000_000)}
                if let error=store.error {throw VMMError.message(error)}
                guard FileManager.default.fileExists(atPath:url.path),store.status.hasPrefix("書き出し完了") else {throw VMMError.message("書き出しは完了しませんでした。")}
                return ["path":url.path]
            }
        case "selection.crossfade":try store.crossfadeSelection()
        case "media.placeRange":
            guard let a=request["sourceIn"] as? Double,let b=request["sourceOut"] as? Double,let mode=SourcePlacement(rawValue:request["mode"] as? String ?? "append") else{throw VMMError.message("素材範囲を指定してください。")}
            try store.placeSource(try uuid("assetID"),sourceIn:a,sourceOut:b,start:request["start"] as? Double,track:request["track"] as? Int,mode:mode)
            return .json(["clipID":store.selectedID!.uuidString])
        case "clip.slip","clip.roll":
            guard let delta=request["delta"] as? Double else{throw VMMError.message("移動量を秒で指定してください。")}
            let id=try uuid("clipID");if command=="clip.slip" {try store.slipSource(id,delta:delta)}else{try store.rollSource(id,delta:delta)}
        case "export.template":
            try store.ensurePreferencesWritable("settings.json")
            guard let id=request["template"] as? String else{throw VMMError.message("書き出しテンプレートを指定してください。")}
            if id == "project" {store.settings.clearExportTemplate()}
            else {guard let template=ExportTemplate(rawValue:id) else{throw VMMError.message("書き出しテンプレートが不正です。")};template.apply(to:&store.settings)}
            store.persistSettings()
        case "export.cancel":store.cancelExport()
        default:return nil
        }
        return .json(["ok":true])
    }
    func enqueue(_ operation:@escaping @MainActor()async throws->[String:Any])->ControlResult {
        let id=UUID().uuidString
        if jobs.count>=100,let key=jobs.first(where:{$0.value["state"] as? String != "running"})?.key {jobs.removeValue(forKey:key)}
        jobs[id]=["jobID":id,"state":"running"]
        Task {do {let result=try await operation();jobs[id]=["jobID":id,"state":"completed","result":result]}catch{jobs[id]=["jobID":id,"state":"failed","error":error.localizedDescription]}}
        return .json(["ok":true,"jobID":id],status:202)
    }
}
