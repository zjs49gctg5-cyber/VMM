import Foundation

/// Compact, self-contained SDR 3D cube. Samples are RGBA float32 little-endian.
struct ColorLUT:Codable,Equatable {
    let name:String
    let size:Int
    let data:Data
    static let maximumInputBytes=4*1024*1024
    static let maximumProjectBytes=8*1024*1024
    func validate()throws {
        guard !name.isEmpty,name.count<=200,(2...33).contains(size),data.count==size*size*size*16 else{throw VMMError.message("LUTのサイズまたはデータが不正です。")}
        let valid=data.withUnsafeBytes { raw -> Bool in
            for offset in stride(from:0,to:raw.count,by:4) {
                let bits=UInt32(littleEndian:raw.loadUnaligned(fromByteOffset:offset,as:UInt32.self)),value=Float(bitPattern:bits)
                guard value.isFinite,(0...1).contains(value),offset%16 != 12 || value==1 else{return false}
            };return true
        }
        guard valid else{throw VMMError.message("LUTに未対応の色値があります。")}
    }
    static func load(_ url:URL)throws->ColorLUT {
        let handle=try FileHandle(forReadingFrom:url);defer{try? handle.close()}
        var data=Data()
        while data.count<=maximumInputBytes {
            guard let part=try handle.read(upToCount:min(65536,maximumInputBytes+1-data.count)),!part.isEmpty else{break}
            data.append(part)
        }
        guard data.count<=maximumInputBytes else{throw VMMError.message("LUTファイルが大きすぎます。")}
        return try parse(data,name:String(url.lastPathComponent.prefix(200)))
    }
    static func parse(_ data:Data,name:String)throws->ColorLUT {
        guard data.count<=maximumInputBytes,let decoded=String(data:data,encoding:.utf8) else{throw VMMError.message("LUTはUTF-8の.cubeファイルを指定してください。")}
        let text=decoded.hasPrefix("\u{FEFF}") ? String(decoded.dropFirst()):decoded
        var dimension:Int?,values:[Float]=[],seenSamples=false
        for raw in text.replacingOccurrences(of:"\r\n",with:"\n").replacingOccurrences(of:"\r",with:"\n").split(separator:"\n",omittingEmptySubsequences:false) {
            let line=raw.split(separator:"#",maxSplits:1,omittingEmptySubsequences:false).first!.trimmingCharacters(in:.whitespacesAndNewlines)
            if line.isEmpty {continue}
            let parts=line.split(whereSeparator:{$0.isWhitespace})
            switch parts[0].uppercased() {
            case "TITLE":guard !seenSamples else{throw VMMError.message("LUTの形式が不正です。")};continue
            case "LUT_3D_SIZE":
                guard !seenSamples,dimension==nil,parts.count==2,let size=Int(parts[1]),(2...33).contains(size) else{throw VMMError.message("LUTは2〜33格子の3D形式に対応します。")}
                dimension=size;values.reserveCapacity(size*size*size*4)
            case "DOMAIN_MIN","DOMAIN_MAX":
                let expected:Float=parts[0].uppercased()=="DOMAIN_MIN" ? 0:1
                guard !seenSamples,parts.count==4,parts.dropFirst().allSatisfy({Float($0)==expected}) else{throw VMMError.message("LUTの入力範囲は0〜1のみ対応します。")}
            case "LUT_1D_SIZE","LUT_1D_INPUT_RANGE","LUT_3D_INPUT_RANGE":throw VMMError.message("1D LUTまたは非標準の入力範囲には対応していません。")
            default:
                guard let size=dimension,parts.count==3,values.count<size*size*size*4,let r=Float(parts[0]),let g=Float(parts[1]),let b=Float(parts[2]),[r,g,b].allSatisfy({$0.isFinite && (0...1).contains($0)}) else{throw VMMError.message("LUTの色値または行数が不正です。")}
                seenSamples=true;values.append(contentsOf:[r,g,b,1])
            }
        }
        guard let dimension,values.count==dimension*dimension*dimension*4 else{throw VMMError.message("LUTの色値または行数が不正です。")}
        var bytes=Data(capacity:values.count*4)
        for value in values {var bits=value.bitPattern.littleEndian;withUnsafeBytes(of:&bits){bytes.append(contentsOf:$0)}}
        let cube=ColorLUT(name:name,size:dimension,data:bytes);try cube.validate();return cube
    }
}
