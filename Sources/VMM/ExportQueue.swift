import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct QueuedExport:Codable,Identifiable {
    enum State:String,Codable {case queued,running,completed,failed,cancelled}
    var id:UUID
    var name:String
    var destination:URL
    var options:UserSettings
    var state:State = .queued
    var progress:Double=0
    var error:String?
    var overwrite:Bool=false
    var created=Date()
}
@MainActor final class ExportQueue:ObservableObject {
    @Published private(set) var jobs:[QueuedExport]=[]
    @Published private(set) var paused=true
    @Published private(set) var runningID:UUID?
    @Published private(set) var activePhase:ExportPhase?
    weak var store:EditorStore?
    let root:URL
    private var task:Task<Void,Never>?
    init(root:URL,store:EditorStore?=nil) {
        self.root=root;self.store=store
        if let data=try? Data(contentsOf:root.appendingPathComponent("queue.json")),let saved=try? JSONDecoder().decode([QueuedExport].self,from:data),saved.count<=100 {
            jobs=saved.filter{job in job.destination.isFileURL && ["mp4","mov"].contains(job.destination.pathExtension.lowercased()) && (try? job.options.validated()) != nil}
            for i in jobs.indices where jobs[i].state == .running {jobs[i].state = .queued;jobs[i].progress=0}
        }
    }
    func snapshot(_ id:UUID)->URL {root.appendingPathComponent(id.uuidString).appendingPathComponent("snapshot.vmm")}
    private func persist()throws {try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);try JSONEncoder().encode(jobs).write(to:root.appendingPathComponent("queue.json"),options:.atomic)}
    @discardableResult private func persistStatus()->Bool {
        do {try persist();return true}
        catch {paused=true;store?.error="書き出しキューを保存できません。\n\(error.localizedDescription)";return false}
    }
    @discardableResult func complete(_ id:UUID)->Bool {
        guard let index=jobs.firstIndex(where:{$0.id==id}) else{return false}
        jobs[index].state = .completed;jobs[index].progress=1
        guard persistStatus() else{return false}
        try? FileManager.default.removeItem(at:snapshot(id))
        return true
    }
    @discardableResult func add(project:Project,directory:URL,options:UserSettings,destination:URL,overwrite:Bool=false)async throws->UUID {
        guard jobs.count<100,destination.isFileURL,["mp4","mov"].contains(destination.pathExtension.lowercased()) else{throw VMMError.message("キューは100件まで、出力先はMP4/MOVにしてください。")}
        guard overwrite || (!FileManager.default.fileExists(atPath:destination.path) && !jobs.contains{$0.destination.standardizedFileURL==destination.standardizedFileURL && [.queued,.running].contains($0.state)}) else{throw VMMError.message("出力先が既存ファイルまたはキューと重複しています。上書きを明示してください。")}
        let id=UUID(),target=snapshot(id)
        var saved=project;saved.assets.removeAll{!project.usedAssetIDs.contains($0.id)}
        let report=await Task.detached {ExportPreflight.inspect(project:saved,directory:directory,options:options,destination:destination)}.value
        guard report.canExport else{throw VMMError.message(report.issues.filter{$0.severity == .error}.map(\.message).joined(separator:"\n"))}
        try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
        do {
            try await Task.detached(priority:.utility){try ProjectPackage.write(saved,media:directory.appendingPathComponent("Media"),to:target,allowMissing:true)}.value
            jobs.append(QueuedExport(id:id,name:saved.name,destination:destination,options:options,overwrite:overwrite))
            do {try persist()}catch {jobs.removeAll{$0.id==id};throw error}
        } catch {try? FileManager.default.removeItem(at:target.deletingLastPathComponent());throw error}
        return id
    }
    func resume() {
        paused=false
        guard task==nil else{return}
        task=Task { [weak self] in
            guard let self else{return}
            defer{self.task=nil;self.runningID=nil;self.activePhase=nil;self.paused=true}
            while !self.paused,let index=self.jobs.firstIndex(where:{$0.state == .queued}) {
                if self.store?.busy == true {try? await Task.sleep(nanoseconds:100_000_000);continue}
                let job=self.jobs[index],source=self.snapshot(job.id)
                self.runningID=job.id;self.activePhase = .preparing;self.jobs[index].state = .running
                guard self.persistStatus() else {self.jobs[index].state = .queued;self.jobs[index].progress=0;self.runningID=nil;self.activePhase=nil;break}
                do {
                    let data=try Data(contentsOf:source.appendingPathComponent("project.json")),project=try JSONDecoder().decode(Project.self,from:data).validated()
                    guard job.overwrite || !FileManager.default.fileExists(atPath:job.destination.path) else{throw VMMError.message("出力先にファイルが作成されました。上書きせず停止しました。")}
                    let work=Task.detached(priority:.utility){
                        let report=ExportPreflight.inspect(project:project,directory:source,options:job.options,destination:job.destination)
                        guard report.canExport else{throw VMMError.message(report.issues.filter{$0.severity == .error}.map(\.message).joined(separator:"\n"))}
                        try await MovieExporter.export(project:project,directory:source,destination:job.destination,options:job.options,overwrite:job.overwrite,phase:{phase in
                            Task{@MainActor in guard self.runningID==job.id else{return};if phase.rawValue >= (self.activePhase?.rawValue ?? 0){self.activePhase=phase}}
                        }){progress in
                            Task{@MainActor in guard let current=self.jobs.firstIndex(where:{$0.id==job.id}),self.jobs[current].state == .running else{return};if progress-self.jobs[current].progress>=0.02 {self.jobs[current].progress=progress}}
                        }
                    }
                    try await withTaskCancellationHandler(operation:{try await work.value},onCancel:{work.cancel()})
                    self.complete(job.id)
                } catch is CancellationError {
                    if let current=self.jobs.firstIndex(where:{$0.id==job.id}) {self.jobs[current].state = .cancelled};self.paused=true
                } catch {
                    if let current=self.jobs.firstIndex(where:{$0.id==job.id}) {self.jobs[current].state = .failed;self.jobs[current].error=error.localizedDescription}
                }
                self.runningID=nil;self.activePhase=nil;self.persistStatus()
            }
        }
    }
    func pause() {paused=true}
    func cancelCurrent() {paused=true;task?.cancel()}
    func retry(_ id:UUID)throws {
        guard let index=jobs.firstIndex(where:{$0.id==id}),[.failed,.cancelled].contains(jobs[index].state),FileManager.default.fileExists(atPath:snapshot(id).path) else{throw VMMError.message("再試行できるスナップショットがありません。")}
        jobs[index].state = .queued;jobs[index].progress=0;jobs[index].error=nil;try persist()
    }
    func remove(_ id:UUID)throws {
        guard runningID != id else{throw VMMError.message("実行中の項目は先に中止してください。")}
        jobs.removeAll{$0.id==id};try persist();try? FileManager.default.removeItem(at:root.appendingPathComponent(id.uuidString))
    }
    func move(_ id:UUID,offset:Int)throws {
        guard let index=jobs.firstIndex(where:{$0.id==id}),jobs[index].state == .queued else{return}
        let target=min(max(0,index+offset),jobs.count-1)
        guard jobs[target].state != .running else{return}
        let job=jobs.remove(at:index);jobs.insert(job,at:target);try persist()
    }
}
@MainActor extension EditorStore {
    @discardableResult func queueExport(to destination:URL,overwrite:Bool=false)async throws->UUID {
        guard !busy,finishPendingPreviewText(),generatingSpeech.isEmpty else{throw VMMError.message("処理や音声生成が完了してからキューへ追加してください。")}
        let source=directory,snapshot=project,options=settings
        busy=true;retainSession(source);defer{releaseSession(source);busy=false}
        let id=try await exportQueue.add(project:snapshot,directory:source,options:options,destination:destination,overwrite:overwrite)
        status="書き出しキューへ追加しました。";return id
    }
    func chooseQueueExport() {
        guard !busy else{return}
        let panel=NSSavePanel();panel.allowedContentTypes=[settings.exportContainer == "MOV" ? .quickTimeMovie:.mpeg4Movie];panel.nameFieldStringValue=project.name+(settings.exportContainer == "MOV" ? ".mov":".mp4")
        guard panel.runModal() == .OK,let url=panel.url else{return}
        let overwrite=FileManager.default.fileExists(atPath:url.path)
        Task{do{_=try await queueExport(to:url,overwrite:overwrite)}catch{self.error=error.localizedDescription}}
    }
}
struct ExportQueueView:View {
    @ObservedObject var queue:ExportQueue
    var body:some View {VStack(alignment:.leading,spacing:12){
        HStack {Button(L("キューを開始")){queue.resume()}.disabled(!queue.paused);Button(L("この出力後に停止")){queue.pause()};Button(L("実行中の出力を中止")){queue.cancelCurrent()}.disabled(queue.runningID==nil)}
        Text(L("追加時のプロジェクトと設定を保存して順に出力します。出力中も編集できます。再起動後は開始ボタンで再開します。")).foregroundColor(.secondary)
        ForEach(queue.jobs){job in VStack(alignment:.leading,spacing:6){
            HStack{Text(job.name).bold();Spacer();Text(L(job.state.rawValue));Button(L("上へ")){queue.store?.reportEditing{try queue.move(job.id,offset:-1)}};Button(L("下へ")){queue.store?.reportEditing{try queue.move(job.id,offset:1)}}}
            Text(job.destination.path).lineLimit(1).foregroundColor(.secondary)
            if job.state == .running {if let phase=queue.activePhase {Text(L(phase.title)).foregroundColor(.secondary)};ProgressView(value:job.progress)}
            if let error=job.error {Text(L(error)).foregroundColor(.orange)}
            HStack {if [.failed,.cancelled].contains(job.state){Button(L("再試行")){queue.store?.reportEditing{try queue.retry(job.id)}}};Button(L("削除")){queue.store?.reportEditing{try queue.remove(job.id)}}.disabled(job.state == .running)}
        }.padding(12).background(Color.secondary.opacity(0.1)).cornerRadius(8)}
    }}
}

struct ExportActionsView:View {
    @ObservedObject var store:EditorStore
    @ObservedObject var queue:ExportQueue
    var body:some View {VStack(alignment:.leading){HStack {
        Button(L("動画を書き出す")){store.exportMovie()}.buttonStyle(.borderedProminent).disabled(store.busy || !store.generatingSpeech.isEmpty || queue.runningID != nil)
        Button(L("書き出しキューへ追加")){store.chooseQueueExport()}.disabled(store.busy || !store.generatingSpeech.isEmpty)
        Button(L("音声のみ（WAV）")){store.exportAudio()}.disabled(store.busy || !store.generatingSpeech.isEmpty || queue.runningID != nil)
    };Button(L("他編集ソフトへ（描画済みXML・ProRes・WAV）")){store.exportInterchange()}.disabled(store.busy || !store.generatingSpeech.isEmpty || queue.runningID != nil)}}
}
