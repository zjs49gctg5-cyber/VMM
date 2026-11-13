import Foundation
import CoreGraphics

enum VideoStabilizer {
    static func validateSource(_ source:Clip,project:Project,strength:Double,smoothing:Double,zoom:Double)throws {
        guard source.kind == .video,source.assetID != nil,project.fps>0,
              strength.isFinite,(0...1).contains(strength),smoothing.isFinite,(0.05...3).contains(smoothing),zoom.isFinite,(1...2).contains(zoom) else {throw VMMError.message("手ぶれ補正の対象または設定が不正です。")}
        guard source.transform?.perspective != true,source.spatialAnimation == nil,
              !(source.animation?.tracks.contains(where:{[.x,.y].contains($0.property) && !$0.keys.isEmpty}) ?? false) else{throw VMMError.message("透視変形・移動パス・位置キーがある動画には適用できません。")}
        guard zoom == 1 || !(source.animation?.tracks.contains(where:{$0.property == .scale && !$0.keys.isEmpty}) ?? false) else{throw VMMError.message("倍率キーがある動画は手ぶれ補正の拡大を使えません。")}
        guard AnimatedProperty.scale.range.contains(source.scale*zoom) else{throw VMMError.message("補正後の倍率が設定範囲を超えます。")}
    }
    /// Suppresses the high-frequency movement of a tracked point. Translation is
    /// computed in the video's parent coordinates, so parent motion is preserved.
    static func applying(_ result:MotionTrackingResult,to source:Clip,project:Project,strength:Double,smoothing:Double,zoom:Double)throws->Clip {
        try result.validated()
        try validateSource(source,project:project,strength:strength,smoothing:smoothing,zoom:zoom)
        guard result.assetID==source.assetID else{throw VMMError.message("手ぶれ補正の対象または設定が不正です。")}
        if let lost=result.lostAt {throw VMMError.message(String(format:L("%.3f秒で追跡を失ったため補正を適用できません。追跡範囲や解析区間を変更してください。"),lost))}
        let fps=Double(project.fps),first=Int(ceil(source.start*fps-1e-8)),last=Int(ceil(source.end*fps-1e-8))-1
        guard first<=last else{throw VMMError.message("補正範囲が短すぎます。")}
        var byFrame:[Int:TrackingSample]=[:]
        for sample in result.samples {
            guard sample.time>=0,sample.time<=source.duration+1e-6 else{throw VMMError.message("追跡結果が動画の範囲外です。")}
            let frame=min(last,max(first,Int(((source.start+sample.time)*fps).rounded())))
            if byFrame[frame] == nil || sample.confidence>(byFrame[frame]?.confidence ?? 0) {byFrame[frame]=sample}
        }
        let frames=byFrame.keys.sorted()
        guard frames.count>=2 else{throw VMMError.message("補正範囲が短すぎます。")}
        let samples=frames.compactMap{byFrame[$0]},fit=min(Double(project.width)/result.frameWidth,Double(project.height)/result.frameHeight)
        let width=result.frameWidth*fit,height=result.frameHeight*fit
        func center(_ sample:TrackingSample)->CGPoint {CGPoint(x:sample.x+sample.width/2,y:sample.y+sample.height/2)}
        var corrected=source;corrected.scale *= zoom
        guard AnimatedProperty.scale.range.contains(corrected.scale) else{throw VMMError.message("補正後の倍率が設定範囲を超えます。")}
        var xKeys:[AnimationKeyframe]=[],yKeys:[AnimationKeyframe]=[]
        for index in samples.indices {
            let sample=samples[index],point=center(sample)
            var total=0.0,averageX=0.0,averageY=0.0
            for other in samples {
                let weight=max(0,1-abs(other.time-sample.time)/smoothing)
                if weight>0 {let p=center(other);total+=weight;averageX+=p.x*weight;averageY+=p.y*weight}
            }
            guard total>0 else{throw VMMError.message("追跡結果が不正です。")}
            let dx=Double(point.x-averageX/total)*width,dy=Double(point.y-averageY/total)*height
            let world=Double(frames[index])/fps,shown=corrected.animated(at:world,aspectRatio:Double(project.width)/Double(project.height)),matrix=shown.objectMatrix(project:project,canvasInput:false)
            let x=source.x-strength*(matrix.a*dx+matrix.c*dy)/Double(project.width)
            let y=source.y-strength*(matrix.b*dx+matrix.d*dy)/Double(project.height)
            guard AnimatedProperty.x.range.contains(x),AnimatedProperty.y.range.contains(y) else{throw VMMError.message("補正位置が設定範囲を超えます。強さを下げてください。")}
            let t=corrected.motionTime(at:world)
            xKeys.append(AnimationKeyframe(time:t,value:x,easing:.linear));yKeys.append(AnimationKeyframe(time:t,value:y,easing:.linear))
        }
        var animation=corrected.animation ?? ClipAnimation()
        for (property,keys) in [(AnimatedProperty.x,xKeys),(.y,yKeys)] {
            if let index=animation.tracks.firstIndex(where:{$0.property==property}) {animation.tracks[index].keys=keys;animation.tracks[index].enabled=true}
            else {animation.tracks.append(AnimationTrack(property:property,keys:keys))}
        }
        corrected.animation=animation;try corrected.validateAnimation();return corrected
    }
}
