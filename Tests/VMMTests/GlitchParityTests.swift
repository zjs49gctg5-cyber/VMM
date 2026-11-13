import XCTest
import AppKit
import AVFoundation
@testable import VMM

final class GlitchParityTests:XCTestCase {
    func testAnimatedEffectsPreviewMatchesActualMP4() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-glitch-parity-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        var project=Project();project.width=320;project.height=180;project.background="172330";project.fps=30
        var shape=Clip(kind:.shape,name:"subject",track:1,start:0,duration:0.6);shape.color="CC6633";shape.scale=2
        for kind in [EffectKind.glitch,.chromaticAberration,.filmGrain] {
            var effect=VisualEffect(kind:kind);effect.amount=kind == .chromaticAberration ? 10:0.7;shape.effects=[effect];project.clips=[shape]
            var options=UserSettings();options.exportVideoMbps=20
            let output=root.appendingPathComponent("\(kind.rawValue).mp4");try await MovieExporter.export(project:project,directory:root,destination:output,options:options){_ in}
            let generator=AVAssetImageGenerator(asset:AVURLAsset(url:output));generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
            for time in [0.1,0.3] {
                let context=try XCTUnwrap(RasterTools.bitmap(CGSize(width:320,height:180)));FrameRenderer().draw(project:project,directory:root,time:time,context:context,size:CGSize(width:320,height:180))
                let preview=NSBitmapImageRep(cgImage:try XCTUnwrap(context.makeImage())),movie=NSBitmapImageRep(cgImage:try generator.copyCGImage(at:CMTime(seconds:time,preferredTimescale:600),actualTime:nil))
                var error=0.0,count=0.0
                for y in stride(from:0,to:180,by:3){for x in stride(from:0,to:320,by:3){let a=try XCTUnwrap(preview.colorAt(x:x,y:y)?.usingColorSpace(.sRGB)),b=try XCTUnwrap(movie.colorAt(x:x,y:y)?.usingColorSpace(.sRGB));error+=abs(a.redComponent-b.redComponent)+abs(a.greenComponent-b.greenComponent)+abs(a.blueComponent-b.blueComponent);count+=3}}
                XCTAssertLessThan(error/count,0.08,"Preview and MP4 mismatch for \(kind) at \(time)")
            }
        }
    }
}
