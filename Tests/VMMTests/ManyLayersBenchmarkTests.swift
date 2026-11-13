import XCTest
import AppKit
import AVFoundation
@testable import VMM

final class ManyLayersBenchmarkTests:XCTestCase {
    /// Reproducible opt-in stress diagnostic. Timings are not an interactive UI FPS measurement.
    func testManyLayersAndAnimatedMedia() async throws {
        guard let output=ProcessInfo.processInfo.environment["VMM_MANY_LAYERS_BENCHMARK"] else {throw XCTSkip("Opt-in many-layer benchmark")}
        let outputURL=URL(fileURLWithPath:output)
        guard !FileManager.default.fileExists(atPath:outputURL.path) else {throw VMMError.message("Benchmark report already exists")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-many-layers-\(UUID())"),media=root.appendingPathComponent("Media")
        try FileManager.default.createDirectory(at:media,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        for n in 0..<8 {
            let ctx=try XCTUnwrap(RasterTools.bitmap(CGSize(width:160,height:90)))
            ctx.setFillColor(NSColor(calibratedHue:CGFloat(n)/8,saturation:0.7,brightness:0.8,alpha:1).cgColor);ctx.fill(CGRect(x:0,y:0,width:160,height:90))
            ctx.setFillColor(NSColor.white.cgColor);ctx.fill(CGRect(x:n*10,y:20,width:40,height:40))
            let image=NSBitmapImageRep(cgImage:try XCTUnwrap(ctx.makeImage()))
            try XCTUnwrap(image.representation(using:.png,properties:[:])).write(to:media.appendingPathComponent("image\(n).png"))
        }
        var results:[[String:Any]]=[]
        for (layerCount,assetCount,clipCount) in [(8,64,128),(16,512,1024),(32,2048,8192)] {
            var project=Project();project.width=1280;project.height=720;project.fps=30
            project.tracks=(0..<layerCount).map{Track(name:"Layer \($0)")}
            project.assets=(0..<assetCount).map{MediaAsset(name:"Image \($0)",file:"image\($0%8).png",kind:.image,duration:1)}
            let properties:[AnimatedProperty]=[.x,.y,.scale,.rotation,.opacity]
            project.clips=(0..<layerCount).map { i in
                var c=Clip(kind:.image,name:"Animated \(i)",track:i,start:0,duration:1)
                c.assetID=project.assets[(i*53)%assetCount].id;c.scale=0.6;c.x=Double(i%8)/9+0.1;c.y=Double(i/8)/5+0.15
                c.animation=ClipAnimation(tracks:properties.map { property in
                    let values:[Double] = property == .rotation ? [0,15,-15,0] : property == .scale ? [0.6,0.7,0.5,0.6] : property == .opacity ? [1,0.7,0.9,1] : property == .x ? [c.x,c.x+0.05,c.x-0.05,c.x] : [c.y,c.y+0.05,c.y-0.05,c.y]
                    return AnimationTrack(property:property,keys:values.enumerated().map{AnimationKeyframe(time:Double($0.offset)/3,value:$0.element,easing:.easeInOut)})
                })
                return c
            }
            project.clips += (layerCount..<clipCount).map { i in
                var c=Clip(kind:.image,name:"Later \(i)",track:i%layerCount,start:2+Double(i-layerCount)*0.1,duration:0.09)
                c.assetID=project.assets[(i*53)%assetCount].id;return c
            }
            let renderer=FrameRenderer(),size=CGSize(width:1280,height:720)
            var draw:[Double]=[]
            for frame in 0..<40 {
                let start=ProcessInfo.processInfo.systemUptime
                try autoreleasepool {
                    let context=try XCTUnwrap(RasterTools.bitmap(size))
                    renderer.draw(project:project,directory:root,time:Double(frame%30)/30,context:context,size:size)
                    context.flush()
                }
                if frame>=10 {draw.append((ProcessInfo.processInfo.systemUptime-start)*1000)}
            }
            let sorted=draw.sorted()
            var settings=UserSettings();settings.rangeEnd=1
            var exports:[Double]=[]
            for run in 0..<2 {
                let movie=root.appendingPathComponent("layers-\(layerCount)-\(run).mp4"),start=ProcessInfo.processInfo.systemUptime
                try await MovieExporter.export(project:project,directory:root,destination:movie,options:settings){_ in}
                exports.append(ProcessInfo.processInfo.systemUptime-start)
                let asset=AVURLAsset(url:movie)
                let duration=try await asset.load(.duration)
                XCTAssertGreaterThan(duration.seconds,0.95)
                let generator=AVAssetImageGenerator(asset:asset)
                XCTAssertEqual(try generator.copyCGImage(at:CMTime(seconds:0.5,preferredTimescale:600),actualTime:nil).width,1280)
            }
            let entry:[String:Any]=["activeLayers":layerCount,"projectAssets":assetCount,"distinctImages":8,"projectClips":clipCount,"animatedClips":layerCount,"propertiesPerClip":5,"keysPerProperty":4,"width":1280,"height":720,"renderMedianMS":sorted[sorted.count/2],"renderP95MS":sorted[Int(Double(sorted.count-1)*0.95)],"exportWallSeconds":exports]
            results.append(entry);print("MANY_LAYERS_BENCHMARK \(entry)")
        }
        let info=ProcessInfo.processInfo
        let report:[String:Any]=["os":info.operatingSystemVersionString,"processorCount":info.processorCount,"physicalMemory":info.physicalMemory,"scope":"720p 30fps; synthetic PNG layers and animated properties; warm raster draw timings exclude UI; 1s H.264 MP4 export includes validation and encode.","samples":results]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:outputURL,options:.withoutOverwriting)
    }
}
