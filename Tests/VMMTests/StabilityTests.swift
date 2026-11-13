import XCTest
import AppKit
import Combine
@testable import VMM

final class StabilityTests:XCTestCase {
    func testRenderCacheEvictionBudgetAndOversizedValues() {
        let cache=RenderCache<String>(budget:10)
        cache.insert("A",key:"a",bytes:4);cache.insert("B",key:"b",bytes:4)
        XCTAssertEqual(cache.value("a"),"A")
        cache.insert("C",key:"c",bytes:4)
        XCTAssertNil(cache.value("b"));XCTAssertEqual(cache.bytes,8)
        cache.insert("Huge",key:"h",bytes:11);XCTAssertNil(cache.value("h"));XCTAssertEqual(cache.bytes,8)
        cache.budget=3;XCTAssertEqual(cache.bytes,0);XCTAssertEqual(cache.count,0)
        cache.clear();XCTAssertEqual(cache.bytes,0)
        let renderer=FrameRenderer();renderer.setCacheBudget(megabytes:16)
        XCTAssertEqual(renderer.cacheUsage.budget,16*1024*1024)
    }
    @MainActor func testPlaybackDoesNotInvalidateWholeEditor()throws {
        let prefs=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-clock-\(UUID())")
        let store=EditorStore(preferencesDirectory:prefs)
        defer{try? FileManager.default.removeItem(at:prefs);try? FileManager.default.removeItem(at:store.directory)}
        store.playing=true
        var editorChanges=0,clockChanges=0
        let editor=store.objectWillChange.sink{editorChanges+=1},clock=store.playbackClock.objectWillChange.sink{clockChanges+=1}
        for i in 0..<100 {store.playhead=Double(i)/30}
        XCTAssertEqual(editorChanges,0);XCTAssertEqual(clockChanges,100)
        store.pause();let before=editorChanges;store.seek(4)
        XCTAssertGreaterThan(editorChanges,before);XCTAssertEqual(store.playhead,4)
        withExtendedLifetime((editor,clock)){}
    }
    @MainActor func testBackgroundAutosaveAndIndependentMediaSnapshot()async throws {
        let prefs=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-autosave-\(UUID())")
        let store=EditorStore(preferencesDirectory:prefs),folder=prefs.appendingPathComponent("Recovery")
        defer{try? FileManager.default.removeItem(at:prefs);try? FileManager.default.removeItem(at:store.directory)}
        let media=store.directory.appendingPathComponent("Media/test.bin"),original=Data(repeating:42,count:2*1024*1024)
        try original.write(to:media);store.project.assets=[MediaAsset(name:"test",file:"test.bin",kind:.image,duration:1)]
        store.settings.autosavePath=folder.path;store.dirty=true
        let snapshot=store.project;store.scheduleAutosave();store.scheduleAutosave()
        store.project.name="Edited during save"
        let limit=ProcessInfo.processInfo.systemUptime+10
        while store.autosaveTask != nil && ProcessInfo.processInfo.systemUptime<limit {try await Task.sleep(nanoseconds:10_000_000)}
        let files=store.recoveryFiles();XCTAssertEqual(files.count,1)
        let saved=try XCTUnwrap(files.first)
        XCTAssertEqual(try JSONDecoder().decode(Project.self,from:Data(contentsOf:saved.appendingPathComponent("project.json"))),snapshot)
        try Data([1,2,3]).write(to:media)
        XCTAssertEqual(try Data(contentsOf:saved.appendingPathComponent("Media/test.bin")),original)
        XCTAssertEqual(store.project.name,"Edited during save")
    }

}
