import AppKit

enum ShortcutAction:String,CaseIterable {case copy,paste,rippleDelete,marker,setIn,setOut,selectAll,select,blade,text,shape,play,delete,split,undo,redo,save,duplicate,previous,next
    var title:String {switch self {case .copy:return "コピー";case .paste:return "ペースト";case .rippleDelete:return "リップル削除";case .marker:return "マーカーを追加";case .setIn:return "インを設定";case .setOut:return "アウトを設定";case .selectAll:return "すべて選択";case .select:return "選択ツール";case .blade:return "分割ツール";case .text:return "文字ツール";case .shape:return "図形ツール";case .play:return "再生・停止";case .delete:return "選択を削除";case .split:return "再生位置で分割";case .undo:return "元に戻す";case .redo:return "やり直す";case .save:return "保存";case .duplicate:return "複製";case .previous:return "1フレーム戻る";case .next:return "1フレーム進む"}}
}
enum ShortcutMap {
    static func key(_ action:ShortcutAction,settings:UserSettings,ignoreCustom:Bool=false)->String {
        if !ignoreCustom,let key=settings.customShortcuts[action.rawValue],!key.isEmpty{return key}
        let standard:[ShortcutAction:String]=[.copy:"cmd+c",.paste:"cmd+v",.rippleDelete:"shift+delete",.marker:"m",.setIn:"i",.setOut:"o",.selectAll:"cmd+a",.select:"v",.blade:"b",.text:"t",.shape:"r",.play:"space",.delete:"delete",.split:"cmd+b",.undo:"cmd+z",.redo:"cmd+shift+z",.save:"cmd+s",.duplicate:"cmd+d",.previous:"left",.next:"right"]
        if settings.shortcuts=="Premiere風" {if action == .blade{return "c"};if action == .split{return "cmd+k"};if action == .shape{return ""}}
        if settings.shortcuts=="Final Cut風",action == .select{return "a"}
        return standard[action] ?? ""
    }
    /// Match the ordering produced by normalized(_:) so modifier order in user input is harmless.
    /// Empty means “use the preset”; nil means the input cannot be dispatched.
    static func canonical(_ input:String)->String? {
        let value=input.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
        if value.isEmpty {return ""}
        let parts=value.split(separator:"+",omittingEmptySubsequences:false).map{String($0).trimmingCharacters(in:.whitespaces)}
        guard !parts.contains(where:{$0.isEmpty}) else{return nil}
        let modifiers=["cmd","ctrl","alt","shift"]
        var seen:Set<String>=[],key:String?
        for part in parts {
            if modifiers.contains(part) {guard seen.insert(part).inserted else{return nil}}
            else {guard key == nil else{return nil};key=part}
        }
        guard let key else{return nil}
        let specials:Set<String>=["space","delete","left","right","up","down","escape"]
        let simple = key.count == 1 && key.unicodeScalars.allSatisfy{(33...126).contains(Int($0.value)) && $0.value != 43}
        guard specials.contains(key) || simple else{return nil}
        return (modifiers.filter{seen.contains($0)}+[key]).joined(separator:"+")
    }
    static func conflicts(for action:ShortcutAction,key:String,settings:UserSettings)->[ShortcutAction] {
        guard !key.isEmpty else{return []}
        return ShortcutAction.allCases.filter{other in
            guard other != action else{return false}
            let existing=Self.key(other,settings:settings)
            return !existing.isEmpty && (canonical(existing) ?? existing) == key
        }
    }
    static func normalized(_ event:NSEvent)->String {
        var result:[String]=[],flags=event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command){result.append("cmd")};if flags.contains(.control){result.append("ctrl")};if flags.contains(.option){result.append("alt")};if flags.contains(.shift){result.append("shift")}
        let special:[UInt16:String]=[49:"space",51:"delete",117:"delete",123:"left",124:"right",125:"down",126:"up",53:"escape"]
        result.append(special[event.keyCode] ?? event.charactersIgnoringModifiers?.lowercased() ?? "")
        return result.joined(separator:"+")
    }
}
@MainActor extension EditorStore {
    func performShortcut(_ action:ShortcutAction) {
        switch action {case .copy:reportEditing{try copyClips()};case .paste:reportEditing{try pasteClips()};case .rippleDelete:reportEditing{try rippleDelete()};case .marker:addMarker();case .setIn:setRange(inPoint:true);case .setOut:setRange(inPoint:false);case .selectAll:selectedIDs=Set(project.clips.map(\.id));selectedID=project.clips.first?.id;case .select:tool = .select;case .blade:tool = .blade;case .text:tool = .text;case .shape:tool = .shape;case .play:togglePlayback();case .delete:deleteSelection();case .split:splitSelected();case .undo:undo();case .redo:redo();case .save:requestSave();case .duplicate:duplicateSelection();case .previous:seek(playhead-1/Double(project.fps));case .next:seek(playhead+1/Double(project.fps))}
    }
}
