import Foundation

enum Easing: String, Codable, CaseIterable {
    case linear, easeIn, easeOut, easeInOut, backOut, bounceOut, hold
    var title: String {
        switch self {
        case .linear: return "直線"
        case .easeIn: return "加速"
        case .easeOut: return "減速"
        case .easeInOut: return "加速・減速"
        case .backOut: return "オーバーシュート"
        case .bounceOut: return "バウンド"
        case .hold: return "瞬間切り替え"
        }
    }
    func value(_ progress: Double) -> Double {
        let t = min(1, max(0, progress))
        switch self {
        case .linear: return t
        case .easeIn: return t * t * t
        case .easeOut: return 1 - pow(1 - t, 3)
        case .easeInOut: return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        case .backOut: return 1 + 2.70158 * pow(t - 1, 3) + 1.70158 * pow(t - 1, 2)
        case .bounceOut:
            let n = 7.5625, d = 2.75
            if t < 1 / d { return n * t * t }
            if t < 2 / d { let x = t - 1.5 / d; return n * x * x + 0.75 }
            if t < 2.5 / d { let x = t - 2.25 / d; return n * x * x + 0.9375 }
            let x = t - 2.625 / d; return n * x * x + 0.984375
        case .hold: return t >= 1 ? 1 : 0
        }
    }
}
struct AnimationKeyframe: Codable, Equatable, Identifiable {
    var id = UUID()
    var time: Double
    var value: Double
    /// Applies from this keyframe to the next one.
    var easing = Easing.easeInOut
    var customCurve:EasingCurve?
}
func interpolate(_ keys: [AnimationKeyframe], at time: Double, fallback: Double) -> Double {
    guard let initial = keys.first else { return fallback }
    guard keys.count > 1 else { return initial.value }
    // Projects may contain keys in any order. Find the enclosing keys without
    // allocating and sorting a fresh array for every animated property/frame.
    // The strict/non-strict comparisons retain the previous stable-sort
    // behavior even for duplicate timestamps in unvalidated input.
    var first = 0, last = 0, before: Int?, after: Int?
    for index in keys.indices {
        let t = keys[index].time
        if t < keys[first].time { first = index }
        if t >= keys[last].time { last = index }
        if t <= time, before == nil || t >= keys[before!].time { before = index }
        if t > time, after == nil || t < keys[after!].time { after = index }
    }
    if time <= keys[first].time { return keys[first].value }
    if time >= keys[last].time { return keys[last].value }
    guard let before, let after else { return keys[last].value }
    let a = keys[before], b = keys[after]
    let progress=(time-a.time)/max(0.000001,b.time-a.time)
    let t = a.customCurve?.value(progress) ?? a.easing.value(progress)
    return a.value + (b.value - a.value) * t
}
enum AnimatedProperty: String, Codable, CaseIterable {
    case x, y, scale, rotation, opacity, volume, scaleX, scaleY, skewX, skewY, regionWidth, regionHeight
    case shutterAngle, blurSamples, trailCount, trailDuration, trailOpacity
    var isTemporal:Bool{[Self.shutterAngle,.blurSamples,.trailCount,.trailDuration,.trailOpacity].contains(self)}
    var unit:String{percent ? "":self == .trailDuration ? "秒":[.blurSamples,.trailCount].contains(self) ? "":"°"}
    var title: String {
        switch self {
        case .shutterAngle:return "シャッター角度"
        case .blurSamples:return "描画サンプル数"
        case .trailCount:return "残像の数"
        case .trailDuration:return "残像の長さ"
        case .trailOpacity:return "残像の不透明度"
        case .regionWidth: return "範囲の幅"
        case .regionHeight: return "範囲の高さ"
        case .scaleX: return "横の拡大率"
        case .scaleY: return "縦の拡大率"
        case .skewX: return "横の傾斜"
        case .skewY: return "縦の傾斜"
        case .x: return "X位置"
        case .y: return "Y位置"
        case .scale: return "拡大率"
        case .rotation: return "回転"
        case .opacity: return "不透明度"
        case .volume: return "音量"
        }
    }
    var range: ClosedRange<Double> {
        switch self {
        case .shutterAngle:return 0...360
        case .blurSamples:return 2...16
        case .trailCount:return 0...12
        case .trailDuration:return 0.001...3
        case .trailOpacity:return 0...1
        case .regionWidth,.regionHeight: return 0.001...4
        case .x, .y: return -2...3
        case .scale,.scaleX,.scaleY: return 0.01...10
        case .skewX,.skewY: return -75...75
        case .rotation: return -3600...3600
        case .opacity: return 0...1
        case .volume: return 0...2
        }
    }
    var percent: Bool { ![.rotation,.skewX,.skewY,.shutterAngle,.blurSamples,.trailCount,.trailDuration].contains(self) }
    func get(_ clip: Clip) -> Double {
        switch self {
        case .shutterAngle:return clip.temporalMotion?.shutterAngle ?? 180
        case .blurSamples:return Double(clip.temporalMotion?.samples ?? 6)
        case .trailCount:return Double(clip.temporalMotion?.trailCount ?? 0)
        case .trailDuration:return clip.temporalMotion?.trailDuration ?? 0.25
        case .trailOpacity:return clip.temporalMotion?.trailOpacity ?? 0.35
        case .regionWidth: return clip.adjustmentRegion?.width ?? 1
        case .regionHeight: return clip.adjustmentRegion?.height ?? 1
        case .scaleX: return clip.transform?.scaleX ?? 1
        case .scaleY: return clip.transform?.scaleY ?? 1
        case .skewX: return clip.transform?.skewX ?? 0
        case .skewY: return clip.transform?.skewY ?? 0
        case .x: return clip.x
        case .y: return clip.y
        case .scale: return clip.scale
        case .rotation: return clip.rotation ?? 0
        case .opacity: return clip.opacity
        case .volume: return clip.volume
        }
    }
    func set(_ value: Double, on clip: inout Clip) {
        let v = min(range.upperBound, max(range.lowerBound, value))
        switch self {
        case .shutterAngle,.blurSamples,.trailCount,.trailDuration,.trailOpacity:
            var t=clip.temporalMotion ?? TemporalMotion()
            switch self{case .shutterAngle:t.shutterAngle=v;case .blurSamples:t.samples=Int(v.rounded());case .trailCount:t.trailCount=Int(v.rounded());case .trailDuration:t.trailDuration=v;case .trailOpacity:t.trailOpacity=v;default:break};clip.temporalMotion=t
        case .regionWidth,.regionHeight:
            var region=clip.adjustmentRegion ?? AdjustmentRegion()
            if self == .regionWidth { region.width=v } else { region.height=v }; clip.adjustmentRegion=region
        case .scaleX,.scaleY,.skewX,.skewY:
            var t=clip.transform ?? Transform2D()
            switch self {case .scaleX:t.scaleX=v;case .scaleY:t.scaleY=v;case .skewX:t.skewX=v;case .skewY:t.skewY=v;default:break};clip.transform=t
        case .x: clip.x = v
        case .y: clip.y = v
        case .scale: clip.scale = v
        case .rotation: clip.rotation = v
        case .opacity: clip.opacity = v
        case .volume: clip.volume = v
        }
    }
}
struct AnimationTrack: Codable, Equatable, Identifiable {
    var id = UUID()
    var property: AnimatedProperty
    var enabled = true
    var keys: [AnimationKeyframe] = []
}
enum EntranceKind: String, Codable, CaseIterable {
    case none, fade, slideLeft, slideRight, slideUp, slideDown, zoom, wipeLeft, wipeRight, iris
    var title: String {
        switch self {
        case .none: return "なし"
        case .fade: return "フェード"
        case .slideLeft: return "左からスライド"
        case .slideRight: return "右からスライド"
        case .slideUp: return "上からスライド"
        case .slideDown: return "下からスライド"
        case .zoom: return "ズーム"
        case .wipeLeft: return "左→右ワイプ"
        case .wipeRight: return "右→左ワイプ"
        case .iris: return "円形ワイプ"
        }
    }
}
struct Entrance: Codable, Equatable {
    var kind = EntranceKind.none
    var duration: Double = 0.5
    var easing = Easing.easeOut
}
enum LoopMotionKind: String, Codable, CaseIterable {
    case shake, bounce, pulse, spin, typewriter
    var title: String {
        switch self {
        case .shake: return "震え"
        case .bounce: return "上下バウンド"
        case .pulse: return "拡大・縮小の反復"
        case .spin: return "連続回転"
        case .typewriter: return "一文字ずつ表示"
        }
    }
}
struct LoopMotion: Codable, Equatable, Identifiable {
    var id = UUID()
    var kind: LoopMotionKind
    var enabled = true
    var amount: Double = 0.1
    var period: Double = 1
}
struct ClipAnimation: Codable, Equatable {
    var entrance = Entrance()
    var exit = Entrance()
    var motions: [LoopMotion] = []
    var tracks: [AnimationTrack] = []
    /// Frozen on split/left trim to retain the original motion time domain.
    var span: Double?
}
enum AudioFadeCurve:String,Codable,CaseIterable {case linear,equalPower}
struct AudioFade: Codable, Equatable {
    var fadeIn: Double = 0
    var fadeOut: Double = 0
    var curve:AudioFadeCurve?
    func gain(_ progress:Double)->Double {let t=min(1,max(0,progress));return curve == .equalPower ? sin(t * .pi / 2):t}
}
enum SceneTransitionKind: String, Codable, CaseIterable {
    case dissolve, fadeBlack, fadeWhite, wipeLeft, wipeRight, wipeUp, wipeDown, slideLeft, slideRight, zoom, iris
    var title: String {
        switch self {
        case .dissolve: return "クロスフェード"
        case .fadeBlack: return "黒を挟んで切り替え"
        case .fadeWhite: return "白を挟んで切り替え"
        case .wipeLeft: return "左→右ワイプ"
        case .wipeRight: return "右→左ワイプ"
        case .wipeUp: return "下→上ワイプ"
        case .wipeDown: return "上→下ワイプ"
        case .slideLeft: return "左へ押し出す"
        case .slideRight: return "右へ押し出す"
        case .zoom: return "ズームで切り替え"
        case .iris: return "円形ワイプ"
        }
    }
}
struct SceneTransition: Codable, Equatable {
    var kind = SceneTransitionKind.dissolve
    var easing = Easing.easeInOut
}

enum EffectKind: String, Codable, CaseIterable {
    case blur, pixelate, brightness, contrast, saturation, hue, sepia, invert, glow, vignette, chromaKey, glitch, chromaticAberration, filmGrain, colorLUT
    var title: String {
        switch self {
        case .blur: return "ぼかし"
        case .pixelate: return "モザイク"
        case .brightness: return "明るさ"
        case .contrast: return "コントラスト"
        case .saturation: return "彩度（0%でモノクロ）"
        case .hue: return "色相"
        case .sepia: return "セピア"
        case .invert: return "色反転"
        case .glow: return "発光"
        case .vignette: return "周辺減光"
        case .chromaKey: return "クロマキー"
        case .glitch: return "ブロックグリッチ"
        case .chromaticAberration: return "色収差"
        case .filmGrain: return "フィルム粒子"
        case .colorLUT: return "3D LUT"
        }
    }
    var range: ClosedRange<Double> {
        switch self {
        case .blur, .glow, .chromaticAberration: return 0...100
        case .pixelate: return 1...100
        case .brightness: return -1...1
        case .contrast, .saturation: return 0...2
        case .hue: return -180...180
        default: return 0...1
        }
    }
    var defaultAmount: Double {
        switch self {
        case .blur: return 8
        case .pixelate: return 16
        case .brightness: return 0.1
        case .contrast: return 1.2
        case .saturation: return 0
        case .hue: return 30
        case .sepia, .invert: return 1
        case .glow: return 12
        case .vignette: return 0.7
        case .chromaKey: return 0.25
        case .glitch: return 0.5
        case .chromaticAberration: return 5
        case .filmGrain: return 0.2
        case .colorLUT: return 1
        }
    }
    var percent: Bool { ![.blur, .pixelate, .hue, .glow, .chromaticAberration].contains(self) }
    var unit: String { self == .hue ? "°" : (percent ? "" : "px") }
    var timeVarying:Bool {self == .glitch || self == .filmGrain}
}
struct VisualEffect: Codable, Equatable, Identifiable {
    var id = UUID()
    var kind: EffectKind
    var enabled = true
    var amount: Double
    var color = "00FF00"
    var lut:ColorLUT?
    var keys: [AnimationKeyframe] = []
    init(kind: EffectKind) { self.kind = kind; amount = kind.defaultAmount }
}

extension Clip {
    var animationTimeOffset: Double { animationOffset ?? 0 }
    func motionTime(at time: Double) -> Double { max(0, time - start + animationTimeOffset) }
    func animated(at time: Double,aspectRatio:Double?=nil) -> Clip {
        var result = self
        let local = motionTime(at: time)
        if let animation {
            for track in animation.tracks where track.enabled && (spatialAnimation == nil || ![.x,.y].contains(track.property)) {
                track.property.set(interpolate(track.keys, at: local, fallback: track.property.get(self)), on: &result)
            }
        if let spatialAnimation {
            let sample=spatialAnimation.sample(at:local,aspectRatio:aspectRatio);result.x=sample.point.x;result.y=sample.point.y
            if spatialAnimation.orientToPath {result.rotation=(result.rotation ?? 0)+sample.angle}
        }
            let span = animation.span ?? duration
            func entrance(_ spec: Entrance, progress: Double, outgoing: Bool) {
                guard spec.kind != .none else { return }
                let p = spec.easing.value(progress), remainder = 1 - p
                switch spec.kind {
                case .fade: result.opacity *= min(1, max(0, p))
                case .slideLeft: result.x -= remainder
                case .slideRight: result.x += remainder
                case .slideUp: result.y -= remainder
                case .slideDown: result.y += remainder
                case .zoom: result.scale *= max(0.001, p)
                default: break
                }
            }
            entrance(animation.entrance, progress: local / max(0.001, animation.entrance.duration), outgoing: false)
            entrance(animation.exit, progress: (span - local) / max(0.001, animation.exit.duration), outgoing: true)
            for motion in animation.motions where motion.enabled {
                let phase = local / motion.period * 2 * .pi
                switch motion.kind {
                case .shake:
                    result.x += sin(phase * 3) * motion.amount * 0.1
                    result.y += sin(phase * 4.7) * motion.amount * 0.1
                case .bounce: result.y -= abs(sin(phase / 2)) * motion.amount
                case .pulse: result.scale *= max(0.01, 1 + sin(phase) * motion.amount)
                case .spin: result.rotation = (result.rotation ?? 0) + local / motion.period * 360 * motion.amount
                case .typewriter:
                    result.text = String(text.prefix(min(text.count, max(0, Int(floor(local / motion.period * Double(text.count)))))))
                }
            }
        }
        if animation == nil {
        if let spatialAnimation {
            let sample=spatialAnimation.sample(at:local,aspectRatio:aspectRatio);result.x=sample.point.x;result.y=sample.point.y
            if spatialAnimation.orientToPath {result.rotation=(result.rotation ?? 0)+sample.angle}
        }
        }
        if let audioReactive {
            let value=audioReactive.value(at:local)
            result.scale *= max(0.01,1+value*audioReactive.scaleAmount)
            result.x += sin(local*47)*value*audioReactive.shakeAmount*0.1
            result.y += sin(local*61)*value*audioReactive.shakeAmount*0.1
        }
        result.opacity = min(1, max(0, result.opacity))
        result.scale = min(20, max(0.001, result.scale))
        return result
    }
    func audioVolume(at time: Double) -> Double {
        let local = max(0, time - start)
        var volume = self.volume
        if let track = animation?.tracks.first(where: { $0.property == .volume && $0.enabled }) {
            volume = interpolate(track.keys, at: motionTime(at: time), fallback: volume)
        }
        if let fade = audioFade {
            if fade.fadeIn > 0 { volume *= fade.gain(local / fade.fadeIn) }
            if fade.fadeOut > 0 { volume *= fade.gain((duration - local) / fade.fadeOut) }
        }
        return min(2, max(0, volume))
    }
    func validateAnimation() throws {
        if lyricWipe != nil {guard [.text,.speech].contains(kind) else{throw VMMError.message("歌詞ワイプはテキスト・セリフに設定してください。")};try lyricWipe?.validate(textCount:text.count)}
        if let segments=lyricWipe?.segments {let chars=Array(text);guard segments.allSatisfy({!chars[$0.startIndex..<$0.endIndex].contains(where:{$0.isNewline})}) else{throw VMMError.message("歌詞の区間を改行にまたがって指定できません。")}}
        if let ruby=lyricRuby {
            let chars=Array(text)
            guard [.text,.speech].contains(kind),ruby.count<=200,Set(ruby.map(\.id)).count==ruby.count else{throw VMMError.message("ルビの設定が不正です。")}
            var end=0
            for item in ruby {
                guard item.startIndex>=end,item.endIndex>item.startIndex,item.endIndex<=chars.count,!item.text.isEmpty,item.text.count<=100,!item.text.contains(where:{$0.isNewline}),!chars[item.startIndex..<item.endIndex].contains(where:{$0.isNewline}) else{throw VMMError.message("ルビの文字範囲または読みが不正です。")}
                if let timings=item.timings {
                    guard timings.count<=100 else{throw VMMError.message("ルビのタイミングが多すぎます。")}
                    var previousIndex = -1,previousTime = -1.0
                    for point in timings {guard point.index>previousIndex,point.index<item.text.count,point.offset.isFinite,point.offset>=0,point.offset>=previousTime,point.offset<=86400 else{throw VMMError.message("ルビのタイミングが不正です。")};previousIndex=point.index;previousTime=point.offset}
                    if let wipe=lyricWipe {
                        let spans=wipe.segments?.filter{max($0.startIndex,item.startIndex)<min($0.endIndex,item.endIndex)} ?? []
                        let span=(spans.last?.end ?? wipe.end)-(spans.first?.start ?? wipe.start)
                        guard timings.allSatisfy({$0.offset<=span+0.0001}) else{throw VMMError.message("ルビのタイミングが親文字の終了を超えています。")}
                    }
                }
                end=item.endIndex
            }
        }
        if spatialAnimation != nil {guard supportsParent || kind == .adjustment else{throw VMMError.message("このアイテムには移動パスを設定できません。")}}
        if textAnimation != nil {guard [.text,.speech].contains(kind) else{throw VMMError.message("文字アニメーションはテキスト・セリフに設定してください。")}}
        try spatialAnimation?.validated()
        try temporalMotion?.validated()
        try audioReactive?.validated()
        try tracking?.validated()
        if audioReactive != nil && (!supportsParent || kind == .adjustment){throw VMMError.message("音声連動は描画アイテムに設定してください。")}
        if temporalMotion != nil && (!supportsParent || kind == .adjustment){throw VMMError.message("ブラー・残像は描画アイテムに設定してください。")}
        try textAnimation?.validated()
        for mask in masks ?? [] {try mask.path?.validated();if mask.path?.closed==false{throw VMMError.message("マスクのパスは閉じてください。")}}
        if let p=anchorPoint {guard p.x.isFinite,p.y.isFinite,(-2...3).contains(p.x),(-2...3).contains(p.y) else{throw VMMError.message("支点が不正です。")}}
        func keys(_ list: [AnimationKeyframe], range: ClosedRange<Double>) throws {
            guard list.count <= 500, Set(list.map(\.id)).count == list.count,
                  Set(list.map(\.time)).count == list.count,
                  list.allSatisfy({ $0.time.isFinite && (0...86400).contains($0.time) && $0.value.isFinite && range.contains($0.value) && ($0.customCurve?.isValid ?? true) }) else { throw VMMError.message("キーフレームの設定が不正です。") }
        }
        if let rotation { guard rotation.isFinite, (-3600...3600).contains(rotation) else { throw VMMError.message("回転角が不正です。") } }
        if let animationOffset { guard animationOffset.isFinite, (0...86400).contains(animationOffset) else { throw VMMError.message("アニメーションの開始位置が不正です。") } }
        if let animation {
            guard animation.tracks.count <= AnimatedProperty.allCases.count, Set(animation.tracks.map(\.property)).count == animation.tracks.count,
                  animation.motions.count <= 16, Set(animation.motions.map(\.id)).count == animation.motions.count,
                  [animation.entrance.duration, animation.exit.duration].allSatisfy({ $0.isFinite && (0.001...60).contains($0) }),
                  animation.span == nil || (animation.span!.isFinite && (0...86400).contains(animation.span!)),
                  animation.motions.allSatisfy({ $0.amount.isFinite && (0...2).contains($0.amount) && $0.period.isFinite && (0.01...60).contains($0.period) }) else { throw VMMError.message("アニメーションの設定が不正です。") }
            for track in animation.tracks {if track.property.isTemporal && (temporalMotion==nil || !supportsParent){throw VMMError.message("ブラー・残像の設定を追加してからキーフレームを設定してください。")};try keys(track.keys, range: track.property.range) }
        }
        if let effects {
            guard effects.count <= 32, Set(effects.map(\.id)).count == effects.count else { throw VMMError.message("エフェクトが多すぎるか重複しています。") }
            for effect in effects {
                guard effect.amount.isFinite, effect.kind.range.contains(effect.amount), effect.color.count == 6, UInt32(effect.color, radix: 16) != nil else { throw VMMError.message("エフェクトの設定が不正です。") }
                guard effect.lut == nil || effect.kind == .colorLUT else {throw VMMError.message("LUTの設定が不正です。")}
                try effect.lut?.validate()
                try keys(effect.keys, range: effect.kind.range)
            }
        }
        if let audioFade {
            guard [audioFade.fadeIn, audioFade.fadeOut].allSatisfy({ $0.isFinite && (0...60).contains($0) }) else { throw VMMError.message("音声フェードの設定が不正です。") }
        }
    }
    mutating func preserveAnimationDomain() {
        let originalSpan = duration + animationTimeOffset
        if animation != nil, animation?.span == nil { animation?.span = originalSpan }
    }
}
