import XCTest
import AVFoundation
@testable import VMM

final class AudioDeliveryTests:XCTestCase {
    func fixture(_ folder:URL)throws->Project {
        try FileManager.default.createDirectory(at:folder.appendingPathComponent("Media"),withIntermediateDirectories:true)
        try AdvancedTests().tone(at:folder.appendingPathComponent("Media/tone.wav"),duration:3)
        var p=Project();p.width=320;p.height=180;let asset=MediaAsset(name:"tone",file:"tone.wav",kind:.audio,duration:3)
        var c=Clip(kind:.audio,name:"sound",track:0,start:0.25,duration:1);c.assetID=asset.id;c.sourceOffset=0.1;c.volume=0.5;c.audioFade=AudioFade(fadeIn:0.2,fadeOut:0.2,curve:.equalPower)
        p.assets=[asset];p.clips=[c,Clip(kind:.text,name:"caption",track:1,start:0,duration:2,text:"音声出力")];return p
    }
    func testWAVExactBoundsSilenceFadesAndOverwriteProtection()async throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-audio-delivery-\(UUID())");defer{try? FileManager.default.removeItem(at:dir)}
        let p=try fixture(dir),url=dir.appendingPathComponent("mix.wav")
        try await AudioOnlyExporter.export(project:p,directory:dir,destination:url){_ in}
        let file=try AVAudioFile(forReading:url);XCTAssertEqual(file.length,96000);XCTAssertEqual(file.processingFormat.sampleRate,48000);XCTAssertEqual(file.processingFormat.channelCount,2)
        let buffer=AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:AVAudioFrameCount(file.length))!;try file.read(into:buffer)
        let data=buffer.floatChannelData![0];XCTAssertLessThan((0..<12000).map{abs(data[$0])}.max()!,1e-5);XCTAssertLessThan((60000..<96000).map{abs(data[$0])}.max()!,1e-5)
        XCTAssertGreaterThan((24000..<48000).map{abs(data[$0])}.max()!,0.01)
        let bytes=try Data(contentsOf:url);do{try await AudioOnlyExporter.export(project:p,directory:dir,destination:url){_ in};XCTFail("overwrite must reject")}catch{}
        XCTAssertEqual(try Data(contentsOf:url),bytes)
        var options=UserSettings();options.rangeStart=0.333;options.rangeEnd=0.777
        let range=dir.appendingPathComponent("range.wav");try await AudioOnlyExporter.export(project:p,directory:dir,destination:range,options:options){_ in}
        XCTAssertEqual(try AVAudioFile(forReading:range).length,21312)
    }
    func testProResMovieKeepsNativeCodecAndPCM()async throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-prores-\(UUID())");defer{try? FileManager.default.removeItem(at:dir)}
        let p=try fixture(dir);var options=UserSettings();options.exportCodec="ProRes 422";options.exportContainer="MOV";options.rangeEnd=0.5
        let url=dir.appendingPathComponent("render.mov");try await MovieExporter.export(project:p,directory:dir,destination:url,options:options){_ in}
        let asset=AVURLAsset(url:url),v=try await asset.loadTracks(withMediaType:.video),a=try await asset.loadTracks(withMediaType:.audio)
        let vf=try await v[0].load(.formatDescriptions),af=try await a[0].load(.formatDescriptions)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(vf[0]),kCMVideoCodecType_AppleProRes422);XCTAssertEqual(CMFormatDescriptionGetMediaSubType(af[0]),kAudioFormatLinearPCM)
        XCTAssertEqual(CMAudioFormatDescriptionGetStreamBasicDescription(af[0])?.pointee.mBitsPerChannel,24)
        let generator=AVAssetImageGenerator(asset:asset);XCTAssertEqual(try generator.copyCGImage(at:.zero,actualTime:nil).width,320)
    }
    func testWAVAndProResShareTheSameMixAndPreview()async throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-mix-consistency-\(UUID())");defer{try? FileManager.default.removeItem(at:dir)}
        let p=try fixture(dir);var options=UserSettings();options.exportCodec="ProRes 422";options.exportContainer="MOV";options.rangeStart=0.3;options.rangeEnd=0.9
        let movie=dir.appendingPathComponent("mixed.mov"),wave=dir.appendingPathComponent("mixed.wav"),decoded=dir.appendingPathComponent("decoded.caf")
        try await MovieExporter.export(project:p,directory:dir,destination:movie,options:options){_ in}
        try await AudioOnlyExporter.export(project:p,directory:dir,destination:wave,options:options){_ in}
        let decodedOK=try await AudioProcessor.decode(source:movie,destination:decoded);XCTAssertTrue(decodedOK)
        func samples(_ url:URL)throws->[Float] {let file=try AVAudioFile(forReading:url),buffer=AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:AVAudioFrameCount(file.length))!;try file.read(into:buffer);return Array(UnsafeBufferPointer(start:buffer.floatChannelData![0],count:Int(buffer.frameLength)))}
        let a=try samples(wave),b=try samples(decoded);XCTAssertEqual(a.count,b.count)
        XCTAssertLessThan(zip(a,b).map{abs($0-$1)}.max() ?? 1,0.00001)
        let context=try XCTUnwrap(RasterTools.bitmap(CGSize(width:p.width,height:p.height)))
        FrameRenderer().draw(project:p,directory:dir,time:0.3,context:context,size:CGSize(width:p.width,height:p.height))
        let frame=try AVAssetImageGenerator(asset:AVURLAsset(url:movie)).copyCGImage(at:.zero,actualTime:nil),raster=try XCTUnwrap(RasterTools.bitmap(CGSize(width:p.width,height:p.height)))
        raster.draw(frame,in:CGRect(x:0,y:0,width:p.width,height:p.height))
        let preview=UnsafeBufferPointer(start:context.data!.assumingMemoryBound(to:UInt8.self),count:context.bytesPerRow*context.height),output=UnsafeBufferPointer(start:raster.data!.assumingMemoryBound(to:UInt8.self),count:raster.bytesPerRow*raster.height)
        XCTAssertLessThan(zip(preview,output).reduce(0.0){$0+Double(abs(Int($1.0)-Int($1.1)))}/Double(preview.count),10)
    }
    @MainActor func testCrossfadeEqualPowerOldModelAndUndo()throws {
        let prefs=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-crossfade-\(UUID())"),store=EditorStore(preferencesDirectory:prefs)
        defer{try? FileManager.default.removeItem(at:store.directory);try? FileManager.default.removeItem(at:prefs)}
        var p=Project();let a=Clip(kind:.audio,name:"a",track:0,start:0,duration:2),b=Clip(kind:.audio,name:"b",track:1,start:1,duration:2)
        p.clips=[a,b];store.project=p;store.selectedIDs=[a.id,b.id];try store.crossfadeSelection()
        let gains=store.project.clips.map{$0.audioVolume(at:1.5)};XCTAssertEqual(gains[0]*gains[0]+gains[1]*gains[1],1,accuracy:1e-12)
        store.undo();XCTAssertEqual(store.project,p)
        let old=try JSONDecoder().decode(AudioFade.self,from:Data("{\"fadeIn\":1,\"fadeOut\":0}".utf8));XCTAssertEqual(old.gain(0.5),0.5)
    }
}
