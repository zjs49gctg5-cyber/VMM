import AppKit

struct PreviewQuality:Equatable {
    var level:Int
    static let maximumLevel=6
    var resolution:Double {[1,1,0.85,0.7,0.55,0.4,0.3][level]}
    var particles:Double {[1,0.75,0.5,0.35,0.25,0.25,0.25][level]}
    func targetFPS(_ projectFPS:Int)->Double {
        let fps=Double(max(1,projectFPS))
        return min(fps,max(12,fps*[1,1,0.85,0.7,0.6,0.5,0.5][level]))
    }
    func rasterSize(display:CGSize,project:Project,playing:Bool,adaptive:Bool,minimumLongEdge:Double=720)->CGSize {
        let native=max(display.width,display.height)
        guard native>0 else {return .zero}
        let base=min(1,Double(max(project.width,project.height))/native)
        let detail=playing && adaptive ? max(resolution,min(1,minimumLongEdge/max(1,native*base))):1
        return CGSize(width:max(1,(display.width*base*detail).rounded()),height:max(1,(display.height*base*detail).rounded()))
    }
}
struct PreviewLoadController {
    private(set) var quality=PreviewQuality(level:0)
    private(set) var averageMS:Double=0
    private var samples:[Double]=[]
    private var overloaded=0
    private var comfortable=0
    mutating func reset() {self=PreviewLoadController()}
    mutating func record(milliseconds:Double,fps:Int,observedFPS:Double?=nil,higherResolutionCost:Double?=nil) {
        guard milliseconds.isFinite,milliseconds>=0 else {return}
        samples.append(milliseconds);if samples.count>9 {samples.removeFirst()}
        let sorted=samples.sorted(),median=sorted[sorted.count/2]
        averageMS=samples.count<5 ? median:averageMS*0.7+median*0.3
        guard samples.count>=5 else {return} // Warm-up and individual slow frames do not lower quality.
        let target=quality.targetFPS(fps),budget=1000/target*0.85
        if averageMS>budget {
            overloaded+=1;comfortable=0
            if quality.level<PreviewQuality.maximumLevel && overloaded>=max(4,Int(target*0.25)) {
                quality.level+=1;overloaded=0;samples=[];averageMS=0
            }
        } else {
            overloaded=0
            guard quality.level>0 else {comfortable=0;return}
            let higher=PreviewQuality(level:quality.level-1)
            let pixels=higherResolutionCost ?? pow(higher.resolution/quality.resolution,2)
            let estimated=averageMS*max(pixels,higher.particles/quality.particles)*1.1
            let nextBudget=1000/higher.targetFPS(fps)*0.85
            let cadenceOK=observedFPS.map{$0>=target*0.85} ?? true
            if estimated<nextBudget*0.8 && cadenceOK {comfortable+=1} else {comfortable=0}
            if comfortable>=max(12,Int(target*0.75)) {
                quality=higher;comfortable=0;samples=[];averageMS=0
            }
        }
    }
}
struct PreviewPerformance:Equatable {
    var milliseconds:Double
    var fps:Double
    var resolutionPercent:Int
    var particlePercent:Int
    var targetFPS:Double=30
    var cacheUsage:RenderCacheUsage?
    var label:String {
        "\(Int(fps.rounded())) fps · \(resolutionPercent)%"
    }
    var detail:String {
        "\(L("描画")) \(String(format:"%.1f",milliseconds)) ms · \(L("目標FPS")) \(Int(targetFPS.rounded())) · \(L("パーティクル")) \(particlePercent)%" + (cacheUsage.map{" · "+$0.detail} ?? "")
    }
}
/// The queue owns its renderer; no AppKit view or editor state is accessed on it.
private final class PreviewRenderWorker {
    let queue=DispatchQueue(label:"app.vmm.preview.render",qos:.userInitiated)
    let renderer:FrameRenderer
    init(renderer:FrameRenderer=FrameRenderer()){self.renderer=renderer}
}
final class PreviewNSView:NSView {
    private struct Request {
        let project:Project
        let directory:URL
        let time:Double
        let playing:Bool
        let adaptive:Bool
        let minimumLongEdge:Double
        let display:CGSize
        let configuration:Int
    }
    private let worker:PreviewRenderWorker
    override init(frame frameRect:NSRect = .zero){worker=PreviewRenderWorker();super.init(frame:frameRect)}
    init(frame frameRect:NSRect,renderer:FrameRenderer){worker=PreviewRenderWorker(renderer:renderer);super.init(frame:frameRect)}
    required init?(coder:NSCoder){worker=PreviewRenderWorker();super.init(coder:coder)}
    private weak var store:EditorStore?
    private var project=Project()
    private var directory=URL(fileURLWithPath:"/tmp")
    private var time:Double=0
    private var playing=false
    private var adaptive=true
    private var minimumLongEdge:Double=720
    private var cacheMB=256
    private var configuration=0
    private var inFlight=false
    private var pending=false
    private var image:CGImage?
    private var load=PreviewLoadController()
    private var lastStatsTime:Double=0
    private var presentations:[Double]=[]
    private var lastRenderStart:Double=0
    private var wake:DispatchWorkItem?
    private var lastDisplay=CGSize.zero
    private var finishedFrames=0
    // Internal counters support tests for bounded work and stale-frame rejection.
    var rendering:Bool {inFlight}
    var displayedTime:Double?
    var presentedFrames:Int {finishedFrames}
    var renderedImage:CGImage? {image}
    private(set) var renderingFailure:String?

    func update(store:EditorStore) {
        self.store=store;self.cacheMB=store.settings.cacheMB
        update(project:store.project,directory:store.directory,time:store.playhead,playing:store.playing,adaptive:store.settings.adaptivePreview ?? true,minimumLongEdge:store.settings.previewMinimumLongEdge ?? 720)
    }
    func update(project:Project,directory:URL,time:Double,playing:Bool,adaptive:Bool,minimumLongEdge:Double=720) {
        let changed=self.project != project || self.directory != directory || self.playing != playing || self.adaptive != adaptive || self.minimumLongEdge != minimumLongEdge
        guard changed || self.time != time || image == nil else {return}
        if changed {
            configuration+=1;load.reset();presentations=[];lastRenderStart=0;wake?.cancel();wake=nil
            renderingFailure=nil
            if self.directory != directory || self.project.width != project.width || self.project.height != project.height {image=nil}
        }
        self.project=project;self.directory=directory;self.time=time;self.playing=playing;self.adaptive=adaptive;self.minimumLongEdge=minimumLongEdge
        pending=true;refreshSize();schedule()
    }
    override func setFrameSize(_ newSize:NSSize) {
        super.setFrameSize(newSize)
        refreshSize()
    }
    override func viewDidMoveToWindow() {super.viewDidMoveToWindow();refreshSize()}
    override func viewDidChangeBackingProperties() {super.viewDidChangeBackingProperties();refreshSize()}
    private func refreshSize() {
        let scale=window?.backingScaleFactor ?? 1
        let display=CGSize(width:bounds.width*scale,height:bounds.height*scale)
        guard display != lastDisplay else {return}
        lastDisplay=display;configuration+=1;pending=true;schedule()
    }
    private func schedule() {
        guard !inFlight,pending,lastDisplay.width>0,lastDisplay.height>0 else {return}
        let now=ProcessInfo.processInfo.systemUptime
        if playing && adaptive {
            let delay=lastRenderStart+1/load.quality.targetFPS(project.fps)-now
            if delay>0.001 {
                if wake == nil {
                    let item=DispatchWorkItem{[weak self] in self?.wake=nil;self?.schedule()}
                    wake=item;DispatchQueue.main.asyncAfter(deadline:.now()+delay,execute:item)
                }
                return
            }
        }
        wake?.cancel();wake=nil;lastRenderStart=now
        pending=false;inFlight=true
        let request=Request(project:project,directory:directory,time:time,playing:playing,adaptive:adaptive,minimumLongEdge:minimumLongEdge,display:lastDisplay,configuration:configuration)
        let quality=load.quality
        let size=quality.rasterSize(display:request.display,project:request.project,playing:request.playing,adaptive:request.adaptive,minimumLongEdge:request.minimumLongEdge)
        let worker=self.worker,cacheMB=self.cacheMB
        worker.queue.async { [weak self] in
            worker.renderer.setCacheBudget(megabytes:cacheMB)
            let start=ProcessInfo.processInfo.systemUptime
            let frame:CGImage?=autoreleasepool {
                guard let context=RasterTools.bitmap(size) else {return nil}
                worker.renderer.previewPlaying=request.playing
                worker.renderer.previewParticleDetail=request.playing && request.adaptive ? quality.particles:1
                worker.renderer.draw(project:request.project,directory:request.directory,time:request.time,context:context,size:size)
                return context.makeImage()
            }
            let elapsed=(ProcessInfo.processInfo.systemUptime-start)*1000,cacheUsage=worker.renderer.cacheUsage,failure=worker.renderer.renderingFailure
            DispatchQueue.main.async { [weak self] in
                guard let self else {return}
                self.inFlight=false
                let current=request.configuration==self.configuration && (self.playing || request.time==self.time)
                if current {self.renderingFailure=failure;self.needsDisplay=true}
                if current,let frame {
                    self.image=frame;self.displayedTime=request.time;self.finishedFrames+=1;self.needsDisplay=true
                    let now=ProcessInfo.processInfo.systemUptime
                    self.presentations.append(now)
                    self.presentations.removeAll{$0<now-1.5}
                    let cadence=self.presentations.count>1 ? Double(self.presentations.count-1)/max(0.001,now-self.presentations[0]):Double(request.project.fps)
                    if request.playing && request.adaptive {
                        let higher=PreviewQuality(level:max(0,quality.level-1)).rasterSize(display:request.display,project:request.project,playing:true,adaptive:true,minimumLongEdge:request.minimumLongEdge)
                        self.load.record(milliseconds:(now-start)*1000,fps:request.project.fps,observedFPS:cadence,higherResolutionCost:pow(higher.width/size.width,2))
                    }
                    if request.playing && now-self.lastStatsTime>0.5 {
                        self.store?.previewPerformance=PreviewPerformance(milliseconds:elapsed,fps:min(Double(request.project.fps),cadence,1000/max(0.01,elapsed)),resolutionPercent:Int(100*size.width/max(1,quality.rasterSize(display:request.display,project:request.project,playing:request.playing,adaptive:false).width)),particlePercent:Int(quality.particles*100),targetFPS:request.adaptive ? quality.targetFPS(request.project.fps):Double(request.project.fps),cacheUsage:cacheUsage)
                        self.lastStatsTime=now
                    }
                }
                self.schedule()
            }
        }
    }
    override var isOpaque:Bool {true}
    override func draw(_ dirtyRect:NSRect) {
        refreshSize()
        guard let context=NSGraphicsContext.current?.cgContext else {return}
        context.saveGState();defer{context.restoreGState()};context.setAlpha(1);context.setBlendMode(.normal)
        context.setFillColor(NSColor(hex:project.background).cgColor);context.fill(bounds)
        if let image {context.interpolationQuality = .high;context.draw(image,in:bounds)}
        if let failure=renderingFailure {
            let message=L("プレビュー描画に失敗しました。")+"\n"+L(failure)
            let paragraph=NSMutableParagraphStyle();paragraph.alignment = .center
            let attributes:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:14,weight:.semibold),.foregroundColor:NSColor.white,.paragraphStyle:paragraph]
            let box=CGRect(x:12,y:12,width:max(0,bounds.width-24),height:min(90,max(0,bounds.height-24)))
            NSColor.black.withAlphaComponent(0.85).setFill();NSBezierPath(roundedRect:box,xRadius:6,yRadius:6).fill()
            message.draw(in:box.insetBy(dx:8,dy:8),withAttributes:attributes)
        }
    }
}
