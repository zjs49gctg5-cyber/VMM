import AppKit
import UniformTypeIdentifiers

struct CaptionCue:Equatable {var start:Double;var end:Double;var text:String}
enum CaptionFormat:String {case srt,vtt}
enum CaptionCodec {
    static func timestamp(_ value:String)throws->Double {
        let parts=value.replacingOccurrences(of:",",with:".").split(separator:":")
        guard (2...3).contains(parts.count),parts.allSatisfy({!$0.isEmpty}),let seconds=Double(parts.last!),seconds.isFinite,(0..<60).contains(seconds),let minutes=Int(parts[parts.count-2]),(0..<60).contains(minutes),let hours=parts.count==3 ? Int(parts[0]):0,(0...24).contains(hours) else{throw VMMError.message("字幕の時刻が不正です。")}
        return Double(hours*3600+minutes*60)+seconds
    }
    static func parse(_ source:String,format:CaptionFormat)throws->[CaptionCue] {
        guard source.utf8.count<=8*1024*1024 else{throw VMMError.message("字幕ファイルが大きすぎます。")}
        let lines=source.replacingOccurrences(of:"\u{FEFF}",with:"").replacingOccurrences(of:"\r\n",with:"\n").replacingOccurrences(of:"\r",with:"\n").components(separatedBy:"\n")
        var cues:[CaptionCue]=[],block:[String]=[]
        func flush()throws {
            defer{block=[]}
            guard !block.isEmpty else{return}
            let first=block[0].trimmingCharacters(in:.whitespaces)
            if format == .vtt,(first.hasPrefix("WEBVTT") || first=="STYLE" || first=="REGION" || first=="NOTE" || first.hasPrefix("NOTE ")){return}
            guard let index=block.firstIndex(where:{$0.contains("-->")}),index<=1 else{throw VMMError.message("字幕の時間行がありません。")}
            let times=block[index].components(separatedBy:"-->")
            guard times.count==2,let right=times[1].split(whereSeparator:{$0.isWhitespace}).first else{throw VMMError.message("字幕の時刻が不正です。")}
            let start=try timestamp(times[0].trimmingCharacters(in:.whitespaces)),end=try timestamp(String(right))
            var text=block.dropFirst(index+1).joined(separator:"\n")
            text=text.replacingOccurrences(of:"<br>",with:"\n").replacingOccurrences(of:"<[^>]+>",with:"",options:.regularExpression)
            for (entity,char) in [("&lt;","<"),("&gt;",">"),("&nbsp;"," "),("&quot;","\""),("&amp;","&")] {text=text.replacingOccurrences(of:entity,with:char)}
            guard start>=0,end>start,end<=86400,!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,text.count<=10000,cues.count<2000 else{throw VMMError.message("字幕の長さ・内容・件数が不正です。")}
            cues.append(CaptionCue(start:start,end:end,text:text))
        }
        for line in lines {if line.trimmingCharacters(in:.whitespaces).isEmpty{try flush()}else{block.append(line)}};try flush()
        guard !cues.isEmpty else{throw VMMError.message("字幕がありません。")}
        return cues.sorted{$0.start<$1.start}
    }
    static func encode(_ cues:[CaptionCue],format:CaptionFormat)->String {
        func stamp(_ t:Double)->String {
            let ms=Int((max(0,t)*1000).rounded())
            return String(format:"%02d:%02d:%02d%@%03d",ms/3600000,ms/60000%60,ms/1000%60,format == .srt ? ",":".",ms%1000)
        }
        let body=cues.enumerated().map{index,cue in
            let text=cue.text.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;")
            return "\(index+1)\n\(stamp(cue.start)) --> \(stamp(cue.end))\n\(text)"
        }.joined(separator:"\n\n")
        return (format == .vtt ? "WEBVTT\n\n":"")+body+"\n"
    }
}
struct CaptionDiagnostic:Identifiable {var id:UUID;var messages:[String]}
extension Project {
    var captionCues:[CaptionCue] {
        clips.filter{[.text,.speech].contains($0.kind) && !($0.kind == .speech && $0.speechCaptionHidden == true) && tracks[$0.track].visible && !$0.text.isEmpty}.compactMap{clip in
            var start=clip.start,end=clip.end,parent=clip.parentID,seen=Set<UUID>()
            while let id=parent,seen.insert(id).inserted,let p=clips.first(where:{$0.id==id}) {
                guard tracks[p.track].visible else{return nil}
                start=max(start,p.start);end=min(end,p.end);parent=p.parentID
            }
            return end>start ? CaptionCue(start:start,end:end,text:clip.text):nil
        }.sorted{$0.start<$1.start}
    }
    var captionDiagnostics:[CaptionDiagnostic] {
        let captions=clips.filter{[.text,.speech].contains($0.kind) && !($0.kind == .speech && $0.speechCaptionHidden == true)}
        return captions.compactMap{clip in
            var messages:[String]=[]
            if clip.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty{messages.append(L("字幕が空です"))}
            if Double(clip.text.filter{!$0.isWhitespace}.count)/clip.duration>15{messages.append(L("字幕の文字数が多すぎます（15字／秒超）"))}
            if clip.text.components(separatedBy:"\n").count>3{messages.append(L("字幕が4行以上です"))}
            if captions.contains(where:{$0.id != clip.id && $0.track==clip.track && $0.start<clip.end && $0.end>clip.start}){messages.append(L("同じレイヤーの字幕が重なっています"))}
            return messages.isEmpty ? nil:CaptionDiagnostic(id:clip.id,messages:messages)
        }
    }
}
@MainActor extension EditorStore {
    /// Convert selected text clips without changing their visual style or timing.
    func convertSelectedTextToSpeech() throws {
        guard !busy else { throw VMMError.message("処理中です。") }
        let targets = selection
        var candidate = project
        let indices = candidate.clips.indices.filter { targets.contains(candidate.clips[$0].id) && candidate.clips[$0].kind == .text }
        guard !indices.isEmpty else { throw VMMError.message("変換するテキストを選択してください。") }
        guard indices.allSatisfy({ !candidate.tracks[candidate.clips[$0].track].locked }) else { throw VMMError.message("対象のレイヤーがロックされています。") }
        for index in indices {
            candidate.clips[index].kind = .speech
            setDefaultSpeechVoice(&candidate.clips[index])
            candidate.clips[index].speechDirty = true
            candidate.clips[index].preserveSpeechDuration = true
        }
        _ = try candidate.validated()
        pause(); checkpoint(); project = candidate
    }
    func importCaptions(_ source:String,format:CaptionFormat,at offset:Double=0)throws {
        guard !busy,!project.tracks[selectedTrack].locked else{throw VMMError.message("編集できないレイヤーです。")}
        let cues=try CaptionCodec.parse(source,format:format),fps=Double(project.fps)
        var candidate=project
        let clips=cues.map{cue->Clip in
            let start=((cue.start+offset)*fps).rounded()/fps,end=((cue.end+offset)*fps).rounded()/fps
            var c=Clip(kind:.text,name:String(cue.text.prefix(40)),track:selectedTrack,start:start,duration:max(1/fps,end-start),text:cue.text);c.y=0.85;return c
        }
        candidate.clips.append(contentsOf:clips);_=try candidate.validated()
        pause();checkpoint();project=candidate;selectedIDs=Set(clips.map(\.id));selectedID=clips.first?.id
    }
    func importCaptionFile() {
        let panel=NSOpenPanel();panel.allowedContentTypes=[UTType(filenameExtension:"srt") ?? .plainText,UTType(filenameExtension:"vtt") ?? .plainText];panel.allowsMultipleSelection=false
        guard panel.runModal() == .OK,let url=panel.url else{return}
        do {try importCaptions(String(contentsOf:url,encoding:.utf8),format:url.pathExtension.lowercased()=="vtt" ? .vtt:.srt,at:playhead)}catch{self.error=error.localizedDescription}
    }
    func exportCaptions(_ format:CaptionFormat) {
        let panel=NSSavePanel();panel.nameFieldStringValue=project.name+"."+format.rawValue
        panel.allowedContentTypes=[UTType(filenameExtension:format.rawValue) ?? .plainText]
        guard panel.runModal() == .OK,let url=panel.url else{return}
        do {try CaptionCodec.encode(project.captionCues,format:format).write(to:url,atomically:true,encoding:.utf8)}catch{self.error=error.localizedDescription}
    }
}
