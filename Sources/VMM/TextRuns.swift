import Foundation

/// Character indices use Swift extended grapheme clusters, never UTF-16 code units.
struct TextRunStyle:Codable,Equatable {
    var color:String?
    var fontName:String?
    var fontSize:Double?
    var outline:Bool?
    var outlineColor:String?
    var outlineWidth:Double?
    var isEmpty:Bool {color == nil && fontName == nil && fontSize == nil && outline == nil && outlineColor == nil && outlineWidth == nil}
}
struct TextRun:Codable,Equatable {
    var start:Int
    var end:Int
    var style:TextRunStyle
}
enum TextRunEditing {
    static func validate(_ runs:[TextRun]?,text:String)throws {
        guard let runs else{return}
        guard runs.count<=1024 else {throw VMMError.message("文字装飾が多すぎます。")}
        var previous=0;let length=text.count
        for run in runs {
            let s=run.style
            guard run.start>=previous,run.end>run.start,run.end<=length,!s.isEmpty,
                  s.fontSize.map({$0.isFinite && (4...500).contains($0)}) ?? true,
                  s.outlineWidth.map({$0.isFinite && (0...20).contains($0)}) ?? true,
                  s.fontName.map({!$0.isEmpty && $0.count<=200}) ?? true,
                  [s.color,s.outlineColor].compactMap({$0}).allSatisfy({$0.count==6 && $0.allSatisfy(\.isHexDigit)}) else{throw VMMError.message("文字装飾の範囲または設定が不正です。")}
            previous=run.end
        }
    }
    static func styles(_ runs:[TextRun]?,count:Int)->[TextRunStyle] {
        var values=[TextRunStyle](repeating:TextRunStyle(),count:max(0,count))
        for run in runs ?? [] where run.start>=0 && run.start<count && run.end>run.start {for i in run.start..<min(run.end,count) {values[i]=run.style}}
        return values
    }
    static func runs(_ styles:[TextRunStyle])->[TextRun]? {
        var result:[TextRun]=[],index=0
        while index<styles.count {
            let style=styles[index],start=index;index+=1
            while index<styles.count && styles[index]==style {index+=1}
            if !style.isEmpty {result.append(TextRun(start:start,end:index,style:style))}
        }
        return result.isEmpty ? nil:result
    }
    /// Keep unaffected prefix/suffix, and inherit the preceding style for inserted characters.
    static func rebase(_ runs:[TextRun]?,old:String,new:String)->[TextRun]? {
        guard old != new,let runs else{return runs}
        let a=Array(old),b=Array(new),oldStyles=styles(runs,count:a.count)
        var prefix=0;while prefix<min(a.count,b.count),a[prefix]==b[prefix] {prefix+=1}
        var suffix=0;while suffix<min(a.count-prefix,b.count-prefix),a[a.count-1-suffix]==b[b.count-1-suffix] {suffix+=1}
        let inherited=prefix>0 ? oldStyles[prefix-1]:(suffix>0 ? oldStyles[a.count-suffix]:TextRunStyle())
        return self.runs(Array(oldStyles.prefix(prefix))+[TextRunStyle](repeating:inherited,count:b.count-prefix-suffix)+Array(oldStyles.suffix(suffix)))
    }
    static func apply(_ runs:[TextRun]?,text:String,range:Range<Int>,change:(inout TextRunStyle)->Void)throws->[TextRun]? {
        guard range.lowerBound>=0,range.upperBound<=text.count,!range.isEmpty else{throw VMMError.message("装飾する文字を選択してください。")}
        var values=styles(runs,count:text.count)
        for i in range {change(&values[i])}
        let result=self.runs(values);try validate(result,text:text);return result
    }
    static func slice(_ runs:[TextRun]?,range:Range<Int>)->[TextRun]? {
        guard let runs else{return nil}
        let parts=runs.compactMap{run->TextRun? in let start=max(run.start,range.lowerBound),end=min(run.end,range.upperBound);return end>start ? TextRun(start:start-range.lowerBound,end:end-range.lowerBound,style:run.style):nil}
        return parts.isEmpty ? nil:parts
    }
}
