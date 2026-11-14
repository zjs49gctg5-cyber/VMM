import XCTest
@testable import VMM

final class LyricLRCTests:XCTestCase {
    func testLineTimingMetadataGapsAndRoundTrip()throws {
        let source="[ti:曲名]\n[00:01.00]一行目\n[00:02.00]\n[00:03.00]二行目\n[00:04.00]\n"
        let lines=try LyricLRC.parse(source,fps:30)
        XCTAssertEqual(lines.map(\.text),["一行目","二行目"])
        XCTAssertEqual(lines.map(\.start),[1,3]);XCTAssertEqual(lines.map(\.end),[2,4])
        let restored=try LyricLRC.parse(LyricLRC.encode(lines,fps:30),fps:30)
        XCTAssertEqual(restored.map(\.text),lines.map(\.text));XCTAssertEqual(restored.map(\.start),lines.map(\.start));XCTAssertEqual(restored.map(\.end),lines.map(\.end))
    }
    func testUnsupportedExtensionsAndInvalidTimingAreRejected()throws {
        for text in ["[00:02]A\n[00:01]B", "[00:60]A", "@Ruby=歌,うた"] {
            XCTAssertThrowsError(try LyricLRC.parse(text,fps:30),text)
        }
    }
    func testKaraokeTagsRubyOffsetRoundTripAndPlacement()throws {
        let text="@Offset=100\n@Ruby1=為替,かわせ\n[00:01:00]本日の[00:02:00]為替[00:04:00]レート[00:05:00]"
        let lines=try LyricLRC.parse(text,fps:30),line=try XCTUnwrap(lines.first)
        XCTAssertEqual(line.text,"本日の為替レート");XCTAssertEqual(line.start,1.1,accuracy:0.001)
        let segments=try XCTUnwrap(line.segments);XCTAssertEqual(segments.map(\.startIndex),[0,3,5]);XCTAssertEqual(segments.map(\.endIndex),[3,5,8])
        XCTAssertEqual(segments[1].start,1,accuracy:0.001);XCTAssertEqual(segments[1].end,3,accuracy:0.001)
        XCTAssertEqual(line.ruby?.first?.text,"かわせ");XCTAssertEqual(line.ruby?.first?.startIndex,3)
        let clip=try XCTUnwrap(LyricTemplatePlanner.karaokeClips(lines,track:0,fps:30,lead:1,tail:0.5).first)
        XCTAssertEqual(try XCTUnwrap(clip.lyricWipe?.segments?[1].start)+clip.start,2.1,accuracy:0.001);XCTAssertEqual(clip.lyricRuby?.first?.text,"かわせ")
        let round=try LyricLRC.parse(LyricLRC.encode(lines,fps:30),fps:30),r=try XCTUnwrap(round.first)
        XCTAssertEqual(r.text,line.text);XCTAssertEqual(r.ruby?.first?.text,"かわせ");XCTAssertEqual(r.segments?.map(\.startIndex),segments.map(\.startIndex))
    }
    func testRubyEmbeddedRelativeTiming()throws {
        let text="@Ruby1=為替,か[00:00:50]わ[00:01:00]せ\n[00:10:00]為替[00:12:00]"
        let lines=try LyricLRC.parse(text,fps:30),line=try XCTUnwrap(lines.first),ruby=try XCTUnwrap(line.ruby?.first)
        XCTAssertEqual(ruby.text,"かわせ");XCTAssertEqual(ruby.timings?.map(\.index),[1,2]);XCTAssertEqual(ruby.timings?.map(\.offset),[0.5,1])
        XCTAssertEqual(ruby.progress(at:10.5,start:10,end:12),1.0/3,accuracy:0.00001)
        XCTAssertEqual(ruby.progress(at:11,start:10,end:12),2.0/3,accuracy:0.00001)
        let round=try XCTUnwrap(try LyricLRC.parse(LyricLRC.encode(lines,fps:30),fps:30).first?.ruby?.first)
        XCTAssertEqual(round.text,ruby.text);XCTAssertEqual(round.timings,ruby.timings)
        XCTAssertThrowsError(try LyricLRC.parse("@Ruby1=為替,か[00:03:00]わ\n[00:10:00]為替[00:12:00]",fps:30))
    }
    func testMetadataPreservedAndInstantSegment()throws {
        let source="[ti:曲名]\n@Artist=歌手\n@Custom=情報\n@Offset=100\n[00:01:00]あ[00:01:00]い[00:02:00]"
        let line=try XCTUnwrap(try LyricLRC.parse(source,fps:30).first)
        XCTAssertEqual(line.segments?.first?.start,line.segments?.first?.end)
        let exported=try LyricLRC.encode([line],fps:30)
        XCTAssertTrue(exported.contains("@Custom=情報"));XCTAssertTrue(exported.contains("@Offset=0"));XCTAssertTrue(exported.contains("[ti:曲名]"))
        let restored=try XCTUnwrap(try LyricLRC.parse(exported,fps:30).first)
        XCTAssertEqual(restored.text,line.text);XCTAssertEqual(restored.start,line.start,accuracy:0.001)
        XCTAssertEqual(restored.segments?.map(\.startIndex),line.segments?.map(\.startIndex))
    }
    func testNonFrameAlignedTagsCanBePlaced()throws {
        let lines=try LyricLRC.parse("[00:01.01]あ[00:01.12]い[00:02.01]",fps:30)
        let clip=try XCTUnwrap(LyricTemplatePlanner.karaokeClips(lines,track:0,fps:30,lead:0,tail:0).first)
        XCTAssertEqual(clip.lyricWipe?.segments?.count,2)
        XCTAssertNoThrow(try LyricLRC.encode(lines,fps:30))
    }
}
