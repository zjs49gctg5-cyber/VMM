import XCTest
import AppKit
import AVFoundation
@testable import VMM

final class BoundedNeutralTransformTests:XCTestCase {
    private func fixture()throws->(URL,Project) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-neutral-bounds-\(UUID())")
        let media=root.appendingPathComponent("Media")
        try FileManager.default.createDirectory(at:media,withIntermediateDirectories:true)
        let c=try XCTUnwrap(RasterTools.bitmap(CGSize(width:83,height:121)))
        c.setFillColor(NSColor.orange.withAlphaComponent(0.7).cgColor);c.fill(CGRect(x:4,y:8,width:75,height:105))
        c.setFillColor(NSColor.blue.cgColor);c.fillEllipse(in:CGRect(x:17,y:24,width:39,height:47))
        let png=NSBitmapImageRep(cgImage:try XCTUnwrap(c.makeImage()))
        try XCTUnwrap(png.representation(using:.png,properties:[:])).write(to:media.appendingPathComponent("image.png"))
        var p=Project();p.width=320;p.height=180;p.fps=30
        let asset=MediaAsset(name:"still",file:"image.png",kind:.image,duration:2);p.assets=[asset]
        var c1=Clip(kind:.image,name:"image",track:0,start:0,duration:1);c1.assetID=asset.id
        c1.animation=ClipAnimation(tracks:[AnimationTrack(property:.rotation,keys:[AnimationKeyframe(time:0,value:-36),AnimationKeyframe(time:1,value:44)])])
        p.clips=[c1];return (root,p)
    }
    private func pixels(_ renderer:FrameRenderer,_ p:Project,_ root:URL,_ t:Double,_ size:CGSize)throws->[UInt8] {
        let c=try XCTUnwrap(RasterTools.bitmap(size))
        renderer.draw(project:p,directory:root,time:t,context:c,size:size);c.flush()
        return Array(UnsafeBufferPointer(start:try XCTUnwrap(c.data).assumingMemoryBound(to:UInt8.self),count:c.height*c.bytesPerRow))
    }
    func testTransformedImageClippingMatchesFullFrame()throws {
        let (root,initial)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let fast=FrameRenderer(useProxies:false),reference=FrameRenderer(useProxies:false);reference.boundNeutralTransforms=false
        for size in [CGSize(width:320,height:180),CGSize(width:160,height:90)] {
            for i in 0..<24 {
                var p=initial
                p.clips[0].x=[-0.12,0.08,0.5,0.91,1.1,0.66][i%6]
                p.clips[0].y=[-0.06,0.13,0.5,0.96,1.09,0.62][(i/2)%6]
                p.clips[0].scale=[0.25,0.73,1.0,1.8][i%4];p.clips[0].opacity=[0.2,0.63,1][i%3]
                p.clips[0].flipX=i%2==0;p.clips[0].flipY=i%3==0
                p.clips[0].transform=Transform2D(scaleX:1.13,scaleY:0.86,skewX:12,skewY:-7)
                for time in [0.11,0.37,0.83] {
                    let a=try pixels(fast,p,root,time,size),b=try pixels(reference,p,root,time,size)
                    let error=zip(a,b).map{abs(Int($0)-Int($1))}.max() ?? 0
                    XCTAssertLessThanOrEqual(error,2,"case \(i) size \(size) time \(time)")
                }
            }
        }
    }
    func testOptInPerformance()async throws {
        guard ProcessInfo.processInfo.environment["VMM_NEUTRAL_BOUNDS_BENCHMARK"]=="1" else{throw XCTSkip("Opt-in comparison")}
        let (root,initial)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        for count in [4,8,16] {
            var p=initial;p.width=1280;p.height=720;p.tracks=(0..<count).map{Track(name:"layer\($0)")}
            p.clips=(0..<count).map{i in var c=initial.clips[0];c.id=UUID();c.track=i;c.x=0.1+Double(i%8)*0.11;c.y=0.25+Double(i/8)*0.45;c.scale=0.35;c.opacity=0.8;return c}
            let size=CGSize(width:1280,height:720)
            for bounded in [false,true] {
                let renderer=FrameRenderer(useProxies:false);renderer.boundNeutralTransforms=bounded
                var times:[Double]=[]
                for frame in 0..<20 {
                    let start=ProcessInfo.processInfo.systemUptime
                    try autoreleasepool{let c=try XCTUnwrap(RasterTools.bitmap(size));renderer.draw(project:p,directory:root,time:Double(frame)/30,context:c,size:size);c.flush()}
                    if frame>=4 {times.append((ProcessInfo.processInfo.systemUptime-start)*1000)}
                }
                let movie=root.appendingPathComponent("\(count)-\(bounded).mp4"),begin=ProcessInfo.processInfo.systemUptime
                try await MovieExporter.export(project:p,directory:root,destination:movie,rendererOverride:renderer){_ in}
                let elapsed=ProcessInfo.processInfo.systemUptime-begin,sorted=times.sorted()
                let asset=AVURLAsset(url:movie);let duration=try await asset.load(.duration);XCTAssertGreaterThan(duration.seconds,0.95)
                print("NEUTRAL_BOUNDS count=\(count) bounded=\(bounded) median_ms=\(sorted[sorted.count/2]) max_ms=\(sorted.last!) export_s=\(elapsed)")
            }
        }
    }
}
