import XCTest
@testable import VMM

final class LyricAlignmentTests:XCTestCase {
    func testMatchesPreserveLyricsAndReportUnknown()throws {
        var clip=Clip(kind:.audio,name:"voice",track:0,start:10,duration:10);clip.playbackRate=2
        let tokens=[TranscriptToken(text:"アイ",start:2,duration:1),TranscriptToken(text:"うえ",start:5,duration:1)]
        let matches=try LyricAlignment.suggest(text:"あい！\n認識なし\nウエ",tokens:tokens,clip:clip,fps:30)
        XCTAssertEqual(matches.map(\.text),["あい！","認識なし","ウエ"])
        XCTAssertEqual(matches.map(\.matched),[true,false,true])
        XCTAssertEqual(try XCTUnwrap(matches[0].start),11,accuracy:0.001)
        XCTAssertEqual(try XCTUnwrap(matches[0].end),11.5,accuracy:0.001)
        XCTAssertEqual(try XCTUnwrap(matches[2].start),12.5,accuracy:0.001)
        XCTAssertNil(matches[1].start)
    }
    func testNoRecognitionNeverInventsTiming()throws {
        let clip=Clip(kind:.audio,name:"voice",track:0,start:0,duration:3)
        let matches=try LyricAlignment.suggest(text:"歌詞\n歌詞",tokens:[],clip:clip,fps:30)
        XCTAssertEqual(matches.count,2);XCTAssertTrue(matches.allSatisfy{!$0.matched})
        XCTAssertThrowsError(try LyricAlignment.suggest(text:"",tokens:[],clip:clip,fps:30))
    }
    func testLongAudioChunksPreserveTrimRateAndSelectBetterRecognition()async throws {
        var clip=Clip(kind:.audio,name:"voice",track:0,start:10,duration:70);clip.playbackRate=2;clip.sourceOffset=7
        let chunks=try LyricAlignment.chunks(clip)
        XCTAssertEqual(chunks.count,5);XCTAssertEqual(chunks.map(\.sourceDelta),[0,30,60,90,120])
        XCTAssertEqual(chunks.map{$0.clip.sourceOffset},[7,37,67,97,127]);XCTAssertEqual(chunks.map{$0.clip.duration},[15,15,15,15,10])
        let matches=try await LyricAlignment.recognize(text:"あい\nうえ",source:URL(fileURLWithPath:"/unused"),clip:clip,language:"ja-JP",fps:30) {_,part,_,hints in
            if part.sourceOffset==7 {return [TranscriptToken(text:"あい",start:2,duration:2)]}
            if part.sourceOffset==37 && !hints.isEmpty {return [TranscriptToken(text:"うえ",start:2,duration:2)]}
            if part.sourceOffset==127 {throw NSError(domain:"kAFAssistantErrorDomain",code:1110)}
            return []
        }
        XCTAssertEqual(matches.map(\.matched),[true,true])
        XCTAssertEqual(try XCTUnwrap(matches[0].start),11,accuracy:0.001)
        XCTAssertEqual(try XCTUnwrap(matches[1].start),26,accuracy:0.001)
        clip.duration=901;XCTAssertThrowsError(try LyricAlignment.chunks(clip))
    }
}
