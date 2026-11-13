import XCTest
import AVFoundation
import AnimationScriptRuntime
@testable import VMM

final class ScriptAnimationTests:XCTestCase {
    var worker:URL {URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/debug/VMMAnimationWorker")}
    func request(_ source:String)->ScriptRequest {ScriptRequest(source:source,duration:1,fps:30,width:320,height:180,seed:42,parameters:[:],base:["x":0.5,"y":0.5],properties:["y"])}
    func testSchemaBackwardCompatibilityAndVersionGate()throws {
        let legacy=DataExtensionPackage.sample
        XCTAssertEqual(try DataExtensionPackage.decode(JSONEncoder().encode(legacy)),legacy)
        let package=DataExtensionPackage.scriptSample
        XCTAssertEqual(try DataExtensionPackage.decode(JSONEncoder().encode(package)),package)
        if let output=ProcessInfo.processInfo.environment["VMM_JS_SAMPLE_OUTPUT"] {let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys];try encoder.encode(package).write(to:URL(fileURLWithPath:output),options:.atomic)}
        var bad=package;bad.version=1;XCTAssertThrowsError(try bad.validated())
        bad=package;bad.animations[0].script=String(repeating:"a",count:65537);XCTAssertThrowsError(try bad.validated())
        bad=package;bad.animations[0].scriptOutputs=[];XCTAssertThrowsError(try bad.validated())
        let c=Clip(kind:.shape,name:"test",track:0,start:0,duration:1)
        XCTAssertThrowsError(try package.animations[0].bake(clip:c,fps:30,values:[:]))
        XCTAssertNil(try JSONDecoder().decode(Clip.self,from:JSONEncoder().encode(c)).customAnimation)
    }
    func testIsolatedJavaScriptInputsRandomnessAndExceptionValidation()async throws {
        let script="""
        function animate(i) {
          if(typeof fetch!=='undefined' || typeof require!=='undefined' || typeof ObjC!=='undefined' || typeof Date!=='undefined') throw Error('unexpected host');
          if(!Object.isFrozen(i) || !Object.isFrozen(i.params) || !Object.isFrozen(i.base)) throw Error('mutable input');
          return {y:i.base.y+i.random()*0.1+Math.random()*0.01};
        }
        """
        let r=request(script),a=try await ScriptRunner.evaluate(r,worker:worker),b=try await ScriptRunner.evaluate(r,worker:worker)
        XCTAssertEqual(a,b);XCTAssertEqual(a.count,31);XCTAssertNotEqual(a[0],a[1]);XCTAssertTrue(a.allSatisfy{(0.5...0.61).contains($0[0])})
        for source in ["function animate( {", "function animate(i){throw Error('sample failure');}", "function animate(i){return {y:NaN};}", "function animate(i){return {y:Infinity};}", "function animate(i){return {x:0,y:0};}", "async function animate(i){return {y:0};}"] {
            do{_=try await ScriptRunner.evaluate(request(source),worker:worker);XCTFail("Invalid script succeeded")}catch{XCTAssertFalse(error.localizedDescription.isEmpty)}
        }
        var proto=request("function animate(i){return {y:i.params['__proto__']};}");proto.parameters=["__proto__":0.25]
        let protoRows=try await ScriptRunner.evaluate(proto,worker:worker);XCTAssertEqual(protoRows.first,[0.25])
    }
    func testTimeoutCancellationAndSuccessfulRecovery()async throws {
        let started=ProcessInfo.processInfo.systemUptime
        do{_=try await ScriptRunner.evaluate(request("function animate(i){while(true){};}"),worker:worker,timeout:0.35);XCTFail("Loop was not stopped")}catch{XCTAssertTrue(error.localizedDescription.contains("timed out"))}
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime-started,3)
        let r=request("function animate(i){while(true){};}"),executable=worker
        let task=Task{try await ScriptRunner.evaluate(r,worker:executable)}
        try await Task.sleep(nanoseconds:150_000_000);task.cancel()
        do{_=try await task.value;XCTFail("Cancellation was ignored")}catch{XCTAssertTrue(error is CancellationError)}
        let recovered=try await ScriptRunner.evaluate(request("function animate(i){return {y:i.t};}"),worker:worker);XCTAssertEqual(recovered.last,[1])
    }
    @MainActor func testTestGenerationApplyUndoSnapshotAndCancellation()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-js-store-\(UUID())"),s=EditorStore(preferencesDirectory:root)
        s.autoSpeech=false;s.settings.autosaveSeconds=0
        defer{try? FileManager.default.removeItem(at:s.directory);try? FileManager.default.removeItem(at:root)}
        var c=Clip(kind:.shape,name:"js",track:0,start:2,duration:1);c.animationOffset=1
        let x=AnimationTrack(property:.x,keys:[AnimationKeyframe(time:1,value:0.4),AnimationKeyframe(time:2,value:0.6)])
        c.animation=ClipAnimation(tracks:[x]);s.project.clips=[c];let before=s.project,definition=AnimationDefinition.scriptSamples[0]
        let count=try await s.runScriptAnimation(definition,packageID:"test.js",values:["amplitude":0.1,"cycles":1],seed:123,clipID:c.id,apply:false,worker:worker)
        XCTAssertGreaterThan(count,2);XCTAssertEqual(s.project,before);XCTAssertFalse(s.scriptGenerating)
        try await s.runScriptAnimation(definition,packageID:"test.js",values:["amplitude":0.1,"cycles":1],seed:123,clipID:c.id,apply:true,worker:worker)
        let applied=s.project;XCTAssertEqual(applied.clips[0].customAnimation?.seed,123);XCTAssertEqual(applied.clips[0].animation?.tracks.first{$0.property == .x},x)
        XCTAssertEqual(applied.clips[0].animation?.tracks.first{$0.property == .y}?.keys.first?.time,1)
        XCTAssertEqual(applied.clips[0].motionValue(.y,at:1.25),0.5+sin(0.25*2*Double.pi)*0.1,accuracy:0.001)
        s.undo();XCTAssertEqual(s.project,before);s.redo();XCTAssertEqual(s.project,applied)
        let url=root.appendingPathComponent("script.vmm");try ProjectPackage.write(applied,media:s.directory.appendingPathComponent("Media"),to:url)
        XCTAssertEqual(try JSONDecoder().decode(Project.self,from:Data(contentsOf:url.appendingPathComponent("project.json"))).validated(),applied)
        var slow=definition;slow.script="function animate(i){while(true){}}"
        let executable=worker
        let task=Task{try await s.runScriptAnimation(slow,packageID:"test.js",values:[:],clipID:c.id,apply:true,worker:executable)}
        try await Task.sleep(nanoseconds:100_000_000);XCTAssertTrue(s.scriptGenerating);s.cancelScriptAnimation()
        do{_=try await task.value;XCTFail("Cancelled apply succeeded")}catch{XCTAssertTrue(error is CancellationError)}
        XCTAssertEqual(s.project,applied);XCTAssertFalse(s.scriptGenerating)
        s.project.tracks[0].locked=true
        do{_=try await s.runScriptAnimation(definition,packageID:"test.js",values:[:],clipID:c.id,apply:true,worker:worker);XCTFail("Locked clip changed")}catch{}
    }
    @MainActor func testEditsDuringGenerationRejectStaleResult()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-js-stale-\(UUID())"),s=EditorStore(preferencesDirectory:root)
        s.autoSpeech=false;s.settings.autosaveSeconds=0
        defer{try? FileManager.default.removeItem(at:s.directory);try? FileManager.default.removeItem(at:root)}
        let c=Clip(kind:.shape,name:"stale",track:0,start:0,duration:1);s.project.clips=[c]
        var def=AnimationDefinition.scriptSamples[0];def.script="function animate(i){let n=0;for(let j=0;j<1000000;j++) n+=j;return {y:n*0+i.t};}"
        let executable=worker
        let task=Task{try await s.runScriptAnimation(def,packageID:"test.js",values:[:],clipID:c.id,apply:true,worker:executable)}
        try await Task.sleep(nanoseconds:20_000_000);s.project.clips[0].name="edited";let edited=s.project
        do{_=try await task.value;XCTFail("Stale result applied")}catch{XCTAssertTrue(error.localizedDescription.contains("変更"),error.localizedDescription)}
        XCTAssertEqual(s.project,edited);XCTAssertFalse(s.scriptGenerating)
    }
    @MainActor func testScriptAPIJobsAndCancellation()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-js-api-\(UUID())"),s=EditorStore(preferencesDirectory:root,scriptWorkerExecutable:worker)
        s.autoSpeech=false;s.settings.autosaveSeconds=0
        defer{try? FileManager.default.removeItem(at:s.directory);try? FileManager.default.removeItem(at:root)}
        let c=Clip(kind:.shape,name:"api",track:0,start:0,duration:1);s.project.clips=[c]
        var package=DataExtensionPackage.scriptSample;package.animations[0].scriptSeed=987;try s.installDataExtension(package)
        let api=EditorCommands();api.store=s
        let command:[String:Any]=["command":"animation.applyDefinition","packageID":DataExtensionPackage.scriptSample.id,"definitionID":"js.wave","clipID":c.id.uuidString,"seed":12]
        var invalid=command;invalid["seed"] = -1
        XCTAssertEqual(api.execute(body:try JSONSerialization.data(withJSONObject:invalid)).status,400)
        XCTAssertEqual(api.execute(body:Data("{\"command\":\"extension.install\",\"package\":12}".utf8)).status,400)
        let response=api.execute(body:try JSONSerialization.data(withJSONObject:command))
        XCTAssertEqual(response.status,202)
        let job=try XCTUnwrap((try JSONSerialization.jsonObject(with:response.body) as? [String:Any])?["jobID"] as? String)
        for _ in 0..<150 {if api.jobs[job]?["state"] as? String != "running"{break};try await Task.sleep(nanoseconds:20_000_000)}
        XCTAssertEqual(api.jobs[job]?["state"] as? String,"completed",api.jobs[job]?["error"] as? String ?? "")
        XCTAssertEqual(s.project.clips[0].customAnimation?.seed,12)
        var shared=command;shared.removeValue(forKey:"seed")
        let sharedResponse=api.execute(body:try JSONSerialization.data(withJSONObject:shared))
        let sharedJob=try XCTUnwrap((try JSONSerialization.jsonObject(with:sharedResponse.body) as? [String:Any])?["jobID"] as? String)
        for _ in 0..<150 {if api.jobs[sharedJob]?["state"] as? String != "running"{break};try await Task.sleep(nanoseconds:20_000_000)}
        XCTAssertEqual(api.jobs[sharedJob]?["state"] as? String,"completed")
        XCTAssertEqual(s.project.clips[0].customAnimation?.seed,987)
        let cancel=api.execute(body:Data("{\"command\":\"animation.cancelGeneration\"}".utf8));XCTAssertEqual(cancel.status,200)
    }
    func testScriptPreviewAndActualMP4()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-js-export-\(UUID())");try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        var p=Project();p.width=320;p.height=180;p.fps=30;p.background="000000"
        var c=Clip(kind:.shape,name:"js orbit",track:0,start:0,duration:1);c.color="FF0000";c.scale=0.05
        let def=AnimationDefinition.scriptSamples[1],values=["amplitude":0.2,"cycles":1.0]
        let request=ScriptRequest(source:def.script!,duration:1,fps:30,width:320,height:180,seed:1,parameters:values,base:["x":0.5,"y":0.5],properties:["x","y"])
        let rows=try await ScriptRunner.evaluate(request,worker:worker)
        let outputs=def.scriptOutputs!
        c.animation=ClipAnimation(tracks:try outputs.enumerated().map{index,o in try AnimationDefinition.reduce(rows.enumerated().map{i,row in AnimationKeyframe(time:Double(i)/30,value:0.5+row[index],easing:.linear)},property:o.property)})
        c.customAnimation=CustomAnimationInstance(packageID:"test.js",definition:def,values:values,seed:1);p.clips=[c];_=try p.validated()
        let output=root.appendingPathComponent("script.mp4");try await MovieExporter.export(project:p,directory:root,destination:output){_ in}
        let gen=AVAssetImageGenerator(asset:AVURLAsset(url:output));gen.requestedTimeToleranceBefore = .zero;gen.requestedTimeToleranceAfter = .zero
        for time in [0.2,0.5,0.8] {
            let ctx=try XCTUnwrap(RasterTools.bitmap(CGSize(width:320,height:180)));FrameRenderer().draw(project:p,directory:root,time:time,context:ctx,size:CGSize(width:320,height:180))
            let preview=NSBitmapImageRep(cgImage:try XCTUnwrap(ctx.makeImage())),frame=NSBitmapImageRep(cgImage:try gen.copyCGImage(at:CMTime(seconds:time,preferredTimescale:600),actualTime:nil)),shown=c.animated(at:time)
            let x=Int(shown.x*320),y=Int(shown.y*180)
            XCTAssertGreaterThan(try XCTUnwrap(preview.colorAt(x:x,y:y)?.usingColorSpace(.sRGB)).redComponent,0.8)
            XCTAssertGreaterThan(try XCTUnwrap(frame.colorAt(x:x,y:y)?.usingColorSpace(.sRGB)).redComponent,0.7)
            XCTAssertLessThan(try XCTUnwrap(frame.colorAt(x:160,y:90)?.usingColorSpace(.sRGB)).redComponent,0.2)
        }
    }
}
