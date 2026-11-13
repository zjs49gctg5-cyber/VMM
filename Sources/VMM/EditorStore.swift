import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class EditorStore: ObservableObject {
    // Retain an active draft even if SwiftUI temporarily removes its preview view.
    var previewTextEditor:ObjectEditingView?
    /// Finish any in-place text draft before snapshotting or replacing the project.
    func finishPendingPreviewText()->Bool {previewTextEditor?.finishTextEditing(commit:true) ?? true}
    @Published var project = Project.demo() {didSet {projectRevision &+= 1}}
    private(set) var projectRevision=0
    @Published var settings=UserSettings()
    @Published var dataExtensions:[DataExtensionPackage]=[]
    @Published var scriptGenerating=false
    var scriptGenerationTask:Task<[AnimationTrack],Error>?
    @Published var selectedMarkerID:UUID?
    lazy var markerWindow=MarkerWindowController(store:self)
    lazy var silenceCutWindow=SilenceCutWindowController(store:self)
    @Published var workspaceSettingsTab=WorkspaceSettingsTab.layout
    @Published var settingsTab=SettingsTab.general
    @Published var catalog=SharedCatalog()
    let preferencesDirectory:URL
    var protectedPreferences:Set<String>=[]
    let scriptWorkerExecutable:URL?
    @Published var selectedIDs:Set<UUID>=[] {didSet{revealSelectedTracks(selectedIDs)}}
    @Published var tool=EditingTool.select
    lazy var panelWindows=EditorPanelWindowController(store:self)
    lazy var precompositionWindows=PrecompositionWindows(owner:self)
    @Published var showAnimationPanel=false
    lazy var workspaceWindows=WorkspaceWindowController(store:self)
    lazy var exportQueue=ExportQueue(root:preferencesDirectory.appendingPathComponent("ExportQueue"),store:self)
    var autosaveTimer:Timer?
    var autosaveTask:Task<Void,Never>?
    var editingPrecompositionID:UUID?
    var sessionReaders:[URL:Int]=[:]
    var retiredSessions:Set<URL>=[]
    var recoveryIdentity=UUID().uuidString
    @Published var projectIOProgress:Double?
    var projectIOID=UUID()
    @Published var selectedID: UUID? {didSet{if let selectedID {revealSelectedTracks([selectedID])}}}
    @Published var selectedTrack = 1
    @Published var collapsedTrackFolders:Set<UUID> = []
    let playbackClock=PlaybackClock()
    var playhead:Double {get{playbackClock.time} set{if !playing {objectWillChange.send()};playbackClock.time=newValue}}
    @Published var playing = false
    var previewPerformance:PreviewPerformance? {get{playbackClock.performance} set{playbackClock.performance=newValue}}
    @Published var zoom: Double = 72
    @Published var layerZoom: Double = 1
    @Published var snapping = true
    @Published var dirty = false
    @Published var status = "素材を読み込むか、セリフを追加してはじめましょう。"
    @Published var error: String?
    var speechService=SpeechService()
    let speechQueue=SpeechGenerationQueue()
    @Published var activeSpeech:Set<UUID>=[]
    @Published var speechFailures:[UUID:String]=[:]
    @Published var speechBatchTotal=0
    @Published var speechBatchCompleted=0
    private var speechBatchIDs:Set<UUID>=[]
    private var voiceConnectionToken=UUID()
    @Published var voices: [VoiceChoice] = []
    @Published var voiceState = "未接続"
    @Published var busy = false
    @Published var exportProgress: Double?
    @Published var exportPhase:ExportPhase?
    private var exportRunID:UUID?
    @Published var exportReport:ExportPreflight?
    @Published var exportChecking=false
    @Published var directory: URL
    @Published var autoSpeech = true { didSet { if autoSpeech { scheduleDirtySpeech() } else { cancelSpeech() } } }
    @Published var generatingSpeech: Set<UUID> = []
    private var speechTasks: [UUID: Task<Void, Never>] = [:]
    private var speechTokens: [UUID: UUID] = [:]
    var libraryAssets: [MediaAsset] {
        let voices = Set(project.clips.filter { $0.kind == .speech }.compactMap(\.assetID))
        return project.assets.filter { $0.generatedSpeech != true && !voices.contains($0.id) }
    }
    @Published var savedURL: URL?
    private var undoStack: [Project] = []
    private var redoStack: [Project] = []
    private var timer: Timer?
    var animationPlaybackRange:TimelineRange?
    var playbackStart: Double = 0
    var playbackOffset: Double = 0
    var players: [UUID: ClipAudioPlayer] = [:]
    var playbackAudioEngine:PlaybackAudioEngine?
    var audioTasks: [UUID:Task<Void,Never>] = [:]
    var audioTokens: [UUID:UUID] = [:]
    private var audioPreparation:Task<Void,Never>?
    private var playbackToken=UUID()
    private var audioModelRevision = -1
    private var audioModelCache:Project?
    func playbackAudioProject()->Project {if audioModelRevision != projectRevision {audioModelCache=project.audioRenderingProject;audioModelRevision=projectRevision};return audioModelCache ?? project}
    private var decodedAudio: [UUID:URL] = [:]
    private var warpedAudio: [UUID:URL] = [:]
    private var warpedAudioDirectory: URL?
    private var missingAudio: Set<UUID> = []
    private var audioSources:[UUID:URL]=[:]
    private var exportTask: Task<Void, Never>?
    var selected: Clip? { project.clips.first { $0.id == selectedID } }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    init(preferencesDirectory:URL=VMMPaths.support,scriptWorkerExecutable:URL?=nil) {
        self.scriptWorkerExecutable=scriptWorkerExecutable
        self.preferencesDirectory=preferencesDirectory
        let loadedSettings=Self.readPreference(UserSettings.self,from:preferencesDirectory.appendingPathComponent("settings.json")) {try $0.validated()}
        let loadedCatalog=Self.readPreference(SharedCatalog.self,from:preferencesDirectory.appendingPathComponent("catalog.json")) {$0}
        settings=loadedSettings.value ?? UserSettings()
        catalog=loadedCatalog.value ?? SharedCatalog()
        if loadedSettings.failed {protectedPreferences.insert("settings.json")}
        if loadedCatalog.failed {protectedPreferences.insert("catalog.json")}
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("vmm-session-\(UUID())")
        try? FileManager.default.createDirectory(at: directory.appendingPathComponent("Media"), withIntermediateDirectories: true)
        loadDataExtensions()
        VMMLocalization.language=settings.uiLanguage ?? .japanese
        selectedID = project.clips.first(where: { $0.kind == .text })?.id
        if !protectedPreferences.isEmpty {
            let names=protectedPreferences.sorted().joined(separator:"、")
            error="設定ファイルを読み込めませんでした: \(names)\n元のファイルを保護するため保存を停止しました。ファイルを修復または別の場所に退避してからVMMを再起動してください。\n場所: \(preferencesDirectory.path)"
        }
    }
    private static func readPreference<T:Decodable>(_ type:T.Type,from url:URL,validate:(T)throws->T)->(value:T?,failed:Bool) {
        do {return (try validate(JSONDecoder().decode(type,from:Data(contentsOf:url))),false)}
        catch {
            let e=error as NSError
            if e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoSuchFileError {return (nil,false)}
            return (nil,true)
        }
    }
    func checkpoint() {
        undoStack.append(project)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
        dirty = true
    }
    func undo() {
        guard !busy, let previous = undoStack.popLast() else { return }
        cancelSpeech(); pause();invalidateAudioCache(); redoStack.append(project); project = previous; reconcileEditingSelection(); dirty = true; scheduleDirtySpeech()
    }
    func redo() {
        guard !busy, let next = redoStack.popLast() else { return }
        cancelSpeech(); pause();invalidateAudioCache(); undoStack.append(project); project = next; reconcileEditingSelection(); dirty = true; scheduleDirtySpeech()
    }
    func edit(_ id: UUID, record: Bool = true, _ change: (inout Clip) -> Void) {
        guard !busy, let index = project.clips.firstIndex(where: { $0.id == id }), !project.tracks[project.clips[index].track].locked else { return }
        let before=project.clips[index];var after=before;change(&after)
        if before.text != after.text && before.textRuns == after.textRuns {after.textRuns=TextRunEditing.rebase(before.textRuns,old:before.text,new:after.text)}
        do {
            try TextRunEditing.validate(after.textRuns,text:after.text)
            if before.effects?.compactMap(\.lut) != after.effects?.compactMap(\.lut) {
                try after.validateAnimation();var check=project;check.clips[index]=after;try check.validateLUTBudget()
            }
            if before.start != after.start || before.duration != after.duration || before.sourceOffset != after.sourceOffset || before.playbackRate != after.playbackRate || before.speedPoints != after.speedPoints || before.reversed != after.reversed {
                let candidate=try LinkedMedia.updated(project,from:before,to:after);pause();if record {checkpoint()};project=candidate
            } else {pause();if record {checkpoint()};project.clips[index]=after}
        }
        catch {self.error=error.localizedDescription;return}
        if after.kind == .speech && (before.text != after.text || before.reading != after.reading || before.speakerID != after.speakerID || before.speechConfiguration != after.speechConfiguration || before.speed != after.speed) {
            project.clips[index].speechDirty = true; scheduleSpeech(id)
        }
        dirty = true
    }
    func binding<T>(_ key: WritableKeyPath<Clip, T>, default fallback: T) -> Binding<T> {
        Binding(get: { self.selected?[keyPath: key] ?? fallback }, set: { value in
            guard let id = self.selectedID else { return }
            self.edit(id) { clip in
                clip[keyPath: key] = value
                if clip.kind == .speech && (key == \Clip.text || key == \Clip.speakerID || key == \Clip.speed) { clip.speechDirty = true }
            }
        })
    }
    func add(_ kind: ClipKind, asset: MediaAsset? = nil) {
        guard !busy, !project.tracks[selectedTrack].locked else { return }
        if let folder=project.tracks[selectedTrack].folderID {collapsedTrackFolders.remove(folder)}
        pause(); checkpoint()
        var clip = Clip(kind: kind, name: asset?.name ?? kind.title, track: selectedTrack, start: snapped(playhead), duration: asset.map { $0.kind == .image ? 5 : max(0.1, $0.duration) } ?? 4)
        clip.assetID = asset?.id
        if let document = asset?.psd { clip.psd = .initial(document) }
        if kind == .text { clip.text = "テキストを入力" }
        if kind == .speech {
            clip.text = "こんにちは。ゆっくりしていってね。"; clip.y = 0.85; clip.speechDirty = true
            setDefaultSpeechVoice(&clip)
        }
        if kind == .shape { clip.color = "3B82F6" }
        if kind == .particles { clip.particles = ParticleSettings();clip.color = "FFDD66" }
        if kind == .adjustment { clip.effects = [] }
        if kind == .transition { clip.duration = 1; clip.sceneTransition = SceneTransition() }
        project.clips.append(clip); selectedIDs=[]; selectedID = clip.id
        if clip.speechDirty { scheduleSpeech(clip.id) }
    }
    func deleteSelected() {deleteSelection()}
    func duplicateSelected() {
        guard let clip=selected,!project.tracks[clip.track].locked,!busy else {return}
        let ids=LinkedMedia.expandedHierarchy([clip.id],in:project),originals=LinkedMedia.remap(project.clips.filter {ids.contains($0.id)})
        guard originals.allSatisfy({!project.tracks[$0.track].locked}) else{return}
        let mapping=Dictionary(uniqueKeysWithValues:originals.map {($0.id,UUID())})
        var candidate=project,copies:[Clip]=[]
        for original in originals {
            var copy=original;copy.id=mapping[original.id]!;copy.start += clip.duration
            if let parent=copy.parentID,let replacement=mapping[parent] {copy.parentID=replacement}
            copy.sceneMembers=copy.sceneMembers?.compactMap{mapping[$0]}
            candidate.clips.append(copy);copies.append(copy)
        }
        candidate.registerSceneCopies(mapping.mapValues{[$0]})
        do{_=try candidate.validated()}catch{self.error=error.localizedDescription;return}
        pause();checkpoint();project=candidate
        for copy in copies where copy.speechDirty {scheduleSpeech(copy.id)}
        selectedIDs=[];selectedID=mapping[clip.id]
    }
    func splitSelected() {
        guard let clip = selected, !project.tracks[clip.track].locked, playhead > clip.start + 1 / Double(project.fps), playhead < clip.end - 1 / Double(project.fps), !busy else { return }
        guard !project.clips.contains(where: { $0.parentID == clip.id }) else { error = "子を持つ親の分割には対応していません。子を分割するか、親の範囲を調整してください。"; return }
        let cut = snapped(playhead)
        if LinkedMedia.expanded([clip.id],in:project).count>1 {reportEditing{try splitLinked(clip.id,at:cut)};return}
        guard cut>clip.start,cut<clip.end else{return}
        guard let index = project.clips.firstIndex(where: { $0.id == clip.id }) else { return }
        var candidate=project
        let left = SourceEditing.fragment(clip,start:clip.start,end:cut)
        let right = SourceEditing.fragment(clip,start:cut,end:clip.end,newID:true)
        candidate.clips[index] = left
        candidate.clips.append(right);candidate.registerSceneCopies([clip.id:[right.id]])
        do{_=try candidate.validated()}catch{self.error=error.localizedDescription;return}
        pause();checkpoint();project=candidate;selectedIDs=[]; selectedID = right.id
        if right.speechDirty { scheduleSpeech(right.id) }
    }
    func snapped(_ value: Double) -> Double {
        let frame = (max(0, value) * Double(project.fps)).rounded() / Double(project.fps)
        guard snapping else { return frame }
        if let rhythm=project.rhythm,project.rhythmEnabled,rhythm.snap {return (rhythm.nearest(frame)*Double(project.fps)).rounded()/Double(project.fps)}
        let points: [Double] = [0.0, playhead] + project.clips.filter { $0.id != selectedID }.flatMap { [$0.start, $0.end] }
        let target = points.min(by: { abs($0 - frame) < abs($1 - frame) }).flatMap { abs($0 - frame) < 8 / zoom ? $0 : nil } ?? frame
        return (target * Double(project.fps)).rounded() / Double(project.fps)
    }
    func seek(_ time: Double) {
        pause(); playhead = min(max(0, time), max(max(10, project.duration + 5),project.markers?.map(\.time).max() ?? 0))
    }
    func togglePlayback() { playing ? pause() : play() }
    func play() {
        guard !busy,!playing,finishPendingPreviewText(),project.duration>0 else {return}
        if let range=animationPlaybackRange ?? project.timelineRange,range.loop,range.start<project.duration,(playhead<range.start || playhead>=min(range.end,project.duration)){playhead=range.start}
        else if playhead>=project.duration {playhead=0}
        playing=true;let token=UUID();playbackToken=token
        let snapshot=playbackAudioProject(),folder=directory
        audioPreparation=Task { [weak self] in
            guard let self else {return}
            let warpDirectory=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-warp-\(UUID().uuidString)",isDirectory:true)
            var installed=false
            defer {if !installed {try? FileManager.default.removeItem(at:warpDirectory)}}
            do {
                let needed=Set(snapshot.clips.filter{[.audio,.video,.speech].contains($0.kind) && !$0.speechDirty}.compactMap(\.assetID))
                for asset in snapshot.assets where needed.contains(asset.id) {
                    let source=self.prepareAudioSource(asset,in:folder)
                    if self.missingAudio.contains(asset.id){continue}
                    try Task.checkCancellation()
                    if let cached=self.decodedAudio[asset.id],FileManager.default.fileExists(atPath:cached.path) {continue}
                    self.status="音声を準備しています：\(asset.name)"
                    let url=folder.appendingPathComponent("decoded-\(UUID()).caf")
                    let decodeTask=Task.detached {try await AudioProcessor.decode(source:source,destination:url)}
                    do {
                        let exists=try await withTaskCancellationHandler(operation:{try await decodeTask.value},onCancel:{decodeTask.cancel()})
                        try Task.checkCancellation()
                        guard self.directory==folder,self.playbackToken==token else{try? FileManager.default.removeItem(at:url);return}
                        if exists {self.decodedAudio[asset.id]=url} else {self.missingAudio.insert(asset.id)}
                    } catch {try? FileManager.default.removeItem(at:url);throw error}
                }
                let warpedClips=snapshot.clips.filter { ($0.reversed ?? false) || !($0.speedPoints ?? []).isEmpty }
                var prepared:[UUID:URL]=[:]
                if !warpedClips.isEmpty {try FileManager.default.createDirectory(at:warpDirectory,withIntermediateDirectories:true)}
                for clip in warpedClips {
                    guard let assetID=clip.assetID,let decoded=self.decodedAudio[assetID] else {continue}
                    try Task.checkCancellation()
                    self.status="速度変更した音声を準備しています：\(clip.name)"
                    let output=warpDirectory.appendingPathComponent("\(clip.id).caf")
                    let worker=Task.detached {
                        try TimeWarpAudio.render(input:decoded,output:output,curve:clip.timeWarpCurve,sourceStart:clip.sourceOffset,sourceEnd:clip.sourceOffset+clip.sourceDuration,duration:clip.duration,reversed:clip.reversed ?? false)
                    }
                    try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()})
                    try Task.checkCancellation()
                    prepared[clip.id]=output
                }
                guard self.playing,self.directory==folder,self.playbackToken==token else {return}
                self.warpedAudio=prepared;self.warpedAudioDirectory=warpDirectory;installed=true
                self.playbackAudioEngine=PlaybackAudioEngine(settings:self.project.masterDynamics)
                self.status="再生中";self.startPlaybackClock()
            } catch is CancellationError { } catch {
                if self.playbackToken==token {self.pause();self.error="音声を再生できませんでした。\n\(error.localizedDescription)"}
            }
            if self.playbackToken==token {self.audioPreparation=nil}
        }
    }
    private func startPlaybackClock() {
        playbackOffset=playhead;playbackStart=ProcessInfo.processInfo.systemUptime
        updateAudio(synchronizeStart:true)
        timer=Timer.scheduledTimer(withTimeInterval:1/Double(project.fps),repeats:true) { [weak self] _ in
            Task { @MainActor in
                guard let self,self.playing else {return}
                let now=ProcessInfo.processInfo.systemUptime
                guard now>=self.playbackStart else{return}
                self.advancePlayback(to:self.playbackOffset+now-self.playbackStart,clockTime:now)
            }
        }
    }
    func pause() {
        animationPlaybackRange=nil
        timer?.invalidate(); timer = nil; playing = false; previewPerformance=nil;playbackClock.stopMeters()
        playbackToken=UUID();audioPreparation?.cancel();audioPreparation=nil
        players.values.forEach { $0.pause() }; players.removeAll();playbackAudioEngine?.stop();playbackAudioEngine=nil
        if let directory=warpedAudioDirectory {try? FileManager.default.removeItem(at:directory)}
        warpedAudioDirectory=nil;warpedAudio.removeAll()
        audioTasks.values.forEach { $0.cancel() };audioTasks.removeAll();audioTokens.removeAll()
    }
    func invalidateAudioCache(_ id:UUID?=nil) {
        let ids=id.map{[$0]} ?? Array(Set(decodedAudio.keys).union(missingAudio))
        for id in ids {
            if let url=decodedAudio.removeValue(forKey:id) {try? FileManager.default.removeItem(at:url)}
            missingAudio.remove(id);audioSources[id]=nil
        }
    }
    private func prepareAudioSource(_ asset:MediaAsset,in folder:URL)->URL {
        let source=folder.appendingPathComponent("Media").appendingPathComponent(asset.file)
        if audioSources[asset.id] != source {invalidateAudioCache(asset.id);audioSources[asset.id]=source}
        return source
    }
    func updateAudio(synchronizeStart:Bool=false) {
        let project=playbackAudioProject()
        var pending:[ClipAudioPlayer]=[]
        // Prepare upcoming voices before their onset so file reads and graph setup do not
        // shift short MAD cuts. Scheduled voices are cancelled normally on pause/seek.
        let lead=0.1
        let clips=project.clips.filter { $0.start<=playhead+lead+0.1 && project.audioIsActive($0,at:max(playhead,$0.start)) && [.speech,.audio,.video].contains($0.kind) && !$0.speechDirty }
        let active=Set(clips.map(\.id))
        for id in Array(players.keys) where !active.contains(id) {players[id]?.pause();players.removeValue(forKey:id)}
        for id in Array(audioTasks.keys) where !active.contains(id) {audioTasks[id]?.cancel();audioTasks.removeValue(forKey:id)}
        let readings=Dictionary(uniqueKeysWithValues:players.map{($0.key,$0.value.meter.drain())})
        let table=Dictionary(uniqueKeysWithValues:project.clips.map{($0.id,$0)}),rootIDs=Set(self.project.clips.map(\.id))
        func rootTrack(_ clip:Clip)->Int {var c=clip;var seen:Set<UUID>=[];while !rootIDs.contains(c.id),let id=c.parentID,seen.insert(id).inserted,let parent=table[id]{c=parent};return c.track}
        let tracks=self.project.tracks.indices.compactMap{index->TrackAudioMeter? in
            let values=clips.filter{rootTrack($0)==index}.compactMap{readings[$0.id]}
            guard clips.contains(where:{rootTrack($0)==index}) else{return nil}
            return TrackAudioMeter(id:index,name:project.tracks[index].name,reading:.upperBound(values))
        }
        playbackClock.updateMeters(playbackAudioEngine?.meter.drain() ?? .upperBound(Array(readings.values)),tracks:tracks)
        for clip in clips {
            if let player=players[clip.id] {player.setVolume(project.effectiveAudioVolume(clip,at:playhead));continue}
            guard audioTasks[clip.id]==nil,let asset=project.asset(for:clip) else {continue}
            let folder=directory,source=prepareAudioSource(asset,in:directory),token=UUID()
            guard !missingAudio.contains(asset.id) else{continue}
            if let decoded=decodedAudio[asset.id],FileManager.default.fileExists(atPath:decoded.path) {
                do {
                    let needsWarp=(clip.reversed ?? false) || !(clip.speedPoints ?? []).isEmpty
                    guard !needsWarp || warpedAudio[clip.id] != nil else {continue}
                    let source=warpedAudio[clip.id] ?? decoded
                    let original=project.audioProcessingClip(clip)
                    let audioClip=needsWarp ? AudioProcessor.warpedPlaybackClip(original):original
                    let player=try ClipAudioPlayer(url:source,clip:audioClip,time:playhead,volume:project.effectiveAudioVolume(clip,at:playhead),shared:playbackAudioEngine,autoplay:false)
                    players[clip.id]=player;pending.append(player)
                }catch{status="音声再生：\(error.localizedDescription)"}
                continue
            }
            audioTokens[clip.id]=token
            audioTasks[clip.id]=Task { [weak self] in
                guard let self else {return}
                var temporary:URL?
                defer {if let temporary {try? FileManager.default.removeItem(at:temporary)};if self.audioTokens[clip.id]==token {self.audioTasks.removeValue(forKey:clip.id);self.audioTokens.removeValue(forKey:clip.id)}}
                do {
                    let decoded:URL
                    if let cached=self.decodedAudio[asset.id],FileManager.default.fileExists(atPath:cached.path) {decoded=cached}
                    else {
                        let url=folder.appendingPathComponent("decoded-\(UUID()).caf");temporary=url
                        let decodeTask=Task.detached {try await AudioProcessor.decode(source:source,destination:url)}
                        let exists=try await withTaskCancellationHandler(operation:{try await decodeTask.value},onCancel:{decodeTask.cancel()})
                        try Task.checkCancellation()
                        guard self.directory==folder,self.audioTokens[clip.id]==token else{return}
                        guard exists else {self.missingAudio.insert(asset.id);return}
                        self.decodedAudio[asset.id]=url;decoded=url;temporary=nil
                    }
                    guard self.playing,self.directory==folder,self.playbackAudioProject().audioIsActive(clip,at:self.playhead) else {return}
                    self.players[clip.id]=try ClipAudioPlayer(url:decoded,clip:self.playbackAudioProject().audioProcessingClip(clip),time:self.playhead,volume:self.playbackAudioProject().effectiveAudioVolume(clip,at:self.playhead),shared:self.playbackAudioEngine)
                } catch is CancellationError { } catch {self.status="音声再生：\(error.localizedDescription)"}
            }
        }
        if !pending.isEmpty {
            do {
                try playbackAudioEngine?.start()
                let future=ProcessInfo.processInfo.systemUptime+lead
                if synchronizeStart {playbackStart=future}
                let time=synchronizeStart ? playhead:playbackOffset+future-playbackStart
                let host=mach_absolute_time()+AVAudioTime.hostTime(forSeconds:lead)
                for player in pending {
                    let target=max(time,player.startTime)
                    let timestamp=AVAudioTime(hostTime:host+AVAudioTime.hostTime(forSeconds:max(0,target-time)))
                    do{try player.start(at:timestamp,timelineTime:target)}catch{status="音声再生：\(error.localizedDescription)"}
                }
            }catch{status="音声再生：\(error.localizedDescription)"}
        }
    }
    func importMedia() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie, .audio, .zip, UTType(filenameExtension: "psd")!]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await importMediaURLs(urls) }
    }
    // The file picker and Finder drop use the same staged, all-or-nothing import.
    func importMediaURLs(_ urls:[URL]) async {
        do {
            let ids = try await importURLs(urls,maximumFiles:max(100,urls.count))
            status = "\(ids.count)個の素材を追加しました。素材の＋でタイムラインに配置できます。"
        } catch {
            self.error = error.localizedDescription
        }
    }

    func setDefaultSpeechVoice(_ clip:inout Clip) {
        clip.speechConfiguration=speechConfiguration
        if let voice=voices.first {clip.speakerID=voice.id;clip.speakerName=voice.name;clip.speechConfiguration=voice.configuration}
    }
    var speechConfiguration:SpeechConfiguration {settings.speechConfiguration ?? .defaults(.voicevox)}
    func invalidateSpeechConnection() {voiceConnectionToken=UUID();voices=[];voiceState="未接続"}
    func updateSpeechConnection(_ value:SpeechConfiguration) {
        do {_ = try value.validated();invalidateSpeechConnection();settings.speechConfiguration=value;persistSettings()} catch {self.error=error.localizedDescription}
    }
    func selectVoice(_ id:Int,clipID:UUID) {
        guard let voice=voices.first(where:{$0.id==id}) else{return}
        edit(clipID){
            var config=voice.configuration
            if config?.engine == $0.speechConfiguration?.engine {config?.language=$0.speechConfiguration?.language;config?.instruction=$0.speechConfiguration?.instruction}
            $0.speakerID=voice.id;$0.speakerName=voice.name;$0.speechConfiguration=config
        }
    }
    func connectVoicevox() {
        let config=speechConfiguration,token=UUID();voiceConnectionToken=token;voiceState="接続中…"
        Task {
            do {
                let choices=try await speechService.speakers(config)
                guard voiceConnectionToken==token else{return}
                voices=choices;voiceState="接続済み";status="\(config.engine.title)：\(voices.count)種類の声を読み込みました。";scheduleDirtySpeech()
            } catch {
                guard voiceConnectionToken==token else{return}
                voices=[];voiceState="未接続";self.error="\(config.engine.title)を起動してから、再接続してください。\n接続先：\(config.endpoint)\n\(error.localizedDescription)"
            }
        }
    }
    func cancelSpeech() {
        speechTasks.values.forEach { $0.cancel() }
        speechTasks.removeAll(); speechTokens.removeAll(); generatingSpeech.removeAll();activeSpeech.removeAll();speechBatchTotal=0;speechBatchCompleted=0;speechBatchIDs.removeAll()
    }
    func scheduleDirtySpeech() {
        for clip in project.clips where clip.kind == .speech && clip.speechDirty { scheduleSpeech(clip.id) }
    }
    func generateDirtySpeech(force:Bool=false) {
        let clips=project.clips.filter{$0.kind == .speech && (force || $0.speechDirty || $0.assetID == nil) && !project.tracks[$0.track].locked && !$0.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}
        speechBatchTotal=clips.count;speechBatchCompleted=0;speechBatchIDs=Set(clips.map(\.id))
        for clip in clips {scheduleSpeech(clip.id,immediate:true)}
    }
    func retryFailedSpeech() {
        let ids=Set(speechFailures.keys).intersection(Set(project.clips.map(\.id)));speechBatchTotal=ids.count;speechBatchCompleted=0;speechBatchIDs=ids
        for id in ids {scheduleSpeech(id,immediate:true)}
    }
    func generateSpeech() { if let id = selectedID { scheduleSpeech(id, immediate: true) } }
    func scheduleSpeech(_ id: UUID, immediate: Bool = false) {
        speechTasks[id]?.cancel(); speechTokens[id] = nil; generatingSpeech.remove(id);activeSpeech.remove(id)
        guard (autoSpeech || immediate), let clip = project.clips.first(where: { $0.id == id }),
              clip.kind == .speech, !clip.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !project.tracks[clip.track].locked else { return }
        let spoken=project.spokenText(for:clip,entries:catalog.pronunciations)
        let token = UUID(), folder = directory
        speechTokens[id] = token; generatingSpeech.insert(id);speechFailures[id]=nil
        speechTasks[id] = Task { [weak self] in
            guard let self else { return }
            var output: URL?
            defer {
                if let output { try? FileManager.default.removeItem(at: output) }
                if self.speechTokens[id] == token {
                    self.generatingSpeech.remove(id);self.activeSpeech.remove(id); self.speechTokens[id] = nil; self.speechTasks[id] = nil
                    if self.speechBatchIDs.remove(id) != nil {self.speechBatchCompleted+=1}
                }
            }
            do {
                if !immediate { try await Task.sleep(nanoseconds: 800_000_000) }
                let config=clip.speechConfiguration ?? SpeechConfiguration.defaults(.voicevox)
                let service=self.speechService
                let result=try await self.speechQueue.run(key:SpeechGenerationQueue.key(config)) {
                    await MainActor.run {if self.speechTokens[id]==token {self.activeSpeech.insert(id)}}
                    return try await service.synthesizeWithTiming(text:spoken,speaker:clip.speakerID,speed:clip.speed,configuration:config)
                }
                if self.speechTokens[id]==token {self.activeSpeech.remove(id)}
                try Task.checkCancellation()
                let file = "\(UUID()).wav", url = folder.appendingPathComponent("Media").appendingPathComponent(file)
                output = url
                try result.data.write(to: url, options: .atomic)
                let duration = try await AVURLAsset(url: url).load(.duration).seconds
                try Task.checkCancellation()
                guard duration.isFinite, duration > 0 else { throw VMMError.message("生成した音声を読み込めませんでした。") }
                // Wait for import/export to finish before touching their project snapshot.
                while self.busy { try await Task.sleep(nanoseconds: 100_000_000) }
                guard self.speechTokens[id] == token, self.directory == folder,
                      let index = self.project.clips.firstIndex(where: { $0.id == id }),
                      !self.project.tracks[self.project.clips[index].track].locked,
                      self.project.spokenText(for:self.project.clips[index],entries:self.catalog.pronunciations) == spoken,
                      self.project.clips[index].speakerID == clip.speakerID,
                      self.project.clips[index].speechConfiguration == clip.speechConfiguration,
                      self.project.clips[index].speed == clip.speed else { return }
                var asset = MediaAsset(name: String(clip.text.prefix(24)) + ".wav", file: file, kind: .audio, duration: duration, generatedSpeech: true, envelope: try audioEnvelope(url: url))
                if let timing=result.vowelTiming,timing.isConsistent(with:duration) {asset.vowelTiming=timing}
                self.pause()
                if immediate { self.checkpoint() }
                self.project.assets.append(asset)
                self.project.clips[index].assetID = asset.id
                // Preserve a trim performed while synthesis was in flight.
                if self.project.clips[index].preserveSpeechDuration != true && self.project.clips[index].duration == clip.duration && self.project.clips[index].sourceOffset == clip.sourceOffset {
                    let oldEnd=self.project.clips[index].end,oldDuration=self.project.clips[index].duration
                    self.project.clips[index].duration = ceil(duration / self.project.clips[index].mediaRate * Double(self.project.fps)) / Double(self.project.fps)
                    if let sequence=self.project.clips[index].scriptSequenceID {
                        let delta=self.project.clips[index].duration-oldDuration
                        for j in self.project.clips.indices where j != index && self.project.clips[j].scriptSequenceID==sequence && self.project.clips[j].start>=oldEnd && !self.project.tracks[self.project.clips[j].track].locked {self.project.clips[j].start=max(0,self.project.clips[j].start+delta)}
                    }
                    self.project.clips[index].sourceOffset = 0
                }
                self.project.clips[index].speechDirty = false
                self.project.clips[index].normalizationGain=nil;self.project.clips[index].measuredLUFS=nil
                self.project.clips[index].speakerName = clip.speakerName.isEmpty ? "話者 \(clip.speakerID)":clip.speakerName
                self.dirty = true; output = nil
                self.status = "セリフの音声を生成しました。"
            } catch is CancellationError { }
            catch {
                if !Task.isCancelled && self.speechTokens[id] == token {
                    self.speechFailures[id]=error.localizedDescription
                    self.status = "音声生成に失敗：選択した音声エンジンを起動し、再生成してください。"
                    if immediate && !self.speechBatchIDs.contains(id) { self.error = error.localizedDescription }
                }
            }
        }
    }
    func moveTrack(from: Int, to: Int) {
        guard !busy, project.tracks.indices.contains(from), project.tracks.indices.contains(to), from != to else { return }
        pause(); checkpoint()
        let old = project.tracks.map(\.id), selected = old[selectedTrack]
        let track = project.tracks.remove(at: from); project.tracks.insert(track, at: to)
        for i in project.clips.indices { project.clips[i].track = project.tracks.firstIndex { $0.id == old[project.clips[i].track] }! }
        selectedTrack = project.tracks.firstIndex { $0.id == selected }!
    }
    /// All timeline gestures use the original clip and absolute canvas deltas.
    func timelineChange(_ original: Clip, delta: Double, track: Int, edge: Int) -> Clip {
        var result = original
        let frame = 1 / Double(project.fps)
        let timed = original.precompositionID != nil || [.audio, .video, .speech].contains(original.kind)
        let animatedImage = original.kind == .image && project.asset(for:original).map { URL(fileURLWithPath:$0.file).pathExtension.lowercased() == "gif" } == true
        if original.hasTimeWarp && edge != 0 {
            if edge < 0 {
                let start = min(original.end-frame,max(original.start,snapped(original.start+delta)))
                return SourceEditing.fragment(original,start:start,end:original.end)
            }
            let end = max(original.start+frame,min(original.end,snapped(original.end+delta)))
            return SourceEditing.fragment(original,start:original.start,end:end)
        }
        if edge < 0 {
            let animated = !(original.psd?.selectionKeys?.isEmpty ?? true) || original.animation != nil || original.spatialAnimation != nil || original.textAnimation != nil || original.kind == .particles || original.effects?.contains(where: { !$0.keys.isEmpty }) == true
            let earliest = max(timed || animatedImage ? max(0, original.start - original.sourceOffset / original.mediaRate) : 0, animated ? max(0, original.start - original.animationTimeOffset) : 0)
            if animated { result.preserveAnimationDomain() }
            result.start = min(original.end - frame, max(earliest, snapped(original.start + delta)))
            result.duration = original.end - result.start
            if timed || animatedImage { result.sourceOffset = original.sourceOffset + (result.start - original.start) * original.mediaRate }
            if animated {
                result.animationOffset = max(0, original.animationTimeOffset + result.start - original.start)
            }
        } else if edge > 0 {
            let limit = original.precompositionID != nil ? max(original.duration,(project.composition(original)?.duration ?? original.duration)-original.sourceOffset):timed ? project.asset(for: original).map { max(original.duration, ($0.duration - original.sourceOffset) / original.mediaRate) } ?? 86400 : 86400
            result.duration = min(limit, max(frame, snapped(original.end + delta) - original.start))
        } else {
            let proposed = max(0, original.start + delta)
            result.start = (proposed * Double(project.fps)).rounded() / Double(project.fps)
            if snapping {
                let points = [0.0, playhead] + project.clips.filter { $0.id != original.id }.flatMap { [$0.start, $0.end] }
                let starts = points.flatMap { [$0, $0 - original.duration] }.filter { $0 >= 0 && abs($0 - proposed) < 8 / zoom }
                if let nearest = starts.min(by: { abs($0 - proposed) < abs($1 - proposed) }) { result.start = (nearest * Double(project.fps)).rounded() / Double(project.fps) }
            }
            if project.tracks.indices.contains(track), !project.tracks[track].locked { result.track = track }
        }
        return result
    }
    func confirmDiscard() -> Bool {
        guard dirty else { return true }
        let alert = NSAlert()
        alert.messageText = "変更を保存しますか？"
        alert.informativeText = "保存しない変更は失われます。"
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "キャンセル"); alert.addButton(withTitle: "保存しない")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }
    func reset(to project: Project, directory: URL, savedURL: URL?) {
        pause()
        collapsedTrackFolders.removeAll()
        cancelSpeech();speechFailures.removeAll();exportReport=nil
        invalidateAudioCache()
        let old = self.directory
        self.playbackClock.resetMeters();self.playbackClock.trackMeters=[];self.project = project; self.directory = directory; self.savedURL = savedURL
        recoveryIdentity=savedURL.flatMap{AutosaveWriter.metadata($0)?.identity} ?? savedURL?.standardizedFileURL.path ?? UUID().uuidString
        selectedID = nil; selectedIDs=[]; selectedTrack = min(1, project.tracks.count - 1); playhead = 0
        undoStack = []; redoStack = []; dirty = false
        if old != directory {retireSession(old)}
        scheduleDirtySpeech()
    }
    func newProject() {
        requestDiscard { allowed in
            guard allowed else{return}
            do {
                let folder=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-session-\(UUID())")
                try FileManager.default.createDirectory(at:folder.appendingPathComponent("Media"),withIntermediateDirectories:true)
                self.reset(to:Project(),directory:folder,savedURL:nil);self.status="新規プロジェクト"
            } catch {self.error=error.localizedDescription}
        }
    }
    func openProject() {
        guard !busy,finishPendingPreviewText() else{return}
        let panel=NSOpenPanel();panel.allowedContentTypes=[UTType(importedAs:"app.vmm.project")];panel.canChooseDirectories=true
        guard panel.runModal() == .OK,let url=panel.url else{return}
        requestLoad(url)
    }
    @discardableResult func loadProject(_ url: URL) -> Bool {
        guard !busy,finishPendingPreviewText() else{return false}
        do {
            let (project,folder)=try ProjectIO.read(url)
            reset(to: project, directory: folder, savedURL: url); status = "\(project.name) を開きました。"
            if !missingAssets.isEmpty {status += " 未検出の素材は素材管理から再リンクしてください。"}
            return true
        } catch { self.error = "プロジェクトを開けませんでした。\n\(error.localizedDescription)";return false }
    }
    @discardableResult func save(asNew: Bool = false) -> Bool {
        guard !busy,finishPendingPreviewText() else { return false }
        pause()
        var destination = asNew ? nil : savedURL
        if destination == nil {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(exportedAs: "app.vmm.project", conformingTo: .package)]
            panel.nameFieldStringValue = project.name + ".vmm"
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return false }
            destination = url
        }
        guard let destination else { return false }
        do {
            var saved = project
            saved.name = destination.deletingPathExtension().lastPathComponent
            _ = try saved.validated()
            try ProjectPackage.write(saved,media:directory.appendingPathComponent("Media"),to:destination)
            project.name = saved.name; savedURL = destination; dirty = false; status = "保存しました：\(destination.lastPathComponent)"
            return true
        } catch { self.error = "保存できませんでした。\n\(error.localizedDescription)"; return false }
    }
    func exportMovie() {
        guard !busy,finishPendingPreviewText() else { return }
        guard generatingSpeech.isEmpty else { status = "音声生成が完了してから書き出してください。"; return }
        pause()
        let panel = NSSavePanel(); panel.allowedContentTypes = [settings.exportContainer == "MOV" ? .quickTimeMovie:.mpeg4Movie]; panel.nameFieldStringValue = project.name + (settings.exportContainer == "MOV" ? ".mov":".mp4")
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        beginExport(to:destination)
    }
    func beginExport(to destination:URL,overwrite:Bool=true) {
        guard !busy,finishPendingPreviewText(),generatingSpeech.isEmpty,exportQueue.runningID == nil else {return}
        busy = true; exportProgress = 0; exportPhase = .preparing; status = "動画を書き出しています…"
        let runID=UUID();exportRunID=runID
        let snapshot = project, directory = directory,options=settings
        exportTask = Task {
            defer { busy = false; exportProgress = nil; exportPhase = nil; exportRunID = nil; exportTask = nil }
            do {
                let report=await Task.detached {ExportPreflight.inspect(project:snapshot,directory:directory,options:options,destination:destination)}.value
                self.exportReport=report
                guard report.canExport else {throw VMMError.message(report.issues.filter{$0.severity == .error}.map(\.message).joined(separator:"\n"))}
                let work = Task.detached {
                    try await MovieExporter.export(project: snapshot, directory: directory, destination: destination,options:options,overwrite:overwrite,phase:{phase in
                        Task { @MainActor in guard self.exportRunID==runID else{return};if phase.rawValue >= (self.exportPhase?.rawValue ?? 0){self.exportPhase=phase} }
                    }) { value in
                        Task { @MainActor in guard self.exportRunID==runID,let previous=self.exportProgress else{return};self.exportProgress=max(previous,min(1,max(0,value))) }
                    }
                }
                try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
                status = "書き出し完了：\(destination.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch is CancellationError { status = "書き出しを中止しました。" }
            catch { self.error = error.localizedDescription; status = "書き出しに失敗しました。" }
        }
    }
    func cancelExport() { exportTask?.cancel() }
    func exportAudio() {
        guard !busy,finishPendingPreviewText(),generatingSpeech.isEmpty,exportQueue.runningID==nil else{return}
        pause();let panel=NSSavePanel();panel.allowedContentTypes=[.wav];panel.nameFieldStringValue=project.name+".wav"
        guard panel.runModal() == .OK,let url=panel.url else{return};beginAudioExport(to:url,overwrite:true)
    }
    func exportInterchange() {
        guard !busy,finishPendingPreviewText(),generatingSpeech.isEmpty,exportQueue.runningID==nil else{return}
        pause();let panel=NSSavePanel();panel.nameFieldStringValue=project.name+"-handoff"
        panel.message="新しいフォルダを作ります。ProRes・WAV・Final Cut／Premiere用XML。字幕やエフェクトは焼き込みです。"
        guard panel.runModal() == .OK,let url=panel.url else{return};beginInterchangeExport(to:url)
    }
    func beginInterchangeExport(to destination:URL) {
        guard !busy,finishPendingPreviewText(),generatingSpeech.isEmpty,exportQueue.runningID==nil else{return}
        pause();busy=true;exportProgress=0;error=nil;status="受け渡し素材を書き出しています…"
        let snapshot=project,source=directory,options=settings
        exportTask=Task {
            defer{busy=false;exportProgress=nil;exportTask=nil}
            do {
                let work=Task.detached {try await TimelineInterchange.export(project:snapshot,directory:source,destination:destination,options:options){value in Task{@MainActor in self.exportProgress=value}}}
                try await withTaskCancellationHandler(operation:{try await work.value},onCancel:{work.cancel()})
                status="書き出し完了：\(destination.lastPathComponent)"
            }catch is CancellationError{status="書き出しを中止しました。"}catch{self.error=error.localizedDescription;status="書き出しに失敗しました。"}
        }
    }
    func beginAudioExport(to destination:URL,overwrite:Bool=false) {
        guard !busy,finishPendingPreviewText(),generatingSpeech.isEmpty,exportQueue.runningID==nil else{return}
        pause();busy=true;exportProgress=0;error=nil;status="音声を書き出しています…"
        let snapshot=project,source=directory,options=settings
        exportTask=Task {
            defer{busy=false;exportProgress=nil;exportTask=nil}
            do {
                let work=Task.detached {try await AudioOnlyExporter.export(project:snapshot,directory:source,destination:destination,options:options,overwrite:overwrite){value in Task{@MainActor in self.exportProgress=value}}}
                try await withTaskCancellationHandler(operation:{try await work.value},onCancel:{work.cancel()})
                status="書き出し完了：\(destination.lastPathComponent)"
            } catch is CancellationError {status="書き出しを中止しました。"}catch{self.error=error.localizedDescription;status="書き出しに失敗しました。"}
        }
    }
}
