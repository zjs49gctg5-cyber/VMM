import XCTest
@testable import VMM

final class LyricTimingTests:XCTestCase {
    func testRecordingPreservesImportedCharacterTiming()throws {
        var lines=try LyricLRC.parse("[00:01.000]あ[00:02.000]い[00:03.000]\n[00:03.000]う[00:04.000]え[00:05.000]",fps:30)
        let original=lines
        XCTAssertThrowsError(try LyricTemplatePlanner.record(&lines,index:1,time:2,fps:30))
        XCTAssertEqual(lines,original)
        try LyricTemplatePlanner.record(&lines,index:0,time:2,fps:30)
        XCTAssertEqual(lines[0].end,4,accuracy:0.0001)
        XCTAssertEqual(lines[0].segments,original[0].segments)
    }
    func testShiftIsFrameAlignedAndRejectsNegativeTimes()throws {
        let lines=try LyricTemplatePlanner.distribute("一\n二",start:1,interval:2,fps:30)
        let shifted=try LyricTemplatePlanner.shifted(lines,by:0.51,fps:30)
        XCTAssertEqual(shifted[0].start,1.5,accuracy:0.00001)
        XCTAssertEqual(shifted[1].end,5.5,accuracy:0.00001)
        XCTAssertThrowsError(try LyricTemplatePlanner.shifted(lines,by:-2,fps:30))
        XCTAssertEqual(lines[0].start,1)
    }
    func testKaraokeAlternatesRowsAndPreservesSingingTimes()throws {
        let lines=try LyricTemplatePlanner.distribute("一\n二\n三\n四",start:2,interval:2,fps:30)
        let clips=try LyricTemplatePlanner.karaokeClips(lines,track:0,fps:30,lead:1,tail:0.5)
        XCTAssertEqual(clips.map(\.y),[0.77,0.87,0.77,0.87])
        for i in lines.indices {
            let wipe=try XCTUnwrap(clips[i].lyricWipe)
            XCTAssertEqual(clips[i].start+wipe.start,lines[i].start,accuracy:0.0001)
            XCTAssertEqual(clips[i].start+wipe.end,lines[i].end,accuracy:0.0001)
            XCTAssertLessThan(clips[i].start,lines[i].start)
            if i>=2 {XCTAssertLessThanOrEqual(clips[i-2].end,clips[i].start)}
        }
        XCTAssertThrowsError(try LyricTemplatePlanner.karaokeClips(lines,track:0,fps:30,lead:-1,tail:0))
        let colored=try LyricTemplatePlanner.karaokeClips(lines,track:0,fps:30,lead:1,tail:0.5,beforeColor:"112233",afterColor:"ABCDEF")
        XCTAssertTrue(colored.allSatisfy{$0.color=="112233" && $0.lyricWipe?.color=="ABCDEF"})
        XCTAssertThrowsError(try LyricTemplatePlanner.karaokeClips(lines,track:0,fps:30,lead:1,tail:0,beforeColor:"bad"))
    }
    func testRecordingSnapsAndPreservesOnInvalidInput()throws {
        var lines=try LyricTemplatePlanner.distribute("一行\n二行",start:0,interval:2,fps:30)
        try LyricTemplatePlanner.record(&lines,index:0,time:0.51,fps:30)
        try LyricTemplatePlanner.record(&lines,index:1,time:1.51,fps:30)
        XCTAssertEqual(lines[0].start,0.5,accuracy:0.0001)
        XCTAssertEqual(lines[0].end,lines[1].start)
        let previous=lines
        XCTAssertThrowsError(try LyricTemplatePlanner.record(&lines,index:1,time:0.2,fps:30))
        XCTAssertEqual(lines,previous)
        XCTAssertNoThrow(try LyricTemplatePlanner.clips(lines,track:0,fps:30,motion:.none))
    }
}
