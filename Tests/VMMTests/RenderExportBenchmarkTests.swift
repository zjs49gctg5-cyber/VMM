import XCTest
import AppKit
import AVFoundation
@testable import VMM

final class RenderExportBenchmarkTests:XCTestCase {
    func testGuideOptimizationBenchmarkOptIn()async throws {
        guard let source=ProcessInfo.processInfo.environment["VMM_GUIDE_BENCHMARK"],let output=ProcessInfo.processInfo.environment["VMM_RENDER_OPT_OUTPUT"] else {throw XCTSkip("Opt-in independent guide render/export benchmark")}
        let directory=URL(fileURLWithPath:source),root=URL(fileURLWithPath:output)
        guard !FileManager.default.fileExists(atPath:root.path) else {throw VMMError.message("Benchmark output must be a new directory")}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let project=try JSONDecoder().decode(Project.self,from:Data(contentsOf:directory.appendingPathComponent("project.json")))
        var results:[[String:Any]]=[]
        for start in [0.0,230.0,325.0] {
            var pair:[[UInt8]]=[]
            for optimized in [false,true] {
                let renderer=FrameRenderer(useProxies:false);renderer.boundedNodes=optimized;renderer.reuseStaticBackgrounds=optimized
                var times:[Double]=[]
                for frame in 0..<90 {
                    try autoreleasepool {
                        let begin=ProcessInfo.processInfo.systemUptime
                        let context=try XCTUnwrap(RasterTools.bitmap(CGSize(width:1920,height:1080)))
                        renderer.draw(project:project,directory:directory,time:start+Double(frame)/30,context:context,size:CGSize(width:1920,height:1080))
                        context.flush()
                        if frame>=10 {times.append((ProcessInfo.processInfo.systemUptime-begin)*1000)}
                        if frame==60 {
                            pair.append(Array(UnsafeBufferPointer(start:try XCTUnwrap(context.data).assumingMemoryBound(to:UInt8.self),count:context.height*context.bytesPerRow)))
                            let image=try XCTUnwrap(context.makeImage())
                            try XCTUnwrap(NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])).write(to:root.appendingPathComponent("\(optimized ? "optimized":"reference")-\(Int(start)).png"))
                        }
                    }
                }
                var settings=UserSettings();settings.exportWidth=1920;settings.exportHeight=1080;settings.exportFPS=30;settings.exportVideoMbps=8;settings.exportAudioKbps=320;settings.exportTemplate="youtube1080";settings.rangeStart=start;settings.rangeEnd=start+10
                let destination=root.appendingPathComponent("\(optimized ? "optimized":"reference")-\(Int(start)).mp4")
                let begin=ProcessInfo.processInfo.systemUptime
                try await MovieExporter.export(project:project,directory:directory,destination:destination,options:settings,optimizeRendering:optimized){_ in}
                let exportSeconds=ProcessInfo.processInfo.systemUptime-begin,sorted=times.sorted()
                let entry:[String:Any]=["optimized":optimized,"startSeconds":start,"durationSeconds":10,"drawMedianMS":sorted[sorted.count/2],"drawP95MS":sorted[Int(Double(sorted.count-1)*0.95)],"exportSeconds":exportSeconds,"exportFPS":300/exportSeconds,"backgroundHits":renderer.backgroundHits,"staticNodeHits":renderer.staticHits,"boundedNodeRenders":renderer.boundedNodeRenders,"cacheBytes":renderer.cacheUsage.bytes]
                results.append(entry);print("GUIDE_RENDER_BENCHMARK \(entry)")
            }
            let errors=zip(pair[0],pair[1]).map{abs(Int($0)-Int($1))}
            let maximum=errors.max() ?? 0,mean=Double(errors.reduce(0,+))/Double(errors.count)
            XCTAssertLessThanOrEqual(maximum,2);print("GUIDE_PIXEL_COMPARISON start=\(start) max=\(maximum) mean=\(mean)")
            results.append(["startSeconds":start,"pixelMaxError":maximum,"pixelMeanError":mean])
            var movieFrames:[[UInt8]]=[]
            for prefix in ["reference","optimized"] {
                let asset=AVURLAsset(url:root.appendingPathComponent("\(prefix)-\(Int(start)).mp4"))
                let duration=try await asset.load(.duration);XCTAssertEqual(duration.seconds,10,accuracy:0.05)
                let generator=AVAssetImageGenerator(asset:asset);generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
                let image=try generator.copyCGImage(at:CMTime(seconds:2,preferredTimescale:600),actualTime:nil)
                let context=try XCTUnwrap(RasterTools.bitmap(CGSize(width:1920,height:1080)));context.draw(image,in:CGRect(x:0,y:0,width:1920,height:1080));context.flush()
                movieFrames.append(Array(UnsafeBufferPointer(start:try XCTUnwrap(context.data).assumingMemoryBound(to:UInt8.self),count:context.height*context.bytesPerRow)))
            }
            let movieMean=zip(movieFrames[0],movieFrames[1]).reduce(0.0){$0+Double(abs(Int($1.0)-Int($1.1)))}/Double(movieFrames[0].count)
            XCTAssertLessThan(movieMean,2);print("GUIDE_MOVIE_COMPARISON start=\(start) mean=\(movieMean)")
        }
        try JSONSerialization.data(withJSONObject:results,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("timing.json"))
        print("GUIDE_RENDER_BENCHMARK_PATH \(root.path)")
    }
}
