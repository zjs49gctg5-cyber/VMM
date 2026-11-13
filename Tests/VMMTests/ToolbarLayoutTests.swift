import XCTest
import SwiftUI
import AppKit
@testable import VMM

final class ToolbarLayoutTests: XCTestCase {
    func testToolbarSymbolsExist() {
        for name in ["doc.badge.plus", "folder", "square.and.arrow.down", "diamond.fill", "waveform", "list.bullet.rectangle", "books.vertical", "gearshape"] {
            XCTAssertNotNil(NSImage(systemSymbolName:name,accessibilityDescription:nil), "Missing toolbar symbol: \(name)")
        }
    }

    @MainActor func testToolbarDisplayModesInWindow() async throws {
        guard let output=testArtifactDirectory() else {throw XCTSkip("Opt-in toolbar UI verification")}
        try FileManager.default.createDirectory(atPath:output,withIntermediateDirectories:true)
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-toolbar-\(UUID())")
        let store=EditorStore(preferencesDirectory:root)
        store.settings.autosaveSeconds=0;store.autoSpeech=false
        defer{try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        _ = NSApplication.shared;NSApp.setActivationPolicy(.regular)
        for (name,mode,large) in [("combined",ToolbarDisplayMode.iconsAndLabels,false),("icons",.iconsOnly,false),("labels",.labelsOnly,false),("large",.iconsAndLabels,true)] {
            store.settings.toolbarDisplayMode=mode
            store.settings.uiFontSize=large ? 24:12;store.settings.uiIconSize=large ? 28:12;store.settings.uiScale=large ? 1.5:1;store.settings.toolbarIconScale=large ? 2:1.75
            let window=NSWindow(contentRect:NSRect(x:0,y:0,width:large ? 1060:1500,height:large ? 720:900),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
            window.title="VMM Toolbar QA — \(mode.rawValue)";window.isReleasedWhenClosed=false;window.appearance=NSAppearance(named:.darkAqua)
            let host=NSHostingView(rootView:EditorView(store:store));window.contentView=host;window.center();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
            host.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:300_000_000)
            let bitmap=try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds));host.cacheDisplay(in:host.bounds,to:bitmap)
            try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:URL(fileURLWithPath:output).appendingPathComponent("toolbar-\(name).png"))
            if ProcessInfo.processInfo.environment["VMM_TOOLBAR_HOLD"]=="1",mode == .iconsAndLabels {try await Task.sleep(nanoseconds:20_000_000_000)}
            window.close()
        }
    }
}
