import XCTest
import AppKit
import Combine
@testable import VMM

final class AdaptivePreviewTests:XCTestCase {
    func testLoadReductionRecoveryAndFullQualityWhenPaused() {
        var load=PreviewLoadController()
        for _ in 0..<60 {load.record(milliseconds:100,fps:30)}
        XCTAssertEqual(load.quality.level,PreviewQuality.maximumLevel);XCTAssertEqual(load.quality.particles,0.25)
        for _ in 0..<10 {load.record(milliseconds:1,fps:30)}
        XCTAssertEqual(load.quality.level,PreviewQuality.maximumLevel) // Hysteresis prevents rapid quality oscillation.
        for _ in 0..<200 {load.record(milliseconds:1,fps:30)}
        XCTAssertEqual(load.quality.level,0)
        let before=load
        load.record(milliseconds:.nan,fps:30);XCTAssertEqual(load.quality,before.quality)
        var project=Project();project.width=3840;project.height=2160
        let display=CGSize(width:3840,height:2160)
        XCTAssertEqual(PreviewQuality(level:6).rasterSize(display:display,project:project,playing:true,adaptive:true),CGSize(width:1152,height:648))
        XCTAssertEqual(PreviewQuality(level:6).rasterSize(display:display,project:project,playing:false,adaptive:true),display)
        XCTAssertEqual(PreviewQuality(level:6).rasterSize(display:display,project:project,playing:true,adaptive:false),display)
        load.reset();XCTAssertEqual(load.quality.level,0)
    }
    func testStableFPSColdSpikeAndReadableResolutionFloor()throws {
        var load=PreviewLoadController()
        load.record(milliseconds:1000,fps:30)
        for _ in 0..<30 {load.record(milliseconds:20,fps:30,observedFPS:30)}
        XCTAssertEqual(load.quality.level,0) // A cold-start spike must not leave a blurry preview.
        for _ in 0..<100 {load.record(milliseconds:24,fps:30,observedFPS:30)}
        XCTAssertEqual(load.quality.level,0)
        var project=Project();project.width=1920;project.height=1080
        let display=CGSize(width:844,height:475),lowest=PreviewQuality(level:6)
        XCTAssertEqual(lowest.rasterSize(display:display,project:project,playing:true,adaptive:true).width,720)
        XCTAssertEqual(lowest.rasterSize(display:display,project:project,playing:true,adaptive:true,minimumLongEdge:1080),display)
        XCTAssertEqual(lowest.targetFPS(30),15);XCTAssertEqual(lowest.targetFPS(60),30);XCTAssertEqual(lowest.targetFPS(10),10)
        var settings=UserSettings();XCTAssertNil(settings.previewMinimumLongEdge)
        settings.previewMinimumLongEdge=1080;_ = try settings.validated()
        XCTAssertEqual(try JSONDecoder().decode(UserSettings.self,from:JSONEncoder().encode(settings)).previewMinimumLongEdge,1080)
        for value in [Double.nan,320,1921] {settings.previewMinimumLongEdge=value;XCTAssertThrowsError(try settings.validated())}
    }
    @MainActor func testPlaybackCadenceDoesNotQueueOldFramesAndPauseRestoresQuality()async throws {
        var project=Project();project.width=800;project.height=450
        var shape=Clip(kind:.shape,name:"Shape",track:0,start:0,duration:10);shape.color="66CCFF";project.clips=[shape]
        let view=PreviewNSView(frame:NSRect(x:0,y:0,width:800,height:450))
        view.update(project:project,directory:FileManager.default.temporaryDirectory,time:0,playing:true,adaptive:true)
        let limit=ProcessInfo.processInfo.systemUptime+5
        while view.displayedTime != 0 && ProcessInfo.processInfo.systemUptime<limit {try await Task.sleep(nanoseconds:10_000_000)}
        for i in 1..<100 {view.update(project:project,directory:FileManager.default.temporaryDirectory,time:Double(i)/30,playing:true,adaptive:true)}
        view.update(project:project,directory:FileManager.default.temporaryDirectory,time:2,playing:false,adaptive:true)
        while (view.displayedTime != 2 || view.rendering) && ProcessInfo.processInfo.systemUptime<limit {try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertEqual(view.displayedTime,2);XCTAssertEqual(view.renderedImage?.width,800)
        XCTAssertLessThanOrEqual(view.presentedFrames,3)
    }
    @MainActor func testViewUpdateDoesNotPublishDuringLayout()throws {
        let prefs=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-preview-layout-\(UUID())")
        let store=EditorStore(preferencesDirectory:prefs)
        defer{try? FileManager.default.removeItem(at:store.directory);try? FileManager.default.removeItem(at:prefs)}
        var publications=0
        let observation=store.objectWillChange.sink{publications+=1}
        let view=PreviewNSView(frame:NSRect(x:0,y:0,width:400,height:300))
        view.update(store:store);view.update(store:store)
        XCTAssertEqual(publications,0)
        withExtendedLifetime(observation){}
    }
    @MainActor func testBackgroundRequestsCoalesceAndStaleFramesAreRejected()async throws {
        var project=Project();project.width=400;project.height=300;project.background="000000"
        var shape=Clip(kind:.shape,name:"Shape",track:0,start:0,duration:10);shape.color="FF0000";project.clips=[shape]
        let view=PreviewNSView(frame:NSRect(x:0,y:0,width:400,height:300))
        for i in 0..<100 {view.update(project:project,directory:FileManager.default.temporaryDirectory,time:Double(i)/30,playing:false,adaptive:true)}
        XCTAssertTrue(view.rendering)
        let deadline=ProcessInfo.processInfo.systemUptime+10
        while (view.displayedTime != 99.0/30 || view.rendering) && ProcessInfo.processInfo.systemUptime<deadline {try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertEqual(view.displayedTime,99.0/30);XCTAssertLessThanOrEqual(view.presentedFrames,2)
        let image=try XCTUnwrap(view.renderedImage);XCTAssertEqual(image.width,400)
        let color=try XCTUnwrap(NSBitmapImageRep(cgImage:image).colorAt(x:200,y:150)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(color.redComponent,0.9);XCTAssertLessThan(color.blueComponent,0.1)
    }
    func testParticlePreviewDetailIsDeterministicAndDoesNotChangeProject()throws {
        var project=Project();project.width=320;project.height=180;project.background="000000"
        var clip=Clip(kind:.particles,name:"Particles",track:0,start:0,duration:3)
        var settings=ParticleSettings();settings.count=1000;settings.burst=true;settings.emitterWidth=1;settings.emitterHeight=1;settings.velocity=0;settings.gravity=0;settings.size=3;clip.particles=settings;project.clips=[clip]
        let saved=try JSONEncoder().encode(project),renderer=FrameRenderer()
        func pixels(_ detail:Double)throws->[UInt8] {
            renderer.previewParticleDetail=detail
            let c=try XCTUnwrap(RasterTools.bitmap(CGSize(width:320,height:180)))
            renderer.draw(project:project,directory:FileManager.default.temporaryDirectory,time:0.5,context:c,size:CGSize(width:320,height:180))
            return Array(UnsafeBufferPointer(start:try XCTUnwrap(c.data).assumingMemoryBound(to:UInt8.self),count:c.bytesPerRow*c.height))
        }
        let full=try pixels(1),reduced=try pixels(0.25)
        XCTAssertNotEqual(full,reduced);XCTAssertEqual(reduced,try pixels(0.25));XCTAssertEqual(full,try pixels(1))
        XCTAssertEqual(try JSONDecoder().decode(Project.self,from:saved),project)
        XCTAssertEqual(FrameRenderer(useProxies:false).previewParticleDetail,1)
        let image=try XCTUnwrap(RasterTools.bitmap(CGSize(width:16,height:16))?.makeImage())
        XCTAssertTrue(EffectRenderer().apply(image,effects:[],time:0,pixelScale:1) === image)
        XCTAssertTrue(MaskRenderer().apply(image,masks:[],project:project,directory:FileManager.default.temporaryDirectory) === image)
    }
}
