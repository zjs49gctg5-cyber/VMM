import SwiftUI

/// Built-in subtitle looks contain no voice or portrait settings.
enum CharacterCaptionTemplate:String,CaseIterable,Identifiable {
    case white,green,blue,pink,yellow,orange
    var id:String {rawValue}
    var title:String {switch self {case .white:return "標準・白";case .green:return "緑";case .blue:return "水色";case .pink:return "ピンク";case .yellow:return "黄色";case .orange:return "オレンジ"}}
    var color:String {switch self {case .white:return "FFFFFF";case .green:return "8BF5A5";case .blue:return "8EDBFF";case .pink:return "FFA8D8";case .yellow:return "FFEA80";case .orange:return "FFC18A"}}
    func apply(to value:inout CharacterPreset) {
        value.color=color;value.fontSize=64;value.x=0.5;value.y=0.85
        var style=TextStyle();style.fontName="HiraginoSans-W6";style.alignment = .center
        style.captionWidth=0.9;style.outline=true;style.outlineWidth=4
        style.shadow=true;style.shadowOpacity=0.55;style.shadowY=3
        value.style=style
    }
}
extension CharacterPreset {
    func applyCaption(to clip:inout Clip) {
        clip.color=color;clip.fontSize=fontSize;clip.x=x;clip.y=y;clip.textStyle=style
    }
}
enum CharacterCaptionQuery {
    static func clips(in project:Project,characterID:UUID?=nil,unassigned:Bool=false)->[Clip] {
        project.clips.filter{[.text,.speech].contains($0.kind) && (unassigned ? $0.characterPresetID==nil:characterID==nil || $0.characterPresetID==characterID)}.sorted{a,b in a.start==b.start ? a.id.uuidString<b.id.uuidString:a.start<b.start}
    }
}
@MainActor extension EditorStore {
    func setCharacterCaptionTemplate(_ template:CharacterCaptionTemplate,characterID:UUID)throws {
        guard var value=project.characters?.first(where:{$0.id==characterID}) else{throw VMMError.message("キャラがありません。")}
        template.apply(to:&value);try updateProjectCharacter(value)
    }
    func captureCharacterCaption(_ id:UUID)throws {
        guard let clip=selected,[.text,.speech].contains(clip.kind),var value=project.characters?.first(where:{$0.id==id}) else{throw VMMError.message("字幕アイテムを選択してください。")}
        value.color=clip.color;value.fontSize=clip.fontSize;value.x=clip.x;value.y=clip.y;value.style=clip.textStyle ?? TextStyle()
        try updateProjectCharacter(value)
    }
    func applyCharacterCaptions(_ id:UUID,ids:Set<UUID>?=nil)throws {
        guard !busy,let preset=availableCharacters.first(where:{$0.id==id}) else{throw VMMError.message("キャラがないか処理中です。")}
        let targets=ids ?? Set(CharacterCaptionQuery.clips(in:project,characterID:id).map(\.id))
        var candidate=project,changed=false
        for i in candidate.clips.indices where targets.contains(candidate.clips[i].id) && [.text,.speech].contains(candidate.clips[i].kind) {
            guard !candidate.tracks[candidate.clips[i].track].locked else{throw VMMError.message("キャラの対象アイテムがロックされています。")}
            preset.applyCaption(to:&candidate.clips[i]);changed=true
        }
        guard changed else{return}
        _=try candidate.validated();pause();checkpoint();project=candidate
    }
    func selectCharacterCaptions(_ id:UUID) {
        guard !busy else{return}
        let clips=CharacterCaptionQuery.clips(in:project,characterID:id)
        selectedIDs=Set(clips.map(\.id));selectedID=clips.first?.id
    }
}

struct CharacterCaptionPreview:View {
    let preset:CharacterPreset;let directory:URL
    private var image:NSImage? {
        var project=Project();project.width=1920;project.height=1080
        var clip=Clip(kind:.text,name:preset.name,track:0,start:0,duration:1)
        clip.text=preset.name+"："+L("こんにちは！");preset.applyCaption(to:&clip);project.clips=[clip]
        let size=CGSize(width:480,height:270)
        guard let context=RasterTools.bitmap(size) else{return nil}
        FrameRenderer().draw(project:project,directory:directory,time:0,context:context,size:size)
        return context.makeImage().map{NSImage(cgImage:$0,size:size)}
    }
    var body:some View {Group {if let image {Image(nsImage:image).resizable().scaledToFit()} else{Color.black}}.frame(maxWidth:.infinity).background(Color.black).cornerRadius(6).accessibilityLabel(L("字幕プレビュー"))}
}
