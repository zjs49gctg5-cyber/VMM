import AppKit
import ImageIO

/// ImageIO owns decoding; only the selected frame is materialized at a time.
final class AnimatedGIF {
    let source: CGImageSource
    let ends: [Double]
    let loopCount: Int?

    init?(url: URL) {
        guard url.pathExtension.lowercased() == "gif",
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 1, count <= 10_000 else { return nil }
        var ends: [Double] = [], total = 0.0
        for index in 0..<count {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue ?? 0.1
            // Tiny/invalid delays are conventionally treated as 100 ms by image viewers.
            total += delay.isFinite && delay >= 0.02 ? delay : 0.1
            ends.append(total)
        }
        self.source = source
        self.ends = ends
        // ImageIO reports a default count even when the file has no loop extension.
        self.loopCount = Self.readLoopCount(url)
    }

    private static func readLoopCount(_ url: URL) -> Int? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count >= 13,
              String(data: data.prefix(3), encoding: .ascii) == "GIF" else { return nil }
        let bytes = data, packed = bytes[10]
        var pos = 13 + (packed & 0x80 == 0 ? 0 : 3 * (1 << (Int(packed & 7) + 1)))
        func skipBlocks(_ pos: inout Int) -> Bool {
            while pos < bytes.count {
                let size = Int(bytes[pos]); pos += 1
                if size == 0 { return true }
                guard size <= bytes.count - pos else { return false }; pos += size
            }
            return false
        }
        while pos < bytes.count {
            let marker = bytes[pos]; pos += 1
            if marker == 0x3b { break }
            if marker == 0x2c {
                guard pos + 9 <= bytes.count else { return nil }
                let flags = bytes[pos + 8]; pos += 9
                if flags & 0x80 != 0 { pos += 3 * (1 << (Int(flags & 7) + 1)) }
                guard pos < bytes.count else { return nil }; pos += 1
                guard skipBlocks(&pos) else { return nil }
            } else if marker == 0x21 {
                guard pos < bytes.count else { return nil }
                let label = bytes[pos]; pos += 1
                if label == 0xff, pos + 12 <= bytes.count, bytes[pos] == 11 {
                    let name = String(bytes: bytes[(pos + 1)..<(pos + 12)], encoding: .ascii)
                    if name == "NETSCAPE2.0" || name == "ANIMEXTS1.0" {
                        pos += 12
                        guard pos + 4 <= bytes.count, bytes[pos] >= 3, bytes[pos + 1] == 1 else { return nil }
                        return Int(bytes[pos + 2]) | (Int(bytes[pos + 3]) << 8)
                    }
                }
                guard skipBlocks(&pos) else { return nil }
            } else { return nil }
        }
        return nil
    }

    func frameIndex(at time: Double) -> Int {
        let duration = ends.last ?? 0
        guard duration > 0 else { return 0 }
        let time = time.isFinite ? max(0, time) : 0
        // A missing loop extension means one play; 0 means infinite repeats.
        if let count = loopCount {
            if count > 0, time >= duration * (Double(count) + 1) { return ends.count - 1 }
        } else if time >= duration { return ends.count - 1 }
        let local = time.truncatingRemainder(dividingBy: duration)
        var low = 0, high = ends.count
        while low < high {
            let middle = (low + high) / 2
            if local < ends[middle] { high = middle } else { low = middle + 1 }
        }
        return min(low, ends.count - 1)
    }

    func image(at index: Int) -> NSImage? {
        guard let frame = CGImageSourceCreateImageAtIndex(source, index, nil) else { return nil }
        return NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height))
    }
}
