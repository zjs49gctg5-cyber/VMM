import Foundation
import SwiftUI
import AppKit

struct ControlResult {
    var status:Int
    var body:Data
    static func json(_ value:Any,status:Int=200)->ControlResult {
        ControlResult(status:status,body:(try? JSONSerialization.data(withJSONObject:value,options:[.sortedKeys])) ?? Data("{}".utf8))
    }
    static func error(_ message:String,_ status:Int=400)->ControlResult {json(["error":L(message)],status:status)}
}

@MainActor
final class EditorCommands {
    weak var store:EditorStore?
    var jobs:[String:[String:Any]]=[:]
    var lyricRecognizer:(URL,Clip,String,[String]) async throws->[TranscriptToken] = {url,clip,language,hints in try await LocalTranscription.recognize(source:url,clip:clip,language:language,hints:hints)}
    var lyricSeparatedRecognizer:(URL,Clip,String,String,Int,String,String) async throws->[LyricAlignmentMatch] = {url,clip,text,language,fps,python,models in try await LocalVocalSeparation.align(source:url,clip:clip,text:text,language:language,fps:fps,python:python,models:models,recognizer:{url,clip,language,hints in try await LocalTranscription.recognize(source:url,clip:clip,language:language,hints:hints)})}
    static var commands:[String] {["karaoke.align","karaoke.separate","karaoke.importParts","karaoke.import","clip.add","clip.update","clip.delete","clip.duplicate","clip.split","select","seek","play","pause","undo","redo","voice.connect","speech.generate","speech.generateBatch","speech.cancel","speech.retryFailed","rhythm.update","rhythm.repeat","rhythm.slice","rhythm.quantize","rhythm.fit","rhythm.pattern"]+workflowCommands}
    func read(_ name:String,jobID:String?=nil)->ControlResult {
        guard let store else{return .error("VMMに接続していません。",503)}
        if let result=readWorkflow(name:name,jobID:jobID,store:store){return result}
        if name == "state" {
            do {
                let project=try JSONSerialization.jsonObject(with:JSONEncoder().encode(store.project))
                return .json(["project":project,"revision":store.projectRevision,"dirty":store.dirty,"projectPath":(store.savedURL?.path as Any?) ?? NSNull(),"playhead":store.playhead,"selectedIDs":store.selection.map(\.uuidString),"playing":store.playing,"busy":store.busy,"selectedID":(store.selectedID?.uuidString as Any?) ?? NSNull(),"generatingScript":store.scriptGenerating,"generatingSpeech":store.generatingSpeech.map(\.uuidString),"activeSpeech":store.activeSpeech.map(\.uuidString),"speechFailures":Dictionary(uniqueKeysWithValues:store.speechFailures.map{($0.key.uuidString,$0.value)}),"speechBatchTotal":store.speechBatchTotal,"speechBatchCompleted":store.speechBatchCompleted,"projectIOProgress":(store.projectIOProgress as Any?) ?? NSNull(),"status":store.status,"error":(store.error as Any?) ?? NSNull()])
            } catch {return .error(error.localizedDescription,500)}
        }
        if name == "capabilities" {
            return .json(["version":1,"commands":["clip.add","clip.update","clip.delete","clip.duplicate","clip.split","select","seek","play","pause","undo","redo","voice.connect","speech.generate","speech.generateBatch","speech.cancel","speech.retryFailed","rhythm.update","rhythm.repeat","rhythm.slice","rhythm.quantize","rhythm.fit","rhythm.pattern"]+Self.workflowCommands,"clipKinds":ClipKind.allCases.map(\.rawValue)])
        }
        return .error("読み取り項目がありません。",404)
    }
    func execute(body:Data)->ControlResult {
        guard let store else{return .error("VMMに接続していません。",503)}
        let requestedCommand=((try? JSONSerialization.jsonObject(with:body)) as? [String:Any])?["command"] as? String
        guard !store.busy || ["export.cancel","animation.cancelGeneration","speech.cancel"].contains(requestedCommand ?? "") else {return .error("VMMは処理中です。",409)}
        do {
            guard let request=try JSONSerialization.jsonObject(with:body) as? [String:Any],let command=request["command"] as? String else {return .error("commandを指定してください。")}
            if let result=try workflow(command,request:request,store:store){return result}
            func clip()throws->Clip {
                guard let text=request["clipID"] as? String,let id=UUID(uuidString:text),let c=store.project.clips.first(where:{$0.id==id}) else {throw VMMError.message("有効なclipIDを指定してください。")}
                guard !store.project.tracks[c.track].locked else {throw VMMError.message("レイヤーがロックされています。")}
                return c
            }
            switch command {
            case "karaoke.align":
                guard let raw=request["clipID"] as? String,let id=UUID(uuidString:raw),let source=store.project.clips.first(where:{$0.id==id}),let text=request["text"] as? String,!text.isEmpty,text.utf8.count<=16384 else{return .error("有効なclipIDと歌詞を指定してください。")}
                let language=request["language"] as? String ?? "ja-JP"
                guard ["ja-JP","en-US"].contains(language) else{return .error("認識言語が不正です。")}
                let method=request["method"] as? String ?? "speech"
                guard ["speech","separated"].contains(method) else{return .error("同期方法が不正です。")}
                let python=UserDefaults.standard.string(forKey:LocalVocalSeparation.pythonKey) ?? "",models=UserDefaults.standard.string(forKey:LocalVocalSeparation.modelsKey) ?? ""
                let snapshot=store.project,directory=store.directory,asset=try TranscriptPlanner.validateSource(source,project:snapshot,maximumSeconds:LyricAlignment.maximumSeconds)
                let url=directory.appendingPathComponent("Media").appendingPathComponent(asset.file)
                guard FileManager.default.fileExists(atPath:url.path) else{return .error("音声素材が見つかりません。")}
                return enqueue {
                    let matches:[LyricAlignmentMatch]
                    if method=="separated" {matches=try await self.lyricSeparatedRecognizer(url,source,text,language,snapshot.fps,python,models)}
                    else {matches=try await LyricAlignment.recognize(text:text,source:url,clip:source,language:language,fps:snapshot.fps,using:self.lyricRecognizer)}
                    guard store.project==snapshot,store.directory==directory else{throw VMMError.message("解析中にプロジェクトが変更されました。")}
                    return ["matches":matches.map{["index":$0.index,"text":$0.text,"start":$0.start as Any? ?? NSNull(),"end":$0.end as Any? ?? NSNull(),"matched":$0.matched] as [String:Any]},"method":method,"sourceClipID":id.uuidString,"warning":"歌声の同期候補は誤る場合があります。時刻を確認して修正してください。"]
                }
            case "karaoke.separate":
                let source=try clip(),snapshot=store.project,directory=store.directory,asset=try TranscriptPlanner.validateSource(source,project:snapshot,maximumSeconds:LyricAlignment.maximumSeconds)
                let url=directory.appendingPathComponent("Media").appendingPathComponent(asset.file),python=UserDefaults.standard.string(forKey:LocalVocalSeparation.pythonKey) ?? "",models=UserDefaults.standard.string(forKey:LocalVocalSeparation.modelsKey) ?? ""
                guard FileManager.default.fileExists(atPath:url.path) else{return .error("音声素材が見つかりません。")}
                return enqueue {
                    let ids=try await LocalVocalSeparation.withVocals(source:url,clip:source,python:python,models:models) {vocals,_ in
                        guard store.project==snapshot,store.directory==directory else{throw VMMError.message("処理中にプロジェクトが変更されました。")}
                        return try await store.importURLs([vocals])
                    }
                    return ["assetIDs":ids.map(\.uuidString)]
                }
            case "karaoke.importParts":
                guard let items=request["parts"] as? [[String:Any]],items.allSatisfy({Set($0.keys).isSubset(of:["text","track","beforeColor","afterColor","topY","bottomY"])}) else{return .error("パートの指定が不正です。")}
                let parts=try JSONDecoder().decode([KaraokePartSpec].self,from:JSONSerialization.data(withJSONObject:items))
                let (project,clips)=try KaraokePartsPlanner.make(parts,project:store.project)
                store.pause();store.checkpoint();store.project=project;store.selectedIDs=Set(clips.map(\.id));store.selectedID=clips.first?.id
                return .json(["ok":true,"clipIDs":clips.map{$0.id.uuidString}])
            case "karaoke.import":
                guard let text=request["text"] as? String,let track=request["track"] as? Int,store.project.tracks.indices.contains(track),!store.project.tracks[track].locked else{return .error("歌詞またはレイヤーが不正です。")}
                let lines=try LyricLRC.parse(text,fps:store.project.fps)
                let trackID=store.project.tracks[track].id
                let (project,clips)=try store.lyricCandidate(lines:lines,trackID:trackID,fps:store.project.fps,motion:.none,karaoke:true,beforeColor:request["beforeColor"] as? String ?? "FFFFFF",afterColor:request["afterColor"] as? String ?? "FFDD33")
                store.pause();store.checkpoint();store.project=project;store.selectedIDs=Set(clips.map(\.id));store.selectedID=clips.first?.id
                return .json(["ok":true,"clipIDs":clips.map{$0.id.uuidString}])
            case "clip.add":
                guard let raw=request["kind"] as? String,let kind=ClipKind(rawValue:raw) else {return .error("有効なkindを指定してください。")}
                let rawTrack=request["track"] as? Int ?? store.selectedTrack
                guard store.project.tracks.indices.contains(rawTrack),!store.project.tracks[rawTrack].locked else {return .error("レイヤーが不正、またはロックされています。")}
                var c=Clip(kind:kind,name:kind.title,track:rawTrack,start:store.playhead,duration:kind == .transition ? 1:4)
                if kind == .transition {c.sceneTransition=SceneTransition()}
                if kind == .particles {c.particles=ParticleSettings()}
                if kind == .speech {store.setDefaultSpeechVoice(&c)}
                c=try patched(c,request["properties"])
                guard !store.project.tracks[c.track].locked else{return .error("移動先がロックされています。",409)}
                if kind == .speech {c.speechDirty=true}
                var project=store.project;project.clips.append(c);_=try project.validated()
                store.pause();store.checkpoint();store.project=project;store.selectedID=c.id;store.selectedIDs=[];store.scheduleDirtySpeech()
                return .json(["ok":true,"clipID":c.id.uuidString])
            case "clip.update":
                let old=try clip(),updated=try patched(old,request["properties"])
                guard !store.project.tracks[updated.track].locked else {return .error("移動先がロックされています。",409)}
                _=try LinkedMedia.updated(store.project,from:old,to:updated);store.edit(old.id){$0=updated}
            case "clip.delete":
                let c=try clip();guard store.project.clips.allSatisfy({$0.parentID != c.id}) else {return .error("子を持つ親は削除できません。",409)}
                store.selectedIDs=[];store.selectedID=c.id;store.deleteSelected()
            case "clip.duplicate":store.selectedID=try clip().id;store.duplicateSelected()
            case "clip.split":
                let c=try clip();guard store.playhead>c.start,store.playhead<c.end,store.project.clips.allSatisfy({$0.parentID != c.id}) else {return .error("現在位置で分割できません。",409)}
                store.selectedID=c.id;store.splitSelected()
            case "rhythm.quantize":
                guard let values=request["clipIDs"] as? [String],!values.isEmpty,values.allSatisfy({UUID(uuidString:$0) != nil}) else {return .error("clipIDsが不正です。")}
                try store.quantizeMAD(Set(values.compactMap(UUID.init(uuidString:))),strength:request["strength"] as? Double ?? 1)
            case "rhythm.fit":
                guard let values=request["clipIDs"] as? [String],!values.isEmpty,values.allSatisfy({UUID(uuidString:$0) != nil}),let beats=request["beats"] as? Double else {return .error("clipIDs・beatsを指定してください。")}
                try store.fitMAD(Set(values.compactMap(UUID.init(uuidString:))),beats:beats)
            case "rhythm.pattern":
                let c=try clip()
                guard let text=request["pattern"] as? String else {return .error("patternを指定してください。")}
                let ids=try store.patternMAD(c.id,pitches:MADArrangement.pitches(text),at:request["start"] as? Double ?? store.playhead,gate:request["gate"] as? Double ?? 0.9)
                return .json(["ok":true,"clipIDs":ids.map(\.uuidString)])
            case "rhythm.update":
                guard let properties=request["properties"] as? [String:Any],Set(properties.keys).isSubset(of:["enabled","bpm","division","offset","snap","visible"]) else {return .error("拍グリッドのpropertiesが不正です。")}
                var values=try JSONSerialization.jsonObject(with:JSONEncoder().encode(store.project.rhythm ?? RhythmSettings())) as! [String:Any]
                for (key,value) in properties {values[key]=value}
                let settings=try JSONDecoder().decode(RhythmSettings.self,from:JSONSerialization.data(withJSONObject:values));try settings.validate();store.editRhythm{$0=settings}
            case "rhythm.repeat","rhythm.slice":
                let c=try clip()
                guard store.project.rhythmEnabled else {return .error("プロジェクトの音MAD設定を有効にしてください。")}
                guard [.audio,.video,.speech].contains(c.kind),!c.speechDirty,store.project.clips.allSatisfy({$0.parentID != c.id}) else {return .error("音声生成済みで、子を持たない音声・動画を指定してください。")}
                store.error=nil
                if command == "rhythm.repeat" {
                    guard let count=request["count"] as? Int,(2...64).contains(count) else {return .error("countは2〜64を指定してください。")}
                    store.repeatAudio(c.id,count:count,onGrid:request["onGrid"] as? Bool ?? false)
                } else {store.sliceAudioOnGrid(c.id)}
                if let error=store.error {return .error(error)}
            case "select":store.selectedID=try clip().id;store.selectedIDs=[]
            case "seek":
                guard let time=request["time"] as? Double,time.isFinite,(0...86400).contains(time) else {return .error("有効なtime（秒）を指定してください。")};store.seek(time)
            case "play":if !store.playing {store.togglePlayback()}
            case "pause":store.pause()
            case "undo":guard store.canUndo else {return .error("Undo履歴がありません。",409)};store.undo()
            case "redo":guard store.canRedo else {return .error("Redo履歴がありません。",409)};store.redo()
            case "voice.connect":store.connectVoicevox()
            case "speech.generateBatch":store.generateDirtySpeech(force:request["force"] as? Bool == true)
            case "speech.cancel":store.cancelSpeech()
            case "speech.retryFailed":store.retryFailedSpeech()
            case "speech.generate":
                let c=try clip();guard c.kind == .speech else {return .error("セリフアイテムを指定してください。")};store.selectedID=c.id;store.generateSpeech()
            default:return .error("未対応のcommandです。")
            }
            return .json(["ok":true,"selectedID":(store.selectedID?.uuidString as Any?) ?? NSNull()])
        } catch {return .error(error.localizedDescription)}
    }
    func patched(_ clip:Clip,_ raw:Any?,project:Project?=nil)throws->Clip {
        guard let raw else {return clip}
        guard let patch=raw as? [String:Any] else {throw VMMError.message("propertiesはJSONオブジェクトで指定してください。")}
        var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(clip)) as! [String:Any]
        let allowed:Set<String>=["lyricRuby","lyricWipe","pan","audioDisabled","normalizationGain","measuredLUFS","reading","precompositionID","spatialAnimation","temporalMotion","audioReactive","tracking","anchorPoint","textAnimation","textRevealRate","characterPresetID","ducking","name","text","track","start","duration","sourceOffset","assetID","x","y","scale","opacity","rotation","flipX","flipY","color","fontSize","volume","speakerID","speakerName","speechConfiguration","characterSpeechEngine","speed","textStyle","shapeStyle","animation","animationOffset","effects","sceneTransition","audioFade","parentID","transform","masks","blendMode","particles","playbackRate","preservePitch","pitchSemitones","equalizer","adjustmentOwnLayer","adjustmentRegion","mouthAssetID","characterSpeakerID","psd"]
        guard Set(patch.keys).isSubset(of:allowed) else {throw VMMError.message("変更できないプロパティがあります。")}
        for (key,value) in patch {object[key]=value}
        var result=try JSONDecoder().decode(Clip.self,from:JSONSerialization.data(withJSONObject:object))
        if result.text != clip.text {result.textRuns=TextRunEditing.rebase(clip.textRuns,old:clip.text,new:result.text)}
        guard (project ?? store?.project)?.tracks.indices.contains(result.track) == true else {throw VMMError.message("レイヤー番号が不正です。")}
        return result
    }
}

