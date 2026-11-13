import AVFoundation
import Speech
import SwiftUI

struct TranscriptToken:Equatable {
    var text:String
    /// Time within the trimmed original audio, before timeline speed is applied.
    var start:Double
    var duration:Double
}

enum TranscriptPlanner {
    static let maximumAudioSeconds=55.0
    static func validateSource(_ clip:Clip,project:Project) throws -> MediaAsset {
        guard !clip.hasTimeWarp else {throw VMMError.message("逆再生・可変速度の素材は文字起こしに対応していません。")}
        guard [.audio,.video,.speech].contains(clip.kind),!(clip.kind == .speech && clip.speechDirty),
              let asset=project.asset(for:clip),clip.duration>0,clip.mediaRate>0,
              clip.duration<=maximumAudioSeconds,clip.duration*clip.mediaRate<=maximumAudioSeconds else {
            throw VMMError.message("音声または動画を1つ選択してください。文字起こしは使用区間と元素材の両方が55秒以内です。")
        }
        return asset
    }
    /// Map recognition timestamps in source seconds onto the clip's timeline frames.
    static func parts(_ tokens:[TranscriptToken],clip:Clip,fps:Int)throws->[CaptionSplitPart] {
        guard fps>0,clip.mediaRate.isFinite,clip.mediaRate>0,tokens.count<=5000 else{throw VMMError.message("文字起こし結果が不正です。")}
        var groups:[(text:String,start:Double,end:Double)]=[]
        for token in tokens.sorted(by:{$0.start<$1.start}) {
            let word=token.text.trimmingCharacters(in:.whitespacesAndNewlines)
            guard !word.isEmpty,word.count<=10000,token.start.isFinite,token.duration.isFinite,token.start>=0,token.duration>=0 else{continue}
            let start=clip.start+token.start/clip.mediaRate,end=min(clip.end,clip.start+(token.start+max(token.duration,0.04))/clip.mediaRate)
            guard start<clip.end,end>clip.start else {continue}
            let needsSpace:Bool = {
                guard let last=groups.last?.text.last,let first=word.first else{return false}
                return last.isASCII && (last.isLetter || last.isNumber) && first.isASCII && (first.isLetter || first.isNumber)
            }()
            if let last=groups.last,(last.text.count+word.count>24 || start-last.end>0.7 || end-last.start>4 || "。！？!?".contains(last.text.last ?? " ")) {
                groups.append((word,start,end))
            } else if !groups.isEmpty {
                groups[groups.count-1].text += (needsSpace ? " ":"")+word
                groups[groups.count-1].end=max(groups[groups.count-1].end,end)
            } else {groups.append((word,start,end))}
        }
        let first=Int(ceil(clip.start*Double(fps)-1e-7)),last=Int(floor(clip.end*Double(fps)+1e-7))
        guard last>first else {throw VMMError.message("文字起こしできる長さがありません。")}
        var result:[CaptionSplitPart]=[]
        for group in groups {
            let start=max(first,result.last.map{Int(($0.end*Double(fps)).rounded())} ?? first,Int((group.start*Double(fps)).rounded()))
            if start>=last {
                if !result.isEmpty {result[result.count-1].text += group.text}
                continue
            }
            let end=min(last,max(start+1,Int((group.end*Double(fps)).rounded())))
            result.append(CaptionSplitPart(text:group.text,start:Double(start)/Double(fps),end:Double(end)/Double(fps)))
        }
        guard !result.isEmpty,result.count<=2000 else {throw VMMError.message("認識できる文章がありませんでした。")}
        return result
    }
}

/// Restricts recognition to an explicitly selected, bounded local audio range.
enum LocalTranscription {
    static func audioRange(source:URL,clip:Clip,destination:URL) async throws {
        let asset=AVURLAsset(url:source)
        guard let track=try await asset.loadTracks(withMediaType:.audio).first else {throw VMMError.message("選択した素材に音声がありません。")}
        let duration=try await asset.load(.duration).seconds
        let amount=min(clip.duration*clip.mediaRate,duration-clip.sourceOffset)
        guard amount.isFinite,amount>0,amount<=TranscriptPlanner.maximumAudioSeconds else {throw VMMError.message("音声の使用範囲が不正です。")}
        let composition=AVMutableComposition()
        guard let target=composition.addMutableTrack(withMediaType:.audio,preferredTrackID:kCMPersistentTrackID_Invalid) else{throw VMMError.message("音声を準備できません。")}
        let requested=CMTimeRange(start:CMTime(seconds:clip.sourceOffset,preferredTimescale:48000),duration:CMTime(seconds:amount,preferredTimescale:48000))
        let available=try await track.load(.timeRange),intersection=CMTimeRangeGetIntersection(requested,otherRange:available)
        guard intersection.isValid,!intersection.isEmpty else{throw VMMError.message("音声の使用範囲が不正です。")}
        try target.insertTimeRange(intersection,of:track,at:CMTimeSubtract(intersection.start,requested.start))
        guard let exporter=AVAssetExportSession(asset:composition,presetName:AVAssetExportPresetAppleM4A) else{throw VMMError.message("音声を準備できません。")}
        exporter.outputURL=destination;exporter.outputFileType = .m4a
        await withTaskCancellationHandler(operation:{await withCheckedContinuation { continuation in exporter.exportAsynchronously {continuation.resume()} }},onCancel:{exporter.cancelExport()})
        try Task.checkCancellation()
        guard exporter.status == .completed else{throw exporter.error ?? VMMError.message("音声の準備に失敗しました。")}
    }
    static func recognize(source:URL,clip:Clip,language:String) async throws -> [TranscriptToken] {
        let scratch=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-transcription-\(UUID())",isDirectory:true)
        try FileManager.default.createDirectory(at:scratch,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:scratch)}
        let cropped=scratch.appendingPathComponent("source.m4a")
        try await audioRange(source:source,clip:clip,destination:cropped)
        try Task.checkCancellation()
        let authorization:SFSpeechRecognizerAuthorizationStatus
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            authorization=await withCheckedContinuation {continuation in SFSpeechRecognizer.requestAuthorization {continuation.resume(returning:$0)}}
        } else {authorization=SFSpeechRecognizer.authorizationStatus()}
        try Task.checkCancellation()
        guard authorization == .authorized else {throw VMMError.message("音声認識が許可されていません。システム設定を確認してください。")}
        guard let recognizer=SFSpeechRecognizer(locale:Locale(identifier:language)),recognizer.isAvailable,recognizer.supportsOnDeviceRecognition else {throw VMMError.message("この言語の端末内音声認識を使用できません。")}
        let request=SFSpeechURLRecognitionRequest(url:cropped);request.requiresOnDeviceRecognition=true;request.shouldReportPartialResults=false
        return try await LocalRecognitionJob().run(recognizer:recognizer,request:request)
    }
}

/// Guarantees a single continuation resume even when cancellation races recognition.
private final class LocalRecognitionJob {
    private let lock=NSLock()
    private var continuation:CheckedContinuation<[TranscriptToken],Error>?
    private var task:SFSpeechRecognitionTask?
    private var cancelled=false
    func run(recognizer:SFSpeechRecognizer,request:SFSpeechURLRecognitionRequest) async throws -> [TranscriptToken] {
        try await withTaskCancellationHandler(operation:{
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled {lock.unlock();continuation.resume(throwing:CancellationError());return}
                self.continuation=continuation;lock.unlock()
                let task=recognizer.recognitionTask(with:request){[weak self] result,error in
                    if let result,result.isFinal {
                        self?.finish(.success(result.bestTranscription.segments.map{TranscriptToken(text:$0.substring,start:$0.timestamp,duration:$0.duration)}))
                    } else if let error {self?.finish(.failure(error))}
                }
                lock.lock();self.task=task;let shouldCancel=cancelled;lock.unlock();if shouldCancel {task.cancel()}
            }
        },onCancel:{self.cancel()})
    }
    private func finish(_ result:Result<[TranscriptToken],Error>) {
        lock.lock();let c=continuation;continuation=nil;task=nil;lock.unlock();c?.resume(with:result)
    }
    private func cancel() {
        lock.lock();cancelled=true;let current=task;let c=continuation;continuation=nil;task=nil;lock.unlock()
        current?.cancel();c?.resume(throwing:CancellationError())
    }
}

@MainActor extension EditorStore {
    func applyTranscript(snapshot:Project,directory:URL,sourceID:UUID,trackID:UUID,parts:[CaptionSplitPart]) throws {
        guard !busy,self.directory==directory,project==snapshot,selectedID==sourceID,selection == Set([sourceID]),
              let source=project.clips.first(where:{$0.id==sourceID}),let track=project.tracks.firstIndex(where:{$0.id==trackID}),!project.tracks[track].locked else {throw VMMError.message("プロジェクト・選択・レイヤーが変更されました。もう一度文字起こししてください。")}
        _=try TranscriptPlanner.validateSource(source,project:project)
        guard !parts.isEmpty,parts.count<=2000 else{throw VMMError.message("字幕の件数が不正です。")}
        let fps=Double(project.fps),epsilon=1e-7
        var previous=source.start
        for part in parts {
            guard !part.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,part.text.count<=10000,
                  part.start.isFinite,part.end.isFinite,part.start>=previous-epsilon,part.start>=source.start-epsilon,part.end<=source.end+epsilon,
                  part.end-part.start>=1/fps-epsilon,abs(part.start*fps-(part.start*fps).rounded())<epsilon,abs(part.end*fps-(part.end*fps).rounded())<epsilon else{throw VMMError.message("字幕の時刻・順序・文章を確認してください。")}
            previous=part.end
        }
        var candidate=project
        let clips=parts.map{part -> Clip in var clip=Clip(kind:.text,name:String(part.text.prefix(40)),track:track,start:part.start,duration:part.end-part.start,text:part.text);clip.y=0.85;return clip}
        candidate.clips.append(contentsOf:clips);_=try candidate.validated()
        pause();checkpoint();project=candidate;selectedIDs=Set(clips.map(\.id));selectedID=clips.first?.id
    }
}

struct TranscriptionSheet:View {
    @ObservedObject var store:EditorStore
    @Environment(\.dismiss) private var dismiss
    let source:Clip
    let snapshot:Project
    let directory:URL
    @State private var trackID:UUID
    @State private var language="ja-JP"
    @State private var parts:[CaptionSplitPart]=[]
    @State private var job:Task<Void,Never>?
    @State private var error:String?
    init(store:EditorStore,source:Clip) {
        self.store=store;self.source=source;snapshot=store.project;directory=store.directory
        _trackID=State(initialValue:store.project.tracks[store.selectedTrack].id)
    }
    private func start() {
        do {
            guard store.project==snapshot,store.directory==directory,store.selectedID==source.id,store.selection == Set([source.id]) else{throw VMMError.message("プロジェクト・選択・レイヤーが変更されました。もう一度文字起こししてください。")}
            guard snapshot.tracks.contains(where:{$0.id==trackID && !$0.locked}) else {throw VMMError.message("字幕の配置先のロックを解除してください。")}
            let asset=try TranscriptPlanner.validateSource(source,project:snapshot)
            let url=directory.appendingPathComponent("Media").appendingPathComponent(asset.file)
            guard FileManager.default.fileExists(atPath:url.path) else {throw VMMError.message("音声素材が見つかりません。")}
            error=nil;parts=[]
            job=Task {
                do {let tokens=try await LocalTranscription.recognize(source:url,clip:source,language:language);try Task.checkCancellation();parts=try TranscriptPlanner.parts(tokens,clip:source,fps:snapshot.fps)}
                catch is CancellationError {}
                catch {self.error=error.localizedDescription}
                job=nil
            }
        } catch {self.error=error.localizedDescription}
    }
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text(L("音声から字幕を作成")).font(.title2)
            Text("\(L("認識するアイテム"))：\(source.name)")
            Text(L("選択した音声の使用区間を端末内で認識します。使用区間と元素材の長さは各55秒以内です。" )).foregroundColor(.secondary)
            Text(L("音声の元データを解析します。速度とトリムは字幕の時刻に反映し、音量・EQ等の加工は解析に含めません。" )).foregroundColor(.secondary)
            HStack {
                VMMMenuPicker(L("認識言語"),selection:$language){VMMChoice(text:L("日本語"),value:"ja-JP");VMMChoice(text:L("英語"),value:"en-US")}.frame(width:170)
                VMMMenuPicker(L("字幕の配置先"),selection:$trackID){VMMOptions(snapshot.tracks){track in VMMChoice(text:track.name+(track.locked ? " 🔒":""),value:track.id)}}.frame(width:230)
                Button(L("文字起こしを開始")){start()}.disabled(job != nil)
                if job != nil {ProgressView().controlSize(.small);Button(L("中止")){job?.cancel()}}
            }
            if !parts.isEmpty {
                Text(L("認識結果を確認し、文章と時刻を修正してください。" )).foregroundColor(.secondary)
                ScrollView {VStack(alignment:.leading,spacing:8) {
                    ForEach($parts) {$part in
                        VStack(alignment:.leading,spacing:4) {
                            TextField(L("字幕"),text:$part.text,axis:.vertical).textFieldStyle(.roundedBorder)
                            HStack {
                                NumberInput(title:"開始フレーム",value:Binding(get:{part.start*Double(snapshot.fps)},set:{part.start=$0.rounded()/Double(snapshot.fps)}),range:ceil(source.start*Double(snapshot.fps))...floor(source.end*Double(snapshot.fps)))
                                NumberInput(title:"終了フレーム",value:Binding(get:{part.end*Double(snapshot.fps)},set:{part.end=$0.rounded()/Double(snapshot.fps)}),range:ceil(source.start*Double(snapshot.fps))...floor(source.end*Double(snapshot.fps)))
                                Button(role:.destructive){parts.removeAll{$0.id==part.id}} label:{Image(systemName:"trash")}.help(L("この字幕を削除"))
                            }
                        }.padding(8).background(Color.secondary.opacity(0.06)).cornerRadius(6)
                    }
                }}
            } else {Spacer()}
            if let error {Text(L(error)).foregroundColor(.red).textSelection(.enabled)}
            HStack {Spacer();Button(L("キャンセル")){dismiss()};Button(L("字幕を作成")){do{try store.applyTranscript(snapshot:snapshot,directory:directory,sourceID:source.id,trackID:trackID,parts:parts);dismiss()}catch{self.error=error.localizedDescription}}.disabled(parts.isEmpty || job != nil).keyboardShortcut(.defaultAction)}
        }.padding(20).frame(minWidth:700,minHeight:440).onDisappear{job?.cancel()}
    }
}
