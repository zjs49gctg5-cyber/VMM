import XCTest
import AppKit
@testable import VMM

final class RenderPerformanceTests:XCTestCase {
    /// Opt-in: measures actual rendering rather than enforcing machine-dependent FPS in CI.
    func testRenderingLoadBenchmark()throws {
        guard let output=ProcessInfo.processInfo.environment["VMM_RENDER_BENCHMARK"] else {throw XCTSkip("Set VMM_RENDER_BENCHMARK to a new JSON output path.")}
        var results:[[String:Any]]=[]
        for (width,height) in [(640,360),(1280,720),(1920,1080),(3840,2160)] {
            for kind in ["particles","mosaic","combined"] {
                for count in [1,4,8,16] {
                    // 4K stresses memory and export; limit layer counts to keep this diagnostic bounded.
                    if width==3840 && count>8 {continue}
                    var p=Project();p.width=1920;p.height=1080;p.clips=[]
                    p.tracks=(0...count*2).map{Track(name:"Layer \($0+1)")}
                    var base=Clip(kind:.shape,name:"Background shape",track:0,start:0,duration:10)
                    base.color="66CCFF";base.rotation=25;p.clips=[base]
                    for i in 0..<count {
                        if kind != "mosaic" {
                            var c=Clip(kind:.particles,name:"Particles",track:i*2+1,start:0,duration:10)
                            var s=ParticleSettings();s.count=1000;s.shape = .star;s.lifetime=8;s.burst=true;s.emitterWidth=1;s.emitterHeight=1
                            c.particles=s;p.clips.append(c)
                        }
                        if kind != "particles" {
                            var c=Clip(kind:.adjustment,name:"Mosaic",track:i*2+2,start:0,duration:10)
                            var effect=VisualEffect(kind:.pixelate);effect.amount=20;c.effects=[effect]
                            var region=AdjustmentRegion();region.width=0.5;region.height=0.5;c.adjustmentRegion=region
                            p.clips.append(c)
                        }
                    }
                    let renderer=FrameRenderer(),size=CGSize(width:width,height:height)
                    let context=try XCTUnwrap(RasterTools.bitmap(size))
                    var samples:[Double]=[]
                    for frame in 0..<7 {
                        let start=ProcessInfo.processInfo.systemUptime
                        autoreleasepool {renderer.draw(project:p,directory:FileManager.default.temporaryDirectory,time:0.5+Double(frame)/30,context:context,size:size)}
                        samples.append((ProcessInfo.processInfo.systemUptime-start)*1000)
                    }
                    let warm=Array(samples.dropFirst()).sorted(),median=(warm[2]+warm[3])/2,p95=warm.last!
                    results.append(["width":width,"height":height,"kind":kind,"layers":count,"particles":kind=="mosaic" ? 0:count*1000,"coldMS":samples[0],"medianMS":median,"p95MS":p95,"renderFPS":1000/median])
                    print("RENDER \(width)x\(height) \(kind) \(count): \(String(format:"%.1f",median)) ms, \(String(format:"%.1f",1000/median)) fps")
                }
            }
        }
        var adaptiveResults:[[String:Any]]=[]
        for count in [4,8,16] {
            var p=Project();p.width=1920;p.height=1080;p.clips=[]
            p.tracks=(0...count*2).map{Track(name:"Layer \($0+1)")}
            var base=Clip(kind:.shape,name:"Base",track:0,start:0,duration:10);base.color="66CCFF";p.clips=[base]
            for i in 0..<count {
                var c=Clip(kind:.particles,name:"Particles",track:i*2+1,start:0,duration:10)
                var settings=ParticleSettings();settings.count=1000;settings.shape = .star;settings.burst=true;settings.lifetime=8;settings.emitterWidth=1;settings.emitterHeight=1;c.particles=settings;p.clips.append(c)
                var effect=Clip(kind:.adjustment,name:"Mosaic",track:i*2+2,start:0,duration:10)
                var pixelate=VisualEffect(kind:.pixelate);pixelate.amount=20;effect.effects=[pixelate]
                var region=AdjustmentRegion();region.width=0.5;region.height=0.5;effect.adjustmentRegion=region;p.clips.append(effect)
            }
            let renderer=FrameRenderer();var load=PreviewLoadController(),times:[Double]=[],lastSize=CGSize.zero,lastQuality=PreviewQuality(level:0)
            for frame in 0..<90 {
                let quality=load.quality,size=quality.rasterSize(display:CGSize(width:1920,height:1080),project:p,playing:true,adaptive:true)
                let start=ProcessInfo.processInfo.systemUptime
                try autoreleasepool {
                    let context=try XCTUnwrap(RasterTools.bitmap(size));renderer.previewParticleDetail=quality.particles
                    renderer.draw(project:p,directory:FileManager.default.temporaryDirectory,time:0.5+Double(frame)/30,context:context,size:size)
                }
                let elapsed=(ProcessInfo.processInfo.systemUptime-start)*1000
                load.record(milliseconds:elapsed,fps:30);times.append(elapsed);lastSize=size;lastQuality=quality
            }
            let warm=times.suffix(30).sorted(),median=(warm[14]+warm[15])/2
            adaptiveResults.append(["pairs":count,"totalLayers":count*2,"width":Int(lastSize.width),"height":Int(lastSize.height),"particlePercent":Int(lastQuality.particles*100),"qualityLevel":lastQuality.level,"medianMS":median,"p95MS":warm[28],"renderFPS":1000/median])
            print("ADAPTIVE \(count) pairs: \(lastSize), particles \(lastQuality.particles), \(String(format:"%.1f",median)) ms")
        }
        let info=ProcessInfo.processInfo
        let report:[String:Any]=["os":info.operatingSystemVersionString,"processorCount":info.processorCount,"physicalMemory":info.physicalMemory,"date":ISO8601DateFormatter().string(from:Date()),"samples":results,"adaptive":adaptiveResults]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:output))
    }
}
