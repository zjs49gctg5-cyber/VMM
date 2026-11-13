import SwiftUI
import AppKit

enum AnimationSection { case all, entrances, motions, keyframes }

struct AnimationInspectorView: View {
    @ObservedObject var store: EditorStore
    let clip: Clip
    var section = AnimationSection.all
    @State private var property = AnimatedProperty.x
    @State private var entrances = false
    @State private var motions = false
    @State private var keyframes = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Menu(L("VMMプリセット")) {
                ForEach(store.enabledDataExtensions){package in Menu(package.name){ForEach(package.presets,id:\.name){preset in Button(preset.name){store.applyPreset(preset,clipID:clip.id)}}}}
                ForEach(EffectPreset.builtins.filter { clip.kind == .audio ? $0.audioFade != nil : $0.animation != nil }, id: \.name) { preset in
                    Button(preset.name) { store.applyPreset(preset, clipID: clip.id) }
                }
                Divider()
                Button(L("プリセットを読み込む…")) { store.importEffectPreset(clipID: clip.id) }
                Button(L("現在の設定を保存…")) { store.exportEffectPreset(clipID: clip.id) }
                Divider()
                Button(L("動きの設定を解除")) { store.edit(clip.id) { $0.spatialAnimation=nil;$0.textAnimation=nil;$0.animation = nil; $0.customAnimation = nil; $0.animationOffset = nil; $0.audioFade = nil } }
            }
            if ![.audio,.adjustment].contains(clip.kind) {
                if section == .all || section == .entrances {
                PanelDisclosure(L("登場・退場"), isExpanded: $entrances) {
                    VStack(alignment: .leading, spacing: 10) {
                        EntranceControls(store: store, clip: clip, exit: false)
                        Divider()
                        EntranceControls(store: store, clip: clip, exit: true)
                    }.padding(.top, 8)
                }
                }
                if section == .all || section == .motions {
                PanelDisclosure(L("反復モーション"), isExpanded: $motions) {
                    VStack(alignment: .leading, spacing: 10) {
                        Menu(L("モーションを追加")) {
                            ForEach(LoopMotionKind.allCases.filter { $0 != .typewriter || [.text, .speech].contains(clip.kind) }, id: \.self) { kind in
                                Button(kind.title) { store.edit(clip.id) { c in
                                    var animation = c.animation ?? ClipAnimation()
                                    if animation.motions.count < 16 { animation.motions.append(LoopMotion(kind: kind, amount: kind == .spin || kind == .typewriter ? 1 : 0.1, period: kind == .typewriter ? 2 : 1)) }
                                    c.animation = animation
                                } }
                            }
                        }
                        ForEach(clip.animation?.motions ?? []) { motion in MotionRow(store: store, clipID: clip.id, motion: motion) }
                    }.padding(.top, 8)
                }
                }
            }
            if section == .all || section == .keyframes {
            PanelDisclosure(L("キーフレーム（中間点）"), isExpanded: $keyframes) {
                VStack(alignment: .leading, spacing: 10) {
                    VMMMenuPicker(L("項目"), selection: $property) {
                        VMMOptions(clip.availableAnimatedProperties, id: \.self) { VMMChoice(text:L($0.title),value:$0) }
                    }
                    HStack {
                        Button(L("現在位置に追加")) { store.addKeyframe(clip.kind == .audio ? .volume : property, clipID: clip.id) }
                        Button(L("開始・終了")) { store.addKeyframe(clip.kind == .audio ? .volume : property, clipID: clip.id, endpoints: true) }
                    }
                    Text(L("時刻はアイテム先頭からの秒数。設定値は基本値より優先されます。区間の補間は左側の点で選びます。"))
                        .vmmFont(size:12).foregroundColor(.secondary)
                    ForEach(clip.animation?.tracks ?? []) { track in KeyframeTrackControls(store: store, clip: clip, track: track) }
                }.padding(.top, 8)
            }

            }
            if section == .all,store.project.asset(for:clip)?.psd != nil {
                PanelDisclosure(L("立ち絵・表情の切り替え")) {PSDAnimationControls(store:store,clip:clip)}
            }
        }.onAppear { property = clip.availableAnimatedProperties.first ?? .x; entrances = section == .entrances; motions = section == .motions; keyframes = section == .keyframes }
    }
}

struct EntranceControls: View {
    @ObservedObject var store: EditorStore
    let clip: Clip
    let exit: Bool
    private var spec: Entrance { exit ? (clip.animation?.exit ?? Entrance()) : (clip.animation?.entrance ?? Entrance()) }
    func binding<T>(_ key: WritableKeyPath<Entrance, T>) -> Binding<T> {
        Binding(get: { let a = store.project.clips.first { $0.id == clip.id }?.animation ?? ClipAnimation(); return (exit ? a.exit : a.entrance)[keyPath: key] }, set: { value in
            store.edit(clip.id) { c in
                var a = c.animation ?? ClipAnimation()
                if exit { a.exit[keyPath: key] = value } else { a.entrance[keyPath: key] = value }
                c.animation = a
            }
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VMMMenuPicker(exit ? "退場" : "登場", selection: binding(\.kind)) {
                VMMOptions(EntranceKind.allCases, id: \.self) { kind in VMMChoice(text:exit ? kind.title.replacingOccurrences(of: "から", with: "へ") : kind.title,value:kind) }
            }
            if spec.kind != .none {
                NumberInput(title: "時間", value: binding(\.duration), range: 0.001...60, step: 1 / Double(store.project.fps), unit: "秒")
                VMMMenuPicker(L("動き方"), selection: binding(\.easing)) { VMMOptions(Easing.allCases.filter { $0 != .hold }, id: \.self) { VMMChoice(text:L($0.title),value:$0) } }
            }
        }
    }
}

struct MotionRow: View {
    @ObservedObject var store: EditorStore
    let clipID: UUID
    let motion: LoopMotion
    func binding<T>(_ key: WritableKeyPath<LoopMotion, T>) -> Binding<T> {
        Binding(get: { (store.project.clips.first { $0.id == clipID }?.animation?.motions.first { $0.id == motion.id } ?? motion)[keyPath: key] }, set: { value in
            store.edit(clipID) { c in guard let i = c.animation?.motions.firstIndex(where: { $0.id == motion.id }) else { return }; c.animation?.motions[i][keyPath: key] = value }
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle(motion.kind.title, isOn: binding(\.enabled))
                Spacer()
                Button { store.edit(clipID) { $0.animation?.motions.removeAll { $0.id == motion.id } } } label: { UIIcon(systemName: "trash") }.buttonStyle(.borderless)
            }
            if motion.kind != .typewriter { NumberInput(title: "強さ", value: binding(\.amount), range: 0...2, percent: true) }
            NumberInput(title: motion.kind == .typewriter ? "全文表示まで" : "周期", value: binding(\.period), range: 0.01...60, step: 0.1, unit: "秒")
        }.padding(8).background(Color.primary.opacity(0.04)).cornerRadius(5)
    }
}

struct KeyframeTrackControls: View {
    @ObservedObject var store: EditorStore
    let clip: Clip
    let track: AnimationTrack
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle(track.property.title, isOn: Binding(get: { track.enabled }, set: { value in store.edit(clip.id) { c in
                    guard let i = c.animation?.tracks.firstIndex(where: { $0.id == track.id }) else { return }; c.animation?.tracks[i].enabled = value
                } }))
                Spacer()
                Button { store.edit(clip.id) { $0.animation?.tracks.removeAll { $0.id == track.id } } } label: { UIIcon(systemName: "trash") }.buttonStyle(.borderless)
            }
            PanelDisclosure("中間点 \(track.keys.count) 個", isExpanded:$expanded) {
            KeyframeGraph(store:store,clip:clip,track:track)
            ForEach(track.keys.sorted { $0.time < $1.time }) { key in
                KeyframeRow(store: store, clip: clip, track: track, key: key)
            }
            }
        }.padding(8).background(Color.primary.opacity(0.04)).cornerRadius(5)
    }
}
struct KeyframeRow: View {
    @ObservedObject var store: EditorStore
    let clip: Clip
    let track: AnimationTrack
    let key: AnimationKeyframe
    func binding<T>(_ path: WritableKeyPath<AnimationKeyframe, T>) -> Binding<T> {
        Binding(get: { (store.project.clips.first { $0.id == clip.id }?.animation?.tracks.first { $0.id == track.id }?.keys.first { $0.id == key.id } ?? key)[keyPath: path] }, set: { value in
            store.edit(clip.id) { c in
                guard let t = c.animation?.tracks.firstIndex(where: { $0.id == track.id }), let k = c.animation?.tracks[t].keys.firstIndex(where: { $0.id == key.id }) else { return }
                if path == \AnimationKeyframe.time, let time = value as? Double,
                   c.animation!.tracks[t].keys.contains(where: { $0.id != key.id && abs($0.time - time) < 0.000001 }) { return }
                c.animation?.tracks[t].keys[k][keyPath: path] = value
                if path == \AnimationKeyframe.easing {c.animation?.tracks[t].keys[k].customCurve=nil}
            }
        })
    }
    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Button("◆ \(String(format: "%.3f", key.time)) 秒へ") { store.seek(clip.start + key.time - clip.animationTimeOffset) }.buttonStyle(.borderless)
                Spacer()
                Button { store.edit(clip.id) { c in guard let i = c.animation?.tracks.firstIndex(where: { $0.id == track.id }) else { return }; c.animation?.tracks[i].keys.removeAll { $0.id == key.id } } } label: { UIIcon(systemName: "xmark") }.buttonStyle(.borderless)
            }
            NumberInput(title: "時刻", value: binding(\.time), range: 0...86400, step: 1 / Double(store.project.fps), unit: "秒")
            NumberInput(title: track.property.title, value: binding(\.value), range: track.property.range, unit: track.property.percent ? "" : "°", percent: track.property.percent)
            VMMMenuPicker(L("補間"), selection: binding(\.easing)) { VMMOptions(Easing.allCases, id: \.self) { VMMChoice(text:L($0.title),value:$0) } }
        }.padding(.vertical, 4)
    }
}

struct EffectStackControls: View {
    @ObservedObject var store: EditorStore
    let clip: Clip
    var body: some View {
        PanelDisclosure(L("映像エフェクト（順番に適用）")) {
            VStack(alignment: .leading, spacing: 10) {
                Menu(L("エフェクトを追加")) {
                    ForEach(EffectKind.allCases, id: \.self) { kind in Button(L(kind.title)) { store.edit(clip.id) { c in
                        var list = c.effects ?? []; if list.count < 32 { list.append(VisualEffect(kind: kind)) }; c.effects = list
                    } } }
                }
                ForEach(Array((clip.effects ?? []).enumerated()), id: \.element.id) { index, effect in
                    EffectRow(store: store, clip: clip, effect: effect, index: index)
                }
            }.padding(.top, 8)
        }
    }
}
struct EffectRow: View {
    @ObservedObject var store: EditorStore
    let clip: Clip
    let effect: VisualEffect
    let index: Int
    func binding<T>(_ key: WritableKeyPath<VisualEffect, T>) -> Binding<T> {
        Binding(get: { (store.project.clips.first { $0.id == clip.id }?.effects?.first { $0.id == effect.id } ?? effect)[keyPath: key] }, set: { value in
            store.edit(clip.id) { c in guard let i = c.effects?.firstIndex(where: { $0.id == effect.id }) else { return }; c.effects?[i][keyPath: key] = value }
        })
    }
    func reorder(_ delta: Int) { store.edit(clip.id) { c in
        guard var list = c.effects, let i = list.firstIndex(where: { $0.id == effect.id }), list.indices.contains(i + delta) else { return }
        list.swapAt(i, i + delta); c.effects = list
    } }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Toggle(effect.kind.title, isOn: binding(\.enabled)).lineLimit(2)
                Spacer(minLength: 0)
                Button { reorder(-1) } label: { UIIcon(systemName: "arrow.up") }.disabled(index == 0)
                Button { reorder(1) } label: { UIIcon(systemName: "arrow.down") }.disabled(index + 1 >= (clip.effects?.count ?? 0))
                Button { store.edit(clip.id) { $0.effects?.removeAll { $0.id == effect.id } } } label: { UIIcon(systemName: "trash") }
            }.buttonStyle(.borderless)
            NumberInput(title: effect.kind == .chromaKey ? "許容範囲" : "強さ", value: binding(\.amount), range: effect.kind.range, unit: effect.kind.unit, percent: effect.kind.percent)
            if effect.kind == .colorLUT {ColorLUTPicker(store:store,cube:binding(\.lut).wrappedValue){try store.setClipLUT($0,clipID:clip.id,effectID:effect.id)}}
            if effect.kind == .chromaKey {
                ColorPicker(L("抜く色"), selection: Binding(get: { Color(nsColor: NSColor(hex: binding(\.color).wrappedValue)) }, set: { binding(\.color).wrappedValue = NSColor($0).hex }), supportsOpacity: false)
            }
            PanelDisclosure(L("強さのキーフレーム")) {
                VStack(spacing: 8) {
                    Button(L("現在位置に追加")) { store.edit(clip.id) { c in
                        guard let i = c.effects?.firstIndex(where: { $0.id == effect.id }) else { return }
                        let time = (max(c.animationTimeOffset, min(c.duration + c.animationTimeOffset, c.motionTime(at: store.playhead))) * Double(store.project.fps)).rounded() / Double(store.project.fps)
                        let value = min(effect.kind.range.upperBound, max(effect.kind.range.lowerBound, interpolate(c.effects![i].keys, at: time, fallback: c.effects![i].amount)))
                        if let k = c.effects?[i].keys.firstIndex(where: { abs($0.time - time) < 0.5 / Double(store.project.fps) }) { c.effects?[i].keys[k].value = value }
                        else if (c.effects?[i].keys.count ?? 0) < 500 { c.effects?[i].keys.append(AnimationKeyframe(time: time, value: value)) }
                    } }
                    ForEach(effect.keys.sorted { $0.time < $1.time }) { key in EffectKeyRow(store: store, clipID: clip.id, effect: effect, key: key) }
                    if !effect.keys.isEmpty { Text(L("キーフレームの値が「強さ」より優先されます。")).vmmFont(size:12).foregroundColor(.secondary) }
                }.padding(.top, 6)
            }
        }.padding(8).background(Color.primary.opacity(0.04)).cornerRadius(5)
    }
}
struct EffectKeyRow: View {
    @ObservedObject var store: EditorStore
    let clipID: UUID
    let effect: VisualEffect
    let key: AnimationKeyframe
    func binding<T>(_ path: WritableKeyPath<AnimationKeyframe, T>) -> Binding<T> {
        Binding(get: { (store.project.clips.first { $0.id == clipID }?.effects?.first { $0.id == effect.id }?.keys.first { $0.id == key.id } ?? key)[keyPath: path] }, set: { value in
            store.edit(clipID) { c in
                guard let i = c.effects?.firstIndex(where: { $0.id == effect.id }), let k = c.effects?[i].keys.firstIndex(where: { $0.id == key.id }) else { return }
                if path == \AnimationKeyframe.time, let time = value as? Double,
                   c.effects![i].keys.contains(where: { $0.id != key.id && abs($0.time - time) < 0.000001 }) { return }
                c.effects?[i].keys[k][keyPath: path] = value
            }
        })
    }
    var body: some View {
        VStack(spacing: 6) {
            HStack { Text(L("◆ キーフレーム")); Spacer(); Button { store.edit(clipID) { c in guard let i = c.effects?.firstIndex(where: { $0.id == effect.id }) else { return }; c.effects?[i].keys.removeAll { $0.id == key.id } } } label: { UIIcon(systemName: "xmark") }.buttonStyle(.borderless) }
            NumberInput(title: "時刻", value: binding(\.time), range: 0...86400, step: 1 / Double(store.project.fps), unit: "秒")
            NumberInput(title: "強さ", value: binding(\.value), range: effect.kind.range, unit: effect.kind.unit, percent: effect.kind.percent)
            VMMMenuPicker(L("補間"), selection: binding(\.easing)) { VMMOptions(Easing.allCases, id: \.self) { VMMChoice(text:L($0.title),value:$0) } }
        }
    }
}

struct SceneTransitionControls: View {
    @ObservedObject var store: EditorStore
    let clip: Clip
    func binding<T>(_ key: WritableKeyPath<SceneTransition, T>) -> Binding<T> {
        Binding(get: { (store.project.clips.first { $0.id == clip.id }?.sceneTransition ?? SceneTransition())[keyPath: key] }, set: { value in
            store.edit(clip.id) { c in var settings = c.sceneTransition ?? SceneTransition(); settings[keyPath: key] = value; c.sceneTransition = settings }
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VMMMenuPicker(L("切り替え方"), selection: binding(\.kind)) { VMMOptions(SceneTransitionKind.allCases, id: \.self) { VMMChoice(text:L($0.title),value:$0) } }
            VMMMenuPicker(L("動き方"), selection: binding(\.easing)) { VMMOptions(Easing.allCases.filter { $0 != .hold }, id: \.self) { VMMChoice(text:L($0.title),value:$0) } }
            Text(L("場面が変わる時刻に先頭を合わせます。このアイテムより下のレイヤーだけを、直前の場面から現在の場面へ切り替えます。同じレイヤーと上のレイヤーは対象外です。"))
                .vmmFont(size:12).foregroundColor(.secondary)
        }
    }
}

struct AudioFadeControls: View {
    @ObservedObject var store: EditorStore
    let clip: Clip
    func binding(_ key: WritableKeyPath<AudioFade, Double>) -> Binding<Double> {
        Binding(get: { (store.project.clips.first { $0.id == clip.id }?.audioFade ?? AudioFade())[keyPath: key] }, set: { value in
            store.edit(clip.id) { c in var fade = c.audioFade ?? AudioFade(); fade[keyPath: key] = value; c.audioFade = fade }
        })
    }
    var body: some View {
        VStack(spacing: 8) {
            NumberInput(title: "フェードイン", value: binding(\.fadeIn), range: 0...60, step: 0.1, unit: "秒")
            NumberInput(title: "フェードアウト", value: binding(\.fadeOut), range: 0...60, step: 0.1, unit: "秒")
            VMMMenuPicker(L("フェード曲線"),selection:Binding(get:{clip.audioFade?.curve ?? .linear},set:{value in store.edit(clip.id){c in var fade=c.audioFade ?? AudioFade();fade.curve=value;c.audioFade=fade}})) {VMMChoice(text:L("直線"),value:AudioFadeCurve.linear);VMMChoice(text:L("等パワー"),value:AudioFadeCurve.equalPower)}
        }
    }
}
