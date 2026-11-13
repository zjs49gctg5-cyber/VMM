import XCTest
import AppKit
@testable import VMM

final class GlitchVisualMigrationTests:XCTestCase {
    func testOptionalMetalStartup() throws {
        guard ProcessInfo.processInfo.environment["VMM_GLITCH_STARTUP"]=="1" else {throw XCTSkip("Optional Metal startup benchmark")}
        let start=ProcessInfo.processInfo.systemUptime
        XCTAssertNotNil(GlitchEffects.metalKernels)
        print(String(format:"GLITCH METAL INITIAL COMPILE %.1f ms",(ProcessInfo.processInfo.systemUptime-start)*1000))
    }
    func testCaptureMigrationReference() throws {
        guard let folder=ProcessInfo.processInfo.environment["VMM_GLITCH_REFERENCE_DIR"] else {throw XCTSkip("Optional migration reference")}
        let root=URL(fileURLWithPath:folder,isDirectory:true);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        print("GLITCH METAL AVAILABLE: \(GlitchEffects.metalKernels != nil)")
        let source=try GlitchEffectsTests().source(),renderer=EffectRenderer()
        for kind in [EffectKind.glitch,.chromaticAberration,.filmGrain] {
            var effect=VisualEffect(kind:kind);effect.id=UUID(uuidString:"A58B4149-77EE-47C5-827C-D8E21A5AB807")!;effect.amount=kind == .chromaticAberration ? 8:0.8
            for t in [0.25,0.5] {
                let img=renderer.apply(source,effects:[effect],time:t,pixelScale:1)
                let data=try XCTUnwrap(NSBitmapImageRep(cgImage:img).representation(using:.png,properties:[:]))
                try data.write(to:root.appendingPathComponent("\(kind.rawValue)-\(t).png"))
            }
        }
    }
    func testOptional4KPerformance() throws {
        guard ProcessInfo.processInfo.environment["VMM_GLITCH_BENCHMARK_4K"]=="1" else {throw XCTSkip("Optional 4K benchmark")}
        var p=Project();p.width=3840;p.height=2160;p.background="000000"
        var shape=Clip(kind:.shape,name:"performance",track:0,start:0,duration:3);shape.color="808080";shape.scale=3;p.clips=[shape]
        func run(_ p:Project)throws->Double {let renderer=FrameRenderer(),size=CGSize(width:3840,height:2160)
            func draw(_ t:Double)throws {let c=try XCTUnwrap(RasterTools.bitmap(size));renderer.draw(project:p,directory:FileManager.default.temporaryDirectory,time:t,context:c,size:size);_=c.makeImage()}
            try draw(0);let start=ProcessInfo.processInfo.systemUptime;for i in 1...3 {try draw(Double(i)/30)};return (ProcessInfo.processInfo.systemUptime-start)/3*1000}
        let baseline=try run(p);p.clips[0].effects=[VisualEffect(kind:.glitch),VisualEffect(kind:.chromaticAberration),VisualEffect(kind:.filmGrain)]
        let all=try run(p);print(String(format:"GLITCH BENCHMARK 4K baseline %.1f ms/frame, three effects %.1f ms/frame",baseline,all))
    }
}
