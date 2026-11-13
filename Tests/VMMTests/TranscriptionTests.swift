import XCTest
import AVFoundation
import SwiftUI
@testable import VMM

final class TranscriptionTests:XCTestCase {
    func testRecognitionTimestampMappingSpeedAndFrameAlignment() throws {
        var clip=Clip(kind:.audio,name:"audio",track:0,start:5,duration:3);clip.sourceOffset=2;clip.playbackRate=2
        let tokens=[TranscriptToken(text:"こんにちは",start:0.2,duration:0.6),TranscriptToken(text:"世界。",start:1,duration:0.3),TranscriptToken(text:"続き",start:3,duration:0.6)]
        let parts=try TranscriptPlanner.parts(tokens,clip:clip,fps:30)
        XCTAssertEqual(parts.count,2);XCTAssertEqual(parts[0].text,"こんにちは世界。");XCTAssertEqual(parts[0].start,5.1,accuracy:0.001);XCTAssertEqual(parts[1].start,6.5,accuracy:0.001)
        XCTAssertTrue(parts.allSatisfy{$0.start>=clip.start && $0.end<=clip.end && $0.end>$0.start})
        let english=try TranscriptPlanner.parts([TranscriptToken(text:"Hello",start:0,duration:0.3),TranscriptToken(text:"world",start:0.4,duration:0.3)],clip:clip,fps:30)
        XCTAssertEqual(english[0].text,"Hello world")
        XCTAssertThrowsError(try TranscriptPlanner.parts([],clip:clip,fps:30))
    }
    @MainActor func testApplyIsAtomicUndoableAndRejectsChangedProjectOrTrack()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-transcript-\(UUID())"),store=EditorStore(preferencesDirectory:root)
        defer{try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        let asset=MediaAsset(name:"source",file:"source.wav",kind:.audio,duration:10)
        var clip=Clip(kind:.audio,name:"audio",track:0,start:1,duration:2);clip.assetID=asset.id
        var other=clip;other.id=UUID();other.start=5
        store.project.assets=[asset];store.project.clips=[clip,other];store.selectedID=clip.id
        let snapshot=store.project,folder=store.directory,track=store.project.tracks[1].id
        let parts=[CaptionSplitPart(text:"字幕",start:1,end:2),CaptionSplitPart(text:"続き",start:2,end:3)]
        var invalid=parts;invalid[1].start=1.5
        XCTAssertThrowsError(try store.applyTranscript(snapshot:snapshot,directory:folder,sourceID:clip.id,trackID:track,parts:invalid));XCTAssertEqual(store.project,snapshot)
        store.project.tracks[1].locked=true
        XCTAssertThrowsError(try store.applyTranscript(snapshot:snapshot,directory:folder,sourceID:clip.id,trackID:track,parts:parts));XCTAssertEqual(store.project.clips,[clip,other])
        store.project=snapshot;store.selectedID=nil
        XCTAssertThrowsError(try store.applyTranscript(snapshot:snapshot,directory:folder,sourceID:clip.id,trackID:track,parts:parts))
        store.selectedID=clip.id;store.selectedIDs=[other.id]
        XCTAssertThrowsError(try store.applyTranscript(snapshot:snapshot,directory:folder,sourceID:clip.id,trackID:track,parts:parts));store.selectedIDs=[]
        store.selectedID=clip.id
        try store.applyTranscript(snapshot:snapshot,directory:folder,sourceID:clip.id,trackID:track,parts:parts)
        XCTAssertEqual(store.project.clips.count,4);XCTAssertEqual(store.project.clips[2].text,"字幕");XCTAssertEqual(store.project.clips[2].track,1)
        store.undo();XCTAssertEqual(store.project,snapshot)
        var long=clip;long.duration=56;XCTAssertThrowsError(try TranscriptPlanner.validateSource(long,project:snapshot))
        long.duration=30;long.playbackRate=2;XCTAssertThrowsError(try TranscriptPlanner.validateSource(long,project:snapshot))
    }
    func testExportedRecognitionAudioContainsOnlySourceRange()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-transcript-audio-\(UUID())");try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let source=root.appendingPathComponent("source.wav"),output=root.appendingPathComponent("crop.m4a")
        let format=AVAudioFormat(standardFormatWithSampleRate:24000,channels:1)!,buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:72000)!
        buffer.frameLength=72000;for i in 0..<72000 {let frequency = i < 18000 ? 220.0:i < 42000 ? 440.0:880.0;buffer.floatChannelData![0][i]=Float(sin(Double(i)*2*Double.pi*frequency/24000)*0.2)}
        var file:AVAudioFile?=try AVAudioFile(forWriting:source,settings:format.settings);try file!.write(from:buffer);file=nil
        var clip=Clip(kind:.audio,name:"audio",track:0,start:5,duration:0.5);clip.sourceOffset=0.75;clip.playbackRate=2
        try await LocalTranscription.audioRange(source:source,clip:clip,destination:output)
        let asset=AVURLAsset(url:output),duration=try await asset.load(.duration).seconds
        XCTAssertEqual(duration,1,accuracy:0.05)
        let frequency=AdvancedTests();XCTAssertGreaterThan(try frequency.energy(output,frequency:440),0.06);XCTAssertLessThan(try frequency.energy(output,frequency:220),0.01);XCTAssertLessThan(try frequency.energy(output,frequency:880),0.01)
    }
    @MainActor func testTranscriptionSheetSnapshot()throws {
        guard let folder=testArtifactDirectory() else{throw XCTSkip("Opt-in transcription UI snapshot")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-transcription-ui-\(UUID())"),store=EditorStore(preferencesDirectory:root)
        defer{try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        let asset=MediaAsset(name:"source",file:"source.wav",kind:.audio,duration:5);var clip=Clip(kind:.audio,name:"音声",track:0,start:0,duration:5);clip.assetID=asset.id
        store.project.assets=[asset];store.project.clips=[clip];store.selectedID=clip.id
        let host=NSHostingView(rootView:TranscriptionSheet(store:store,source:clip));host.frame=CGRect(x:0,y:0,width:800,height:500)
        let window=NSWindow(contentRect:host.frame,styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.contentView=host;window.orderBack(nil);defer{window.close()}
        host.layoutSubtreeIfNeeded();let bitmap=try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds));host.cacheDisplay(in:host.bounds,to:bitmap)
        let destination=URL(fileURLWithPath:folder);try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
        try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:destination.appendingPathComponent("transcription-sheet.png"))
    }
}
