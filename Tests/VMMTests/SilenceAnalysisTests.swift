import XCTest
import AVFoundation
import SwiftUI
@testable import VMM

final class SilenceAnalysisTests: XCTestCase {
    @MainActor func testSilenceWindowLayout() async throws {
        guard let path=ProcessInfo.processInfo.environment["VMM_SILENCE_UI_TEST_DIR"] else {throw XCTSkip("UI capture only")}
        let root=URL(fileURLWithPath:path,isDirectory:true),store=EditorStore(preferencesDirectory:root)
        defer{store.pause();try? FileManager.default.removeItem(at:store.directory)}
        let host=NSHostingView(rootView:SilenceCutView(store:store,clipID:UUID()).preferredColorScheme(.dark).vmmAppearance(store.settings))
        host.frame=NSRect(x:0,y:0,width:640,height:540)
        let window=NSWindow(contentRect:host.frame,styleMask:[.titled,.resizable],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.contentView=host;window.orderBack(nil)
        defer{window.close()};host.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:250_000_000)
        let image=try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds));host.cacheDisplay(in:host.bounds,to:image)
        try XCTUnwrap(image.representation(using:.png,properties:[:])).write(to:root.appendingPathComponent("silence-window.png"))
    }
    @MainActor func testCommitUndoAndStaleProjectProtection() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-silence-undo-\(UUID())"),store=EditorStore(preferencesDirectory:root)
        defer{store.pause();try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        let asset=MediaAsset(name:"audio",file:"input.wav",kind:.audio,duration:4)
        var clip=Clip(kind:.audio,name:"audio",track:1,start:0,duration:4);clip.assetID=asset.id
        store.project=Project();store.project.assets=[asset];store.project.clips=[clip]
        let before=store.project;let cuts=[SilenceCutRange(start:1,end:2)]
        try store.commitSilenceCut(snapshot:before,directory:store.directory,ids:[clip.id],cuts:cuts);XCTAssertEqual(store.project.clips.count,2)
        XCTAssertThrowsError(try store.commitSilenceCut(snapshot:before,directory:store.directory,ids:[clip.id],cuts:cuts))
        store.undo();XCTAssertEqual(store.project,before)
    }
    @MainActor func testFadeOnTargetOrLinkedPeerIsRejectedWithoutUndo() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-silence-fade-\(UUID())"),store=EditorStore(preferencesDirectory:root)
        defer{store.pause();try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        let asset=MediaAsset(name:"audio",file:"input.wav",kind:.audio,duration:4)
        var video=Clip(kind:.video,name:"video",track:1,start:0,duration:4);video.assetID=asset.id;video.linkID=UUID()
        var audio=video;audio.id=UUID();audio.kind = .audio;audio.track=2
        store.project=Project();store.project.assets=[asset];store.project.clips=[video,audio]
        let cuts=[SilenceCutRange(start:1,end:2)]
        store.project.clips[0].audioFade=AudioFade(fadeIn:0.5,fadeOut:0)
        var before=store.project;XCTAssertFalse(store.canUndo)
        XCTAssertThrowsError(try store.commitSilenceCut(snapshot:before,directory:store.directory,ids:[video.id],cuts:cuts)) {XCTAssertTrue($0.localizedDescription.contains("フェード"))}
        XCTAssertEqual(store.project,before);XCTAssertFalse(store.canUndo)
        store.project.clips[0].audioFade=nil;store.project.clips[1].audioFade=AudioFade(fadeIn:0,fadeOut:1)
        before=store.project
        XCTAssertThrowsError(try store.commitSilenceCut(snapshot:before,directory:store.directory,ids:[video.id],cuts:cuts)) {XCTAssertTrue($0.localizedDescription.contains("フェード"))}
        XCTAssertEqual(store.project,before);XCTAssertFalse(store.canUndo)
        store.project.clips[1].audioFade=AudioFade(fadeIn:0,fadeOut:0);before=store.project
        XCTAssertNoThrow(try store.commitSilenceCut(snapshot:before,directory:store.directory,ids:[video.id],cuts:cuts));XCTAssertTrue(store.canUndo)
        store.undo();XCTAssertEqual(store.project,before)
    }
    @MainActor func testIdenticalProjectInDifferentDirectoryIsRejected() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-silence-directory-\(UUID())"),store=EditorStore(preferencesDirectory:root)
        let originalDirectory=store.directory
        defer{store.directory=originalDirectory;store.pause();try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:originalDirectory)}
        let asset=MediaAsset(name:"audio",file:"input.wav",kind:.audio,duration:4)
        var clip=Clip(kind:.audio,name:"audio",track:1,start:0,duration:4);clip.assetID=asset.id
        store.project=Project();store.project.assets=[asset];store.project.clips=[clip]
        let before=store.project;store.directory=root.appendingPathComponent("other-\(UUID())")
        XCTAssertThrowsError(try store.commitSilenceCut(snapshot:before,directory:originalDirectory,ids:[clip.id],cuts:[SilenceCutRange(start:1,end:2)]))
        XCTAssertEqual(store.project,before);XCTAssertFalse(store.canUndo)
    }
    @MainActor func testRejectsMismatchedLinkedDurationAndOutOfSourceWithoutUndo() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-silence-bounds-\(UUID())"),store=EditorStore(preferencesDirectory:root)
        defer{store.pause();try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        let asset=MediaAsset(name:"audio",file:"input.wav",kind:.audio,duration:4)
        var video=Clip(kind:.video,name:"video",track:1,start:0,duration:4);video.assetID=asset.id;video.linkID=UUID()
        var audio=video;audio.id=UUID();audio.kind = .audio;audio.track=2;audio.duration=3.99
        store.project=Project();store.project.assets=[asset];store.project.clips=[video,audio]
        let cuts=[SilenceCutRange(start:1,end:2)];var before=store.project
        XCTAssertThrowsError(try store.commitSilenceCut(snapshot:before,directory:store.directory,ids:[video.id],cuts:cuts))
        XCTAssertEqual(store.project,before);XCTAssertFalse(store.canUndo)
        store.project.clips[1].duration=4;store.project.clips[0].sourceOffset=0.02;before=store.project
        XCTAssertThrowsError(try store.commitSilenceCut(snapshot:before,directory:store.directory,ids:[video.id],cuts:cuts))
        XCTAssertEqual(store.project,before);XCTAssertFalse(store.canUndo)
    }
    func testSynchronizedCutPreservesSourceLinkAndUnselectedClips() throws {
        var p=Project();let asset=MediaAsset(name:"video",file:"video.mp4",kind:.video,duration:8)
        var video=Clip(kind:.video,name:"video",track:0,start:2,duration:4);video.assetID=asset.id;video.sourceOffset=1;video.linkID=UUID()
        var audio=video;audio.id=UUID();audio.track=1;audio.kind = .audio
        var other=Clip(kind:.shape,name:"other",track:2,start:5,duration:1);other.x=0.2
        p.assets=[asset];p.clips=[video,audio,other]
        let (result,selection)=try SilenceCut.apply(project:p,ids:[video.id],cuts:[SilenceCutRange(start:1,end:2)])
        let images=result.clips.filter{$0.kind == .video}.sorted{$0.start<$1.start},sounds=result.clips.filter{$0.kind == .audio}.sorted{$0.start<$1.start}
        XCTAssertEqual(selection.count,4);XCTAssertEqual(images.map(\.start),[2,3]);XCTAssertEqual(images.map(\.duration),[1,2]);XCTAssertEqual(images.map(\.sourceOffset),[1,3])
        XCTAssertEqual(images.map(\.linkID),sounds.map(\.linkID));XCTAssertNotEqual(images[0].linkID,images[1].linkID)
        XCTAssertEqual(result.clips.first{$0.id==other.id},other)
        p.tracks[1].locked=true;XCTAssertThrowsError(try SilenceCut.apply(project:p,ids:[video.id],cuts:[SilenceCutRange(start:1,end:2)]))
        p.tracks[1].locked=false;XCTAssertThrowsError(try SilenceCut.apply(project:p,ids:[video.id],cuts:[SilenceCutRange(start:0,end:4)]))
    }
    func testThresholdDurationAndEdgeMargin() throws {
        let rms = [0.1,0.1] + Array(repeating:0.001,count:10) + [0.1,0.1] + Array(repeating:0.001,count:3)
        let ranges = try SilenceAnalysis.ranges(rms:rms,fps:10,thresholdDB:-40,minimum:0.5,margin:0.1)
        XCTAssertEqual(ranges,[SilenceCutRange(start:0.3,end:1.1)])
        XCTAssertThrowsError(try SilenceAnalysis.ranges(rms:rms,fps:0,thresholdDB:-40,minimum:0.5,margin:0.1))
    }
    func testMultichannelSourceOffsetAndPlaybackRate() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-silence-test-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let url=root.appendingPathComponent("input.wav"),format=AVAudioFormat(standardFormatWithSampleRate:48000,channels:2)!
        let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:96000)!;buffer.frameLength=96000
        for i in 0..<96000 {let sample:Float = (i < 24000 || i >= 72000) ? 0.25:0;buffer.floatChannelData![0][i]=sample;buffer.floatChannelData![1][i] = -sample}
        var file:AVAudioFile?=try AVAudioFile(forWriting:url,settings:format.settings);try file!.write(from:buffer);file=nil
        var clip=Clip(kind:.audio,name:"test",track:0,start:2,duration:0.5);clip.sourceOffset=0.5;clip.playbackRate=2
        let result=try await SilenceAnalysis.analyze(url:url,clip:clip,fps:20,thresholdDB:-40,minimum:0.2,margin:0.05)
        XCTAssertEqual(result,[SilenceCutRange(start:0.05,end:0.45)])
    }
    func testCutAudioPlaysAndExports() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-silence-output-\(UUID())"),media=root.appendingPathComponent("Media")
        try FileManager.default.createDirectory(at:media,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let url=media.appendingPathComponent("input.wav"),format=AVAudioFormat(standardFormatWithSampleRate:48000,channels:1)!
        let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:96000)!;buffer.frameLength=96000
        for i in 0..<96000 {buffer.floatChannelData![0][i] = (i<24000 || i>=72000) ? Float(sin(Double(i)*2*Double.pi*440/48000)*0.2):0}
        var file:AVAudioFile?=try AVAudioFile(forWriting:url,settings:format.settings);try file!.write(from:buffer);file=nil
        let asset=MediaAsset(name:"audio",file:"input.wav",kind:.audio,duration:2)
        var clip=Clip(kind:.audio,name:"audio",track:1,start:0,duration:2);clip.assetID=asset.id
        var project=Project();project.width=640;project.height=360;project.assets=[asset];project.clips=[clip]
        let (cut,_)=try SilenceCut.apply(project:project,ids:[clip.id],cuts:[SilenceCutRange(start:0.5,end:1.5)])
        let part=try XCTUnwrap(cut.clips.first),player=try ClipAudioPlayer(url:url,clip:part,time:0,volume:0.01);player.pause()
        let output=root.appendingPathComponent("cut.mp4");try await MovieExporter.export(project:cut,directory:root,destination:output){_ in}
        let video=AVURLAsset(url:output),tracks=try await video.loadTracks(withMediaType:.audio)
        let duration=try await video.load(.duration).seconds;XCTAssertEqual(tracks.count,1);XCTAssertEqual(duration,1,accuracy:0.1)
    }
}
