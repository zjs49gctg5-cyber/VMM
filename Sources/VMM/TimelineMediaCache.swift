import AppKit
import AVFoundation
import ImageIO
import Combine

final class TimelineMediaCache:ObservableObject {
    @Published private(set) var revision=0
    private struct Failure {var signature:String;var attempts:Int;var retryAfter:Double}
    private var failed:[String:Failure]=[:]
    static let shared=TimelineMediaCache()
    private let images=NSCache<NSString,NSImage>()
    private var pending:Set<String>=[]
    private final class Waveform:NSObject {let values:[Double];init(_ values:[Double]){self.values=values}}
    private let envelopes=NSCache<NSString,Waveform>()
    private var generation=0
    private struct Job {let key:String;let generation:Int;let source:URL?;let work:()async->Value;let onReady:()->Void}
    private enum Value {case image(NSImage?),waveform([Double])}
    private var jobs:[Job]=[]
    private var tasks:[UUID:Task<Void,Never>]=[:]
    private(set) var peakConcurrentRequests=0
    var pendingRequests:Int {pending.count}
    var activeRequests:Int {tasks.count}
    init(){envelopes.totalCostLimit=64*1024*1024;envelopes.countLimit=256}
    func clear(){
        generation+=1;images.removeAllObjects();envelopes.removeAllObjects();jobs=[]
        tasks.values.forEach{$0.cancel()};pending.removeAll();failed.removeAll();revision+=1
    }
    private func enqueue(_ key:String,source:URL?=nil,onReady:@escaping()->Void,work:@escaping()async->Value) {
        pending.insert(key);jobs.append(Job(key:key,generation:generation,source:source,work:work,onReady:onReady));startJobs()
    }
    private func signature(_ url:URL?)->String {
        guard let url,let attributes=try? FileManager.default.attributesOfItem(atPath:url.path) else{return "missing"}
        return "\(attributes[.size] ?? 0):\(attributes[.modificationDate] ?? Date.distantPast)"
    }
    private func startJobs() {
        while tasks.count<2,!jobs.isEmpty {
            let job=jobs.removeFirst(),id=UUID()
            tasks[id]=Task.detached(priority:.utility){[weak self] in
                let value=await job.work()
                guard let cache=self else{return}
                await MainActor.run {
                    cache.tasks.removeValue(forKey:id)
                    if cache.generation==job.generation {
                        cache.pending.remove(job.key)
                        switch value {
                        case .image(let image):
                            if let image {cache.failed[job.key]=nil;cache.images.setObject(image,forKey:job.key as NSString,cost:max(1,Int(image.size.width*image.size.height)*4))}
                            else {
                                let attempts=(cache.failed[job.key]?.attempts ?? 0)+1,delay=Double(attempts*attempts)
                                if cache.failed.count>=1024 {cache.failed.removeAll()}
                                cache.failed[job.key]=Failure(signature:cache.signature(job.source),attempts:attempts,retryAfter:ProcessInfo.processInfo.systemUptime+delay)
                                if attempts<3 {
                                    DispatchQueue.main.asyncAfter(deadline:.now()+delay){[weak cache] in
                                        guard let cache,cache.generation==job.generation,cache.failed[job.key]?.attempts==attempts else{return}
                                        cache.revision+=1
                                    }
                                }
                            }
                        case .waveform(let values):cache.envelopes.setObject(Waveform(values),forKey:job.key as NSString,cost:values.count*MemoryLayout<Double>.stride)
                        }
                        cache.revision+=1;job.onReady()
                    }
                    cache.startJobs()
                }
            }
            peakConcurrentRequests=max(peakConcurrentRequests,tasks.count)
        }
    }
    func thumbnail(asset:MediaAsset,directory:URL,time:Double,limitMB:Int,onReady:@escaping()->Void)->NSImage? {
        images.totalCostLimit=max(16,limitMB)*1024*1024
        let original=directory.appendingPathComponent("Media").appendingPathComponent(asset.file)
        let proxy=asset.proxyFile.map{directory.appendingPathComponent("Media").appendingPathComponent($0)}
        let url=proxy.flatMap{FileManager.default.fileExists(atPath:$0.path) ? $0:nil} ?? original
        let sample=(time*4).rounded()/4,key=url.path+"@\(asset.kind == .image ? 0:sample)"
        if let image=images.object(forKey:key as NSString){return image}
        if let failure=failed[key] {
            if failure.signature != signature(url) {failed[key]=nil}
            else if failure.attempts>=3 || ProcessInfo.processInfo.systemUptime<failure.retryAfter {return nil}
        }
        guard !pending.contains(key),pending.count<64 else {return nil}
        enqueue(key,source:url,onReady:onReady) {
            guard !Task.isCancelled else{return .image(nil)}
            let image:NSImage? = autoreleasepool {
                if let document=asset.psd {
                    return PSDRenderer().image(asset:asset,state:.initial(document),directory:directory,speaking:false,time:0,maximumSize:CGSize(width:128,height:128))
                }
                if asset.kind == .image {
                    if let source=CGImageSourceCreateWithURL(url as CFURL,nil),let cg=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:128,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary) {
                        return NSImage(cgImage:cg,size:CGSize(width:cg.width,height:cg.height))
                    }
                    // AppKit also supports vector formats such as SVG/PDF.
                    guard let source=NSImage(contentsOf:url),source.size.width>0,source.size.height>0 else{return nil}
                    let scale=min(1,128/source.size.width,128/source.size.height)
                    let size=CGSize(width:source.size.width*scale,height:source.size.height*scale)
                    guard let context=RasterTools.bitmap(size) else{return nil}
                    let previous=NSGraphicsContext.current
                    NSGraphicsContext.current=NSGraphicsContext(cgContext:context,flipped:false)
                    defer{NSGraphicsContext.current=previous}
                    source.draw(in:CGRect(origin:.zero,size:size))
                    return context.makeImage().map{NSImage(cgImage:$0,size:size)}
                }
                let generator=AVAssetImageGenerator(asset:AVURLAsset(url:url));generator.maximumSize=CGSize(width:128,height:74);generator.appliesPreferredTrackTransform=true
                return (try? generator.copyCGImage(at:CMTime(seconds:max(0,min(max(0,asset.duration-0.02),sample)),preferredTimescale:600),actualTime:nil)).map{NSImage(cgImage:$0,size:CGSize(width:$0.width,height:$0.height))}
            }
            return .image(image)
        }
        return nil
    }
    func envelope(asset:MediaAsset,directory:URL,onReady:@escaping()->Void)->[Double]? {
        if let envelope=asset.envelope {return envelope}
        let url=directory.appendingPathComponent("Media").appendingPathComponent(asset.file),key="wave:"+url.path
        if let values=envelopes.object(forKey:key as NSString){return values.values};guard !pending.contains(key),pending.count<64 else{return nil}
        enqueue(key,onReady:onReady) {
            guard !Task.isCancelled else{return .waveform([])}
            var scratch:URL?
            let values:[Double]
            if let direct=try? audioEnvelope(url:url){values=direct} else if Task.isCancelled {values=[]} else {
                let target=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-wave-\(UUID()).caf");scratch=target
                if (try? await AudioProcessor.decode(source:url,destination:target)) == true {values=(try? audioEnvelope(url:target)) ?? []} else {values=[]}
            }
            if let scratch{try? FileManager.default.removeItem(at:scratch)}
            return .waveform(values)
        }
        return nil
    }
}
