import XCTest
import AVFoundation
@testable import VMM

final class MIDIMotionTests:XCTestCase {
    private func be32(_ value:Int)->[UInt8] {[UInt8((value>>24)&255),UInt8((value>>16)&255),UInt8((value>>8)&255),UInt8(value&255)]}
    private func midi(format:Int=1,division:Int=480,tracks:[[UInt8]])->Data {
        var bytes=Array("MThd".utf8)+[0,0,0,6,UInt8(format>>8),UInt8(format&255),UInt8(tracks.count>>8),UInt8(tracks.count&255),UInt8((division>>8)&255),UInt8(division&255)]
        for track in tracks {bytes+=Array("MTrk".utf8)+be32(track.count)+track};return Data(bytes)
    }
    private let end:[UInt8]=[0,0xff,0x2f,0]
    private func sample()->Data {
        // Track 1: 120 BPM, changing to 60 BPM at tick 480.
        let tempo:[UInt8]=[0,0xff,0x51,3,0x07,0xa1,0x20,0x83,0x60,0xff,0x51,3,0x0f,0x42,0x40]+end
        // Track 2: C on tick 0; D on tick 480 using running status; zero-velocity E is ignored; channel 2 F at tick 960.
        let notes:[UInt8]=[0,0x90,60,100,0x83,0x60,62,80,0,64,0,0x83,0x60,0x91,65,127]+end
        return midi(tracks:[tempo,notes])
    }
    func testFormatOneTempoMapRunningStatusChannelsAndZeroVelocity()throws {
        let seq=try MIDIReader.parse(sample());XCTAssertEqual(seq.tracks,2);XCTAssertEqual(seq.tempoChanges,2)
        XCTAssertEqual(seq.notes.map(\.note),[60,62,65]);XCTAssertEqual(seq.notes.map(\.channel),[1,1,2]);XCTAssertEqual(seq.notes.map(\.track),[2,2,2])
        XCTAssertEqual(seq.notes[0].time,0,accuracy:1e-9);XCTAssertEqual(seq.notes[1].time,0.5,accuracy:1e-9);XCTAssertEqual(seq.notes[2].time,1.5,accuracy:1e-9)
    }
    func testRejectsUnsupportedMalformedAndBounds()throws {
        let good=midi(format:0,tracks:[[0,0x90,60,100]+end]);XCTAssertEqual(try MIDIReader.parse(good).notes.count,1)
        XCTAssertThrowsError(try MIDIReader.parse(midi(format:2,tracks:[end])))
        XCTAssertThrowsError(try MIDIReader.parse(midi(format:0,division:0xe728,tracks:[end])))
        XCTAssertThrowsError(try MIDIReader.parse(Data(good.dropLast())))
        XCTAssertThrowsError(try MIDIReader.parse(midi(format:0,tracks:[[0,0xff,0x51,3,0,0,0]+end])))
        XCTAssertThrowsError(try MIDIReader.parse(midi(format:0,tracks:[[0x80,0x80,0x80,0x80,0]+end])))
        XCTAssertThrowsError(try MIDIReader.parse(midi(format:0,tracks:[[0,60,100]+end])))
        XCTAssertThrowsError(try MIDIReader.parse(Data(repeating:0,count:2*1024*1024+1)))
        let tooMany=Array(repeating:[UInt8(0),0x90,60,100],count:50000).flatMap{$0}+end
        XCTAssertThrowsError(try MIDIReader.parse(midi(format:0,tracks:[tooMany])))
    }
    @MainActor func testBPMPhaseFramesMIDIChannelsExistingKeysLockAndUndo()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-midi-\(UUID())"),store=EditorStore(preferencesDirectory:root)
        defer{store.pause();try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        store.project=Project();var clip=Clip(kind:.shape,name:"motion",track:1,start:0,duration:3);clip.scale=1
        let existing=AnimationTrack(property:.x,keys:[AnimationKeyframe(time:0,value:0.2),AnimationKeyframe(time:2,value:0.8)])
        clip.animation=ClipAnimation(tracks:[existing]);store.project.clips=[clip]
        let before=store.project;var rhythm=RhythmSettings();rhythm.bpm=120;rhythm.offset=0.25
        let keys=try MusicMotionPlanner.keys(clip:clip,fps:30,kind:.pulse,strength:0.5,source:.bpm(rhythm,from:0))
        XCTAssertEqual(keys[0].time,0,accuracy:1e-9);XCTAssertEqual(keys[1].time,8.0/30,accuracy:1e-9)
        XCTAssertTrue(keys.allSatisfy{abs($0.time*30-($0.time*30).rounded())<1e-8})
        let seq=try MIDIReader.parse(sample())
        let noteKeys=try MusicMotionPlanner.keys(clip:clip,fps:30,kind:.pulse,strength:0.5,source:.midi(seq,from:0,channel:2))
        XCTAssertTrue(noteKeys.contains(where:{abs($0.time-1.5)<1e-9 && $0.value>1}))
        store.project.tracks[1].locked=true;XCTAssertThrowsError(try store.applyMusicMotion(id:clip.id,kind:.pulse,strength:0.5,source:.bpm(rhythm,from:0)));store.project.tracks[1].locked=false
        XCTAssertEqual(store.project,before)
        try store.applyMusicMotion(id:clip.id,kind:.pulse,strength:0.5,source:.bpm(rhythm,from:0))
        XCTAssertEqual(store.project.clips[0].animation?.tracks.first{$0.property == .x},existing)
        let applied=try XCTUnwrap(store.project.clips[0].animation?.tracks.first{$0.property == .scale}?.keys)
        XCTAssertEqual(applied.map(\.time),keys.map(\.time));XCTAssertEqual(applied.map(\.value),keys.map(\.value));XCTAssertEqual(applied.map(\.easing),keys.map(\.easing))
        let after=store.project;XCTAssertThrowsError(try store.applyMusicMotion(id:clip.id,kind:.pulse,strength:0.5,source:.bpm(rhythm,from:0)));XCTAssertEqual(store.project,after)
        XCTAssertEqual(store.project.clips[0].animated(at:0.6,aspectRatio:1).scale,1,accuracy:1e-8)
        let animated=store.project.clips[0],originalScale=animated.animated(at:1.3,aspectRatio:1).scale
        store.snapping=false;let trimmed=store.timelineChange(animated,delta:0.5,track:animated.track,edge:-1)
        XCTAssertEqual(trimmed.animated(at:1.3,aspectRatio:1).scale,originalScale,accuracy:1e-8)
        store.selectedID=animated.id;store.playhead=1;store.splitSelected()
        let right=try XCTUnwrap(store.selected);XCTAssertEqual(right.animated(at:1.3,aspectRatio:1).scale,originalScale,accuracy:1e-8)
        store.undo();XCTAssertEqual(store.project,after)
        store.undo();XCTAssertEqual(store.project,before)
    }
    func testHighDensityIsBoundedAndSameFrameVelocityCombined()throws {
        let clip=Clip(kind:.shape,name:"motion",track:0,start:0,duration:10),fps=30
        let notes=(0..<50000).map{_ in MIDINoteOn(time:0.5,velocity:64,note:60,channel:1,track:1)}+[MIDINoteOn(time:0.5,velocity:127,note:70,channel:1,track:1)]
        let keys=try MusicMotionPlanner.keys(clip:clip,fps:fps,kind:.pulse,strength:1,source:.midi(MIDISequence(notes:notes,tracks:1,tempoChanges:0),from:0,channel:0))
        XCTAssertEqual(keys.count,3);XCTAssertEqual(keys[1].value,1.5,accuracy:1e-9)
        let dense=(0..<250).map{MIDINoteOn(time:Double($0)/30,velocity:100,note:60,channel:1,track:1)}
        XCTAssertThrowsError(try MusicMotionPlanner.keys(clip:clip,fps:fps,kind:.pulse,strength:1,source:.midi(MIDISequence(notes:dense,tracks:1,tempoChanges:0),from:0,channel:0)))
    }
    @MainActor func testPreviewAndMP4ShowMIDIKeyframeMotion()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-midi-render-\(UUID())"),store=EditorStore(preferencesDirectory:root)
        defer{store.pause();try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        store.project=Project();store.project.width=320;store.project.height=180;store.project.background="000000"
        var clip=Clip(kind:.shape,name:"shape",track:1,start:0,duration:2);clip.scale=0.8;store.project.clips=[clip]
        let midi=MIDISequence(notes:[MIDINoteOn(time:0.5,velocity:127,note:60,channel:1,track:1)],tracks:1,tempoChanges:0)
        try store.applyMusicMotion(id:clip.id,kind:.pulse,strength:1,source:.midi(midi,from:0,channel:1))
        let helper=AdvancedTests(),before=try helper.pixels(helper.render(store.project,0.1,directory:store.directory)),hit=try helper.pixels(helper.render(store.project,0.5,directory:store.directory));XCTAssertNotEqual(before,hit)
        let file=root.appendingPathComponent("midi-motion.mp4");try await MovieExporter.export(project:store.project,directory:store.directory,destination:file){_ in}
        let gen=AVAssetImageGenerator(asset:AVURLAsset(url:file));gen.requestedTimeToleranceBefore = .zero;gen.requestedTimeToleranceAfter = .zero
        func pixels(_ time:Double)throws->[UInt8] {let image=try gen.copyCGImage(at:CMTime(seconds:time,preferredTimescale:600),actualTime:nil),context=try XCTUnwrap(RasterTools.bitmap(CGSize(width:320,height:180)));context.draw(image,in:CGRect(x:0,y:0,width:320,height:180));return try helper.pixels(context)}
        XCTAssertNotEqual(try pixels(0.1),try pixels(0.5))
    }
}
