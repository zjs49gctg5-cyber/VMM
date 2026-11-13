import XCTest
import AVFoundation
@testable import VMM
final class AnimationAnalysisIntegrationTests:XCTestCase {
    @MainActor func testMCPAudioJobUndoLocksAndPresetPortability()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("analysis-command-"+UUID().uuidString),s=EditorStore(preferencesDirectory:root);s.autoSpeech=false;s.settings.autosaveSeconds=0;defer{try? FileManager.default.removeItem(at:s.directory);try? FileManager.default.removeItem(at:root)}
        try FileManager.default.createDirectory(at:s.directory.appendingPathComponent("Media"),withIntermediateDirectories:true);try AdvancedTests().tone(at:s.directory.appendingPathComponent("Media/tone.wav"),duration:1)
        let asset=MediaAsset(name:"tone",file:"tone.wav",kind:.audio,duration:1);var source=Clip(kind:.audio,name:"source",track:0,start:0,duration:1);source.assetID=asset.id;let target=Clip(kind:.shape,name:"target",track:1,start:0,duration:1);s.project=Project();s.project.assets=[asset];s.project.clips=[source,target]
        let commands=EditorCommands();commands.store=s;try MCPTools.validate(["clipID":target.id.uuidString,"sourceClipID":source.id.uuidString],command:"animation.analyzeAudio")
        let response=commands.execute(body:try JSONSerialization.data(withJSONObject:["command":"animation.analyzeAudio","clipID":target.id.uuidString,"sourceClipID":source.id.uuidString]));XCTAssertEqual(response.status,202);let job=try XCTUnwrap((JSONSerialization.jsonObject(with:response.body) as? [String:Any])?["jobID"] as? String)
        for _ in 0..<200{if commands.jobs[job]?["state"] as? String != "running"{break};try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertEqual(commands.jobs[job]?["state"] as? String,"completed",commands.jobs[job]?["error"] as? String ?? "");let reactive=try XCTUnwrap(s.project.clips[1].audioReactive);XCTAssertEqual(reactive.assetID,asset.id);XCTAssertTrue(s.mediaDeletionIDs(asset.id).contains(target.id))
        s.undo();XCTAssertNil(s.project.clips[1].audioReactive);s.redo();XCTAssertNotNil(s.project.clips[1].audioReactive)
        s.project.tracks[1].locked=true;do{try await s.analyzeReactiveAudio(clipID:target.id,sourceClipID:source.id);XCTFail("Locked target modified")}catch{}
        s.project.tracks[1].locked=false
        var style=ShapeStyle();style.path=AnimatedBezierShape();let preset=try EffectPreset(name:"path and pulse",shapeStyle:style,temporalMotion:TemporalMotion(),audioReactive:reactive).validated();s.applyPreset(preset,clipID:target.id);XCTAssertNil(s.error);XCTAssertNil(s.project.clips[1].audioReactive?.assetID);XCTAssertEqual(s.project.clips[1].shapeStyle,style);_=try s.project.validated()
        try MCPTools.validate(["clipID":target.id.uuidString,"sourceClipID":source.id.uuidString,"region":["x":0.1,"y":0.2,"width":0.3,"height":0.4],"sourceIn":0.5,"duration":1.25,"sampleRate":15.0,"followScale":true],command:"animation.track")
        XCTAssertThrowsError(try MCPTools.validate(["clipID":target.id.uuidString,"sourceClipID":source.id.uuidString,"region":"wrong","sourceIn":0,"duration":1],command:"animation.track"))
    }
    @MainActor func testCancellationDoesNotApplyAnalysis()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),s=EditorStore(preferencesDirectory:root);s.autoSpeech=false;s.settings.autosaveSeconds=0;defer{try? FileManager.default.removeItem(at:s.directory);try? FileManager.default.removeItem(at:root)}
        try FileManager.default.createDirectory(at:s.directory.appendingPathComponent("Media"),withIntermediateDirectories:true);try AdvancedTests().tone(at:s.directory.appendingPathComponent("Media/tone.wav"),duration:2)
        let asset=MediaAsset(name:"tone",file:"tone.wav",kind:.audio,duration:2);var source=Clip(kind:.audio,name:"source",track:0,start:0,duration:2);source.assetID=asset.id;let target=Clip(kind:.shape,name:"target",track:1,start:0,duration:2);s.project=Project();s.project.assets=[asset];s.project.clips=[source,target]
        let task=Task{@MainActor in try await s.analyzeReactiveAudio(clipID:target.id,sourceClipID:source.id)};task.cancel();do{try await task.value;XCTFail("Cancellation ignored")}catch{};XCTAssertNil(s.project.clips[1].audioReactive)
    }
}
