import XCTest
@testable import VMM

final class MediaTagTests:XCTestCase {
    @MainActor func testTagsSearchUsageAndUndoCleanupPreserveFiles()throws {
        let s=EditorStore(preferencesDirectory:FileManager.default.temporaryDirectory.appendingPathComponent("vmm-tags-\(UUID())"));defer{try? FileManager.default.removeItem(at:s.directory)}
        let used=MediaAsset(name:"Background",file:"a.png",kind:.image,duration:3),mouth=MediaAsset(name:"Mouth",file:"b.png",kind:.image,duration:3),mask=MediaAsset(name:"Mask",file:"c.png",kind:.image,duration:3),unused=MediaAsset(name:"Unused",file:"d.png",kind:.image,duration:3),speech=MediaAsset(name:"Generated",file:"voice.wav",kind:.audio,duration:3,generatedSpeech:true)
        var c=Clip(kind:.image,name:"image",track:0,start:0,duration:3);c.assetID=used.id;c.mouthAssetID=mouth.id;c.masks=[ClipMask(kind:.image,assetID:mask.id)]
        s.project=Project();s.project.assets=[used,mouth,mask,unused,speech];s.project.clips=[c]
        let file=s.directory.appendingPathComponent("Media/d.png");try Data("preserved".utf8).write(to:file)
        try s.setMediaTags(unused.id,text:" 背景, 夜景,背景 ");XCTAssertEqual(s.project.assets[3].tags,["夜景","背景"])
        let tagged=LibraryQuery.assets(s.libraryAssets,search:"Unused 背景",filter:.all,sort:.name,descending:false,usage:.unused,usedIDs:s.project.usedAssetIDs)
        XCTAssertEqual(tagged.map(\.id),[unused.id]);XCTAssertEqual(s.project.usedAssetIDs,[used.id,mouth.id,mask.id]);XCTAssertEqual(s.project.usageCount(mask.id),1)
        XCTAssertEqual(s.unusedLibraryAssets.map(\.id),[unused.id]);s.removeUnusedMedia();XCTAssertEqual(s.project.assets.count,4);XCTAssertEqual(try String(contentsOf:file),"preserved")
        s.undo();XCTAssertEqual(s.project.assets.count,5);XCTAssertEqual(s.project.assets[3].tags,["夜景","背景"])
        XCTAssertThrowsError(try s.setMediaTags(unused.id,text:String(repeating:"a",count:81)))
        let old=try JSONDecoder().decode(MediaAsset.self,from:JSONEncoder().encode(used));XCTAssertNil(old.tags)
    }
}
