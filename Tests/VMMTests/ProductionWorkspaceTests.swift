import XCTest
import SwiftUI
import AppKit
@testable import VMM

final class ProductionWorkspaceTests:XCTestCase {
    @MainActor func testNativeProductionPanelsInBothLanguages()async throws {
        guard let output=testArtifactDirectory() else{throw XCTSkip("Opt-in production panel snapshots")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-panels-\(UUID())"),store=EditorStore(preferencesDirectory:root)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(atPath:output,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        let originalLanguage=VMMLocalization.language;defer{VMMLocalization.language=originalLanguage}
        store.autoSpeech=false;store.settings.autosaveSeconds=0;store.settings.libraryPath=root.appendingPathComponent("Library").path;store.project=Project();store.project.width=320;store.project.height=180
        let clip=Clip(kind:.shape,name:"Sample",track:0,start:0,duration:1);store.project.clips=[clip];store.selectedID=clip.id
        _=try store.addProjectCharacter(name:"Actor")
        _=try await store.saveScene(name:"Sample scene")
        _=try await store.queueExport(to:root.appendingPathComponent("output.mp4"))
        for language in UILanguage.allCases {
            VMMLocalization.language=language
            let views:[(String,AnyView)]=[("characters",AnyView(CharacterWorkspace(store:store))),("queue",AnyView(ExportQueueView(queue:store.exportQueue))),("scenes",AnyView(SceneLibraryView(store:store)))]
            for (name,view) in views {
                let host=NSHostingView(rootView:view.padding(20).frame(width:900,height:520).background(Color.white).environment(\.colorScheme,.light)),window=NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:520),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
                window.isReleasedWhenClosed=false;window.appearance=NSAppearance(named:.aqua);host.appearance=NSAppearance(named:.aqua);window.contentView=host
                host.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:100_000_000)
                let bitmap=try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds));host.cacheDisplay(in:host.bounds,to:bitmap)
                XCTAssertGreaterThan(bitmap.pixelsWide,500)
                try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:URL(fileURLWithPath:output).appendingPathComponent("\(name)-\(language.rawValue).png"))
                window.close()
            }
        }
    }
}
