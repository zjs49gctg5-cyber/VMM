import Foundation

/// Shared by preflight and the exporter so disabled/out-of-range material is treated identically.
struct ExportScope {
    let visual:Set<UUID>
    let audio:Set<UUID>
    var all:Set<UUID> {visual.union(audio)}
    init(project:Project,options:UserSettings) {
        let start=options.rangeStart,end=options.rangeEnd>0 ? min(options.rangeEnd,project.duration):project.duration
        let table=Dictionary(uniqueKeysWithValues:project.clips.map{($0.id,$0)})
        var owners:[UUID:[UUID]]=[:]
        for clip in project.clips {for member in clip.sceneMembers ?? [] {owners[member,default:[]].append(clip.id)}}
        func eligible(_ clip:Clip,audio:Bool,in range:Range<Double>)->Bool {
            var a=max(range.lowerBound,clip.start),b=min(range.upperBound,clip.end)
            var frontier=[clip.id],seen:Set<UUID>=[]
            while let id=frontier.popLast() {
                guard seen.insert(id).inserted,let current=table[id] else{continue}
                guard audio ? (!project.tracks[current.track].muted && current.audioDisabled != true):project.tracks[current.track].visible else{return false}
                a=max(a,current.start);b=min(b,current.end)
                if let parent=current.parentID {frontier.append(parent)}
                frontier+=owners[id] ?? []
            }
            return b>a
        }
        // For an invalid range still aggregate model/media diagnostics as before.
        let range=start<end ? start..<end:0..<max(1,project.duration)
        var visual:Set<UUID>=[],audio:Set<UUID>=[]
        for clip in project.clips {
            if clip.kind != .audio,eligible(clip,audio:false,in:range) {visual.insert(clip.id)}
            if [.audio,.speech,.video].contains(clip.kind),clip.audioDisabled != true,eligible(clip,audio:true,in:range) {audio.insert(clip.id)}
        }
        // A transition can read an outgoing frame preceding the requested export range.
        for transition in project.clips where transition.kind == .transition && visual.contains(transition.id) {
            let time=max(0,transition.start-1/Double(project.fps))
            let sample=time..<(time+0.000001)
            for clip in project.clips where clip.kind != .audio && eligible(clip,audio:false,in:sample) {visual.insert(clip.id)}
        }
        self.visual=visual;self.audio=audio
    }
    func assetIDs(in project:Project)->Set<UUID> {
        Set(project.clips.flatMap{clip->[UUID] in
            var ids:[UUID]=[]
            if audio.contains(clip.id) || (visual.contains(clip.id) && [.image,.video].contains(clip.kind)) {ids+=clip.assetID.map{[$0]} ?? []}
            if visual.contains(clip.id) {
                ids+=clip.mouthAssetID.map{[$0]} ?? []
                ids+=(clip.masks ?? []).filter{$0.enabled}.compactMap(\.assetID)
            }
            return ids
        })
    }
}
