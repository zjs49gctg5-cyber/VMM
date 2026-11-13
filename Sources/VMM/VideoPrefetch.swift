import AVFoundation
import Foundation

/// At most two decoding jobs. Callbacks own no editor state; stale generations
/// cannot populate the byte-bounded cache after a project or directory switch.
final class VideoPrefetch {
    private let lock=NSLock()
    private let cache=RenderCache<CGImage>(budget:32*1024*1024)
    private var jobs:[String:AVAssetImageGenerator]=[:]
    private var generation=UUID()
    var bytes:Int {lock.lock();defer{lock.unlock()};return cache.bytes}
    var pendingCount:Int {lock.lock();defer{lock.unlock()};return jobs.count}
    private func key(_ path:URL,_ size:CGSize,_ time:CMTime)->String {"\(path.path):\(size.width)x\(size.height):\(time.convertScale(600,method:.default).value)"}
    func setBudget(_ bytes:Int){lock.lock();cache.budget=max(0,bytes);lock.unlock()}
    func clear() {
        lock.lock();generation=UUID();cache.clear();let old=Array(jobs.values);jobs.removeAll();lock.unlock()
        old.forEach{$0.cancelAllCGImageGeneration()}
    }
    deinit {jobs.values.forEach{$0.cancelAllCGImageGeneration()}}
    func image(path:URL,size:CGSize,time:CMTime)->CGImage? {
        lock.lock();defer{lock.unlock()};return cache.value(key(path,size,time))
    }
    func request(path:URL,size:CGSize,times:[CMTime]) {
        lock.lock()
        let jobKey="\(path.path):\(size.width)x\(size.height)"
        // Bound in-flight decoded pixel memory as well as retained images.
        guard jobs.count<2,jobs[jobKey]==nil,Int(size.width*size.height)*4*4<=cache.budget else{lock.unlock();return}
        var seen=Set<String>()
        let missing=times.filter{let k=key(path,size,$0);return seen.insert(k).inserted && cache.value(k)==nil}
        guard !missing.isEmpty else{lock.unlock();return}
        let token=generation,generator=AVAssetImageGenerator(asset:AVURLAsset(url:path))
        generator.appliesPreferredTrackTransform=true;generator.maximumSize=size
        generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
        jobs[jobKey]=generator;lock.unlock()
        var remaining=missing.count
        generator.generateCGImagesAsynchronously(forTimes:missing.map{NSValue(time:$0)}) {[weak self] requested,image,_,result,_ in
            guard let self else{return}
            self.lock.lock();defer{self.lock.unlock()}
            guard self.generation==token else{return}
            if result == .succeeded,let image{self.cache.insert(image,key:self.key(path,size,requested),bytes:image.bytesPerRow*image.height)}
            remaining-=1;if remaining==0{self.jobs.removeValue(forKey:jobKey)}
        }
    }
}
