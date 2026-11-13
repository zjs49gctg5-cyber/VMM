import Foundation

extension Clip {
    var motionStart:Double {animationTimeOffset}
    var motionEnd:Double {motionStart+duration}
    var motionProperties:[AnimatedProperty] {
        let basic:[AnimatedProperty]=kind == .audio ? [.volume] : kind == .adjustment ? [.x,.y,.regionWidth,.regionHeight,.opacity,.rotation] : [.x,.y,.scale,.opacity,.rotation]
        return basic.filter{availableAnimatedProperties.contains($0)}
    }
    var motionBoundaries:[Double] {
        Array(Set([motionStart,motionEnd]+(animation?.tracks ?? []).flatMap(\.keys).map(\.time).filter{$0>motionStart && $0<motionEnd})).sorted()
    }
    func motionValue(_ property:AnimatedProperty,at time:Double)->Double {
        let track=animation?.tracks.first{$0.property==property}
        return min(property.range.upperBound,max(property.range.lowerBound,interpolate(track?.keys ?? [],at:time,fallback:property.get(self))))
    }
    mutating func putMotionKey(_ property:AnimatedProperty,time:Double,value:Double,easing:Easing?=nil) {
        var a=animation ?? ClipAnimation(),track=a.tracks.first{$0.property==property} ?? AnimationTrack(property:property)
        if let i=track.keys.firstIndex(where:{abs($0.time-time)<0.000001}) {track.keys[i].value=value;if let easing {track.keys[i].easing=easing;track.keys[i].customCurve=nil}}
        else {track.keys.append(AnimationKeyframe(time:time,value:value,easing:easing ?? .easeInOut))}
        track.keys.sort{$0.time<$1.time}
        if let i=a.tracks.firstIndex(where:{$0.property==property}){a.tracks[i]=track}else{a.tracks.append(track)}
        animation=a
    }
    /// Record only manipulated properties at the current time, preserving the
    /// original path and any independent motions on every other frame.
    func recordingPreviewChange(_ candidate:Clip,at time:Double)->Clip {
        var result=self
        if var path=spatialAnimation,let candidatePath=candidate.spatialAnimation {
            let before=path.sample(at:time).point,after=candidatePath.sample(at:time).point
            if hypot(before.x-after.x,before.y-after.y)>0.000001 {
                if let i=path.keys.firstIndex(where:{abs($0.time-time)<0.000001}){path.keys[i].point=after}
                else{path.keys.append(SpatialKey(time:time,point:after));path.keys.sort{$0.time<$1.time}}
                result.spatialAnimation=path
            }
        }
        for property in availableAnimatedProperties where spatialAnimation == nil || ![.x,.y].contains(property) {
            let active=animation?.tracks.first{$0.property==property}?.enabled == true
            let before=active ? motionValue(property,at:time):property.get(self),after=active ? candidate.motionValue(property,at:time):property.get(candidate)
            if abs(before-after)>0.000001 {
                if result.animation?.tracks.first(where:{$0.property==property}) == nil {
                    result.putMotionKey(property,time:motionStart,value:property.get(self))
                    result.putMotionKey(property,time:motionEnd,value:property.get(self))
                }
                result.putMotionKey(property,time:time,value:after)
                if let i=result.animation?.tracks.firstIndex(where:{$0.property==property}){result.animation?.tracks[i].enabled=true}
            }
        }
        return result
    }
}

@MainActor extension EditorStore {
    private func motionPlaybackRange(_ clip:Clip,from:Double,to:Double,loop:Bool)->TimelineRange {
        TimelineRange(start:loop ? clip.start+from-clip.motionStart:clip.start,
                      end:loop ? clip.start+to-clip.motionStart:clip.end,loop:loop)
    }
    func setMotionPlaybackLoop(_ enabled:Bool,clipID:UUID,from:Double,to:Double){
        guard animationPlaybackRange != nil,let clip=project.clips.first(where:{$0.id==clipID}),to>from else{return}
        animationPlaybackRange=motionPlaybackRange(clip,from:from,to:to,loop:enabled)
    }

    func toggleMotionPlayback(_ id:UUID,from:Double,to:Double,loop:Bool){
        guard !busy,let c=project.clips.first(where:{$0.id==id}),to>from else{return}
        if playing{pause();return}
        let range=motionPlaybackRange(c,from:from,to:to,loop:loop)
        if playhead<range.start || playhead>=range.end{seek(range.start)}
        animationPlaybackRange=range;play()
    }

    func mutateMotion(_ id:UUID,_ change:(inout Clip)throws->Void)throws {
        guard !busy,let clip=project.clips.first(where:{$0.id==id}),!project.tracks[clip.track].locked else{throw VMMError.message("レイヤーがロックされているか、処理中です。")}
        var value=clip;try change(&value);var candidate=project
        candidate.clips[candidate.clips.firstIndex(where:{$0.id==id})!]=value;_=try candidate.validated()
        if value != clip {edit(id){$0=value}}
    }
    func setMotionValue(_ id:UUID,property:AnimatedProperty,time:Double,value:Double,easing:Easing?=nil)throws {
        try mutateMotion(id){c in
            guard c.availableAnimatedProperties.contains(property),time.isFinite,time>=c.motionStart,time<=c.motionEnd,value.isFinite,property.range.contains(value) else{throw VMMError.message("キーフレームの設定が不正です。")}
            if c.animation?.tracks.first(where:{$0.property==property}) == nil {
                c.putMotionKey(property,time:c.motionStart,value:property.get(c))
                c.putMotionKey(property,time:c.motionEnd,value:property.get(c))
            }
            c.putMotionKey(property,time:time,value:value,easing:easing)
        }
    }
    func setMotionCurve(_ id:UUID,property:AnimatedProperty,time:Double,end:Double?=nil,curve:EasingCurve?)throws {
        try mutateMotion(id){c in
            guard c.availableAnimatedProperties.contains(property),time.isFinite,time>=c.motionStart,time<c.motionEnd,curve?.isValid ?? true else{throw VMMError.message("カーブの設定が不正です。")}
            let endTime=end ?? c.animation?.tracks.first{$0.property==property}?.keys.sorted{$0.time<$1.time}.first{$0.time>time}?.time ?? c.motionEnd
            guard endTime.isFinite,endTime>time,endTime<=c.motionEnd else{throw VMMError.message("カーブの設定が不正です。")}
            let startValue=c.motionValue(property,at:time),endValue=c.motionValue(property,at:endTime)
            if c.animation?.tracks.first(where:{$0.property==property}) == nil {
                c.putMotionKey(property,time:c.motionStart,value:property.get(c));c.putMotionKey(property,time:c.motionEnd,value:property.get(c))
            }
            if !(c.animation?.tracks.first{$0.property==property}?.keys.contains{abs($0.time-endTime)<0.000001} ?? false){c.putMotionKey(property,time:endTime,value:endValue)}
            c.putMotionKey(property,time:time,value:startValue)
            if let i=c.animation?.tracks.firstIndex(where:{$0.property==property}),let j=c.animation?.tracks[i].keys.firstIndex(where:{abs($0.time-time)<0.000001}) {c.animation?.tracks[i].keys[j].customCurve=curve;if curve != nil{c.animation?.tracks[i].enabled=true}}
        }
    }
    @discardableResult func insertMotionPoint(_ id:UUID,at time:Double,property:AnimatedProperty?=nil)throws->Double {
        var inserted=time
        try mutateMotion(id){c in
            guard time.isFinite else{throw VMMError.message("キーフレームの設定が不正です。")}
            inserted=min(c.motionEnd,max(c.motionStart,(time*Double(project.fps)).rounded()/Double(project.fps)))
            let properties=property.map{[$0]} ?? Array(Set(c.motionProperties+(c.animation?.tracks.map(\.property) ?? [])))
            guard properties.allSatisfy({c.availableAnimatedProperties.contains($0)}) else{throw VMMError.message("キーフレームの設定が不正です。")}
            let values=properties.map{($0,c.motionValue($0,at:inserted))}
            for (p,v) in values where !(c.animation?.tracks.first{$0.property==p}?.keys.contains{abs($0.time-inserted)<0.000001} ?? false){c.putMotionKey(p,time:inserted,value:min(p.range.upperBound,max(p.range.lowerBound,v)))}
        };return inserted
    }
    @discardableResult func moveMotionPoint(_ id:UUID,from:Double,to:Double,property:AnimatedProperty?=nil)throws->Double {
        var moved=to
        try mutateMotion(id){c in
            guard from>c.motionStart,from<c.motionEnd,to.isFinite,to>c.motionStart,to<c.motionEnd else{throw VMMError.message("開始・終了点は移動できません。")}
            let t=(to*Double(project.fps)).rounded()/Double(project.fps);moved=t
            guard t>c.motionStart,t<c.motionEnd else{throw VMMError.message("開始・終了点は移動できません。")}
            for i in c.animation?.tracks.indices ?? 0..<0 where property == nil || c.animation!.tracks[i].property==property {
                let keys=c.animation!.tracks[i].keys
                guard keys.contains(where:{abs($0.time-from)<0.000001}) else{continue}
                guard !keys.contains(where:{abs($0.time-from)>=0.000001 && abs($0.time-t)<0.000001}) else{throw VMMError.message("同じ時刻に中間点があります。")}
                for j in keys.indices where abs(keys[j].time-from)<0.000001{c.animation!.tracks[i].keys[j].time=t}
                c.animation!.tracks[i].keys.sort{$0.time<$1.time}
            }
        };return moved
    }
    func deleteMotionPoint(_ id:UUID,at time:Double,property:AnimatedProperty?=nil)throws {
        try mutateMotion(id){c in
            guard time>c.motionStart,time<c.motionEnd else{throw VMMError.message("開始・終了点は削除できません。")}
            for i in c.animation?.tracks.indices ?? 0..<0 where property == nil || c.animation!.tracks[i].property==property {c.animation!.tracks[i].keys.removeAll{abs($0.time-time)<0.000001}}
        }
    }
    @discardableResult func duplicateMotionPoint(_ id:UUID,at time:Double,property:AnimatedProperty?=nil)throws->Double {
        var target=time
        try mutateMotion(id){c in
            let step=1/Double(project.fps),occupied=c.motionBoundaries
            guard let t=(1...500).lazy.map({(time/step).rounded()*step+Double($0)*step}).first(where:{candidate in candidate<c.motionEnd && !occupied.contains(where:{abs($0-candidate)<0.000001})}) else{throw VMMError.message("中間点を配置する空きがありません。")}
            target=t
            let tracks=(c.animation?.tracks ?? []).filter{property == nil || $0.property==property}
            let matches=tracks.compactMap{track in track.keys.first(where:{abs($0.time-time)<0.000001}).map{(track.property,$0)}}
            if matches.isEmpty {
                for p in property.map({[$0]}) ?? c.motionProperties {c.putMotionKey(p,time:t,value:c.motionValue(p,at:time))}
            }else{for (p,key) in matches {c.putMotionKey(p,time:t,value:key.value,easing:key.easing);if let i=c.animation?.tracks.firstIndex(where:{$0.property==p}),let j=c.animation?.tracks[i].keys.firstIndex(where:{abs($0.time-t)<0.000001}){c.animation?.tracks[i].keys[j].customCurve=key.customCurve}}}
        };return target
    }
}
