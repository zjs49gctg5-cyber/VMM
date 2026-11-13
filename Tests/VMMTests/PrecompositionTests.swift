import XCTest
import AppKit
import AVFoundation
@testable import VMM
final class PrecompositionTests:XCTestCase {
    @MainActor func store()->EditorStore {let s=EditorStore(preferencesDirectory:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString));s.autoSpeech=false;s.settings.autosaveSeconds=0;s.project=Project();s.project.width=320;s.project.height=180;s.project.background="000000";return s}
    func frame(_ p:Project,_ directory:URL,_ time:Double)throws->NSBitmapImageRep {let c=try XCTUnwrap(RasterTools.bitmap(CGSize(width:p.width,height:p.height)));FrameRenderer().draw(project:p,directory:directory,time:time,context:c,size:CGSize(width:p.width,height:p.height));return NSBitmapImageRep(cgImage:try XCTUnwrap(c.makeImage()))}
    @MainActor func testCreateIndependentTimelineSharedInstancesUniqueCopyAndUndo()throws {
        let s=store();defer{try? FileManager.default.removeItem(at:s.directory)}
        var a=Clip(kind:.shape,name:"A",track:0,start:1,duration:2);a.color="FF0000";a.scale=0.2;a.x=0.3
        var b=a;b.id=UUID();b.name="B";b.track=1;b.color="00FF00";b.x=0.7;s.project.clips=[a,b];s.selectedIDs=[a.id,b.id];s.project.tracks[1].opacity=0.6
        let original=s.project,id=try s.createPrecomposition(name:"AB"),instance=try XCTUnwrap(s.project.clips.first{$0.id==id}),comp=try XCTUnwrap(s.project.composition(instance))
        XCTAssertEqual(s.project.clips.count,1);XCTAssertEqual(comp.clips.map(\.start),[0,0]);XCTAssertEqual(comp.duration,2);XCTAssertEqual(comp.tracks.count,2)
        let before=try frame(original,s.directory,1.5),after=try frame(s.project,s.directory,1.5)
        XCTAssertEqual(before.bitmapData.map{Data(bytes:$0,count:before.bytesPerRow*before.pixelsHigh)},after.bitmapData.map{Data(bytes:$0,count:after.bytesPerRow*after.pixelsHigh)})
        s.duplicateSelected();XCTAssertEqual(s.project.clips.count,2);let duplicate=try XCTUnwrap(s.selected);XCTAssertEqual(duplicate.precompositionID,instance.precompositionID)
        try s.makePrecompositionUnique(duplicate.id);XCTAssertNotEqual(s.selected?.precompositionID,instance.precompositionID);s.undo();XCTAssertEqual(s.selected?.precompositionID,instance.precompositionID)
        let encoded=try JSONEncoder().encode(s.project);XCTAssertEqual(try JSONDecoder().decode(Project.self,from:encoded).validated(),s.project)
        s.undo();s.undo();XCTAssertEqual(s.project,original)
        let old=try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(original));XCTAssertNil(old.precompositions)
    }
    func testIndependentDefinitionCacheAndMissingReference()throws {
        var p=Project();p.width=320;p.height=180;p.background="000000"
        var a=Clip(kind:.shape,name:"A",track:0,start:0,duration:1);a.color="FF0000"
        let first=Precomposition(name:"red",width:320,height:180,fps:30,duration:1,tracks:[Track(name:"one")],clips:[a]);a.color="00FF00"
        let second=Precomposition(name:"green",width:320,height:180,fps:30,duration:1,tracks:[Track(name:"one")],clips:[a])
        var left=Clip(kind:.group,name:"left",track:0,start:0,duration:1);left.precompositionID=first.id;left.x=0.25;left.scale=0.2
        var right=left;right.id=UUID();right.name="right";right.x=0.75;right.precompositionID=second.id;p.clips=[left,right];p.precompositions=[first,second];_=try p.validated()
        let folder=FileManager.default.temporaryDirectory,bitmap=try frame(p,folder,0.5)
        XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x:80,y:90)?.usingColorSpace(.sRGB)).redComponent,0.8);XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x:240,y:90)?.usingColorSpace(.sRGB)).greenComponent,0.8)
        p.clips[0].precompositionID=UUID();XCTAssertThrowsError(try p.validated())
    }
    @MainActor func testNestedValidationAudioTimeDomainsAndSplit()throws {
        let s=store();defer{try? FileManager.default.removeItem(at:s.directory)}
        let asset=MediaAsset(name:"tone",file:"tone.wav",kind:.audio,duration:4);var a=Clip(kind:.audio,name:"voice",track:0,start:1,duration:3);a.assetID=asset.id;a.volume=0.5;a.audioFade=AudioFade(fadeIn:1,fadeOut:1);s.project.assets=[asset];s.project.clips=[a];s.selectedID=a.id
        let innerID=try s.createPrecomposition(name:"inner");let outerID=try s.createPrecomposition(name:"outer");let outer=try XCTUnwrap(s.project.clips.first{$0.id==outerID})
        let flat=s.project.audioRenderingProject,voice=try XCTUnwrap(flat.clips.first{$0.kind == .audio})
        XCTAssertEqual(voice.start,1);XCTAssertEqual(flat.effectiveAudioVolume(voice,at:1.5),0.25,accuracy:0.001);XCTAssertEqual(flat.clips.count,3)
        let trimmed=s.timelineChange(outer,delta:1,track:outer.track,edge:-1);s.edit(outerID){$0=trimmed};XCTAssertEqual(s.selected?.sourceOffset,1)
        let cropped=s.project.audioRenderingProject,v=try XCTUnwrap(cropped.clips.first{$0.kind == .audio});XCTAssertEqual(v.start,2);XCTAssertEqual(v.sourceOffset,1);XCTAssertEqual(cropped.effectiveAudioVolume(v,at:2),0.5,accuracy:0.001)
        s.seek(3);s.splitSelected();XCTAssertEqual(s.project.clips.count,2);let split=s.project.audioRenderingProject;XCTAssertEqual(split.clips.filter{$0.kind == .audio}.count,2)
        let before=s.project;let current=s.project.composition(s.project.clips[0])!;var cyclic=current;cyclic.clips[0].precompositionID=current.id
        let patch=try JSONSerialization.jsonObject(with:JSONEncoder().encode(cyclic.clips));XCTAssertThrowsError(try s.updatePrecomposition(current.id,properties:["clips":patch]));XCTAssertEqual(s.project,before)
        XCTAssertEqual(innerID == outerID,false)
    }
    @MainActor func testApplyRejectsConcurrentChangesAndRetainsNewMedia()async throws {
        let s=store();defer{try? FileManager.default.removeItem(at:s.directory)};let a=Clip(kind:.shape,name:"A",track:0,start:0,duration:1);s.project.clips=[a];s.selectedID=a.id;_ = try s.createPrecomposition(name:"scene");let c=s.project.precompositions![0];var draft=s.project.compositionProject(c);draft.clips[0].color="FF0000";draft.markers=[TimelineMarker(time:0.5,name:"内部マーカー")];draft.timelineRange=TimelineRange(start:0,end:1,loop:true);draft.background="222222"
        let expected=s.directory;let updated=try await s.applyPrecomposition(baseline:c,draft:draft,media:s.directory.appendingPathComponent("Media"),duration:1,expectedDirectory:expected,baselineLibrary:s.project.precompositions)
        XCTAssertEqual(updated.clips[0].color,"FF0000");XCTAssertEqual(updated.markers,draft.markers);XCTAssertEqual(updated.timelineRange,draft.timelineRange);XCTAssertEqual(updated.background,"222222");let before=s.project
        do{_ = try await s.applyPrecomposition(baseline:c,draft:draft,media:s.directory.appendingPathComponent("Media"),duration:1,expectedDirectory:expected);XCTFail("stale edits must fail")}catch{}
        XCTAssertEqual(s.project,before);s.undo();XCTAssertEqual(s.project.precompositions![0],c)
    }
    @MainActor func testNewMediaApplyPackageUndoAndSourceDeletion()async throws {
        let s=store();defer{try? FileManager.default.removeItem(at:s.directory)};let a=Clip(kind:.shape,name:"A",track:0,start:0,duration:1);s.project.clips=[a];s.selectedID=a.id;_ = try s.createPrecomposition(name:"media")
        let c=s.project.precompositions![0],source=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:source)}
        let filename=UUID().uuidString+".wav";try AdvancedTests().tone(at:source.appendingPathComponent(filename),duration:1)
        var draft=s.project.compositionProject(c);let asset=MediaAsset(name:"new tone",file:filename,kind:.audio,duration:1);draft.assets.append(asset);var sound=Clip(kind:.audio,name:"sound",track:0,start:0,duration:1);sound.assetID=asset.id;draft.clips.append(sound)
        _ = try await s.applyPrecomposition(baseline:c,draft:draft,media:source,duration:1,expectedDirectory:s.directory)
        XCTAssertTrue(s.project.usedAssetIDs.contains(asset.id));XCTAssertEqual(s.project.usageCount(asset.id),1);let target=s.directory.appendingPathComponent("Media").appendingPathComponent(filename);XCTAssertEqual(try Data(contentsOf:target),try Data(contentsOf:source.appendingPathComponent(filename)))
        s.undo();XCTAssertFalse(s.project.assets.contains{$0.id==asset.id});XCTAssertTrue(FileManager.default.fileExists(atPath:target.path));s.redo()
        let package=source.appendingPathComponent("saved.vmm");try ProjectPackage.write(s.project,media:s.directory.appendingPathComponent("Media"),to:package);XCTAssertTrue(FileManager.default.fileExists(atPath:package.appendingPathComponent("Media").appendingPathComponent(filename).path))
        XCTAssertThrowsError(try s.deletePrecomposition(c.id));s.deleteSelection();try s.deletePrecomposition(c.id);XCTAssertTrue(s.project.precompositions!.isEmpty)
    }
    @MainActor func testMCPAndScenePackageRetainCompositionDefinitions()async throws {
        let s=store();defer{try? FileManager.default.removeItem(at:s.directory)};let a=Clip(kind:.shape,name:"A",track:0,start:0,duration:1);s.project.clips=[a];s.selectedID=a.id
        let commands=EditorCommands();commands.store=s;let result=commands.execute(body:try JSONSerialization.data(withJSONObject:["command":"precomposition.create","name":"MCP"]));XCTAssertEqual(result.status,200)
        let c=try XCTUnwrap(s.project.precompositions?.first);try s.updatePrecomposition(c.id,properties:["name":"updated"]);let original=s.project
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),package=root.appendingPathComponent("Scene.vmm");try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        _ = try await s.saveScene(name:"scene",to:package);_ = try await s.insertScene(package,at:2);_=try s.project.validated();XCTAssertEqual(s.project.precompositions?.count,2);XCTAssertEqual(s.project.clips.filter{$0.precompositionID != nil}.count,2);s.undo();XCTAssertEqual(s.project,original)
    }
}

extension PrecompositionTests {
    @MainActor func testPlaybackWAVMP4AndTrimmedNestedPixels()async throws {
        let s=store();defer{s.pause();try? FileManager.default.removeItem(at:s.directory)}
        try AdvancedTests().tone(at:s.directory.appendingPathComponent("Media/tone.wav"),duration:3)
        let asset=MediaAsset(name:"tone",file:"tone.wav",kind:.audio,duration:3)
        var sound=Clip(kind:.audio,name:"sound",track:0,start:0,duration:2);sound.assetID=asset.id;sound.volume=0.5;sound.audioFade=AudioFade(fadeIn:0.25,fadeOut:0.5)
        var shape=Clip(kind:.shape,name:"box",track:1,start:0,duration:2);shape.color="FF0000";shape.scale=0.2;shape.putMotionKey(.x,time:0,value:0.25,easing:.linear);shape.putMotionKey(.x,time:2,value:0.75)
        s.project.assets=[asset];s.project.clips=[sound,shape];s.selectedIDs=[sound.id,shape.id];let inner=try s.createPrecomposition(name:"音声と図形");let outer=try s.createPrecomposition(name:"入れ子")
        s.edit(outer){$0.start=0.5;$0.sourceOffset=0.25;$0.duration=1.5;$0.rotation=15;$0.effects=[VisualEffect(kind:.glow)]}
        let project=s.project,root=s.directory.appendingPathComponent("qa");try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let movie=root.appendingPathComponent("precomposition.mp4"),wav=root.appendingPathComponent("mix.wav");try await MovieExporter.export(project:project,directory:s.directory,destination:movie){_ in};try await AudioOnlyExporter.export(project:project,directory:s.directory,destination:wav){_ in}
        let file=try AVAudioFile(forReading:wav),buffer=AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:AVAudioFrameCount(file.length))!;try file.read(into:buffer);let samples=buffer.floatChannelData![0]
        XCTAssertLessThan((0..<23000).map{abs(samples[$0])}.max()!,0.0001);XCTAssertGreaterThan((30000..<50000).map{abs(samples[$0])}.max()!,0.01)
        let generator=AVAssetImageGenerator(asset:AVURLAsset(url:movie));generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
        for time in [0.6,1.2,1.8]{let preview=try frame(project,s.directory,time),output=NSBitmapImageRep(cgImage:try generator.copyCGImage(at:CMTime(seconds:time,preferredTimescale:600),actualTime:nil));var error=0.0;for y in stride(from:0,to:180,by:4){for x in stride(from:0,to:320,by:4){let a=try XCTUnwrap(preview.colorAt(x:x,y:y)?.usingColorSpace(.sRGB)),b=try XCTUnwrap(output.colorAt(x:x,y:y)?.usingColorSpace(.sRGB));error+=abs(a.redComponent-b.redComponent)+abs(a.greenComponent-b.greenComponent)+abs(a.blueComponent-b.blueComponent)}};XCTAssertLessThan(error/(80*45*3),0.04)}
        s.playhead=0.5;s.play();try await Task.sleep(nanoseconds:600_000_000);XCTAssertTrue(s.playing);XCTAssertFalse(s.players.isEmpty);XCTAssertNotNil(s.playbackAudioEngine);s.pause()
        if let directory=ProcessInfo.processInfo.environment["VMM_PRECOMP_QA_ROOT"]{let target=URL(fileURLWithPath:directory);try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true);try FileManager.default.copyItem(at:movie,to:target.appendingPathComponent("precomposition.mp4"));try ProjectPackage.write(project,media:s.directory.appendingPathComponent("Media"),to:target.appendingPathComponent("Precomposition-QA.vmm"))}
        XCTAssertNotEqual(inner,outer)
    }
    @MainActor func testWindowDraftMediaIsolationApplyAndSnapshot()async throws {
        let s=store();defer{try? FileManager.default.removeItem(at:s.directory)};let a=Clip(kind:.shape,name:"A",track:0,start:0,duration:1);s.project.clips=[a];s.selectedID=a.id;_ = try s.createPrecomposition(name:"独立編集")
        let session=try await PrecompositionSession(owner:s,composition:s.project.precompositions![0],onClose:{});defer{session.window.close()};session.window.makeKeyAndOrderFront(nil)
        XCTAssertNotEqual(session.draft.directory,s.directory);session.draft.edit(a.id){$0.color="FF0000"};XCTAssertNotEqual(session.draft.project.clips[0].color,s.project.precompositions![0].clips[0].color)
        session.apply();for _ in 0..<100 where session.applying{try await Task.sleep(nanoseconds:20_000_000)};XCTAssertFalse(session.applying);XCTAssertNil(session.draft.error);XCTAssertEqual(s.project.precompositions![0].clips[0].color,"FF0000");s.undo();XCTAssertNotEqual(s.project.precompositions![0].clips[0].color,"FF0000")
        if let directory=ProcessInfo.processInfo.environment["VMM_PRECOMP_QA_ROOT"],let host=session.window.contentView{host.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:300_000_000);let rep=try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds));host.cacheDisplay(in:host.bounds,to:rep);try XCTUnwrap(rep.representation(using:.png,properties:[:])).write(to:URL(fileURLWithPath:directory).appendingPathComponent("editor.png"))}
    }
}
