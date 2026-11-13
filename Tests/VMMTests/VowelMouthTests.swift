import XCTest
import AVFoundation
import AppKit
@testable import VMM

final class VowelMouthTests:XCTestCase {
    private func query()->[String:Any] {[
        "prePhonemeLength":0.1,"postPhonemeLength":0.1,
        "accent_phrases":[["moras":[["consonant":"k","consonant_length":0.1,"vowel":"a","vowel_length":0.3],["consonant":"s","consonant_length":0.1,"vowel":"i","vowel_length":0.3]],"is_interrogative":false]]
    ]}
    func testVoicevoxQueryTimingAndUnsupportedDurations()throws {
        let timing=try XCTUnwrap(VoicevoxVowelTiming.parse(query(),speed:1))
        XCTAssertTrue(timing.isConsistent(with:1));XCTAssertEqual(timing.vowel(at:0.2),.a);XCTAssertEqual(timing.vowel(at:0.6),.i);XCTAssertNil(timing.vowel(at:0.01))
        XCTAssertNil(VoicevoxVowelTiming.parse(query(),speed:0))
        XCTAssertFalse(timing.isConsistent(with:0.5))
        var invalid=query();invalid["accent_phrases"]=[["moras":[["vowel":"a","vowel_length":0.3]],"is_interrogative":true]]
        XCTAssertNil(VoicevoxVowelTiming.parse(invalid,speed:1))
        let fast=try XCTUnwrap(VoicevoxVowelTiming.parse(query(),speed:2));XCTAssertTrue(fast.isConsistent(with:0.5))
    }
    @MainActor func testGenerationStoresOnlyVoicevoxTimingWhenDurationMatches()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-vowel-speech-\(UUID())"),store=EditorStore(preferencesDirectory:root),helper=SpeechEngineTests()
        defer{store.cancelSpeech();SpeechProtocol.handler=nil;try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        let wav=try helper.wave(),query=try JSONSerialization.data(withJSONObject:query())
        SpeechProtocol.handler={request in request.url!.path=="/audio_query" ? (200,query):(200,wav)}
        store.autoSpeech=false;store.speechService=helper.service()
        var speech=Clip(kind:.speech,name:"line",track:0,start:0,duration:1,text:"声");speech.speechDirty=true;speech.speechConfiguration = .defaults(.voicevox)
        store.project.clips=[speech];store.selectedID=speech.id;store.generateSpeech()
        for _ in 0..<100 where !store.generatingSpeech.isEmpty {try await Task.sleep(nanoseconds:50_000_000)}
        let asset=try XCTUnwrap(store.project.asset(for:try XCTUnwrap(store.selected)));XCTAssertNotNil(asset.vowelTiming)
        let aivis=try await helper.service().synthesizeWithTiming(text:"声",speaker:0,speed:1,configuration:.defaults(.aivisSpeech));XCTAssertNil(aivis.vowelTiming)
        // The mock returns one second even when asked for 2× speed, so timing must be discarded.
        store.edit(speech.id){$0.speed=2};store.generateSpeech()
        for _ in 0..<100 where !store.generatingSpeech.isEmpty {try await Task.sleep(nanoseconds:50_000_000)}
        let mismatch=try XCTUnwrap(store.project.asset(for:try XCTUnwrap(store.selected)));XCTAssertNil(mismatch.vowelTiming)
    }
    func testVisibilityOverridesOnlyMouthAndRespectsBlinkAndFallback()throws {
        var doc=PSDTests().sample()
        doc.layers.append(PSDLayer(id:5,parent:0,name:"*あ",group:false,visible:false,opacity:1,x:0,y:0,width:1,height:1))
        doc.layers.append(PSDLayer(id:6,parent:0,name:"*い",group:false,visible:false,opacity:1,x:0,y:0,width:1,height:1))
        doc.layers += [PSDLayer(id:7,name:"!目",group:true,visible:true,opacity:1,x:0,y:0,width:0,height:0),PSDLayer(id:8,parent:7,name:"*開き目",group:false,visible:true,opacity:1,x:0,y:0,width:1,height:1),PSDLayer(id:9,parent:7,name:"*閉じ目",group:false,visible:false,opacity:1,x:0,y:0,width:1,height:1)]
        var state=PSDState(selected:doc.defaults);state.mouthOpen=1;state.mouthClosed=2;state.mouthAnimation=true;state.vowelAnimation=true;state.vowelLayers=["a":5,"i":6];state.blink=true;state.eyeClosed=9
        state.selectionKeys=[PSDSelectionKeyframe(time:0,name:"manual",selected:doc.selecting(2,enabled:true,in:doc.defaults))]
        let voiced=state.visibility(document:doc,speaking:true,time:2.95,selectionTime:0,mouthCue:ProjectMouthCue(vowel:.a))
        XCTAssertTrue(voiced.contains(5));XCTAssertFalse(voiced.contains(2));XCTAssertTrue(voiced.contains(9))
        let closed=state.visibility(document:doc,speaking:true,time:0,mouthCue:ProjectMouthCue(vowel:nil));XCTAssertTrue(closed.contains(2))
        let missingMapping=state.visibility(document:doc,speaking:true,time:0,mouthCue:ProjectMouthCue(vowel:.u));XCTAssertTrue(missingMapping.contains(1))
        let noTiming=state.visibility(document:doc,speaking:true,time:0);XCTAssertTrue(noTiming.contains(1))
        let legacy=try JSONDecoder().decode(PSDState.self,from:JSONEncoder().encode(PSDState(selected:doc.defaults)))
        XCTAssertNil(legacy.vowelAnimation);XCTAssertNil(legacy.vowelLayers)
    }
    func testProjectCueUsesCharacterOffsetRateAndNonVoicevoxFallback()throws {
        var p=Project(),voice=Clip(kind:.speech,name:"line",track:1,start:2,duration:1)
        voice.speakerID=3;voice.sourceOffset=0.2;voice.playbackRate=2
        let timing=VowelTiming(duration:3,intervals:[VowelInterval(start:0.2,end:0.8,vowel:.a),VowelInterval(start:0.8,end:2.9,vowel:.i)])
        var asset=MediaAsset(name:"voice",file:"voice.wav",kind:.audio,duration:3);asset.envelope=[Double](repeating:0.2,count:90);asset.vowelTiming=timing;voice.assetID=asset.id
        var portrait=Clip(kind:.image,name:"portrait",track:0,start:0,duration:5);portrait.characterSpeakerID=3
        p.assets=[asset];p.clips=[voice,portrait]
        XCTAssertEqual(p.mouthCue(for:portrait,at:2.1)?.vowel,.a);XCTAssertEqual(p.mouthCue(for:portrait,at:2.4)?.vowel,.i)
        var split=voice;split.start=2.4;split.sourceOffset=1.0;split.duration=0.6;p.clips[0]=split
        XCTAssertEqual(p.mouthCue(for:portrait,at:2.4)?.vowel,.i)
        p.assets[0].vowelTiming=nil;XCTAssertNil(p.mouthCue(for:portrait,at:2.4));XCTAssertTrue(p.mouthIsOpen(for:portrait,at:2.4))
        var config=SpeechConfiguration.defaults(.aivisSpeech);config.endpoint="http://localhost:10101";p.clips[0].speechConfiguration=config;portrait.characterSpeechEngine = .aivisSpeech
        XCTAssertTrue(p.mouthIsOpen(for:portrait,at:2.4));XCTAssertNil(p.mouthCue(for:portrait,at:2.4))
        p.assets[0].vowelTiming=VowelTiming(duration:0.1,intervals:[VowelInterval(start:0,end:0.1,vowel:.a)]);XCTAssertThrowsError(try p.validated())
    }
    func testPreviewAndMP4ShowDifferentVowelsWithAudio()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-vowel-render-\(UUID())"),media=root.appendingPathComponent("Media");try FileManager.default.createDirectory(at:media,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        func makeImage(_ color:NSColor,_ name:String)throws {
            let context=try XCTUnwrap(CGContext(data:nil,width:32,height:32,bitsPerComponent:8,bytesPerRow:32*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(color.cgColor);context.fill(CGRect(x:0,y:0,width:32,height:32))
            let bitmap=NSBitmapImageRep(cgImage:try XCTUnwrap(context.makeImage()))
            try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:media.appendingPathComponent(name))
        }
        try makeImage(.red,"a.png");try makeImage(.green,"i.png");try makeImage(.blue,"closed.png")
        let doc=PSDDocument(width:32,height:32,layers:[
            PSDLayer(id:0,name:"!口",group:true,visible:true,opacity:1,x:0,y:0,width:0,height:0),
            PSDLayer(id:1,parent:0,name:"*あ",group:false,visible:true,opacity:1,x:0,y:0,width:32,height:32,file:"a.png"),
            PSDLayer(id:2,parent:0,name:"*い",group:false,visible:false,opacity:1,x:0,y:0,width:32,height:32,file:"i.png"),
            PSDLayer(id:3,parent:0,name:"*閉じ",group:false,visible:false,opacity:1,x:0,y:0,width:32,height:32,file:"closed.png")])
        var image=MediaAsset(name:"portrait",file:"portrait.png",kind:.image,duration:0);image.psd=doc;try makeImage(.red,"portrait.png")
        let wav=try SpeechEngineTests().wave();try wav.write(to:media.appendingPathComponent("voice.wav"))
        var voice=MediaAsset(name:"voice",file:"voice.wav",kind:.audio,duration:1,generatedSpeech:true,envelope:[Double](repeating:0.2,count:30));voice.vowelTiming=VowelTiming(duration:1,intervals:[VowelInterval(start:0.1,end:0.4,vowel:.a),VowelInterval(start:0.5,end:0.8,vowel:.i)])
        var portrait=Clip(kind:.image,name:"portrait",track:0,start:0,duration:1);portrait.assetID=image.id;portrait.characterSpeakerID=0
        var state=PSDState(selected:doc.defaults);state.mouthAnimation=true;state.mouthOpen=1;state.mouthClosed=3;state.vowelAnimation=true;state.vowelLayers=["a":1,"i":2];portrait.psd=state
        var speech=Clip(kind:.speech,name:"voice",track:1,start:0,duration:1,text:"test");speech.assetID=voice.id;speech.speechCaptionHidden=true
        var p=Project();p.width=320;p.height=180;p.assets=[image,voice];p.clips=[portrait,speech];_=try p.validated()
        let renderer=FrameRenderer()
        func pixel(_ time:Double)throws->NSColor {
            let context=try XCTUnwrap(CGContext(data:nil,width:p.width,height:p.height,bitsPerComponent:8,bytesPerRow:p.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            renderer.draw(project:p,directory:root,time:time,context:context,size:CGSize(width:p.width,height:p.height))
            return try XCTUnwrap(NSBitmapImageRep(cgImage:try XCTUnwrap(context.makeImage())).colorAt(x:160,y:90)?.usingColorSpace(.sRGB))
        }
        XCTAssertGreaterThan(try pixel(0.2).redComponent,0.7);XCTAssertGreaterThan(try pixel(0.6).greenComponent,0.7)
        let output=root.appendingPathComponent("vowel.mp4");try await MovieExporter.export(project:p,directory:root,destination:output){_ in}
        let asset=AVURLAsset(url:output),tracks=try await asset.loadTracks(withMediaType:.audio);XCTAssertEqual(tracks.count,1)
        let generator=AVAssetImageGenerator(asset:asset);generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
        func videoPixel(_ time:Double)throws->NSColor {let image=try generator.copyCGImage(at:CMTime(seconds:time,preferredTimescale:600),actualTime:nil);return try XCTUnwrap(NSBitmapImageRep(cgImage:image).colorAt(x:160,y:90)?.usingColorSpace(.sRGB))}
        XCTAssertGreaterThan(try videoPixel(0.2).redComponent,0.6);XCTAssertGreaterThan(try videoPixel(0.6).greenComponent,0.6)
    }
}
