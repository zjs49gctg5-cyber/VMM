import XCTest
import AppKit
@testable import VMM

final class DetachedPanelTests:XCTestCase {
    func testLegacyPreferencesAndIndependentLayoutRoundTrip()throws {
        var json=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(UserSettings())) as? [String:Any])
        for panel in EditorPanel.allCases {json.removeValue(forKey: "detached"+panel.rawValue.prefix(1).uppercased()+panel.rawValue.dropFirst())}
        var legacy=try JSONDecoder().decode(UserSettings.self,from:JSONSerialization.data(withJSONObject:json))
        XCTAssertTrue(EditorPanel.embeddedTopPanels(in:legacy))
        for panel in EditorPanel.allCases {XCTAssertFalse(panel.isDetached(in:legacy));panel.setDetached(true,in:&legacy)}
        XCTAssertFalse(EditorPanel.embeddedTopPanels(in:legacy))
        legacy.showLibrary=false;legacy.showInspector=false
        let restored=try JSONDecoder().decode(UserSettings.self,from:JSONEncoder().encode(legacy))
        XCTAssertEqual(restored,legacy);XCTAssertFalse(EditorPanel.library.isVisible(in:restored));XCTAssertTrue(EditorPanel.timeline.isVisible(in:restored))
        EditorPanel.preview.setDetached(false,in:&legacy);XCTAssertTrue(EditorPanel.embeddedTopPanels(in:legacy))
        XCTAssertTrue(EditorPanel.timeline.isDetached(in:legacy))
    }
    @MainActor func testAPISettingsPersistWithoutOpeningWindowsOrChangingProject()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-detached-\(UUID())")
        let store=EditorStore(preferencesDirectory:root),api=EditorCommands();api.store=store;store.autoSpeech=false;store.settings.autosaveSeconds=0
        defer{try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        let before=store.project,selected=store.selectedID
        let request:[String:Any]=["command":"settings.update","properties":["detachedTimeline":true,"detachedInspector":true,"detachedPreview":true,"detachedLibrary":true,"detachedAnimation":true]]
        XCTAssertEqual(api.execute(body:try JSONSerialization.data(withJSONObject:request)).status,200)
        XCTAssertTrue(store.panelWindows.windows.isEmpty)
        XCTAssertEqual(store.project,before);XCTAssertEqual(store.selectedID,selected)
        let saved=try JSONDecoder().decode(UserSettings.self,from:Data(contentsOf:root.appendingPathComponent("settings.json")))
        for panel in EditorPanel.allCases {XCTAssertTrue(panel.isDetached(in:saved))}
        let invalid:[String:Any]=["command":"settings.update","properties":["detachedTimeline":"invalid"]]
        XCTAssertEqual(api.execute(body:try JSONSerialization.data(withJSONObject:invalid)).status,400)
        XCTAssertEqual(store.settings,saved)
    }
    @MainActor func testNativePanelLifecycleAndCloseReattachesWithoutEditing()async throws {
        _=NSApplication.shared
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-panel-lifecycle-\(UUID())")
        let store=EditorStore(preferencesDirectory:root);store.autoSpeech=false;store.settings.autosaveSeconds=0
        let controller=store.panelWindows,before=store.project
        let mainWindow=NSWindow(contentRect:NSRect(x:0,y:0,width:600,height:400),styleMask:[.titled,.closable],backing:.buffered,defer:false);mainWindow.isReleasedWhenClosed=false
        controller.start(mainWindow:mainWindow)
        store.dirty=true
        defer {
            for panel in EditorPanel.allCases {panel.setDetached(false,in:&store.settings)}
            controller.synchronize();mainWindow.close()
            try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)
        }
        for panel in EditorPanel.allCases {panel.setDetached(true,in:&store.settings)}
        controller.synchronize();XCTAssertEqual(controller.windows.count,5)
        for panel in EditorPanel.allCases {
            let window=try XCTUnwrap(controller.windows[panel])
            XCTAssertTrue(window.styleMask.contains(.resizable));XCTAssertNotNil(window.contentView)
            XCTAssertTrue(controller.contains(window))
        }
        if let output=testArtifactDirectory() {
            try FileManager.default.createDirectory(atPath:output,withIntermediateDirectories:true)
            try await Task.sleep(nanoseconds:300_000_000)
            for panel in [EditorPanel.preview,.animation] {
                let window=try XCTUnwrap(controller.windows[panel]),view=try XCTUnwrap(window.contentView)
                view.layoutSubtreeIfNeeded();let bitmap=try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds));view.cacheDisplay(in:view.bounds,to:bitmap)
                try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:URL(fileURLWithPath:output).appendingPathComponent("detached-\(panel.rawValue).png"))
            }
        }
        let preview=try XCTUnwrap(controller.windows[.preview])
        preview.setContentSize(NSSize(width:720,height:460));XCTAssertEqual(preview.contentView?.frame.width,720)
        let savedFrame=preview.frame
        EditorPanel.preview.setDetached(false,in:&store.settings);controller.synchronize()
        XCTAssertNil(preview.contentView)
        EditorPanel.preview.setDetached(true,in:&store.settings);controller.synchronize()
        let restoredPreview=try XCTUnwrap(controller.windows[.preview])
        XCTAssertEqual(restoredPreview.frame,savedFrame)
        store.selectedID=store.project.clips.last?.id;store.seek(1)
        let selection=store.selectedID
        store.settings.showLibrary=false;controller.synchronize()
        XCTAssertNil(controller.windows[.library]);XCTAssertTrue(EditorPanel.library.isDetached(in:store.settings))
        store.settings.showLibrary=true;controller.synchronize();XCTAssertNotNil(controller.windows[.library])
        let timeline=try XCTUnwrap(controller.windows[.timeline])
        timeline.performClose(nil);controller.synchronize()
        XCTAssertFalse(EditorPanel.timeline.isDetached(in:store.settings));XCTAssertNil(controller.windows[.timeline])
        XCTAssertNil(timeline.contentView) // No hidden duplicate rendering when reattached.
        XCTAssertEqual(controller.windows.count,4);XCTAssertEqual(store.project,before)
        let animation=try XCTUnwrap(controller.windows[.animation])
        animation.performClose(nil);controller.synchronize()
        XCTAssertFalse(EditorPanel.animation.isDetached(in:store.settings));XCTAssertTrue(store.showAnimationPanel)
        XCTAssertNil(controller.windows[.animation]);XCTAssertEqual(controller.windows.count,3)
        XCTAssertTrue(mainWindow.isVisible);XCTAssertTrue(store.dirty)
        XCTAssertEqual(store.selectedID,selection);XCTAssertEqual(store.playhead,1)
    }

}
