import XCTest
import AppKit
import SwiftUI
@testable import VMM

final class SettingsOrganizationTests:XCTestCase {
    @MainActor func testRecoveryAndSettingsHaveDistinctDestinations()throws {
        XCTAssertFalse(WorkspacePage.productionPages.contains(.recovery))
        XCTAssertEqual(WorkspaceWindowController.Kind.destination(for:.recovery),.settings)
        XCTAssertEqual(WorkspaceWindowController.Kind.destination(for:.workspaceSettings),.workspaceSettings)
        XCTAssertEqual(WorkspaceWindowController.Kind.destination(for:.export),.export)
        for page in WorkspacePage.productionPages {XCTAssertEqual(WorkspaceWindowController.Kind.destination(for:page),.production)}
        let old=UserSettings();let decoded=try JSONDecoder().decode(UserSettings.self,from:JSONEncoder().encode(old));XCTAssertEqual(old,decoded)
        XCTAssertTrue(SettingsTab.allCases.contains(.recovery));XCTAssertTrue(WorkspaceSettingsTab.allCases.contains(.appearance))
    }
    @MainActor func testSettingsTabsNativeLayout()async throws {
        guard let output=testArtifactDirectory() else{throw XCTSkip("Opt-in settings panel snapshots")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-settings-panels-\(UUID())"),store=EditorStore(preferencesDirectory:root)
        store.settings.autosaveSeconds=0;store.settings.autosavePath=root.appendingPathComponent("Recovery").path;store.settings.libraryPath=root.appendingPathComponent("Library").path
        defer{try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        try FileManager.default.createDirectory(atPath:output,withIntermediateDirectories:true)
        let original=VMMLocalization.language;defer{VMMLocalization.language=original}
        let project=store.project,settings=store.settings
        for language in UILanguage.allCases {
            VMMLocalization.language=language
            for tab in SettingsTab.allCases {
                store.settingsTab=tab
                try await capture(AnyView(SettingsWorkspace(store:store)),name:"settings-\(tab)-\(language.rawValue)",output:output)
            }
            for tab in WorkspaceSettingsTab.allCases {
                store.workspaceSettingsTab=tab
                try await capture(AnyView(WorkspaceSettingsView(store:store)),name:"workspace-\(tab)-\(language.rawValue)",output:output)
            }
            try await capture(AnyView(WorkspaceView(store:store,selection:WorkspaceSelection())),name:"production-\(language.rawValue)",output:output)
        }
        XCTAssertEqual(store.project,project);XCTAssertEqual(store.settings,settings)
    }
    @MainActor private func capture(_ view:AnyView,name:String,output:String)async throws {
        let host=NSHostingView(rootView:view.frame(width:900,height:700).background(Color.white).environment(\.colorScheme,.light))
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:700),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.appearance=NSAppearance(named:.aqua);host.appearance=NSAppearance(named:.aqua);window.contentView=host;defer{window.close()}
        host.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:100_000_000)
        let bitmap=try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds));host.cacheDisplay(in:host.bounds,to:bitmap)
        try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:URL(fileURLWithPath:output).appendingPathComponent(name+".png"))
    }
}
