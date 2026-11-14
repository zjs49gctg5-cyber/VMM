import Foundation

enum ClipKind: String, Codable, CaseIterable {
    case text, speech, image, video, audio, shape, transition, group, particles, adjustment
    var title: String {
        switch self {
        case .text: return "テキスト"
        case .speech: return "セリフ"
        case .image: return "画像・立ち絵"
        case .video: return "動画"
        case .audio: return "音声・BGM"
        case .shape: return "図形"
        case .group: return "グループ制御"
        case .particles: return "パーティクル"
        case .adjustment: return "調整エフェクト"
        case .transition: return "場面切り替え"
        }
    }
    var symbol: String {
        switch self {
        case .text: return "textformat"
        case .speech: return "waveform"
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "music.note"
        case .shape: return "rectangle.fill"
        case .group: return "square.stack.3d.up"
        case .particles: return "sparkles"
        case .adjustment: return "slider.horizontal.3"
        case .transition: return "rectangle.on.rectangle"
        }
    }
}

struct MediaAsset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var file: String
    var kind: ClipKind
    var duration: Double
    var tags:[String]?
    var generatedSpeech: Bool?
    var vowelTiming:VowelTiming?
    var proxyFile:String?
    var envelope: [Double]?
    var psd: PSDDocument?
    var files: [String] { [file] + (proxyFile.map{[$0]} ?? []) + (psd?.files ?? []) }
}

struct Track: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var visible = true
    var muted = false
    var locked = false
    var effects: [VisualEffect]?
    var blendMode: CompositeMode?
    var opacity: Double?
    var folder:TrackFolder?
    var folderID:UUID? {folder?.id}
}

struct TrackFolder: Codable, Identifiable, Equatable {
    var id = UUID()
    var name:String
}

struct TextGradient: Codable, Equatable {
    var enabled = false
    var endColor = "66CCFF"
    var angle: Double = 90
}

enum TextAlignment:String,Codable,CaseIterable {
    case left,center,right,distributed
    var title:String {switch self {case .left:return "左揃え";case .center:return "中央揃え";case .right:return "右揃え";case .distributed:return "等間隔"}}
}

struct TextStyle: Codable, Equatable {
    var alignment:TextAlignment?
    var fillGradient: TextGradient?
    var outlineGradient: TextGradient?
    var outline = true
    var outlineColor = "000000"
    var outlineWidth: Double = 3
    var shadow = false
    var shadowColor = "000000"
    var shadowOpacity: Double = 0.7
    var shadowBlur: Double = 4
    var shadowX: Double = 4
    var shadowY: Double = 4
    var fontName:String?
    var tracking:Double?
    var lineSpacing:Double?
    var captionWidth:Double?
}

struct LyricWipeSegment:Codable,Equatable,Identifiable {
    var id=UUID()
    var startIndex:Int
    var endIndex:Int
    var start:Double
    var end:Double
}
struct LyricRubyTiming:Codable,Equatable {
    var index:Int
    /// Seconds relative to the beginning of the parent text's wipe.
    var offset:Double
}
struct LyricRuby:Codable,Equatable,Identifiable {
    var id=UUID()
    var startIndex:Int
    var endIndex:Int
    var text:String
    var timings:[LyricRubyTiming]?
    func progress(at time:Double,start:Double,end:Double)->Double {
        guard end>start else{return time>=end ? 1:0}
        let points=[LyricRubyTiming(index:0,offset:0)]+(timings ?? [])+[LyricRubyTiming(index:text.count,offset:end-start)]
        let elapsed=time-start
        if elapsed<0{return 0};if elapsed>=end-start{return 1}
        for i in 1..<points.count where elapsed<points[i].offset {
            let a=points[i-1],b=points[i],span=b.offset-a.offset
            let ratio=span>0 ? (elapsed-a.offset)/span:1
            return min(1,max(0,(Double(a.index)+Double(b.index-a.index)*ratio)/Double(max(1,text.count))))
        }
        return 1
    }
}
struct LyricWipe:Codable,Equatable {
    var start:Double=0
    var end:Double=2
    var color:String="FFDD33"
    var segments:[LyricWipeSegment]?
    func progress(at time:Double)->Double {min(1,max(0,(time-start)/(end-start)))}
    func validate(textCount:Int?=nil) throws {
        guard start.isFinite,end.isFinite,start>=0,end>start,end<=86400,
              color.count == 6,color.allSatisfy({$0.isHexDigit && $0.isASCII}) else {throw VMMError.message("歌詞ワイプの時刻または色が不正です。")}
        if let segments {
            guard !segments.isEmpty,segments.count<=2000,Set(segments.map(\.id)).count==segments.count else{throw VMMError.message("歌詞の区間が不正です。")}
            var lastIndex=0,lastTime=0.0
            for segment in segments {
                guard segment.startIndex>=lastIndex,segment.endIndex>segment.startIndex,segment.endIndex <= (textCount ?? 10000),segment.start.isFinite,segment.end.isFinite,segment.start>=lastTime,segment.end>=segment.start,segment.end<=86400 else{throw VMMError.message("歌詞の文字範囲または時刻が不正です。")}
                lastIndex=segment.endIndex;lastTime=segment.end
            }
        }
    }
}

struct Clip: Codable, Identifiable, Equatable {
    var lyricRuby:[LyricRuby]?
    var lyricWipe:LyricWipe?
    var cameraDepth:Double?
    var precompositionID:UUID?
    var spatialAnimation:SpatialAnimation?
    var temporalMotion:TemporalMotion?
    var audioReactive:AudioReactive?
    var tracking:MotionTrackingResult?
    var anchorPoint:NormalizedPoint?
    var textAnimation:CharacterAnimation?
    var nineSlice:NineSliceSettings?
    var customAnimation:CustomAnimationInstance?
    var id = UUID()
    var kind: ClipKind
    var name: String
    var track: Int
    var start: Double
    var duration: Double
    var sourceOffset: Double = 0
    var assetID: UUID?
    var text = ""
    var reading:String?
    var scriptSequenceID:UUID?
    var textRevealRate:Double?
    var characterPresetID:UUID?
    var ducking:Double?
    var x: Double = 0.5
    var y: Double = 0.5
    var scale: Double = 1
    var opacity: Double = 1
    var animation: ClipAnimation?
    var animationOffset: Double?
    var effects: [VisualEffect]?
    var rotation: Double?
    var flipX: Bool?
    var flipY: Bool?
    var sceneTransition: SceneTransition?
    var audioFade: AudioFade?
    var parentID: UUID?
    var linkID:UUID?
    var sceneMembers:[UUID]?
    var transform: Transform2D?
    var masks: [ClipMask]?
    var blendMode: CompositeMode?
    var particles: ParticleSettings?
    var playbackRate: Double?
    var reversed: Bool?
    var speedPoints: [SpeedCurve.Point]?
    var preservePitch: Bool?
    var pitchSemitones: Double?
    var equalizer: Equalizer?
    var adjustmentOwnLayer: Bool?
    var adjustmentRegion: AdjustmentRegion?
    var shapeStyle: ShapeStyle?
    var textStyle: TextStyle?
    var textRuns:[TextRun]?
    var fontSize: Double = 64
    var color = "FFFFFF"
    var audioDisabled:Bool?
    var normalizationGain:Double?
    var measuredLUFS:Double?
    var pan:Double?
    var volume: Double = 1
    var speechConfiguration:SpeechConfiguration?
    var preserveSpeechDuration:Bool?
    var speechCaptionHidden:Bool?
    var characterSpeechEngine:SpeechEngine?
    var speakerID: Int = 0
    var speakerName = ""
    var speed: Double = 1
    var speechDirty = false
    var mouthAssetID: UUID?
    var characterSpeakerID: Int?
    var psd: PSDState?
    var timelineTitle:String { [.text,.speech].contains(kind) && !text.isEmpty ? text.replacingOccurrences(of:"\n",with:" "):name }
    var end: Double { start + duration }
    func active(at time: Double) -> Bool { time >= start && time < end }
}

/// Built only after unique IDs have been checked; shared by the clip validators.
struct ProjectValidationIndex {
    let assets:[UUID:MediaAsset]
    let clips:[UUID:Clip]
    init(project:Project) {
        assets=Dictionary(uniqueKeysWithValues:project.assets.map{($0.id,$0)})
        clips=Dictionary(uniqueKeysWithValues:project.clips.map{($0.id,$0)})
    }
}

struct Project: Codable, Equatable {
    var camera3D:Camera3D?
    var precompositions:[Precomposition]?
    var version = 1
    var name = "名称未設定"
    var width = 1920
    var height = 1080
    var fps = 30
    var background = "111827"
    var tracks = (1...5).map { Track(name: "レイヤー \($0)") }
    var assets: [MediaAsset] = []
    var clips: [Clip] = []
    var characters:[CharacterPreset]?
    var pronunciations:[PronunciationEntry]?
    var rhythm:RhythmSettings?
    var masterVolume:Double?
    var masterDynamics:MasterDynamics?
    var markers:[TimelineMarker]?
    var timelineRange:TimelineRange?
    var trackFolders:[TrackFolder] {
        var seen=Set<UUID>()
        return tracks.compactMap(\.folder).filter{seen.insert($0.id).inserted}
    }
    var duration: Double { clips.map(\.end).max() ?? 0 }
    func asset(for clip: Clip) -> MediaAsset? { assets.first { $0.id == clip.assetID } }
    func visibleClips(at time: Double) -> [Clip] {
        clips.filter { $0.active(at: time) && tracks.indices.contains($0.track) && tracks[$0.track].visible }
            .sorted { $0.track == $1.track ? $0.start < $1.start : $0.track < $1.track }
    }
    func validateLUTBudget()throws {
        var bytes=0
        func count(_ effects:[VisualEffect]?)throws {
            for effect in effects ?? [] {bytes += effect.lut?.data.count ?? 0;guard bytes<=ColorLUT.maximumProjectBytes else{throw VMMError.message("プロジェクト内のLUT容量が上限を超えています。")}}
        }
        for track in tracks {try count(track.effects)};for clip in clips {try count(clip.effects)}
        for composition in precompositions ?? [] {for track in composition.tracks {try count(track.effects)};for clip in composition.clips {try count(clip.effects)}}
    }
    func validated(validateCompositions:Bool=true) throws -> Project {
        try camera3D?.validate()
        if validateCompositions {try validateLUTBudget()}
        if validateCompositions {try validatePrecompositions()}
        if let characters {guard characters.count<=200,Set(characters.map(\.id)).count==characters.count else{throw VMMError.message("キャラ定義が多すぎるか重複しています。")};for character in characters {try character.validate(in:self)}}
        try rhythm?.validate()
        try masterDynamics?.validate()
        if let range=timelineRange {guard range.start.isFinite,range.end.isFinite,range.start>=0,range.end>range.start,range.end<=86400 else{throw VMMError.message("タイムライン範囲が不正です。")}}
        if let markers {guard markers.count<=2000,Set(markers.map(\.id)).count==markers.count,markers.allSatisfy({$0.time.isFinite && (0...86400).contains($0.time) && !$0.name.isEmpty && $0.name.count<=200}) else{throw VMMError.message("マーカーが不正です。")}}
        guard (masterVolume ?? 1).isFinite,(0...2).contains(masterVolume ?? 1) else{throw VMMError.message("マスター音量が不正です。")}
        guard version == 1 else { throw VMMError.message("未対応のプロジェクト形式です。") }
        guard [24, 30, 60].contains(fps), (64...3840).contains(width), (64...2160).contains(height),
              width % 2 == 0, height % 2 == 0, (1...32).contains(tracks.count),
              Set(assets.map(\.id)).count == assets.count, Set(clips.map(\.id)).count == clips.count,
              Set(tracks.map(\.id)).count == tracks.count else { throw VMMError.message("プロジェクト設定が不正です。") }
        let folders=trackFolders
        guard folders.allSatisfy({!$0.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && $0.name.count<=100}),tracks.allSatisfy({track in track.folder == nil || folders.contains(where:{$0 == track.folder})}) else { throw VMMError.message("レイヤーフォルダの設定が不正です。") }
        for asset in assets {
            if let tags=asset.tags {guard tags.count<=32,Set(tags).count==tags.count,tags.allSatisfy({!$0.isEmpty && $0.count<=80}) else{throw VMMError.message("素材タグが不正です。")}}
            if let timing=asset.vowelTiming {guard asset.kind == .audio,timing.isConsistent(with:asset.duration) else{throw VMMError.message("母音の時刻が音声と一致しません。")}}
            if let document = asset.psd { try document.validate() }
            guard asset.proxyFile.map({ !$0.isEmpty && $0 == URL(fileURLWithPath:$0).lastPathComponent && !$0.contains("/") && $0 != "." && $0 != ".." }) ?? true else {throw VMMError.message("不正なプロキシのファイル名です。") }
            guard !asset.file.isEmpty, asset.file == URL(fileURLWithPath: asset.file).lastPathComponent,
                  !asset.file.contains("/"), asset.file != ".", asset.file != "..",
                  asset.duration.isFinite, asset.duration >= 0 else { throw VMMError.message("素材のパスまたは長さが不正です。") }
        }
        for track in tracks {
            var test = Clip(kind:.adjustment,name:track.name,track:0,start:0,duration:1); test.effects = track.effects
            try test.validateAnimation()
            guard track.opacity == nil || (track.opacity!.isFinite && (0...1).contains(track.opacity!)) else { throw VMMError.message("レイヤーの不透明度が不正です。") }
        }
        let index=ProjectValidationIndex(project:self)
        let clipIDs=Set(index.clips.keys)
        guard clips.allSatisfy({$0.cameraDepth.map { $0.isFinite && (-8...8).contains($0) } ?? true}) else {throw VMMError.message("3Dレイヤーの奥行きが不正です。")}
        try validateSceneOwnership()
        for c in clips {
            if let slice=c.nineSlice {guard c.kind == .image else{throw VMMError.message("9スライスは画像アイテムにのみ使用できます。")};try slice.validate()}
            try TextRunEditing.validate(c.textRuns,text:c.text)
            if let pan=c.pan {guard pan.isFinite,(-1...1).contains(pan) else{throw VMMError.message("パンが不正です。")}}
            if let members=c.sceneMembers {guard c.kind == .group,members.count<=20000,Set(members).count==members.count,Set(members).isSubset(of:clipIDs),!members.contains(c.id) else{throw VMMError.message("シーンのメンバーが不正です。")}}
            guard c.linkID == nil || [.audio,.video].contains(c.kind) else{throw VMMError.message("リンクは映像・音声に指定してください。")}
            guard (c.normalizationGain ?? 1).isFinite,(0...64).contains(c.normalizationGain ?? 1),c.measuredLUFS.map({$0.isFinite && (-120...30).contains($0)}) ?? true else{throw VMMError.message("音量正規化が不正です。")}
            try c.shapeStyle?.validate()
            _ = try c.speechConfiguration?.validated()
            try c.validateAdvanced(project:self,index:index)
            if let id=c.precompositionID {guard c.kind == .group,c.sceneMembers==nil,c.mediaRate==1,precompositions?.contains(where:{$0.id==id}) == true else{throw VMMError.message("プリコンポジションの参照・速度が不正です。")}}
            try c.validateAnimation()
            try c.customAnimation?.validate()
            if let rate=c.textRevealRate {guard rate.isFinite,(1...100).contains(rate) else {throw VMMError.message("文字送りが不正です。")}}
            if let duck=c.ducking {guard duck.isFinite,(0...1).contains(duck) else {throw VMMError.message("BGM音量比が不正です。")}}
            if let t = c.textStyle {
                guard (t.tracking ?? 0).isFinite,(-0.2...2).contains(t.tracking ?? 0),(t.lineSpacing ?? 0).isFinite,(0...2).contains(t.lineSpacing ?? 0),(t.captionWidth ?? 0.9).isFinite,(0.1...1).contains(t.captionWidth ?? 0.9) else {throw VMMError.message("文字組みが不正です。")}
                for g in [t.fillGradient, t.outlineGradient].compactMap({ $0 }) {
                    guard g.angle.isFinite, (0...360).contains(g.angle) else { throw VMMError.message("グラデーションの角度が不正です。") }
                }
                guard t.outlineWidth.isFinite, (0...20).contains(t.outlineWidth),
                    t.shadowOpacity.isFinite, (0...1).contains(t.shadowOpacity),
                    t.shadowBlur.isFinite, (0...100).contains(t.shadowBlur),
                    t.shadowX.isFinite, (-100...100).contains(t.shadowX),
                    t.shadowY.isFinite, (-100...100).contains(t.shadowY) else { throw VMMError.message("文字装飾の設定が不正です。") }
            }
            if let state = c.psd {
                guard let document = c.assetID.flatMap({index.assets[$0]})?.psd,
                      Set(state.selected).isSubset(of: Set(document.layers.map(\.id))),
                      [state.mouthClosed, state.mouthOpen, state.eyeClosed].compactMap({ $0 }).allSatisfy({ id in document.layers.contains { $0.id == id } }),
                      state.blinkInterval.isFinite, (0.5...30).contains(state.blinkInterval) else { throw VMMError.message("PSDの表情設定が不正です。") }
                if let mappings=state.vowelLayers {
                    guard Set(mappings.keys).isSubset(of:Set(MouthVowel.allCases.map(\.rawValue))),mappings.values.allSatisfy({id in document.layers.contains{$0.id==id && !$0.group}}) else {throw VMMError.message("母音の口レイヤー設定が不正です。")}
                }
                let keys=state.selectionKeys ?? []
                guard keys.count<=1024,Set(keys.map(\.id)).count==keys.count,
                      keys.allSatisfy({$0.time.isFinite && (0...86400).contains($0.time) && Set($0.selected).isSubset(of:Set(document.layers.map(\.id)))}),
                      Set(keys.map(\.time)).count==keys.count else {throw VMMError.message("PSDのレイヤー切り替えキーフレームが不正です。") }
            }
            guard tracks.indices.contains(c.track), c.start.isFinite, c.start >= 0,
                  c.duration.isFinite, c.duration > 0, c.end <= 86400,
                  c.sourceOffset.isFinite, c.sourceOffset >= 0,
                  c.x.isFinite, c.y.isFinite, c.scale.isFinite, (0.01...10).contains(c.scale),
                  c.opacity.isFinite, (0...1).contains(c.opacity), c.volume.isFinite, (0...2).contains(c.volume),
                  c.fontSize.isFinite, (8...400).contains(c.fontSize), c.speed.isFinite, (0.5...2).contains(c.speed),
                  c.assetID.map({index.assets[$0] != nil}) ?? true,
                  c.mouthAssetID.map({index.assets[$0]?.kind == .image}) ?? true else {
                throw VMMError.message("クリップ「\(c.name)」の設定が不正です。")
            }
        }
        return self
    }
    func mouthIsOpen(for character: Clip, at time: Double) -> Bool {
        guard let speaker = character.characterSpeakerID else { return false }
        return clips.contains { speech in
            guard speech.kind == .speech, speech.speakerID == speaker,
                  character.characterPresetID == nil || speech.characterPresetID == character.characterPresetID,
                  (speech.speechConfiguration?.engine ?? .voicevox) == (character.characterSpeechEngine ?? .voicevox), audioIsActive(speech, at: time),
                  !speech.speechDirty, !tracks[speech.track].muted,
                  let envelope = asset(for: speech)?.envelope else { return false }
            let sample = Int(speech.sourceTime(at:time) * 30)
            return envelope.indices.contains(sample) && envelope[sample] > 0.018
        }
    }
    static func demo() -> Project {
        var p = Project()
        p.name = "はじめての動画"
        var box = Clip(kind: .shape, name: "アクセント", track: 0, start: 0, duration: 8)
        box.color = "2563EB"; box.y = 0.46; box.scale = 1.2
        var title = Clip(kind: .text, name: "タイトル", track: 1, start: 0, duration: 4)
        title.text = "Macで、ゆっくり動画。"; title.y = 0.43; title.fontSize = 100
        var sub = Clip(kind: .text, name: "サブタイトル", track: 2, start: 0, duration: 4)
        sub.text = "VMM  /  VOICE MOVIE MAKER"; sub.y = 0.59; sub.fontSize = 32; sub.color = "BFDBFE"
        var next = Clip(kind: .text, name: "編集をはじめよう", track: 1, start: 4, duration: 4)
        next.text = "台本も、字幕も、タイムラインで。"; next.fontSize = 76
        p.clips = [box, title, sub, next]
        return p
    }
}

enum VMMError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(message) = self { return message }; return nil }
}

func timecode(_ seconds: Double, fps: Int = 30) -> String {
    let frames = max(0, Int((seconds * Double(fps)).rounded()))
    return String(format: "%02d:%02d:%02d:%02d", frames / fps / 3600, frames / fps / 60 % 60, frames / fps % 60, frames % fps)
}
