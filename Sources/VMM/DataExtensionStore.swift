import AppKit
import UniformTypeIdentifiers

@MainActor extension EditorStore {
    func loadDataExtensions() {
        // Bound the persistent catalogue before decoding; a damaged file never runs code.
        let url=preferencesDirectory.appendingPathComponent("extensions.json")
        guard let size=try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize,size<=16_777_216,let data=try? Data(contentsOf:url),let raw=try? JSONSerialization.jsonObject(with:data) as? [[String:Any]],raw.count<=32 else{return}
        dataExtensions=raw.compactMap{try? DataExtensionPackage.decode(JSONSerialization.data(withJSONObject:$0))}
        var ids=Set<String>();dataExtensions=dataExtensions.filter{ids.insert($0.id).inserted}
    }
    var enabledDataExtensions:[DataExtensionPackage] {dataExtensions.filter{!(settings.disabledExtensions ?? []).contains($0.id)}}
    func installDataExtension(_ package:DataExtensionPackage,replace:Bool=false)throws {
        _=try package.validated();guard !busy else{throw VMMError.message("処理中です。")}
        var list=dataExtensions
        if let i=list.firstIndex(where:{$0.id==package.id}) {guard replace else{throw VMMError.message("同じIDの拡張が導入済みです。")};list[i]=package}
        else {guard list.count<32 else{throw VMMError.message("拡張は32個まで導入できます。")};list.append(package)}
        guard try JSONEncoder().encode(package).count<=1_048_576 else{throw VMMError.message("拡張JSONは1MB以内にしてください。")}
        guard try JSONEncoder().encode(list).count<=16_777_216 else{throw VMMError.message("拡張ライブラリは16MB以内にしてください。")}
        try writePreferences(list,file:"extensions.json");dataExtensions=list
    }
    func setDataExtensionEnabled(_ id:String,_ enabled:Bool)throws {
        guard dataExtensions.contains(where:{$0.id==id}),!busy else{throw VMMError.message("拡張が存在しないか処理中です。")}
        var candidate=settings;var ids=Set((candidate.disabledExtensions ?? []).filter{id in dataExtensions.contains{$0.id==id}})
        if enabled{ids.remove(id)}else{ids.insert(id)};candidate.disabledExtensions=ids.sorted()
        try writePreferences(candidate,file:"settings.json");settings=candidate
    }
    func removeDataExtension(_ id:String)throws {
        guard !busy else{throw VMMError.message("処理中です。")}
        let list=dataExtensions.filter{$0.id != id};try writePreferences(list,file:"extensions.json");dataExtensions=list
    }
    func importDataExtension() {
        let panel=NSOpenPanel();panel.allowedContentTypes=[.json];panel.allowsMultipleSelection=false
        guard panel.runModal() == .OK,let url=panel.url else{return}
        do {
            let size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
            guard size<=1_048_576 else{throw VMMError.message("拡張JSONは1MB以内にしてください。")}
            let package=try DataExtensionPackage.decode(Data(contentsOf:url))
            let existing=dataExtensions.first{$0.id==package.id}
            let alert=NSAlert();alert.messageText=package.name
            alert.informativeText=(package.animations.contains{$0.script != nil} ? L("JavaScriptを含みます。生成時だけ別プロセスで実行します。")+"\n":"")+"\(package.author) · \(package.revision)\n\(L("アニメーション")): \(package.animations.count) / \(L("プリセット")): \(package.presets.count)"+(existing.map{"\n\(L("既存の拡張を更新します。")) \($0.revision) → \(package.revision)"} ?? "")
            alert.addButton(withTitle:L(existing == nil ? "導入":"更新"));alert.addButton(withTitle:L("キャンセル"))
            if alert.runModal() == .alertFirstButtonReturn{try installDataExtension(package,replace:existing != nil)}
        }catch{self.error=error.localizedDescription}
    }
    func exportDataExtension(_ package:DataExtensionPackage) {
        let panel=NSSavePanel();panel.allowedContentTypes=[.json];panel.nameFieldStringValue=package.id+".vmmext.json"
        guard panel.runModal() == .OK,let url=panel.url else{return}
        do {let e=JSONEncoder();e.outputFormatting=[.prettyPrinted,.sortedKeys];try e.encode(package).write(to:url,options:.atomic)}catch{self.error=error.localizedDescription}
    }
    func applyDefinedAnimation(_ definition:AnimationDefinition,packageID:String,values:[String:Double],clipID:UUID)throws {
        guard !busy,let clip=project.clips.first(where:{$0.id==clipID}),project.tracks.indices.contains(clip.track),!project.tracks[clip.track].locked else{throw VMMError.message("アイテムがありません。")}
        let keys=try definition.bake(clip:clip,fps:project.fps,values:values),values=try definition.resolved(values)
        try mutateMotion(clipID){c in
            var animation=c.animation ?? ClipAnimation()
            for track in keys {animation.tracks.removeAll{$0.property==track.property};animation.tracks.append(track)}
            c.animation=animation;c.customAnimation=CustomAnimationInstance(packageID:packageID,definition:definition,values:values)
        }
        status="カスタムアニメーションを適用しました。"
    }
}
