import XCTest
import AVFoundation
import Darwin
@testable import VMM

final class MixedMediaSoakTests:XCTestCase {
    func memory()->UInt64 {
        var info=mach_task_basic_info(),count=mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size/MemoryLayout<integer_t>.size)
        let code=withUnsafeMutablePointer(to:&info){pointer in pointer.withMemoryRebound(to:integer_t.self,capacity:Int(count)){task_info(mach_task_self_,task_flavor_t(MACH_TASK_BASIC_INFO),$0,&count)}}
        return code==KERN_SUCCESS ? info.resident_size:0
    }
    func testHourLongMixedProjectPlaybackSaveRestoreAndExport()async throws {
        guard let reportPath=ProcessInfo.processInfo.environment["VMM_MIXED_MEDIA_SOAK"] else{throw XCTSkip("Opt-in two-minute mixed-media stability test")}
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-soak-\(UUID())")
        defer{try? FileManager.default.removeItem(at:folder)}
        var seed=try AudioDeliveryTests().fixture(folder);seed.clips[1].text="混在素材の検証";seed.clips[1].color="55AAFF"
        let mp4=folder.appendingPathComponent("Media/source.mp4"),mov=folder.appendingPathComponent("Media/source.mov")
        try await MovieExporter.export(project:seed,directory:folder,destination:mp4){_ in}
        var prores=UserSettings();prores.exportCodec="ProRes 422";prores.exportContainer="MOV"
        try await MovieExporter.export(project:seed,directory:folder,destination:mov,options:prores){_ in}
        let image=try XCTUnwrap(RasterTools.bitmap(CGSize(width:320,height:180)));image.setFillColor(NSColor.systemGreen.cgColor);image.fill(CGRect(x:0,y:0,width:320,height:180))
        try NSBitmapImageRep(cgImage:try XCTUnwrap(image.makeImage())).representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent("Media/image.png"))
        var p=Project();p.width=1280;p.height=720;p.fps=30
        p.assets=seed.assets+[MediaAsset(name:"MP4",file:"source.mp4",kind:.video,duration:2),MediaAsset(name:"MOV",file:"source.mov",kind:.video,duration:2),MediaAsset(name:"PNG",file:"image.png",kind:.image,duration:0)]
        for i in 0..<1200 {
            let start=Double(i)*3
            var v=Clip(kind:.video,name:"video \(i)",track:0,start:start,duration:2);v.assetID=p.assets[1+i%2].id;v.audioDisabled=true;p.clips.append(v)
            var caption=Clip(kind:.text,name:"caption \(i)",track:1,start:start,duration:3,text:"字幕 \(i)");caption.x=0.4;caption.y=0.8;p.clips.append(caption)
            var sound=Clip(kind:.audio,name:"audio \(i)",track:2,start:start,duration:2);sound.assetID=p.assets[0].id;sound.audioFade=AudioFade(fadeIn:0.05,fadeOut:0.1,curve:.equalPower);p.clips.append(sound)
        }
        var overlay=Clip(kind:.image,name:"image",track:3,start:0,duration:3600);overlay.assetID=p.assets[3].id;overlay.scale=0.2;overlay.x=0.9;p.clips.append(overlay)
        let package=folder.appendingPathComponent("saved.vmm");try ProjectPackage.write(p,media:folder.appendingPathComponent("Media"),to:package)
        let(restored,session)=try ProjectIO.read(package);defer{try? FileManager.default.removeItem(at:session)}
        XCTAssertEqual(restored,p.packageSnapshot)
        let renderer=FrameRenderer();renderer.setCacheBudget(megabytes:64);renderer.previewPlaying=true
        let size=CGSize(width:960,height:540),context=try XCTUnwrap(RasterTools.bitmap(size))
        let runSeconds=Double(ProcessInfo.processInfo.environment["VMM_SOAK_SECONDS"] ?? "120") ?? 120
        let start=ProcessInfo.processInfo.systemUptime,initial=memory();var peak=initial,peakCache=0,maxDecoders=0,frames=0,timings:[Double]=[]
        while ProcessInfo.processInfo.systemUptime-start<runSeconds {
            let tick=ProcessInfo.processInfo.systemUptime
            // Long timeline seeks, continuous short playback, and project/session switches.
            let time=Double((frames/90*179)%1199)*3+Double(frames%60)/30
            autoreleasepool {renderer.draw(project:frames%600<570 ? restored:seed,directory:frames%600<570 ? session:folder,time:frames%600<570 ? time:0.5,context:context,size:size)}
            let elapsed=ProcessInfo.processInfo.systemUptime-tick;timings.append(elapsed*1000);frames += 1
            peak=max(peak,memory());peakCache=max(peakCache,renderer.cacheUsage.bytes);maxDecoders=max(maxDecoders,renderer.cacheUsage.decoderCount)
            XCTAssertLessThanOrEqual(renderer.cacheUsage.bytes,renderer.cacheUsage.budget)
            if elapsed<1/30 {try await Task.sleep(nanoseconds:UInt64((1/30-elapsed)*1_000_000_000))}
        }
        let movie=folder.appendingPathComponent("sample.mp4");var options=UserSettings();options.rangeStart=1797;options.rangeEnd=1800;options.exportVideoMbps=4
        try await MovieExporter.export(project:restored,directory:session,destination:movie,options:options){_ in}
        let exported=AVURLAsset(url:movie),duration=try await exported.load(.duration).seconds
        XCTAssertEqual(duration,3,accuracy:1/30);let generator=AVAssetImageGenerator(asset:exported);XCTAssertEqual(try generator.copyCGImage(at:CMTime(seconds:1,preferredTimescale:30),actualTime:nil).width,1280)
        XCTAssertLessThan(peak-initial,512*1024*1024)
        let sorted=timings.sorted(),report:[String:Any]=["timelineSeconds":3600,"clipCount":p.clips.count,"runSeconds":ProcessInfo.processInfo.systemUptime-start,"frames":frames,"renderMedianMs":sorted[sorted.count/2],"renderP95Ms":sorted[Int(Double(sorted.count-1)*0.95)],"initialResidentMiB":Double(initial)/1048576,"peakResidentMiB":Double(peak)/1048576,"peakCacheMiB":Double(peakCache)/1048576,"maxDecoders":maxDecoders,"saveRestoreEqual":true,"exportSeconds":duration,"note":"Synthetic 1-hour timeline; two-minute rendering/seek soak. This is not a one-hour real-time playback or full export test." ]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:reportPath))
    }
}
