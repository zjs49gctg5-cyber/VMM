import XCTest
import AVFoundation
@testable import VMM

final class RhythmTests:XCTestCase {
    @MainActor func testGridRepeatSliceUndoAndCompatibility()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-rhythm-\(UUID())")
        let store=EditorStore(preferencesDirectory:root);defer{store.pause();try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        var c=Clip(kind:.audio,name:"素材",track:0,start:0,duration:1);c.sourceOffset=0.25;c.playbackRate=2
        let asset=MediaAsset(name:"素材",file:"tone.wav",kind:.audio,duration:5);c.assetID=asset.id
        store.project.assets=[asset];store.project.clips=[c];store.selectedID=c.id
        store.editRhythm{$0.bpm=120;$0.division=2;$0.snap=true}
        XCTAssertEqual(store.snapped(0.31),0.2666666667,accuracy:0.000001)
        store.sliceAudioOnGrid(c.id)
        let pieces=store.project.clips.sorted{$0.start<$1.start};XCTAssertEqual(pieces.count,4)
        XCTAssertEqual(pieces.map(\.duration).reduce(0,+),1,accuracy:0.000001)
        for piece in pieces {XCTAssertEqual(piece.sourceOffset,0.25+piece.start*2,accuracy:0.000001)}
        _=try store.project.validated();store.undo();XCTAssertEqual(store.project.clips,[c])
        store.repeatAudio(c.id,count:8,onGrid:true)
        XCTAssertEqual(store.project.clips.count,8);XCTAssertEqual(try XCTUnwrap(store.project.clips.last).start,1.7666666667,accuracy:0.000001)
        XCTAssertTrue(store.project.clips.allSatisfy{$0.sourceOffset==0.25 && $0.duration<=0.267})
        _=try store.project.validated();store.undo();XCTAssertEqual(store.project.clips,[c])
        store.edit(c.id){$0.pitchSemitones=12}
        store.editRhythm{$0.enabled=false}
        XCTAssertFalse(store.project.rhythmEnabled);XCTAssertEqual(store.snapped(0.31),0.3,accuracy:0.000001)
        XCTAssertNil(store.project.audioProcessingClip(try XCTUnwrap(store.selected)).pitchSemitones)
        store.repeatAudio(c.id,count:8,onGrid:true);XCTAssertEqual(store.project.clips.count,1)
        store.editRhythm{$0.enabled=true};XCTAssertEqual(store.project.audioProcessingClip(try XCTUnwrap(store.selected)).pitchSemitones,12)
        store.project.tracks[0].locked=true;store.repeatAudio(c.id,count:8,onGrid:false);XCTAssertEqual(store.project.clips.count,1)
        let restored=try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(store.project));XCTAssertEqual(restored.rhythm,store.project.rhythm)
        var legacy=Project();legacy.clips=[c];let decoded=try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(legacy));XCTAssertNil(decoded.rhythm);XCTAssertNil(decoded.clips[0].pitchSemitones)
        legacy.rhythm=RhythmSettings(bpm:0);XCTAssertThrowsError(try legacy.validated())
    }
    @MainActor func testAPICommandsValidateAndEditRhythm()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-rhythm-api-\(UUID())")
        let store=EditorStore(preferencesDirectory:root),api=EditorCommands();api.store=store
        defer{store.pause();try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        var c=Clip(kind:.audio,name:"素材",track:0,start:0,duration:1)
        let asset=MediaAsset(name:"素材",file:"tone.wav",kind:.audio,duration:4);c.assetID=asset.id
        store.project.assets=[asset];store.project.clips=[c]
        func command(_ values:[String:Any])throws->Int {api.execute(body:try JSONSerialization.data(withJSONObject:values)).status}
        XCTAssertEqual(try command(["command":"rhythm.update","properties":["bpm":120,"division":2,"snap":true]]),200)
        XCTAssertEqual(try command(["command":"rhythm.update","properties":["bpm":0]]),400)
        XCTAssertEqual(store.project.rhythm?.bpm,120)
        XCTAssertEqual(try command(["command":"clip.update","clipID":c.id.uuidString,"properties":["pitchSemitones":7]]),200)
        XCTAssertEqual(try command(["command":"rhythm.repeat","clipID":c.id.uuidString,"count":4,"onGrid":true]),200)
        XCTAssertEqual(store.project.clips.count,4)
        store.undo();XCTAssertEqual(try command(["command":"rhythm.slice","clipID":c.id.uuidString]),200)
        XCTAssertEqual(store.project.clips.count,4)
    }
    func testPitchOfflineRealtimeAndMP4()async throws {
        let helper=AdvancedTests(),root=try helper.folder();defer{try? FileManager.default.removeItem(at:root)}
        let wav=root.appendingPathComponent("Media/tone.wav");try helper.tone(at:wav,duration:3)
        var c=Clip(kind:.audio,name:"音",track:0,start:0,duration:2);c.pitchSemitones=12
        let output=root.appendingPathComponent("pitch.caf");XCTAssertEqual(try AudioProcessor.process(decoded:wav,clip:c,destination:output),2,accuracy:0.001)
        XCTAssertGreaterThan(try helper.energy(output,frequency:2000),0.02);XCTAssertLessThan(try helper.energy(output,frequency:1000),0.01)
        let graph=AudioGraph(format:try AVAudioFile(forReading:wav).processingFormat,clip:c);XCTAssertEqual(try XCTUnwrap(graph.pitch).pitch,1200);XCTAssertEqual(try XCTUnwrap(graph.pitch).rate,1)
        let player=try ClipAudioPlayer(url:wav,clip:c,time:0,volume:0.01);player.pause()
        c.preservePitch=false;c.playbackRate=2;c.pitchSemitones = -12
        let combined=root.appendingPathComponent("combined.caf");_ = try AudioProcessor.process(decoded:wav,clip:c,destination:combined)
        XCTAssertGreaterThan(try helper.energy(combined,frequency:1000),0.02)
        c.playbackRate=1;c.preservePitch=true;c.pitchSemitones=12
        let asset=MediaAsset(name:"音",file:"tone.wav",kind:.audio,duration:3);c.assetID=asset.id
        var p=helper.project();p.rhythm=RhythmSettings();p.assets=[asset];p.clips=[c]
        let mp4=root.appendingPathComponent("pitch.mp4");try await MovieExporter.export(project:p,directory:root,destination:mp4){_ in}
        let decoded=root.appendingPathComponent("mp4.caf");let hasAudio=try await AudioProcessor.decode(source:mp4,destination:decoded);XCTAssertTrue(hasAudio)
        XCTAssertGreaterThan(try helper.energy(decoded,frequency:2000),0.015);XCTAssertLessThan(try helper.energy(decoded,frequency:1000),0.01)
        p.rhythm?.enabled=false
        let bypass=root.appendingPathComponent("bypass.mp4");try await MovieExporter.export(project:p,directory:root,destination:bypass){_ in}
        let bypassAudio=root.appendingPathComponent("bypass.caf");let bypassDecoded=try await AudioProcessor.decode(source:bypass,destination:bypassAudio);XCTAssertTrue(bypassDecoded)
        XCTAssertGreaterThan(try helper.energy(bypassAudio,frequency:1000),0.015);XCTAssertLessThan(try helper.energy(bypassAudio,frequency:2000),0.01)
        p.clips[0].pitchSemitones=25;XCTAssertThrowsError(try p.validated())
    }
}
