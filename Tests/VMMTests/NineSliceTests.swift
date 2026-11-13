import XCTest
import AppKit
import AVFoundation
@testable import VMM

final class NineSliceTests:XCTestCase {
    func testPatchGeometryAndLegacyValidation()throws {
        var settings=NineSliceSettings();settings.left=0.2;settings.right=0.1;settings.top=0.3;settings.bottom=0.1
        let patches=NineSlicePainter.patches(imageSize:CGSize(width:100,height:80),destination:CGRect(x:0,y:0,width:200,height:160),fit:1,settings:settings)
        XCTAssertEqual(patches.count,9);XCTAssertEqual(patches[0].source,CGRect(x:0,y:56,width:20,height:24));XCTAssertEqual(patches[0].destination,CGRect(x:0,y:0,width:20,height:24))
        let narrow=NineSlicePainter.patches(imageSize:CGSize(width:100,height:80),destination:CGRect(x:0,y:0,width:12,height:12),fit:1,settings:settings)
        XCTAssertTrue(narrow.allSatisfy{$0.destination.minX>=0 && $0.destination.maxX<=12 && $0.destination.minY>=0 && $0.destination.maxY<=12})
        var project=Project();let old=Clip(kind:.image,name:"image",track:0,start:0,duration:1);project.clips=[old]
        let decoded=try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(project));XCTAssertNil(decoded.clips[0].nineSlice)
        project.clips[0].nineSlice=settings;_=try project.validated();let roundTrip=try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(project));XCTAssertEqual(roundTrip.clips[0].nineSlice,settings)
        settings.left=0.9;settings.right=0.2;project.clips[0].nineSlice=settings;XCTAssertThrowsError(try project.validated())
        settings=NineSliceSettings();project.clips[0].kind = .text;project.clips[0].nineSlice=settings;XCTAssertThrowsError(try project.validated())
        project.clips[0].kind = .image;settings.width=2;project.clips[0].nineSlice=settings
        let legacy=try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(project));_=try legacy.validated();XCTAssertEqual(legacy.clips[0].nineSlice?.width,2)
        let report=ExportPreflight.inspect(project:legacy,directory:FileManager.default.temporaryDirectory,options:UserSettings())
        XCTAssertTrue(report.issues.contains{$0.id=="nine-slice-\(old.id)" && $0.severity == .warning});XCTAssertEqual(NineSliceSettings.userSize(2,current:0.5),1);XCTAssertEqual(NineSliceSettings.userSize(2,current:2),2);XCTAssertEqual(NineSliceSettings.userSize(1.5,current:2),1)
    }
    private func fixture(_ media:URL)throws {
        let context=try XCTUnwrap(CGContext(data:nil,width:40,height:40,bitsPerComponent:8,bytesPerRow:160,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor);context.fill(CGRect(x:0,y:0,width:40,height:40))
        for (color,rect) in [(NSColor.red,CGRect(x:0,y:36,width:4,height:4)),(NSColor.green,CGRect(x:36,y:36,width:4,height:4)),(NSColor.blue,CGRect(x:0,y:0,width:4,height:4)),(NSColor.yellow,CGRect(x:36,y:0,width:4,height:4))] {context.setFillColor(color.cgColor);context.fill(rect)}
        let png=try XCTUnwrap(NSBitmapImageRep(cgImage:try XCTUnwrap(context.makeImage())).representation(using:.png,properties:[:]))
        try png.write(to:media.appendingPathComponent("nine.png"))
    }
    @MainActor func testPreviewResizeAndUndo()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-nine-preview-\(UUID())"),store=EditorStore(preferencesDirectory:root);defer{try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        try fixture(store.directory.appendingPathComponent("Media"))
        let asset=MediaAsset(name:"frame",file:"nine.png",kind:.image,duration:0);var clip=Clip(kind:.image,name:"frame",track:0,start:0,duration:2);clip.assetID=asset.id;clip.nineSlice=NineSliceSettings()
        store.project.width=400;store.project.height=300;store.project.assets=[asset];store.project.clips=[clip];store.selectedID=clip.id
        let view=ObjectEditingView(frame:CGRect(x:0,y:0,width:400,height:300));view.store=store
        let geometry=try XCTUnwrap(view.geometry(clip)),start=geometry.points[4],end=CGPoint(x:start.x+50,y:start.y+30)
        func event(_ kind:NSEvent.EventType,_ p:CGPoint)->NSEvent {NSEvent.mouseEvent(with:kind,location:view.convert(p,to:nil),modifierFlags:[],timestamp:0,windowNumber:0,context:nil,eventNumber:0,clickCount:1,pressure:1)!}
        view.mouseDown(with:event(.leftMouseDown,start));view.mouseDragged(with:event(.leftMouseDragged,end));view.mouseUp(with:event(.leftMouseUp,end))
        let changed=try XCTUnwrap(store.selected);XCTAssertEqual(changed.nineSlice?.width ?? 0,0.625,accuracy:0.001);XCTAssertEqual(changed.nineSlice?.height ?? 0,0.4,accuracy:0.001);XCTAssertNil(changed.transform)
        let resized=try XCTUnwrap(view.geometry(changed));XCTAssertEqual(resized.points[0].x,geometry.points[0].x,accuracy:0.01);XCTAssertEqual(resized.points[0].y,geometry.points[0].y,accuracy:0.01)
        store.undo();XCTAssertEqual(store.project.clips,[clip])
        let outer=CGPoint(x:start.x+600,y:start.y+300)
        view.mouseDown(with:event(.leftMouseDown,start));view.mouseDragged(with:event(.leftMouseDragged,outer));view.mouseUp(with:event(.leftMouseUp,outer))
        XCTAssertEqual(store.selected?.nineSlice?.width,1);XCTAssertEqual(store.selected?.nineSlice?.height,1)
        store.undo();store.project.clips[0].nineSlice?.width=2
        let oversized=try XCTUnwrap(store.selected),oversizedGeometry=try XCTUnwrap(view.geometry(oversized)),bottom=oversizedGeometry.points[5],down=CGPoint(x:bottom.x,y:bottom.y+20)
        view.mouseDown(with:event(.leftMouseDown,bottom));view.mouseDragged(with:event(.leftMouseDragged,down));view.mouseUp(with:event(.leftMouseUp,down))
        XCTAssertEqual(store.selected?.nineSlice?.width,2);XCTAssertGreaterThan(store.selected?.nineSlice?.height ?? 0,0.3)
    }
    func testPreviewAndMP4PreserveFourCorners()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-nine-render-\(UUID())"),media=root.appendingPathComponent("Media");try FileManager.default.createDirectory(at:media,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)};try fixture(media)
        let asset=MediaAsset(name:"frame",file:"nine.png",kind:.image,duration:0);var clip=Clip(kind:.image,name:"frame",track:0,start:0,duration:1);clip.assetID=asset.id
        var slice=NineSliceSettings();slice.width=0.75;slice.height=0.5;slice.left=0.1;slice.right=0.1;slice.top=0.1;slice.bottom=0.1;clip.nineSlice=slice
        var project=Project();project.width=400;project.height=300;project.assets=[asset];project.clips=[clip];_=try project.validated()
        let renderer=FrameRenderer(),context=try XCTUnwrap(CGContext(data:nil,width:400,height:300,bitsPerComponent:8,bytesPerRow:1600,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        renderer.draw(project:project,directory:root,time:0.3,context:context,size:CGSize(width:400,height:300))
        let preview=NSBitmapImageRep(cgImage:try XCTUnwrap(context.makeImage()))
        func pixel(_ image:NSBitmapImageRep,_ x:Int,_ y:Int)throws->NSColor {try XCTUnwrap(image.colorAt(x:x,y:y)?.usingColorSpace(.sRGB))}
        XCTAssertGreaterThan(try pixel(preview,65,90).redComponent,0.7);XCTAssertGreaterThan(try pixel(preview,335,90).greenComponent,0.7)
        XCTAssertGreaterThan(try pixel(preview,65,210).blueComponent,0.7);XCTAssertGreaterThan(try pixel(preview,335,210).redComponent,0.7)
        let output=root.appendingPathComponent("frame.mp4");try await MovieExporter.export(project:project,directory:root,destination:output){_ in}
        let generator=AVAssetImageGenerator(asset:AVURLAsset(url:output));generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
        let movie=NSBitmapImageRep(cgImage:try generator.copyCGImage(at:CMTime(seconds:0.3,preferredTimescale:600),actualTime:nil))
        XCTAssertGreaterThan(try pixel(movie,65,90).redComponent,0.6);XCTAssertGreaterThan(try pixel(movie,335,90).greenComponent,0.6)
        XCTAssertGreaterThan(try pixel(movie,65,210).blueComponent,0.6);XCTAssertGreaterThan(try pixel(movie,335,210).redComponent,0.6)
    }
    func testAnimatedGIFAndPSDRemainDynamic()throws {
        let helper=AnimatedGIFTests(),root=try helper.fixture();defer{try? FileManager.default.removeItem(at:root)}
        var project=helper.project();var slice=NineSliceSettings();slice.width=0.75;slice.height=0.75;project.clips[0].nineSlice=slice
        let renderer=FrameRenderer()
        func frame(_ project:Project,_ time:Double)throws->[UInt8] {let context=try XCTUnwrap(RasterTools.bitmap(CGSize(width:64,height:64)));renderer.draw(project:project,directory:root,time:time,context:context,size:CGSize(width:64,height:64));return try helper.pixel(context)}
        let red=try frame(project,0.2),blue=try frame(project,0.7);XCTAssertGreaterThan(red[0],red[2]);XCTAssertGreaterThan(blue[2],blue[0])
        let document=PSDDocument(width:32,height:32,layers:[PSDLayer(id:0,name:"色",group:false,visible:true,opacity:1,x:0,y:0,width:32,height:32,file:"nine.png")])
        try fixture(root.appendingPathComponent("Media"));var image=MediaAsset(name:"PSD",file:"nine.png",kind:.image,duration:0);image.psd=document
        project.assets=[image];project.clips[0].assetID=image.id;project.clips[0].psd=PSDState(selected:document.defaults)
        _=try project.validated();let psd=try frame(project,0.2);XCTAssertGreaterThan(psd[0],200);XCTAssertGreaterThan(psd[1],200);XCTAssertGreaterThan(psd[2],200)
    }
    func testMaskAndParentTransformStillApply()throws {
        let root=try AdvancedTests().folder();defer{try? FileManager.default.removeItem(at:root)};try fixture(root.appendingPathComponent("Media"))
        let asset=MediaAsset(name:"frame",file:"nine.png",kind:.image,duration:0)
        var group=Clip(kind:.group,name:"parent",track:0,start:0,duration:1);group.x=0.6;group.scale=0.5
        var clip=Clip(kind:.image,name:"frame",track:1,start:0,duration:1);clip.assetID=asset.id;clip.nineSlice=NineSliceSettings();clip.parentID=group.id
        var project=Project();project.width=400;project.height=300;project.assets=[asset];project.clips=[group,clip]
        let renderer=FrameRenderer()
        func pixel(_ x:Int,_ y:Int)throws->NSColor {let context=try XCTUnwrap(RasterTools.bitmap(CGSize(width:400,height:300)));renderer.draw(project:project,directory:root,time:0.2,context:context,size:CGSize(width:400,height:300));return try XCTUnwrap(NSBitmapImageRep(cgImage:try XCTUnwrap(context.makeImage())).colorAt(x:x,y:y)?.usingColorSpace(.sRGB))}
        XCTAssertGreaterThan(try pixel(240,150).redComponent,0.8);XCTAssertLessThan(try pixel(100,150).redComponent,0.2)
        var mask=ClipMask();mask.width=0.1;mask.height=0.1;clip.masks=[mask];project.clips=[group,clip]
        XCTAssertGreaterThan(try pixel(240,150).redComponent,0.8);XCTAssertLessThan(try pixel(280,150).redComponent,0.2)
    }
    func testScaledNineSliceInsideScaledParentMatchesMP4() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-nine-parent-\(UUID())"),media=root.appendingPathComponent("Media")
        try FileManager.default.createDirectory(at:media,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)};try fixture(media)
        let asset=MediaAsset(name:"frame",file:"nine.png",kind:.image,duration:0)
        var parent=Clip(kind:.group,name:"parent",track:1,start:0,duration:1);parent.scale=1.25
        var clip=Clip(kind:.image,name:"frame",track:0,start:0,duration:1);clip.assetID=asset.id;clip.parentID=parent.id;clip.scale=1.2
        var slice=NineSliceSettings();slice.width=0.5;slice.height=0.4;slice.left=0.1;slice.right=0.1;slice.top=0.1;slice.bottom=0.1;clip.nineSlice=slice
        var project=Project();project.width=400;project.height=300;project.background="000000";project.assets=[asset];project.clips=[clip,parent];_=try project.validated()
        let ctx=try XCTUnwrap(RasterTools.bitmap(CGSize(width:400,height:300)));FrameRenderer().draw(project:project,directory:root,time:0.3,context:ctx,size:CGSize(width:400,height:300))
        let preview=NSBitmapImageRep(cgImage:try XCTUnwrap(ctx.makeImage()))
        func pixel(_ image:NSBitmapImageRep,_ x:Int,_ y:Int)throws->NSColor {try XCTUnwrap(image.colorAt(x:x,y:y)?.usingColorSpace(.sRGB))}
        for x in [60,90] {let color=try pixel(preview,x,70);XCTAssertGreaterThan(color.redComponent,0.7);XCTAssertLessThan(color.greenComponent,0.3)}
        let edge=try pixel(preview,105,70);XCTAssertGreaterThan(edge.redComponent,0.7);XCTAssertGreaterThan(edge.greenComponent,0.7)
        let output=root.appendingPathComponent("scaled.mp4");try await MovieExporter.export(project:project,directory:root,destination:output){_ in}
        let gen=AVAssetImageGenerator(asset:AVURLAsset(url:output));gen.requestedTimeToleranceBefore = .zero;gen.requestedTimeToleranceAfter = .zero
        let movie=NSBitmapImageRep(cgImage:try gen.copyCGImage(at:CMTime(seconds:0.3,preferredTimescale:600),actualTime:nil))
        var error=0.0,count=0.0
        for y in stride(from:0,to:300,by:4){for x in stride(from:0,to:400,by:4){let a=try pixel(preview,x,y),b=try pixel(movie,x,y);error+=abs(a.redComponent-b.redComponent)+abs(a.greenComponent-b.greenComponent)+abs(a.blueComponent-b.blueComponent);count+=3}}
        XCTAssertLessThan(error/count,0.04)
    }
}
