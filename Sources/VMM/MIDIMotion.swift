import Foundation

struct MIDINoteOn:Equatable {
    var time:Double
    var velocity:Int
    var note:Int
    var channel:Int
    var track:Int
}
struct MIDISequence:Equatable {
    var notes:[MIDINoteOn]
    var tracks:Int
    var tempoChanges:Int
}

/// Bounded Standard MIDI File reader: format 0/1, PPQN timing, note-on and tempo only.
enum MIDIReader {
    private struct RawNote {var tick:UInt64;var velocity:Int;var note:Int;var channel:Int;var track:Int}
    private struct Tempo {var tick:UInt64;var micros:Int;var order:Int}
    static func parse(_ data:Data)throws->MIDISequence {
        guard data.count<=2*1024*1024 else{throw VMMError.message("MIDIファイルは2 MiBまでです。")}
        let bytes=[UInt8](data),count=bytes.count
        func u16(_ at:Int)->Int {(Int(bytes[at])<<8)|Int(bytes[at+1])}
        func u32(_ at:Int)->Int {(Int(bytes[at])<<24)|(Int(bytes[at+1])<<16)|(Int(bytes[at+2])<<8)|Int(bytes[at+3])}
        guard count>=14,Array(bytes[0..<4]) == Array("MThd".utf8) else{throw VMMError.message("MIDIヘッダーが不正です。")}
        let header=u32(4)
        guard header>=6,header<=count-8 else{throw VMMError.message("MIDIヘッダーが不正です。")}
        let format=u16(8),tracks=u16(10),division=u16(12)
        guard (format==0 || format==1),tracks>=1,tracks<=64,(format != 0 || tracks==1) else{throw VMMError.message("MIDI形式はSMF 0または1（最大64トラック）に対応します。")}
        guard division>0,division & 0x8000 == 0 else{throw VMMError.message("SMPTE時間形式のMIDIには対応していません。")}
        var pos=8+header,raw:[RawNote]=[],tempos:[Tempo]=[],eventCount=0,order=0
        for track in 0..<tracks {
            guard pos<=count-8,Array(bytes[pos..<(pos+4)]) == Array("MTrk".utf8) else{throw VMMError.message("MIDIトラックが不正です。")}
            let length=u32(pos+4);pos+=8
            guard length<=count-pos else{throw VMMError.message("MIDIトラックが途中で切れています。")}
            let end=pos+length
            var tick:UInt64=0,running:UInt8?,sawEnd=false
            func byte()throws->UInt8 {guard pos<end else{throw VMMError.message("MIDIイベントが途中で切れています。")};defer{pos+=1};return bytes[pos]}
            func variable()throws->UInt32 {
                var value:UInt32=0
                for _ in 0..<4 {let b=try byte();value=(value<<7)|UInt32(b & 0x7f);if b & 0x80 == 0{return value}}
                throw VMMError.message("MIDI可変長整数が不正です。")
            }
            while pos<end {
                eventCount+=1;guard eventCount<=50000 else{throw VMMError.message("MIDIイベントは50,000件までです。")}
                let delta=try variable();guard tick<=UInt64.max-UInt64(delta) else{throw VMMError.message("MIDI時刻が不正です。")} ;tick += UInt64(delta)
                guard pos<end else{throw VMMError.message("MIDIイベントが途中で切れています。")}
                let status:UInt8
                if bytes[pos] & 0x80 != 0 {status=try byte();if status<0xf0{running=status}else{running=nil}}
                else {guard let existing=running else{throw VMMError.message("MIDIランニングステータスが不正です。")};status=existing}
                if status==0xff {
                    let type=try byte(),n=Int(try variable());guard n<=end-pos else{throw VMMError.message("MIDIイベントが途中で切れています。")}
                    if type==0x51 {guard n==3 else{throw VMMError.message("MIDIテンポが不正です。")} ;let micros=(Int(bytes[pos])<<16)|(Int(bytes[pos+1])<<8)|Int(bytes[pos+2]);guard micros>0 else{throw VMMError.message("MIDIテンポが不正です。")} ;tempos.append(Tempo(tick:tick,micros:micros,order:order));order+=1}
                    if type==0x2f {guard n==0,pos==end else{throw VMMError.message("MIDIトラック終端が不正です。")} ;sawEnd=true;break}
                    pos += n
                } else if status==0xf0 || status==0xf7 {
                    let n=Int(try variable());guard n<=end-pos else{throw VMMError.message("MIDIイベントが途中で切れています。")} ;pos += n
                } else if status>=0x80 && status<=0xef {
                    let kind=status & 0xf0,a=try byte(),b:UInt8=(kind==0xc0 || kind==0xd0) ? 0:try byte()
                    guard a<128,b<128 else{throw VMMError.message("MIDIイベントが不正です。")}
                    if kind==0x90 && b>0 {raw.append(RawNote(tick:tick,velocity:Int(b),note:Int(a),channel:Int(status & 0x0f)+1,track:track+1))}
                } else {throw VMMError.message("このMIDIシステムイベントには対応していません。")}
            }
            guard sawEnd else{throw VMMError.message("MIDIトラックの終端がありません。")}
        }
        guard pos==count else{throw VMMError.message("MIDIに未対応の追加データがあります。")}
        tempos.sort{$0.tick == $1.tick ? $0.order<$1.order:$0.tick<$1.tick}
        raw.sort{$0.tick == $1.tick ? ($0.track == $1.track ? $0.note<$1.note:$0.track<$1.track):$0.tick<$1.tick}
        var tempoIndex=0,previousTick:UInt64=0,seconds=0.0,micros=500000
        var notes:[MIDINoteOn]=[];notes.reserveCapacity(raw.count)
        for item in raw {
            while tempoIndex<tempos.count && tempos[tempoIndex].tick<=item.tick {
                let t=tempos[tempoIndex];seconds+=Double(t.tick-previousTick)*Double(micros)/Double(division)/1_000_000;previousTick=t.tick;micros=t.micros;tempoIndex+=1
            }
            let time=seconds+Double(item.tick-previousTick)*Double(micros)/Double(division)/1_000_000
            guard time.isFinite,time<=86400 else{throw VMMError.message("MIDIの長さは24時間までです。")}
            notes.append(MIDINoteOn(time:time,velocity:item.velocity,note:item.note,channel:item.channel,track:item.track))
        }
        return MIDISequence(notes:notes,tracks:tracks,tempoChanges:tempos.count)
    }
}

enum MusicMotionKind:String,CaseIterable {
    case pulse,bounce
    var title:String {self == .pulse ? "拡大":"上下バウンド"}
    var property:AnimatedProperty {self == .pulse ? .scale:.y}
}
enum MusicMotionSource {
    case bpm(RhythmSettings,from:Double)
    case midi(MIDISequence,from:Double,channel:Int)
}
enum MusicMotionPlanner {
    static func keys(clip:Clip,fps:Int,kind:MusicMotionKind,strength:Double,source:MusicMotionSource)throws->[AnimationKeyframe] {
        guard fps>0,strength.isFinite,(0...1).contains(strength),clip.availableAnimatedProperties.contains(kind.property) else{throw VMMError.message("音楽モーションの設定が不正です。")}
        guard kind != .bounce || clip.spatialAnimation == nil else{throw VMMError.message("移動パスが有効なため、上下モーションは適用できません。")}
        guard !(clip.animation?.tracks.first{$0.property==kind.property}?.keys.isEmpty == false) else{throw VMMError.message("対象項目にキーフレームがあります。既存キーを削除するか別の項目を選んでください。")}
        var hits:[Int:Double]=[:],scale=Double(fps)
        func insert(_ time:Double,_ velocity:Double)throws {
            guard time.isFinite,time>=clip.start,time<clip.end else{return}
            let first=Int(ceil(clip.start*scale-1e-8)),last=Int(ceil(clip.end*scale-1e-8))-1
            guard first<=last else{return}
            let frame=min(last,max(first,Int((time*scale).rounded())))
            hits[frame]=max(hits[frame] ?? 0,velocity)
            guard hits.count<=249 else{throw VMMError.message("音符・拍が多すぎます。範囲を短くしてください（最大249点）。")}
        }
        switch source {
        case .bpm(let rhythm,let from):
            try rhythm.validate();guard from.isFinite else{throw VMMError.message("音楽モーションの開始位置が不正です。")}
            let interval=60/rhythm.bpm,start=max(from,clip.start),phase=rhythm.offset
            guard start<clip.end else{throw VMMError.message("対象範囲に拍や音符がありません。")}
            let first=max(0,ceil((start-phase)/interval-1e-9)),amount=max(0,ceil((clip.end-(phase+first*interval))/interval))
            guard amount<=1000 else{throw VMMError.message("音符・拍が多すぎます。範囲を短くしてください（最大249点）。")}
            for i in 0..<Int(amount) {try insert(phase+(first+Double(i))*interval,1)}
        case .midi(let midi,let from,let channel):
            guard from.isFinite,from>=0,(0...16).contains(channel) else{throw VMMError.message("MIDIの開始位置またはチャンネルが不正です。")}
            for note in midi.notes where channel==0 || note.channel==channel {try insert(from+note.time,Double(note.velocity)/127)}
        }
        let frames=hits.keys.sorted();guard !frames.isEmpty else{throw VMMError.message("対象範囲に拍や音符がありません。")}
        let property=kind.property,base=property.get(clip),release=max(1,Int((0.12*scale).rounded()))
        func local(_ frame:Int)->Double {Double(frame)/scale-clip.start+clip.animationTimeOffset}
        var keys:[AnimationKeyframe]=[]
        if local(frames[0])>clip.animationTimeOffset+1e-8 {keys.append(AnimationKeyframe(time:clip.animationTimeOffset,value:base,easing:.hold))}
        for (index,frame) in frames.enumerated() {
            let amount=strength*(hits[frame] ?? 0),peak=kind == .pulse ? base*(1+0.5*amount):base-0.12*amount
            keys.append(AnimationKeyframe(time:local(frame),value:min(property.range.upperBound,max(property.range.lowerBound,peak)),easing:.easeOut))
            let next=index+1<frames.count ? frames[index+1]:Int(ceil(clip.end*scale))
            let end=min(frame+release,next-1,Int(ceil(clip.end*scale))-1)
            if end>frame {keys.append(AnimationKeyframe(time:local(end),value:base,easing:.hold))}
        }
        return keys
    }
}
@MainActor extension EditorStore {
    func applyMusicMotion(id:UUID,kind:MusicMotionKind,strength:Double,source:MusicMotionSource)throws {
        guard let clip=project.clips.first(where:{$0.id==id}),!busy,!project.tracks[clip.track].locked else{throw VMMError.message("レイヤーがロックされているか、処理中です。")}
        let keys=try MusicMotionPlanner.keys(clip:clip,fps:project.fps,kind:kind,strength:strength,source:source)
        try mutateMotion(id){value in
            var animation=value.animation ?? ClipAnimation()
            if let index=animation.tracks.firstIndex(where:{$0.property==kind.property}) {animation.tracks[index].keys=keys;animation.tracks[index].enabled=true}
            else {animation.tracks.append(AnimationTrack(property:kind.property,keys:keys))}
            value.animation=animation
        }
    }
}
