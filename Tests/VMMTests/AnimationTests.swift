import XCTest
import AppKit
import AVFoundation
@testable import VMM

final class AnimationTests: XCTestCase {
    func scene() -> Project {
        var p = Project(); p.width = 320; p.height = 180; p.background = "000000"
        var a = Clip(kind: .shape, name: "赤い場面", track: 1, start: 0, duration: 1)
        a.color = "FF0000"; a.scale = 4
        var b = Clip(kind: .shape, name: "青い場面", track: 1, start: 1, duration: 2)
        b.color = "0000FF"; b.scale = 4
        var t = Clip(kind: .transition, name: "切り替え", track: 0, start: 1, duration: 1)
        t.sceneTransition = SceneTransition(kind: .dissolve, easing: .linear)
        p.clips = [a,b,t]; return p
    }
    func render(_ p: Project, _ time: Double) throws -> CGContext {
        let c = try XCTUnwrap(CGContext(data: nil, width: p.width, height: p.height, bitsPerComponent: 8, bytesPerRow: p.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        FrameRenderer().draw(project: p, directory: FileManager.default.temporaryDirectory, time: time, context: c, size: CGSize(width: p.width, height: p.height))
        return c
    }
    func pixel(_ c: CGContext, x: Int = 160, y: Int = 90) throws -> [Int] {
        let d = try XCTUnwrap(c.data).assumingMemoryBound(to: UInt8.self); let i = (y*c.width+x)*4
        return (0..<4).map { Int(d[i+$0]) }
    }
    func testSceneTransitionsCompositeActualScenes() throws {
        var p = scene()
        XCTAssertEqual(try pixel(render(p,1)), [255,0,0,255])
        let mid = try pixel(render(p,1.5)); XCTAssertEqual(mid[0],128,accuracy:2); XCTAssertEqual(mid[2],128,accuracy:2)
        XCTAssertEqual(try pixel(render(p,2)),[0,0,255,255])
        p.clips[2].sceneTransition?.kind = .wipeLeft
        let wipe = try render(p,1.5)
        XCTAssertEqual(try pixel(wipe,x:40),[0,0,255,255]); XCTAssertEqual(try pixel(wipe,x:280),[255,0,0,255])
        for kind in SceneTransitionKind.allCases {
            p.clips[2].sceneTransition?.kind = kind
            XCTAssertEqual(try pixel(render(p,1)),[255,0,0,255],kind.rawValue)
            let image = try render(p,1.5)
            XCTAssertEqual(try pixel(image)[3],255,kind.rawValue)
        }
    }
    func scopedScene() -> Project {
        var p=scene()
        p.clips[0].scale=0.35;p.clips[0].x=0.2
        p.clips[1].scale=0.35;p.clips[1].x=0.2
        var overlay=Clip(kind:.shape,name:"上側の緑",track:0,start:1,duration:2)
        overlay.color="00FF00";overlay.scale=0.35;overlay.x=0.8;overlay.y=0.15
        p.clips.append(overlay)
        return p
    }
    func testTransitionOnlyAffectsLowerRows() throws {
        var p=scopedScene()
        for kind in SceneTransitionKind.allCases {
            p.clips[2].sceneTransition?.kind=kind
            XCTAssertEqual(try pixel(render(p,1),x:256,y:27),[0,255,0,255],"Upper row must not be delayed: \(kind)")
            XCTAssertEqual(try pixel(render(p,1.5),x:256,y:27),[0,255,0,255],"Upper row must stay unchanged: \(kind)")
        }
        p.clips[2].sceneTransition?.kind = .dissolve
        let mixed=try pixel(render(p,1.5),x:64)
        XCTAssertEqual(mixed[0],128,accuracy:2);XCTAssertEqual(mixed[2],128,accuracy:2)
        p.clips[2].track=2
        XCTAssertEqual(try pixel(render(p,1),x:64),[0,0,255,255],"An empty lower range must not affect upper rows")
    }
    func testTransitionPreservesTransparencyAboveUnchangedLayers() throws {
        var p=scene();p.clips=[p.clips[0],p.clips[2]]
        p.clips[0].scale=0.35
        var background=Clip(kind:.shape,name:"上側の背景",track:0,start:0,duration:3)
        background.color="00FF00";background.scale=4;p.clips.append(background)
        XCTAssertEqual(try pixel(render(p,1),x:160),[255,0,0,255])
        let middle=try pixel(render(p,1.5),x:160)
        XCTAssertEqual(middle[0],128,accuracy:2);XCTAssertEqual(middle[1],128,accuracy:2)
        XCTAssertEqual(try pixel(render(p,1.5),x:10),[0,255,0,255])
        XCTAssertEqual(try pixel(render(p,2),x:160),[0,255,0,255])
    }
    func testTransitionScopeInActualMP4() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-transition-scope-\(UUID())")
        try FileManager.default.createDirectory(at:root.appendingPathComponent("Media"),withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let project=scopedScene(),output=root.appendingPathComponent("scoped.mp4")
        try await MovieExporter.export(project:project,directory:root,destination:output){_ in}
        let generator=AVAssetImageGenerator(asset:AVURLAsset(url:output));generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
        let image=try generator.copyCGImage(at:CMTime(seconds:1.5,preferredTimescale:600),actualTime:nil)
        let ctx=try XCTUnwrap(CGContext(data:nil,width:320,height:180,bitsPerComponent:8,bytesPerRow:1280,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image,in:CGRect(x:0,y:0,width:320,height:180))
        let unchanged=try pixel(ctx,x:256,y:27),mixed=try pixel(ctx,x:64)
        XCTAssertEqual(unchanged[1],255,accuracy:12);XCTAssertEqual(unchanged[0],0,accuracy:12)
        XCTAssertEqual(mixed[0],128,accuracy:14);XCTAssertEqual(mixed[2],128,accuracy:14)
    }
    func testEffectsOrderDisableAndChromaTransparency() throws {
        var p = scene(); p.clips = [p.clips[0]]
        var gray = VisualEffect(kind:.saturation); gray.amount = 0
        p.clips[0].effects = [gray]
        let mono = try pixel(render(p,0.5)); XCTAssertEqual(mono[0],mono[1],accuracy:2); XCTAssertEqual(mono[1],mono[2],accuracy:2)
        p.clips[0].effects?[0].enabled = false
        XCTAssertEqual(try pixel(render(p,0.5)),[255,0,0,255])
        var key = VisualEffect(kind:.chromaKey); key.color = "FF0000"
        p.clips[0].effects = [key]
        XCTAssertEqual(try pixel(render(p,0.5)),[0,0,0,255])
        var bright = VisualEffect(kind:.brightness); bright.amount = 0.25
        let invert = VisualEffect(kind:.invert)
        p.clips[0].effects = [bright,invert]; let first = try pixel(render(p,0.5))
        p.clips[0].effects = [invert,bright]; XCTAssertNotEqual(try pixel(render(p,0.5)),first)
        for kind in EffectKind.allCases {
            p.clips[0].effects = [VisualEffect(kind:kind)]
            XCTAssertNotNil(try render(p,0.5).makeImage(),kind.rawValue)
        }
    }
    func testAnimatedMovementAndEffectStrengthPixels() throws {
        var p = scene(); var c = p.clips[0]; c.scale = 0.3; c.x = 0.2; c.duration = 2
        c.animation = ClipAnimation(tracks:[AnimationTrack(property:.x,keys:[AnimationKeyframe(time:0,value:0.2,easing:.linear),AnimationKeyframe(time:2,value:0.8)])])
        p.clips = [c]
        XCTAssertGreaterThan(try pixel(render(p,0),x:64)[0],240)
        XCTAssertEqual(try pixel(render(p,1),x:64)[0],0)
        XCTAssertGreaterThan(try pixel(render(p,1),x:160)[0],240)
        var gray = VisualEffect(kind:.saturation); gray.keys = [AnimationKeyframe(time:0,value:1,easing:.linear),AnimationKeyframe(time:2,value:0)]
        p.clips[0].effects = [gray]
        let mid = try pixel(render(p,1)); XCTAssertGreaterThan(mid[0],mid[1]); XCTAssertGreaterThan(mid[1],20)
    }
    @MainActor func testSplitAndTrimKeepOriginalAnimationTimeAndUndo() throws {
        let s = EditorStore(); defer { try? FileManager.default.removeItem(at:s.directory) }
        var c = Clip(kind:.shape,name:"動く図形",track:0,start:2,duration:4)
        c.animation = ClipAnimation(exit:Entrance(kind:.fade,duration:1,easing:.linear),tracks:[AnimationTrack(property:.x,keys:[AnimationKeyframe(time:0,value:0.1,easing:.linear),AnimationKeyframe(time:4,value:0.9)])])
        s.project.clips = [c]; s.selectedID = c.id; s.playhead = 4; s.snapping = false
        s.splitSelected()
        XCTAssertEqual(s.project.clips[1].animated(at:4.5).x,c.animated(at:4.5).x,accuracy:0.0001)
        XCTAssertEqual(s.project.clips[0].animated(at:3.9).opacity,1)
        s.undo(); XCTAssertEqual(s.project.clips,[c])
        let trimmed = s.timelineChange(c,delta:1,track:0,edge:-1)
        XCTAssertEqual(trimmed.animation?.span,4)
        XCTAssertEqual(trimmed.animated(at:5.5).opacity,c.animated(at:5.5).opacity,accuracy:0.0001)
        XCTAssertEqual(trimmed.animated(at:4.5).x,c.animated(at:4.5).x,accuracy:0.0001)
        s.playhead = 100; s.addKeyframe(.opacity,clipID:c.id)
        XCTAssertEqual(s.project.clips[0].animation?.tracks.last?.keys.first?.time,4)
    }
    func testPresetRoundTripAndValidation() throws {
        for preset in EffectPreset.builtins {
            let decoded = try JSONDecoder().decode(EffectPreset.self,from:JSONEncoder().encode(preset)).validated()
            XCTAssertEqual(decoded,preset)
        }
        var c = scene().clips[0]; c.effects = [VisualEffect(kind:.blur)]; c.effects?[0].amount = .nan
        XCTAssertThrowsError(try c.validateAnimation())
        c.effects = nil; c.animation = ClipAnimation(tracks:[AnimationTrack(property:.x,keys:[AnimationKeyframe(time:0,value:0),AnimationKeyframe(time:0,value:1)])])
        XCTAssertThrowsError(try c.validateAnimation())
        for easing in Easing.allCases { XCTAssertEqual(easing.value(0),0,accuracy:0.000001); XCTAssertEqual(easing.value(1),1,accuracy:0.000001) }
    }
    func testTransitionsAndEffectsInActualMP4() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vmm-animation-\(UUID())")
        try FileManager.default.createDirectory(at:directory.appendingPathComponent("Media"),withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        var p = scene(); var invert = VisualEffect(kind:.invert); invert.amount = 1
        p.clips[1].effects = [invert] // Blue becomes yellow in both preview and export.
        let output = directory.appendingPathComponent("effects.mp4")
        try await MovieExporter.export(project:p,directory:directory,destination:output) { _ in }
        let generator = AVAssetImageGenerator(asset:AVURLAsset(url:output)); generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        for (time,expected) in [(0.5,[255,0,0]),(1.5,[255,128,0]),(2.5,[255,255,0])] {
            let image = try generator.copyCGImage(at:CMTime(seconds:time,preferredTimescale:600),actualTime:nil)
            let ctx = try XCTUnwrap(CGContext(data:nil,width:320,height:180,bitsPerComponent:8,bytesPerRow:1280,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.draw(image,in:CGRect(x:0,y:0,width:320,height:180)); let actual = try pixel(ctx)
            for i in 0..<3 { XCTAssertEqual(actual[i],expected[i],accuracy:12) }
        }
        if let path = testArtifactDirectory() {
            let root = URL(fileURLWithPath:path); try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            try FileManager.default.copyItem(at:output,to:root.appendingPathComponent("effects-transitions.mp4"))
            let package = root.appendingPathComponent("Effects-Demo.vmm"); try FileManager.default.createDirectory(at:package.appendingPathComponent("Media"),withIntermediateDirectories:true)
            try JSONEncoder().encode(p).write(to:package.appendingPathComponent("project.json"))
        }
    }
}
