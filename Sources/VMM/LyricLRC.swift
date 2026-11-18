import Foundation

/// Timed karaoke text and the @Ruby extension. Draft segment times are relative
/// to the line's singing start; project clip times are adjusted on placement.
enum LyricLRC {
    private struct Chunk {var text:String;var start:Double;var end:Double}
    private struct Row {var chunks:[Chunk];var pending:String;var pendingStart:Double;var terminal:Double?}
    private struct RubyRule {var number:Int;var target:String;var reading:String;var timings:[LyricRubyTiming]?;var start:Double;var end:Double}
    private static let tag = try! NSRegularExpression(pattern:#"[\[<](\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?[\]>]"#)
    private static func number(_ match:NSTextCheckingResult,_ s:String,_ i:Int)->String {Range(match.range(at:i),in:s).map{String(s[$0])} ?? ""}
    private static func time(_ match:NSTextCheckingResult,_ s:String)throws->Double {
        let token=(s as NSString).substring(with:match.range)
        guard (token.first == "[" && token.last == "]") || (token.first == "<" && token.last == ">") else{throw VMMError.message("LRCのタイムタグが不正です。")}
        let min=Double(number(match,s,1)) ?? -1,sec=Double(number(match,s,2)) ?? -1,fraction=number(match,s,3)
        let t=min*60+sec+(fraction.isEmpty ? 0:(Double(fraction) ?? 0)/pow(10,Double(fraction.count)))
        guard sec<60,t>=0,t<=86400 else{throw VMMError.message("LRCの時刻が不正です。")};return t
    }
    private static func singleTime(_ s:String)throws->Double {
        let range=NSRange(s.startIndex...,in:s)
        guard let m=tag.firstMatch(in:s,range:range),m.range==range else{throw VMMError.message("ルビの適用時刻が不正です。")};return try time(m,s)
    }
    private static func reading(_ raw:String)throws->(String,[LyricRubyTiming]?) {
        let ns=raw as NSString,matches=tag.matches(in:raw,range:NSRange(raw.startIndex...,in:raw))
        var plain="",last=0,markers:[LyricRubyTiming]=[]
        for match in matches {
            plain += ns.substring(with:NSRange(location:last,length:match.range.location-last))
            let point=LyricRubyTiming(index:plain.count,offset:try time(match,raw))
            guard markers.last.map({point.index>$0.index && point.offset >= $0.offset}) ?? true else{throw VMMError.message("ルビ内の時刻が逆順または重複しています。")}
            markers.append(point);last=NSMaxRange(match.range)
        }
        plain += ns.substring(from:last)
        guard !plain.contains("[") && !plain.contains("]") && !plain.contains("<") && !plain.contains(">"),markers.allSatisfy({$0.index<plain.count}) else{throw VMMError.message("ルビ内のタイムタグが不正です。")}
        return(plain,markers.isEmpty ? nil:markers)
    }
    static func parse(_ text:String,fps:Int)throws->[LyricDraftLine] {
        guard fps>0,text.utf8.count<=1_048_576 else{throw VMMError.message("歌詞ファイルが大きすぎるかFPSが不正です。")}
        var rules:[RubyRule]=[],offset=0.0,seen=Set<String>(),rows:[Row]=[],metadata:[String]=[]
        let meta=try NSRegularExpression(pattern:#"^\[(ar|ti|al|by|re|ve|length):[^\]]*\]$"#,options:.caseInsensitive)
        for raw in text.replacingOccurrences(of:"\u{FEFF}",with:"").components(separatedBy:.newlines) {
            let line=raw.trimmingCharacters(in:.whitespacesAndNewlines);if line.isEmpty {continue}
            if line.hasPrefix("@") {
                let pieces=line.dropFirst().split(separator:"=",maxSplits:1,omittingEmptySubsequences:false)
                guard pieces.count==2 else{throw VMMError.message("LRCの@タグが不正です。")}
                let key=pieces[0].trimmingCharacters(in:.whitespaces).lowercased(),value=String(pieces[1])
                guard seen.insert(key).inserted else{throw VMMError.message("LRCの@タグが重複しています。")}
                if key=="offset" {guard let ms=Int(value),abs(Double(ms))<=86_400_000 else{throw VMMError.message("LRCオフセットが不正です。")};offset=Double(ms)/1000;metadata.append("@Offset=0");continue}
                if key.hasPrefix("ruby"),let n=Int(key.dropFirst(4)),n>0 {
                    let fields=value.components(separatedBy:",");guard (1...4).contains(fields.count),!fields[0].isEmpty,fields[0].count<=200,rules.count<200 else{throw VMMError.message("ルビタグが不正または多すぎます。")}
                    let (pronunciation,timings)=try reading(fields.count>1 ? fields[1]:"")
                    let a=fields.count>2 && !fields[2].isEmpty ? try singleTime(fields[2]):0
                    let b=fields.count>3 && !fields[3].isEmpty ? try singleTime(fields[3]):86400
                    guard a<=b else{throw VMMError.message("ルビの適用範囲が不正です。")}
                    rules.append(RubyRule(number:n,target:fields[0],reading:pronunciation,timings:timings,start:a,end:b));continue
                }
                if key.hasPrefix("ruby") {throw VMMError.message("ルビタグが不正です。")}
                metadata.append(line);continue
            }
            let range=NSRange(line.startIndex...,in:line)
            if meta.firstMatch(in:line,range:range) != nil {metadata.append(line);continue}
            let matches=tag.matches(in:line,range:range)
            guard let first=matches.first,first.range.location==0 else{throw VMMError.message("LRCの行頭に時刻が必要です。")}
            var lastTime=try time(first,line),lastEnd=NSMaxRange(first.range),chunks:[Chunk]=[]
            let ns=line as NSString
            for m in matches.dropFirst() {
                let current=try time(m,line);guard current>=lastTime else{throw VMMError.message("LRCの時刻が逆順です。")}
                let value=ns.substring(with:NSRange(location:lastEnd,length:m.range.location-lastEnd))
                if !value.isEmpty {chunks.append(Chunk(text:value,start:lastTime,end:current))}
                lastTime=current;lastEnd=NSMaxRange(m.range)
            }
            let rest=ns.substring(from:lastEnd)
            guard !rest.contains("[") && !rest.contains("]") && !rest.contains("<") && !rest.contains(">"),chunks.allSatisfy({!$0.text.contains("[") && !$0.text.contains("]") && !$0.text.contains("<") && !$0.text.contains(">")}) else{throw VMMError.message("未対応または不正なLRCタイムタグです。")}
            rows.append(Row(chunks:chunks,pending:rest,pendingStart:lastTime,terminal:rest.isEmpty ? lastTime:nil))
        }
        let sortedRules=rules.sorted{$0.number<$1.number};guard sortedRules.enumerated().allSatisfy({$0.element.number==$0.offset+1}),rows.count<=201 else{throw VMMError.message("ルビ番号または歌詞行数が不正です。")}
        func adjusted(_ t:Double)->Double {max(0,min(86400,t+offset))}
        var result:[LyricDraftLine]=[]
        for i in rows.indices {
            var row=rows[i]
            if !row.pending.isEmpty {
                let next=i+1<rows.count ? (rows[i+1].chunks.first?.start ?? rows[i+1].pendingStart):row.pendingStart+2
                guard next>=row.pendingStart else{throw VMMError.message("LRCの時刻が逆順です。")}
                row.chunks.append(Chunk(text:row.pending,start:row.pendingStart,end:next))
            }
            guard let first=row.chunks.first,let last=row.chunks.last else{continue}
            let start=(adjusted(first.start)*Double(fps)).rounded()/Double(fps),end=(adjusted(last.end)*Double(fps)).rounded()/Double(fps)
            guard end>start,result.last.map({$0.end<=start}) ?? true else{throw VMMError.message("LRCの行が重複または逆順です。別パートは別ファイルに分けてください。")}
            let content=row.chunks.map(\.text).joined();guard content.count<=10000,row.chunks.count<=2000 else{throw VMMError.message("歌詞行またはタイムタグが長すぎます。")};var index=0,segments:[LyricWipeSegment]=[]
            for chunk in row.chunks {
                let n=chunk.text.count,a=max(0,(adjusted(chunk.start)*Double(fps)).rounded()/Double(fps)-start),b=max(0,(adjusted(chunk.end)*Double(fps)).rounded()/Double(fps)-start)
                segments.append(LyricWipeSegment(startIndex:index,endIndex:index+n,start:a,end:b));index+=n
            }
            guard index==content.count else{throw VMMError.message("タイムタグが結合文字の途中にあります。")}
            var ruby:[LyricRuby]=[];let chars=Array(content)
            for rule in sortedRules {
                let target=Array(rule.target);guard !target.isEmpty,target.count<=chars.count else{continue}
                for pos in 0...(chars.count-target.count) where chars[pos]==target[0] && Array(chars[pos..<pos+target.count])==target {
                    let occurrence=segments.firstIndex(where:{$0.startIndex<=pos && pos<$0.endIndex}).map{adjusted(row.chunks[$0].start)} ?? adjusted(first.start)
                    guard occurrence>=adjusted(rule.start)-0.0001,occurrence<=adjusted(rule.end)+0.0001 else{continue}
                    ruby.removeAll{max($0.startIndex,pos)<min($0.endIndex,pos+target.count)}
                    if !rule.reading.isEmpty {
                        let matching=segments.filter{max($0.startIndex,pos)<min($0.endIndex,pos+target.count)}
                        let duration=(matching.last?.end ?? (end-start))-(matching.first?.start ?? 0)
                        guard rule.timings?.allSatisfy({$0.offset<=duration+0.0001}) ?? true else{throw VMMError.message("ルビのタイミングが親文字の終了を超えています。")}
                        ruby.append(LyricRuby(startIndex:pos,endIndex:pos+target.count,text:rule.reading,timings:rule.timings))
                    }
                }
            }
            ruby.sort{$0.startIndex<$1.startIndex}
            let rich=row.chunks.count>1 || row.terminal != nil || ruby.contains(where:{$0.timings != nil})
            result.append(LyricDraftLine(text:content,start:start,end:end,segments:rich ? segments:nil,ruby:ruby.isEmpty ? nil:ruby))
        }
        guard !result.isEmpty,result.count<=200 else{throw VMMError.message("歌詞がありません。")}
        if !metadata.isEmpty {result[0].lrcMetadata=metadata}
        return result
    }
    static func encode(_ lines:[LyricDraftLine],fps:Int)throws->String {
        _=try LyricTemplatePlanner.clips(lines,track:0,fps:fps,motion:.none)
        _=try LyricTemplatePlanner.karaokeClips(lines,track:0,fps:fps,lead:0,tail:0)
        func stamp(_ time:Double)->String {let ms=Int((time*1000).rounded());return String(format:"[%02d:%02d.%03d]",ms/60000,(ms/1000)%60,ms%1000)}
        var result="",rubyTags:[String]=[]
        for (i,line) in lines.enumerated() {
            let chars=Array(line.text)
            guard !line.text.contains("\n"),!line.text.contains("\r"),!line.text.contains("["),!line.text.contains("]"),!line.text.contains("<"),!line.text.contains(">") else{throw VMMError.message("LRCに書き出せない文字があります。")}
            if let segments=line.segments {
                var index=0
                for segment in segments {
                    guard segment.startIndex==index,segment.endIndex<=chars.count,segment.start>=0,segment.end>=segment.start,line.start+segment.end<=line.end+0.001 else{throw VMMError.message("文字タイミングが不正か、未指定の文字があります。")}
                    result += stamp(line.start+segment.start)+String(chars[segment.startIndex..<segment.endIndex])+stamp(line.start+segment.end)
                    index=segment.endIndex
                }
                guard index==chars.count else{throw VMMError.message("未指定の文字タイミングがあります。")};result += "\n"
            } else {result += stamp(line.start)+line.text+"\n";if i==lines.count-1 || lines[i+1].start>line.end+0.000001 {result += stamp(line.end)+"\n"}}
            for item in line.ruby ?? [] {
                guard item.startIndex>=0,item.endIndex>item.startIndex,item.endIndex<=chars.count,!item.text.contains(","),!item.text.contains("[") else{throw VMMError.message("ルビをLRCに書き出せません。")}
                let target=String(chars[item.startIndex..<item.endIndex]),position=line.segments?.first(where:{$0.startIndex<=item.startIndex && item.startIndex<$0.endIndex}).map{line.start+$0.start} ?? line.start
                let targetChars=Array(target)
                for pos in 0...(chars.count-targetChars.count) where pos != item.startIndex && Array(chars[pos..<pos+targetChars.count])==targetChars {
                    let other=line.segments?.first(where:{$0.startIndex<=pos && pos<$0.endIndex}).map{line.start+$0.start} ?? line.start
                    if abs(position-other)<0.0005 {throw VMMError.message("同じ時刻に同じルビ対象が複数あるためLRCに正確に書き出せません。文字タイミングを分けてください。")}
                }
                var reading="";let markers=item.timings ?? [],readingChars=Array(item.text)
                for (n,ch) in readingChars.enumerated(){if let marker=markers.first(where:{$0.index==n}){reading+=stamp(marker.offset)};reading.append(ch)}
                guard markers.allSatisfy({$0.index>=0 && $0.index<readingChars.count}) else{throw VMMError.message("ルビのタイミングが不正です。")}
                rubyTags.append("@Ruby\(rubyTags.count+1)=\(target),\(reading),\(stamp(position)),\(stamp(position))")
            }
        }
        let headers=(lines.first?.lrcMetadata ?? [])+rubyTags
        return headers.joined(separator:"\n")+(headers.isEmpty ? "":"\n")+result
    }
}
