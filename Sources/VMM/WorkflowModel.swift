import Foundation
import AppKit

struct CharacterPreset:Codable,Equatable,Identifiable {
    var id=UUID();var name:String
    var portraitAssetID:UUID?;var portraitMouthID:UUID?;var portraitPSD:PSDState?
    var portraitX:Double?;var portraitY:Double?;var portraitScale:Double?
    var speechConfiguration:SpeechConfiguration?
    var speakerName:String?
    var speakerID:Int=0;var color="FFFFFF";var fontSize:Double=64
    var x:Double=0.5;var y:Double=0.85;var style=TextStyle()
    func apply(to clip:inout Clip) {clip.characterPresetID=id;clip.speakerID=speakerID;clip.speechConfiguration=speechConfiguration;clip.speakerName=speakerName ?? "";clip.color=color;clip.fontSize=fontSize;clip.x=x;clip.y=y;clip.textStyle=style}
}
struct PronunciationEntry:Codable,Equatable,Identifiable {
    var id=UUID();var word:String;var reading:String
}
enum ToolbarDisplayMode:String,Codable,CaseIterable {
    case iconsAndLabels,iconsOnly,labelsOnly
    var title:String {switch self {case .iconsAndLabels:return "アイコンとラベル";case .iconsOnly:return "アイコンのみ";case .labelsOnly:return "ラベルのみ"}}
}
enum UITheme:String,Codable,CaseIterable {
    case system,light,dark
    var title:String {switch self {case .system:return "macOSに合わせる";case .light:return "ライト";case .dark:return "ダーク"}}
    var appearance:NSAppearance? {switch self {case .system:return nil;case .light:return NSAppearance(named:.aqua);case .dark:return NSAppearance(named:.darkAqua)}}
}
struct UserSettings:Codable,Equatable {
    var uiTheme:UITheme?
    var disabledExtensions:[String]?
    var detachedTimeline:Bool?;var detachedInspector:Bool?
    var detachedPreview:Bool?;var detachedLibrary:Bool?;var detachedAnimation:Bool?
    var toolbarDisplayMode:ToolbarDisplayMode?
    var speechConfiguration:SpeechConfiguration?
    var uiLanguage:UILanguage?
    var adaptivePreview:Bool?
    var previewMinimumLongEdge:Double?
    var uiScale:Double=1
    var uiFontSize:Double?;var uiIconSize:Double?
    var toolbarLabels:Bool?;var toolbarIconScale:Double?
    var inspectorLeft=false;var showLibrary=true;var showInspector=true
    var safeArea=false;var thumbnails=true;var waveforms=true;var showTools=true
    var autosaveSeconds:Double=60;var recoveryCount=10;var cacheMB=256
    var shortcuts="VMM標準";var customShortcuts:[String:String]=[:]
    var exportCodec="H.264";var exportQuality:Double=0.75
    var exportContainer="MP4";var rangeStart:Double=0;var rangeEnd:Double=0
    var exportTemplate:String?
    var exportWidth:Int?;var exportHeight:Int?;var exportFPS:Int?
    var exportVideoMbps:Double?;var exportAudioKbps:Int?
    var autosavePath:String?;var libraryPath:String?
    var libraryLayout:LibraryLayout?;var librarySort:LibrarySort?
    var libraryDescending:Bool?;var libraryThumbnails:Bool?;var libraryFiltersVisible:Bool?
    var libraryHoverPreview:Bool?;var libraryHoverSeconds:Double?
}
struct SharedCatalog:Codable,Equatable {
    var characters:[CharacterPreset]=[]
    var pronunciations:[PronunciationEntry]=[]
}
enum VMMPaths {
    static var support:URL {FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/VMM")}
    static var recovery:URL {support.appendingPathComponent("Recovery")}
    static var library:URL {support.appendingPathComponent("SharedLibrary")}
    static func read<T:Decodable>(_ type:T.Type,_ file:String,fallback:T)->T {(try? JSONDecoder().decode(type,from:Data(contentsOf:support.appendingPathComponent(file)))) ?? fallback}
    static func write<T:Encodable>(_ value:T,_ file:String)throws {try FileManager.default.createDirectory(at:support,withIntermediateDirectories:true);try JSONEncoder().encode(value).write(to:support.appendingPathComponent(file),options:.atomic)}
}
struct ScriptLine:Identifiable,Equatable {
    var id=UUID();var speaker:String;var text:String
}
enum ScriptParser {
    static func parse(_ source:String)->[ScriptLine] {
        var result:[ScriptLine]=[]
        for line in source.replacingOccurrences(of:"\r\n",with:"\n").components(separatedBy:"\n") {
            let text=line.trimmingCharacters(in:.whitespaces)
            if text.isEmpty || text.hasPrefix("#") {continue}
            if let colon=text.firstIndex(where:{$0 == ":" || $0 == "："}) {
                let speaker=String(text[..<colon]).trimmingCharacters(in:.whitespaces),value=String(text[text.index(after:colon)...]).trimmingCharacters(in:.whitespaces)
                if !speaker.isEmpty,!value.isEmpty {result.append(ScriptLine(speaker:speaker,text:value));continue}
            }
            result.append(ScriptLine(speaker:"",text:text))
        }
        return result
    }
}
extension Project {
    func spokenText(for clip:Clip,entries:[PronunciationEntry]=[])->String {
        let value=(clip.reading?.isEmpty == false ? clip.reading!:clip.text)
        let dictionary=(pronunciations ?? entries).filter{!$0.word.isEmpty}.sorted{$0.word.count>$1.word.count}
        var remaining=value[...],result=""
        while !remaining.isEmpty {
            if let entry=dictionary.first(where:{remaining.hasPrefix($0.word)}) {result+=entry.reading;remaining=remaining.dropFirst(entry.word.count)}
            else {result.append(remaining.removeFirst())}
        }
        return result
    }
}

extension UserSettings {
    func validated()throws->UserSettings {
        guard (disabledExtensions?.count ?? 0)<=256,(disabledExtensions ?? []).allSatisfy(DataExtensionPackage.validID) else{throw VMMError.message("無効な拡張IDの設定です。") }
        guard (libraryHoverSeconds ?? 3).isFinite,(1...10).contains(libraryHoverSeconds ?? 3) else{throw VMMError.message("ホバー再生の長さは1〜10秒で指定してください。") }
        _ = try speechConfiguration?.validated()
        try validateExportOverrides()
        guard (toolbarIconScale ?? 1.75).isFinite,(0.5...2).contains(toolbarIconScale ?? 1.75) else{throw VMMError.message("上部アイコン倍率は50〜200%で指定してください。") }
        guard (previewMinimumLongEdge ?? 720).isFinite,(480...1920).contains(previewMinimumLongEdge ?? 720) else {throw VMMError.message("プレビューの最低解像度が不正です。")}
        guard (uiFontSize ?? 12).isFinite,(12...24).contains(uiFontSize ?? 12),(uiIconSize ?? 12).isFinite,(12...28).contains(uiIconSize ?? 12),uiScale.isFinite,(0.8...1.5).contains(uiScale),autosaveSeconds.isFinite,(autosaveSeconds==0 || (10...3600).contains(autosaveSeconds)),(1...100).contains(recoveryCount),(16...2048).contains(cacheMB),exportQuality.isFinite,(0.1...1).contains(exportQuality),rangeStart.isFinite,(0...86400).contains(rangeStart),rangeEnd.isFinite,(0...86400).contains(rangeEnd),["MP4","MOV"].contains(exportContainer),["H.264","HEVC","ProRes 422"].contains(exportCodec),["VMM標準","Final Cut風","Premiere風"].contains(shortcuts) else {throw VMMError.message("設定値が範囲外です。")}
        return self
    }
}
