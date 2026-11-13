import XCTest
@testable import VMM

final class SpeedCurveTests: XCTestCase {
    func testLinearSpeedIntegralAndInverse() throws {
        let curve = try SpeedCurve(points: [.init(time: 0, rate: 1), .init(time: 2, rate: 3)])
        XCTAssertEqual(curve.distance(at: 1), 1.5, accuracy: 1e-9)
        XCTAssertEqual(curve.distance(at: 3), 7, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(curve.timelineTime(forDistance: 1.5, duration: 3)), 1, accuracy: 1e-9)
        XCTAssertNil(curve.timelineTime(forDistance: 8, duration: 3))
    }
    func testReverseAndInvalidPoints() throws {
        let curve = try SpeedCurve(points: [.init(time: 0, rate: 1)])
        XCTAssertEqual(curve.sourceTime(at: 2, lowerBound: 3, upperBound: 10, reversed: true), 8)
        XCTAssertEqual(curve.sourceTime(at: 20, lowerBound: 3, upperBound: 10, reversed: true), 3)
        XCTAssertThrowsError(try SpeedCurve(points: [.init(time: 0, rate: 1), .init(time: 0, rate: 2)]))
        XCTAssertThrowsError(try SpeedCurve(points: [.init(time: 0, rate: 0)]))
    }
    func testInverseAcrossSegmentsAndOffsets() throws {
        let curve = try SpeedCurve(points: [.init(time: 1, rate: 2), .init(time: 3, rate: 1), .init(time: 4, rate: 4)])
        for time in stride(from: 0.0, through: 6.0, by: 0.125) {
            let distance = curve.distance(at: time)
            XCTAssertEqual(try XCTUnwrap(curve.timelineTime(forDistance: distance, duration: 6)), time, accuracy: 1e-8)
            XCTAssertEqual(curve.sourceTime(at: time, lowerBound: 10, upperBound: 50, reversed: true), 50-distance, accuracy: 1e-8)
        }
    }
    func testFragmentsPreserveSourceMappingInBothDirections() throws {
        for reversed in [false,true] {
            var clip=Clip(kind:.video,name:"test",track:0,start:10,duration:4)
            clip.sourceOffset=3;clip.reversed=reversed
            clip.speedPoints=[.init(time:0,rate:0.5),.init(time:2,rate:2),.init(time:4,rate:1)]
            let fragment=SourceEditing.fragment(clip,start:11,end:13)
            for time in stride(from:11.0,through:13.0,by:0.1) {
                XCTAssertEqual(fragment.sourceTime(at:time),clip.sourceTime(at:time),accuracy:1e-8)
            }
        }
    }
    func testReusableSourceMappingForTimelineSamples() throws {
        var clip=Clip(kind:.video,name:"mapping",track:0,start:10,duration:2)
        clip.sourceOffset=3
        clip.speedPoints=[.init(time:0,rate:1),.init(time:2,rate:3)]
        for reversed in [false,true] {
            clip.reversed=reversed
            let mapping=clip.sourceTimeMapping
            for (time,forward) in [(9.0,3.0),(10.0,3.0),(11.0,4.5),(12.0,7.0),(13.0,10.0)] {
                let expected=reversed ? 10-forward : forward
                XCTAssertEqual(mapping.sourceTime(at:time),expected,accuracy:1e-9)
                XCTAssertEqual(clip.sourceTime(at:time),expected,accuracy:1e-9)
            }
        }
        // Unvalidated in-memory clips retain the previous fallback of unit speed.
        clip.reversed=true;clip.speedPoints=[];clip.playbackRate=2
        XCTAssertEqual(clip.sourceTimeMapping.sourceTime(at:11),4,accuracy:1e-9)
        clip.speedPoints=nil;clip.playbackRate = .nan
        XCTAssertEqual(clip.sourceTimeMapping.sourceTime(at:11),4,accuracy:1e-9)
    }
}
