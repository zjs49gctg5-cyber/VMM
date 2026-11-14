import Foundation

struct LyricAlignmentMatch:Codable,Equatable {
    var index:Int
    var text:String
    var start:Double?
    var end:Double?
    var matched:Bool {start != nil && end != nil}
}
enum LyricAlignment {
    static let maximumSeconds=900.0
    static let recognitionChunkSeconds=30.0
    /// Each request stays within the speech recognizer limit. Token times remain
    /// relative to the original trimmed source, including when playback rate differs.
    static func chunks(_ clip:Clip)throws->[(clip:Clip,sourceDelta:Double)] {
        guard clip.duration.isFinite,clip.duration>0,clip.mediaRate.isFinite,clip.mediaRate>0,clip.duration<=maximumSeconds,clip.duration*clip.mediaRate<=maximumSeconds else{throw VMMError.message("歌詞同期の音声範囲が不正です。")}
        let maximum=min(recognitionChunkSeconds,recognitionChunkSeconds/clip.mediaRate)
        var result:[(clip:Clip,sourceDelta:Double)]=[],elapsed=0.0
        while elapsed<clip.duration-0.000001 {
            var part=clip;part.start=clip.start+elapsed;part.duration=min(maximum,clip.duration-elapsed)
            part.sourceOffset=clip.sourceOffset+elapsed*clip.mediaRate
            result.append((part,elapsed*clip.mediaRate));elapsed+=part.duration
        }
        return result
    }
    static func recognize(text:String,source:URL,clip:Clip,language:String,fps:Int,using recognizer:(URL,Clip,String,[String]) async throws->[TranscriptToken]) async throws->[LyricAlignmentMatch] {
        _=try suggest(text:text,tokens:[],clip:clip,fps:fps)
        let hints=text.components(separatedBy:.newlines)
        var plain:[TranscriptToken]=[],guided:[TranscriptToken]=[]
        func recognizePart(_ part:Clip,_ hints:[String]) async throws->[TranscriptToken] {
            do {return try await recognizer(source,part,language,hints)}
            catch {let error=error as NSError;if error.domain=="kAFAssistantErrorDomain" && error.code==1110 {return []};throw error}
        }
        for part in try chunks(clip) {
            try Task.checkCancellation()
            let a=try await recognizePart(part.clip,[])
            try Task.checkCancellation()
            let b=try await recognizePart(part.clip,hints)
            plain += a.map{TranscriptToken(text:$0.text,start:$0.start+part.sourceDelta,duration:$0.duration)}
            guided += b.map{TranscriptToken(text:$0.text,start:$0.start+part.sourceDelta,duration:$0.duration)}
        }
        let first=try suggest(text:text,tokens:plain,clip:clip,fps:fps),second=try suggest(text:text,tokens:guided,clip:clip,fps:fps)
        return second.filter(\.matched).count>first.filter(\.matched).count ? second:first
    }
    private struct TimedCharacter {var value:Character;var start:Double;var end:Double}
    private static func normalized(_ input:String)->[Character] {
        let text=input.precomposedStringWithCompatibilityMapping.lowercased()
        let kana=text.applyingTransform(.hiraganaToKatakana,reverse:false) ?? text
        return kana.filter{$0.unicodeScalars.contains{CharacterSet.alphanumerics.contains($0)}}.map{$0}
    }
    private static func find(_ needle:[Character],in source:[TimedCharacter],from cursor:Int)->Int? {
        guard !needle.isEmpty,cursor<source.count else{return nil}
        var prefix=[Int](repeating:0,count:needle.count),matched=0
        if needle.count>1 {for i in 1..<needle.count {
            while matched>0 && needle[i] != needle[matched] {matched=prefix[matched-1]}
            if needle[i]==needle[matched] {matched+=1};prefix[i]=matched
        }}
        matched=0
        for i in cursor..<source.count {
            while matched>0 && source[i].value != needle[matched] {matched=prefix[matched-1]}
            if source[i].value==needle[matched] {matched+=1}
            if matched==needle.count {return i-needle.count+1}
        }
        return nil
    }
    static func suggest(text:String,tokens:[TranscriptToken],clip:Clip,fps:Int)throws->[LyricAlignmentMatch] {
        let lines=text.components(separatedBy:.newlines).map{$0.trimmingCharacters(in:.whitespacesAndNewlines)}.filter{!$0.isEmpty}
        guard fps>0,clip.mediaRate.isFinite,clip.mediaRate>0,!lines.isEmpty,lines.count<=200,text.utf8.count<=16384,tokens.count<=5000 else{throw VMMError.message("歌詞または音声認識結果が不正です。")}
        var recognized:[TimedCharacter]=[]
        for token in tokens.sorted(by:{$0.start<$1.start}) {
            guard token.start.isFinite,token.duration.isFinite,token.start>=0,token.duration>0 else{continue}
            let chars=normalized(token.text);guard !chars.isEmpty else{continue}
            for (i,ch) in chars.enumerated() {
                let start=clip.start+(token.start+token.duration*Double(i)/Double(chars.count))/clip.mediaRate
                let end=clip.start+(token.start+token.duration*Double(i+1)/Double(chars.count))/clip.mediaRate
                if start<clip.end,end>clip.start {recognized.append(TimedCharacter(value:ch,start:max(clip.start,start),end:min(clip.end,end)))}
            }
            guard recognized.count<=12000 else{throw VMMError.message("音声認識結果が長すぎます。")}
        }
        var cursor=0,result:[LyricAlignmentMatch]=[]
        for (index,line) in lines.enumerated() {
            let needle=normalized(line)
            guard !needle.isEmpty,needle.count<=2000 else{result.append(LyricAlignmentMatch(index:index,text:line));continue}
            guard let first=find(needle,in:recognized,from:cursor) else{result.append(LyricAlignmentMatch(index:index,text:line));continue}
            let last=first+needle.count-1,scale=Double(fps)
            let start=(recognized[first].start*scale).rounded()/scale,end=(recognized[last].end*scale).rounded()/scale
            guard end>start else{result.append(LyricAlignmentMatch(index:index,text:line));continue}
            result.append(LyricAlignmentMatch(index:index,text:line,start:start,end:end));cursor=last+1
        }
        return result
    }
}
