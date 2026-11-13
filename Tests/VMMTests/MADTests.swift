import XCTest
import AVFoundation
import SwiftUI
@testable import VMM

final class MADTests:XCTestCase {
    @MainActor func store() -> EditorStore {EditorStore(preferencesDirectory:FileManager.default.temporaryDirectory.appendingPathComponent("vmm-mad-\(UUID())"))}
    @MainActor func clean(_ store:EditorStore) {store.pause();try? FileManager.default.removeItem(at:store.preferencesDirectory);try? FileManager.default.removeItem(at:store.directory)}
    @MainActor func setup(_ store:EditorStore)->Clip {
        var clip=Clip(kind:.audio,name:"test",track:0,start:0.11,duration:0.25)
        let asset=MediaAsset(name:"test.wav",file:"test.wav",kind:.audio,duration:2);clip.assetID=asset.id
        store.project.fps=60;store.project.assets=[asset];store.project.clips=[clip];store.project.rhythm=RhythmSettings(enabled:true,bpm:120,division:2);return clip
    }
    func testPitchPatternRejectsInvalidToken() {
        XCTAssertThrowsError(try MADArrangement.pitches("0 garbage"))
    }
    @MainActor func testPatternRestGridUndoAndFailures()throws {
        let s=store();defer{clean(s)};let c=setup(s),before=s.project
        let ids=try s.patternMAD(c.id,pitches:MADArrangement.pitches("0 - 12 -7"),at:1,gate:1)
        let copies=s.project.clips.filter{ids.contains($0.id)}.sorted{$0.start<$1.start}
        XCTAssertEqual(copies.map(\.start),[1,1.5,1.75]);XCTAssertEqual(copies.map(\.pitchSemitones),[0,12,-7]);XCTAssertEqual(s.project.clips.first{$0.id==c.id},c)
        XCTAssertTrue(copies.allSatisfy{$0.duration==0.25 && $0.preservePitch==true})
        s.undo();XCTAssertEqual(s.project,before)
        XCTAssertThrowsError(try s.patternMAD(c.id,pitches:[0,25],at:0));XCTAssertEqual(s.project,before)
        s.project.tracks[0].locked=true;XCTAssertThrowsError(try s.quantizeMAD([c.id]))
    }
    @MainActor func testFitQuantizeAtomicAndMCP()throws {
        let s=store();defer{clean(s)};let c=setup(s)
        try s.quantizeMAD([c.id]);XCTAssertEqual(s.project.clips[0].start,0)
        try s.fitMAD([c.id],beats:1);XCTAssertEqual(s.project.clips[0].playbackRate,0.5);XCTAssertEqual(s.project.clips[0].duration,0.5)
        let before=s.project;XCTAssertThrowsError(try s.fitMAD([c.id],beats:64));XCTAssertEqual(s.project,before)
        var other=c;other.id=UUID();other.track=1;s.project.clips.append(other);s.project.tracks[1].locked=true
        let locked=s.project;XCTAssertThrowsError(try s.quantizeMAD([c.id,other.id]));XCTAssertEqual(s.project,locked)
        let commands=EditorCommands();commands.store=s
        let body=try JSONSerialization.data(withJSONObject:["command":"rhythm.pattern","clipID":c.id.uuidString,"pattern":"0 - 12","gate":1])
        XCTAssertEqual(commands.execute(body:body).status,200)
        try MCPTools.validate(["clipIDs":[c.id.uuidString],"beats":0.5],command:"rhythm.fit")
        XCTAssertThrowsError(try MCPTools.validate(["clipIDs":[c.id.uuidString],"beats":"bad"],command:"rhythm.fit"))
    }
    func testFitRealtimeAndExport()async throws {
        let helper=AdvancedTests(),root=try helper.folder();defer{try? FileManager.default.removeItem(at:root)}
        let wav=root.appendingPathComponent("Media/tone.wav");try helper.tone(at:wav,duration:1)
        var clip=Clip(kind:.audio,name:"音",track:0,start:0,duration:0.5);clip=try MADArrangement.fit(clip,duration:1);clip.pitchSemitones=12
        let graph=AudioGraph(format:try AVAudioFile(forReading:wav).processingFormat,clip:clip);XCTAssertEqual(try XCTUnwrap(graph.pitch).rate,0.5);XCTAssertEqual(try XCTUnwrap(graph.pitch).pitch,1200)
        let player=try ClipAudioPlayer(url:wav,clip:clip,time:0,volume:0.01);player.pause()
        var project=helper.project();let asset=MediaAsset(name:"tone.wav",file:"tone.wav",kind:.audio,duration:1);clip.assetID=asset.id;project.assets=[asset];project.clips=[clip];project.rhythm=RhythmSettings(enabled:true)
        let mp4=root.appendingPathComponent("mad.mp4");try await MovieExporter.export(project:project,directory:root,destination:mp4){_ in}
        let decoded=root.appendingPathComponent("mad.caf");let found=try await AudioProcessor.decode(source:mp4,destination:decoded);XCTAssertTrue(found)
        XCTAssertGreaterThan(try helper.energy(decoded,frequency:2000),0.015);XCTAssertLessThan(try helper.energy(decoded,frequency:1000),0.01)
    }
    @MainActor func testNativeModeSnapshots()async throws {
        guard let output=ProcessInfo.processInfo.environment["VMM_MAD_QA"] else {throw XCTSkip("Opt-in native music mode snapshots")}
        _ = NSApplication.shared;NSApp.setActivationPolicy(.regular);NSApp.appearance=NSAppearance(named:.darkAqua)
        let root=URL(fileURLWithPath:output);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let s=store();defer{clean(s);VMMLocalization.language = .japanese};let clip=setup(s);s.selectedID=clip.id
        for language in UILanguage.allCases {
            VMMLocalization.language=language
            for page in 0...1 {
                let host=NSHostingView(rootView:MADWorkspace(store:s,initialPage:page).preferredColorScheme(.dark).vmmAppearance(s.settings))
                let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1040,height:730),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
                window.isReleasedWhenClosed=false;window.appearance=NSAppearance(named:.darkAqua);window.contentView=host
                window.makeKeyAndOrderFront(nil);host.layoutSubtreeIfNeeded();host.displayIfNeeded();try await Task.sleep(nanoseconds:100_000_000)
                if page==1,language == .japanese,ProcessInfo.processInfo.environment["VMM_MAD_HOLD"]=="1" {try await Task.sleep(nanoseconds:45_000_000_000)}
                let bitmap=try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds));host.cacheDisplay(in:host.bounds,to:bitmap)
                try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:root.appendingPathComponent("mad-\(language.rawValue)-\(page).png"));window.close()
            }
        }
    }
}
