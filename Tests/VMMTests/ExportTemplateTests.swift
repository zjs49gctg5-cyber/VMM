import XCTest
import AVFoundation
import AppKit
@testable import VMM

final class ExportTemplateTests:XCTestCase {
    func testTemplatesRetainRangeAndLegacySettings()throws {
        let youtube:[ExportTemplate:Double]=[.youtube360:1,.youtube360High:1.5,.youtube480:2.5,.youtube480High:4,.youtube720:5,.youtube720High:7.5,.youtube1080:8,.youtube1080High:12,.youtube1440:16,.youtube1440High:24,.youtube4K:40,.youtube4KHigh:60,.youtube8K:120,.youtube8KHigh:180]
        for (template,bitrate) in youtube{XCTAssertEqual(template.videoMbps,bitrate)}
        XCTAssertEqual(ExportTemplate.niconico.videoMbps,12);XCTAssertEqual(ExportTemplate.niconico720.videoMbps,6);XCTAssertEqual(ExportTemplate.niconico480.videoMbps,2)
        var settings=UserSettings();settings.rangeStart=3;settings.rangeEnd=8
        let old=try JSONEncoder().encode(settings)
        XCTAssertNil(try JSONDecoder().decode(UserSettings.self,from:old).exportWidth)
        for preset in ExportTemplate.allCases {
            preset.apply(to:&settings);_ = try settings.validated()
            XCTAssertEqual(settings.exportContainer,"MP4");XCTAssertEqual(settings.exportCodec,"H.264")
            XCTAssertEqual(settings.rangeStart,3);XCTAssertEqual(settings.rangeEnd,8)
            XCTAssertEqual(settings.exportVideoMbps,preset.videoMbps)
        }
        settings.clearExportTemplate();XCTAssertNil(settings.exportFPS);XCTAssertNil(settings.exportAudioKbps)
        settings.exportWidth=1920;XCTAssertThrowsError(try settings.validated())
        settings.exportHeight=1080;settings.exportVideoMbps = .nan;XCTAssertThrowsError(try settings.validated())
        settings.exportVideoMbps=8;settings.exportFPS=120;XCTAssertThrowsError(try settings.validated())
    }
    func testFitPreservesPortraitAndProject() {
        var project=Project();project.width=1080;project.height=1920
        var settings=UserSettings();ExportTemplate.x.apply(to:&settings)
        let rect=settings.exportFitRect(project)
        XCTAssertEqual(rect.width/rect.height,1080.0/1920,accuracy:0.00001)
        XCTAssertEqual(rect.midX,960);XCTAssertEqual(rect.midY,540)
        XCTAssertEqual(project.width,1080);XCTAssertEqual(project.height,1920)
    }
    @MainActor func testAPITemplateAndOverridesValidateAtomically()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-export-api-\(UUID())"),store=EditorStore(preferencesDirectory:root),api=EditorCommands();api.store=store
        defer{try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        func call(_ request:[String:Any])throws->ControlResult{api.execute(body:try JSONSerialization.data(withJSONObject:request))}
        XCTAssertEqual(try call(["command":"export.template","template":"niconico720"]).status,200)
        XCTAssertEqual(store.settings.exportVideoMbps,6)
        let before=store.settings
        XCTAssertEqual(try call(["command":"export.template","template":"unknown"]).status,400);XCTAssertEqual(store.settings,before)
        XCTAssertEqual(try call(["command":"settings.update","properties":["exportFPS":200]]).status,400);XCTAssertEqual(store.settings,before)
        XCTAssertEqual(try call(["command":"export.template","template":"project"]).status,200);XCTAssertNil(store.settings.exportWidth)
    }
    func testActualPresetExportsPreserveFPSAudioRangeAndPadding()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-export-templates-\(UUID())")
        try FileManager.default.createDirectory(at:root.appendingPathComponent("Media"),withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let format=AVAudioFormat(standardFormatWithSampleRate:24000,channels:1)!
        let pcm=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:24000)!;pcm.frameLength=24000
        for i in 0..<24000{pcm.floatChannelData![0][i]=Float(sin(Double(i)*2*Double.pi*440/24000)*0.2)}
        var file:AVAudioFile?=try AVAudioFile(forWriting:root.appendingPathComponent("Media/tone.wav"),settings:format.settings);try file!.write(from:pcm);file=nil
        let media=MediaAsset(name:"tone",file:"tone.wav",kind:.audio,duration:1)
        var clip=Clip(kind:.audio,name:"tone",track:0,start:0.3,duration:0.7);clip.assetID=media.id
        var project=Project();project.width=320;project.height=320;project.fps=24;project.background="FF0000";project.assets=[media];project.clips=[clip]
        for preset in ExportTemplate.allCases {
            var settings=UserSettings();preset.apply(to:&settings);settings.rangeStart=0.2;settings.rangeEnd=0.4
            let url=root.appendingPathComponent("\(preset.rawValue).mp4")
            try await MovieExporter.export(project:project,directory:root,destination:url,options:settings){_ in}
            let asset=AVURLAsset(url:url),videos=try await asset.loadTracks(withMediaType:.video)
            let video=try XCTUnwrap(videos.first)
            let size=try await video.load(.naturalSize),fps=try await video.load(.nominalFrameRate)
            XCTAssertEqual(Int(size.width),preset.width);XCTAssertEqual(Int(size.height),preset.height);XCTAssertEqual(Double(fps),Double(preset.fps),accuracy:0.1)
            let duration=try await asset.load(.duration);XCTAssertEqual(duration.seconds,0.2,accuracy:0.03)
            let generator=AVAssetImageGenerator(asset:asset),image=try generator.copyCGImage(at:.zero,actualTime:nil)
            let bitmap=NSBitmapImageRep(cgImage:image),center=try XCTUnwrap(bitmap.colorAt(x:preset.width/2,y:preset.height/2)?.usingColorSpace(.sRGB)),edge=try XCTUnwrap(bitmap.colorAt(x:20,y:preset.height/2)?.usingColorSpace(.sRGB))
            XCTAssertGreaterThan(center.redComponent,0.8);XCTAssertLessThan(edge.redComponent,0.05)
            let audios=try await asset.loadTracks(withMediaType:.audio),audio=try XCTUnwrap(audios.first),descriptions=try await audio.load(.formatDescriptions)
            let description=try XCTUnwrap(descriptions.first)
            XCTAssertEqual(CMFormatDescriptionGetMediaSubType(description),kAudioFormatMPEG4AAC)
            let asbd=try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(description));XCTAssertEqual(asbd.pointee.mSampleRate,48000);XCTAssertEqual(asbd.pointee.mChannelsPerFrame,2)
            let decoded=root.appendingPathComponent("\(preset.rawValue).caf")
            let didDecode=try await AudioProcessor.decode(source:url,destination:decoded);XCTAssertTrue(didDecode)
            let read=try AVAudioFile(forReading:decoded),buffer=AVAudioPCMBuffer(pcmFormat:read.processingFormat,frameCapacity:AVAudioFrameCount(read.length))!
            try read.read(into:buffer);XCTAssertGreaterThan((0..<Int(buffer.frameLength)).map{abs(buffer.floatChannelData![0][$0])}.max() ?? 0,0.1)
        }
        var silentProject=project;silentProject.clips=[Clip(kind:.shape,name:"silent",track:0,start:0,duration:1)]
        var silentOptions=UserSettings();ExportTemplate.x.apply(to:&silentOptions)
        let silentURL=root.appendingPathComponent("no-audio.mp4")
        try await MovieExporter.export(project:silentProject,directory:root,destination:silentURL,options:silentOptions){_ in}
        let silentTracks=try await AVURLAsset(url:silentURL).loadTracks(withMediaType:.audio);XCTAssertTrue(silentTracks.isEmpty)
        XCTAssertEqual(project.width,320);XCTAssertEqual(project.fps,24)
    }
}
