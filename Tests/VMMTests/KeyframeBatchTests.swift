import XCTest
import AppKit
@testable import VMM

final class KeyframeBatchTests:XCTestCase {
    @MainActor func testMoveStretchCopyPasteCollisionsUndoAndEffects()throws {
        let s=EditorStore(preferencesDirectory:FileManager.default.temporaryDirectory.appendingPathComponent("vmm-keys-\(UUID())"));defer{try? FileManager.default.removeItem(at:s.directory)}
        var c=Clip(kind:.shape,name:"keys",track:0,start:5,duration:10)
        c.animationOffset=2;c.animation=ClipAnimation(tracks:[AnimationTrack(property:.x,keys:[AnimationKeyframe(time:2,value:0.2),AnimationKeyframe(time:3,value:0.8)])])
        var e=VisualEffect(kind:.blur);e.keys=[AnimationKeyframe(time:2,value:0),AnimationKeyframe(time:3,value:20)];c.effects=[e];s.project=Project();s.project.clips=[c]
        let ids=Set(c.batchKeys.map(\.id));try s.changeKeyframeTimes(c.id,selection:ids,offset:1,scale:2)
        XCTAssertEqual(s.project.clips[0].batchKeys.map(\.time),[3,3,5,5]);s.undo();XCTAssertEqual(s.project.clips[0],c)
        let pb=NSPasteboard(name:NSPasteboard.Name("vmm-test-\(UUID())"));defer{pb.releaseGlobally()}
        try s.copyKeyframes(c,selection:ids,pasteboard:pb);s.playhead=9;try s.pasteKeyframes(c.id,pasteboard:pb)
        XCTAssertEqual(s.project.clips[0].batchKeys.count,8);XCTAssertEqual(s.project.clips[0].batchKeys.map(\.time),[2,2,3,3,6,6,7,7]);XCTAssertEqual(Set(s.project.clips[0].batchKeys.map(\.id)).count,8)
        let snapshot=s.project
        s.playhead=5;XCTAssertThrowsError(try s.pasteKeyframes(c.id,pasteboard:pb));XCTAssertEqual(s.project,snapshot)
        s.project.tracks[0].locked=true;try s.changeKeyframeTimes(c.id,selection:ids,offset:1,scale:1);XCTAssertEqual(s.project.clips[0],snapshot.clips[0])
    }
    @MainActor func testPSDKeysRequireMatchingAssetAndPreserveSelection()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-psd-batch-\(UUID())");defer{try? FileManager.default.removeItem(at:root)}
        let s=EditorStore(preferencesDirectory:root);defer{try? FileManager.default.removeItem(at:s.directory)}
        s.project=try PSDAnimationTests().fixture(root);let clip=s.project.clips[0],ids=Set(clip.batchKeys.map(\.id))
        let pb=NSPasteboard(name:NSPasteboard.Name("vmm-test-\(UUID())"));defer{pb.releaseGlobally()}
        try s.copyKeyframes(clip,selection:ids,pasteboard:pb);s.playhead=3;try s.pasteKeyframes(clip.id,pasteboard:pb)
        XCTAssertEqual(s.project.clips[0].psd?.selectionKeys?.map(\.time),[1,2,3,4]);XCTAssertEqual(s.project.clips[0].psd?.selectionKeys?.last?.selected,[0])
        try s.changeKeyframeTimes(clip.id,selection:ids,offset:-0.5,scale:0.5)
        XCTAssertEqual(s.project.clips[0].psd?.selectionKeys?.map(\.time),[0.5,1,3,4])
        var other=s.project.assets[0];other.id=UUID();s.project.assets.append(other);s.project.clips[0].assetID=other.id
        XCTAssertThrowsError(try s.pasteKeyframes(clip.id,pasteboard:pb))
    }
}
