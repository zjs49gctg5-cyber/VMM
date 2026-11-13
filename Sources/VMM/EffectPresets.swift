import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct EffectPreset: Codable, Equatable {
    var version = 1
    var name: String
    var spatialAnimation:SpatialAnimation?
    var shapeStyle:ShapeStyle?
    var temporalMotion:TemporalMotion?
    var audioReactive:AudioReactive?
    var anchorPoint:NormalizedPoint?
    var textAnimation:CharacterAnimation?
    var animation: ClipAnimation?
    var effects: [VisualEffect]?
    var audioFade: AudioFade?
    var transform:Transform2D?
    var masks:[ClipMask]?
    var blendMode:CompositeMode?
    var particles:ParticleSettings?
    var playbackRate:Double?
    var preservePitch:Bool?
    var equalizer:Equalizer?
    var adjustmentRegion:AdjustmentRegion?
    func validated() throws -> EffectPreset {
        guard version == 1, !name.isEmpty, name.count <= 120 else { throw VMMError.message("未対応または不正なVMMプリセットです。") }
        var clip = Clip(kind: .text, name: name, track: 0, start: 0, duration: 5)
        clip.shapeStyle=shapeStyle;clip.temporalMotion=temporalMotion;clip.audioReactive=audioReactive;clip.audioReactive?.assetID=nil;try shapeStyle?.validate()
        clip.spatialAnimation=spatialAnimation;clip.anchorPoint=anchorPoint;clip.textAnimation=textAnimation
        clip.animation = animation; clip.effects = effects; clip.audioFade = audioFade
        try clip.validateAnimation()
        clip.transform=transform;clip.masks=masks;clip.blendMode=blendMode;clip.particles=particles;clip.playbackRate=playbackRate;clip.equalizer=equalizer;clip.adjustmentRegion=adjustmentRegion
        var project=Project();project.clips=[clip]
        project.assets=Array(Set((masks ?? []).compactMap(\.assetID))).map {MediaAsset(id:$0,name:"mask",file:"mask.png",kind:.image,duration:5)}
        try clip.validateAnimation()
        try clip.validateAdvanced(project:project)
        return self
    }
    static var builtins: [EffectPreset] {
        var fade = ClipAnimation(); fade.entrance = Entrance(kind: .fade, duration: 0.5, easing: .easeOut); fade.exit = Entrance(kind: .fade, duration: 0.5, easing: .easeIn)
        var pop = ClipAnimation(); pop.entrance = Entrance(kind: .zoom, duration: 0.5, easing: .backOut)
        var slide = ClipAnimation(); slide.entrance = Entrance(kind: .slideLeft, duration: 0.6, easing: .easeOut); slide.exit = Entrance(kind: .slideRight, duration: 0.5, easing: .easeIn)
        var shake = ClipAnimation(); shake.motions = [LoopMotion(kind: .shake, amount: 0.12, period: 0.4)]
        var bounce = ClipAnimation(); bounce.motions = [LoopMotion(kind: .bounce, amount: 0.05, period: 1)]
        var pulse = ClipAnimation(); pulse.motions = [LoopMotion(kind: .pulse, amount: 0.08, period: 2)]
        var typewriter = ClipAnimation(); typewriter.motions = [LoopMotion(kind: .typewriter, amount: 1, period: 2)]
        var gray = VisualEffect(kind: .saturation); gray.amount = 0
        var sepia = VisualEffect(kind: .sepia); sepia.amount = 0.6
        var vignette = VisualEffect(kind: .vignette); vignette.amount = 0.6
        var blur = VisualEffect(kind: .blur); blur.keys = [AnimationKeyframe(time: 0, value: 24, easing: .easeOut), AnimationKeyframe(time: 1, value: 0)]
        return [
            EffectPreset(name: "フェードイン・アウト", animation: fade),
            EffectPreset(name: "ポン出し", animation: pop),
            EffectPreset(name: "スライド登場・退場", animation: slide),
            EffectPreset(name: "震える立ち絵", animation: shake),
            EffectPreset(name: "上下にバウンド", animation: bounce),
            EffectPreset(name: "呼吸する拡大・縮小", animation: pulse),
            EffectPreset(name: "タイプライター", animation: typewriter),
            EffectPreset(name: "モノクロ", effects: [gray]),
            EffectPreset(name: "映画調セピア", effects: [sepia, vignette]),
            EffectPreset(name: "ぼかしからクリア", effects: [blur]),
            EffectPreset(name: "BGMフェード", audioFade: AudioFade(fadeIn: 1, fadeOut: 1))
        ]
    }
}

@MainActor
extension EditorStore {
    func animationBinding<T>(_ key: WritableKeyPath<ClipAnimation, T>, clipID: UUID) -> Binding<T> {
        Binding(get: { (self.project.clips.first { $0.id == clipID }?.animation ?? ClipAnimation())[keyPath: key] }, set: { value in
            self.edit(clipID) { c in var animation = c.animation ?? ClipAnimation(); animation[keyPath: key] = value; c.animation = animation }
        })
    }
    func addKeyframe(_ property: AnimatedProperty, clipID: UUID, endpoints: Bool = false) {
        guard let clip = project.clips.first(where: { $0.id == clipID }) else { return }
        let fps = Double(project.fps)
        let local = min(clip.animationTimeOffset + clip.duration, max(clip.animationTimeOffset, (clip.motionTime(at: playhead) * fps).rounded() / fps))
        let value = property.get(clip.animated(at: playhead))
        edit(clipID) { c in
            if [.regionWidth,.regionHeight].contains(property),c.adjustmentRegion == nil {c.adjustmentRegion=AdjustmentRegion(width:1,height:1)}
            var animation = c.animation ?? ClipAnimation()
            var track = animation.tracks.first { $0.property == property } ?? AnimationTrack(property: property)
            func insert(_ time: Double, _ v: Double) {
                if let i = track.keys.firstIndex(where: { abs($0.time - time) < 0.5 / fps }) { track.keys[i].value = v }
                else if track.keys.count < 500 { track.keys.append(AnimationKeyframe(time: time, value: v)) }
            }
            if endpoints {
                insert(c.animationTimeOffset, property.get(c)); insert(c.animationTimeOffset + c.duration, property.get(c))
            } else { insert(local, value) }
            if let index = animation.tracks.firstIndex(where: { $0.property == property }) { animation.tracks[index] = track }
            else { animation.tracks.append(track) }
            c.animation = animation
        }
    }
    func applyPreset(_ preset: EffectPreset, clipID: UUID) {
        do {
            _ = try preset.validated()
            if let target=project.clips.first(where:{$0.id==clipID}) {
                guard preset.textAnimation==nil || [.text,.speech].contains(target.kind),preset.spatialAnimation==nil || target.supportsParent || target.kind == .adjustment else{throw VMMError.message("このアイテムにはプリセットのアニメーションを適用できません。")}
            }
            if let target=project.clips.first(where:{$0.id==clipID}) {guard preset.shapeStyle==nil || target.kind == .shape,(preset.temporalMotion==nil && preset.audioReactive==nil) || target.supportsParent else{throw VMMError.message("このアイテムにはプリセットの描画設定を適用できません。")}}
            let assetIDs=Set(project.assets.map(\.id))
            edit(clipID) { clip in
                if var animation = preset.animation { animation.span = nil; clip.animation = animation; clip.animationOffset = 0;clip.customAnimation=nil }
                if let path=preset.spatialAnimation {clip.spatialAnimation=path;clip.animationOffset=0}
                if let style=preset.shapeStyle{clip.shapeStyle=style;clip.animationOffset=0}
                if let temporal=preset.temporalMotion{clip.temporalMotion=temporal}
                if var reactive=preset.audioReactive{reactive.assetID=nil;clip.audioReactive=reactive;clip.animationOffset=0}
                if let anchor=preset.anchorPoint {clip.anchorPoint=anchor}
                if let text=preset.textAnimation {clip.textAnimation=text}
                if let effects = preset.effects { clip.effects = effects }
                if let fade = preset.audioFade { clip.audioFade = fade }
                if let region=preset.adjustmentRegion {clip.adjustmentRegion=region}
                if let transform=preset.transform {clip.transform=transform}
                if let masks=preset.masks {clip.masks=masks.map {mask in var m=mask;if m.assetID.map(assetIDs.contains) != true {m.assetID=nil};return m}}
                if let mode=preset.blendMode {clip.blendMode=mode}
                if let particles=preset.particles {clip.particles=particles}
                if let equalizer=preset.equalizer {clip.equalizer=equalizer}
                if let rate=preset.playbackRate {clip.duration=clip.duration*clip.mediaRate/rate;clip.playbackRate=rate}
                if let pitch=preset.preservePitch {clip.preservePitch=pitch}
            }
            status = "プリセット「\(preset.name)」を適用しました。"
            if preset.masks?.contains(where:{ mask in mask.kind == .image && !project.assets.contains(where:{$0.id==mask.assetID})}) == true {status += " マスク画像を選択してください。"}
        } catch { self.error = error.localizedDescription }
    }
    func importEffectPreset(clipID: UUID) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 1_048_576 else { throw VMMError.message("プリセットは1MB以内にしてください。") }
            let preset = try JSONDecoder().decode(EffectPreset.self, from: Data(contentsOf: url)).validated()
            applyPreset(preset, clipID: clipID)
        } catch { self.error = "VMMプリセットを読み込めませんでした。\n\(error.localizedDescription)" }
    }
    func exportEffectPreset(clipID: UUID) {
        guard let clip = project.clips.first(where: { $0.id == clipID }) else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = clip.name + ".vmmfx.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            var animation = clip.animation; animation?.span = nil
            let preset = try EffectPreset(name: clip.name,spatialAnimation:clip.spatialAnimation,shapeStyle:clip.shapeStyle,temporalMotion:clip.temporalMotion,audioReactive:clip.audioReactive,anchorPoint:clip.anchorPoint,textAnimation:clip.textAnimation, animation: animation, effects: clip.effects, audioFade: clip.audioFade,transform:clip.transform,masks:clip.masks,blendMode:clip.blendMode,particles:clip.particles,playbackRate:clip.playbackRate,preservePitch:clip.preservePitch,equalizer:clip.equalizer,adjustmentRegion:clip.adjustmentRegion).validated()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            var portable=preset;portable.audioReactive?.assetID=nil;let data=try encoder.encode(portable);guard data.count<=1_048_576 else{throw VMMError.message("プリセットは1MB以内にしてください。音声連動の解析データはプロジェクト／シーンで保存できます。")};try data.write(to:url,options:.atomic)
            status = "VMMプリセットを保存しました。"
        } catch { self.error = error.localizedDescription }
    }
}
