import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store = EditorStore()
    var window: NSWindow!
    let controlMCP=VMMControlMCP()
    private var mcpWindow:NSWindow?
    private var settingsObserver:AnyCancellable?
    private var projectTitle:ProjectWindowTitleController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.appearance = (store.settings.uiTheme ?? .system).appearance
        let root = EditorView(store: store)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1380, height: 880), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        projectTitle=ProjectWindowTitleController(window:window,store:store)
        window.minSize = NSSize(width: 1060, height: 720)
        window.contentView = NSHostingView(rootView: root)
        window.isReleasedWhenClosed=false
        window.delegate = self
        window.center(); window.makeKeyAndOrderFront(nil)
        makeMenu()
        store.panelWindows.start(mainWindow:window)
        settingsObserver=store.$settings.sink{[weak self] settings in DispatchQueue.main.async{NSApp.appearance=(settings.uiTheme ?? .system).appearance;self?.makeMenu()}}
        store.startAutosave()
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let keyWindow=NSApp.keyWindow, (keyWindow === self.window || self.store.panelWindows.contains(keyWindow) || PrecompositionWindows.focused != nil), NSApp.modalWindow == nil, !(keyWindow.firstResponder is NSTextView), !self.store.busy else { return event }
            if let timeline=keyWindow.firstResponder as? TimelineNSView,timeline.handleMarkerKey(event){return nil}
            let key=ShortcutMap.normalized(event)
            if let action=ShortcutAction.allCases.first(where:{ShortcutMap.key($0,settings:self.editingStore.settings)==key}) {if action == .save,let session=PrecompositionWindows.focused{session.apply()}else{self.editingStore.performShortcut(action)};return nil}
            return event
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    func makeMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        item("設定…",#selector(showSettings),",",to:appMenu)
        item("復元履歴…",#selector(showRecovery),"",to:appMenu)
        item("ワークスペース設定…",#selector(showWorkspaceSettings),"",to:appMenu)
        appMenu.addItem(.separator())
        item("MCP接続…", #selector(showMCP), "", to:appMenu)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle:L("VMMを終了"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let file = NSMenuItem(); file.title=L("ファイル"); menu.addItem(file)
        let fileMenu = NSMenu(title:L("ファイル")); file.submenu = fileMenu
        item("新規プロジェクト", #selector(newProject), "n", to: fileMenu)
        item("開く…", #selector(openProject), "o", to: fileMenu)
        item("保存", #selector(saveProject), "s", to: fileMenu)
        item("別名で保存…", #selector(saveAs), "s", to: fileMenu, shift: true)
        item("TXT脚本を読み込む…", #selector(importScript), "", to:fileMenu)
        item("音MADモード…", #selector(showMAD), "", to:fileMenu)
        item("制作ワークスペース…", #selector(showWorkspace), "", to:fileMenu)
        fileMenu.addItem(.separator())
        item("素材を読み込む…", #selector(importMedia), "i", to: fileMenu)
        item("動画を書き出す…", #selector(exportMovie), "e", to: fileMenu)
        let edit = NSMenuItem(); edit.title=L("編集"); menu.addItem(edit)
        let editMenu = NSMenu(title:L("編集")); edit.submenu = editMenu
        item("元に戻す", #selector(undoEdit), "z", to: editMenu)
        item("やり直す", #selector(redoEdit), "z", to: editMenu, shift: true)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle:L("カット"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        item("コピー",#selector(copyItems),"c",to:editMenu)
        item("ペースト",#selector(pasteItems),"v",to:editMenu)
        editMenu.addItem(withTitle:L("すべて選択"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        item("アイテムを複製", #selector(duplicate), "d", to: editMenu)
        item("再生位置で分割", #selector(split), "b", to: editMenu)
        let mapped:[Selector:ShortcutAction]=[#selector(saveProject):.save,#selector(undoEdit):.undo,#selector(redoEdit):.redo,#selector(duplicate):.duplicate,#selector(split):.split]
        for submenu in menu.items.compactMap(\.submenu) {for item in submenu.items {if let action=item.action,let command=mapped[action] {
            let parts=ShortcutMap.key(command,settings:store.settings).split(separator:"+").map(String.init)
            item.keyEquivalent=parts.last ?? "";var flags:NSEvent.ModifierFlags=[]
            if parts.contains("cmd"){flags.insert(.command)};if parts.contains("shift"){flags.insert(.shift)};if parts.contains("ctrl"){flags.insert(.control)};if parts.contains("alt"){flags.insert(.option)}
            item.keyEquivalentModifierMask=flags
        }}}
        let windowItem=NSMenuItem();windowItem.title=L("ウィンドウ");menu.addItem(windowItem)
        let windowMenu=NSMenu(title:L("ウィンドウ"));windowItem.submenu=windowMenu
        item("メインウィンドウを表示",#selector(showMainWindow),"",to:windowMenu)
        windowMenu.addItem(withTitle:L("すべてを手前に移動"),action:#selector(NSApplication.arrangeInFront(_:)),keyEquivalent:"")
        NSApp.windowsMenu=windowMenu
        NSApp.mainMenu = menu
    }
    func item(_ title: String, _ selector: Selector, _ key: String, to menu: NSMenu, shift: Bool = false) {
        let item = NSMenuItem(title:L(title), action:selector, keyEquivalent: key)
        item.target = self
        if shift { item.keyEquivalentModifierMask = [.command, .shift] }
        menu.addItem(item)
    }
    @objc func showMCP() {
        if let mcpWindow {mcpWindow.makeKeyAndOrderFront(nil);return}
        let panel=NSWindow(contentRect:NSRect(x:0,y:0,width:680,height:520),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        panel.title="VMM — MCP接続";panel.isReleasedWhenClosed=false
        panel.contentView=NSHostingView(rootView:ControlMCPSettings(mcp:controlMCP,store:store));panel.center();panel.makeKeyAndOrderFront(nil);mcpWindow=panel
    }
    private var editingStore:EditorStore {PrecompositionWindows.focused?.draft ?? store}
    func windowDidBecomeKey(_ notification:Notification){if notification.object as? NSWindow === window{PrecompositionWindows.active=nil}}
    @objc func importScript(){editingStore.importScriptFile()}
    @objc func showMainWindow(){window.makeKeyAndOrderFront(nil)}
    @objc func showRecovery(){store.workspaceWindows.show(.recovery)}
    @objc func showSettings(){store.workspaceWindows.show(.settings)}
    @objc func showWorkspaceSettings(){store.workspaceWindows.show(.workspaceSettings)}
    @objc func showMAD(){store.workspaceWindows.show(.mad)}
    @objc func showWorkspace(){store.workspaceWindows.show(.script)}
    @objc func newProject() {guard PrecompositionWindows.focused==nil else{return};store.newProject() }
    @objc func openProject() {guard PrecompositionWindows.focused==nil else{return};store.openProject() }
    @objc func saveProject() {if let session=PrecompositionWindows.focused{session.apply()}else{store.requestSave()} }
    @objc func saveAs() {if let session=PrecompositionWindows.focused{session.apply()}else{store.requestSave(asNew:true)} }
    @objc func importMedia() {editingStore.importMedia() }
    @objc func exportMovie() {editingStore.workspaceWindows.show(.export) }
    @objc func undoEdit() { EditUndoRouting.perform(redo:false,responder:NSApp.keyWindow?.firstResponder){editingStore.undo()} }
    @objc func redoEdit() { EditUndoRouting.perform(redo:true,responder:NSApp.keyWindow?.firstResponder){editingStore.redo()} }
    @objc func copyItems() {
        if let text=NSApp.keyWindow?.firstResponder as? NSTextView{text.copy(nil)}
        else{editingStore.reportEditing{try editingStore.copyClips()}}
    }
    @objc func pasteItems() {
        if let text=NSApp.keyWindow?.firstResponder as? NSTextView{text.paste(nil)}
        else{editingStore.reportEditing{try editingStore.pasteClips()}}
    }
    @objc func duplicate() {editingStore.duplicateSelection() }
    @objc func split() {editingStore.splitSelected() }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        guard !store.busy,let filename=filenames.first else {sender.reply(toOpenOrPrint:.cancel);return}
        store.requestDiscard {allowed in
            guard allowed else{sender.reply(toOpenOrPrint:.cancel);return}
            Task {let loaded=await self.store.loadProjectAsync(URL(fileURLWithPath:filename));sender.reply(toOpenOrPrint:loaded ? .success:.failure)}
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !store.busy,store.finishPendingPreviewText() else {return false}
        // With another workspace window open, closing the editor only hides it.
        // Keep the document dirty and accessible from the Window menu.
        if NSApp.windows.contains(where:{$0 !== sender && ($0.isVisible || $0.isMiniaturized)}) {return true}
        guard store.dirty else{return true}
        store.requestDiscard {allowed in Task {if allowed {self.store.dirty=false;sender.performClose(nil)}}}
        return false
    }
    func applicationWillTerminate(_ notification:Notification){controlMCP.stop()}
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if store.busy || !store.finishPendingPreviewText() || !store.precompositionWindows.closeAll() { return .terminateCancel }
        guard store.dirty else{return .terminateNow}
        // Defer the response even when the discard dialog responds synchronously.
        Task {self.store.requestDiscard {allowed in sender.reply(toApplicationShouldTerminate:allowed)}}
        return .terminateLater
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
