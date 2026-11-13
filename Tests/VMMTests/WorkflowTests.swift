import XCTest
import AppKit
import AVFoundation
@testable import VMM

final class WorkflowTests:XCTestCase {
    func render(_ p:Project,renderer:FrameRenderer=FrameRenderer(),time:Double=0)throws->[UInt8] {
        let c=try XCTUnwrap(RasterTools.bitmap(CGSize(width:p.width,height:p.height)))
        renderer.draw(project:p,directory:FileManager.default.temporaryDirectory,time:time,context:c,size:CGSize(width:p.width,height:p.height))
        return Array(UnsafeBufferPointer(start:try XCTUnwrap(c.data).assumingMemoryBound(to:UInt8.self),count:c.height*c.bytesPerRow))
    }
    func testFontTrackingRevealAndLegacyRoundTrip()throws {
        var p=Project();p.width=640;p.height=360;p.background="000000"
        var c=Clip(kind:.text,name:"文字",track:0,start:0,duration:4);c.text="ABC abc 123";c.fontSize=48;c.textStyle=TextStyle();c.textStyle?.fontName="Menlo-Regular"
        p.clips=[c];let renderer=FrameRenderer(),a=try render(p,renderer:renderer)
        p.clips[0].textStyle?.fontName="Helvetica-Bold";let b=try render(p,renderer:renderer);XCTAssertNotEqual(a,b)
        p.clips[0].textStyle?.tracking=0.3;XCTAssertNotEqual(b,try render(p,renderer:renderer))
        p.clips[0].textRevealRate=2
        let empty=try render(p,time:0),partial=try render(p,time:1),full=try render(p,time:3)
        XCTAssertNotEqual(empty,partial);XCTAssertNotEqual(partial,full)
        let saved=try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(p));XCTAssertEqual(saved,p)
        p.clips[0].textRevealRate=nil;p.clips[0].textStyle=nil;_=try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(p)).validated()
    }
    @MainActor func testScriptParsingCharacterAssignmentAndReading()throws {
        let lines=ScriptParser.parse("# comment\r\nずんだもん：こんにちは\r\n\r\n解説:APIを使う\n続き")
        XCTAssertEqual(lines.count,3);XCTAssertEqual(lines[0].speaker,"ずんだもん");XCTAssertEqual(lines[2].speaker,"")
        let store=EditorStore();store.autoSpeech=false;store.project.clips=[];defer{try? FileManager.default.removeItem(at:store.directory)}
        store.catalog.characters=[CharacterPreset(name:"ずんだもん",speakerID:3,color:"22CC55")]
        try store.importScript("ずんだもん：こんにちは\n解説：APIを使う",at:0,track:1)
        XCTAssertEqual(store.project.clips.count,2);XCTAssertEqual(store.project.clips[0].speakerID,3);XCTAssertEqual(store.project.clips[0].color,"22CC55")
        XCTAssertGreaterThan(store.project.clips[1].start,store.project.clips[0].end)
        XCTAssertEqual(store.project.clips[0].scriptSequenceID,store.project.clips[1].scriptSequenceID)
        var c=store.project.clips[1];var fallback=store.project;fallback.pronunciations=nil;XCTAssertEqual(fallback.spokenText(for:c,entries:[PronunciationEntry(word:"API",reading:"エーピーアイ")]),"エーピーアイを使う")
        c.reading="よみ";XCTAssertEqual(store.project.spokenText(for:c),"よみ")
        store.undo();XCTAssertTrue(store.project.clips.isEmpty)
    }
    @MainActor func testAutosaveRotationAndPackageContainsMedia()throws {
        let store=EditorStore();store.autoSpeech=false;store.settings.recoveryCount=2
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:store.directory);try? FileManager.default.removeItem(at:folder)}
        try Data("fixture".utf8).write(to:store.directory.appendingPathComponent("Media/file.png"))
        store.project.assets=[MediaAsset(name:"fixture",file:"file.png",kind:.image,duration:1)]
        for _ in 0..<3 {_=try store.autosave(to:folder)}
        let files=try FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil)
        XCTAssertEqual(files.count,2)
        let restored=try JSONDecoder().decode(Project.self,from:Data(contentsOf:files[0].appendingPathComponent("project.json")))
        XCTAssertEqual(restored.assets,store.project.assets)
        XCTAssertEqual(try Data(contentsOf:files[0].appendingPathComponent("Media/file.png")),Data("fixture".utf8))
    }
}

extension WorkflowTests {
    func testRangeHEVCProxyAndDuckingInActualMovie()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-workflow-export-\(UUID())")
        try FileManager.default.createDirectory(at:root.appendingPathComponent("Media"),withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        var source=Project();source.width=320;source.height=180;source.clips=[Clip(kind:.shape,name:"source",track:0,start:0,duration:2,color:"FF0000")]
        let original=root.appendingPathComponent("Media/original.mp4")
        try await MovieExporter.export(project:source,directory:root,destination:original){_ in}
        source.clips[0].color="0000FF"
        let proxy=root.appendingPathComponent("Media/proxy.mp4")
        try await MovieExporter.export(project:source,directory:root,destination:proxy){_ in}
        let media=MediaAsset(name:"original",file:"original.mp4",kind:.video,duration:2,proxyFile:"proxy.mp4")
        var project=source;var clip=Clip(kind:.video,name:"movie",track:0,start:0,duration:2);clip.assetID=media.id;project.assets=[media];project.clips=[clip]
        let c=try XCTUnwrap(RasterTools.bitmap(CGSize(width:320,height:180)))
        FrameRenderer().draw(project:project,directory:root,time:0.5,context:c,size:CGSize(width:320,height:180))
        let pixels=try XCTUnwrap(c.data).assumingMemoryBound(to:UInt8.self),center=90*c.bytesPerRow+160*4
        XCTAssertGreaterThan(pixels[center+2],pixels[center]) // preview uses blue proxy
        var settings=UserSettings();settings.rangeStart=0.5;settings.rangeEnd=1.5;settings.exportCodec="HEVC";settings.exportContainer="MOV";settings.exportQuality=0.5
        let output=root.appendingPathComponent("range.mov")
        try await MovieExporter.export(project:project,directory:root,destination:output,options:settings){_ in}
        let movie=AVURLAsset(url:output),duration=try await movie.load(.duration);XCTAssertEqual(duration.seconds,1,accuracy:0.05)
        let tracks=try await movie.loadTracks(withMediaType:.video);let track=try XCTUnwrap(tracks.first)
        let formats=try await track.load(.formatDescriptions);XCTAssertEqual(CMFormatDescriptionGetMediaSubType(try XCTUnwrap(formats.first)),kCMVideoCodecType_HEVC)
        let generator=AVAssetImageGenerator(asset:movie),frame=try generator.copyCGImage(at:.zero,actualTime:nil)
        let bitmap=NSBitmapImageRep(cgImage:frame),color=try XCTUnwrap(bitmap.colorAt(x:160,y:90)?.usingColorSpace(.sRGB));XCTAssertGreaterThan(color.redComponent,color.blueComponent+0.5) // export uses original red
        let proxyStore=await EditorStore(preferencesDirectory:root.appendingPathComponent("Preferences"))
        let proxyDirectory=await proxyStore.directory
        try FileManager.default.copyItem(at:original,to:proxyDirectory.appendingPathComponent("Media/original.mp4"))
        let proxyProject=project
        await MainActor.run {proxyStore.project=proxyProject;proxyStore.project.assets[0].proxyFile=nil;proxyStore.autoSpeech=false}
        try await proxyStore.makeProxy(media.id)
        let generated=await proxyStore.project.assets[0].proxyFile
        XCTAssertNotNil(generated);let generatedURL=proxyDirectory.appendingPathComponent("Media").appendingPathComponent(try XCTUnwrap(generated))
        let proxyDuration=try await AVURLAsset(url:generatedURL).load(.duration);XCTAssertEqual(proxyDuration.seconds,2,accuracy:0.05)
        try? FileManager.default.removeItem(at:proxyDirectory)
        var audio=Clip(kind:.audio,name:"BGM",track:0,start:0,duration:3);audio.ducking=0.2
        var speech=Clip(kind:.speech,name:"speech",track:1,start:1,duration:1);speech.assetID=media.id
        project.clips=[audio,speech]
        XCTAssertEqual(project.effectiveAudioVolume(audio,at:0.5),1,accuracy:0.001)
        XCTAssertEqual(project.effectiveAudioVolume(audio,at:1.5),0.2,accuracy:0.001)
        XCTAssertGreaterThan(project.effectiveAudioVolume(audio,at:2.1),0.2)
        project.tracks[1].muted=true;XCTAssertEqual(project.effectiveAudioVolume(audio,at:1.5),1,accuracy:0.001)
        project.tracks[1].muted=false
        let format=AVAudioFormat(standardFormatWithSampleRate:24000,channels:1)!,pcm=AVAudioPCMBuffer(pcmFormat:AVAudioFormat(standardFormatWithSampleRate:24000,channels:1)!,frameCapacity:72000)!
        pcm.frameLength=72000
        for i in 0..<72000 {pcm.floatChannelData![0][i]=Float(sin(Double(i)*2*Double.pi*440/24000)*0.3)}
        let tone=root.appendingPathComponent("Media/tone.wav");var file:AVAudioFile?=try AVAudioFile(forWriting:tone,settings:format.settings);try file?.write(from:pcm);file=nil
        for i in 0..<72000 {pcm.floatChannelData![0][i]=0}
        let silent=root.appendingPathComponent("Media/speech.wav");file=try AVAudioFile(forWriting:silent,settings:format.settings);try file?.write(from:pcm);file=nil
        let bgm=MediaAsset(name:"BGM",file:"tone.wav",kind:.audio,duration:3),voice=MediaAsset(name:"voice",file:"speech.wav",kind:.audio,duration:3)
        project.assets=[bgm,voice];project.clips[0].assetID=bgm.id;project.clips[1].assetID=voice.id
        let mixed=root.appendingPathComponent("duck.mp4");try await MovieExporter.export(project:project,directory:root,destination:mixed){_ in}
        let decoded=root.appendingPathComponent("duck.caf");let hasAudio=try await AudioProcessor.decode(source:mixed,destination:decoded);XCTAssertTrue(hasAudio)
        let sound=try AVAudioFile(forReading:decoded),samples=AVAudioPCMBuffer(pcmFormat:sound.processingFormat,frameCapacity:AVAudioFrameCount(sound.length))!;try sound.read(into:samples)
        let rate=sound.processingFormat.sampleRate
        func peak(_ a:Double,_ b:Double)->Float {UnsafeBufferPointer(start:samples.floatChannelData![0].advanced(by:Int(a*rate)),count:Int((b-a)*rate)).map{abs($0)}.max() ?? 0}
        let normal=peak(0.3,0.6),duck=peak(1.3,1.6);XCTAssertGreaterThan(normal,0.2);XCTAssertLessThan(duck,normal*0.35);XCTAssertGreaterThan(peak(2.5,2.8),normal*0.8)

    }
    @MainActor func testMissingMediaRelinkAndSharedTemplateRoundTrip()async throws {
        let store=EditorStore();store.autoSpeech=false;store.project.clips=[]
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-library-test-\(UUID())")
        store.settings.libraryPath=root.path
        defer{try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let image=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:8,pixelsHigh:8,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        let url=root.appendingPathComponent("replacement.png");try image.representation(using:.png,properties:[:])!.write(to:url)
        let asset=MediaAsset(name:"missing",file:"missing.png",kind:.image,duration:5);store.project.assets=[asset]
        XCTAssertEqual(store.missingAssets.count,1);try await store.relink(asset.id,url:url);XCTAssertTrue(store.missingAssets.isEmpty)
        try store.addSharedAsset(asset.id);let saved=try XCTUnwrap(store.sharedAssets().first)
        try store.importShared(saved.0,asset:saved.1);XCTAssertEqual(store.project.assets.count,2)
        try store.saveTemplate(name:"shared");let template=try XCTUnwrap(store.templates().first)
        let before=store.project;store.loadProject(template);XCTAssertNil(store.error);XCTAssertEqual(store.project,before)
        // Importing the same file twice must not break package save/reopen.
        let target=root.appendingPathComponent("copy.vmm");try ProjectPackage.write(store.project,media:store.directory.appendingPathComponent("Media"),to:target)
    }
}

extension WorkflowTests {
    @MainActor func testMultiDuplicatePreservesRelativeTimesParentAndScriptIsolation()throws {
        let store=EditorStore();store.autoSpeech=false;defer{try? FileManager.default.removeItem(at:store.directory)}
        let sequence=UUID();var parent=Clip(kind:.group,name:"parent",track:0,start:1,duration:4),child=Clip(kind:.text,name:"child",track:1,start:2,duration:2)
        parent.scriptSequenceID=sequence;child.scriptSequenceID=sequence;child.parentID=parent.id
        store.project.clips=[child,parent];store.selectedIDs=[child.id,parent.id];store.selectedID=parent.id
        store.duplicateSelection();XCTAssertEqual(store.project.clips.count,4)
        let copies=store.project.clips.filter{store.selection.contains($0.id)},copyParent=try XCTUnwrap(copies.first{$0.kind == .group}),copyChild=try XCTUnwrap(copies.first{$0.kind == .text})
        XCTAssertEqual(copyChild.parentID,copyParent.id);XCTAssertEqual(copyChild.start-copyParent.start,1)
        XCTAssertEqual(copyParent.scriptSequenceID,copyChild.scriptSequenceID);XCTAssertNotEqual(copyParent.scriptSequenceID,sequence)
        store.undo();XCTAssertEqual(store.project.clips.count,2);XCTAssertTrue(store.selection.isEmpty)
        var project=Project();let c=Clip(kind:.speech,name:"reading",track:0,start:0,duration:1,text:"APIAPI")
        project.pronunciations=[PronunciationEntry(word:"API",reading:"エーピーアイ"),PronunciationEntry(word:"エーピーアイ",reading:"別")]
        XCTAssertEqual(project.spokenText(for:c),"エーピーアイエーピーアイ")
    }
}
