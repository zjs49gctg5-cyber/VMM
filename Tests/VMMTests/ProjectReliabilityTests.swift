import XCTest
@testable import VMM

final class ProjectReliabilityTests:XCTestCase {
    @MainActor func testAsyncSaveLoadAndFailurePreserveDocument()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-io-test-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let store=EditorStore(preferencesDirectory:root);store.autoSpeech=false
        defer{try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        let media=Data(repeating:45,count:2*1024*1024)
        try media.write(to:store.directory.appendingPathComponent("Media/fixture.bin"))
        store.project.assets=[MediaAsset(name:"fixture",file:"fixture.bin",kind:.image,duration:1)]
        store.dirty=true
        let path=root.appendingPathComponent("Saved.vmm")
        let saved=await store.saveProject(to:path);XCTAssertTrue(saved,store.error ?? "")
        XCTAssertFalse(store.busy);XCTAssertNil(store.projectIOProgress);XCTAssertFalse(store.dirty)
        let previous=try Data(contentsOf:path.appendingPathComponent("project.json"))
        store.project.assets.append(MediaAsset(name:"missing",file:"missing.bin",kind:.image,duration:1));store.dirty=true
        let failed=await store.saveProject(to:path);XCTAssertFalse(failed);XCTAssertTrue(store.dirty)
        XCTAssertEqual(try Data(contentsOf:path.appendingPathComponent("project.json")),previous)
        let source=store.directory
        let loaded=await store.loadProjectAsync(path);XCTAssertTrue(loaded,store.error ?? "")
        XCTAssertEqual(store.project.name,"Saved");XCTAssertEqual(try Data(contentsOf:store.directory.appendingPathComponent("Media/fixture.bin")),media)
        XCTAssertFalse(FileManager.default.fileExists(atPath:source.path))
        let current=store.project,folder=store.directory
        let invalid=await store.loadProjectAsync(root.appendingPathComponent("not-there.vmm"));XCTAssertFalse(invalid)
        XCTAssertEqual(store.project,current);XCTAssertEqual(store.directory,folder)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).allSatisfy{!$0.lastPathComponent.hasPrefix(".vmm-package-")})
    }
    @MainActor func testProjectSwitchKeepsAutosaveSourceUntilComplete()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-switch-test-\(UUID())")
        let store=EditorStore(preferencesDirectory:root);store.autoSpeech=false
        defer{try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        let source=store.directory,bytes=Data(repeating:76,count:1024*1024)
        try bytes.write(to:source.appendingPathComponent("Media/source.bin"))
        store.project.assets=[MediaAsset(name:"source",file:"source.bin",kind:.image,duration:1)]
        store.settings.autosavePath=root.appendingPathComponent("Recovery").path;store.dirty=true
        let snapshot=store.project
        store.scheduleAutosave()
        let next=root.appendingPathComponent("new-session")
        try FileManager.default.createDirectory(at:next.appendingPathComponent("Media"),withIntermediateDirectories:true)
        // Reset before the autosave task gets its first actor turn: a deterministic race.
        store.reset(to:Project(),directory:next,savedURL:nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath:source.path))
        await store.autosaveTask?.value
        XCTAssertFalse(FileManager.default.fileExists(atPath:source.path))
        let backup=try XCTUnwrap(store.recoveryFiles().first)
        XCTAssertEqual(try Data(contentsOf:backup.appendingPathComponent("Media/source.bin")),bytes)
        XCTAssertEqual(try JSONDecoder().decode(Project.self,from:Data(contentsOf:backup.appendingPathComponent("project.json"))),snapshot)
    }
    func testRecoveryRetentionIsPerDocumentAndLegacyRemains()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-history-test-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        var a=Project();a.name="A";var b=Project();b.name="B"
        let legacy=root.appendingPathComponent("Autosave-legacy.vmm")
        try ProjectPackage.write(a,media:root,to:legacy)
        for _ in 0..<3 {_=try AutosaveWriter.write(a,media:root,folder:root,keep:2,identity:"project-A")}
        for _ in 0..<3 {_=try AutosaveWriter.write(b,media:root,folder:root,keep:2,identity:"project-B")}
        let entries=AutosaveWriter.entries(in:root)
        XCTAssertEqual(entries.count,5);XCTAssertEqual(entries.filter{$0.record.identity=="project-A"}.count,2)
        XCTAssertEqual(entries.filter{$0.record.identity=="project-B"}.count,2);XCTAssertTrue(FileManager.default.fileExists(atPath:legacy.path))
        a.assets=[MediaAsset(name:"missing",file:"absent.bin",kind:.image,duration:1)]
        let missing=try AutosaveWriter.write(a,media:root,folder:root,keep:2,identity:"project-A")
        XCTAssertEqual(AutosaveWriter.metadata(missing)?.missingFiles,1)
    }
    func testFreeSpacePreflight()throws {
        let root=FileManager.default.temporaryDirectory
        XCTAssertThrowsError(try ProjectIO.preflight(files:[],destination:root,availableCapacity:1))
        XCTAssertNoThrow(try ProjectIO.preflight(files:[],destination:root,availableCapacity:2_000_000))
    }
}
