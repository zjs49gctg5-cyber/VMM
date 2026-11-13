import AppKit

/// A deterministic byte budget; oversized values can be used without being retained.
final class RenderCache<Value> {
    private struct Entry {var value:Value;var bytes:Int;var age:UInt64}
    private var entries:[String:Entry]=[:]
    private var age:UInt64=0
    var budget:Int {didSet{trim()}}
    private(set) var bytes=0
    var count:Int {entries.count}
    init(budget:Int){self.budget=max(0,budget)}
    func value(_ key:String)->Value? {
        guard var entry=entries[key] else{return nil};age &+= 1;entry.age=age;entries[key]=entry;return entry.value
    }
    func insert(_ value:Value,key:String,bytes cost:Int) {
        if let old=entries.removeValue(forKey:key){bytes-=old.bytes}
        let cost=max(0,cost);guard cost<=max(0,budget) else{return}
        age &+= 1;entries[key]=Entry(value:value,bytes:cost,age:age);bytes+=cost;trim()
    }
    func clear(){entries.removeAll();bytes=0}
    private func trim(){while bytes>max(0,budget),let oldest=entries.min(by:{$0.value.age<$1.value.age}) {entries.removeValue(forKey:oldest.key);bytes-=oldest.value.bytes}}
}
extension NSImage {
    var renderCacheBytes:Int {
        let pixels=representations.map{max(1,$0.pixelsWide)*max(1,$0.pixelsHigh)}.max() ?? max(1,Int(size.width*size.height))
        return pixels*4
    }
}
struct RenderCacheUsage:Equatable {
    var bytes:Int;var budget:Int;var decoderCount:Int
    var detail:String {String(format:"%@ %.1f / %.0f MiB · %@ %d",L("描画キャッシュ"),Double(bytes)/1048576,Double(budget)/1048576,L("動画デコーダー"),decoderCount)}
}
