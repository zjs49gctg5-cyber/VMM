import XCTest
import AVFoundation
import AppKit
@testable import VMM
final class SceneLibraryTests:XCTestCase {
    @MainActor func testSceneSaveInsertRemapsLinksGroupsAndActualRender()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-scene-\(UUID())"),s=EditorStore(preferencesDirectory:root)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);s.autoSpeech=false;s.project=Project();s.project.width=320;s.project.height=180
        defer{try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:s.directory)}
        var shape=Clip(kind:.shape,name:"shape",track:0,start:2,duration:0.3);shape.color="33CC77";shape.x=0.35;shape.scale=0.6
        var caption=Clip(kind:.text,name:"caption",track:1,start:2,duration:0.3);caption.text="Scene";caption.fontSize=32;caption.y=0.8
        s.project.clips=[shape,caption];s.selectedIDs=Set(s.project.clips.map(\.id));s.selectedID=shape.id
        let before=try WorkflowTests().render(s.project,time:2.1)
        let package=try await s.saveScene(name:"Saved scene",to:root.appendingPathComponent("scene.vmm"))
        s.project.clips=[];let group=try await s.insertScene(package,at:0)
        XCTAssertEqual(s.project.clips.count,3);XCTAssertEqual(s.project.descendants(of:group).count,2)
        XCTAssertEqual(try WorkflowTests().render(s.project,time:0.1),before)
        let movie=root.appendingPathComponent("scene.mp4");try await MovieExporter.export(project:s.project,directory:s.directory,destination:movie){_ in}
        let frame=NSBitmapImageRep(cgImage:try AVAssetImageGenerator(asset:AVURLAsset(url:movie)).copyCGImage(at:.zero,actualTime:nil))
        XCTAssertEqual(frame.pixelsWide,320)
        let color=try XCTUnwrap(frame.colorAt(x:112,y:90)?.usingColorSpace(.sRGB));XCTAssertGreaterThan(color.greenComponent,0.65);XCTAssertLessThan(color.redComponent,0.3)
        s.edit(group){$0.start=5};XCTAssertEqual(Set(s.project.clips.map(\.start)),[5])
        s.duplicateSelected();XCTAssertEqual(s.project.clips.count,6);_=try s.project.validated()
        s.deleteSelected();XCTAssertEqual(s.project.clips.count,3);s.undo();XCTAssertEqual(s.project.clips.count,6)
        let current=s.selected?.id ?? group;s.selectedID=current
        try s.dissolveScene(current);_=try s.project.validated()
    }
    func testCompoundAdjustmentsStayIsolatedAndOwnershipRejectsCycles()throws {
        var p=Project();p.width=320;p.height=180
        var image=Clip(kind:.shape,name:"background",track:0,start:0,duration:1);image.color="112233"
        var child=Clip(kind:.shape,name:"child",track:1,start:0,duration:1);child.color="88AAFF"
        var adjustment=Clip(kind:.adjustment,name:"mosaic",track:2,start:0,duration:1);adjustment.effects=[VisualEffect(kind:.pixelate)]
        var group=Clip(kind:.group,name:"Scene",track:3,start:0,duration:1);group.sceneMembers=[child.id,adjustment.id];child.parentID=group.id
        p.clips=[image,child,adjustment,group];_=try p.validated()
        let withEffect=try WorkflowTests().render(p,time:0.2);p.clips[2].effects=[];let without=try WorkflowTests().render(p,time:0.2)
        XCTAssertNotEqual(withEffect,without)
        p.clips[3].sceneMembers=[group.id];XCTAssertThrowsError(try p.validated())
    }
    @MainActor func testSceneImportsMediaWithUniqueFilenamesAndProfileReferences()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-scene-media-\(UUID())"),s=EditorStore(preferencesDirectory:root)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);s.autoSpeech=false;s.project=Project()
        defer{try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:s.directory)}
        try Data("media fixture".utf8).write(to:s.directory.appendingPathComponent("Media/file.png"))
        let asset=MediaAsset(name:"asset",file:"file.png",kind:.image,duration:0);s.project.assets=[asset]
        var clip=Clip(kind:.image,name:"image",track:0,start:0,duration:1);clip.assetID=asset.id
        let id=try s.addProjectCharacter(name:"Actor");var preset=s.project.characters![0];preset.portraitAssetID=asset.id;try s.updateProjectCharacter(preset);clip.characterPresetID=id
        s.project.clips=[clip];s.selectedID=clip.id
        let url=try await s.saveScene(name:"Media",to:root.appendingPathComponent("media.vmm"))
        _=try await s.insertScene(url,at:2)
        XCTAssertEqual(s.project.assets.count,2);XCTAssertEqual(Set(s.project.assets.map(\.file)).count,2)
        let imported=try XCTUnwrap(s.project.characters?.last);XCTAssertNotEqual(imported.id,id);XCTAssertNotEqual(imported.portraitAssetID,asset.id)
        XCTAssertEqual(try Data(contentsOf:s.directory.appendingPathComponent("Media").appendingPathComponent(s.project.assets.last!.file)),Data("media fixture".utf8))
        _=try s.project.validated()
    }
}
