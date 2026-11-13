import XCTest
import AVFoundation
@testable import VMM

final class LongProjectPerformanceTests:XCTestCase {
    /// Opt-in diagnostics: performance depends on the Mac. Never claim render throughput as UI FPS.
    func testLong4KProjectRenderingAndExport()async throws {
        guard let output=ProcessInfo.processInfo.environment["VMM_LONG_PROJECT_BENCHMARK"] else{throw XCTSkip("Opt-in long 4K project benchmark")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-long-4k-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        var results:[[String:Any]]=[]
        for pairs in [2,8] {
            var p=Project();p.width=3840;p.height=2160;p.fps=30
            p.tracks=(0..<32).map{Track(name:"Layer \($0)")}
            p.clips=(0..<1000).map{Clip(kind:.text,name:"字幕 \($0)",track:0,start:Double($0)*2,duration:1.5,text:"長尺プロジェクトの字幕 \($0)")}
            var base=Clip(kind:.shape,name:"Animated shape",track:1,start:0,duration:2000);base.color="66CCFF"
            base.animation=ClipAnimation(tracks:[AnimationTrack(property:.rotation,keys:(0...400).map{AnimationKeyframe(time:Double($0)*5,value:Double($0%36)*10,easing:.linear)})]);p.clips.append(base)
            for i in 0..<pairs {
                var particles=Clip(kind:.particles,name:"Particles",track:i*2+2,start:995,duration:20)
                var settings=ParticleSettings();settings.count=1000;settings.shape = .star;settings.burst=true;settings.lifetime=20;settings.emitterWidth=1;settings.emitterHeight=1
                particles.particles=settings;p.clips.append(particles)
                var mosaic=Clip(kind:.adjustment,name:"Mosaic",track:i*2+3,start:0,duration:2000)
                var effect=VisualEffect(kind:.pixelate);effect.amount=20;mosaic.effects=[effect]
                var region=AdjustmentRegion();region.width=0.5;region.height=0.5;mosaic.adjustmentRegion=region;p.clips.append(mosaic)
            }
            let renderer=FrameRenderer();var full:[Double]=[]
            let context=try XCTUnwrap(RasterTools.bitmap(CGSize(width:3840,height:2160)))
            for frame in 0..<7 {
                let start=ProcessInfo.processInfo.systemUptime
                autoreleasepool{renderer.draw(project:p,directory:root,time:1000+Double(frame)/30,context:context,size:CGSize(width:3840,height:2160))}
                full.append((ProcessInfo.processInfo.systemUptime-start)*1000)
            }
            var load=PreviewLoadController(),adaptive:[Double]=[],lastQuality=load.quality,lastSize=CGSize.zero
            for frame in 0..<90 {
                let quality=load.quality,size=quality.rasterSize(display:CGSize(width:1920,height:1080),project:p,playing:true,adaptive:true)
                let start=ProcessInfo.processInfo.systemUptime
                try autoreleasepool {
                    let ctx=try XCTUnwrap(RasterTools.bitmap(size));renderer.previewParticleDetail=quality.particles
                    renderer.draw(project:p,directory:root,time:1000+Double(frame)/30,context:ctx,size:size)
                }
                let elapsed=(ProcessInfo.processInfo.systemUptime-start)*1000
                adaptive.append(elapsed);load.record(milliseconds:elapsed,fps:p.fps);lastQuality=quality;lastSize=size
            }
            // Export a representative slice rather than writing a 33-minute synthetic movie.
            var slice=p;slice.clips=p.visibleClips(at:1000).map{clip in var c=clip;c.start=0;c.duration=0.2;return c}
            let movie=root.appendingPathComponent("4k-\(pairs).mp4"),start=ProcessInfo.processInfo.systemUptime
            try await MovieExporter.export(project:slice,directory:root,destination:movie){_ in}
            let exportSeconds=ProcessInfo.processInfo.systemUptime-start
            let asset=AVURLAsset(url:movie),track=try XCTUnwrap(asset.tracks(withMediaType:.video).first)
            XCTAssertEqual(track.naturalSize,CGSize(width:3840,height:2160));XCTAssertGreaterThan(asset.duration.seconds,0.15)
            let generator=AVAssetImageGenerator(asset:asset)
            XCTAssertEqual(try generator.copyCGImage(at:.zero,actualTime:nil).width,3840)
            let warm=full.dropFirst().sorted(),tail=adaptive.suffix(30).sorted()
            results.append(["clips":p.clips.count,"projectSeconds":p.duration,"width":p.width,"height":p.height,"pairs":pairs,"fullMedianMS":(warm[2]+warm[3])/2,"adaptiveMedianMS":(tail[14]+tail[15])/2,"adaptiveP95MS":tail[28],"adaptiveWidth":Int(lastSize.width),"adaptiveHeight":Int(lastSize.height),"particlePercent":Int(lastQuality.particles*100),"targetFPS":lastQuality.targetFPS(p.fps),"exportSliceSeconds":0.2,"exportWallSeconds":exportSeconds])
        }
        let report:[String:Any]=["date":ISO8601DateFormatter().string(from:Date()),"os":ProcessInfo.processInfo.operatingSystemVersionString,"physicalMemory":ProcessInfo.processInfo.physicalMemory,"samples":results,"scope":"Synthetic long-project render timings and short real 4K MP4 export; not whole-session playback FPS."]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:output))
        print("LONG 4K PROJECT \(results)")
    }
}
