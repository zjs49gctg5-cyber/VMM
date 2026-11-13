import XCTest
import AppKit
import AVFoundation
@testable import VMM
final class ProjectCharacterTests:XCTestCase {
    @MainActor func testProjectCharactersScriptAssignmentApplyAndUndo()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-char-\(UUID())"),s=EditorStore(preferencesDirectory:root)
        s.autoSpeech=false;s.project=Project();defer{try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:s.directory)}
        let id=try s.addProjectCharacter(name:"ずんだもん")
        var character=try XCTUnwrap(s.project.characters?.first);character.speakerID=3;character.color="22CC55";character.speechConfiguration = .defaults(.aivisSpeech);try s.updateProjectCharacter(character)
        try s.importScript("ずんだもん：こんにちは",track:1)
        let clip=try XCTUnwrap(s.project.clips.first);XCTAssertEqual(clip.characterPresetID,id);XCTAssertEqual(clip.color,"22CC55");XCTAssertEqual(clip.speechConfiguration?.engine,.aivisSpeech)
        character.color="FF0000";try s.updateProjectCharacter(character);XCTAssertEqual(s.project.clips[0].color,"22CC55")
        try s.applyProjectCharacter(id,toAll:true);XCTAssertEqual(s.project.clips[0].color,"FF0000");s.undo();XCTAssertEqual(s.project.clips[0].color,"22CC55")
        s.project.tracks[1].locked=true;let before=s.project;XCTAssertThrowsError(try s.applyProjectCharacter(id,toAll:true));XCTAssertEqual(s.project,before)
        let roundTrip=try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(s.project));XCTAssertEqual(try roundTrip.validated(),s.project)
        var old=Project();old.characters=nil;XCTAssertNil(try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(old)).characters)
    }
    @MainActor func testPortraitAssetsProtectedAndPreviewMP4()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-char-render-\(UUID())"),s=EditorStore(preferencesDirectory:root)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        s.autoSpeech=false;s.project=Project();s.project.width=320;s.project.height=180
        defer{try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:s.directory)}
        let bitmap=try XCTUnwrap(RasterTools.bitmap(CGSize(width:32,height:32)));bitmap.setFillColor(NSColor.green.cgColor);bitmap.fill(CGRect(x:0,y:0,width:32,height:32))
        let image=NSBitmapImageRep(cgImage:try XCTUnwrap(bitmap.makeImage()));try XCTUnwrap(image.representation(using:.png,properties:[:])).write(to:s.directory.appendingPathComponent("Media/portrait.png"))
        let asset=MediaAsset(name:"portrait",file:"portrait.png",kind:.image,duration:0);s.project.assets=[asset]
        let id=try s.addProjectCharacter(name:"Character");var value=s.project.characters![0];value.portraitAssetID=asset.id;value.portraitX=0.3;value.portraitScale=0.5;try s.updateProjectCharacter(value)
        s.removeUnusedMedia();XCTAssertEqual(s.project.assets.count,1)
        let clipID=try s.placePortrait(id);s.edit(clipID){$0.duration=0.2}
        XCTAssertEqual(s.selected?.characterSpeakerID,value.speakerID);XCTAssertEqual(s.selected?.x,0.3)
        _=try WorkflowTests().render(s.project)
        let movie=root.appendingPathComponent("portrait.mp4");try await MovieExporter.export(project:s.project,directory:s.directory,destination:movie){_ in}
        let generator=AVAssetImageGenerator(asset:AVURLAsset(url:movie));XCTAssertEqual(try generator.copyCGImage(at:.zero,actualTime:nil).width,320)
        let package=root.appendingPathComponent("character.vmm");try ProjectPackage.write(s.project,media:s.directory.appendingPathComponent("Media"),to:package)
        let reopened=await s.loadProjectAsync(package);XCTAssertTrue(reopened);XCTAssertEqual(s.project.characters?.first?.portraitAssetID,asset.id)
    }
}
