import XCTest
import AVFoundation
import SwiftUI
@testable import VMM

final class CaptionSplitTests:XCTestCase {
    @MainActor func testSplitSheetSnapshot() async throws {
        guard let output=testArtifactDirectory() else{throw XCTSkip("Opt-in caption split UI snapshot")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-caption-sheet-\(UUID())"),store=EditorStore(preferencesDirectory:root)
        defer{store.pause();try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        let clip=Clip(kind:.speech,name:"字幕",track:1,start:0,duration:4,text:"字幕を分割します。時間を確認して調整できます。")
        store.project.clips=[clip];let parts=try CaptionSplitPlanner.suggest(clip,fps:store.project.fps)
        let size=CGSize(width:760,height:540),host=NSHostingView(rootView:CaptionSplitSheet(store:store,clip:clip,parts:parts).frame(width:size.width,height:size.height).preferredColorScheme(.dark).vmmAppearance(store.settings))
        let window=NSWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.appearance=NSAppearance(named:.darkAqua);window.contentView=host;window.makeKeyAndOrderFront(nil);defer{window.close()}
        host.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:200_000_000)
        let bitmap=try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds));host.cacheDisplay(in:host.bounds,to:bitmap)
        try FileManager.default.createDirectory(atPath:output,withIntermediateDirectories:true)
        try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:URL(fileURLWithPath:output).appendingPathComponent("caption-split.png"))
    }
    @MainActor func testProposalApplyUndoAndExport() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-caption-split-\(UUID())"),store=EditorStore(preferencesDirectory:root)
        defer{store.cancelSpeech();try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        store.project=Project();store.autoSpeech=false
        var speech=Clip(kind:.speech,name:"話者",track:1,start:0,duration:3,text:"最初の文章です。次に続く文章です。最後の文章です。")
        speech.color="00FF00";speech.fontSize=42;speech.reading="発音";speech.speechDirty=false
        var parent=Clip(kind:.group,name:"parent",track:2,start:0.5,duration:2);parent.x=0.6;speech.parentID=parent.id
        store.project.clips=[speech,parent]
        let parts=try CaptionSplitPlanner.suggest(speech,fps:store.project.fps)
        XCTAssertGreaterThan(parts.count,1);XCTAssertEqual(parts.first?.start,0);XCTAssertEqual(parts.last?.end,3)
        var invalid=parts;invalid[0].end=invalid[0].start;let original=store.project
        XCTAssertThrowsError(try store.applyCaptionSplit(original:speech,fps:store.project.fps,parts:invalid));XCTAssertEqual(store.project,original)
        store.project.tracks[1].locked=true;XCTAssertThrowsError(try store.applyCaptionSplit(original:speech,fps:store.project.fps,parts:parts));store.project.tracks[1].locked=false
        store.project.tracks[2].locked=true;let locked=store.project
        XCTAssertThrowsError(try store.applyCaptionSplit(original:speech,fps:store.project.fps,parts:parts));XCTAssertEqual(store.project,locked);store.project.tracks[2].locked=false
        try store.applyCaptionSplit(original:speech,fps:store.project.fps,parts:parts)
        let updated=try XCTUnwrap(store.project.clips.first{$0.id==speech.id})
        XCTAssertEqual(updated.speechCaptionHidden,true);XCTAssertEqual(updated.text,speech.text);XCTAssertEqual(updated.reading,speech.reading);XCTAssertEqual(updated.preserveSpeechDuration,true)
        let captions=store.project.clips.filter{$0.kind == .text};XCTAssertEqual(captions.count,parts.count)
        XCTAssertTrue(captions.allSatisfy{$0.parentID==parent.id && $0.color==speech.color && $0.assetID==nil})
        let cues=store.project.captionCues;XCTAssertEqual(cues.count,parts.filter{$0.end>parent.start && $0.start<parent.end}.count)
        XCTAssertTrue(cues.allSatisfy{$0.start>=parent.start && $0.end<=parent.end})
        let encoded=CaptionCodec.encode(cues,format:.srt);XCTAssertFalse(encoded.contains(speech.text))
        let decoded=try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(store.project));XCTAssertEqual(decoded,store.project)
        store.undo();XCTAssertEqual(store.project,original)
        speech.parentID=nil;parent.sceneMembers=[speech.id];store.project.clips=[speech,parent]
        store.project.tracks[2].locked=true;let lockedScene=store.project
        XCTAssertThrowsError(try store.applyCaptionSplit(original:speech,fps:store.project.fps,parts:parts));XCTAssertEqual(store.project,lockedScene);store.project.tracks[2].locked=false
        try store.applyCaptionSplit(original:speech,fps:store.project.fps,parts:parts)
        let members=try XCTUnwrap(store.project.clips.first{$0.id==parent.id}?.sceneMembers)
        XCTAssertEqual(Set(members),Set([speech.id]+store.project.clips.filter{$0.kind == .text}.map(\.id)))
    }

    @MainActor func testRenderedCaptionAndAudioExportMatchIndependentText() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-caption-split-render-\(UUID())"),store=EditorStore(preferencesDirectory:root)
        defer{SpeechProtocol.handler=nil;store.cancelSpeech();store.pause();try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        store.autoSpeech=false;store.project=Project();store.project.width=320;store.project.height=180
        let helper=SpeechEngineTests(),wave=try helper.wave();store.speechService=helper.service()
        SpeechProtocol.handler={request in request.url?.path == "/audio_query" ? (200,try helper.json(["speedScale":1,"accent_phrases":[]])):(200,wave)}
        var speech=Clip(kind:.speech,name:"voice",track:1,start:0,duration:1,text:"はじめの言葉です。次の言葉です。",fontSize:42)
        var parent=Clip(kind:.group,name:"parent",track:2,start:0,duration:1);parent.x=0.6;speech.parentID=parent.id
        store.project.clips=[speech,parent];store.selectedID=speech.id;store.generateSpeech()
        for _ in 0..<100 where !store.generatingSpeech.isEmpty {try await Task.sleep(nanoseconds:50_000_000)}
        speech=try XCTUnwrap(store.selected);let asset=try XCTUnwrap(store.project.asset(for:speech)),file=store.directory.appendingPathComponent("Media").appendingPathComponent(asset.file)
        let original=store.project, parts=try CaptionSplitPlanner.suggest(speech,fps:store.project.fps)
        try store.applyCaptionSplit(original:speech,fps:store.project.fps,parts:parts)
        let rendered=try AdvancedTests().pixels(AdvancedTests().render(store.project,0.1,directory:store.directory))
        var withoutSpeech=store.project;withoutSpeech.clips.removeAll{$0.id==speech.id}
        XCTAssertEqual(rendered,try AdvancedTests().pixels(AdvancedTests().render(withoutSpeech,0.1,directory:store.directory)))
        let player=try ClipAudioPlayer(url:file,clip:speech,time:0,volume:0.01);player.pause()
        let before=root.appendingPathComponent("before.mp4"),after=root.appendingPathComponent("after.mp4")
        try await MovieExporter.export(project:original,directory:store.directory,destination:before){_ in}
        try await MovieExporter.export(project:store.project,directory:store.directory,destination:after){_ in}
        let generator=AVAssetImageGenerator(asset:AVURLAsset(url:after));generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
        func pixelsAt(_ seconds:Double)throws->[UInt8] {
            let image=try generator.copyCGImage(at:CMTime(seconds:seconds,preferredTimescale:600),actualTime:nil)
            let context=try XCTUnwrap(RasterTools.bitmap(CGSize(width:320,height:180)));context.draw(image,in:CGRect(x:0,y:0,width:320,height:180))
            return try AdvancedTests().pixels(context)
        }
        let frameA=try pixelsAt(0.1),frameB=try pixelsAt(0.8)
        XCTAssertGreaterThan(frameA.enumerated().filter{$0.offset%4 != 3 && $0.element>40}.count,30)
        XCTAssertNotEqual(frameA,frameB)
        let tracks=try await AVURLAsset(url:after).loadTracks(withMediaType:.audio);XCTAssertEqual(tracks.count,1)
        let beforeEnergy=try AdvancedTests().energy(before,frequency:440),afterEnergy=try AdvancedTests().energy(after,frequency:440)
        XCTAssertGreaterThan(beforeEnergy,0.01);XCTAssertEqual(afterEnergy,beforeEnergy,accuracy:0.01)
    }
}
