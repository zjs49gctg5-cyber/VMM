import SwiftUI
import AppKit

extension CharacterPreset {
    func validate(in project:Project)throws {
        guard !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,name.count<=200 else{throw VMMError.message("キャラ名を200文字以内で指定してください。")}
        var test=project;test.characters=nil;test.precompositions=nil;test.clips=[]
        var caption=Clip(kind:.speech,name:name,track:0,start:0,duration:1);apply(to:&caption);test.clips=[caption]
        if let assetID=portraitAssetID {
            guard project.assets.contains(where:{$0.id==assetID && $0.kind == .image}) else{throw VMMError.message("キャラの立ち絵素材がありません。")}
            var portrait=Clip(kind:.image,name:name,track:0,start:0,duration:1);applyPortrait(to:&portrait);test.clips.append(portrait)
        } else if portraitPSD != nil || portraitMouthID != nil {throw VMMError.message("立ち絵の素材を先に指定してください。")}
        _=try test.validated()
    }
    func applyPortrait(to clip:inout Clip) {
        clip.characterPresetID=id;clip.assetID=portraitAssetID;clip.mouthAssetID=portraitMouthID;clip.psd=portraitPSD
        clip.characterSpeakerID=speakerID;clip.characterSpeechEngine=speechConfiguration?.engine ?? .voicevox
        clip.x=portraitX ?? 0.5;clip.y=portraitY ?? 0.5;clip.scale=portraitScale ?? 1
    }
}
@MainActor extension EditorStore {
    var availableCharacters:[CharacterPreset] {(project.characters ?? [])+catalog.characters.filter{preset in !(project.characters ?? []).contains{$0.id==preset.id}}}
    @discardableResult func addProjectCharacter(name:String,preset:CharacterPreset?=nil)throws->UUID {
        guard !busy else{throw VMMError.message("処理中です。")}
        var value=preset ?? CharacterPreset(name:name,speechConfiguration:speechConfiguration)
        value.id=UUID();value.name=name
        try value.validate(in:project)
        var candidate=project;candidate.characters=(candidate.characters ?? [])+[value];_=try candidate.validated()
        pause();checkpoint();project=candidate;return value.id
    }
    func updateProjectCharacter(_ value:CharacterPreset)throws {
        guard !busy,let index=project.characters?.firstIndex(where:{$0.id==value.id}) else{throw VMMError.message("キャラがないか処理中です。")}
        try value.validate(in:project);pause();checkpoint();project.characters?[index]=value
    }
    func capturePortrait(_ id:UUID)throws {
        guard let clip=selected,clip.kind == .image,var value=project.characters?.first(where:{$0.id==id}) else{throw VMMError.message("立ち絵アイテムを選択してください。")}
        value.portraitAssetID=clip.assetID;value.portraitMouthID=clip.mouthAssetID;value.portraitPSD=clip.psd
        value.portraitX=clip.x;value.portraitY=clip.y;value.portraitScale=clip.scale
        try updateProjectCharacter(value)
    }
    func applyProjectCharacter(_ id:UUID,toAll:Bool=false,ids:Set<UUID>?=nil)throws {
        guard !busy,let preset=project.characters?.first(where:{$0.id==id}) else{throw VMMError.message("キャラがないか処理中です。")}
        let targets=toAll ? Set(project.clips.filter{$0.characterPresetID==id}.map(\.id)):(ids ?? selection)
        var candidate=project
        for i in candidate.clips.indices where targets.contains(candidate.clips[i].id) {
            guard !candidate.tracks[candidate.clips[i].track].locked else{throw VMMError.message("キャラの対象アイテムがロックされています。")}
            let old=candidate.clips[i]
            if [.text,.speech].contains(old.kind) {
                preset.apply(to:&candidate.clips[i])
                if old.kind == .speech && (old.speechConfiguration != preset.speechConfiguration || old.speakerID != preset.speakerID) {candidate.clips[i].speechDirty=true}
            } else if old.kind == .image,preset.portraitAssetID != nil {preset.applyPortrait(to:&candidate.clips[i])}
        }
        _=try candidate.validated();pause();checkpoint();project=candidate;scheduleDirtySpeech()
    }
    @discardableResult func placePortrait(_ id:UUID)throws->UUID {
        guard !busy,let preset=project.characters?.first(where:{$0.id==id}),preset.portraitAssetID != nil,!project.tracks[selectedTrack].locked else{throw VMMError.message("立ち絵を指定し、配置先のロックを解除してください。")}
        var clip=Clip(kind:.image,name:preset.name,track:selectedTrack,start:playhead,duration:selected?.duration ?? 4);preset.applyPortrait(to:&clip)
        var candidate=project;candidate.clips.append(clip);_=try candidate.validated();pause();checkpoint();project=candidate;selectedIDs=[];selectedID=clip.id;return clip.id
    }
    func removeProjectCharacter(_ id:UUID)throws {
        guard !busy else{throw VMMError.message("処理中です。")}
        pause();checkpoint();project.characters?.removeAll{$0.id==id}
        for i in project.clips.indices where project.clips[i].characterPresetID==id {project.clips[i].characterPresetID=nil}
    }
}
struct CharacterWorkspace:View {
    @ObservedObject var store:EditorStore
    var body:some View {TabView {ProjectCharactersView(store:store).tabItem{Text(L("プロジェクトのキャラ"))};SharedCharacterWorkspace(store:store).tabItem{Text(L("共有プリセット"))}}.disabled(store.busy)}
}
struct ProjectCharactersView:View {
    @ObservedObject var store:EditorStore
    @State private var selected:UUID?
    @State private var name=""
    var body:some View {VStack(alignment:.leading,spacing:12){
        HStack {TextField(L("キャラ名"),text:$name);Button(L("キャラを追加")){store.reportEditing{selected=try store.addProjectCharacter(name:name);name=""}}.disabled(name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
            Menu(L("共有プリセットから追加")){ForEach(store.catalog.characters){preset in Button(preset.name){store.reportEditing{selected=try store.addProjectCharacter(name:preset.name,preset:preset)}}}}
        }
        HSplitView {
            List(store.project.characters ?? [],selection:$selected){preset in HStack {Circle().fill(Color(nsColor:NSColor(hex:preset.color))).frame(width:12,height:12);Text(preset.name);Spacer();Text(String(CharacterCaptionQuery.clips(in:store.project,characterID:preset.id).count)).foregroundColor(.secondary)}.tag(preset.id)}.frame(minWidth:150,idealWidth:200)
            if let id=selected,store.project.characters?.contains(where:{$0.id==id}) == true {ProjectCharacterEditor(store:store,id:id)}
            else {Text(L("キャラを選択してください。字幕・音声・立ち絵をまとめて設定できます。")).frame(maxWidth:.infinity,maxHeight:.infinity)}
        }
    }.padding(18)}
}
struct ProjectCharacterEditor:View {
    @ObservedObject var store:EditorStore;let id:UUID
    var value:CharacterPreset {store.project.characters?.first{$0.id==id} ?? CharacterPreset(name:"")}
    func binding<T>(_ key:WritableKeyPath<CharacterPreset,T>)->Binding<T>{Binding(get:{value[keyPath:key]},set:{v in var next=value;next[keyPath:key]=v;store.reportEditing{try store.updateProjectCharacter(next)}})}
    func style<T>(_ key:WritableKeyPath<TextStyle,T>)->Binding<T>{Binding(get:{value.style[keyPath:key]},set:{v in var next=value;next.style[keyPath:key]=v;store.reportEditing{try store.updateProjectCharacter(next)}})}
    var body:some View {ScrollView{VStack(alignment:.leading,spacing:14){
        TextField(L("名前"),text:binding(\.name)).textFieldStyle(.roundedBorder)
        PanelDisclosure(L("字幕")) {VStack(alignment:.leading,spacing:10){
            Menu(L("字幕テンプレート")){ForEach(CharacterCaptionTemplate.allCases){template in Button(L(template.title)){store.reportEditing{try store.setCharacterCaptionTemplate(template,characterID:id)}}}}
            Text(L("テンプレートはキャラ定義に保存します。既存字幕には反映ボタンで適用します。")).foregroundColor(.secondary)
            Text(L("字幕プレビュー")).font(.caption).foregroundColor(.secondary)
            CharacterCaptionPreview(preset:value,directory:store.directory).frame(height:150)
            TextField(L("文字色（HEX）"),text:binding(\.color)).textFieldStyle(.roundedBorder)
            VMMMenuPicker(L("フォント"),selection:Binding(get:{value.style.fontName ?? "HiraginoSans-W6"},set:{v in var next=value;next.style.fontName=v;store.reportEditing{try store.updateProjectCharacter(next)}})){VMMOptions(NSFontManager.shared.availableFonts.sorted(),id:\.self){VMMChoice(text:$0,value:$0)}}
            NumberInput(title:"文字サイズ",value:binding(\.fontSize),range:8...400)
            NumberInput(title:"字幕 X",value:binding(\.x),range:-1...2,percent:true);NumberInput(title:"字幕 Y",value:binding(\.y),range:-1...2,percent:true)
            Toggle(L("縁取り"),isOn:style(\.outline))
            if value.style.outline {TextField(L("縁の色（HEX）"),text:style(\.outlineColor));NumberInput(title:"太さ（文字サイズ比）",value:style(\.outlineWidth),range:0...20,unit:"%")}
            Toggle(L("影"),isOn:style(\.shadow))
            if value.style.shadow {TextField(L("影の色（HEX）"),text:style(\.shadowColor));NumberInput(title:"影の濃さ",value:style(\.shadowOpacity),range:0...1,percent:true);NumberInput(title:"影 X",value:style(\.shadowX),range:-100...100,unit:"px");NumberInput(title:"影 Y",value:style(\.shadowY),range:-100...100,unit:"px")}
            VMMMenuPicker(L("文字揃え"),selection:Binding(get:{value.style.alignment ?? .center},set:{style(\.alignment).wrappedValue=$0})){VMMOptions(TextAlignment.allCases,id:\.self){VMMChoice(text:L($0.title),value:$0)}}
            NumberInput(title:"字幕の最大幅",value:Binding(get:{value.style.captionWidth ?? 0.9},set:{style(\.captionWidth).wrappedValue=$0}),range:0.1...1,percent:true)
            Button(L("選択字幕の装飾を取り込む")){store.reportEditing{try store.captureCharacterCaption(id)}}.disabled(store.selected.map{![.text,.speech].contains($0.kind)} ?? true)
            Button(L("このキャラの字幕だけに反映")){store.reportEditing{try store.applyCharacterCaptions(id)}}
            Button(L("このキャラの字幕を選択")){store.selectCharacterCaptions(id)}
            Text(L("字幕だけの反映では、音声・立ち絵・キーフレームを保持します。")).foregroundColor(.secondary)
        }}
        PanelDisclosure(L("音声エンジン")) {VStack(alignment:.leading){
            Text(value.speechConfiguration?.engine.title ?? "VOICEVOX")
            Button(L("接続中のエンジン設定を使う")){var next=value;next.speechConfiguration=store.speechConfiguration;store.reportEditing{try store.updateProjectCharacter(next)}}
            Menu(L("話者")){ForEach(store.voices){voice in Button(voice.name){var next=value;next.speakerID=voice.id;next.speakerName=voice.name;next.speechConfiguration=voice.configuration ?? store.speechConfiguration;store.reportEditing{try store.updateProjectCharacter(next)}}}}
            Text(value.speakerName ?? String(value.speakerID)).foregroundColor(.secondary)
            Button(L("選択セリフの音声設定を取り込む")){if let clip=store.selected,clip.kind == .speech {var next=value;next.speechConfiguration=clip.speechConfiguration;next.speakerID=clip.speakerID;next.speakerName=clip.speakerName;store.reportEditing{try store.updateProjectCharacter(next)}}}
        }}
        PanelDisclosure(L("立ち絵・表情")) {VStack(alignment:.leading){
            VMMMenuPicker(L("立ち絵"),selection:Binding(get:{value.portraitAssetID},set:{assetID in var next=value;next.portraitAssetID=assetID;next.portraitMouthID=nil;next.portraitPSD=store.project.assets.first{$0.id==assetID}?.psd.map{PSDState.initial($0)};store.reportEditing{try store.updateProjectCharacter(next)}})){VMMChoice(text:L("なし"),value:Optional<UUID>.none);VMMOptions(store.project.assets.filter{$0.kind == .image},id:\.id){VMMChoice(text:$0.name,value:Optional($0.id))}}
            Button(L("選択立ち絵の表情・口パク・配置を取り込む")){store.reportEditing{try store.capturePortrait(id)}}.disabled(store.selected?.kind != .image)
            Button(L("立ち絵を配置")){store.reportEditing{_=try store.placePortrait(id)}}.disabled(value.portraitAssetID==nil)
        }}
        HStack {Button(L("選択に適用")){store.reportEditing{try store.applyProjectCharacter(id)}};Button(L("このキャラの全アイテムへ反映")){store.reportEditing{try store.applyProjectCharacter(id,toAll:true)}}}
        Button(L("キャラ定義を削除")){store.reportEditing{try store.removeProjectCharacter(id)}}
        Text(L("変更は適用ボタンで既存アイテムへ反映します。立ち絵と字幕はプロジェクトに保存されます。")).foregroundColor(.secondary)
    }.padding(18)}}
}
