import XCTest
import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
@testable import VMM

final class SceneTransitionMediaTests:XCTestCase {
    func testTextParticipatesInSceneTransition()throws {
        var project=AnimationTests().scene()
        project.clips[0].kind = .text;project.clips[0].text="TEST";project.clips[0].fontSize=100;project.clips[0].scale=1
        let first=try AnimationTests().render(project,1),middle=try AnimationTests().render(project,1.5)
        let bytes=try XCTUnwrap(first.data).assumingMemoryBound(to:UInt8.self)
        let index=try XCTUnwrap((0..<(first.width*first.height)).first{bytes[$0*4]>220 && bytes[$0*4+2]<10})
        let x=index%first.width,y=index/first.width
        let before=try AnimationTests().pixel(first,x:x,y:y),during=try AnimationTests().pixel(middle,x:x,y:y)
        XCTAssertEqual(during[0],before[0]/2,accuracy:5);XCTAssertEqual(during[2],128,accuracy:5)
    }
    func testOutgoingAnimatedGIFKeepsPlayingDuringTransition()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-transition-gif-\(UUID())")
        let media=root.appendingPathComponent("Media")
        try FileManager.default.createDirectory(at:media,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let destination=try XCTUnwrap(CGImageDestinationCreateWithURL(media.appendingPathComponent("moving.gif") as CFURL,UTType.gif.identifier as CFString,2,nil))
        CGImageDestinationSetProperties(destination,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
        for color in [NSColor.red,NSColor.green] {
            let context=try XCTUnwrap(RasterTools.bitmap(CGSize(width:320,height:180)))
            context.setFillColor(color.cgColor);context.fill(CGRect(x:0,y:0,width:320,height:180))
            CGImageDestinationAddImage(destination,try XCTUnwrap(context.makeImage()),[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:1.0]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        var project=AnimationTests().scene()
        let asset=MediaAsset(name:"moving",file:"moving.gif",kind:.image,duration:2)
        project.assets=[asset];project.clips[0].kind = .image;project.clips[0].assetID=asset.id;project.clips[0].scale=1
        let renderer=FrameRenderer(),context=try XCTUnwrap(CGContext(data:nil,width:320,height:180,bitsPerComponent:8,bytesPerRow:1280,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        renderer.draw(project:project,directory:root,time:1.5,context:context,size:CGSize(width:320,height:180))
        let mid=try AnimationTests().pixel(context)
        XCTAssertLessThan(mid[0],20);XCTAssertEqual(mid[1],128,accuracy:20);XCTAssertEqual(mid[2],128,accuracy:20)
        let output=root.appendingPathComponent("gif-transition.mp4")
        try await MovieExporter.export(project:project,directory:root,destination:output){_ in}
        let generator=AVAssetImageGenerator(asset:AVURLAsset(url:output));generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
        let frame=try generator.copyCGImage(at:CMTime(seconds:1.5,preferredTimescale:600),actualTime:nil)
        let exported=try XCTUnwrap(CGContext(data:nil,width:320,height:180,bitsPerComponent:8,bytesPerRow:1280,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        exported.draw(frame,in:CGRect(x:0,y:0,width:320,height:180))
        let pixel=try AnimationTests().pixel(exported)
        XCTAssertLessThan(pixel[0],25);XCTAssertEqual(pixel[1],128,accuracy:25);XCTAssertEqual(pixel[2],128,accuracy:25)
    }
    func testOutgoingVideoHoldsLastFrameWhenSourceEnds()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-transition-video-end-\(UUID())")
        let media=root.appendingPathComponent("Media")
        try FileManager.default.createDirectory(at:media,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        var source=Project();source.width=320;source.height=180
        var red=Clip(kind:.shape,name:"red",track:1,start:0,duration:1);red.color="FF0000";red.scale=4;source.clips=[red]
        try await MovieExporter.export(project:source,directory:root,destination:media.appendingPathComponent("red.mp4")){_ in}
        var project=AnimationTests().scene()
        let asset=MediaAsset(name:"red",file:"red.mp4",kind:.video,duration:1)
        project.assets=[asset];project.clips[0].kind = .video;project.clips[0].assetID=asset.id;project.clips[0].scale=1
        let renderer=FrameRenderer(),context=try XCTUnwrap(CGContext(data:nil,width:320,height:180,bitsPerComponent:8,bytesPerRow:1280,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        renderer.draw(project:project,directory:root,time:1.5,context:context,size:CGSize(width:320,height:180))
        XCTAssertNil(renderer.renderingFailure)
        let pixel=try AnimationTests().pixel(context)
        XCTAssertEqual(pixel[0],128,accuracy:20);XCTAssertEqual(pixel[2],128,accuracy:20)
    }
    func testOutgoingVideoKeepsPlayingDuringTransition()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-transition-motion-\(UUID())")
        let media=root.appendingPathComponent("Media")
        try FileManager.default.createDirectory(at:media,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        var source=Project();source.width=320;source.height=180
        var first=Clip(kind:.shape,name:"red",track:1,start:0,duration:1);first.color="FF0000";first.scale=4
        var second=Clip(kind:.shape,name:"green",track:1,start:1,duration:1);second.color="00FF00";second.scale=4
        source.clips=[first,second]
        try await MovieExporter.export(project:source,directory:root,destination:media.appendingPathComponent("moving.mp4")){_ in}
        var project=AnimationTests().scene()
        let asset=MediaAsset(name:"moving",file:"moving.mp4",kind:.video,duration:2)
        project.assets=[asset];project.clips[0].kind = .video;project.clips[0].assetID=asset.id;project.clips[0].scale=1
        let renderer=FrameRenderer(),context=try XCTUnwrap(CGContext(data:nil,width:320,height:180,bitsPerComponent:8,bytesPerRow:1280,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        renderer.draw(project:project,directory:root,time:1.5,context:context,size:CGSize(width:320,height:180))
        let mid=try AnimationTests().pixel(context)
        XCTAssertLessThan(mid[0],20,"The outgoing video must advance beyond its last timeline frame when source handles are available")
        XCTAssertEqual(mid[1],128,accuracy:20);XCTAssertEqual(mid[2],128,accuracy:20)
        let output=root.appendingPathComponent("moving-transition.mp4")
        try await MovieExporter.export(project:project,directory:root,destination:output){_ in}
        let generator=AVAssetImageGenerator(asset:AVURLAsset(url:output));generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
        let frame=try generator.copyCGImage(at:CMTime(seconds:1.5,preferredTimescale:600),actualTime:nil)
        let exported=try XCTUnwrap(CGContext(data:nil,width:320,height:180,bitsPerComponent:8,bytesPerRow:1280,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        exported.draw(frame,in:CGRect(x:0,y:0,width:320,height:180))
        let pixel=try AnimationTests().pixel(exported)
        XCTAssertLessThan(pixel[0],25);XCTAssertEqual(pixel[1],128,accuracy:25);XCTAssertEqual(pixel[2],128,accuracy:25)
        project.clips[0].sourceOffset=1;project.clips[0].reversed=true
        let reversed=try XCTUnwrap(CGContext(data:nil,width:320,height:180,bitsPerComponent:8,bytesPerRow:1280,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        renderer.draw(project:project,directory:root,time:1.5,context:reversed,size:CGSize(width:320,height:180))
        let reversePixel=try AnimationTests().pixel(reversed)
        XCTAssertEqual(reversePixel[0],128,accuracy:20);XCTAssertLessThan(reversePixel[1],20);XCTAssertEqual(reversePixel[2],128,accuracy:20)
    }
    func testVideoScenesTransitionInPreviewAndExport()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-transition-video-\(UUID())")
        let media=root.appendingPathComponent("Media")
        try FileManager.default.createDirectory(at:media,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        for (file,color) in [("red.mp4","FF0000"),("blue.mp4","0000FF")] {
            var project=Project();project.width=320;project.height=180
            var clip=Clip(kind:.shape,name:color,track:1,start:0,duration:2);clip.color=color;clip.scale=4
            project.clips=[clip]
            try await MovieExporter.export(project:project,directory:root,destination:media.appendingPathComponent(file)){_ in}
        }
        var project=AnimationTests().scene()
        let red=MediaAsset(name:"red",file:"red.mp4",kind:.video,duration:2)
        let blue=MediaAsset(name:"blue",file:"blue.mp4",kind:.video,duration:2)
        project.assets=[red,blue]
        project.clips[0].kind = .video;project.clips[0].assetID=red.id;project.clips[0].scale=1
        project.clips[1].kind = .video;project.clips[1].assetID=blue.id;project.clips[1].scale=1
        let renderer=FrameRenderer();renderer.previewPlaying=true
        let context=try XCTUnwrap(CGContext(data:nil,width:320,height:180,bitsPerComponent:8,bytesPerRow:1280,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        renderer.draw(project:project,directory:root,time:1.5,context:context,size:CGSize(width:320,height:180))
        XCTAssertNil(renderer.renderingFailure)
        let mid=try AnimationTests().pixel(context)
        XCTAssertEqual(mid[0],128,accuracy:16);XCTAssertEqual(mid[2],128,accuracy:16)
        let output=root.appendingPathComponent("transition.mp4")
        try await MovieExporter.export(project:project,directory:root,destination:output){_ in}
        let generator=AVAssetImageGenerator(asset:AVURLAsset(url:output));generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
        let image=try generator.copyCGImage(at:CMTime(seconds:1.5,preferredTimescale:600),actualTime:nil)
        let outputContext=try XCTUnwrap(CGContext(data:nil,width:320,height:180,bitsPerComponent:8,bytesPerRow:1280,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        outputContext.draw(image,in:CGRect(x:0,y:0,width:320,height:180))
        let exported=try AnimationTests().pixel(outputContext)
        XCTAssertEqual(exported[0],128,accuracy:20);XCTAssertEqual(exported[2],128,accuracy:20)
    }
}
