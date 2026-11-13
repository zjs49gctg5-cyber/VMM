import AppKit

enum LibraryUsageFilter:String,CaseIterable {case all,used,unused
    var title:String {switch self{case .all:return "使用状況すべて";case .used:return "使用中";case .unused:return "未使用"}}
}
extension Project {
    var usedAssetIDs:Set<UUID> {Set((characters ?? []).flatMap{[$0.portraitAssetID,$0.portraitMouthID].compactMap{$0}}).union(Set((clips+(precompositions ?? []).flatMap(\.clips)).flatMap{c in ([c.assetID,c.mouthAssetID,c.audioReactive?.assetID,c.tracking?.assetID]+(c.masks ?? []).map(\.assetID)).compactMap{$0}}))}
    func usageCount(_ id:UUID)->Int {(clips+(precompositions ?? []).flatMap(\.clips)).filter{c in c.tracking?.assetID==id || c.audioReactive?.assetID==id || c.assetID==id || c.mouthAssetID==id || (c.masks ?? []).contains{$0.assetID==id}}.count}
}
@MainActor extension EditorStore {
    var unusedLibraryAssets:[MediaAsset] {let used=project.usedAssetIDs;return libraryAssets.filter{!used.contains($0.id)}}
    func setMediaTags(_ id:UUID,text:String)throws {
        guard !busy,let i=project.assets.firstIndex(where:{$0.id==id}) else{return}
        let tags=Array(Set(text.components(separatedBy:CharacterSet(charactersIn:",、\n")).map{$0.trimmingCharacters(in:.whitespacesAndNewlines)}.filter{!$0.isEmpty})).sorted()
        guard tags.count<=32,tags.allSatisfy({$0.count<=80}) else{throw VMMError.message("タグは32個以内、各80文字以内にしてください。")}
        checkpoint();project.assets[i].tags=tags.isEmpty ? nil:tags
    }
    func editMediaTags(_ asset:MediaAsset) {
        let alert=NSAlert();alert.messageText=L("素材タグ");alert.informativeText=L("カンマで区切って入力してください。")
        let field=NSTextField(string:(asset.tags ?? []).joined(separator:", "));field.frame=NSRect(x:0,y:0,width:320,height:25);alert.accessoryView=field
        alert.addButton(withTitle:L("変更"));alert.addButton(withTitle:L("キャンセル"))
        if alert.runModal() == .alertFirstButtonReturn{reportEditing{try setMediaTags(asset.id,text:field.stringValue)}}
    }
    func removeUnusedMedia() {
        guard !busy else{return}
        let ids=Set(unusedLibraryAssets.map(\.id));guard !ids.isEmpty else{return}
        pause();checkpoint();project.assets.removeAll{ids.contains($0.id)}
        status="\(ids.count)\(L("件の未使用素材登録を解除しました。元ファイルは保持されています。"))"
    }
}
