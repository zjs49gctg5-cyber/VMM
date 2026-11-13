import Foundation

@MainActor extension EditorCommands {
    func transaction(_ request:[String:Any],store:EditorStore)throws->ControlResult {
        if request["expectedRevision"] != nil && !(request["expectedRevision"] is Int) {throw VMMError.message("expectedRevisionは整数で指定してください。")}
        if let expected=request["expectedRevision"] as? Int,expected != store.projectRevision {return .error("プロジェクトが更新されています。最新のrevisionを取得してください。",409)}
        guard let operations=request["operations"] as? [[String:Any]],!operations.isEmpty,operations.count<=100 else{throw VMMError.message("operationsを1〜100件指定してください。")}
        var candidate=store.project,created:[String:String]=[:],added:[UUID]=[]
        func resolve(_ raw:Any?)throws->UUID {
            guard let text=raw as? String else{throw VMMError.message("clipIDを指定してください。")}
            let value=text.hasPrefix("$") ? created[String(text.dropFirst())]:text
            guard let value,let id=UUID(uuidString:value) else{throw VMMError.message("IDまたは作成済みの参照名が不正です。")};return id
        }
        func properties(_ raw:Any?)throws->Any? {
            guard var value=raw as? [String:Any] else{return raw}
            for key in ["parentID","assetID","mouthAssetID","characterPresetID"] {if let text=value[key] as? String,text.hasPrefix("$"){value[key]=try resolve(text).uuidString}}
            return value
        }
        for (number,operation) in operations.enumerated() {
            do {
                guard let command=operation["command"] as? String else{throw VMMError.message("commandを指定してください。")}
                switch command {
                case "clip.add":
                    guard let raw=operation["kind"] as? String,let kind=ClipKind(rawValue:raw) else{throw VMMError.message("kindが不正です。")}
                    let track=operation["track"] as? Int ?? store.selectedTrack
                    guard candidate.tracks.indices.contains(track),!candidate.tracks[track].locked else{throw VMMError.message("配置先がないかロックされています。")}
                    var clip=Clip(kind:kind,name:kind.title,track:track,start:store.playhead,duration:kind == .transition ? 1:4)
                    if kind == .transition {clip.sceneTransition=SceneTransition()};if kind == .particles {clip.particles=ParticleSettings()}
                    if kind == .speech {store.setDefaultSpeechVoice(&clip);clip.speechDirty=true}
                    clip=try patched(clip,properties(operation["properties"]),project:candidate)
                    guard !candidate.tracks[clip.track].locked else{throw VMMError.message("配置先がロックされています。")}
                    candidate.clips.append(clip);added.append(clip.id)
                    if let ref=operation["ref"] as? String {
                        guard !ref.isEmpty,ref.count<=64,!ref.hasPrefix("$"),created[ref]==nil else{throw VMMError.message("refが空・重複・長すぎます。")};created[ref]=clip.id.uuidString
                    }
                case "clip.update":
                    let id=try resolve(operation["clipID"])
                    guard let before=candidate.clips.first(where:{$0.id==id}),!candidate.tracks[before.track].locked else{throw VMMError.message("対象がないかロックされています。")}
                    var after=try patched(before,properties(operation["properties"]),project:candidate)
                    if after.kind == .speech && (before.text != after.text || before.reading != after.reading || before.speakerID != after.speakerID || before.speechConfiguration != after.speechConfiguration || before.speed != after.speed) {after.speechDirty=true}
                    candidate=try LinkedMedia.updated(candidate,from:before,to:after,validate:false)
                case "clip.delete":
                    let id=try resolve(operation["clipID"])
                    guard let clip=candidate.clips.first(where:{$0.id==id}) else{throw VMMError.message("対象がありません。")}
                    let roots=LinkedMedia.expanded([id],in:candidate),children=roots.reduce(Set<UUID>()){$0.union(candidate.descendants(of:$1))}
                    guard children.isEmpty || operation["withChildren"] as? Bool == true || clip.sceneMembers != nil else{throw VMMError.message("子を削除するにはwithChildren:trueを指定してください。")}
                    let ids=roots.union(children)
                    guard candidate.clips.filter({ids.contains($0.id)}).allSatisfy({!candidate.tracks[$0.track].locked}) else{throw VMMError.message("対象にロックされたアイテムがあります。")}
                    candidate.removeClips(ids)
                case "track.add":
                    guard candidate.tracks.count<32 else{throw VMMError.message("レイヤーは32個までです。")}
                    candidate.tracks.append(Track(name:operation["name"] as? String ?? "レイヤー \(candidate.tracks.count+1)"))
                case "track.update":
                    guard let index=operation["track"] as? Int,candidate.tracks.indices.contains(index),let patch=operation["properties"] as? [String:Any],Set(patch.keys).isSubset(of:["name","visible","muted","locked","effects","opacity","blendMode"]) else{throw VMMError.message("レイヤー設定が不正です。")}
                    var value=try JSONSerialization.jsonObject(with:JSONEncoder().encode(candidate.tracks[index])) as! [String:Any]
                    for (key,v) in patch {value[key]=v};candidate.tracks[index]=try JSONDecoder().decode(Track.self,from:JSONSerialization.data(withJSONObject:value))
                case "track.move":
                    guard let from=operation["from"] as? Int,let to=operation["to"] as? Int,candidate.tracks.indices.contains(from),candidate.tracks.indices.contains(to) else{throw VMMError.message("レイヤー番号が不正です。")}
                    let old=candidate.tracks.map(\.id),track=candidate.tracks.remove(at:from);candidate.tracks.insert(track,at:to)
                    for i in candidate.clips.indices {candidate.clips[i].track=candidate.tracks.firstIndex{$0.id==old[candidate.clips[i].track]}!}
                case "project.update":
                    guard let patch=operation["properties"] as? [String:Any],Set(patch.keys).isSubset(of:["name","width","height","fps","background","masterVolume","masterDynamics","markers","timelineRange"]) else{throw VMMError.message("プロジェクト設定が不正です。")}
                    var value=try JSONSerialization.jsonObject(with:JSONEncoder().encode(candidate)) as! [String:Any]
                    for (key,v) in patch {value[key]=v};candidate=try JSONDecoder().decode(Project.self,from:JSONSerialization.data(withJSONObject:value))
                default:throw VMMError.message("トランザクションでは\(command)を使用できません。ファイル・外部処理は個別に実行してください。")
                }
            } catch {throw VMMError.message("操作\(number+1)：\(error.localizedDescription)")}
        }
        _=try candidate.validated()
        let dryRun=request["dryRun"] as? Bool ?? false
        if !dryRun {
            store.pause();store.checkpoint();store.cancelSpeech();store.project=candidate;store.reconcileEditingSelection();store.scheduleDirtySpeech()
        }
        var response:[String:Any]=["ok":true,"dryRun":dryRun,"created":created,"clipIDs":added.map(\.uuidString),"revision":store.projectRevision]
        if dryRun {response["project"]=try JSONSerialization.jsonObject(with:JSONEncoder().encode(candidate))}
        return .json(response)
    }
}
