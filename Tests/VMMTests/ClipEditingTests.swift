import XCTest
import AppKit
import AVFoundation
@testable import VMM

final class ClipEditingTests:XCTestCase {
    @MainActor func testCopyPasteParentsTimingLockedAndForeignProject()throws {
        let s=EditorStore(preferencesDirectory:FileManager.default.temporaryDirectory.appendingPathComponent("vmm-clip-edit-\(UUID())"));defer{try? FileManager.default.removeItem(at:s.directory)}
        var group=Clip(kind:.group,name:"group",track:0,start:1,duration:4),child=Clip(kind:.text,name:"child",track:1,start:2,duration:2,text:"字幕")
        child.parentID=group.id;s.project=Project();s.project.clips=[group,child];s.selectedID=group.id
        let pb=NSPasteboard(name:NSPasteboard.Name("vmm-test-\(UUID())"));defer{pb.releaseGlobally()}
        try s.copyClips(pasteboard:pb);s.playhead=10;s.selectedTrack=2;try s.pasteClips(pasteboard:pb)
        XCTAssertEqual(s.project.clips.count,4);let copies=Array(s.project.clips.suffix(2));XCTAssertEqual(copies.map(\.start),[10,11]);XCTAssertEqual(copies.map(\.track),[2,3]);XCTAssertEqual(copies[1].parentID,copies[0].id)
        s.undo();XCTAssertEqual(s.project.clips.count,2)
        s.project.tracks[2].locked=true;XCTAssertThrowsError(try s.pasteClips(pasteboard:pb));XCTAssertEqual(s.project.clips.count,2)
        s.directory=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-other-\(UUID())");XCTAssertThrowsError(try s.pasteClips(pasteboard:pb))
        group.name="unused"
    }
    @MainActor func testRippleUnionMarkersRangeUndoAndOverlapProtection()throws {
        let s=EditorStore(preferencesDirectory:FileManager.default.temporaryDirectory.appendingPathComponent("vmm-ripple-\(UUID())"));defer{try? FileManager.default.removeItem(at:s.directory)}
        let a=Clip(kind:.text,name:"A",track:0,start:1,duration:2),b=Clip(kind:.text,name:"B",track:1,start:2,duration:2),c=Clip(kind:.text,name:"C",track:0,start:6,duration:1)
        s.project=Project();s.project.clips=[a,b,c];s.project.markers=[TimelineMarker(time:6,name:"cue")];s.project.timelineRange=TimelineRange(start:4,end:7);s.selectedIDs=[a.id,b.id];s.selectedID=a.id
        try s.rippleDelete();XCTAssertEqual(s.project.clips[0].start,3);XCTAssertEqual(s.project.markers?.first?.time,3);XCTAssertEqual(s.project.timelineRange?.start,1)
        s.undo();XCTAssertEqual(s.project.clips,[a,b,c]);s.selectedIDs=[a.id];s.selectedID=a.id
        let before=s.project;XCTAssertThrowsError(try s.rippleDelete());XCTAssertEqual(s.project,before)
        s.selectedIDs=[a.id,b.id];s.project.tracks[0].locked=true;XCTAssertThrowsError(try s.rippleDelete())
    }
    @MainActor func testAudioSeparationHasOneAudioTrackAndPreservesPlaybackSettings()async throws {
        let s=EditorStore(preferencesDirectory:FileManager.default.temporaryDirectory.appendingPathComponent("vmm-separate-\(UUID())"));defer{s.pause();try? FileManager.default.removeItem(at:s.directory)}
        let wav=s.directory.appendingPathComponent("Media/tone.wav");try AdvancedTests().tone(at:wav,duration:2)
        var p=Project();p.width=320;p.height=180;let sourceAsset=MediaAsset(name:"tone",file:"tone.wav",kind:.audio,duration:2);p.assets=[sourceAsset]
        var sound=Clip(kind:.audio,name:"tone",track:0,start:0,duration:1);sound.assetID=sourceAsset.id;p.clips=[sound]
        let movie=s.directory.appendingPathComponent("Media/source.mp4");try await MovieExporter.export(project:p,directory:s.directory,destination:movie){_ in}
        let video=MediaAsset(name:"source",file:"source.mp4",kind:.video,duration:1)
        var clip=Clip(kind:.video,name:"video",track:0,start:0,duration:0.5);clip.assetID=video.id;clip.sourceOffset=0.2;clip.playbackRate=1.5;clip.volume=0.4
        s.project=p;s.project.assets=[video];s.project.clips=[clip]
        try await s.separateAudio(clip.id);XCTAssertEqual(s.project.clips.count,2);XCTAssertEqual(s.project.clips[0].audioDisabled,true)
        let audio=s.project.clips[1];XCTAssertEqual(audio.kind,.audio);XCTAssertEqual(audio.assetID,video.id);XCTAssertEqual(audio.sourceOffset,0.2);XCTAssertEqual(audio.mediaRate,1.5);XCTAssertEqual(audio.volume,0.4)
        XCTAssertFalse(s.project.audioIsActive(s.project.clips[0],at:0.1));XCTAssertTrue(s.project.audioIsActive(audio,at:0.1))
        let result=s.directory.appendingPathComponent("separated.mp4");try await MovieExporter.export(project:s.project,directory:s.directory,destination:result){_ in}
        let tracks=try await AVURLAsset(url:result).loadTracks(withMediaType:.audio);XCTAssertEqual(tracks.count,1)
        s.undo();XCTAssertEqual(s.project.clips,[clip])
    }
}
