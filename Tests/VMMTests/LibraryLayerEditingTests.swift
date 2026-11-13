import XCTest
@testable import VMM

@MainActor final class LibraryLayerEditingTests:XCTestCase {
    func store()throws->EditorStore {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-library-layer-\(UUID())")
        let store=EditorStore(preferencesDirectory:root);store.autoSpeech=false
        let session=store.directory
        addTeardownBlock{try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:session)}
        return store
    }
    func testLayerDeletionRemapsSurvivorsAndProtectsChildrenLocksAndUndo()throws {
        let s=try store();s.project.tracks=[Track(name:"A"),Track(name:"B"),Track(name:"C")]
        let parent=Clip(kind:.group,name:"parent",track:1,start:0,duration:1)
        var child=Clip(kind:.shape,name:"child",track:2,start:0,duration:1);child.parentID=parent.id
        let survivor=Clip(kind:.text,name:"keep",track:2,start:0,duration:1,text:"keep")
        s.project.clips=[parent,child,survivor];s.selectedTrack=2;s.selectedID=parent.id
        let initial=s.project
        XCTAssertThrowsError(try s.deleteTrack(1));XCTAssertEqual(s.project,initial)
        s.project.tracks[2].locked=true;let locked=s.project
        XCTAssertThrowsError(try s.deleteTrack(1,deleteItems:true));XCTAssertEqual(s.project,locked)
        s.project=initial;try s.deleteTrack(1,deleteItems:true)
        XCTAssertEqual(s.project.tracks.map(\.name),["A","C"]);XCTAssertEqual(s.project.clips.map(\.id),[survivor.id]);XCTAssertEqual(s.project.clips[0].track,1);XCTAssertEqual(s.selectedTrack,1);XCTAssertNil(s.selectedID)
        _=try s.project.validated();s.undo();XCTAssertEqual(s.project,initial)
        s.selectedTrack=2;s.redo();XCTAssertEqual(s.selectedTrack,1);_=try s.project.validated()
        s.project.clips=[];try s.deleteTrack(0);let last=s.project
        XCTAssertThrowsError(try s.deleteTrack(0));XCTAssertEqual(s.project,last)
    }
    func testMediaDeletionIncludesMaskMouthAndDescendantsPreservesFilesAndUndo()throws {
        let s=try store(),asset=MediaAsset(name:"fixture",file:"fixture.png",kind:.image,duration:1)
        let file=s.directory.appendingPathComponent("Media/fixture.png");try Data("fixture".utf8).write(to:file)
        var source=Clip(kind:.image,name:"source",track:0,start:0,duration:1);source.assetID=asset.id
        var child=Clip(kind:.shape,name:"child",track:1,start:0,duration:1);child.parentID=source.id
        var mouth=Clip(kind:.image,name:"mouth",track:1,start:0,duration:1);mouth.mouthAssetID=asset.id
        var masked=Clip(kind:.shape,name:"mask",track:1,start:0,duration:1);var mask=ClipMask();mask.kind = .image;mask.assetID=asset.id;masked.masks=[mask]
        s.project.assets=[asset];s.project.clips=[source,child,mouth,masked];let initial=s.project
        XCTAssertThrowsError(try s.deleteMedia(asset.id));XCTAssertEqual(s.project,initial)
        XCTAssertEqual(s.mediaDeletionIDs(asset.id).count,4)
        s.project.tracks[1].locked=true;let locked=s.project
        XCTAssertThrowsError(try s.deleteMedia(asset.id,deleteItems:true));XCTAssertEqual(s.project,locked)
        s.project=initial;try s.deleteMedia(asset.id,deleteItems:true)
        XCTAssertTrue(s.project.assets.isEmpty);XCTAssertTrue(s.project.clips.isEmpty);XCTAssertEqual(try Data(contentsOf:file),Data("fixture".utf8))
        s.undo();XCTAssertEqual(s.project,initial)
    }
    func testToolbarOptionalCompatibilityAndAPIValidation()throws {
        var settings=UserSettings();let decoded=try JSONDecoder().decode(UserSettings.self,from:JSONEncoder().encode(settings));XCTAssertNil(decoded.toolbarLabels);XCTAssertNil(decoded.toolbarIconScale);XCTAssertNil(decoded.toolbarDisplayMode);XCTAssertEqual(decoded.toolbarMode,.iconsAndLabels)
        settings.toolbarIconScale=0.5;_=try settings.validated();settings.toolbarIconScale=0.49;XCTAssertThrowsError(try settings.validated());settings.toolbarIconScale=1.5;_=try settings.validated();settings.toolbarIconScale=2;_=try settings.validated();settings.toolbarIconScale=2.01;XCTAssertThrowsError(try settings.validated())
        let s=try store(),api=EditorCommands();api.store=s
        func command(_ body:[String:Any])throws->ControlResult{api.execute(body:try JSONSerialization.data(withJSONObject:body))}
        XCTAssertEqual(try command(["command":"settings.update","properties":["toolbarLabels":false,"toolbarIconScale":2]]).status,200)
        XCTAssertEqual(s.settings.toolbarLabels,false);XCTAssertEqual(s.settings.toolbarMode,.iconsOnly)
        XCTAssertEqual(try command(["command":"settings.update","properties":["toolbarDisplayMode":"labelsOnly","toolbarIconScale":0.75]]).status,200)
        XCTAssertEqual(s.settings.toolbarMode,.labelsOnly);XCTAssertEqual(s.settings.toolbarIconScale,0.75)
        let restored=try JSONDecoder().decode(UserSettings.self,from:JSONEncoder().encode(s.settings));XCTAssertEqual(restored.toolbarMode,.labelsOnly)
        XCTAssertEqual(try command(["command":"settings.update","properties":["toolbarLabels":true]]).status,200);XCTAssertEqual(s.settings.toolbarMode,.iconsAndLabels)
        let prior=s.settings
        XCTAssertEqual(try command(["command":"settings.update","properties":["toolbarDisplayMode":"unknown"]]).status,400);XCTAssertEqual(s.settings,prior)
        XCTAssertEqual(try command(["command":"settings.update","properties":["toolbarIconScale":3]]).status,400);XCTAssertEqual(s.settings,prior)
        s.project.clips=[Clip(kind:.text,name:"occupied",track:1,start:0,duration:1)]
        let count=s.project.tracks.count
        XCTAssertEqual(try command(["command":"track.delete","track":1]).status,400)
        XCTAssertEqual(try command(["command":"track.delete","track":1,"deleteItems":true]).status,200);XCTAssertEqual(s.project.tracks.count,count-1)
    }
}
