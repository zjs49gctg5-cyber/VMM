import XCTest
@testable import VMM
final class ExportPreflightTests:XCTestCase {
    func testCPUWarningOnlyWhenGlitchIsVisibleAndUsedWithinExportRange()throws {
        var p=Project();var clip=Clip(kind:.shape,name:"shape",track:0,start:0,duration:2)
        clip.effects=[VisualEffect(kind:.filmGrain)];p.clips=[clip]
        var options=UserSettings();options.rangeEnd=1
        func cpuWarning(_ project:Project,_ available:Bool)->Bool {
            ExportPreflight.inspect(project:project,directory:FileManager.default.temporaryDirectory,options:options,metalKernelsAvailable:available).issues.contains{$0.id=="glitch-cpu"}
        }
        XCTAssertTrue(cpuWarning(p,false));XCTAssertFalse(cpuWarning(p,true))
        p.tracks[0].visible=false;XCTAssertFalse(cpuWarning(p,false));p.tracks[0].visible=true
        p.clips[0].effects?[0].enabled=false;XCTAssertFalse(cpuWarning(p,false))
        p.clips[0].effects?[0].enabled=true;p.clips[0].effects?[0].amount=0;XCTAssertFalse(cpuWarning(p,false))
        p.clips[0].effects?[0].keys=[AnimationKeyframe(time:1.5,value:0),AnimationKeyframe(time:2,value:0.8)]
        XCTAssertFalse(cpuWarning(p,false));options.rangeStart=1.5;options.rangeEnd=2;XCTAssertTrue(cpuWarning(p,false))
        p.clips[0].effects=nil;p.tracks[0].effects=[VisualEffect(kind:.glitch)];XCTAssertTrue(cpuWarning(p,false))
        p.clips[0].start=0;p.clips[0].duration=1;p.clips.append(Clip(kind:.shape,name:"later",track:1,start:1,duration:1));options.rangeStart=1;options.rangeEnd=2;XCTAssertFalse(cpuWarning(p,false))
    }
    func testCPUWarningIncludesVisiblePrecompositionEffects()throws {
        var p=Project();var child=Clip(kind:.shape,name:"inner",track:0,start:0,duration:1);child.effects=[VisualEffect(kind:.glitch)]
        let composition=Precomposition(name:"scene",width:p.width,height:p.height,fps:p.fps,duration:1,tracks:[Track(name:"inside")],clips:[child])
        var instance=Clip(kind:.group,name:"scene",track:0,start:0,duration:1);instance.precompositionID=composition.id
        p.precompositions=[composition];p.clips=[instance]
        let report=ExportPreflight.inspect(project:p,directory:FileManager.default.temporaryDirectory,options:UserSettings(),metalKernelsAvailable:false)
        XCTAssertTrue(report.issues.contains{$0.id=="glitch-cpu"});XCTAssertTrue(report.canExport)
    }
    func testCPUWarningIncludesKeyframedOutgoingTransitionFrame()throws {
        var p=Project()
        var lower=Clip(kind:.shape,name:"lower",track:1,start:0,duration:2)
        var effect=VisualEffect(kind:.glitch)
        effect.keys=[AnimationKeyframe(time:0,value:1),AnimationKeyframe(time:1,value:0)]
        lower.effects=[effect]
        p.clips=[Clip(kind:.transition,name:"transition",track:0,start:1,duration:1),lower]
        var options=UserSettings();options.rangeStart=1;options.rangeEnd=2
        func warns(_ available:Bool)->Bool {
            ExportPreflight.inspect(project:p,directory:FileManager.default.temporaryDirectory,options:options,metalKernelsAvailable:available).issues.contains{$0.id=="glitch-cpu"}
        }
        XCTAssertTrue(warns(false));XCTAssertFalse(warns(true))
        p.clips[1].effects=nil;p.tracks[1].effects=[effect]
        XCTAssertTrue(warns(false));XCTAssertFalse(warns(true))
        p.tracks[1].visible=false;XCTAssertFalse(warns(false))
    }
    func testAggregatesMissingMediaSpeechFontAndRange()throws {
        var p=Project();let asset=MediaAsset(name:"missing",file:"missing.png",kind:.image,duration:1);p.assets=[asset]
        var image=Clip(kind:.image,name:"image",track:0,start:0,duration:1);image.assetID=asset.id
        var speech=Clip(kind:.speech,name:"dialogue",track:1,start:0,duration:1);speech.speechDirty=true;speech.textStyle=TextStyle();speech.textStyle?.fontName="VMM-Not-A-Font-\(UUID())"
        p.clips=[image,speech];var settings=UserSettings();settings.rangeStart=2
        let report=ExportPreflight.inspect(project:p,directory:FileManager.default.temporaryDirectory,options:settings)
        XCTAssertFalse(report.canExport);XCTAssertEqual(report.issues.filter{$0.severity == .error}.count,3);XCTAssertEqual(report.issues.filter{$0.severity == .warning}.count,1)
    }
    func testReadyAndInvalidDestination() {
        var p=Project();p.clips=[Clip(kind:.shape,name:"shape",track:0,start:0,duration:1)]
        let report=ExportPreflight.inspect(project:p,directory:FileManager.default.temporaryDirectory,options:UserSettings())
        XCTAssertTrue(report.canExport);XCTAssertGreaterThan(report.estimatedBytes,1_048_576)
        let invalid=ExportPreflight.inspect(project:p,directory:FileManager.default.temporaryDirectory,options:UserSettings(),destination:URL(fileURLWithPath:"/not-there-\(UUID())/movie.mp4"))
        XCTAssertFalse(invalid.canExport)
    }
}
