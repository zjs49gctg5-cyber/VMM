import XCTest
@testable import VMM

final class AnimationInterpolationPerformanceTests: XCTestCase {
    // The original sorting implementation serves as a reference, including
    // edge cases from older projects whose keys are not stored chronologically.
    private func reference(_ keys: [AnimationKeyframe], at time: Double, fallback: Double) -> Double {
        let sorted = keys.sorted { $0.time < $1.time }
        guard let first = sorted.first, let last = sorted.last else { return fallback }
        if time <= first.time { return first.value }
        if time >= last.time { return last.value }
        guard let index = sorted.firstIndex(where: { $0.time > time }), index > 0 else { return last.value }
        let a = sorted[index - 1], b = sorted[index]
        let progress = (time - a.time) / max(0.000001, b.time - a.time)
        let t = a.customCurve?.value(progress) ?? a.easing.value(progress)
        return a.value + (b.value - a.value) * t
    }

    func testInterpolationMatchesSortingForUnorderedKeysAndBoundaries() {
        let empty: [AnimationKeyframe] = []
        XCTAssertEqual(interpolate(empty, at: 1, fallback: 4), 4)
        let keys = (0..<100).map { i in
            AnimationKeyframe(time: Double((i * 37) % 29) / 4, value: Double(i) / 10,
                              easing: Easing.allCases[i % Easing.allCases.count],
                              customCurve: i.isMultiple(of: 5) ? EasingCurve() : nil)
        }
        for list in [[keys[0]], keys, keys.reversed().map { $0 }, keys.sorted { $0.time < $1.time }] {
            for step in -4...36 {
                let time = Double(step) / 4
                XCTAssertEqual(interpolate(list, at: time, fallback: -1), reference(list, at: time, fallback: -1), accuracy: 1e-12)
                XCTAssertEqual(interpolate(list, at: time + 0.123, fallback: -1), reference(list, at: time + 0.123, fallback: -1), accuracy: 1e-12)
            }
        }
    }

    func testInterpolationTimingWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["VMM_ANIMATION_BENCHMARK"] == "1" else { throw XCTSkip("Opt-in benchmark") }
        let keys = (0..<500).map { i in AnimationKeyframe(time: Double(i) / 30, value: Double(i % 100) / 100, easing: .linear) }
        let iterations = 20_000
        var checksum = 0.0
        let startOld = ProcessInfo.processInfo.systemUptime
        for i in 0..<iterations { checksum += reference(keys, at: Double(i % 499) / 30 + 0.005, fallback: 0) }
        let old = ProcessInfo.processInfo.systemUptime - startOld
        let startNew = ProcessInfo.processInfo.systemUptime
        for i in 0..<iterations { checksum += interpolate(keys, at: Double(i % 499) / 30 + 0.005, fallback: 0) }
        let new = ProcessInfo.processInfo.systemUptime - startNew
        print("Animation interpolation (\(iterations) x \(keys.count) keys): sorted \(old)s, single-pass \(new)s, checksum \(checksum)")
        XCTAssertTrue(checksum.isFinite)
    }
}
