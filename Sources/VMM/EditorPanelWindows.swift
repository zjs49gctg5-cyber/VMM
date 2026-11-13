import AppKit
import SwiftUI
import Combine

/// Layout preferences belong to the workspace, never to the video project.
enum EditorPanel:String,CaseIterable,Identifiable {
    case timeline,inspector,preview,library,animation
    var id:String {rawValue}
    var title:String {switch self {case .timeline:return "タイムライン";case .inspector:return "アイテム設定";case .preview:return "プレビュー";case .library:return "素材ライブラリ";case .animation:return "アニメーション"}}
    var detachLabel:String {switch self {case .timeline:return "タイムラインを独立ウィンドウにする";case .inspector:return "アイテム設定を独立ウィンドウにする";case .preview:return "プレビューを独立ウィンドウにする";case .library:return "素材ライブラリを独立ウィンドウにする";case .animation:return "アニメーションを独立ウィンドウにする"}}
    var preference:WritableKeyPath<UserSettings,Bool?> {switch self {case .timeline:return \.detachedTimeline;case .inspector:return \.detachedInspector;case .preview:return \.detachedPreview;case .library:return \.detachedLibrary;case .animation:return \.detachedAnimation}}
    func isDetached(in settings:UserSettings)->Bool {settings[keyPath:preference] ?? false}
    func setDetached(_ value:Bool,in settings:inout UserSettings) {settings[keyPath:preference]=value}
    func isVisible(in settings:UserSettings)->Bool {switch self {case .inspector:return settings.showInspector;case .library:return settings.showLibrary;default:return true}}
    static func embeddedTopPanels(in settings:UserSettings)->Bool {[inspector,preview,library].contains{$0.isVisible(in:settings) && !$0.isDetached(in:settings)}}
    var size:NSSize {switch self {case .timeline:return NSSize(width:1100,height:420);case .inspector:return NSSize(width:400,height:760);case .preview:return NSSize(width:880,height:600);case .library:return NSSize(width:440,height:680);case .animation:return NSSize(width:1060,height:520)}}
    var minimumSize:NSSize {switch self {case .timeline:return NSSize(width:640,height:240);case .inspector:return NSSize(width:300,height:400);case .preview:return NSSize(width:420,height:300);case .library:return NSSize(width:280,height:360);case .animation:return NSSize(width:700,height:300)}}
}

struct TimelinePanel:View {
    @ObservedObject var store:EditorStore
    var body:some View {
        HStack(spacing:0){
            TimelineAudioMeter(clock:store.playbackClock).frame(width:max(132,store.settings.textPoints*11))
            Divider()
            VStack(spacing:0){if store.settings.showTools {EditingToolbar(store:store)};TimelineView(store:store)}
        }
    }
}
struct DetachedEditorPanel:View {
    @ObservedObject var store:EditorStore
    let panel:EditorPanel
    var body:some View {
        Group {switch panel {
        case .timeline:TimelinePanel(store:store)
        case .inspector:InspectorView(store:store)
        case .preview:VStack(spacing:0){EditorToolbar(store:store);Divider();PreviewPanel(store:store)}
        case .library:MediaLibraryPanel(store:store)
        case .animation:AnimationWorkspace(store:store,onClose:{store.panelWindows.closeAnimation()})

        }}.frame(maxWidth:.infinity,maxHeight:.infinity)
            .vmmAppearance(store.settings).foregroundColor(.primary)
            .background(Color(nsColor:.windowBackgroundColor))
            .tint(.accentColor)
            .alert(L("確認してください"),isPresented:Binding(get:{store.error != nil},set:{if !$0 {store.error=nil}})){Button("OK"){store.error=nil}}message:{Text(L(store.error ?? ""))}
    }
}

@MainActor final class EditorPanelWindowController:NSObject,NSWindowDelegate {
    private weak var store:EditorStore?
    private weak var mainWindow:NSWindow?
    private(set) var windows:[EditorPanel:NSWindow]=[:]
    private var observer:AnyCancellable?
    init(store:EditorStore){self.store=store;super.init()}
    /// Start only when the real editor is ready; model/API tests never open windows.
    func start(mainWindow:NSWindow?=nil) {
        self.mainWindow=mainWindow
        guard observer == nil,let store else{return}
        observer=Publishers.CombineLatest4(store.$settings,store.$project.map(\.name).removeDuplicates(),store.$dirty.removeDuplicates(),store.$savedURL.removeDuplicates()).receive(on:RunLoop.main).sink{[weak self] _ in self?.synchronize()}
        synchronize()
    }
    func contains(_ window:NSWindow)->Bool {windows.values.contains{$0 === window}}
    func closeAll(){observer=nil;for window in windows.values{window.close();window.contentView=nil};windows.removeAll()}
    func present(_ panel:EditorPanel) {synchronize();windows[panel]?.makeKeyAndOrderFront(nil)}
    func closeAnimation(){guard let store else{return};store.showAnimationPanel=false;EditorPanel.animation.setDetached(false,in:&store.settings);store.persistSettings()}

    func synchronize() {
        guard let store else{return}
        for panel in EditorPanel.allCases {
            let visible=panel.isDetached(in:store.settings) && panel.isVisible(in:store.settings)
            if !visible {
                if let old=windows.removeValue(forKey:panel) {
                    old.saveFrame(usingName:"VMM.editorPanel.\(panel.rawValue)")
                    old.close();old.contentView=nil
                }
                continue
            }
            let window:NSWindow
            if let existing=windows[panel] {window=existing}
            else {
                window=NSWindow(contentRect:NSRect(origin:.zero,size:panel.size),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
                window.isReleasedWhenClosed=false;window.tabbingMode = .disallowed
                window.minSize=panel.minimumSize
                let host=NSHostingView(rootView:DetachedEditorPanel(store:store,panel:panel));if #available(macOS 13.0,*){host.sizingOptions=[]}
                window.contentView=host;window.delegate=self
                window.center()
                // QA uses its own bundle identifier, so it cannot alter the user's saved frames.
                window.setFrameAutosaveName("VMM.editorPanel.\(panel.rawValue)")
                _=window.setFrameUsingName("VMM.editorPanel.\(panel.rawValue)")
                windows[panel]=window
            }
            window.title="\(store.project.name) — \(L(panel.title)) — VMM"
            window.representedURL=store.savedURL;window.isDocumentEdited=store.dirty
            // Do not steal focus or unminimize other panels on every preference change.
            if !window.isVisible && !window.isMiniaturized {window.orderFront(nil)}
        }
    }
    func windowShouldClose(_ sender:NSWindow)->Bool {
        guard let store,let panel=windows.first(where:{$0.value === sender})?.key else{return true}
        guard store.finishPendingPreviewText() else{return false}
        panel.setDetached(false,in:&store.settings);if panel == .animation {store.showAnimationPanel=true};store.persistSettings()
        mainWindow?.makeKeyAndOrderFront(nil)
        return true
    }
}

@MainActor extension EditorStore {
    func openAnimationPanel(){showAnimationPanel=true;if EditorPanel.animation.isDetached(in:settings){panelWindows.present(.animation)}}
    func toggleAnimationPanel(){if EditorPanel.animation.isDetached(in:settings){panelWindows.present(.animation)}else{showAnimationPanel.toggle()}}
}
