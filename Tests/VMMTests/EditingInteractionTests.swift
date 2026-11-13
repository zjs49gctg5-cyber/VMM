import XCTest
import AppKit
import AVFoundation
@testable import VMM

// Integration regressions for interactions between editing, media and export.
final class EditingInteractionTests:XCTestCase {
    @MainActor func store()->EditorStore {
        let s=EditorStore(preferencesDirectory:FileManager.default.temporaryDirectory.appendingPathComponent("vmm-review-\(UUID())"))
        s.autoSpeech=false;s.project=Project();s.project.width=320;s.project.height=180
        return s
    }
    @MainActor func cleanup(_ s:EditorStore) {
        s.pause();s.cancelSpeech();try? FileManager.default.removeItem(at:s.directory);try? FileManager.default.removeItem(at:s.preferencesDirectory)
    }
    @MainActor func scene(_ s:EditorStore)->(UUID,UUID) {
        var child=Clip(kind:.shape,name:"child",track:0,start:0,duration:1)
        child.color="00FF00"
        var group=Clip(kind:.group,name:"scene",track:1,start:0,duration:1)
        child.parentID=group.id;group.sceneMembers=[child.id];s.project.clips=[child,group];s.selectedID=child.id
        return (child.id,group.id)
    }
    @MainActor func testDeletingSceneMemberMustRemainSaveable()async throws {
        let s=store();defer{cleanup(s)};_=scene(s);_=try s.project.validated()
        s.deleteSelection()
        XCTAssertNoThrow(try s.project.validated(),"Deleting an internal item must remove its scene membership.")
        let destination=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-review-save-\(UUID()).vmm")
        defer{try? FileManager.default.removeItem(at:destination)}
        let saved=await s.saveProject(to:destination)
        XCTAssertTrue(saved,s.error ?? "")
    }
    @MainActor func testSplitInsideSceneMustKeepRightHalfVisible()async throws {
        let s=store();defer{cleanup(s)};_=scene(s);s.snapping=false
        s.playhead=0.5;s.splitSelected();_=try s.project.validated()
        let right=try XCTUnwrap(s.selected)
        XCTAssertTrue(s.project.clips.first{$0.sceneMembers != nil}!.sceneMembers!.contains(right.id))
        let context=try XCTUnwrap(RasterTools.bitmap(CGSize(width:320,height:180)))
        FrameRenderer().draw(project:s.project,directory:s.directory,time:0.75,context:context,size:CGSize(width:320,height:180))
        let preview=NSBitmapImageRep(cgImage:try XCTUnwrap(context.makeImage()))
        let color=try XCTUnwrap(preview.colorAt(x:160,y:90)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(color.greenComponent,0.8,"The split right half must remain visible in preview.")
        let movie=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-review-scene-\(UUID()).mp4")
        defer{try? FileManager.default.removeItem(at:movie)}
        try await MovieExporter.export(project:s.project,directory:s.directory,destination:movie){_ in}
        let g=AVAssetImageGenerator(asset:AVURLAsset(url:movie));g.requestedTimeToleranceBefore = .zero;g.requestedTimeToleranceAfter = .zero
        let bitmap=NSBitmapImageRep(cgImage:try g.copyCGImage(at:CMTime(seconds:0.75,preferredTimescale:600),actualTime:nil))
        XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x:160,y:90)?.usingColorSpace(.sRGB)).greenComponent,0.8,"The right half must remain visible in MP4 too.")
    }
    func tone(_ url:URL,amplitude:Float) throws {
        let format=AVAudioFormat(standardFormatWithSampleRate:24000,channels:1)!,buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:48000)!
        buffer.frameLength=48000
        for i in 0..<48000{buffer.floatChannelData![0][i]=amplitude*Float(sin(Double(i)*2 * .pi*440/24000))}
        var file:AVAudioFile?=try AVAudioFile(forWriting:url,settings:format.settings);try file?.write(from:buffer);file=nil
    }
    func peak(_ url:URL)throws->Float {
        let file=try AVAudioFile(forReading:url),buffer=AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:24000)!
        try file.read(into:buffer)
        return UnsafeBufferPointer(start:buffer.floatChannelData![0],count:Int(buffer.frameLength)).map{abs($0)}.max() ?? 0
    }
    @MainActor func playerFile(_ s:EditorStore,_ id:UUID)async throws->URL {
        s.seek(0);s.play()
        for _ in 0..<200 where s.players[id]==nil {try await Task.sleep(nanoseconds:5_000_000)}
        let player=try XCTUnwrap(s.players[id])
        return try XCTUnwrap(Mirror(reflecting:player).children.first{$0.label=="file"}?.value as? AVAudioFile).url
    }
    @MainActor func testRelinkingAudioMustInvalidatePlaybackCache()async throws {
        let s=store();defer{cleanup(s)}
        try tone(s.directory.appendingPathComponent("Media/old.wav"),amplitude:0.002)
        let replacement=s.directory.appendingPathComponent("replacement.wav");try tone(replacement,amplitude:0.3)
        let asset=MediaAsset(name:"audio",file:"old.wav",kind:.audio,duration:2)
        var clip=Clip(kind:.audio,name:"audio",track:0,start:0,duration:1);clip.assetID=asset.id
        s.project.assets=[asset];s.project.clips=[clip]
        let old=try await playerFile(s,clip.id);s.pause();XCTAssertLessThan(try peak(old),0.01)
        try await s.relink(asset.id,url:replacement)
        let current=try await playerFile(s,clip.id);s.pause()
        XCTAssertGreaterThan(try peak(current),0.2,"Preview must use the newly linked loud audio, not cached old audio.")
        let movie=s.directory.appendingPathComponent("audio.mp4")
        try await MovieExporter.export(project:s.project,directory:s.directory,destination:movie){_ in}
        let output=s.directory.appendingPathComponent("export.caf")
        let decoded=try await AudioProcessor.decode(source:movie,destination:output);XCTAssertTrue(decoded)
        XCTAssertGreaterThan(try peak(output),0.15)
        print("AUDIT RELINK previewPeak=\(try peak(current)), exportPeak=\(try peak(output))")
    }
    @MainActor func testQueueMustProtectDestinationCreatedDuringRendering()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-review-queue-\(UUID())")
        try FileManager.default.createDirectory(at:root.appendingPathComponent("Session/Media"),withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        var p=Project();p.width=1920;p.height=1080;p.clips=[Clip(kind:.shape,name:"test",track:0,start:0,duration:3)]
        let q=ExportQueue(root:root.appendingPathComponent("Queue")),destination=root.appendingPathComponent("result.mp4")
        _=try await q.add(project:p,directory:root.appendingPathComponent("Session"),options:UserSettings(),destination:destination)
        q.resume()
        for _ in 0..<1000 where (q.jobs.first?.progress ?? 0)<0.05 {try await Task.sleep(nanoseconds:2_000_000)}
        XCTAssertEqual(q.jobs.first?.state,.running)
        let expected=Data("created by another export while queue is rendering".utf8);try expected.write(to:destination,options:.withoutOverwriting)
        for _ in 0..<1000 where q.runningID != nil {try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertEqual(q.jobs.first?.state,.failed)
        XCTAssertEqual(try Data(contentsOf:destination),expected,"overwrite=false must protect files created during the render, not only before it.")
    }
    @MainActor func testParentMovementMustPreserveChildAVLink()throws {
        let s=store();defer{cleanup(s)}
        var v=Clip(kind:.video,name:"video",track:0,start:1,duration:2);v.linkID=UUID();v.audioDisabled=true
        var a=Clip(kind:.audio,name:"audio",track:1,start:1,duration:2);a.linkID=v.linkID
        let parent=Clip(kind:.group,name:"group",track:2,start:1,duration:2);v.parentID=parent.id
        s.project.clips=[v,a,parent];_=try s.project.validated()
        s.edit(parent.id){$0.start=5}
        XCTAssertEqual(s.project.clips[0].start,s.project.clips[1].start,"Moving a parent must keep its video child synchronized with linked audio.")
    }
    @MainActor func testRegeneratedSpeechMustNotAccumulateInSavedProject()async throws {
        let s=store();defer{cleanup(s);SpeechProtocol.handler=nil}
        let helper=SpeechEngineTests(),wav=try helper.wave();s.speechService=helper.service()
        SpeechProtocol.handler={_ in (200,wav)}
        var c=Clip(kind:.speech,name:"speech",track:0,start:0,duration:1);c.text="test"
        var config=SpeechConfiguration.defaults(.qwen3TTS);config.speaker="Ryan";c.speechConfiguration=config
        s.project.clips=[c];s.selectedID=c.id
        for _ in 0..<3 {
            s.generateSpeech()
            for _ in 0..<200 where !s.generatingSpeech.isEmpty {try await Task.sleep(nanoseconds:5_000_000)}
            XCTAssertTrue(s.generatingSpeech.isEmpty);XCTAssertTrue(s.speechFailures.isEmpty)
        }
        s.removeUnusedMedia()
        let destination=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-review-speech-\(UUID()).vmm")
        defer{try? FileManager.default.removeItem(at:destination)}
        let saved=await s.saveProject(to:destination);XCTAssertTrue(saved)
        let files=try FileManager.default.contentsOfDirectory(at:destination.appendingPathComponent("Media"),includingPropertiesForKeys:nil)
        print("AUDIT SPEECH used=\(s.project.usedAssetIDs.count), hiddenAssets=\(s.project.assets.count), savedFiles=\(files.count)")
        XCTAssertEqual(files.count,1,"Obsolete hidden generated audio must not persist into each saved package.")
    }
    @MainActor func testExportRangeMustIgnoreMutedSpeechOutsideRange()async throws {
        let s=store();defer{cleanup(s)}
        var pending=Clip(kind:.speech,name:"unrendered later dialogue",track:1,start:10,duration:4);pending.speechDirty=true;pending.text="later"
        s.project.clips=[Clip(kind:.shape,name:"first scene",track:0,start:0,duration:3),pending];s.project.tracks[1].visible=false;s.project.tracks[1].muted=true
        s.project.width=320;s.project.height=180
        var options=UserSettings();options.rangeStart=0;options.rangeEnd=3
        XCTAssertTrue(ExportPreflight.inspect(project:s.project,directory:s.directory,options:options).canExport,"Fully disabled and out-of-range dialogue must not prevent this range export.")
        let movie=s.directory.appendingPathComponent("range-\(UUID()).mp4")
        try await MovieExporter.export(project:s.project,directory:s.directory,destination:movie,options:options){_ in}
        let duration=try await AVURLAsset(url:movie).load(.duration)
        XCTAssertEqual(duration.seconds,3,accuracy:0.05)
    }
}
