import Foundation

enum MouthVowel:String,Codable,CaseIterable {
    case a,i,u,e,o
    var title:String {switch self {case .a:return "あ";case .i:return "い";case .u:return "う";case .e:return "え";case .o:return "お"}}
}
struct VowelInterval:Codable,Equatable {
    var start:Double
    var end:Double
    var vowel:MouthVowel
}
struct VowelTiming:Codable,Equatable {
    var duration:Double
    var intervals:[VowelInterval]
    func isConsistent(with audioDuration:Double)->Bool {
        guard duration.isFinite,duration>0,audioDuration.isFinite,audioDuration>0,
              abs(duration-audioDuration)<=max(0.12,duration*0.03),!intervals.isEmpty,intervals.count<=10000 else{return false}
        var end=0.0
        for interval in intervals {
            guard interval.start.isFinite,interval.end.isFinite,interval.start>=end,interval.end>interval.start,interval.end<=duration else{return false}
            end=interval.end
        }
        return true
    }
    func vowel(at time:Double)->MouthVowel? {
        var lower=0,upper=intervals.count
        while lower<upper {let middle=(lower+upper)/2;if intervals[middle].start<=time {lower=middle+1}else{upper=middle}}
        guard lower>0 else{return nil};let interval=intervals[lower-1]
        return time<interval.end ? interval.vowel:nil
    }
}

enum VoicevoxVowelTiming {
    /// VOICEVOX query durations are estimated and rounded to its decoder frames.
    static func parse(_ query:[String:Any],speed:Double)->VowelTiming? {
        guard speed.isFinite,speed>0,let phrases=query["accent_phrases"] as? [[String:Any]],!phrases.isEmpty,
              let pre=(query["prePhonemeLength"] as? NSNumber)?.doubleValue,
              let post=(query["postPhonemeLength"] as? NSNumber)?.doubleValue,pre.isFinite,post.isFinite,pre>=0,post>=0 else{return nil}
        func frame(_ seconds:Double)->Double {((seconds/speed*93.75).rounded(.toNearestOrEven))/93.75}
        var cursor=frame(pre),intervals:[VowelInterval]=[]
        let pauseScale=(query["pauseLengthScale"] as? NSNumber)?.doubleValue ?? 1
        let pauseOverride=(query["pauseLength"] as? NSNumber)?.doubleValue
        guard pauseScale.isFinite,pauseScale>=0,pauseOverride.map({$0.isFinite && $0>=0}) ?? true else{return nil}
        func append(_ mora:[String:Any])->Bool {
            guard let vowel=mora["vowel"] as? String,let raw=(mora["vowel_length"] as? NSNumber)?.doubleValue,raw.isFinite,raw>=0 else{return false}
            if mora["consonant"] is String && !(mora["consonant_length"] is NSNumber) {return false}
            let consonant=(mora["consonant_length"] as? NSNumber)?.doubleValue ?? 0
            guard consonant.isFinite,consonant>=0 else{return false}
            let duration = vowel == "pau" ? (pauseOverride ?? raw)*pauseScale:raw
            let start=cursor;cursor += frame(consonant)+frame(duration)
            if let shape=MouthVowel(rawValue:vowel.lowercased()),cursor>start {intervals.append(VowelInterval(start:start,end:cursor,vowel:shape))}
            return cursor.isFinite && cursor<=86400 && intervals.count<=10000
        }
        for phrase in phrases {
            // The engine may append an extra upspeak mora. Avoid guessing its duration.
            if phrase["is_interrogative"] as? Bool == true {return nil}
            guard let moras=phrase["moras"] as? [[String:Any]] else{return nil}
            for mora in moras {if !append(mora) {return nil}}
            if let pause=phrase["pause_mora"] as? [String:Any],!append(pause){return nil}
        }
        cursor += frame(post)
        let result=VowelTiming(duration:cursor,intervals:intervals)
        return result.isConsistent(with:cursor) ? result:nil
    }
}

struct ProjectMouthCue {var vowel:MouthVowel?}
extension Project {
    func mouthCue(for character:Clip,at time:Double)->ProjectMouthCue? {
        guard let speaker=character.characterSpeakerID else{return nil}
        var timed=false,untimed=false
        for speech in clips {
            guard speech.kind == .speech,speech.speakerID==speaker,
                  character.characterPresetID == nil || speech.characterPresetID==character.characterPresetID,
                  (speech.speechConfiguration?.engine ?? .voicevox)==(character.characterSpeechEngine ?? .voicevox),
                  audioIsActive(speech,at:time),!speech.speechDirty,!tracks[speech.track].muted else{continue}
            guard let asset=asset(for:speech),let timing=asset.vowelTiming else{untimed=true;continue}
            timed=true
            if let vowel=timing.vowel(at:speech.sourceTime(at:time)) {return ProjectMouthCue(vowel:vowel)}
        }
        return timed && !untimed ? ProjectMouthCue(vowel:nil):nil
    }
}
