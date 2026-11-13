import XCTest
import AppKit
import AVFoundation
@testable import VMM

final class CharacterCaptionTests:XCTestCase {
    @MainActor func testTemplatesCaptionOnlyBatchFilterLockAndUndo()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-caption-\(UUID())"),store=EditorStore(preferencesDirectory:root)
        store.autoSpeech=false;store.project=Project()
        defer{try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        let a=try store.addProjectCharacter(name:"A"),b=try store.addProjectCharacter(name:"B")
        try store.setCharacterCaptionTemplate(.green,characterID:a);try store.setCharacterCaptionTemplate(.pink,characterID:b)
        try store.importScript("A：hello\nB：world\nA：again\nunassigned",track:1)
        XCTAssertEqual(CharacterCaptionQuery.clips(in:store.project,characterID:a).count,2)
        XCTAssertEqual(CharacterCaptionQuery.clips(in:store.project,unassigned:true).count,1)
        store.selectCharacterCaptions(a);XCTAssertEqual(store.selection.count,2)
        store.project.clips[0].speechDirty=false
        let old=store.project.clips
        try store.setCharacterCaptionTemplate(.blue,characterID:a)
        XCTAssertEqual(store.project.clips,old,"Changing the template must wait for explicit apply")
        try store.applyCharacterCaptions(a)
        XCTAssertEqual(store.project.clips[0].color,CharacterCaptionTemplate.blue.color)
        XCTAssertEqual(store.project.clips[2].color,CharacterCaptionTemplate.blue.color)
        XCTAssertEqual(store.project.clips[1],old[1]);XCTAssertEqual(store.project.clips[3],old[3])
        for (new,old) in zip(store.project.clips,old) {
            XCTAssertEqual(new.speakerID,old.speakerID);XCTAssertEqual(new.speechConfiguration,old.speechConfiguration)
            XCTAssertEqual(new.speechDirty,old.speechDirty);XCTAssertEqual(new.animation,old.animation);XCTAssertEqual(new.characterPresetID,old.characterPresetID)
        }
        store.undo();XCTAssertEqual(store.project.clips,old)
        store.project.tracks[1].locked=true;let locked=store.project
        XCTAssertThrowsError(try store.applyCharacterCaptions(a));XCTAssertEqual(store.project,locked)
        let api=EditorCommands();api.store=store
        XCTAssertEqual(try CommandTests().command(api,["command":"character.captionTemplate","characterID":a.uuidString,"template":"yellow"]).status,200)
        XCTAssertEqual(try CommandTests().command(api,["command":"character.applyCaptions","characterID":a.uuidString]).status,400)
        XCTAssertEqual(try CommandTests().command(api,["command":"character.captionTemplate","characterID":a.uuidString,"template":"invalid"]).status,400)
    }
    func testMouthAnimationSeparatesCharactersSharingOneVoice() {
        var project=Project();let a=UUID(),b=UUID()
        let asset=MediaAsset(name:"speech",file:"speech.wav",kind:.audio,duration:1,envelope:Array(repeating:0.3,count:30))
        var speech=Clip(kind:.speech,name:"A",track:0,start:0,duration:1)
        speech.assetID=asset.id;speech.speakerID=3;speech.characterPresetID=a;speech.speechDirty=false
        project.assets=[asset];project.clips=[speech]
        var portrait=Clip(kind:.image,name:"B",track:1,start:0,duration:1);portrait.characterSpeakerID=3;portrait.characterPresetID=b
        XCTAssertFalse(project.mouthIsOpen(for:portrait,at:0.5))
        portrait.characterPresetID=a;XCTAssertTrue(project.mouthIsOpen(for:portrait,at:0.5))
        portrait.characterPresetID=nil;XCTAssertTrue(project.mouthIsOpen(for:portrait,at:0.5),"Legacy portraits still use voice matching")
    }
    @MainActor func testMultiCharacterTemplatesPreviewSaveAndMP4()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-caption-render-\(UUID())"),store=EditorStore(preferencesDirectory:root)
        store.autoSpeech=false;store.project=Project();store.project.width=640;store.project.height=360
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        for (index,template) in CharacterCaptionTemplate.allCases.enumerated() {
            let id=try store.addProjectCharacter(name:template.rawValue)
            try store.setCharacterCaptionTemplate(template,characterID:id)
            let preset=try XCTUnwrap(store.project.characters?.last)
            var clip=Clip(kind:.text,name:template.rawValue,track:0,start:Double(index)*0.2,duration:0.2)
            clip.text="Caption";preset.apply(to:&clip);store.project.clips.append(clip)
        }
        let renderer=FrameRenderer(),white=try WorkflowTests().render(store.project,renderer:renderer,time:0.1),green=try WorkflowTests().render(store.project,renderer:renderer,time:0.3)
        XCTAssertNotEqual(white,green)
        let package=root.appendingPathComponent("captions.vmm")
        try ProjectPackage.write(store.project,media:store.directory.appendingPathComponent("Media"),to:package)
        let saved=try JSONDecoder().decode(Project.self,from:Data(contentsOf:package.appendingPathComponent("project.json")))
        XCTAssertEqual(saved.characters,store.project.characters)
        let movie=root.appendingPathComponent("captions.mp4")
        try await MovieExporter.export(project:store.project,directory:store.directory,destination:movie){_ in}
        let generator=AVAssetImageGenerator(asset:AVURLAsset(url:movie));generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
        let first=try generator.copyCGImage(at:CMTime(seconds:0.1,preferredTimescale:600),actualTime:nil)
        let second=try generator.copyCGImage(at:CMTime(seconds:0.3,preferredTimescale:600),actualTime:nil)
        XCTAssertEqual(first.width,640)
        XCTAssertNotEqual(NSBitmapImageRep(cgImage:first).representation(using:.png,properties:[:]),NSBitmapImageRep(cgImage:second).representation(using:.png,properties:[:]))
    }
}
