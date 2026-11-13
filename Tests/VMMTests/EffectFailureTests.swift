import XCTest
import AppKit
import CoreImage
@testable import VMM

private final class DelayedFailureKernel:CIImageProcessorKernel {
    override class var outputFormat:CIFormat {.RGBAf}
    override class func formatForInput(at index:Int32)->CIFormat {.RGBAf}
    override class func process(with inputs:[CIImageProcessorInput]?,arguments:[String:Any]?,output:CIImageProcessorOutput)throws {throw VMMError.message("forced lazy processor failure")}
}

final class EffectFailureTests:XCTestCase {
    private func failingRenderer() -> FrameRenderer {
        FrameRenderer(useProxies:false,effectRenderer:EffectRenderer(glitchFilter:{_,_,_,_,_,_,_,_ in throw VMMError.message("forced GPU and CPU failure")}))
    }
    private func project(_ scope:String) -> Project {
        var p=Project();p.width=320;p.height=180;p.background="000000"
        var shape=Clip(kind:.shape,name:"shape",track:0,start:0,duration:0.5);shape.color="808080"
        let effect=VisualEffect(kind:.chromaticAberration)
        switch scope {
        case "item":shape.effects=[effect];p.clips=[shape]
        case "layer":p.clips=[shape];p.tracks[0].effects=[effect]
        default:
            var adjustment=Clip(kind:.adjustment,name:"partial",track:1,start:0,duration:0.5)
            adjustment.effects=[effect];adjustment.adjustmentRegion=AdjustmentRegion(width:0.4,height:0.4);p.clips=[shape,adjustment]
        }
        return p
    }
    private func draw(_ renderer:FrameRenderer,_ project:Project)throws {
        let size=CGSize(width:320,height:180),context=try XCTUnwrap(RasterTools.bitmap(size))
        renderer.draw(project:project,directory:FileManager.default.temporaryDirectory,time:0,context:context,size:size)
    }
    func testItemLayerAndPartialFailuresPropagateAndDoNotPoisonCache()throws {
        for scope in ["item","layer","partial"] {
            let renderer=failingRenderer(),p=project(scope)
            try draw(renderer,p);XCTAssertTrue(renderer.renderingFailure?.contains("forced GPU and CPU failure") == true,scope)
            // The same frame should attempt to render again, rather than cache the failed output.
            try draw(renderer,p);XCTAssertNotNil(renderer.renderingFailure,scope)
            var clean=p;clean.clips.removeAll{$0.kind == .adjustment}
            clean.clips[0].effects=nil;clean.tracks[0].effects=nil
            try draw(renderer,clean);XCTAssertNil(renderer.renderingFailure,scope)
        }
    }
    func testLazyCoreImageFailureIsReported()throws {
        let renderer=FrameRenderer(effectRenderer:EffectRenderer(glitchFilter:{image,_,_,_,_,_,_,_ in image},rasterizeOverride:{_,_ in nil}))
        try draw(renderer,project("item"));XCTAssertTrue(renderer.renderingFailure?.contains("エフェクト") == true)
    }
    func testDeferredMetalFailureRetriesEntireEffectChainOnCPU()throws {
        let context=CIContext(options:[.cacheIntermediates:false]);var automaticCalls=0,cpuCalls=0,rasterCalls=0
        let effects=EffectRenderer(glitchFilter:{image,_,_,_,_,_,_,_ in automaticCalls+=1;return image},cpuGlitchFilter:{image,_,_,_,_,_,_,_ in cpuCalls+=1;return image},rasterizeOverride:{image,rect in
            rasterCalls+=1;return rasterCalls == 1 ? nil:context.createCGImage(image,from:rect)
        })
        let renderer=FrameRenderer(effectRenderer:effects)
        try draw(renderer,project("item"));XCTAssertNil(renderer.renderingFailure);XCTAssertEqual(automaticCalls,1);XCTAssertEqual(cpuCalls,1);XCTAssertEqual(rasterCalls,2)
    }
    func testDeferredFailureOnPartialRegionRetriesOnCPU()throws {
        let context=CIContext(options:[.cacheIntermediates:false]);var cpuCalls=0,rasterCalls=0
        let effects=EffectRenderer(glitchFilter:{image,_,_,_,_,_,_,_ in image},cpuGlitchFilter:{image,_,_,_,_,_,_,_ in cpuCalls+=1;return image},rasterizeOverride:{image,rect in
            rasterCalls+=1;return rasterCalls == 1 ? nil:context.createCGImage(image,from:rect)
        })
        let renderer=FrameRenderer(effectRenderer:effects)
        try draw(renderer,project("partial"));XCTAssertNil(renderer.renderingFailure);XCTAssertEqual(cpuCalls,1);XCTAssertEqual(rasterCalls,2)
    }
    func testActualDeferredProcessorFailureRetriesCPU()throws {
        var cpuCalls=0
        let effects=EffectRenderer(glitchFilter:{image,_,_,_,_,_,extent,_ in try DelayedFailureKernel.apply(withExtent:extent,inputs:[image],arguments:[:])},cpuGlitchFilter:{image,_,_,_,_,_,_,_ in cpuCalls+=1;return image})
        let renderer=FrameRenderer(effectRenderer:effects)
        try draw(renderer,project("item"));XCTAssertNil(renderer.renderingFailure);XCTAssertEqual(cpuCalls,1)
    }
    #if DEBUG
    func testActualCPUProcessorFailureIsReportedAfterRetry()throws {
        let failing:EffectRenderer.GlitchFilter={image,_,_,_,_,_,extent,signal in
            try GlitchCPUProcessor.failureForTesting(image:image,extent:extent,signal:signal)
        }
        let renderer=FrameRenderer(effectRenderer:EffectRenderer(glitchFilter:failing,cpuGlitchFilter:failing))
        try draw(renderer,project("item"));XCTAssertNotNil(renderer.renderingFailure)
    }
    #endif
    func testCheckedRasterizationKeepsColorAlphaOrientationAndPartialBounds()throws {
        let size=CGSize(width:96,height:64),c=try XCTUnwrap(RasterTools.bitmap(size))
        c.setFillColor(NSColor(calibratedRed:0.15,green:0.55,blue:0.85,alpha:0.4).cgColor);c.fill(CGRect(x:0,y:0,width:96,height:32))
        c.setFillColor(NSColor(calibratedRed:0.9,green:0.25,blue:0.1,alpha:0.8).cgColor);c.fill(CGRect(x:0,y:32,width:96,height:32))
        let source=try XCTUnwrap(c.makeImage()),engine=EffectRenderer(glitchFilter:{image,_,_,_,_,_,_,_ in image}),effect=VisualEffect(kind:.filmGrain),context=CIContext(options:[.cacheIntermediates:false])
        func compare(_ actual:CGImage,_ expected:CGImage)throws {
            let a=try GlitchEffectsTests().pixels(actual),b=try GlitchEffectsTests().pixels(expected)
            XCTAssertEqual(a.count,b.count);XCTAssertLessThanOrEqual(zip(a,b).map{abs(Int($0)-Int($1))}.max() ?? 0,1)
        }
        let reference=try XCTUnwrap(context.createCGImage(CIImage(cgImage:source),from:CGRect(origin:.zero,size:size)))
        try compare(engine.apply(source,effects:[effect],time:0,pixelScale:1),reference)
        let maskContext=try XCTUnwrap(RasterTools.bitmap(size));maskContext.setFillColor(NSColor.white.cgColor);maskContext.fill(CGRect(x:20,y:15,width:50,height:40))
        let mask=try XCTUnwrap(maskContext.makeImage()),bounds=CGRect(x:20,y:15,width:50,height:40)
        let masked=CIImage(cgImage:source).applyingFilter("CIBlendWithAlphaMask",parameters:[kCIInputBackgroundImageKey:CIImage(color:.clear).cropped(to:bounds),kCIInputMaskImageKey:CIImage(cgImage:mask)])
        let expected=try XCTUnwrap(context.createCGImage(masked,from:bounds)),actual=try XCTUnwrap(engine.partial(source,effects:[effect],time:0,pixelScale:1,mask:mask,bounds:bounds))
        try compare(actual,expected);XCTAssertNil(engine.failure)
    }
    func testFailedRenderDoesNotReplaceExistingMovie()async throws {
        let fm=FileManager.default,root=fm.temporaryDirectory.appendingPathComponent("vmm-effect-fail-\(UUID())")
        try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
        let destination=root.appendingPathComponent("movie.mp4"),original=Data("keep-existing-output".utf8);try original.write(to:destination)
        do {
            try await MovieExporter.export(project:project("partial"),directory:root,destination:destination,rendererOverride:failingRenderer()){_ in}
            XCTFail("The export must fail if the effect cannot render")
        } catch {XCTAssertTrue(error.localizedDescription.contains("forced GPU and CPU failure"),"\(error)")}
        XCTAssertEqual(try Data(contentsOf:destination),original)
    }
    @MainActor func testPreviewShowsCurrentFailureAndClearsIt() async throws {
        let view=PreviewNSView(frame:NSRect(x:0,y:0,width:320,height:180),renderer:failingRenderer())
        view.update(project:project("item"),directory:FileManager.default.temporaryDirectory,time:0,playing:false,adaptive:false)
        let deadline=ProcessInfo.processInfo.systemUptime+10
        while (view.rendering || view.displayedTime == nil) && ProcessInfo.processInfo.systemUptime<deadline {try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertTrue(view.renderingFailure?.contains("forced GPU and CPU failure") == true)
        var clean=project("item");clean.clips[0].effects=nil
        view.update(project:clean,directory:FileManager.default.temporaryDirectory,time:0,playing:false,adaptive:false)
        while view.rendering && ProcessInfo.processInfo.systemUptime<deadline {try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertNil(view.renderingFailure)
    }
}
