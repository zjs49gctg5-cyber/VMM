import XCTest
import AVFoundation
@testable import VMM

final class EasingCurveTests:XCTestCase {
    func testBezierSolvesTimeAndHandlesDegenerateTangents()throws {
        let linear=EasingCurve(x1:0,y1:0,x2:1,y2:1)
        for i in 0...100 {let t=Double(i)/100;XCTAssertEqual(linear.value(t),t,accuracy:0.000000001)}
        let flat=EasingCurve(x1:0,y1:0,x2:0,y2:1)
        // X(s)=s³, so at time 1/8, s=1/2 and Y(s)=1/2.
        XCTAssertEqual(flat.value(0.125),0.5,accuracy:0.000000001)
        let ease=EasingCurve();XCTAssertLessThan(ease.value(0.25),0.25);XCTAssertEqual(ease.value(0.5),0.5,accuracy:0.000000001);XCTAssertGreaterThan(ease.value(0.75),0.75)
        let crossed=EasingCurve(x1:1,y1:0,x2:0,y2:1)
        XCTAssertEqual(crossed.value(0.5),0.5,accuracy:0.00001)
        XCTAssertEqual(ease.value(-1),0);XCTAssertEqual(ease.value(2),1)
        let old=AnimationKeyframe(time:0,value:0,easing:.linear)
        var custom=old;custom.customCurve=flat
        let keys=[custom,AnimationKeyframe(time:1,value:1)]
        XCTAssertEqual(interpolate(keys,at:0.125,fallback:0),0.5,accuracy:0.000000001)
        let restored=try JSONDecoder().decode([AnimationKeyframe].self,from:JSONEncoder().encode(keys));XCTAssertEqual(restored,keys)
        let legacy=try JSONDecoder().decode(AnimationKeyframe.self,from:JSONEncoder().encode(old));XCTAssertNil(legacy.customCurve)
        var c=Clip(kind:.shape,name:"curve",track:0,start:0,duration:1);c.animation=ClipAnimation(tracks:[AnimationTrack(property:.x,keys:keys)])
        try c.validateAnimation();c.animation?.tracks[0].keys[0].customCurve?.segments[0].x1 = .nan;XCTAssertThrowsError(try c.validateAnimation())
        c.animation?.tracks[0].keys[0].customCurve=EasingCurve(x1:-0.1);XCTAssertThrowsError(try c.validateAnimation())
    }
    func testAdditionalPointsPreserveShapeAndCanBounceOrOscillate()throws {
        let original=EasingCurve(x1:0.2,y1:-0.3,x2:0.75,y2:1.8)
        var curve=original
        for i in [0,1,0] {XCTAssertTrue(curve.insertPoint(in:i));XCTAssertTrue(curve.isValid)}
        XCTAssertEqual(curve.parts.count,4)
        for i in 0...200 {let t=Double(i)/200;XCTAssertEqual(curve.value(t),original.value(t),accuracy:0.00000001)}
        curve.update(1){$0.endY = -0.5;$0.endX=0.9};XCTAssertTrue(curve.isValid)
        XCTAssertTrue(curve.removePoint(after:1));XCTAssertTrue(curve.isValid)
        XCTAssertFalse(curve.removePoint(after:curve.parts.count-1))
        let roundTrip=try JSONDecoder().decode(EasingCurve.self,from:JSONEncoder().encode(curve));XCTAssertEqual(roundTrip,curve)
        let singleSegment=EasingCurve()
        let encoded=try JSONEncoder().encode(singleSegment)
        XCTAssertEqual(try JSONDecoder().decode(EasingCurve.self,from:encoded),singleSegment)
        let json=try XCTUnwrap(JSONSerialization.jsonObject(with:encoded) as? [String:Any])
        XCTAssertNotNil(json["segments"]);XCTAssertNil(json["x1"])
        XCTAssertThrowsError(try JSONDecoder().decode(EasingCurve.self,from:Data("{\"x1\":0.42,\"y1\":0,\"x2\":0.58,\"y2\":1}".utf8)))
        let bounce=try XCTUnwrap(EasingCurve.presets.first{$0.0=="バウンド"}?.1)
        XCTAssertTrue(bounce.isValid);XCTAssertEqual(bounce.value(0.36),1,accuracy:0.000001);XCTAssertLessThan(bounce.value(0.54),0.8);XCTAssertGreaterThan(bounce.value(0.72),0.99)
        let vibration=try XCTUnwrap(EasingCurve.presets.first{$0.0=="振動"}?.1)
        XCTAssertTrue(vibration.isValid);XCTAssertGreaterThan(vibration.value(0.18),1.4);XCTAssertLessThan(vibration.value(0.32),0.7);XCTAssertGreaterThan(vibration.value(0.46),1.2)
        XCTAssertEqual(vibration.value(0),0);XCTAssertEqual(vibration.value(1),1)
        var invalid=curve;invalid.segments[0].endX=0;XCTAssertFalse(invalid.isValid)
        invalid=curve;invalid.segments[0].x1=1;XCTAssertFalse(invalid.isValid)
        invalid=curve;invalid.segments[0].y1 = .infinity;XCTAssertFalse(invalid.isValid)
        var bounded=EasingCurve();while bounded.parts.count<32 {XCTAssertTrue(bounded.insertPoint(in:bounded.parts.enumerated().max{a,b in let pa=a.offset==0 ? 0:bounded.parts[a.offset-1].endX,pb=b.offset==0 ? 0:bounded.parts[b.offset-1].endX;return a.element.endX-pa<b.element.endX-pb}!.offset))}
        XCTAssertFalse(bounded.insertPoint(in:0));XCTAssertTrue(bounded.isValid)
    }
    @MainActor func testApplyUndoDuplicatePresetAndRestoreStandard()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-curve-\(UUID())")
        let s=EditorStore(preferencesDirectory:root);s.autoSpeech=false;s.settings.autosaveSeconds=0
        defer{try? FileManager.default.removeItem(at:s.directory);try? FileManager.default.removeItem(at:root)}
        var c=Clip(kind:.shape,name:"curve",track:0,start:0,duration:4);c.animation=ClipAnimation(tracks:[AnimationTrack(property:.x,keys:[AnimationKeyframe(time:0,value:0.1),AnimationKeyframe(time:2,value:0.5),AnimationKeyframe(time:4,value:0.9)])]);s.project.clips=[c];let before=s.project
        let curve=EasingCurve(x1:0.2,y1:0.1,x2:0.8,y2:0.9)
        try s.setMotionCurve(c.id,property:.x,time:2,end:4,curve:curve)
        XCTAssertEqual(s.project.clips[0].animation?.tracks[0].keys[1].customCurve,curve)
        s.undo();XCTAssertEqual(s.project,before);s.redo()
        let t=try s.duplicateMotionPoint(c.id,at:2,property:.x)
        XCTAssertEqual(s.project.clips[0].animation?.tracks[0].keys.first{$0.time==t}?.customCurve,curve)
        let preset=try EffectPreset(name:"curve",animation:s.project.clips[0].animation).validated()
        XCTAssertEqual(try JSONDecoder().decode(EffectPreset.self,from:JSONEncoder().encode(preset)),preset)
        try s.setMotionValue(c.id,property:.x,time:2,value:0.5,easing:.linear);XCTAssertNil(s.project.clips[0].animation?.tracks[0].keys[1].customCurve)
        let valid=s.project;XCTAssertThrowsError(try s.setMotionCurve(c.id,property:.x,time:2,curve:EasingCurve(y1:5)));XCTAssertEqual(s.project,valid)
        s.project.tracks[0].locked=true;XCTAssertThrowsError(try s.setMotionCurve(c.id,property:.x,time:2,curve:curve))
    }
    func testCustomCurvePreviewAndActualMP4()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-curve-export-\(UUID())");try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        var p=Project();p.width=320;p.height=180;p.fps=30;p.background="000000"
        var c=Clip(kind:.shape,name:"curve",track:0,start:0,duration:1);c.color="FF0000";c.scale=0.1
        c.animation=ClipAnimation(tracks:[AnimationTrack(property:.x,keys:[AnimationKeyframe(time:0,value:0.1,easing:.linear,customCurve:EasingCurve(x1:0,y1:0,x2:0,y2:1)),AnimationKeyframe(time:1,value:0.9)])]);p.clips=[c]
        let output=root.appendingPathComponent("curve.mp4");try await MovieExporter.export(project:p,directory:root,destination:output){_ in}
        let gen=AVAssetImageGenerator(asset:AVURLAsset(url:output));gen.requestedTimeToleranceBefore = .zero;gen.requestedTimeToleranceAfter = .zero
        for time in [0.2,0.5,0.8] {
            let ctx=try XCTUnwrap(RasterTools.bitmap(CGSize(width:320,height:180)));FrameRenderer().draw(project:p,directory:root,time:time,context:ctx,size:CGSize(width:320,height:180))
            let preview=NSBitmapImageRep(cgImage:try XCTUnwrap(ctx.makeImage())),frame=NSBitmapImageRep(cgImage:try gen.copyCGImage(at:CMTime(seconds:time,preferredTimescale:600),actualTime:nil))
            let x=Int(c.animated(at:time).x*320),y=Int(c.y*180)
            XCTAssertGreaterThan(try XCTUnwrap(preview.colorAt(x:x,y:y)?.usingColorSpace(.sRGB)).redComponent,0.8)
            XCTAssertGreaterThan(try XCTUnwrap(frame.colorAt(x:x,y:y)?.usingColorSpace(.sRGB)).redComponent,0.7)
            let linearX=Int((0.1+0.8*time)*320);XCTAssertLessThan(try XCTUnwrap(frame.colorAt(x:linearX,y:y)?.usingColorSpace(.sRGB)).redComponent,0.2)
        }
    }
    func testBounceAndVibrationPreviewAndActualMP4()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-oscillation-\(UUID())");try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        for name in ["バウンド","振動"] {
            var p=Project();p.width=320;p.height=180;p.fps=30;p.background="000000"
            let curve=try XCTUnwrap(EasingCurve.presets.first{$0.0==name}?.1)
            var c=Clip(kind:.shape,name:name,track:0,start:0,duration:1);c.color="FF0000";c.scale=0.08
            c.animation=ClipAnimation(tracks:[AnimationTrack(property:.x,keys:[AnimationKeyframe(time:0,value:0.15,easing:.linear,customCurve:curve),AnimationKeyframe(time:1,value:0.6)])]);p.clips=[c];_=try p.validated()
            let restored=try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(p));XCTAssertEqual(restored,p)
            let output=root.appendingPathComponent("\(name).mp4");try await MovieExporter.export(project:p,directory:root,destination:output){_ in}
            let gen=AVAssetImageGenerator(asset:AVURLAsset(url:output));gen.requestedTimeToleranceBefore = .zero;gen.requestedTimeToleranceAfter = .zero
            for time in [0.2,0.4,0.6,0.8] {
                let ctx=try XCTUnwrap(RasterTools.bitmap(CGSize(width:320,height:180)));FrameRenderer().draw(project:p,directory:root,time:time,context:ctx,size:CGSize(width:320,height:180))
                let preview=NSBitmapImageRep(cgImage:try XCTUnwrap(ctx.makeImage())),frame=NSBitmapImageRep(cgImage:try gen.copyCGImage(at:CMTime(seconds:time,preferredTimescale:600),actualTime:nil))
                let x=Int(c.animated(at:time).x*320),y=Int(c.y*180)
                XCTAssertGreaterThan(try XCTUnwrap(preview.colorAt(x:x,y:y)?.usingColorSpace(.sRGB)).redComponent,0.8)
                XCTAssertGreaterThan(try XCTUnwrap(frame.colorAt(x:x,y:y)?.usingColorSpace(.sRGB)).redComponent,0.7)
            }
        }
    }

}
