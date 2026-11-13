import XCTest
import SwiftUI
import AnimationScriptRuntime
@testable import VMM

final class ScriptEditingTests:XCTestCase {
    func testUnfinishedDraftSurvivesCloseSampleSwitchAndIncomingEdits()throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-script-drafts-\(UUID())")
        defer{try? FileManager.default.removeItem(at:directory)}
        let clipID=UUID(),repo=ScriptDraftRepository(directory:directory,scope:"project-A",clipID:clipID,origin:"workspace")
        var draft=ScriptAnimationDraft(definition:AnimationDefinition.scriptSamples[0],values:["amplitude":0.125],seed:42)
        draft.source="function animate(input) { // 未完成😀\n";draft.parameterJSON="[{"
        var session=ScriptDraftSession(draft);try repo.save(session)
        session=try XCTUnwrap(repo.load());XCTAssertEqual(session.drafts[session.active],draft)
        session.select(ScriptAnimationDraft(definition:AnimationDefinition.scriptSamples[1]));try repo.save(session)
        session=try XCTUnwrap(repo.load());XCTAssertEqual(session.active,"js.orbit")
        session.select(ScriptAnimationDraft(definition:AnimationDefinition.scriptSamples[0]))
        XCTAssertEqual(session.drafts[session.active],draft)
        session.mergeIncoming(["amplitude":0.18],definitionID:"js.wave")
        XCTAssertEqual(session.drafts[session.active]?.values["amplitude"],0.18)
        XCTAssertEqual(session.drafts[session.active]?.source,draft.source)
        XCTAssertEqual(session.drafts[session.active]?.seed,42)
        XCTAssertEqual(session.drafts[session.active]?.packageID,draft.packageID)
        XCTAssertNil(try ScriptDraftRepository(directory:directory,scope:"project-B",clipID:clipID,origin:"workspace").load())
        XCTAssertNil(try ScriptDraftRepository(directory:directory,scope:"project-A",clipID:UUID(),origin:"workspace").load())
        // A persistence failure must not destroy the previous valid draft.
        var invalid=session;invalid.drafts[session.active]?.values["amplitude"] = .nan
        XCTAssertThrowsError(try repo.save(invalid));XCTAssertEqual(try repo.load()?.active,"js.orbit")
    }
    func testSharedSettingsDefaultsSeedStableIdentityAndLegacyDecode()async throws {
        var draft=ScriptAnimationDraft(definition:AnimationDefinition.scriptSamples[0],values:["amplitude":0.12345,"cycles":3],seed:987)
        draft.source="function animate(i) { return {y:(i.random()-0.5)*i.params.amplitude}; }"
        let available=Clip(kind:.shape,name:"test",track:0,start:0,duration:1).availableAnimatedProperties
        let first=try draft.sharedPackage(available:available)
        let imported=try DataExtensionPackage.decode(JSONEncoder().encode(first))
        let definition=try XCTUnwrap(imported.animations.first)
        XCTAssertEqual(try definition.resolved([:]),["amplitude":0.12345,"cycles":3])
        XCTAssertEqual(definition.scriptSeed,987)
        let worker=ScriptAnimationTests().worker
        func request(values:[String:Double],seed:UInt32)->ScriptRequest {ScriptRequest(source:draft.source,duration:1,fps:30,width:320,height:180,seed:seed,parameters:values,base:["y":0.5],properties:["y"])}
        let before=try await ScriptRunner.evaluate(request(values:draft.values,seed:draft.seedValue!),worker:worker)
        let after=try await ScriptRunner.evaluate(request(values:definition.resolved([:]),seed:definition.scriptSeed!),worker:worker)
        XCTAssertEqual(before,after)
        draft.values["amplitude"]=0.2;XCTAssertEqual(try draft.sharedPackage(available:available).id,first.id)
        let legacy=try JSONDecoder().decode(AnimationDefinition.self,from:Data("{\"id\":\"legacy\",\"name\":\"Legacy\",\"parameters\":[],\"tracks\":[],\"script\":\"function animate(i){return {y:0};}\",\"scriptOutputs\":[{\"property\":\"y\",\"offset\":true}]}".utf8))
        XCTAssertNil(legacy.scriptSeed)
        draft.seed=1.5;XCTAssertNil(draft.seedValue);XCTAssertThrowsError(try draft.sharedPackage(available:available))
    }
    func testCodeLineDiagnosticsAndUnicodeRanges()async throws {
        let source="function animate(input) {\n  const label = '日本語😀';\n  throw Error(label);\n}"
        let request=ScriptRequest(source:source,duration:1,fps:30,width:320,height:180,seed:1,parameters:[:],base:["y":0.5],properties:["y"])
        do{_=try await ScriptRunner.evaluate(request,worker:ScriptAnimationTests().worker);XCTFail("Expected a code error")}catch{
            XCTAssertEqual((error as? ScriptError)?.sourceLine,3,error.localizedDescription)
        }
        let range=try XCTUnwrap(ScriptSourceLines.range(2,in:source))
        XCTAssertEqual((source as NSString).substring(with:range),"  const label = '日本語😀';\n")
        XCTAssertNil(ScriptSourceLines.range(0,in:source));XCTAssertNil(ScriptSourceLines.range(99,in:source))
        XCTAssertEqual(ScriptSourceLines.range(1,in:""),NSRange(location:0,length:0))
    }
    @MainActor func testPreflightLimitsAndAudioTemplateDoNotMutateProject()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-script-limits-\(UUID())"),store=EditorStore(preferencesDirectory:root)
        defer{try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        store.autoSpeech=false;store.settings.autosaveSeconds=0
        let clip=Clip(kind:.audio,name:"Audio",track:0,start:0,duration:400)
        let sample=try XCTUnwrap(AnimationDefinition.scriptSamples(for:clip).first)
        XCTAssertEqual(sample.targetProperties,[.volume]);_=try sample.validated()
        store.project.fps=60;store.project.clips=[clip];let before=store.project
        do{_=try await store.runScriptAnimation(sample,packageID:"test.limits",values:[:],clipID:clip.id,apply:true);XCTFail("Should reject before launching the helper")}catch{XCTAssertTrue(error.localizedDescription.contains("20,000"))}
        XCTAssertEqual(store.project,before);XCTAssertFalse(store.scriptGenerating)
        XCTAssertNoThrow(try ScriptGenerationLimits.validate(duration:Double(20000)/60,fps:60))
        XCTAssertThrowsError(try ScriptGenerationLimits.validate(duration:334,fps:60))
    }
    @MainActor func testCodeEditorSnapshotAndErrorHighlight()async throws {
        guard let output=testArtifactDirectory() else{throw XCTSkip("Opt-in native editor snapshot")}
        try FileManager.default.createDirectory(atPath:output,withIntermediateDirectories:true)
        let source="function animate(input) {\n  const label = '日本語😀';\n  throw Error(label);\n}\n"
        let host=NSHostingView(rootView:ScriptCodeEditor(source:.constant(source),errorLine:3))
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:780,height:320),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.contentView=host;defer{window.close()}
        host.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:100_000_000)
        func findText(_ view:NSView)->NSTextView?{if let text=view as? NSTextView{return text};return view.subviews.compactMap{findText($0)}.first}
        let text=try XCTUnwrap(findText(host));XCTAssertEqual(text.string,source);XCTAssertNotNil(text.enclosingScrollView?.verticalRulerView)
        let range=try XCTUnwrap(ScriptSourceLines.range(3,in:source))
        XCTAssertNotNil(text.layoutManager?.temporaryAttribute(.backgroundColor,atCharacterIndex:range.location,effectiveRange:nil))
        let bitmap=try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds));host.cacheDisplay(in:host.bounds,to:bitmap)
        try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:URL(fileURLWithPath:output).appendingPathComponent("script-code-editor.png"))
    }
    @MainActor func testEditorRestoresDraftAndPassesCurrentValues()async throws {
        guard let output=testArtifactDirectory() else{throw XCTSkip("Opt-in native editor integration")}
        try FileManager.default.createDirectory(atPath:output,withIntermediateDirectories:true)
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-script-editor-ui-\(UUID())"),store=EditorStore(preferencesDirectory:root)
        defer{try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        store.autoSpeech=false;store.settings.autosaveSeconds=0
        let clip=Clip(kind:.shape,name:"UI QA",track:0,start:0,duration:4),definition=AnimationDefinition.scriptSamples[0]
        store.project.clips=[clip];let before=store.project
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1040,height:860),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;defer{window.close()}
        func makeEditor(_ amplitude:Double)->NSHostingView<ScriptAnimationEditor> {
            NSHostingView(rootView:ScriptAnimationEditor(store:store,clip:clip,initialDefinition:definition,initialValues:["amplitude":amplitude,"cycles":2],valueOverrides:["amplitude":amplitude],initialSeed:42))
        }
        func textViews(_ view:NSView)->[NSTextView] {(view as? NSTextView).map{[$0]} ?? view.subviews.flatMap{textViews($0)}}
        var host=makeEditor(0.125);window.contentView=host;host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds:450_000_000)
        let code=try XCTUnwrap(textViews(host).first)
        let unfinished="function animate(input) { // 保存される下書き😀\n"
        code.string=unfinished;code.delegate?.textDidChange?(Notification(name:NSText.didChangeNotification,object:code))
        try await Task.sleep(nanoseconds:450_000_000)
        let repo=ScriptDraftRepository(directory:root,scope:store.directory.standardizedFileURL.path,clipID:clip.id,origin:"workspace")
        var session=try XCTUnwrap(repo.load());var draft=try XCTUnwrap(session.drafts[session.active])
        XCTAssertEqual(draft.source,unfinished);XCTAssertEqual(draft.values["amplitude"],0.125);XCTAssertEqual(draft.seed,42)
        host=makeEditor(0.18);window.contentView=host;host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds:450_000_000)
        XCTAssertEqual(textViews(host).first?.string,unfinished)
        session=try XCTUnwrap(repo.load());draft=try XCTUnwrap(session.drafts[session.active]);XCTAssertEqual(draft.values["amplitude"],0.18)
        XCTAssertEqual(store.project,before)
        let bitmap=try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds));host.cacheDisplay(in:host.bounds,to:bitmap)
        try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:URL(fileURLWithPath:output).appendingPathComponent("script-animation-editor.png"))
    }
}
