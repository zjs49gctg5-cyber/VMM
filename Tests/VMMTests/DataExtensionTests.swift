import XCTest
import AVFoundation
@testable import VMM

final class DataExtensionTests:XCTestCase {
    func testSchemaRoundTripRejectsInvalidAndBoundedExpressions()throws {
        let package=DataExtensionPackage.sample,data=try JSONEncoder().encode(package)
        XCTAssertEqual(try DataExtensionPackage.decode(data),package)
        if let output=ProcessInfo.processInfo.environment["VMM_EXTENSION_SAMPLE_OUTPUT"] {
            let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
            try encoder.encode(package).write(to:URL(fileURLWithPath:output),options:.atomic)
        }
        var bad=package;bad.version=3;XCTAssertThrowsError(try bad.validated())
        bad=package;bad.id="../evil";XCTAssertThrowsError(try bad.validated())
        bad=package;bad.animations[0].parameters[0].defaultValue = .nan;XCTAssertThrowsError(try bad.validated())
        bad=package;bad.animations[0].tracks[0].expression=AnimationExpression(op:.multiply,args:[]);XCTAssertThrowsError(try bad.validated())
        bad=package;bad.animations[0].tracks[0].expression=AnimationExpression(op:.parameter,parameter:"missing");XCTAssertThrowsError(try bad.validated())
        var deep=AnimationExpression(op:.time)
        for _ in 0..<14 {deep=AnimationExpression(op:.sin,args:[deep])}
        bad=package;bad.animations[0].tracks[0].expression=deep;XCTAssertThrowsError(try bad.validated())
        XCTAssertThrowsError(try DataExtensionPackage.decode(Data(repeating:32,count:1_048_577)))
        let invalid=Data("{\"version\":1,\"id\":\"test\",\"name\":\"test\",\"author\":\"\",\"revision\":\"1\",\"animations\":[{\"id\":\"a\",\"name\":\"a\",\"parameters\":[],\"tracks\":[{\"property\":\"x\",\"offset\":true,\"expression\":{\"op\":\"exec\"}}]}],\"presets\":[]}".utf8)
        XCTAssertThrowsError(try DataExtensionPackage.decode(invalid))
        XCTAssertThrowsError(try package.animations[0].resolved(["amplitude":1]))
        XCTAssertThrowsError(try package.animations[0].resolved(["unknown":0]))
    }
    func testBakedFramesAccuracyOffsetsAndLimits()throws {
        let definition=DataExtensionPackage.sample.animations[0]
        var c=Clip(kind:.shape,name:"wave",track:0,start:2,duration:4);c.y=0.4;c.animationOffset=1
        let tracks=try definition.bake(clip:c,fps:60,values:["amplitude":0.12,"cycles":3])
        XCTAssertEqual(tracks[0].keys.first?.time,1);XCTAssertEqual(tracks[0].keys.last?.time,5)
        for i in 0...240 {let t=Double(i)/60;let expected=0.4+0.12*sin(t/4*3*2*Double.pi);XCTAssertEqual(interpolate(tracks[0].keys,at:1+t,fallback:0),expected,accuracy:0.000101)}
        XCTAssertLessThan(tracks[0].keys.count,241)
        c.duration=400;XCTAssertThrowsError(try definition.bake(clip:c,fps:60,values:[:]))
        var high=definition;high.parameters[1].maximum=1000;c.duration=20
        XCTAssertThrowsError(try high.bake(clip:c,fps:60,values:["amplitude":0.5,"cycles":400]))
        var zero=definition;zero.tracks[0].expression=AnimationExpression(op:.divide,args:[AnimationExpression(op:.time),AnimationExpression(op:.constant,value:0)])
        XCTAssertThrowsError(try zero.bake(clip:c,fps:30,values:[:]))
        c.kind = .audio;XCTAssertThrowsError(try definition.bake(clip:c,fps:30,values:[:]))
    }
    @MainActor func testInstallationUpdatesDisabledReloadAndAtomicApplication()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-data-extension-\(UUID())")
        let s=EditorStore(preferencesDirectory:root);s.autoSpeech=false;s.settings.autosaveSeconds=0
        defer{try? FileManager.default.removeItem(at:s.directory);try? FileManager.default.removeItem(at:root)}
        var c=Clip(kind:.shape,name:"wave",track:0,start:0,duration:2);c.animationOffset=1
        let x=AnimationTrack(property:.x,keys:[AnimationKeyframe(time:1,value:0.3),AnimationKeyframe(time:3,value:0.7)])
        c.animation=ClipAnimation(tracks:[x]);s.project.clips=[c];let before=s.project,package=DataExtensionPackage.sample
        try s.installDataExtension(package);XCTAssertEqual(s.project,before);XCTAssertThrowsError(try s.installDataExtension(package))
        var updated=package;updated.revision="1.1";try s.installDataExtension(updated,replace:true)
        try s.setDataExtensionEnabled(package.id,false);XCTAssertTrue(s.enabledDataExtensions.isEmpty)
        let reloaded=EditorStore(preferencesDirectory:root);defer{try? FileManager.default.removeItem(at:reloaded.directory)}
        XCTAssertEqual(reloaded.dataExtensions,[updated]);XCTAssertTrue(reloaded.enabledDataExtensions.isEmpty)
        try s.setDataExtensionEnabled(package.id,true)
        try s.applyDefinedAnimation(package.animations[0],packageID:package.id,values:["amplitude":0.1,"cycles":1],clipID:c.id)
        let applied=s.project;XCTAssertEqual(applied.clips[0].animation?.tracks.first{$0.property == .x},x)
        XCTAssertEqual(applied.clips[0].customAnimation?.values["amplitude"],0.1)
        s.undo();XCTAssertEqual(s.project,before);s.redo();XCTAssertEqual(s.project,applied)
        try s.removeDataExtension(package.id);XCTAssertEqual(s.project,applied);XCTAssertTrue(s.dataExtensions.isEmpty)
        let restored=try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(applied)).validated();XCTAssertEqual(restored,applied)
        let saved=try XCTUnwrap(restored.clips[0].customAnimation)
        try s.applyDefinedAnimation(saved.definition,packageID:saved.packageID,values:saved.values,clipID:c.id)
        XCTAssertEqual(s.project.clips[0].animation?.tracks.first{$0.property == .y}?.keys.map(\.value),applied.clips[0].animation?.tracks.first{$0.property == .y}?.keys.map(\.value))
        let valid=s.project
        XCTAssertThrowsError(try s.applyDefinedAnimation(saved.definition,packageID:"bad/id",values:[:],clipID:c.id));XCTAssertEqual(s.project,valid)
        s.project.tracks[0].locked=true;let locked=s.project
        XCTAssertThrowsError(try s.applyDefinedAnimation(saved.definition,packageID:saved.packageID,values:[:],clipID:c.id));XCTAssertEqual(s.project,locked)
        let legacy=try JSONDecoder().decode(Clip.self,from:JSONEncoder().encode(c));XCTAssertNil(legacy.customAnimation)
        let legacySettings=try JSONDecoder().decode(UserSettings.self,from:JSONEncoder().encode(UserSettings()));XCTAssertNil(legacySettings.disabledExtensions)
        var setting=UserSettings();setting.disabledExtensions=["../bad"];XCTAssertThrowsError(try setting.validated())
    }
    @MainActor func testPersistenceFailureLeavesCatalogueUnchanged()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-extension-failure-\(UUID())")
        let s=EditorStore(preferencesDirectory:root);defer{try? FileManager.default.removeItem(at:s.directory);try? FileManager.default.removeItem(at:root)}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:root.appendingPathComponent("extensions.json"),withIntermediateDirectories:true)
        XCTAssertThrowsError(try s.installDataExtension(.sample));XCTAssertTrue(s.dataExtensions.isEmpty)
    }
    @MainActor func testExtensionAPIRequiresValidEnabledDefinitionsAndExplicitUpdate()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-extension-api-\(UUID())"),s=EditorStore(preferencesDirectory:root)
        s.autoSpeech=false;s.settings.autosaveSeconds=0
        defer{try? FileManager.default.removeItem(at:s.directory);try? FileManager.default.removeItem(at:root)}
        let c=Clip(kind:.shape,name:"api",track:0,start:0,duration:1);s.project.clips=[c]
        let api=EditorCommands();api.store=s
        func send(_ command:String,_ payload:[String:Any]=[:])throws->ControlResult {
            var request=payload;request["command"]=command
            return api.execute(body:try JSONSerialization.data(withJSONObject:request))
        }
        let p=DataExtensionPackage.sample,raw=try JSONSerialization.jsonObject(with:JSONEncoder().encode(p))
        XCTAssertEqual(try send("extension.install",["package":raw]).status,200)
        XCTAssertEqual(try send("extension.install",["package":raw]).status,400)
        XCTAssertEqual(try send("extension.install",["package":raw,"replace":true]).status,200)
        let payload:[String:Any]=["clipID":c.id.uuidString,"packageID":p.id,"definitionID":"wave","values":["amplitude":0.1,"cycles":1]]
        XCTAssertEqual(try send("animation.applyDefinition",payload).status,200)
        let applied=s.project
        XCTAssertEqual(try send("extension.enable",["packageID":p.id,"enabled":false]).status,200)
        XCTAssertEqual(try send("animation.applyDefinition",payload).status,400);XCTAssertEqual(s.project,applied)
        XCTAssertEqual(api.read("extensions").status,200)
        XCTAssertEqual(try send("extension.enable",["packageID":p.id,"enabled":true]).status,200)
        XCTAssertEqual(try send("extension.applyPreset",["clipID":c.id.uuidString,"packageID":p.id,"name":p.presets[0].name]).status,200)
        XCTAssertNil(s.project.clips[0].customAnimation)
        XCTAssertEqual(try send("extension.remove",["packageID":p.id]).status,200)
    }
    func testJSONAnimationPreviewMatchesActualMP4()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-json-export-\(UUID())");try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        var p=Project();p.width=320;p.height=180;p.fps=30;p.background="000000"
        var c=Clip(kind:.shape,name:"orbit",track:0,start:0,duration:1);c.color="FF0000";c.scale=0.05
        let package=DataExtensionPackage.sample,definition=package.animations[1],values=["amplitude":0.2,"cycles":1.0]
        c.animation=ClipAnimation(tracks:try definition.bake(clip:c,fps:p.fps,values:values))
        c.customAnimation=CustomAnimationInstance(packageID:package.id,definition:definition,values:values);p.clips=[c];_=try p.validated()
        let output=root.appendingPathComponent("json-motion.mp4");try await MovieExporter.export(project:p,directory:root,destination:output){_ in}
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
