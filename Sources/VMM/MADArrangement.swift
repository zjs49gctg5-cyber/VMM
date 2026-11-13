import Foundation

enum MADArrangement {
    static func pitches(_ text:String)throws->[Double?] {
        let tokens=text.split{ $0.isWhitespace || $0=="," }
        guard !tokens.isEmpty,tokens.count<=512 else {throw VMMError.message("音程を1〜512個入力してください。")}
        return try tokens.map { token in
            if token=="-" || token=="休" {return nil}
            guard let value=Double(token),value.isFinite,(-24...24).contains(value) else {throw VMMError.message("音程は−24〜24半音、休符は - で指定してください。")};return value
        }
    }
    static func fit(_ clip:Clip,duration:Double)throws->Clip {
        guard !clip.hasTimeWarp else {throw VMMError.message("逆再生・可変速度の素材は拍に合わせた伸縮に対応していません。")}
        var c=clip;let rate=clip.duration*clip.mediaRate/duration
        guard duration.isFinite,duration>0,rate.isFinite,(0.25...4).contains(rate) else {throw VMMError.message("伸縮率が範囲外です。素材の切り出し長か音符の長さを変更してください（速度25〜400%）。")}
        c.preserveAnimationDomain();c.duration=duration;c.playbackRate=rate;c.preservePitch=true;return c
    }
}
@MainActor extension EditorStore {
    func requireMAD(_ ids:Set<UUID>)throws->[Clip] {
        guard !busy,project.rhythmEnabled,!ids.isEmpty else {throw VMMError.message("音MADモードを有効にして素材を選択してください。")}
        let clips=project.clips.filter{ids.contains($0.id)}
        guard clips.count==ids.count,clips.allSatisfy({[.audio,.video,.speech].contains($0.kind) && !$0.speechDirty && !project.tracks[$0.track].locked && $0.linkID==nil && project.descendants(of:$0.id).isEmpty}) else {throw VMMError.message("生成済みの音声・動画を選択してください。ロック・リンク・子を持つ素材は対象外です。")};return clips
    }
    func commitMAD(_ candidate:Project,selection ids:Set<UUID>)throws {
        let validated=try candidate.validated();pause();checkpoint();project=validated;selectedIDs=ids;selectedID=ids.first;status="音MADの配置を更新しました。"
    }
    func quantizeMAD(_ ids:Set<UUID>,strength:Double=1)throws {
        guard strength.isFinite,(0...1).contains(strength) else {throw VMMError.message("拍合わせの強さは0〜100%です。")}
        let clips=try requireMAD(ids),rhythm=project.rhythm ?? RhythmSettings();guard strength>0 else{return};var candidate=project
        for clip in clips {
            let time=clip.start+(rhythm.nearest(clip.start)-clip.start)*strength
            let index=candidate.clips.firstIndex{$0.id==clip.id}!
            candidate.clips[index].start=(time*Double(project.fps)).rounded()/Double(project.fps)
        }
        try commitMAD(candidate,selection:ids)
    }
    func fitMAD(_ ids:Set<UUID>,beats:Double)throws {
        guard beats.isFinite,(0.125...64).contains(beats) else {throw VMMError.message("音符長は0.125〜64拍です。")}
        let clips=try requireMAD(ids),duration=(60/(project.rhythm?.bpm ?? 120)*beats*Double(project.fps)).rounded()/Double(project.fps);var candidate=project
        for clip in clips {candidate.clips[candidate.clips.firstIndex{$0.id==clip.id}!]=try MADArrangement.fit(clip,duration:duration)}
        try commitMAD(candidate,selection:ids)
    }
    func patternMAD(_ id:UUID,pitches:[Double?],at start:Double,gate:Double=0.9)throws->[UUID] {
        let source=try requireMAD([id])[0]
        guard !pitches.isEmpty,pitches.count<=512,pitches.contains(where:{$0 != nil}),start.isFinite,start>=0,gate.isFinite,(0.05...1).contains(gate) else {throw VMMError.message("パターンの開始・音符・ゲートが不正です。")}
        let step=(project.rhythm ?? RhythmSettings()).interval,fps=Double(project.fps)
        var candidate=project,added:[UUID]=[]
        for (i,pitch) in pitches.enumerated() {
            guard let pitch else {continue};guard pitch.isFinite,(-24...24).contains(pitch) else {throw VMMError.message("音程は−24〜24半音です。")}
            let time=((start+Double(i)*step)*fps).rounded()/fps
            let length=((start+Double(i)*step+step*gate)*fps).rounded()/fps-time
            guard length>=1/fps else {throw VMMError.message("音符が1フレーム未満です。音符長かFPSを変更してください。")}
            var c=try MADArrangement.fit(source,duration:length);c.id=UUID();c.start=time;c.pitchSemitones=pitch;c.parentID=nil;c.sceneMembers=nil
            c.audioFade=AudioFade(fadeIn:min(0.005,length/4),fadeOut:min(0.01,length/4));candidate.clips.append(c);added.append(c.id)
        }
        try commitMAD(candidate,selection:Set(added));return added
    }
}
