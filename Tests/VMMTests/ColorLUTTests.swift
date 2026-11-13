import XCTest
import AppKit
import AVFoundation
import SwiftUI
@testable import VMM

final class ColorLUTTests:XCTestCase {
    @MainActor func testPickerSnapshot()async throws {
        guard let output=testArtifactDirectory() else{throw XCTSkip("Opt-in LUT picker snapshot")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-lut-ui-\(UUID())"),s=EditorStore(preferencesDirectory:root)
        defer{try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:s.directory)}
        let size=CGSize(width:430,height:90),host=NSHostingView(rootView:ColorLUTPicker(store:s,cube:try cube()){_ in}.padding().frame(width:size.width,height:size.height).preferredColorScheme(.dark).vmmAppearance(s.settings))
        let window=NSWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.appearance=NSAppearance(named:.darkAqua);window.contentView=host;window.makeKeyAndOrderFront(nil);defer{window.close()}
        host.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:100_000_000)
        let rep=try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds));host.cacheDisplay(in:host.bounds,to:rep);try FileManager.default.createDirectory(atPath:output,withIntermediateDirectories:true)
        try XCTUnwrap(rep.representation(using:.png,properties:[:])).write(to:URL(fileURLWithPath:output).appendingPathComponent("lut-picker.png"))
    }
    func source(invert:Bool=false)->Data {
        var lines=["TITLE \"test\"","LUT_3D_SIZE 2","DOMAIN_MIN 0 0 0","DOMAIN_MAX 1 1 1"]
        for b in 0...1 {for g in 0...1 {for r in 0...1 {lines.append(invert ? "\(1-r) \(1-g) \(1-b)":"\(r) \(g) \(b)")}}}
        return Data(lines.joined(separator:"\n").utf8)
    }
    func cube(invert:Bool=false)throws->ColorLUT {try ColorLUT.parse(source(invert:invert),name:"test.cube")}
    func image()throws->CGImage {
        let c=try XCTUnwrap(RasterTools.bitmap(CGSize(width:100,height:100)))
        c.setFillColor(NSColor(calibratedRed:0.8,green:0.2,blue:0.3,alpha:0.5).cgColor);c.fill(CGRect(x:0,y:0,width:100,height:100))
        return try XCTUnwrap(c.makeImage())
    }
    func pixels(_ image:CGImage)throws->[UInt8] {let c=try XCTUnwrap(RasterTools.bitmap(CGSize(width:image.width,height:image.height)));c.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height));return try AdvancedTests().pixels(c)}
    func testParserAndUnsafeInputs()throws {
        let value=try cube();XCTAssertEqual(value.size,2);XCTAssertEqual(value.data.count,128);try value.validate()
        for text in ["LUT_3D_SIZE 99\n0 0 0","LUT_1D_SIZE 2\n0 0 0","LUT_3D_SIZE 2\nDOMAIN_MIN -1 0 0\n0 0 0","LUT_3D_SIZE 2\n0 nan 0","LUT_3D_SIZE 2\n0 0 0","LUT_3D_SIZE 2\n1.2 0 0"] {XCTAssertThrowsError(try ColorLUT.parse(Data(text.utf8),name:"test.cube"))}
        XCTAssertThrowsError(try ColorLUT.parse(Data(repeating:0,count:ColorLUT.maximumInputBytes+1),name:"bad"))
        let corrupt=ColorLUT(name:"bad",size:2,data:Data(repeating:0,count:128));XCTAssertThrowsError(try corrupt.validate())
    }
    func testSRGBIdentityStrengthAndAlpha()throws {
        let src=try image(),renderer=EffectRenderer(),base=try pixels(src)
        var effect=VisualEffect(kind:.colorLUT);effect.lut=try cube();effect.amount=1
        let identity=try pixels(renderer.apply(src,effects:[effect],time:0,pixelScale:1))
        XCTAssertLessThanOrEqual(zip(base,identity).map{abs(Int($0)-Int($1))}.max() ?? 0,2)
        effect.lut=try cube(invert:true);let full=try pixels(renderer.apply(src,effects:[effect],time:0,pixelScale:1));XCTAssertTrue(full != base)
        for i in stride(from:3,to:base.count,by:4) {XCTAssertEqual(base[i],full[i],accuracy:1)}
        effect.amount=0;XCTAssertTrue(try pixels(renderer.apply(src,effects:[effect],time:0,pixelScale:1)) == base)
        effect.amount=0.5;let half=try pixels(renderer.apply(src,effects:[effect],time:0,pixelScale:1));XCTAssertTrue(half != base && half != full)
        effect.keys=[AnimationKeyframe(time:0,value:0,easing:.linear),AnimationKeyframe(time:1,value:1,easing:.linear)]
        XCTAssertTrue(try pixels(renderer.apply(src,effects:[effect],time:0,pixelScale:1)) == base)
        XCTAssertTrue(try pixels(renderer.apply(src,effects:[effect],time:1,pixelScale:1)) == full)
    }
    @MainActor func testEmbeddedRoundTripScopeUndoAndSizeLimit()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-lut-\(UUID())"),s=EditorStore(preferencesDirectory:root)
        defer{try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:s.directory)}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        s.project=Project();var clip=Clip(kind:.adjustment,name:"LUT",track:1,start:0,duration:2);let effect=VisualEffect(kind:.colorLUT);clip.effects=[effect];s.project.clips=[clip]
        let file=root.appendingPathComponent("test.cube");try source(invert:true).write(to:file);let v=try ColorLUT.load(file);try s.setClipLUT(v,clipID:clip.id,effectID:effect.id);try FileManager.default.removeItem(at:file)
        let encoded=try JSONEncoder().encode(s.project),decoded=try JSONDecoder().decode(Project.self,from:encoded).validated();XCTAssertEqual(decoded.clips[0].effects?[0].lut,v)
        let package=root.appendingPathComponent("project.vmm");try ProjectPackage.write(s.project,media:s.directory.appendingPathComponent("Media"),to:package)
        let (reopened,session)=try ProjectIO.read(package);defer{try? FileManager.default.removeItem(at:session)};XCTAssertEqual(reopened.clips[0].effects?[0].lut,v)
        s.undo();XCTAssertNil(s.project.clips[0].effects?[0].lut)
        s.project.tracks[1].effects=[VisualEffect(kind:.colorLUT)];let trackEffect=try XCTUnwrap(s.project.tracks[1].effects?.first)
        try s.setTrackLUT(v,trackID:s.project.tracks[1].id,effectID:trackEffect.id);XCTAssertEqual(s.project.tracks[1].effects?.first?.lut,v)
        s.project.tracks[1].locked=true;XCTAssertThrowsError(try s.setClipLUT(v,clipID:clip.id,effectID:effect.id));s.project.tracks[1].locked=false
        var block=Data();block.reserveCapacity(33*33*33*16)
        for _ in 0..<(33*33*33) {block.append(contentsOf:[0,0,0,0,0,0,0,0,0,0,0,0,0,0,128,63])}
        let big=ColorLUT(name:"big",size:33,data:block);try big.validate();var p=Project();p.clips=[]
        for index in 0..<16 {var c=Clip(kind:.text,name:"\(index)",track:0,start:0,duration:1,text:"x");var e=VisualEffect(kind:.colorLUT);e.lut=big;c.effects=[e];p.clips.append(c)}
        XCTAssertThrowsError(try p.validated())
        p.clips.removeLast(2);_=try p.validated();s.project=p;s.selectedID=p.clips[0].id;s.playhead=0.5
        s.duplicateSelected();XCTAssertEqual(s.project.clips.count,14);XCTAssertNotNil(s.error)
        s.error=nil;s.splitSelected();XCTAssertEqual(s.project.clips.count,14);XCTAssertNotNil(s.error)
        p.clips=[];var missing=Clip(kind:.text,name:"missing",track:0,start:0,duration:1,text:"x");missing.effects=[VisualEffect(kind:.colorLUT)];p.clips=[missing]
        XCTAssertTrue(ExportPreflight.inspect(project:p,directory:s.directory,options:UserSettings()).issues.contains{$0.id.hasPrefix("lut-") && $0.severity == .warning})
    }
    func testPartialAndActualMP4()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-lut-export-\(UUID())");try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        var p=Project();p.width=320;p.height=180;p.background="000000"
        var shape=Clip(kind:.shape,name:"source",track:0,start:0,duration:0.5);shape.color="FF0000";shape.scale=3
        var a=Clip(kind:.adjustment,name:"LUT",track:1,start:0,duration:0.5);var effect=VisualEffect(kind:.colorLUT);effect.lut=try cube(invert:true);a.effects=[effect];a.adjustmentRegion=AdjustmentRegion(width:0.5,height:0.5);p.clips=[shape,a]
        func frame(_ renderer:FrameRenderer)throws->[UInt8] {let c=try XCTUnwrap(RasterTools.bitmap(CGSize(width:320,height:180)));renderer.draw(project:p,directory:root,time:0.1,context:c,size:CGSize(width:320,height:180));return try AdvancedTests().pixels(c)}
        let fast=FrameRenderer(),slow=FrameRenderer();slow.partialAdjustments=false
        let optimized=try frame(fast),reference=try frame(slow);XCTAssertLessThanOrEqual(zip(optimized,reference).map{abs(Int($0)-Int($1))}.max() ?? 0,2)
        let output=root.appendingPathComponent("lut.mp4");try await MovieExporter.export(project:p,directory:root,destination:output){_ in}
        let generator=AVAssetImageGenerator(asset:AVURLAsset(url:output)),image=try generator.copyCGImage(at:CMTime(seconds:0.1,preferredTimescale:600),actualTime:nil),data=try pixels(image)
        let i=(90*320+160)*4;XCTAssertGreaterThan(data[i+1],100);XCTAssertGreaterThan(data[i+2],100);XCTAssertLessThan(data[i],100)
    }
}
