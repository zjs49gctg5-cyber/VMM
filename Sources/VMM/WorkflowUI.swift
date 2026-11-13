import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum WorkspacePage:String,CaseIterable {
    case mad="音MAD",media="素材管理",script="台本",characters="キャラ",dictionary="発音辞書",library="共有ライブラリ",settings="設定",workspaceSettings="ワークスペース設定",recovery="復元履歴",export="書き出し"
    static let productionPages:[WorkspacePage]=[.media,.script,.characters,.dictionary,.library]
}
@MainActor final class WorkspaceWindowController {
    enum Kind:CaseIterable {case mad,production,settings,workspaceSettings,export
        static func destination(for page:WorkspacePage)->Kind {switch page {case .mad:return .mad;case .settings,.recovery:return .settings;case .workspaceSettings:return .workspaceSettings;case .export:return .export;default:return .production}}
        var title:String {switch self {case .mad:return L("音MADモード");case .production:return L("制作ワークスペース");case .settings:return L("設定");case .workspaceSettings:return L("ワークスペース設定");case .export:return L("書き出し設定")}}
    }
    weak var store:EditorStore?
    private var windows:[Kind:NSWindow]=[:]
    private let selection=WorkspaceSelection()
    init(store:EditorStore){self.store=store}
    func contains(_ window:NSWindow)->Bool {windows.values.contains{$0 === window}}
    func closeAll(){for window in windows.values{window.close();window.contentView=nil};windows.removeAll()}
    func refreshTitles(){for (kind,window) in windows{window.title="VMM — \(kind.title)"}}
    func show(_ page:WorkspacePage) {
        guard let store else{return}
        let kind=Kind.destination(for:page)
        if page == .recovery {store.settingsTab = .recovery}
        if kind == .production {selection.page=page}
        refreshTitles()
        if let window=windows[kind]{window.makeKeyAndOrderFront(nil);return}
        let production=kind == .production || kind == .mad
        let panel=NSWindow(contentRect:NSRect(x:0,y:0,width:production ? 1040:780,height:production ? 730:760),styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
        panel.title="VMM — \(kind.title)";panel.minSize=NSSize(width:production ? 820:780,height:580);panel.isReleasedWhenClosed=false
        panel.tabbingMode = .disallowed
        panel.contentView=NSHostingView(rootView:IndependentWorkspaceView(store:store,selection:selection,kind:kind))
        panel.center();panel.makeKeyAndOrderFront(nil);windows[kind]=panel
    }
}
struct IndependentWorkspaceView:View {
    @ObservedObject var store:EditorStore
    @ObservedObject var selection:WorkspaceSelection
    let kind:WorkspaceWindowController.Kind
    var body:some View {
        Group {
            switch kind {
            case .mad:MADWorkspace(store:store)
            case .production:WorkspaceView(store:store,selection:selection)
            case .settings:SettingsWorkspace(store:store)
            case .workspaceSettings:WorkspaceSettingsView(store:store)
            case .export:ExportWorkspace(store:store)
            }
        }.frame(maxWidth:.infinity,maxHeight:.infinity)
        .background(Color(nsColor:.windowBackgroundColor)).vmmAppearance(store.settings)
        .alert(L("確認してください"),isPresented:Binding(get:{store.error != nil},set:{if !$0{store.error=nil}})){Button("OK"){store.error=nil}} message:{Text(L(store.error ?? ""))}
    }
}
@MainActor final class WorkspaceSelection:ObservableObject {@Published var page=WorkspacePage.script}
struct WorkspaceView:View {
    @ObservedObject var store:EditorStore;@ObservedObject var selection:WorkspaceSelection
    var body:some View {
        VStack(spacing:0) {
            Picker(L("制作機能"),selection:$selection.page){ForEach(WorkspacePage.productionPages,id:\.self){Text(L($0.rawValue)).vmmFont().tag($0)}}.pickerStyle(.segmented).padding(16)
            HStack {
                Text(L("台本・キャラ・発音辞書・素材を管理します。")).foregroundColor(.secondary)
                Spacer()
                Button(L("ワークスペース設定…")){store.workspaceWindows.show(.workspaceSettings)}
                Button(L("設定…")){store.workspaceWindows.show(.settings)}
                Button(L("書き出し設定…")){store.workspaceWindows.show(.export)}
            }.padding(.horizontal,16).padding(.bottom,12)
            Divider()
            Group {
                switch selection.page {case .mad:MADWorkspace(store:store);case .media:MediaWorkspace(store:store);case .script:ScriptWorkspace(store:store);case .characters:CharacterWorkspace(store:store);case .dictionary:DictionaryWorkspace(store:store);case .library:LibraryWorkspace(store:store);case .settings:SettingsWorkspace(store:store);case .workspaceSettings:WorkspaceSettingsView(store:store);case .recovery:RecoveryWorkspace(store:store);case .export:ExportWorkspace(store:store)}
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
        }
    }
}
struct TypographyControls:View {
    @ObservedObject var store:EditorStore;let clip:Clip
    @State private var search="";@State private var presetName=""
    func binding<T>(_ key:WritableKeyPath<TextStyle,T>)->Binding<T>{store.advancedBinding(clip.id,\.textStyle,key,default:TextStyle())}
    var fonts:[String] {NSFontManager.shared.availableFonts.sorted().filter{search.isEmpty || $0.localizedCaseInsensitiveContains(search)}}
    var body:some View {
        VStack(alignment:.leading,spacing:9) {
                VMMMenuPicker(L("文字の配置"),selection:Binding(get:{clip.textStyle?.alignment ?? .center},set:{v in store.edit(clip.id){var style=$0.textStyle ?? TextStyle();style.alignment=v;$0.textStyle=style}})) {
                    VMMOptions(TextAlignment.allCases,id:\.self){VMMChoice(text:L($0.title),value:$0)}
                }
        PanelDisclosure(L("フォント・文字組み")) {
            VStack(alignment:.leading,spacing:9) {
                TextField(L("フォントを検索"),text:$search).textFieldStyle(.roundedBorder)
                VMMMenuPicker(L("フォント"),selection:Binding(get:{clip.textStyle?.fontName ?? "HiraginoSans-W6"},set:{v in store.edit(clip.id){var style=$0.textStyle ?? TextStyle();style.fontName=v;$0.textStyle=style}})) {
                    let current=clip.textStyle?.fontName ?? "HiraginoSans-W6"
                    if !fonts.contains(current) {VMMChoice(text:current,value:current)}
                    VMMOptions(fonts,id:\.self){VMMChoice(text:L($0),value:$0)}
                }
                Text(L("あいうえお ABC 123")).font(Font(NSFont(name:clip.textStyle?.fontName ?? "HiraginoSans-W6",size:18) ?? NSFont.systemFont(ofSize:18)))
                NumberInput(title:"文字間隔",value:Binding(get:{clip.textStyle?.tracking ?? 0},set:{v in store.edit(clip.id){var s=$0.textStyle ?? TextStyle();s.tracking=v;$0.textStyle=s}}),range:-0.2...2,percent:true)
                NumberInput(title:"行間",value:Binding(get:{clip.textStyle?.lineSpacing ?? 0},set:{v in store.edit(clip.id){var s=$0.textStyle ?? TextStyle();s.lineSpacing=v;$0.textStyle=s}}),range:0...2,percent:true)
                NumberInput(title:"字幕の最大幅",value:Binding(get:{clip.textStyle?.captionWidth ?? 0.9},set:{v in store.edit(clip.id){var s=$0.textStyle ?? TextStyle();s.captionWidth=v;$0.textStyle=s}}),range:0.1...1,percent:true)
                Toggle(L("一文字ずつ表示"),isOn:Binding(get:{clip.textRevealRate != nil},set:{v in store.edit(clip.id){$0.textRevealRate=v ? 12:nil}}))
                if clip.textRevealRate != nil {NumberInput(title:"文字送り速度",value:Binding(get:{clip.textRevealRate ?? 12},set:{v in store.edit(clip.id){$0.textRevealRate=v}}),range:1...100,unit:"字/秒")}
                Menu(L("キャラ字幕プリセット")) {ForEach(store.availableCharacters){preset in Button(preset.name){store.applyCharacter(preset.id,to:[clip.id])}};Divider();Button(L("キャラ設定を開く")){store.workspaceWindows.show(.characters)}}
            }.padding(.top,8)
        }
        }
    }
}
struct ScriptWorkspace:View {
    @ObservedObject var store:EditorStore;@State private var source="";@State private var showImport=false;@State private var characterFilter:UUID?;@State private var unassignedOnly=false
    @State private var splitDraft:CaptionSplitPresentation?
    @State private var transcriptionClip:Clip?
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {Menu(L("字幕ファイル")){Button(L("SRT/VTTを読み込む")){store.importCaptionFile()};Button(L("選択テキストをセリフに変換")){store.reportEditing{try store.convertSelectedTextToSpeech()}}.disabled(store.busy || !store.project.clips.contains{store.selection.contains($0.id) && $0.kind == .text});Button(L("音声から字幕を作成")){transcriptionClip=store.selected}.disabled(store.busy || store.selection.count != 1 || store.selected.map{![.audio,.video,.speech].contains($0.kind)} != false);Button(L("SRTを書き出す")){store.exportCaptions(.srt)};Button(L("VTTを書き出す")){store.exportCaptions(.vtt)}};Button(L("TXT脚本を読み込む")){store.importScriptFile()};Button(L("貼り付けから読み込む")){showImport.toggle()};Spacer();Menu(L("音声を生成")){Button(L("変更・未生成のセリフ")){store.generateDirtySpeech()};Button(L("全セリフを再生成")){store.generateDirtySpeech(force:true)}}.disabled(store.busy)}
            if !store.generatingSpeech.isEmpty || !store.speechFailures.isEmpty {
                HStack {
                    if !store.generatingSpeech.isEmpty {
                        ProgressView().controlSize(.small)
                        Text(String(format:L("生成中 %d・待機 %d"),store.activeSpeech.count,max(0,store.generatingSpeech.count-store.activeSpeech.count)))
                        if store.speechBatchTotal>0 {Text(String(format:L("処理済 %d/%d"),store.speechBatchCompleted,store.speechBatchTotal)).monospacedDigit()}
                        Button(L("中止")){store.cancelSpeech()}
                    }
                    if !store.speechFailures.isEmpty {Text(String(format:L("失敗 %d"),store.speechFailures.count)).foregroundColor(.orange);Button(L("失敗分を再試行")){store.retryFailedSpeech()}.disabled(store.busy)}
                    Spacer()
                }
            }
            if !store.project.captionDiagnostics.isEmpty {
                PanelDisclosure(L("字幕診断")) {
                    ScrollView {VStack(alignment:.leading){ForEach(store.project.captionDiagnostics){d in Button{store.selectedIDs=[];store.selectedID=d.id;if let c=store.selected{store.seek(c.start)}} label:{Text((store.project.clips.first{$0.id==d.id}?.name ?? "")+": "+d.messages.joined(separator:" / "))}}}}.frame(maxHeight:140)
                }
            }
            if showImport {
                Text(L("話者名：セリフ。キャラ名をプリセットと一致させると字幕・話者を自動で割り当てます。")).foregroundColor(.secondary)
                TextEditor(text:$source).frame(height:120).border(Color.gray)
                Button(L("現在位置に配置")){do {try store.importScript(source);source="";showImport=false}catch{store.error=error.localizedDescription}}
            }
            HStack {
                VMMMenuPicker(L("キャラで絞り込み"),selection:$characterFilter){VMMChoice(text:L("すべて"),value:Optional<UUID>.none);VMMOptions(store.availableCharacters,id:\.id){VMMChoice(text:$0.name,value:Optional($0.id))}}.disabled(unassignedOnly)
                Toggle(L("未割り当てのみ"),isOn:$unassignedOnly)
                Spacer()
                Button(L("キャラ設定を開く")){store.workspaceWindows.show(.characters)}
            }
            ScrollView {
                LazyVStack(spacing:10) {
                    ForEach(CharacterCaptionQuery.clips(in:store.project,characterID:characterFilter,unassigned:unassignedOnly)) {clip in
                        HStack(alignment:.top,spacing:12) {
                            Button(String(format:"%.2f秒",clip.start)){store.selectedIDs=[];store.selectedID=clip.id;store.seek(clip.start)}.frame(width:70)
                            VStack(alignment:.leading,spacing:8) {
                                HStack {TextField(L("話者・名前"),text:Binding(get:{clip.name},set:{v in store.edit(clip.id){$0.name=v}})).frame(width:140)
                                    Menu {ForEach(store.availableCharacters){p in Button(p.name){store.applyCharacter(p.id,to:[clip.id])}}} label:{HStack{Circle().fill(Color(nsColor:NSColor(hex:clip.color))).frame(width:10,height:10);Text(store.availableCharacters.first{$0.id==clip.characterPresetID}?.name ?? L("未割り当て"))}}}
                                TextField(L("セリフ"),text:Binding(get:{clip.text},set:{v in store.edit(clip.id){$0.text=v}}),axis:.vertical)
                                if clip.kind == .speech {TextField(L("読み上げ文字（空欄なら字幕と同じ）"),text:Binding(get:{clip.reading ?? ""},set:{v in store.edit(clip.id){$0.reading=v.isEmpty ? nil:v}}))}
                            }.textFieldStyle(.roundedBorder)
                            if clip.kind == .speech {VStack {
                                Button(L(store.generatingSpeech.contains(clip.id) ? (store.activeSpeech.contains(clip.id) ? "生成中":"待機中"):"生成")){store.scheduleSpeech(clip.id,immediate:true)}.disabled(store.generatingSpeech.contains(clip.id))
                                Button(L("字幕を分割")){do{splitDraft=CaptionSplitPresentation(original:clip,parts:try CaptionSplitPlanner.suggest(clip,fps:store.project.fps))}catch{store.error=error.localizedDescription}}.disabled(clip.speechCaptionHidden == true || store.generatingSpeech.contains(clip.id) || store.project.tracks[clip.track].locked)
                                if let failure=store.speechFailures[clip.id] {Text(L("生成失敗")).foregroundColor(.orange).help(failure)}
                            }}
                        }.padding(12).background(Color.primary.opacity(0.04)).cornerRadius(8)
                    }
                }
            }
        }.padding(18).disabled(store.busy).sheet(item:$splitDraft){draft in CaptionSplitSheet(store:store,clip:draft.original,parts:draft.parts)}.sheet(item:$transcriptionClip){clip in TranscriptionSheet(store:store,source:clip)}
    }
}
struct SharedCharacterWorkspace:View {
    @ObservedObject var store:EditorStore;@State private var name=""
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            Text(L("字幕の色・縁・影・フォント・位置と音声エンジン・話者をまとめて保存します。")).foregroundColor(.secondary)
            HStack {TextField(L("キャラ名"),text:$name).textFieldStyle(.roundedBorder);Button(L("選択字幕から保存")){store.captureCharacter(name:name);name=""}.disabled(store.selected.map{![.text,.speech].contains($0.kind)} ?? true)}
            List {ForEach(store.catalog.characters){preset in HStack {TextField(L("名前"),text:Binding(get:{preset.name},set:{v in if let i=store.catalog.characters.firstIndex(where:{$0.id==preset.id}) {store.catalog.characters[i].name=v;store.persistCatalog()}}));Text("\(L("話者")) \(preset.speakerID)").foregroundColor(.secondary);Circle().fill(Color(nsColor:NSColor(hex:preset.color))).frame(width:15,height:15);Button(L("選択に適用")){store.applyCharacter(preset.id)};Button(L("削除")){store.catalog.characters.removeAll{$0.id==preset.id};store.persistCatalog()}}}}
            HStack {Button(L("プリセットを書き出す")){let p=NSSavePanel();p.allowedContentTypes=[.json];p.nameFieldStringValue="characters.json";if p.runModal() == .OK,let url=p.url {do {try JSONEncoder().encode(store.catalog.characters).write(to:url)}catch{store.error=error.localizedDescription}}}
                Button(L("プリセットを読み込む")){let p=NSOpenPanel();p.allowedContentTypes=[.json];if p.runModal() == .OK,let url=p.url {do {let values=try JSONDecoder().decode([CharacterPreset].self,from:Data(contentsOf:url));for v in values {var p=Project();var c=Clip(kind:.speech,name:v.name,track:0,start:0,duration:1);v.apply(to:&c);p.clips=[c];_=try p.validated()};for var v in values {v.id=UUID();store.catalog.characters.append(v)};store.persistCatalog()}catch{store.error=error.localizedDescription}}}}
        }.padding(18)
    }
}
struct DictionaryWorkspace:View {
    @ObservedObject var store:EditorStore;@State private var word="";@State private var reading=""
    var entries:[PronunciationEntry] {store.project.pronunciations ?? store.catalog.pronunciations}
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text(L("字幕を変えずに読みを置き換えます。長い単語から置換します。変更したセリフは音声を再生成します。")).foregroundColor(.secondary)
            HStack {TextField(L("単語"),text:$word);TextField(L("読み"),text:$reading);Button(L("追加")){store.setDictionary(entries+[PronunciationEntry(word:word,reading:reading)]);word="";reading=""}.disabled(word.isEmpty || reading.isEmpty)}.textFieldStyle(.roundedBorder)
            List(entries){entry in HStack {Text(entry.word);UIIcon(systemName:"arrow.right");Text(entry.reading);Spacer();Button(L("削除")){store.setDictionary(entries.filter{$0.id != entry.id})}}}
        }.padding(18)
    }
}
struct RecoveryWorkspace:View {
    @ObservedObject var store:EditorStore
    @State private var refresh=0
    @State private var entries:[RecoveryEntry]=[]
    @State private var saving=false
    var body:some View {VStack(alignment:.leading,spacing:12){
        HStack{Text(L("自動保存履歴")).vmmFont(size:14,weight:.semibold);Spacer()
            Button(L("今すぐ保存")){saving=true;Task{_=await store.saveRecoveryNow();saving=false;refresh+=1}}.disabled(saving || store.busy)
            Button(L("更新")){refresh+=1}}
        List(entries){entry in HStack {
            VStack(alignment:.leading){Text(entry.record.name);Text(entry.record.date,style:.date)+Text(" ")+Text(entry.record.date,style:.time)
                if let path=entry.record.savedPath {Text(path).foregroundColor(.secondary).lineLimit(1)}
                if entry.record.missingFiles>0 {Text(String(format:L("未検出の素材：%d"),entry.record.missingFiles)).foregroundColor(.orange)}
            };Spacer();Button(L("復元")){store.requestLoad(entry.url,asCopy:true)}.disabled(store.busy)
        }}
        Text(L("復元後は別名で保存します。自動保存はプロジェクトごとに設定件数まで保持します。旧履歴も復元できます。")).foregroundColor(.secondary)
    }.padding(18).task(id:store.recoveryFolder.path+"-\(refresh)"){let folder=store.recoveryFolder;entries=await Task.detached(priority:.utility){AutosaveWriter.entries(in:folder)}.value}}
}
struct LibraryWorkspace:View {
    @ObservedObject var store:EditorStore;@State private var name="";@State private var refresh=0
    var body:some View {VStack(alignment:.leading,spacing:12){HStack{TextField(L("テンプレート名"),text:$name);Button(L("現在の動画をテンプレートに保存")){do{try store.saveTemplate(name:name);refresh+=1}catch{store.error=error.localizedDescription}};Button(L("共有用.vmmを書き出す")){store.requestSave(asNew:true)};Button(L("更新")){refresh+=1}}
        HSplitView {
            List(store.templates(),id:\.path){url in HStack{Text(url.deletingPathExtension().lastPathComponent);Spacer();Button(L("使用")){store.requestLoad(url,asCopy:true)}}}
            VStack {Text(L("共有素材")).vmmFont(size:14,weight:.semibold);List(store.sharedAssets(),id:\.0.path){folder,asset in HStack{Text(asset.name);Spacer();Button(L("読み込む")){do{try store.importShared(folder,asset:asset)}catch{store.error=error.localizedDescription}}}}
                Menu(L("現在の素材を共有ライブラリに登録")){ForEach(store.libraryAssets){asset in Button(asset.name){do{try store.addSharedAsset(asset.id);refresh+=1}catch{store.error=error.localizedDescription}}}}}
        }
        Divider();SceneLibraryView(store:store)
        Text(L("素材を含めて保存します。共有フォルダーは設定から指定できます。フォント本体は含みません。")).foregroundColor(.secondary)
    }.padding(18).id(refresh)}
}
enum SettingsTab:String,CaseIterable {case general="一般",speech="音声エンジン",shortcuts="ショートカット",storage="保存とライブラリ",recovery="復元履歴",extensions="拡張"}
struct SettingsWorkspace:View {
    @ObservedObject var store:EditorStore
    func binding<T>(_ key:WritableKeyPath<UserSettings,T>)->Binding<T>{Binding(get:{store.settings[keyPath:key]},set:{store.settings[keyPath:key]=$0;if store.settings.autosaveSeconds>0 && store.settings.autosaveSeconds<10 {store.settings.autosaveSeconds=10};store.persistSettings()})}
    var body:some View {
        VStack(spacing:12) {
            HStack {Text(L("アプリ全体の動作・保存を設定します。")).foregroundColor(.secondary);Spacer();Button(L("ワークスペース設定…")){store.workspaceWindows.show(.workspaceSettings)}}.padding(.horizontal,24)
        TabView(selection:$store.settingsTab) {
            settingsPage {
        VMMMenuPicker(L("表示言語 / UI language"),selection:Binding(get:{store.settings.uiLanguage ?? .japanese},set:{store.settings.uiLanguage=$0;store.persistSettings()})) {
            VMMChoice(text:L("日本語"),value:UILanguage.japanese);VMMChoice(text:"English",value:UILanguage.english)
        }
        Divider()
        HStack {Text(L("バージョン"));Spacer();Text(AppVersion.current.fullDisplay).textSelection(.enabled)}
        Divider()
        Text(L("画面の文字・アイコン・配置・再生品質はワークスペース設定で変更できます。")).foregroundColor(.secondary)
        Button(L("外観の設定を開く")){store.workspaceSettingsTab = .appearance;store.workspaceWindows.show(.workspaceSettings)}
        Button(L("書き出し設定…")){store.workspaceWindows.show(.export)}
            }.tabItem{Text(L(SettingsTab.general.rawValue))}.tag(SettingsTab.general)
            settingsPage {SpeechConnectionControls(store:store)}.tabItem{Text(L(SettingsTab.speech.rawValue))}.tag(SettingsTab.speech)
            settingsPage {
        VMMMenuPicker(L("操作プリセット"),selection:binding(\.shortcuts)){VMMOptions(["VMM標準","Final Cut風","Premiere風"],id:\.self){VMMChoice(text:L($0),value:$0)}}
        Text(L("キーは b、v、space、cmd+shift+s の形式で指定。空欄はプリセットを使用します。")) .foregroundColor(.secondary)
        Button(L("ショートカットをすべて標準に戻す")){store.settings.customShortcuts.removeAll();store.persistSettings()}.disabled(store.settings.customShortcuts.isEmpty)
        ForEach(ShortcutAction.allCases,id:\.self){action in ShortcutEditorRow(store:store,action:action)}

            }.tabItem{Text(L(SettingsTab.shortcuts.rawValue))}.tag(SettingsTab.shortcuts)
            settingsPage {
        NumberInput(title:"自動保存の間隔（0で無効）",value:binding(\.autosaveSeconds),range:0...3600,step:10,unit:"秒")
        NumberInput(title:"復元履歴の保持数",value:Binding(get:{Double(store.settings.recoveryCount)},set:{store.settings.recoveryCount=Int($0);store.persistSettings()}),range:1...100)
        folder("自動保存先",key:\.autosavePath);folder("共有ライブラリ",key:\.libraryPath)
        Text(L("自動保存と共有素材の保存先を管理します。復元するファイルは復元履歴で選択してください。")).foregroundColor(.secondary)
        Button(L("復元履歴を開く")){store.settingsTab = .recovery}
            }.tabItem{Text(L(SettingsTab.storage.rawValue))}.tag(SettingsTab.storage)
            VStack(alignment:.leading,spacing:0){HStack{Text(L("自動保存からプロジェクトを復元します。")).foregroundColor(.secondary);Spacer();Button(L("自動保存の設定")){store.settingsTab = .storage}}.padding(.horizontal,24).padding(.top,16);RecoveryWorkspace(store:store)}.tabItem{Text(L(SettingsTab.recovery.rawValue))}.tag(SettingsTab.recovery)
            settingsPage {DataExtensionSettings(store:store)}.tabItem{Text(L(SettingsTab.extensions.rawValue))}.tag(SettingsTab.extensions)
        }
        }.padding(16)
    }
    func settingsPage<Content:View>(@ViewBuilder _ content:()->Content)->some View {
        ScrollView {VStack(alignment:.leading,spacing:16,content:content).frame(maxWidth:.infinity,alignment:.leading).padding(24)}
    }
    func folder(_ title:String,key:WritableKeyPath<UserSettings,String?>)->some View {HStack{Text(L(title));Text(store.settings[keyPath:key] ?? L("標準フォルダー")).lineLimit(1).foregroundColor(.secondary);Spacer();Button(L("選択")){let p=NSOpenPanel();p.canChooseDirectories=true;p.canChooseFiles=false;if p.runModal() == .OK,let url=p.url{store.settings[keyPath:key]=url.path;store.persistSettings()}};Button(L("標準に戻す")){store.settings[keyPath:key]=nil;store.persistSettings()}}}
}
enum WorkspaceSettingsTab:String,CaseIterable {case appearance="外観",layout="レイアウト",timeline="タイムライン表示",library="素材ライブラリ",preview="プレビューとキャッシュ"}
struct WorkspaceSettingsView:View {
    @ObservedObject var store:EditorStore
    func binding<T>(_ key:WritableKeyPath<UserSettings,T>)->Binding<T>{Binding(get:{store.settings[keyPath:key]},set:{store.settings[keyPath:key]=$0;if store.settings.autosaveSeconds>0 && store.settings.autosaveSeconds<10 {store.settings.autosaveSeconds=10};store.persistSettings()})}
    var body:some View {
        VStack(spacing:12) {
            HStack {Text(L("編集画面の見た目と表示を設定します。")).foregroundColor(.secondary);Spacer();Button(L("アプリの設定…")){store.workspaceWindows.show(.settings)}}.padding(.horizontal,24)
        TabView(selection:$store.workspaceSettingsTab) {
            ScrollView {VStack(alignment:.leading,spacing:16) {
        VMMMenuPicker(L("テーマ"),selection:Binding(get:{store.settings.uiTheme ?? .system},set:{store.settings.uiTheme=$0;store.persistSettings()})){VMMOptions(UITheme.allCases,id:\.self){VMMChoice(text:L($0.title),value:$0)}}
        NumberInput(title:"UI文字サイズ",value:Binding(get:{store.settings.uiFontSize ?? 12},set:{store.settings.uiFontSize=$0;store.persistSettings()}),range:12...24,unit:"pt")
        NumberInput(title:"UIアイコンサイズ",value:Binding(get:{store.settings.uiIconSize ?? 12},set:{store.settings.uiIconSize=$0;store.persistSettings()}),range:12...28,unit:"pt")
        Button(L("文字・アイコンを12ptに戻す")){store.settings.uiFontSize=12;store.settings.uiIconSize=12;store.settings.uiScale=1;store.persistSettings()}
        NumberInput(title:"UI倍率",value:binding(\.uiScale),range:0.8...1.5,percent:true)
        VMMMenuPicker(L("上部ボタンの表示"),selection:Binding(get:{store.settings.toolbarMode},set:{store.settings.toolbarDisplayMode=$0;store.persistSettings()})){VMMOptions(ToolbarDisplayMode.allCases,id:\.self){VMMChoice(text:L($0.title),value:$0)}}
        NumberInput(title:"上部アイコン倍率",value:Binding(get:{store.settings.toolbarIconScale ?? 1.75},set:{store.settings.toolbarIconScale=$0;store.persistSettings()}),range:0.5...2,percent:true)
            }.frame(maxWidth:.infinity,alignment:.leading).padding(24)}.tabItem{Text(L(WorkspaceSettingsTab.appearance.rawValue))}.tag(WorkspaceSettingsTab.appearance)
            ScrollView {VStack(alignment:.leading,spacing:16) {
                Text(L("ウィンドウの分離")).vmmFont(weight:.semibold)
                ForEach(EditorPanel.allCases) {panel in
                    Toggle(L(panel.detachLabel),isOn:Binding(get:{panel.isDetached(in:store.settings)},set:{if panel == .preview && !store.finishPendingPreviewText() {return};if panel == .animation && !$0 {store.showAnimationPanel=true};panel.setDetached($0,in:&store.settings);store.persistSettings()}))
                }
                Text(L("閉じると元の画面に戻ります。サイズと位置は次回起動時も復元します。")).foregroundColor(.secondary)
                Divider()
        Toggle(L("素材ライブラリを表示"),isOn:binding(\.showLibrary));Toggle(L("設定パネルを表示"),isOn:binding(\.showInspector));Toggle(L("設定パネルを左に配置"),isOn:binding(\.inspectorLeft));Toggle(L("編集ツールバーを表示"),isOn:binding(\.showTools))
            }.frame(maxWidth:.infinity,alignment:.leading).padding(24)}.tabItem{Text(L(WorkspaceSettingsTab.layout.rawValue))}.tag(WorkspaceSettingsTab.layout)
            ScrollView {VStack(alignment:.leading,spacing:16) {
                Toggle(L("サムネイルを表示"),isOn:binding(\.thumbnails));Toggle(L("音声波形を表示"),isOn:binding(\.waveforms))
                Text(L("時間軸とレイヤー高さの拡大率は、タイムライン右上で変更できます。")).foregroundColor(.secondary)
            }.frame(maxWidth:.infinity,alignment:.leading).padding(24)}.tabItem{Text(L(WorkspaceSettingsTab.timeline.rawValue))}.tag(WorkspaceSettingsTab.timeline)
            ScrollView {LibraryDisplaySettings(store:store).frame(maxWidth:.infinity,alignment:.leading).padding(24)}.tabItem{Text(L(WorkspaceSettingsTab.library.rawValue))}.tag(WorkspaceSettingsTab.library)
            ScrollView {VStack(alignment:.leading,spacing:16) {
        Toggle(L("再生負荷に応じてプレビューを軽量化"),isOn:Binding(get:{store.settings.adaptivePreview ?? true},set:{store.settings.adaptivePreview=$0;store.persistSettings()}))
        NumberInput(title:"プレビューの最低解像度（長辺）",value:Binding(get:{store.settings.previewMinimumLongEdge ?? 720},set:{store.settings.previewMinimumLongEdge=$0;store.persistSettings()}),range:480...1920,unit:"px")
        Text(L("画質を保ちながら、負荷に応じて粒子数・解像度・描画FPSを調整します。")).foregroundColor(.secondary)
        Text(L("再生時のみ画質を調整します。停止時と書き出しは全品質です。")).foregroundColor(.secondary)
        Toggle(L("字幕安全領域を表示"),isOn:binding(\.safeArea))
        Divider()
        NumberInput(title:"サムネイルキャッシュ上限",value:Binding(get:{Double(store.settings.cacheMB)},set:{store.settings.cacheMB=Int($0);store.persistSettings()}),range:16...2048,unit:"MB")
        Button(L("プレビューキャッシュを削除")){TimelineMediaCache.shared.clear();store.status="キャッシュを削除しました。"}
            }.frame(maxWidth:.infinity,alignment:.leading).padding(24)}.tabItem{Text(L(WorkspaceSettingsTab.preview.rawValue))}.tag(WorkspaceSettingsTab.preview)
        }
        }.padding(16)
    }
}
struct ExportWorkspace:View {
    @ObservedObject var store:EditorStore
    static let outputSizes=["640x360","854x480","1280x720","1920x1080","2560x1440","3840x2160","7680x4320","720x1280","1080x1920","1080x1080"]
    static func outputSizeChoices(_ settings:UserSettings)->[String] {
        guard let w=settings.exportWidth,let h=settings.exportHeight else{return outputSizes}
        let current="\(w)x\(h)";return outputSizes.contains(current) ? outputSizes:[current]+outputSizes
    }
    func binding<T>(_ key:WritableKeyPath<UserSettings,T>)->Binding<T>{Binding(get:{store.settings[keyPath:key]},set:{store.settings[keyPath:key]=$0;if key == \UserSettings.exportCodec && store.settings.exportCodec == "ProRes 422"{store.settings.exportContainer="MOV"};if key == \UserSettings.exportContainer && store.settings.exportContainer == "MP4" && store.settings.exportCodec == "ProRes 422"{store.settings.exportCodec="H.264"};if key == \UserSettings.exportContainer || key == \UserSettings.exportCodec || key == \UserSettings.exportQuality{store.settings.exportTemplate=nil};if store.settings.autosaveSeconds>0 && store.settings.autosaveSeconds<10 {store.settings.autosaveSeconds=10};store.persistSettings()})}
    var body:some View {ScrollView {VStack(alignment:.leading,spacing:18){Text(L("書き出し設定")).vmmFont(size:18,weight:.bold)
        VMMMenuPicker(L("書き出しテンプレート"),selection:Binding(get:{store.settings.exportTemplate ?? "custom"},set:{value in if let preset=ExportTemplate(rawValue:value){preset.apply(to:&store.settings)}else{store.settings.exportTemplate=nil};store.persistSettings()})) {
            VMMChoice(text:L("カスタム"),value:"custom")
            VMMOptions(ExportTemplate.allCases,id:\.rawValue){VMMChoice(text:$0.title,value:$0.rawValue)}
        }
        Button(L("プロジェクト設定に戻す")){store.settings.clearExportTemplate();store.persistSettings()}
        Text(L("書き出し時だけサイズとFPSを変更します。縦横比を保ち、余白を黒で補います。")).foregroundColor(.secondary)
        VMMMenuPicker(L("書き出しサイズ"),selection:Binding(get:{if let w=store.settings.exportWidth,let h=store.settings.exportHeight{return "\(w)x\(h)"};return "project"},set:{value in
            store.settings.exportTemplate=nil
            let parts=value.split(separator:"x").compactMap{Int($0)}
            store.settings.exportWidth=parts.count==2 ? parts[0]:nil;store.settings.exportHeight=parts.count==2 ? parts[1]:nil;store.persistSettings()
        })) {
            VMMChoice(text:L("プロジェクト設定"),value:"project")
            VMMOptions(Self.outputSizeChoices(store.settings),id:\.self){VMMChoice(text:$0.replacingOccurrences(of:"x",with:" × "),value:$0)}
        }
        Toggle(L("プロジェクトのFPSを使う"),isOn:Binding(get:{store.settings.exportFPS==nil},set:{v in store.settings.exportTemplate=nil;store.settings.exportFPS=v ? nil:store.project.fps;store.persistSettings()}))
        if store.settings.exportFPS != nil {NumberInput(title:"書き出しFPS",value:Binding(get:{Double(store.settings.exportFPS ?? store.project.fps)},set:{store.settings.exportTemplate=nil;store.settings.exportFPS=Int($0);store.persistSettings()}),range:1...60)}

        VMMMenuPicker(L("形式"),selection:binding(\.exportContainer)){VMMChoice(text:"MP4",value:"MP4");VMMChoice(text:"MOV",value:"MOV")}
        VMMMenuPicker(L("コーデック"),selection:binding(\.exportCodec)){VMMChoice(text:"H.264",value:"H.264");VMMChoice(text:"HEVC",value:"HEVC");VMMChoice(text:"ProRes 422",value:"ProRes 422")}
        if store.settings.exportCodec != "ProRes 422" {
        Toggle(L("映像ビットレートを指定"),isOn:Binding(get:{store.settings.exportVideoMbps != nil},set:{v in store.settings.exportTemplate=nil;store.settings.exportVideoMbps=v ? 8:nil;store.persistSettings()}))
        if store.settings.exportVideoMbps != nil {NumberInput(title:"映像ビットレート",value:Binding(get:{store.settings.exportVideoMbps ?? 8},set:{store.settings.exportTemplate=nil;store.settings.exportVideoMbps=$0;store.persistSettings()}),range:0.2...240,unit:"Mbps")}
        else {NumberInput(title:"品質",value:binding(\.exportQuality),range:0.1...1,percent:true)}
        Toggle(L("音声ビットレートを指定"),isOn:Binding(get:{store.settings.exportAudioKbps != nil},set:{v in store.settings.exportTemplate=nil;store.settings.exportAudioKbps=v ? 192:nil;store.persistSettings()}))
        if store.settings.exportAudioKbps != nil {NumberInput(title:"音声ビットレート",value:Binding(get:{Double(store.settings.exportAudioKbps ?? 192)},set:{store.settings.exportTemplate=nil;store.settings.exportAudioKbps=Int($0);store.persistSettings()}),range:64...320,unit:"kbps")}
        }
        Text(L(store.settings.exportCodec == "ProRes 422" ? "ProResは中間素材用。音声はPCM・48 kHz・24 bit・ステレオです。":"ビットレートは目標値です。音声はAAC・48 kHz・ステレオです。")).foregroundColor(.secondary)
        if store.settings.exportTemplate == ExportTemplate.x.rawValue && exportDuration>140 {Text(L("Xの通常投稿は140秒までです。範囲を短くするか、Premiumの投稿条件を確認してください。")).foregroundColor(.orange)}

        NumberInput(title:"開始",value:binding(\.rangeStart),range:0...max(0,store.project.duration),unit:"秒")
        NumberInput(title:"終了（0なら末尾）",value:binding(\.rangeEnd),range:0...max(0,store.project.duration),unit:"秒")
        HStack{Button(L("イン／アウト範囲")){if let r=store.project.timelineRange{store.settings.rangeStart=r.start;store.settings.rangeEnd=min(r.end,store.project.duration);store.persistSettings()}}.disabled(store.project.timelineRange==nil);Button(L("全体")){store.settings.rangeStart=0;store.settings.rangeEnd=0;store.persistSettings()};Button(L("選択アイテムの範囲")){if let c=store.selected{store.settings.rangeStart=c.start;store.settings.rangeEnd=c.end;store.persistSettings()}}}
        ExportReportView(store:store)
        ExportActionsView(store:store,queue:store.exportQueue)
        Divider();ExportQueueView(queue:store.exportQueue)
        Spacer()
    }.padding(24).frame(maxWidth:650)}.disabled(store.busy).onChange(of:store.project){_ in store.exportReport=nil}.onChange(of:store.settings){_ in store.exportReport=nil}}
    var exportDuration:Double{max(0,(store.settings.rangeEnd>0 ? min(store.settings.rangeEnd,store.project.duration):store.project.duration)-store.settings.rangeStart)}
}
struct EditingToolbar:View {
    @ObservedObject var store:EditorStore
    var body:some View {HStack(spacing:14){Picker(L("ツール"),selection:$store.tool){ForEach(EditingTool.allCases,id:\.self){Text(L($0.rawValue)).vmmFont().tag($0)}}.pickerStyle(.segmented).frame(width:290)
        TimelineNavigationControls(store:store)
        Text(L("⌘クリックで複数選択")).vmmFont().foregroundColor(.secondary)
        Spacer();Text(VMMLocalization.language == .english ? "\(store.selection.count) selected":"\(store.selection.count)個選択").vmmFont()
        Menu(L("一括操作")){Button(L("選択を複製")){store.duplicateSelection()};Button(L("字幕スタイルを揃える")){store.bulkStyle()};ForEach(["左揃え","上揃え","中央","開始揃え","順に配置"],id:\.self){mode in Button(mode){store.arrange(mode)}};Divider();Button(L("選択を削除")){store.deleteSelection()}}
    }.padding(.horizontal,16).frame(height:38).disabled(store.busy)}
}

struct MediaWorkspace:View {
    @ObservedObject var store:EditorStore
    var body:some View {VStack(alignment:.leading,spacing:12){
        Text(L("未検出の素材を再リンクできます。動画プロキシは編集プレビューで使い、書き出しには元素材を使います。")).foregroundColor(.secondary)
        List(store.project.assets){asset in HStack {
            UIIcon(systemName:store.missingAssets.contains(where:{$0.id==asset.id}) ? "exclamationmark.triangle":"checkmark.circle")
            Text(asset.name);Spacer();Text(L(asset.kind.title)).foregroundColor(.secondary)
            Button(L("再リンク")){store.chooseRelink(asset.id)}
            if asset.kind == .video {Button(asset.proxyFile == nil ? "プロキシを作成":"再生成"){Task{do{try await store.makeProxy(asset.id)}catch{store.error=error.localizedDescription}}};if asset.proxyFile != nil{Button(L("元素材で編集")){store.pause();store.checkpoint();if let i=store.project.assets.firstIndex(where:{$0.id==asset.id}){store.project.assets[i].proxyFile=nil}}}}
        }}

    }.padding(18).disabled(store.busy)}
}

/// Edits remain local until applied so incomplete input never replaces a working shortcut.
private struct ShortcutEditorRow:View {
    @ObservedObject var store:EditorStore
    let action:ShortcutAction
    @State private var draft=""
    @State private var attempted=false
    private var saved:String {store.settings.customShortcuts[action.rawValue] ?? ""}
    private var parsed:String? {ShortcutMap.canonical(draft)}
    private var candidate:String {parsed == "" ? ShortcutMap.key(action,settings:store.settings,ignoreCustom:true):(parsed ?? "")}
    private var conflicts:[ShortcutAction] {ShortcutMap.conflicts(for:action,key:candidate,settings:store.settings)}
    var body:some View {
        VStack(alignment:.leading,spacing:3) {
            HStack {
                Text(L(action.title)).frame(width:150,alignment:.leading)
                TextField("\(L("標準")): \(ShortcutMap.key(action,settings:store.settings,ignoreCustom:true))",text:$draft)
                    .textFieldStyle(.roundedBorder).onSubmit(apply)
                    .accessibilityLabel(L(action.title)+" "+L("ショートカット"))
                Button(L("適用"),action:apply).disabled(parsed == nil || !conflicts.isEmpty || draft==saved)
                Button(L("標準に戻す")){store.settings.customShortcuts.removeValue(forKey:action.rawValue);store.persistSettings();draft="";attempted=false}.disabled(saved.isEmpty && draft.isEmpty)
            }
            if parsed == nil {
                Text(L("入力形式を確認してください。例: cmd+shift+s、space、left")) .foregroundColor(.orange)
            } else if !conflicts.isEmpty {
                Text(L("同じキーが割り当てられています:")+" "+conflicts.map{L($0.title)}.joined(separator:", ")) .foregroundColor(.orange)
            } else if attempted {
                Text(L("ショートカットを適用しました。")) .foregroundColor(.secondary)
            }
        }.onAppear{draft=saved}.onChange(of:saved){draft=$0;attempted=false}
    }
    private func apply() {
        guard let value=parsed,conflicts.isEmpty else{return}
        if value.isEmpty {store.settings.customShortcuts.removeValue(forKey:action.rawValue)}
        else {store.settings.customShortcuts[action.rawValue]=value}
        store.persistSettings();draft=value;attempted=true
    }
}
