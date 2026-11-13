import SwiftUI
import AppKit

@MainActor final class PrecompositionWindows {
    weak var owner:EditorStore?
    private var opening:Set<UUID>=[]
    private var sessions:[UUID:PrecompositionSession]=[:]
    static weak var active:PrecompositionSession?
    func closeAll()->Bool {guard opening.isEmpty else{return false};for session in Array(sessions.values){session.window.performClose(nil);if session.window.isVisible || session.window.isMiniaturized{return false}};return true}
    static var focused:PrecompositionSession? {guard let active,let window=NSApp.keyWindow else{return nil};return active.owns(window) ? active:nil}
    init(owner:EditorStore){self.owner=owner}
    func show(_ clipID:UUID){
        guard let owner,let clip=owner.project.clips.first(where:{$0.id==clipID}),let c=owner.project.composition(clip),!owner.busy else{return}
        if let session=sessions[c.id]{session.window.makeKeyAndOrderFront(nil);return}
        guard opening.insert(c.id).inserted else{return}
        owner.pause()
        Task{[self] in defer{opening.remove(c.id)};do{
            let session=try await PrecompositionSession(owner:owner,composition:c,onClose:{[weak self] in self?.sessions[c.id]=nil})
            guard owner.project.precompositions?.contains(where:{$0.id==c.id}) == true else{session.dispose();return}
            sessions[c.id]=session;session.window.makeKeyAndOrderFront(nil)
        }catch{owner.error=error.localizedDescription}}
    }
}
@MainActor final class PrecompositionSession:NSObject,ObservableObject,NSWindowDelegate {
    let draft:EditorStore
    weak var owner:EditorStore?
    var window:NSWindow!
    @Published var duration:Double
    @Published var applying=false
    var baselineLibrary:[Precomposition]
    var baseline:Precomposition
    private let parentDirectory:URL
    private let onClose:()->Void
    init(owner:EditorStore,composition:Precomposition,onClose:@escaping ()->Void)async throws {
        self.owner=owner;baselineLibrary=owner.project.precompositions ?? [];baseline=composition;duration=composition.duration;parentDirectory=owner.directory;self.onClose=onClose
        draft=EditorStore(preferencesDirectory:FileManager.default.temporaryDirectory.appendingPathComponent("vmm-comp-prefs-\(UUID())"),scriptWorkerExecutable:owner.scriptWorkerExecutable)
        super.init()
        draft.autoSpeech=false;draft.settings=owner.settings;draft.settings.autosaveSeconds=0;draft.settings.rangeStart=0;draft.settings.rangeEnd=0;draft.settings.detachedTimeline=false;draft.settings.detachedInspector=false;draft.settings.detachedPreview=false;draft.settings.detachedLibrary=false;draft.settings.detachedAnimation=false;draft.settings.showLibrary=true;draft.settings.showInspector=true
        draft.catalog=owner.catalog;draft.dataExtensions=owner.dataExtensions;draft.project=owner.project.compositionProject(composition);draft.selectedID=draft.project.clips.first?.id;draft.selectedTrack=draft.project.clips.first?.track ?? 0;draft.dirty=false;draft.editingPrecompositionID=composition.id
        let source=owner.directory.appendingPathComponent("Media"),target=draft.directory.appendingPathComponent("Media"),files=Set(owner.project.assets.flatMap(\.files))
        owner.retainSession(owner.directory);defer{owner.releaseSession(parentDirectory)}
        do{try await Task.detached{for file in files{let from=source.appendingPathComponent(file);if FileManager.default.fileExists(atPath:from.path){try ProjectIO.copy(from,to:target.appendingPathComponent(file))}}}.value}catch{dispose();throw error}
        let available=NSScreen.main?.visibleFrame.size ?? CGSize(width:1440,height:1000)
        window=NSWindow(contentRect:CGRect(x:0,y:0,width:min(1380,available.width-40),height:min(940,available.height-60)),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.contentMinSize=CGSize(width:1060,height:780);window.title="VMM — \(L("プリコンポジション")): \(composition.name)";window.delegate=self;window.contentView=NSHostingView(rootView:PrecompositionEditor(session:self));window.center();draft.panelWindows.start(mainWindow:window)
    }
    func apply(){guard !applying,!draft.busy,draft.finishPendingPreviewText(),!draft.scriptGenerating,draft.generatingSpeech.isEmpty,let owner else{return};applying=true
        Task{defer{applying=false};do{
            let updated=try await owner.applyPrecomposition(baseline:baseline,draft:draft.project,media:draft.directory.appendingPathComponent("Media"),duration:duration,expectedDirectory:parentDirectory,baselineLibrary:baselineLibrary)
            baseline=updated;baselineLibrary=owner.project.precompositions ?? [];draft.project.precompositions=baselineLibrary;draft.dirty=false;draft.status="プリコンポジションの変更を適用しました。"
        }catch{draft.error=error.localizedDescription}}
    }
    func owns(_ window:NSWindow)->Bool {self.window === window || draft.panelWindows.contains(window) || draft.workspaceWindows.contains(window)}
    func windowDidBecomeKey(_ notification:Notification){PrecompositionWindows.active=self}
    func windowShouldClose(_ sender:NSWindow)->Bool {
        guard !applying,!draft.busy,draft.finishPendingPreviewText(),draft.precompositionWindows.closeAll() else{return false}
        if draft.dirty {let alert=NSAlert();alert.messageText=L("プリコンポジションの変更を破棄しますか？");alert.addButton(withTitle:L("破棄"));alert.addButton(withTitle:L("キャンセル"));return alert.runModal() == .alertFirstButtonReturn};return true
    }
    func windowWillClose(_ notification:Notification){dispose();onClose();if PrecompositionWindows.active === self{PrecompositionWindows.active=nil}}
    func dispose(){draft.panelWindows.closeAll();draft.workspaceWindows.closeAll();draft.pause();draft.cancelSpeech();try? FileManager.default.removeItem(at:draft.directory);try? FileManager.default.removeItem(at:draft.preferencesDirectory)}
}
@MainActor extension EditorStore {
    func applyPrecomposition(baseline:Precomposition,draft:Project,media:URL,duration:Double,expectedDirectory:URL,baselineLibrary:[Precomposition]?=nil)async throws->Precomposition {
        guard !busy,directory==expectedDirectory,let index=project.precompositions?.firstIndex(where:{$0.id==baseline.id}),project.precompositions?[index]==baseline else{throw VMMError.message("元のプリコンポジションが変更されています。開き直してから編集してください。")}
        let updated=Precomposition(id:baseline.id,name:draft.name,width:draft.width,height:draft.height,fps:draft.fps,duration:duration,tracks:draft.tracks,clips:draft.clips,markers:draft.markers,timelineRange:draft.timelineRange,background:draft.background)
        var candidate=project
        let ids=Set(candidate.assets.map(\.id)),newAssets=draft.assets.filter{!ids.contains($0.id)}
        candidate.assets+=newAssets
        let characters=Set((candidate.characters ?? []).map(\.id));candidate.characters=(candidate.characters ?? [])+(draft.characters ?? []).filter{!characters.contains($0.id)}
        for c in draft.precompositions ?? [] where c.id != baseline.id {
            if let old=baselineLibrary?.first(where:{$0.id==c.id}),old==c{continue}
            if let old=baselineLibrary?.first(where:{$0.id==c.id}),candidate.precompositions?.first(where:{$0.id==c.id}) != old {throw VMMError.message("入れ子のプリコンポジションが別の画面で変更されています。開き直してください。")}
            if let i=candidate.precompositions?.firstIndex(where:{$0.id==c.id}){candidate.precompositions?[i]=c}else{candidate.precompositions?.append(c)}
        }
        candidate.precompositions?[index]=updated
        // Retain current instance trims; extend full-length instances with their source.
        for i in candidate.clips.indices where candidate.clips[i].precompositionID==baseline.id && candidate.clips[i].sourceOffset==0 && abs(candidate.clips[i].duration-baseline.duration)<0.000001{candidate.clips[i].duration=duration}
        _=try candidate.validated();busy=true;pause();retainSession(directory);defer{busy=false;releaseSession(expectedDirectory)}
        let target=directory.appendingPathComponent("Media"),files=Set(newAssets.flatMap(\.files))
        try await Task.detached{var copied:[URL]=[];do{for file in files{let destination=target.appendingPathComponent(file);guard !FileManager.default.fileExists(atPath:destination.path) else{throw VMMError.message("素材名が衝突しています。既存素材は保持しました。")};try ProjectIO.copy(media.appendingPathComponent(file),to:destination);copied.append(destination)}}catch{for file in copied{try? FileManager.default.removeItem(at:file)};throw error}}.value
        checkpoint();project=candidate;status="プリコンポジションの変更を全配置へ適用しました。";return updated
    }
}
struct PrecompositionEditor:View {
    @ObservedObject var session:PrecompositionSession
    @ObservedObject var draft:EditorStore
    init(session:PrecompositionSession){self.session=session;self.draft=session.draft}
    var body:some View {VStack(spacing:0){
        HStack{Label(L("プリコンポジション"),systemImage:"square.stack.3d.up").bold();TextField(L("名前"),text:Binding(get:{session.draft.project.name},set:{session.draft.checkpoint();session.draft.project.name=$0})).frame(width:240)
            NumberInput(title:"コンポの長さ",value:Binding(get:{session.duration},set:{session.duration=$0;session.draft.dirty=true}),range:1/Double(session.draft.project.fps)...86400,unit:"秒").frame(width:260)
            Spacer()
            Button(L("変更を適用")){session.apply()}.keyboardShortcut("s",modifiers:.command).disabled(session.applying || session.draft.busy || session.draft.scriptGenerating || !session.draft.generatingSpeech.isEmpty)
            Button(L("閉じる")){session.window.performClose(nil)}
        }.padding(.horizontal,12).padding(.top,12)
        HStack{Button(L("素材を読み込む")){draft.importMedia()};Button(L("元に戻す")){draft.undo()}.disabled(!draft.canUndo);Button(L("やり直す")){draft.redo()}.disabled(!draft.canRedo)
            Button(L("プリコンポジションにまとめる…")){draft.promptPrecomposition()}.disabled(draft.selection.isEmpty)
            Button(L("共有ライブラリ")){draft.workspaceWindows.show(.library)}
            Spacer();Text(L("編集後に「変更を適用」でメインへ反映します。" )).foregroundColor(.secondary)
        }.padding(12).disabled(draft.busy || session.applying)
        EditorView(store:session.draft,showToolbar:false)
    }.background(Color(nsColor:.windowBackgroundColor)).vmmAppearance(session.draft.settings).onChange(of:draft.dirty){dirty in session.window?.isDocumentEdited=dirty}.onChange(of:draft.project.name){name in session.window?.title="VMM — \(L("プリコンポジション")): \(name)"}}
}
struct PrecompositionLibrary:View {
    @ObservedObject var store:EditorStore
    var body:some View {VStack(alignment:.leading,spacing:8){
        Button(L("選択をプリコンポジションにまとめる…")){store.promptPrecomposition()}.disabled(store.selection.isEmpty || store.busy)
        ForEach((store.project.precompositions ?? []).filter{$0.id != store.editingPrecompositionID}){c in HStack{Text(c.name);Spacer();Text(String(format:"%.2f s",c.duration));Button(L("配置")){store.reportEditing{try store.placePrecomposition(c.id)}}}.contextMenu{Button(L("削除")){store.reportEditing{try store.deletePrecomposition(c.id)}}.disabled((store.project.clips+(store.project.precompositions ?? []).flatMap(\.clips)).contains{$0.precompositionID==c.id})}}
    }}
}
@MainActor extension EditorStore {
    func placePrecomposition(_ id:UUID)throws {
        guard !busy,!project.tracks[selectedTrack].locked,let c=project.precompositions?.first(where:{$0.id==id}) else{throw VMMError.message("配置可能なプリコンポジションを選択してください。")}
        var clip=Clip(kind:.group,name:c.name,track:selectedTrack,start:playhead,duration:c.duration);clip.precompositionID=id;var candidate=project;candidate.clips.append(clip);_=try candidate.validated();pause();checkpoint();project=candidate;selectedIDs=[];selectedID=clip.id
    }
}
