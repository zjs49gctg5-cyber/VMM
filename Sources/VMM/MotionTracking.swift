import AVFoundation
import Vision
import AppKit

struct TrackingSample:Codable,Equatable {
    var time:Double
    /// Top-left-origin coordinates in the untransformed video frame.
    var x:Double;var y:Double;var width:Double;var height:Double;var confidence:Double
    var rect:CGRect{CGRect(x:x,y:y,width:width,height:height)}
}
struct MotionTrackingResult:Codable,Equatable {
    var assetID:UUID?
    var samples:[TrackingSample]
    var frameWidth:Double;var frameHeight:Double
    var lostAt:Double?
    func validated()throws {
        guard (2...498).contains(samples.count),frameWidth.isFinite,frameHeight.isFinite,(1...16384).contains(frameWidth),(1...16384).contains(frameHeight),Set(samples.map(\.time)).count==samples.count,samples.allSatisfy({s in s.time.isFinite && (0...86400).contains(s.time) && [s.x,s.y,s.width,s.height,s.confidence].allSatisfy{$0.isFinite} && (-0.1...1.1).contains(s.x) && (-0.1...1.1).contains(s.y) && (0.001...1).contains(s.width) && (0.001...1).contains(s.height) && (0...1).contains(s.confidence)}),lostAt.map({$0.isFinite && (0...86400).contains($0)}) ?? true else{throw VMMError.message("追跡結果が不正です。")}
    }
}
enum MotionTracker {
    static func thumbnail(url:URL,time:Double)throws->CGImage {
        let generator=AVAssetImageGenerator(asset:AVURLAsset(url:url));generator.appliesPreferredTrackTransform=true;generator.maximumSize=CGSize(width:960,height:960)
        return try generator.copyCGImage(at:CMTime(seconds:time,preferredTimescale:600),actualTime:nil)
    }
    static func analyze(url:URL,source:Clip,region:CGRect,from:Double,duration:Double,sampleRate:Double,progress:@escaping @Sendable (Double)->Void={_ in})throws->MotionTrackingResult {
        guard !source.hasTimeWarp else {throw VMMError.message("逆再生・可変速度の素材はモーショントラッキングに対応していません。")}
        guard source.kind == .video,region.minX>=0,region.minY>=0,region.maxX<=1,region.maxY<=1,region.width>=0.01,region.height>=0.01,from.isFinite,duration.isFinite,sampleRate.isFinite,from>=0,duration>=0.05,duration<=30,from+duration<=source.duration+0.000001,(1...30).contains(sampleRate) else{throw VMMError.message("動画内の追跡範囲と解析区間（最大30秒）を指定してください。")}
        let count=min(498,max(2,Int(ceil(duration*sampleRate))+1)),generator=AVAssetImageGenerator(asset:AVURLAsset(url:url));generator.appliesPreferredTrackTransform=true;generator.maximumSize=CGSize(width:960,height:960);generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
        let sequence=VNSequenceRequestHandler(),initial=VNDetectedObjectObservation(boundingBox:CGRect(x:region.minX,y:1-region.maxY,width:region.width,height:region.height)),request=VNTrackObjectRequest(detectedObjectObservation:initial);request.trackingLevel = .accurate
        var samples=[TrackingSample](),dimensions=CGSize.zero,lost:Double?
        for index in 0..<count {
            try Task.checkCancellation()
            let elapsed=min(source.duration-0.000001,from+duration*Double(index)/Double(count-1)),time=source.sourceOffset+elapsed*source.mediaRate
            let image=try generator.copyCGImage(at:CMTime(seconds:time,preferredTimescale:600),actualTime:nil);dimensions=CGSize(width:image.width,height:image.height)
            try sequence.perform([request],on:image)
            guard let observation=request.results?.first as? VNDetectedObjectObservation,observation.confidence>=0.3 else{lost=elapsed;break}
            let box=observation.boundingBox
            samples.append(TrackingSample(time:elapsed,x:box.minX,y:1-box.maxY,width:box.width,height:box.height,confidence:Double(observation.confidence)));request.inputObservation=observation;progress(Double(index+1)/Double(count))
        }
        guard samples.count>=2 else{throw VMMError.message("対象を追跡できませんでした。特徴のある範囲を広めに指定してください。")}
        let result=MotionTrackingResult(assetID:source.assetID,samples:samples,frameWidth:dimensions.width,frameHeight:dimensions.height,lostAt:lost);try result.validated();return result
    }
    @MainActor static func applying(_ result:MotionTrackingResult,to target:Clip,source:Clip,project:Project,followScale:Bool)throws->Clip {
        try result.validated();guard let first=result.samples.first,(target.supportsParent || target.kind == .adjustment),source.transform?.perspective != true else{throw VMMError.message("このアイテムの変形には追跡を適用できません。")}
        let geometry=PreviewGeometry(),fit=min(Double(project.width)/result.frameWidth,Double(project.height)/result.frameHeight),w=result.frameWidth*fit,h=result.frameHeight*fit
        func position(_ sample:TrackingSample)throws->(CGPoint,CGRect){let worldTime=source.start+sample.time,shown=source.animated(at:worldTime,aspectRatio:Double(project.width)/Double(project.height));guard let parent=geometry.parentTransform(source,project:project,time:worldTime),let targetParent=geometry.parentTransform(target,project:project,time:worldTime) else{throw VMMError.message("追跡対象の親座標を計算できません。")};let matrix=shown.objectMatrix(project:project,canvasInput:false).concatenating(parent).concatenating(targetParent.inverted()),rect=CGRect(x:(sample.x-0.5)*w,y:(sample.y-0.5)*h,width:sample.width*w,height:sample.height*h);return (CGPoint(x:rect.midX,y:rect.midY).applying(matrix),rect.applying(matrix))}
        var baseline=target;baseline.audioReactive=nil;baseline.animation?.entrance=Entrance();baseline.animation?.exit=Entrance();baseline.animation?.motions=[]
        let (origin,baseRect)=try position(first);var clip=target,keys=[SpatialKey]()
        for sample in result.samples {
            let worldTime=source.start+sample.time,time=target.motionTime(at:worldTime)
            guard worldTime>=target.start-0.000001,worldTime<=target.end+0.000001 else{throw VMMError.message("解析区間を配置先アイテムの時間内にしてください。")}
            let (point,rect)=try position(sample),base=baseline.animated(at:worldTime,aspectRatio:Double(project.width)/Double(project.height)),position=NormalizedPoint(x:base.x+(point.x-origin.x)/Double(project.width),y:base.y+(point.y-origin.y)/Double(project.height))
            keys.append(SpatialKey(time:time,point:position,incoming:NormalizedPoint(x:0,y:0),outgoing:NormalizedPoint(x:0,y:0),easing:.linear))
            if followScale {
                let ratio=max(0.01,min(20,sqrt(max(0.001,rect.width*rect.height)/max(0.001,baseRect.width*baseRect.height))))
                if target.kind == .adjustment {clip.putMotionKey(.regionWidth,time:time,value:min(4,max(0.001,(base.adjustmentRegion?.width ?? 0.3)*rect.width/max(0.001,baseRect.width))),easing:.linear);clip.putMotionKey(.regionHeight,time:time,value:min(4,max(0.001,(base.adjustmentRegion?.height ?? 0.3)*rect.height/max(0.001,baseRect.height))),easing:.linear)}
                else{clip.putMotionKey(.scale,time:time,value:min(20,max(0.001,base.scale*ratio)),easing:.linear)}
            }
        }
        // Zero-offset handles describe straight segments. Set thirds for constant velocity.
        for i in 0..<(keys.count-1){let dx=(keys[i+1].point.x-keys[i].point.x)/3,dy=(keys[i+1].point.y-keys[i].point.y)/3;keys[i].outgoing=NormalizedPoint(x:dx,y:dy);keys[i+1].incoming=NormalizedPoint(x:-dx,y:-dy)}
        clip.spatialAnimation=SpatialAnimation(keys:keys);clip.tracking=result;try clip.validateAnimation();return clip
    }
}
