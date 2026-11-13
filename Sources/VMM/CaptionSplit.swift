import SwiftUI

struct CaptionSplitPart: Identifiable, Equatable {
    var id = UUID()
    var text: String
    var start: Double
    var end: Double
}
struct CaptionSplitPresentation:Identifiable {
    var id=UUID()
    var original:Clip
    var parts:[CaptionSplitPart]
}

enum CaptionSplitPlanner {
    /// Split into readable groups and distribute the available frames by character count.
    /// This is a timing suggestion, not speech recognition or forced alignment.
    static func suggest(_ clip: Clip, fps: Int) throws -> [CaptionSplitPart] {
        guard clip.kind == .speech, clip.speechCaptionHidden != true, fps > 0 else { throw VMMError.message("字幕を分割できるセリフを選択してください。") }
        let text = clip.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let first = Int(ceil(clip.start * Double(fps) - 1e-8)), last = Int(floor(clip.end * Double(fps) + 1e-8))
        guard !text.isEmpty, last > first else { throw VMMError.message("字幕の文章または長さが不足しています。") }
        let chars = Array(text), maxParts = min(100, last - first)
        let maxLength = max(14, Int(ceil(Double(chars.count) / Double(maxParts))))
        var groups:[String] = [], buffer = ""
        for char in chars {
            if char == "\n" {
                if groups.count + 1 < maxParts && !buffer.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {groups.append(buffer.trimmingCharacters(in:.whitespacesAndNewlines));buffer=""}
                else {buffer.append(" ")}
            } else {
                buffer.append(char)
                if groups.count + 1 < maxParts && !buffer.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && (buffer.count >= maxLength || (buffer.count >= 7 && "。！？!?".contains(char))) {
                    groups.append(buffer.trimmingCharacters(in:.whitespacesAndNewlines));buffer=""
                }
            }
        }
        if !buffer.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {groups.append(buffer.trimmingCharacters(in:.whitespacesAndNewlines))}
        guard !groups.isEmpty, groups.count <= maxParts else { throw VMMError.message("字幕の文章または長さが不足しています。") }
        let total = groups.reduce(0){$0 + max(1,$1.count)}, frames = last-first
        var previous=first, used=0, parts:[CaptionSplitPart]=[]
        for (index,group) in groups.enumerated() {
            used += max(1,group.count)
            let remaining = groups.count-index-1
            let next = index == groups.count-1 ? last : min(last-remaining,max(previous+1,first+Int((Double(frames)*Double(used)/Double(total)).rounded())))
            parts.append(CaptionSplitPart(text:group,start:Double(previous)/Double(fps),end:Double(next)/Double(fps)));previous=next
        }
        return parts
    }
}

@MainActor extension EditorStore {
    func applyCaptionSplit(original:Clip, fps:Int, parts:[CaptionSplitPart]) throws {
        guard !busy, project.fps == fps, let index=project.clips.firstIndex(where:{$0.id==original.id}), project.clips[index] == original else {throw VMMError.message("セリフが変更されました。もう一度開いてください。")}
        func editable(_ clip:Clip)->Bool {
            var current:Clip?=clip,seen=Set<UUID>()
            while let value=current,seen.insert(value.id).inserted {
                guard project.tracks.indices.contains(value.track),!project.tracks[value.track].locked else{return false}
                current=value.parentID.flatMap{id in project.clips.first{$0.id==id}}
            }
            return current == nil
        }
        guard original.kind == .speech, original.speechCaptionHidden != true, !generatingSpeech.contains(original.id),editable(original),
              !project.clips.contains(where:{($0.sceneMembers ?? []).contains(original.id) && !editable($0)}) else {throw VMMError.message("字幕を分割できるセリフを選択してください。")}
        guard !parts.isEmpty,parts.count<=100 else {throw VMMError.message("字幕の件数が不正です。")}
        let scale=Double(fps), epsilon=1e-7
        var lastEnd=original.start
        for part in parts {
            guard !part.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,part.text.count<=10000,
                  part.start.isFinite,part.end.isFinite,part.start>=original.start-epsilon,part.end<=original.end+epsilon,
                  part.end-part.start >= 1/scale-epsilon,part.start>=lastEnd-epsilon,
                  abs(part.start*scale-(part.start*scale).rounded())<epsilon,abs(part.end*scale-(part.end*scale).rounded())<epsilon else {throw VMMError.message("字幕の時刻・順序・文章を確認してください。")}
            lastEnd=part.end
        }
        var candidate=project, base=original
        base.preserveAnimationDomain()
        candidate.clips[index].speechCaptionHidden=true
        candidate.clips[index].preserveSpeechDuration=true
        var searchFrom=original.text.startIndex
        let captions=parts.map { part -> Clip in
            var copy=base
            copy.id=UUID();copy.kind = .text;copy.name=String(part.text.prefix(40));copy.text=part.text
            if let match=original.text.range(of:part.text,range:searchFrom..<original.text.endIndex) {
                let start=original.text.distance(from:original.text.startIndex,to:match.lowerBound)
                copy.textRuns=TextRunEditing.slice(original.textRuns,range:start..<(start+part.text.count));searchFrom=match.upperBound
            } else {copy.textRuns=nil}
            copy.start=part.start;copy.duration=part.end-part.start;copy.animationOffset=base.animationTimeOffset+part.start-original.start
            copy.assetID=nil;copy.reading=nil;copy.scriptSequenceID=nil;copy.linkID=nil;copy.sceneMembers=nil
            copy.speechCaptionHidden=nil;copy.speechConfiguration=nil;copy.preserveSpeechDuration=nil;copy.speechDirty=false
            copy.audioFade=nil;copy.ducking=nil;copy.playbackRate=nil;copy.preservePitch=nil;copy.pitchSemitones=nil;copy.equalizer=nil
            copy.audioDisabled=nil;copy.normalizationGain=nil;copy.measuredLUFS=nil;copy.pan=nil
            return copy
        }
        candidate.clips.append(contentsOf:captions);candidate.registerSceneCopies([original.id:captions.map(\.id)]);_=try candidate.validated()
        pause();checkpoint();project=candidate;selectedIDs=Set(captions.map(\.id));selectedID=captions.first?.id
    }
}

struct CaptionSplitSheet: View {
    @ObservedObject var store: EditorStore
    @Environment(\.dismiss) private var dismiss
    let original: Clip
    let fps: Int
    @State private var parts:[CaptionSplitPart]
    @State private var error:String?
    init(store:EditorStore,clip:Clip,parts:[CaptionSplitPart]) {self.store=store;original=clip;fps=store.project.fps;_parts=State(initialValue:parts)}
    private func split(_ id:UUID) {
        guard let i=parts.firstIndex(where:{$0.id==id}),parts.count<100 else{return}
        let item=parts[i],chars=Array(item.text),start=Int((item.start*Double(fps)).rounded()),end=Int((item.end*Double(fps)).rounded())
        guard chars.count>=2,end-start>=2 else {error=L("この字幕はこれ以上分割できません。");return}
        let midpoint=chars.count/2,left=String(chars[..<midpoint]).trimmingCharacters(in:.whitespacesAndNewlines),right=String(chars[midpoint...]).trimmingCharacters(in:.whitespacesAndNewlines)
        guard !left.isEmpty,!right.isEmpty else {error=L("この字幕はこれ以上分割できません。");return}
        let time=Double(start+(end-start)/2)/Double(fps)
        parts[i].text=left;parts[i].end=time;parts.insert(CaptionSplitPart(text:right,start:time,end:item.end),at:i+1);error=nil
    }
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text(L("字幕分割・タイミング調整")).font(.title2)
            Text(L("時刻は文字数からの目安です。音声を確認して修正してください。元のセリフ音声は変更しません。")).foregroundColor(.secondary)
            ScrollView {VStack(alignment:.leading,spacing:12) {
                ForEach($parts) { $part in
                    VStack(alignment:.leading,spacing:6) {
                        TextField(L("字幕"),text:$part.text,axis:.vertical).textFieldStyle(.roundedBorder)
                        HStack {
                            NumberInput(title:"開始フレーム",value:Binding(get:{part.start*Double(fps)},set:{part.start=$0.rounded()/Double(fps)}),range:ceil(original.start*Double(fps))...floor(original.end*Double(fps)))
                            NumberInput(title:"終了フレーム",value:Binding(get:{part.end*Double(fps)},set:{part.end=$0.rounded()/Double(fps)}),range:ceil(original.start*Double(fps))...floor(original.end*Double(fps)))
                            Button {store.seek(part.start);store.play()} label:{Image(systemName:"play.fill")}.help(L("この位置から再生"))
                            Button {split(part.id)} label:{Image(systemName:"scissors")}.help(L("この字幕を分割"))
                            Button(role:.destructive){parts.removeAll{$0.id==part.id}} label:{Image(systemName:"trash")}.help(L("この字幕を削除"))
                        }
                        Text(String(format:"%.3f – %.3f s",part.start,part.end)).foregroundColor(.secondary)
                    }.padding(8).background(Color.secondary.opacity(0.06)).cornerRadius(6)
                }
            }}
            if let error {Text(error).foregroundColor(.red)}
            HStack {Spacer();Button(L("キャンセル")){dismiss()};Button(L("字幕を作成")) {do{try store.applyCaptionSplit(original:original,fps:fps,parts:parts);dismiss()}catch{self.error=error.localizedDescription}}.keyboardShortcut(.defaultAction)}
        }.padding(20).frame(minWidth:700,minHeight:440).onDisappear{store.pause()}
    }
}
