import Foundation

/// A piecewise-linear speed curve in timeline seconds. Source distance is its integral.
struct SpeedCurve {
    struct Point: Codable, Equatable {
        var time: Double
        var rate: Double
    }
    func rate(at time: Double) -> Double {
        guard time > points[0].time else { return points[0].rate }
        for (left, right) in zip(points, points.dropFirst()) where time <= right.time {
            let t = (time - left.time) / (right.time - left.time)
            return left.rate + (right.rate - left.rate) * t
        }
        return points.last!.rate
    }
    let points: [Point]
    private let cumulativeDistances: [Double]

    init(points: [Point]) throws {
        guard !points.isEmpty, points.count <= 500,
              points.allSatisfy({ $0.time.isFinite && $0.time >= 0 && $0.time <= 86400 && $0.rate.isFinite && (0.25...4).contains($0.rate) }),
              zip(points, points.dropFirst()).allSatisfy({ $0.time < $1.time }) else {
            throw VMMError.message("速度カーブが不正です。")
        }
        self.points = points
        var cumulative = [points[0].time * points[0].rate]
        for (left, right) in zip(points, points.dropFirst()) {
            cumulative.append(cumulative.last! + (right.time - left.time) * (left.rate + right.rate) / 2)
        }
        self.cumulativeDistances = cumulative
    }

    func distance(at time: Double) -> Double {
        guard time.isFinite, time > 0 else { return 0 }
        guard time > points[0].time else { return time * points[0].rate }
        var low = 0, high = points.count
        while low + 1 < high {
            let middle = (low + high) / 2
            if points[middle].time <= time { low = middle } else { high = middle }
        }
        let left = points[low], length = time - left.time
        guard low + 1 < points.count else { return cumulativeDistances[low] + length * left.rate }
        let right = points[low + 1]
        let slope = (right.rate - left.rate) / (right.time - left.time)
        return cumulativeDistances[low] + left.rate * length + slope * length * length / 2
    }

    func sourceTime(at time: Double, lowerBound: Double, upperBound: Double, reversed: Bool) -> Double {
        let offset = distance(at: time)
        return reversed ? max(lowerBound, upperBound - offset) : min(upperBound, lowerBound + offset)
    }

    /// Positive rates make distance monotonic, so inversion is stable even at control points.
    func timelineTime(forDistance distance: Double, duration: Double) -> Double? {
        guard distance.isFinite, duration.isFinite, duration >= 0, distance >= 0,
              distance <= self.distance(at: duration) + 1e-9 else { return nil }
        var low = 0.0, high = duration
        for _ in 0..<64 {
            let mid = (low + high) / 2
            if self.distance(at: mid) < distance { low = mid } else { high = mid }
        }
        return (low + high) / 2
    }
}

/// Reuse a validated curve and its total distance when sampling many timeline positions.
struct SourceTimeMapping {
    private let start: Double
    private let offset: Double
    private let curve: SpeedCurve
    private let reverseDistance: Double?

    init(clip: Clip) {
        start = clip.start
        offset = clip.sourceOffset
        curve = clip.timeWarpCurve
        reverseDistance = clip.reversed == true ? curve.distance(at: clip.duration) : nil
    }

    func sourceTime(at time: Double) -> Double {
        let distance = curve.distance(at: max(0, time - start))
        return reverseDistance.map { offset + $0 - distance } ?? offset + distance
    }
}
