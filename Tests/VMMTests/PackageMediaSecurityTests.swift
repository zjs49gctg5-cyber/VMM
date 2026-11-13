import Foundation
import AppKit
import Darwin
import XCTest
@testable import VMM

final class PackageMediaSecurityTests:XCTestCase {
    func testProjectRejectsSymbolicLinkMediaFileAndDirectory() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-package-security-\(UUID())")
        let package=root.appendingPathComponent("test.vmm"),outside=root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at:package.appendingPathComponent("Media"),withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:outside,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        try Data("private".utf8).write(to:outside.appendingPathComponent("image.png"))
        var project=Project();project.assets=[MediaAsset(name:"image",file:"image.png",kind:.image,duration:1)]
        try JSONEncoder().encode(project).write(to:package.appendingPathComponent("project.json"))
        let file=package.appendingPathComponent("Media/image.png")
        try FileManager.default.createSymbolicLink(at:file,withDestinationURL:outside.appendingPathComponent("image.png"))
        func reject() {
            do {let (_,session)=try ProjectIO.read(package);try? FileManager.default.removeItem(at:session);XCTFail("Untrusted link was accepted")}
            catch { }
        }
        reject()
        try FileManager.default.removeItem(at:package.appendingPathComponent("Media"))
        try FileManager.default.createSymbolicLink(at:package.appendingPathComponent("Media"),withDestinationURL:outside)
        reject()
        try FileManager.default.removeItem(at:package.appendingPathComponent("Media"))
        try FileManager.default.createDirectory(at:package.appendingPathComponent("Media"),withIntermediateDirectories:true)
        try FileManager.default.createSymbolicLink(at:file,withDestinationURL:outside.appendingPathComponent("missing.png"))
        reject() // A dangling symlink is unsafe, not an ordinary missing asset.
        try FileManager.default.removeItem(at:file)
        XCTAssertEqual(mkfifo(file.path,0o600),0)
        reject() // Opening an untrusted FIFO must not block.
    }
    func testProjectAllowsRegularAndMissingMedia() throws {
        let package=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-package-regular-\(UUID()).vmm")
        try FileManager.default.createDirectory(at:package.appendingPathComponent("Media"),withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:package)}
        var project=Project();project.assets=[MediaAsset(name:"image",file:"image.png",kind:.image,duration:1),MediaAsset(name:"missing",file:"missing.png",kind:.image,duration:1)]
        try JSONEncoder().encode(project).write(to:package.appendingPathComponent("project.json"))
        let bytes=Data("regular media".utf8);try bytes.write(to:package.appendingPathComponent("Media/image.png"))
        let (loaded,session)=try ProjectIO.read(package)
        defer{try? FileManager.default.removeItem(at:session)}
        XCTAssertEqual(loaded.assets.count,2)
        XCTAssertEqual(try Data(contentsOf:session.appendingPathComponent("Media/image.png")),bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath:session.appendingPathComponent("Media/missing.png").path))
    }
    func testDirectorySwapDoesNotRedirectAnAlreadyOpenedPackage()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-package-swap-\(UUID())")
        let package=root.appendingPathComponent("test.vmm"),outside=root.appendingPathComponent("outside")
        let media=package.appendingPathComponent("Media"),original=package.appendingPathComponent("OriginalMedia")
        try FileManager.default.createDirectory(at:media,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:outside,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        try Data("package".utf8).write(to:media.appendingPathComponent("image.png"))
        try Data("outside".utf8).write(to:outside.appendingPathComponent("image.png"))
        let reader=try PackageMediaReader(package)
        try FileManager.default.moveItem(at:media,to:original)
        try FileManager.default.createSymbolicLink(at:media,withDestinationURL:outside)
        let copy=root.appendingPathComponent("copy.png")
        XCTAssertTrue(try reader.copyMedia("image.png",to:copy))
        XCTAssertEqual(try Data(contentsOf:copy),Data("package".utf8))
        try FileManager.default.removeItem(at:original.appendingPathComponent("image.png"))
        try FileManager.default.createSymbolicLink(at:original.appendingPathComponent("image.png"),withDestinationURL:outside.appendingPathComponent("image.png"))
        XCTAssertThrowsError(try reader.copyMedia("image.png",to:root.appendingPathComponent("second.png")))
    }
    func testProjectRejectsLinkedProjectJSON() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-project-link-\(UUID())")
        let package=root.appendingPathComponent("test.vmm")
        try FileManager.default.createDirectory(at:package,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let external=root.appendingPathComponent("project.json")
        try JSONEncoder().encode(Project()).write(to:external)
        try FileManager.default.createSymbolicLink(at:package.appendingPathComponent("project.json"),withDestinationURL:external)
        XCTAssertThrowsError(try ProjectIO.read(package))
    }
    func testRecoveryMetadataRejectsSymlinks() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-recovery-link-\(UUID())")
        let package=root.appendingPathComponent("recovery.vmm"),external=root.appendingPathComponent("record.json")
        try FileManager.default.createDirectory(at:package,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        try JSONEncoder().encode(RecoveryRecord(identity:"test",name:"test",date:Date(),missingFiles:0)).write(to:external)
        try FileManager.default.createSymbolicLink(at:package.appendingPathComponent("recovery.json"),withDestinationURL:external)
        XCTAssertNil(AutosaveWriter.metadata(package))
    }
    func testUserSelectedProjectMayBeALink()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-user-project-link-\(UUID())")
        let package=root.appendingPathComponent("real.vmm"),link=root.appendingPathComponent("selected.vmm")
        try FileManager.default.createDirectory(at:package,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        try JSONEncoder().encode(Project()).write(to:package.appendingPathComponent("project.json"))
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:package)
        let (_,session)=try ProjectIO.read(link)
        defer{try? FileManager.default.removeItem(at:session)}
        XCTAssertTrue(FileManager.default.fileExists(atPath:session.appendingPathComponent("Media").path))
    }
    @MainActor func testUserSelectedMediaLinkIsImportedAsRegularFile()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-user-media-link-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let store=EditorStore(preferencesDirectory:root.appendingPathComponent("prefs"));store.autoSpeech=false
        defer{try? FileManager.default.removeItem(at:store.directory);try? FileManager.default.removeItem(at:root)}
        let bitmap=try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:8,pixelsHigh:8,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
        let original=root.appendingPathComponent("original.png"),link=root.appendingPathComponent("selected.png")
        try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:original)
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:original)
        _=try await store.importURLs([link])
        let asset=try XCTUnwrap(store.project.assets.last),imported=store.directory.appendingPathComponent("Media").appendingPathComponent(asset.file)
        var info=stat();XCTAssertEqual(lstat(imported.path,&info),0);XCTAssertEqual(info.st_mode & S_IFMT,S_IFREG)
        let package=root.appendingPathComponent("saved.vmm")
        try ProjectPackage.write(store.project,media:store.directory.appendingPathComponent("Media"),to:package)
        let (_,session)=try ProjectIO.read(package);defer{try? FileManager.default.removeItem(at:session)}
        XCTAssertTrue(FileManager.default.fileExists(atPath:session.appendingPathComponent("Media").appendingPathComponent(asset.file).path))
    }
    @MainActor func testSharedImportRejectsSymlinksWithoutPartialFiles()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-shared-security-\(UUID())")
        let folder=root.appendingPathComponent("shared"),media=folder.appendingPathComponent("Media")
        try FileManager.default.createDirectory(at:media,withIntermediateDirectories:true)
        let store=EditorStore(preferencesDirectory:root.appendingPathComponent("prefs"));store.autoSpeech=false
        defer{try? FileManager.default.removeItem(at:store.directory);try? FileManager.default.removeItem(at:root)}
        let outside=root.appendingPathComponent("private.png")
        try Data("private".utf8).write(to:outside)
        try Data("first".utf8).write(to:media.appendingPathComponent("a.png"))
        try FileManager.default.createSymbolicLink(at:media.appendingPathComponent("b.png"),withDestinationURL:outside)
        var asset=MediaAsset(name:"shared",file:"a.png",kind:.image,duration:1);asset.proxyFile="b.png"
        let original=store.project
        XCTAssertThrowsError(try store.importShared(folder,asset:asset))
        XCTAssertEqual(store.project,original)
        XCTAssertFalse(FileManager.default.fileExists(atPath:store.directory.appendingPathComponent("Media/a.png").path))
    }
    @MainActor func testSharedAssetMetadataRejectsSymlinks()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-shared-metadata-\(UUID())")
        let folder=root.appendingPathComponent("shared")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let store=EditorStore(preferencesDirectory:root.appendingPathComponent("prefs"));store.autoSpeech=false
        defer{try? FileManager.default.removeItem(at:store.directory);try? FileManager.default.removeItem(at:root)}
        let external=root.appendingPathComponent("asset.json")
        try JSONEncoder().encode(MediaAsset(name:"image",file:"image.png",kind:.image,duration:1)).write(to:external)
        try FileManager.default.createSymbolicLink(at:folder.appendingPathComponent("asset.json"),withDestinationURL:external)
        XCTAssertThrowsError(try store.readSharedAsset(folder))
    }
}
