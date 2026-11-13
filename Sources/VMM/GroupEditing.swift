import SwiftUI

@MainActor extension EditorStore {
    func setParent(_ parent:UUID?,clipID:UUID) {
        guard let clip=project.clips.first(where:{$0.id==clipID}),parent != clipID else {return}
        if let parent,project.descendants(of:clipID).contains(parent) {error="子孫アイテムを親にはできません。";return}
        var candidate=clip;candidate.parentID=parent
        do {try candidate.validateAdvanced(project:project);edit(clipID) {$0.parentID=parent}}
        catch {self.error=error.localizedDescription}
    }
    func groupSelectedLayer() {
        guard !busy,!project.tracks[selectedTrack].locked else {return}
        let members=project.clips.filter {$0.track==selectedTrack && $0.parentID==nil && ![.transition,.adjustment].contains($0.kind)}
        guard let start=members.map(\.start).min(),let end=members.map(\.end).max() else {status="このレイヤーにグループ化できるアイテムがありません。";return}
        pause();checkpoint()
        let group=Clip(kind:.group,name:"\(project.tracks[selectedTrack].name)のグループ",track:selectedTrack,start:start,duration:end-start)
        let ids=Set(members.map(\.id))
        for i in project.clips.indices where ids.contains(project.clips[i].id) {project.clips[i].parentID=group.id}
        project.clips.append(group);selectedID=group.id
    }
    func editTrack(_ index:Int,_ action:(inout Track)->Void) {
        guard !busy,project.tracks.indices.contains(index),!project.tracks[index].locked else {return}
        pause();checkpoint();action(&project.tracks[index])
    }
    func setMediaRate(_ rate:Double,clipID:UUID) {
        let fps=Double(project.fps)
        edit(clipID) {c in
            let old=c.mediaRate;c.playbackRate=rate
            c.duration=max(1/fps,c.duration*old/rate)
            if c.animation != nil,c.animation?.span != nil {c.animation?.span=nil}
        }
    }
    func advancedBinding<T,Settings>(_ clipID:UUID,_ key:WritableKeyPath<Clip,Settings?>,_ property:WritableKeyPath<Settings,T>,default fallback:Settings) -> Binding<T> {
        Binding(get:{(self.project.clips.first{$0.id==clipID}?[keyPath:key] ?? fallback)[keyPath:property]},set:{value in
            self.edit(clipID) {c in var settings=c[keyPath:key] ?? fallback;settings[keyPath:property]=value;c[keyPath:key]=settings}
        })
    }
}
