import XCTest
@testable import VMM

final class PreferenceProtectionTests:XCTestCase {
    @MainActor func testCorruptPreferencesAreReportedAndPreserved() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-preferences-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let settingsURL=root.appendingPathComponent("settings.json"),catalogURL=root.appendingPathComponent("catalog.json")
        let brokenSettings=Data("{broken-settings".utf8),brokenCatalog=Data("{broken-catalog".utf8)
        try brokenSettings.write(to:settingsURL);try brokenCatalog.write(to:catalogURL)
        let store=EditorStore(preferencesDirectory:root)
        defer{try? FileManager.default.removeItem(at:store.directory)}
        XCTAssertEqual(store.protectedPreferences,["settings.json","catalog.json"])
        XCTAssertTrue(store.error?.contains("settings.json") == true)
        XCTAssertTrue(store.error?.contains("catalog.json") == true)
        store.settings.uiLanguage = .english;store.persistSettings()
        store.persistCatalog()
        XCTAssertEqual(try Data(contentsOf:settingsURL),brokenSettings)
        XCTAssertEqual(try Data(contentsOf:catalogURL),brokenCatalog)
        XCTAssertThrowsError(try store.writePreferences(store.settings,file:"settings.json"))
        XCTAssertThrowsError(try store.writePreferences(store.catalog,file:"catalog.json"))
    }
    @MainActor func testMCPRejectsProtectedPreferenceWritesWithoutMutatingState() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-preferences-mcp-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let settingsURL=root.appendingPathComponent("settings.json"),catalogURL=root.appendingPathComponent("catalog.json")
        let settingsData=Data("{broken-settings".utf8),catalogData=Data("{broken-catalog".utf8)
        try settingsData.write(to:settingsURL);try catalogData.write(to:catalogURL)
        let store=EditorStore(preferencesDirectory:root),api=EditorCommands();api.store=store;store.autoSpeech=false
        defer{try? FileManager.default.removeItem(at:store.directory)}
        let settings=store.settings,catalog=store.catalog,project=store.project
        let requests:[[String:Any]]=[
            ["command":"settings.update","properties":["uiFontSize":20]],
            ["command":"export.template","template":"youtube1080"],
            ["command":"dictionary.set","entries":[]],
            ["command":"character.capture","name":"テスト"]
        ]
        for request in requests {
            let result=try CommandTests().command(api,request)
            XCTAssertEqual(result.status,400,"Expected error for \(request)")
        }
        XCTAssertEqual(store.settings,settings);XCTAssertEqual(store.catalog,catalog);XCTAssertEqual(store.project,project)
        XCTAssertEqual(try Data(contentsOf:settingsURL),settingsData);XCTAssertEqual(try Data(contentsOf:catalogURL),catalogData)
    }
    @MainActor func testMissingAndValidPreferencesRemainWritable() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-preferences-\(UUID())")
        defer{try? FileManager.default.removeItem(at:root)}
        let store=EditorStore(preferencesDirectory:root)
        defer{try? FileManager.default.removeItem(at:store.directory)}
        XCTAssertTrue(store.protectedPreferences.isEmpty);XCTAssertNil(store.error)
        store.persistSettings();store.persistCatalog()
        XCTAssertNil(store.error)
        let loaded=EditorStore(preferencesDirectory:root)
        defer{try? FileManager.default.removeItem(at:loaded.directory)}
        XCTAssertTrue(loaded.protectedPreferences.isEmpty);XCTAssertNil(loaded.error)
    }
}
