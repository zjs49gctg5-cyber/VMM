import XCTest
import AppKit
import AVFoundation
@testable import VMM

final class AdvancedTests:XCTestCase {
    func project()->Project {var p=Project();p.width=320;p.height=180;p.background="000000";return p}
    func render(_ p:Project,_ t:Double=0.5,directory:URL=FileManager.default.temporaryDirectory)throws->CGContext {
        let c=try XCTUnwrap(RasterTools.bitmap(CGSize(width:p.width,height:p.height)))
        FrameRenderer().draw(project:p,directory:directory,time:t,context:c,size:CGSize(width:p.width,height:p.height));return c
    }
    func pixels(_ c:CGContext)throws->[UInt8] {Array(UnsafeBufferPointer(start:try XCTUnwrap(c.data).assumingMemoryBound(to:UInt8.self),count:c.height*c.bytesPerRow))}
    func pixel(_ c:CGContext,_ x:Int=160,_ y:Int=90)throws->[Int] {
        let d=try pixels(c),i=y*c.bytesPerRow+x*4;return (0..<4).map{Int(d[i+$0])}
    }
    func folder()throws->URL {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-advanced-\(UUID())")
        try FileManager.default.createDirectory(at:url.appendingPathComponent("Media"),withIntermediateDirectories:true);return url
    }
    func shape(_ color:String,track:Int=0)->Clip {var c=Clip(kind:.shape,name:color,track:track,start:0,duration:3);c.color=color;return c}
    func testNestedParentsMoveChildrenAsOneCompositeAndGateTime()throws {
        var p=project(),child=shape("FF0000");child.scale=0.25
        var group=Clip(kind:.group,name:"親",track:1,start:0,duration:3);group.x=0.7;group.opacity=0.5
        var ancestor=Clip(kind:.group,name:"祖先",track:2,start:0,duration:1);ancestor.y=0.7
        child.parentID=group.id;group.parentID=ancestor.id;p.clips=[child,group,ancestor]
        let c=try render(p)
        XCTAssertEqual(try pixel(c,160,90)[0],0)
        XCTAssertEqual(try pixel(c,224,126)[0],128,accuracy:2)
        XCTAssertEqual(try pixel(render(p,1.5),224,126)[0],0)
        p.clips[0].parentID=ancestor.id;p.clips[1].parentID=child.id;p.clips[2].parentID=group.id
        XCTAssertThrowsError(try p.validated())
    }
    @MainActor func testGroupEditingMoveDuplicateUndoAndParentDeletionProtection()throws {
        let store=EditorStore();defer{try? FileManager.default.removeItem(at:store.directory)}
        var a=shape("FF0000"),b=shape("00FF00");b.start=1;b.duration=2
        a.duration=1;store.project.clips=[a,b];store.selectedTrack=0;store.groupSelectedLayer()
        let group=try XCTUnwrap(store.selected)
        XCTAssertEqual(store.project.clips.filter{$0.parentID==group.id}.count,2)
        store.edit(group.id){$0.start=2}
        XCTAssertEqual(store.project.clips[0].start,2);XCTAssertEqual(store.project.clips[1].start,3)
        store.duplicateSelected();XCTAssertEqual(store.project.clips.count,6)
        let duplicate=try XCTUnwrap(store.selected);XCTAssertEqual(store.project.clips.filter{$0.parentID==duplicate.id}.count,2)
        _=try store.project.validated();store.undo();XCTAssertEqual(store.project.clips.count,3)
        store.selectedID=group.id;store.deleteSelected();XCTAssertEqual(store.project.clips.count,3)
        store.setParent(a.id,clipID:group.id);XCTAssertNotNil(store.error)
    }
    func testMasksIntersectionInvertFeatherAndPolygon()throws {
        var p=project(),c=shape("FFFFFF");c.scale=4
        var mask=ClipMask();mask.width=0.05;mask.height=0.05;c.masks=[mask];p.clips=[c]
        XCTAssertEqual(try pixel(render(p)),[255,255,255,255]);XCTAssertEqual(try pixel(render(p),10,90),[0,0,0,255])
        p.clips[0].masks?[0].inverted=true
        XCTAssertEqual(try pixel(render(p)),[0,0,0,255]);XCTAssertEqual(try pixel(render(p),10,90),[255,255,255,255])
        // Mask is in the local canvas before the item's 400% scale: its right edge is x=320.
        p.clips[0].scale=1;p.clips[0].masks?[0].width=0.25;p.clips[0].masks?[0].height=0.25;p.clips[0].masks?[0].inverted=false;p.clips[0].masks?[0].feather=8
        let edge=try pixel(render(p),200,90)[0];XCTAssertGreaterThan(edge,10);XCTAssertLessThan(edge,240)
        mask.kind = .polygon;mask.width=1;mask.height=1;mask.points=[NormalizedPoint(x:0,y:0),NormalizedPoint(x:1,y:0),NormalizedPoint(x:0,y:1)]
        p.clips[0].masks=[mask];p.clips[0].scale=4
        XCTAssertEqual(try pixel(render(p),60,60)[0],255);XCTAssertEqual(try pixel(render(p),260,120)[0],0)
        var second=mask;second.id=UUID();second.kind = .rectangle;second.width=0.1;second.height=0.1
        p.clips[0].masks?.append(second)
        XCTAssertEqual(try pixel(render(p),20,20)[0],0)
    }
    func testBlendModesLayerEffectsAndTimedAdjustment()throws {
        var p=project(),a=shape("FF0000"),b=shape("0000FF",track:1);a.scale=4;b.scale=4;b.blendMode = .screen;p.clips=[a,b]
        XCTAssertEqual(try pixel(render(p)),[255,0,255,255])
        b.blendMode = .multiply;p.clips=[a,b]
        // Blend is applied against lower layers, not an isolated transparent layer.
        XCTAssertEqual(try pixel(render(p)),[0,0,0,255])
        b.blendMode=nil;p.clips=[a,b];var gray=VisualEffect(kind:.saturation);gray.amount=0;p.tracks[1].effects=[gray]
        let mono=try pixel(render(p));XCTAssertEqual(mono[0],mono[1],accuracy:2);XCTAssertEqual(mono[1],mono[2],accuracy:2)
        var adjustment=Clip(kind:.adjustment,name:"調整",track:2,start:1,duration:1);adjustment.effects=[VisualEffect(kind:.invert)];p.tracks[1].effects=nil;p.clips=[a,b,adjustment]
        XCTAssertEqual(try pixel(render(p,0.5)),[0,0,255,255]);XCTAssertEqual(try pixel(render(p,1.5)),[255,255,0,255]);XCTAssertEqual(try pixel(render(p,2.5)),[0,0,255,255])
        let top=shape("00FF00",track:3);p.clips.append(top)
        XCTAssertEqual(try pixel(render(p,1.5)),[0,255,0,255])
    }
    func testParticleSeekIsDeterministicAndGeometryChangesPixels()throws {
        var p=project(),c=Clip(kind:.particles,name:"粒子",track:0,start:0,duration:4)
        c.particles=ParticleSettings(count:80,burst:true,shape:.star);c.color="FFFF00";p.clips=[c]
        let first=try pixels(render(p,0.5)),second=try pixels(render(p,1)),seek=try pixels(render(p,0.5))
        XCTAssertEqual(first,seek);XCTAssertNotEqual(first,second);XCTAssertGreaterThan(first.filter{$0>20}.count,p.width*p.height)
        c=shape("FFFFFF");c.scale=0.5;p.clips=[c]
        let plain=try pixels(render(p));p.clips[0].transform=Transform2D(scaleX:0.5,scaleY:2,skewX:30)
        XCTAssertNotEqual(try pixels(render(p)),plain)
        p.clips[0].animation=ClipAnimation(tracks:[AnimationTrack(property:.skewX,keys:[AnimationKeyframe(time:0,value:0,easing:.linear),AnimationKeyframe(time:2,value:60)])])
        XCTAssertNotEqual(try pixels(render(p,0)),try pixels(render(p,1)))
    }
    func tone(at url:URL,duration:Double=4)throws {
        let format=AVAudioFormat(standardFormatWithSampleRate:48000,channels:2)!,n=Int(duration*48000)
        let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(n))!;buffer.frameLength=AVAudioFrameCount(n)
        for i in 0..<n {let v=Float(sin(Double(i)*2*Double.pi*1000/48000)*0.2);for channel in 0..<2 {buffer.floatChannelData![channel][i]=v}}
        var file:AVAudioFile?=try AVAudioFile(forWriting:url,settings:format.settings);try file?.write(from:buffer);file=nil
    }
    func energy(_ url:URL,frequency:Double)throws->Double {
        let file=try AVAudioFile(forReading:url);let n=24000;file.framePosition=min(file.length/3,max(0,file.length-Int64(n)))
        let b=AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:AVAudioFrameCount(n))!;try file.read(into:b)
        var real=0.0,imaginary=0.0
        for i in 0..<Int(b.frameLength) {let phase=Double(i)*2*Double.pi*frequency/file.processingFormat.sampleRate,v=Double(b.floatChannelData![0][i]);real+=v*cos(phase);imaginary+=v*sin(phase)}
        return hypot(real,imaginary)/Double(b.frameLength)
    }
    func testActualAudioRatePitchAndEqualizerProcessing()async throws {
        let root=try folder();defer{try? FileManager.default.removeItem(at:root)}
        let source=root.appendingPathComponent("tone.wav");try tone(at:source)
        let decoded=root.appendingPathComponent("decode.caf");let exists=try await AudioProcessor.decode(source:source,destination:decoded);XCTAssertTrue(exists)
        var clip=Clip(kind:.audio,name:"EQ",track:0,start:0,duration:2);clip.playbackRate=2
        let output=root.appendingPathComponent("rate.caf")
        let duration=try AudioProcessor.process(decoded:decoded,clip:clip,destination:output);XCTAssertEqual(duration,2,accuracy:0.01)
        let retained=try energy(output,frequency:1000);XCTAssertGreaterThan(retained,0.04)
        clip.preservePitch=false
        let shifted=root.appendingPathComponent("shift.caf");_=try AudioProcessor.process(decoded:decoded,clip:clip,destination:shifted)
        XCTAssertGreaterThan(try energy(shifted,frequency:2000),0.04);XCTAssertLessThan(try energy(shifted,frequency:1000),0.005)
        clip.playbackRate=1;clip.preservePitch=true;clip.equalizer=Equalizer();clip.equalizer?.bands[2].gain = -24
        let eq=root.appendingPathComponent("eq.caf");_=try AudioProcessor.process(decoded:decoded,clip:clip,destination:eq)
        XCTAssertLessThan(try energy(eq,frequency:1000),retained*0.2)
    }
    @MainActor func testSpeedAwareTrimSplitAndMouthSampling()throws {
        let s=EditorStore();defer{try? FileManager.default.removeItem(at:s.directory)}
        var c=Clip(kind:.speech,name:"速度",track:0,start:2,duration:2);c.playbackRate=2;c.sourceOffset=1
        let asset=MediaAsset(name:"声",file:"voice.wav",kind:.audio,duration:8,envelope:[0,0]+Array(repeating:0.1,count:300));c.assetID=asset.id
        s.project.assets=[asset];s.project.clips=[c];s.selectedID=c.id;s.playhead=3;s.snapping=false
        s.splitSelected();XCTAssertEqual(s.project.clips[1].sourceOffset,3)
        let trim=s.timelineChange(c,delta:0.5,track:0,edge:-1);XCTAssertEqual(trim.sourceOffset,2)
        s.undo();s.setMediaRate(1,clipID:c.id);XCTAssertEqual(s.project.clips[0].duration,4)
        var character=shape("FFFFFF");character.characterSpeakerID=0;s.project.clips.append(character)
        XCTAssertTrue(s.project.mouthIsOpen(for:character,at:2.1))
        _=try s.project.validated()
    }
    func testImageAlphaMaskPerspectiveAndFormatProbe()async throws {
        let root=try folder();defer{try? FileManager.default.removeItem(at:root)}
        let image=try XCTUnwrap(RasterTools.bitmap(CGSize(width:320,height:180)))
        image.setFillColor(NSColor.white.cgColor);image.fill(CGRect(x:0,y:0,width:160,height:180))
        let png=root.appendingPathComponent("Media/mask.png")
        try XCTUnwrap(NSBitmapImageRep(cgImage:try XCTUnwrap(image.makeImage())).representation(using:.png,properties:[:])).write(to:png)
        let probe=try await MediaProbe.inspect(png);XCTAssertEqual(probe.kind,.image)
        var p=project(),c=shape("FF0000");c.scale=4
        let asset=MediaAsset(name:"mask",file:"mask.png",kind:.image,duration:5);p.assets=[asset]
        c.masks=[ClipMask(kind:.image,width:1,height:1,assetID:asset.id)];p.clips=[c]
        XCTAssertEqual(try pixel(render(p,directory:root),30,90)[0],255);XCTAssertEqual(try pixel(render(p,directory:root),290,90)[0],0)
        c.masks=nil;c.scale=1;c.transform=Transform2D(perspective:true,corners:[NormalizedPoint(x:0.2,y:0),NormalizedPoint(x:0.8,y:0),NormalizedPoint(x:1,y:1),NormalizedPoint(x:0,y:1)]);p.clips=[c]
        XCTAssertNotEqual(try pixels(render(p,directory:root)),try pixels(render({var q=p;q.clips[0].transform=nil;return q}(),directory:root)))
        XCTAssertEqual(try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(p)).validated(),p)
    }
    func moviePixel(_ generator:AVAssetImageGenerator,_ time:Double)throws->[Int] {
        let image=try generator.copyCGImage(at:CMTime(seconds:time,preferredTimescale:600),actualTime:nil)
        let c=try XCTUnwrap(RasterTools.bitmap(CGSize(width:320,height:180)));c.draw(image,in:CGRect(x:0,y:0,width:320,height:180));return try pixel(c,224,90)
    }
    func testAdvancedMP4MatchesPreviewAndProcessedAudio()async throws {
        let root=try folder();defer{try? FileManager.default.removeItem(at:root)}
        let wav=root.appendingPathComponent("Media/tone.wav");try tone(at:wav)
        var p=project(),group=Clip(kind:.group,name:"グループ",track:2,start:0,duration:3)
        group.x=0.7;group.opacity=0.7;group.volume=2;group.masks=[ClipMask(kind:.ellipse,width:0.8,height:0.8)]
        group.animation=ClipAnimation(tracks:[AnimationTrack(property:.rotation,keys:[AnimationKeyframe(time:0,value:0,easing:.linear),AnimationKeyframe(time:3,value:45)])])
        var child=shape("FF6600");child.scale=0.6;child.parentID=group.id
        var gray=VisualEffect(kind:.saturation);gray.amount=0;child.effects=[gray]
        let asset=MediaAsset(name:"tone",file:"tone.wav",kind:.audio,duration:4);p.assets=[asset]
        var audio=Clip(kind:.audio,name:"加工音声",track:0,start:0.5,duration:2)
        audio.assetID=asset.id;audio.parentID=group.id;audio.playbackRate=2;audio.equalizer=Equalizer();audio.equalizer?.bands[2].gain = -24
        audio.audioFade=AudioFade(fadeIn:0.1,fadeOut:0.2)
        var particle=Clip(kind:.particles,name:"紙吹雪",track:3,start:0,duration:3);particle.x=0.1;particle.y=0.1;particle.color="FFFF00";particle.particles=ParticleSettings(count:40,velocity:0.05,gravity:0,burst:true,shape:.square)
        p.clips=[child,group,audio,particle]
        let output=root.appendingPathComponent("advanced.mp4");try await MovieExporter.export(project:p,directory:root,destination:output){_ in}
        let generator=AVAssetImageGenerator(asset:AVURLAsset(url:output));generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
        for time in [0.5,1.5,2.5] {
            let actual=try moviePixel(generator,time),expected=try pixel(render(p,time,directory:root),224,90)
            for channel in 0..<3 {XCTAssertEqual(actual[channel],expected[channel],accuracy:12)}
        }
        let decoded=root.appendingPathComponent("muxed.caf");let hasAudio=try await AudioProcessor.decode(source:output,destination:decoded);XCTAssertTrue(hasAudio)
        XCTAssertLessThan(try energy(decoded,frequency:1000),0.02)
        XCTAssertGreaterThan(try energy(decoded,frequency:1000),0.009)
        if let path=testArtifactDirectory() {
            let destination=URL(fileURLWithPath:path);try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
            try FileManager.default.copyItem(at:output,to:destination.appendingPathComponent("advanced-features.mp4"))
            let package=destination.appendingPathComponent("Advanced-Demo.vmm");try FileManager.default.createDirectory(at:package,withIntermediateDirectories:true)
            try FileManager.default.copyItem(at:root.appendingPathComponent("Media"),to:package.appendingPathComponent("Media"))
            try JSONEncoder().encode(p).write(to:package.appendingPathComponent("project.json"))
            let image=try XCTUnwrap(try render(p,1.5,directory:root).makeImage())
            try XCTUnwrap(NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])).write(to:destination.appendingPathComponent("advanced-features.png"))
        }
    }
    func testVideoSpeedUsesCorrectSourceFramesAndCommonMediaFormats()async throws {
        let root=try folder();defer{try? FileManager.default.removeItem(at:root)}
        var source=project();source.clips=[]
        for (i,color) in ["FF0000","0000FF","00FF00"].enumerated() {var c=shape(color);c.start=Double(i);c.duration=1;c.scale=4;source.clips.append(c)}
        let sourceURL=root.appendingPathComponent("Media/source.mp4");try await MovieExporter.export(project:source,directory:root,destination:sourceURL){_ in}
        let probe=try await MediaProbe.inspect(sourceURL);XCTAssertEqual(probe.kind,.video);XCTAssertEqual(probe.duration,3,accuracy:0.05)
        var p=project();let asset=MediaAsset(name:"元動画",file:"source.mp4",kind:.video,duration:3);p.assets=[asset]
        var video=Clip(kind:.video,name:"倍速",track:0,start:0,duration:1.5);video.assetID=asset.id;video.playbackRate=2;p.clips=[video]
        let output=root.appendingPathComponent("speed.mp4");try await MovieExporter.export(project:p,directory:root,destination:output){_ in}
        let generator=AVAssetImageGenerator(asset:AVURLAsset(url:output));generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
        for (time,color) in [(0.25,[255,0,0]),(0.75,[0,0,255]),(1.25,[0,255,0])] {
            let actual=try moviePixel(generator,time);for c in 0..<3 {XCTAssertEqual(actual[c],color[c],accuracy:12)}
        }
        let image=try XCTUnwrap(RasterTools.bitmap(CGSize(width:64,height:64)));image.setFillColor(NSColor.red.cgColor);image.fill(CGRect(x:0,y:0,width:64,height:64))
        let rep=NSBitmapImageRep(cgImage:try XCTUnwrap(image.makeImage()))
        for (ext,type) in [("png",NSBitmapImageRep.FileType.png),("jpg",.jpeg),("tiff",.tiff),("bmp",.bmp),("gif",.gif)] {
            let url=root.appendingPathComponent("image.\(ext)");try XCTUnwrap(rep.representation(using:type,properties:[:])).write(to:url)
            let result=try await MediaProbe.inspect(url);XCTAssertEqual(result.kind,.image,ext)
        }
        let wave=root.appendingPathComponent("tone.wav");try tone(at:wave,duration:1)
        let sound=try await MediaProbe.inspect(wave);XCTAssertEqual(sound.kind,.audio)
        let broken=root.appendingPathComponent("broken.mp4");try Data("not a video".utf8).write(to:broken)
        do {_=try await MediaProbe.inspect(broken);XCTFail("Corrupt video accepted")} catch { }
    }

    func testPartialAdjustmentShapesAnimationAndLegacyProject() throws {
        var p=project(),base=shape("FF0000");base.scale=4
        var a=Clip(kind:.adjustment,name:"部分加工",track:1,start:0,duration:3)
        a.effects=[VisualEffect(kind:.invert)];a.adjustmentRegion=AdjustmentRegion(width:0.5,height:0.5)
        p.clips=[base,a]
        XCTAssertEqual(try pixel(render(p),160,90),[0,255,255,255])
        XCTAssertEqual(try pixel(render(p),10,90),[255,0,0,255])
        XCTAssertEqual(try pixel(render(p),90,50),[0,255,255,255])
        p.clips[1].adjustmentRegion?.shape = .ellipse
        XCTAssertEqual(try pixel(render(p),90,50),[255,0,0,255])
        p.clips[1].adjustmentRegion?.shape = .roundedRectangle
        XCTAssertEqual(try pixel(render(p),81,46),[255,0,0,255])
        p.clips[1].adjustmentRegion?.shape = .rectangle
        p.clips[1].animation=ClipAnimation(tracks:[AnimationTrack(property:.x,keys:[AnimationKeyframe(time:0,value:0.25,easing:.linear),AnimationKeyframe(time:2,value:0.75)]),AnimationTrack(property:.regionWidth,keys:[AnimationKeyframe(time:0,value:0.1,easing:.linear),AnimationKeyframe(time:2,value:0.2)])])
        XCTAssertEqual(try pixel(render(p,0),80,90),[0,255,255,255])
        XCTAssertEqual(try pixel(render(p,2),80,90),[255,0,0,255])
        XCTAssertEqual(try pixel(render(p,2),240,90),[0,255,255,255])
        _=try p.validated()
        let saved=try JSONEncoder().encode(p),restored=try JSONDecoder().decode(Project.self,from:saved)
        XCTAssertEqual(try pixels(render(p,2)),try pixels(render(restored,2)))
        p.clips[1].animation=nil;p.clips[1].adjustmentRegion=nil
        let legacy=try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(p))
        XCTAssertNil(legacy.clips[1].adjustmentRegion)
        XCTAssertEqual(try pixel(render(legacy),10,90),[0,255,255,255])
        p.clips[1].adjustmentRegion=AdjustmentRegion(width:.nan)
        XCTAssertThrowsError(try p.validated())
    }
    func testPartialMosaicPreservesOutsidePixelsAndExports() async throws {
        let root=try folder();defer{try? FileManager.default.removeItem(at:root)}
        let image=try XCTUnwrap(RasterTools.bitmap(CGSize(width:320,height:180)))
        for x in 0..<80 {image.setFillColor((x%2 == 0 ? NSColor.red:NSColor.blue).cgColor);image.fill(CGRect(x:x*4,y:0,width:4,height:180))}
        let rep=NSBitmapImageRep(cgImage:try XCTUnwrap(image.makeImage()))
        try XCTUnwrap(rep.representation(using:.png,properties:[:])).write(to:root.appendingPathComponent("Media/stripes.png"))
        var p=project();let asset=MediaAsset(name:"stripes",file:"stripes.png",kind:.image,duration:1);p.assets=[asset]
        var base=Clip(kind:.image,name:"背景",track:0,start:0,duration:1);base.assetID=asset.id
        p.clips=[base];let before=try render(p,directory:root)
        var a=Clip(kind:.adjustment,name:"部分モザイク",track:1,start:0,duration:1);var mosaic=VisualEffect(kind:.pixelate);mosaic.amount=24;a.effects=[mosaic];a.adjustmentRegion=AdjustmentRegion(width:0.5,height:0.5);p.clips.append(a)
        if let artifacts=testArtifactDirectory() {
            let destination=URL(fileURLWithPath:artifacts).appendingPathComponent("Partial-Mosaic.vmm")
            try FileManager.default.createDirectory(at:destination.appendingPathComponent("Media"),withIntermediateDirectories:true)
            try FileManager.default.copyItem(at:root.appendingPathComponent("Media/stripes.png"),to:destination.appendingPathComponent("Media/stripes.png"))
            try JSONEncoder().encode(p).write(to:destination.appendingPathComponent("project.json"))
        }
        let after=try render(p,directory:root)
        XCTAssertEqual(try pixel(before,24,90),try pixel(after,24,90))
        XCTAssertNotEqual(try pixel(before,160,90),try pixel(after,160,90))
        let output=root.appendingPathComponent("region.mp4");try await MovieExporter.export(project:p,directory:root,destination:output){_ in}
        let generator=AVAssetImageGenerator(asset:AVURLAsset(url:output));generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
        let actual=try moviePixel(generator,0.5),expected=try pixel(after,224,90)
        for ch in 0..<3 {XCTAssertEqual(actual[ch],expected[ch],accuracy:18)}
    }

    func testFrameDrawingUsesViewSizeForNonBitmapContexts() throws {
        var p=project(),base=shape("FF0000");base.scale=4;p.clips=[base]
        let data=NSMutableData(),consumer=try XCTUnwrap(CGDataConsumer(data:data))
        var page=CGRect(x:0,y:0,width:320,height:180)
        let context=try XCTUnwrap(CGContext(consumer:consumer,mediaBox:&page,nil))
        XCTAssertEqual(context.width,0)
        context.beginPDFPage(nil)
        FrameRenderer().draw(project:p,directory:FileManager.default.temporaryDirectory,time:0.5,context:context,size:page.size)
        context.endPDFPage();context.closePDF()
        let document=try XCTUnwrap(CGPDFDocument(CGDataProvider(data:data)!)),pdfPage=try XCTUnwrap(document.page(at:1))
        let raster=try XCTUnwrap(RasterTools.bitmap(page.size));raster.drawPDFPage(pdfPage)
        XCTAssertEqual(try pixel(raster),[255,0,0,255])
    }

}
