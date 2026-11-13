import XCTest
@testable import VMM

final class CaptionTests:XCTestCase {
    @MainActor func testConvertSelectedTextPreservesStyleAndTimingAndIsAtomic() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-convert-\(UUID())"),s=EditorStore(preferencesDirectory:root)
        defer { s.cancelSpeech(); try? FileManager.default.removeItem(at:root); try? FileManager.default.removeItem(at:s.directory) }
        s.autoSpeech=false;s.project=Project();s.selectedTrack=1
        try s.importCaptions("1\n00:00:01,000 --> 00:00:01,500\n字幕\n\n2\n00:00:02,000 --> 00:00:03,000\n次",format:.srt)
        s.project.clips[0].color="FF0000"
        let original=s.project.clips
        s.project.tracks[1].locked=true
        XCTAssertThrowsError(try s.convertSelectedTextToSpeech());XCTAssertEqual(s.project.clips,original)
        s.project.tracks[1].locked=false;try s.convertSelectedTextToSpeech()
        XCTAssertTrue(s.project.clips.allSatisfy{$0.kind == .speech && $0.speechDirty && $0.preserveSpeechDuration == true})
        XCTAssertEqual(s.project.clips.map(\.start),original.map(\.start));XCTAssertEqual(s.project.clips.map(\.duration),original.map(\.duration));XCTAssertEqual(s.project.clips[0].color,"FF0000")
        s.undo();XCTAssertEqual(s.project.clips,original)
    }
    func testSRTVTTParsingMultilineEntitiesAndRoundTrip()throws {
        let source="\u{FEFF}1\r\n00:00:01,250 --> 00:00:03,000\r\nHello &amp; &lt;world&gt;\r\nsecond line\r\n\r\n2\r\n00:00:04,000 --> 00:00:05,000\r\n<i>字幕</i>"
        let cues=try CaptionCodec.parse(source,format:.srt)
        XCTAssertEqual(cues.count,2);XCTAssertEqual(cues[0],CaptionCue(start:1.25,end:3,text:"Hello & <world>\nsecond line"));XCTAssertEqual(cues[1].text,"字幕")
        for format in [CaptionFormat.srt,.vtt] {XCTAssertEqual(try CaptionCodec.parse(CaptionCodec.encode(cues,format:format),format:format),cues)}
        let vtt="WEBVTT\n\nNOTE ignored\ncomment\n\nidentifier\n00:01.000 --> 00:02.000 align:start\n<v Voice>字幕</v>\n"
        XCTAssertEqual(try CaptionCodec.parse(vtt,format:.vtt),[CaptionCue(start:1,end:2,text:"字幕")])
        for invalid in ["00:00:03,000 --> 00:00:01,000\nno","99:60:00,000 --> 99:61:00,000\nno","9223372036854775807:00:00.000 --> 99:00:00.000\nno","garbage",""] {XCTAssertThrowsError(try CaptionCodec.parse(invalid,format:.srt))}
    }
    @MainActor func testImportUndoDiagnosticsAndParentVisibleExport()throws {
        let s=EditorStore(preferencesDirectory:FileManager.default.temporaryDirectory.appendingPathComponent("vmm-caption-\(UUID())"));defer{try? FileManager.default.removeItem(at:s.directory)}
        s.project=Project();s.selectedTrack=1
        try s.importCaptions("1\n00:00:00,000 --> 00:00:01,000\n長い字幕をここに書いて文字数の診断を確かめます\n\n2\n00:00:00,500 --> 00:00:02,000\n字幕",format:.srt,at:3)
        XCTAssertEqual(s.project.clips.count,2);XCTAssertEqual(s.project.clips[0].start,3);XCTAssertEqual(s.project.captionDiagnostics.count,2)
        var group=Clip(kind:.group,name:"parent",track:2,start:3.25,duration:0.5);s.project.clips[0].parentID=group.id;s.project.clips.append(group)
        XCTAssertEqual(s.project.captionCues.first?.start,3.25);XCTAssertEqual(s.project.captionCues.first?.end,3.75)
        group.id=UUID();s.project.tracks[2].visible=false;XCTAssertEqual(s.project.captionCues.count,1)
        s.undo();XCTAssertTrue(s.project.clips.isEmpty)
        s.project.tracks[1].locked=true;XCTAssertThrowsError(try s.importCaptions("1\n00:00:00,000 --> 00:00:01,000\n字幕",format:.srt));XCTAssertTrue(s.project.clips.isEmpty)
    }
}
