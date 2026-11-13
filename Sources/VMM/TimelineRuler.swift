import Foundation

/// Integer frames avoid drifting ticks and keep subsecond labels frame accurate.
struct TimelineRuler {
    static let zoomRange:ClosedRange<Double> = 4...1200
    let fps:Int
    let majorFrames:Int
    let minorFrames:Int
    init(zoom:Double,fps:Int,textSize:Double) {
        let rate=max(1,fps)
        self.fps=rate
        let spacing=max(90,110*textSize/12)
        let candidates=[1,2,3,5,6,10,12,15,20,30].filter{$0<rate} + [1,2,5,10,15,30,60,120,300,600,1800,3600,7200,14400,86400].map{$0*rate}
        let major=candidates.first{Double($0)*zoom/Double(rate)>=spacing} ?? candidates.last!
        majorFrames=major
        minorFrames=[10,6,5,4,3,2].first{major % $0 == 0 && Double(major/$0)*zoom/Double(rate)>=8}.map{major/$0} ?? major
    }
    func ticks(from start:Double,to end:Double)->[Int] {
        let first=max(0,Int(floor(max(0,start)*Double(fps)/Double(minorFrames)))*minorFrames)
        let last=max(first,Int(ceil(max(0,end)*Double(fps))))
        return Array(stride(from:first,through:last,by:minorFrames))
    }
    func label(frame:Int)->String {
        let seconds=frame/fps,subframe=frame % fps
        if majorFrames<fps {return String(format:"%02d:%02d:%02d:%02d",seconds/3600,seconds/60 % 60,seconds % 60,subframe)}
        if seconds>=3600 {return String(format:"%02d:%02d:%02d",seconds/3600,seconds/60 % 60,seconds % 60)}
        return String(format:"%02d:%02d",seconds/60,seconds % 60)
    }
}
