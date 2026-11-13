import AppKit
import CZlib

struct BinaryReader {
    let data: Data
    var position = 0
    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, position <= data.count, count <= data.count - position else { throw VMMError.message("PSD/ZIPデータが途中で切れています。") }
        defer { position += count }
        return data.subdata(in: position..<position + count)
    }
    mutating func skip(_ count: Int) throws { _ = try bytes(count) }
    mutating func u8() throws -> UInt8 { try bytes(1).first! }
    mutating func u16() throws -> Int { try bytes(2).reduce(0) { ($0 << 8) | Int($1) } }
    mutating func i16() throws -> Int { Int(Int16(bitPattern: UInt16(try u16()))) }
    mutating func u32() throws -> Int { try bytes(4).reduce(0) { ($0 << 8) | Int($1) } }
    mutating func i32() throws -> Int { Int(Int32(bitPattern: UInt32(try u32()))) }
    mutating func ascii(_ count: Int) throws -> String { String(data: try bytes(count), encoding: .ascii) ?? "" }
    mutating func section() throws -> BinaryReader { let size = try u32(); return BinaryReader(data: try bytes(size)) }
}

enum PSDImporter {
    private struct Record {
        var layer: PSDLayer
        var section: Int
        var channels: [(Int, Int)]
    }
    static func importFile(data: Data, mediaDirectory: URL, readme: String? = nil) throws -> PSDDocument {
        guard data.count < 512_000_000 else { throw VMMError.message("PSDが大きすぎます（上限512MB）。") }
        var reader = BinaryReader(data: data)
        guard try reader.ascii(4) == "8BPS", try reader.u16() == 1 else { throw VMMError.message("PSD形式に対応しています。PSB形式は未対応です。") }
        try reader.skip(6)
        _ = try reader.u16()
        let height = try reader.u32(), width = try reader.u32()
        guard (1...16384).contains(width), (1...16384).contains(height), width * height <= 32_000_000,
              try reader.u16() == 8, try reader.u16() == 3 else { throw VMMError.message("RGB・8bit、3200万画素以内のPSDを使用してください。") }
        _ = try reader.section(); _ = try reader.section()
        var layerAndMask = try reader.section()
        var layerInfo = try layerAndMask.section()
        let count = abs(try layerInfo.i16())
        guard (1...2000).contains(count) else { throw VMMError.message("PSDのレイヤー数が未対応です（1〜2000）。") }
        var records: [Record] = []
        var totalPixels = 0
        for id in 0..<count {
            let top = try layerInfo.i32(), left = try layerInfo.i32(), bottom = try layerInfo.i32(), right = try layerInfo.i32()
            let w = right - left, h = bottom - top
            guard w >= 0, h >= 0, w <= 16384, h <= 16384, abs(top) <= 32768, abs(left) <= 32768 else { throw VMMError.message("PSDのレイヤーサイズが不正です。") }
            totalPixels += w * h
            guard totalPixels <= 120_000_000 else { throw VMMError.message("PSDの展開サイズが上限を超えています。") }
            let channelCount = try layerInfo.u16()
            guard channelCount <= 16 else { throw VMMError.message("PSDのチャンネル数が未対応です。") }
            var channels: [(Int, Int)] = []
            for _ in 0..<channelCount { channels.append((try layerInfo.i16(), try layerInfo.u32())) }
            guard try layerInfo.ascii(4) == "8BIM" else { throw VMMError.message("PSDのレイヤーレコードが不正です。") }
            let blend = try layerInfo.ascii(4)
            let opacity = Double(try layerInfo.u8()) / 255
            let clipping = try layerInfo.u8(), flags = try layerInfo.u8()
            try layerInfo.skip(1)
            var extra = try layerInfo.section()
            let mask = try extra.section()
            _ = try extra.section()
            let nameLength = Int(try extra.u8())
            let legacy = try extra.bytes(nameLength)
            var name = String(data: legacy, encoding: .shiftJIS) ?? String(data: legacy, encoding: .macOSRoman) ?? "Layer \(id)"
            try extra.skip((4 - (nameLength + 1) % 4) % 4)
            var section = 0
            while extra.position + 12 <= extra.data.count {
                let signature = try extra.ascii(4)
                guard signature == "8BIM" || signature == "8B64" else { break }
                let key = try extra.ascii(4)
                var block = try extra.section()
                if block.data.count % 2 != 0 { try extra.skip(1) }
                if key == "luni" {
                    let units = try block.u32()
                    guard units <= 16384 else { throw VMMError.message("PSDレイヤー名が長すぎます。") }
                    name = String(data: try block.bytes(units * 2), encoding: .utf16BigEndian) ?? name
                }
                if key == "lsct" || key == "lsdk" { section = try block.u32() }
                if ["vmsk", "vsms", "TySh", "lfx2", "lrFX", "levl", "curv", "brit", "blnc", "mixr", "hue2", "hue ", "selc", "grdm", "vibA", "expA", "blwh", "SoCo", "GdFl", "PtFl"].contains(key) {
                    throw VMMError.message("レイヤー「\(name)」のベクターマスク・文字・効果は未対応です。ラスタライズしたPSDを使用してください。")
                }
            }
            guard mask.data.isEmpty, clipping == 0, ["norm", "pass"].contains(blend) else {
                throw VMMError.message("レイヤー「\(name)」のマスク／クリッピング／合成モード「\(blend)」は未対応です。通常合成のPSDを使用してください。")
            }
            guard section <= 3 else { throw VMMError.message("未対応のPSDグループ形式です。") }
            guard blend != "pass" || opacity == 1 else { throw VMMError.message("半透明の通過グループは未対応です：\(name)") }
            let layer = PSDLayer(id: id, name: name, group: section == 1 || section == 2, visible: flags & 2 == 0, opacity: opacity, x: left, y: top, width: w, height: h, blend: blend)
            records.append(Record(layer: layer, section: section, channels: channels))
        }
        var created: [URL] = []
        do {
            for index in records.indices {
                let record = records[index], w = record.layer.width, h = record.layer.height
                var decoded: [Int: [UInt8]] = [:]
                for (channel, length) in record.channels {
                    let payload = try layerInfo.bytes(length)
                    if record.section == 0 && w * h > 0 && [-1, 0, 1, 2].contains(channel) {
                        decoded[channel] = try decodeChannel(payload, width: w, height: h)
                    }
                }
                if record.section == 0 && w * h > 0 {
                    var rgba = [UInt8](repeating: 0, count: w * h * 4)
                    for pixel in 0..<(w * h) {
                        rgba[pixel * 4] = decoded[0]?[pixel] ?? 0
                        rgba[pixel * 4 + 1] = decoded[1]?[pixel] ?? 0
                        rgba[pixel * 4 + 2] = decoded[2]?[pixel] ?? 0
                        rgba[pixel * 4 + 3] = decoded[-1]?[pixel] ?? 255
                    }
                    let provider = CGDataProvider(data: Data(rgba) as CFData)!
                    guard let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
                          let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { throw VMMError.message("PSDレイヤーを画像に変換できません。") }
                    let filename = "\(UUID()).png"
                    let output = mediaDirectory.appendingPathComponent(filename)
                    try png.write(to: output, options: .atomic); created.append(output)
                    records[index].layer.file = filename
                }
            }
            var layers: [PSDLayer] = [], parents: [Int] = []
            // PSD stores back-to-front records; folder end markers come before their children.
            for record in records.reversed() {
                if record.section == 3 {
                    guard !parents.isEmpty else { throw VMMError.message("PSDのグループ構造が不正です。") }
                    parents.removeLast(); continue
                }
                var layer = record.layer; layer.parent = parents.last
                layers.append(layer)
                if layer.group { parents.append(layer.id) }
            }
            guard parents.isEmpty else { throw VMMError.message("PSDのグループが閉じていません。") }
            return PSDDocument(width: width, height: height, layers: layers, readme: readme)
        } catch { for url in created { try? FileManager.default.removeItem(at: url) }; throw error }
    }
    static func decodeChannel(_ data: Data, width: Int, height: Int) throws -> [UInt8] {
        var reader = BinaryReader(data: data)
        let compression = try reader.u16(), size = width * height
        switch compression {
        case 0: return Array(try reader.bytes(size))
        case 1:
            var lengths: [Int] = []
            for _ in 0..<height { lengths.append(try reader.u16()) }
            var output: [UInt8] = []; output.reserveCapacity(size)
            for length in lengths {
                var row = BinaryReader(data: try reader.bytes(length))
                let start = output.count
                while row.position < row.data.count {
                    let control = Int(Int8(bitPattern: try row.u8()))
                    if control >= 0 {
                        guard output.count - start + control + 1 <= width else { throw VMMError.message("PSDのRLE行が不正です。") }
                        output.append(contentsOf: try row.bytes(control + 1))
                    } else if control != -128 {
                        guard output.count - start + 1 - control <= width else { throw VMMError.message("PSDのRLE行が不正です。") }
                        output.append(contentsOf: repeatElement(try row.u8(), count: 1 - control))
                    }
                }
                guard output.count - start == width else { throw VMMError.message("PSDのRLE行の長さが不正です。") }
            }
            return output
        case 2, 3:
            let compressed = try reader.bytes(data.count - reader.position)
            var output = try inflateData(compressed, size: size, raw: false)
            if compression == 3 {
                for y in 0..<height { for x in 1..<width { output[y * width + x] &+= output[y * width + x - 1] } }
            }
            return output
        default: throw VMMError.message("未対応のPSD圧縮方式です：\(compression)")
        }
    }
}

func inflateData(_ compressed: Data, size: Int, raw: Bool) throws -> [UInt8] {
    guard size >= 0, size <= 512_000_000 else { throw VMMError.message("展開サイズが大きすぎます。") }
    var output = [UInt8](repeating: 0, count: max(1, size))
    var stream = z_stream()
    guard inflateInit2_(&stream, raw ? -MAX_WBITS : MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw VMMError.message("展開を開始できません。") }
    defer { inflateEnd(&stream) }
    let result = compressed.withUnsafeBytes { source in
        output.withUnsafeMutableBytes { target in
            stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(compressed.count)
            stream.next_out = target.bindMemory(to: Bytef.self).baseAddress
            stream.avail_out = uInt(target.count)
            return inflate(&stream, Z_FINISH)
        }
    }
    guard result == Z_STREAM_END, Int(stream.total_out) == size else { throw VMMError.message("圧縮データが破損しています。") }
    return Array(output.prefix(size))
}

enum PSDZip {
    struct Entry { var name: String; var data: Data }
    static func read(_ data: Data) throws -> [Entry] {
        func le(_ offset: Int, _ count: Int) throws -> Int {
            guard offset >= 0, count <= data.count - offset else { throw VMMError.message("ZIPが破損しています。") }
            return data[offset..<offset + count].reversed().reduce(0) { ($0 << 8) | Int($1) }
        }
        guard data.count >= 22, data.count < 512_000_000 else { throw VMMError.message("ZIPのサイズが未対応です。") }
        var end: Int?
        for offset in stride(from: data.count - 22, through: max(0, data.count - 65557), by: -1) {
            if try le(offset, 4) == 0x06054b50 { end = offset; break }
        }
        guard let end, try le(end + 4, 2) == 0, try le(end + 6, 2) == 0 else { throw VMMError.message("分割ZIPには対応していません。") }
        let count = try le(end + 10, 2)
        guard count < 4096 else { throw VMMError.message("ZIPのファイル数が多すぎます。") }
        var offset = try le(end + 16, 4), result: [Entry] = [], total = 0
        for _ in 0..<count {
            guard try le(offset, 4) == 0x02014b50 else { throw VMMError.message("ZIPの索引が不正です。") }
            let flags = try le(offset + 8, 2), method = try le(offset + 10, 2)
            let checksum = try le(offset + 16, 4), compressedSize = try le(offset + 20, 4), size = try le(offset + 24, 4)
            let nameSize = try le(offset + 28, 2), extraSize = try le(offset + 30, 2), commentSize = try le(offset + 32, 2)
            let local = try le(offset + 42, 4)
            guard nameSize <= data.count - offset - 46 else { throw VMMError.message("ZIPのファイル名が不正です。") }
            let nameData = data.subdata(in: offset + 46..<offset + 46 + nameSize)
            let name = String(data: nameData, encoding: flags & 0x800 != 0 ? .utf8 : .shiftJIS) ?? String(data: nameData, encoding: .utf8) ?? "unknown"
            offset += 46 + nameSize + extraSize + commentSize
            guard ["psd", "pfv", "txt"].contains((name as NSString).pathExtension.lowercased()) else { continue }
            total += size
            guard flags & 1 == 0, total <= 512_000_000, [0, 8].contains(method), try le(local, 4) == 0x04034b50 else { throw VMMError.message("暗号化ZIP、ZIP64、または大きすぎるZIPは未対応です。") }
            let start = local + 30 + (try le(local + 26, 2)) + (try le(local + 28, 2))
            guard start <= data.count, compressedSize <= data.count - start else { throw VMMError.message("ZIPの圧縮データが不正です。") }
            let compressed = data.subdata(in: start..<start + compressedSize)
            let bytes = method == 0 ? Array(compressed) : try inflateData(compressed, size: size, raw: true)
            let crc = bytes.withUnsafeBufferPointer { crc32(0, $0.baseAddress, uInt($0.count)) }
            guard bytes.count == size, Int(crc) == checksum else { throw VMMError.message("ZIPのチェックサムが一致しません。") }
            result.append(Entry(name: (name as NSString).lastPathComponent, data: Data(bytes)))
        }
        return result
    }
}
