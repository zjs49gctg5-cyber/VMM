import Foundation
import CoreGraphics

enum CompositeMode: String, Codable, CaseIterable {
    case normal, multiply, screen, overlay, darken, lighten, colorDodge, colorBurn, difference, exclusion, add
    var title: String {
        switch self {
        case .normal: return "通常"
        case .multiply: return "乗算"
        case .screen: return "スクリーン"
        case .overlay: return "オーバーレイ"
        case .darken: return "比較（暗）"
        case .lighten: return "比較（明）"
        case .colorDodge: return "覆い焼き"
        case .colorBurn: return "焼き込み"
        case .difference: return "差の絶対値"
        case .exclusion: return "除外"
        case .add: return "加算"
        }
    }
    var cg: CGBlendMode {
        switch self {
        case .normal: return .normal
        case .multiply: return .multiply
        case .screen: return .screen
        case .overlay: return .overlay
        case .darken: return .darken
        case .lighten: return .lighten
        case .colorDodge: return .colorDodge
        case .colorBurn: return .colorBurn
        case .difference: return .difference
        case .exclusion: return .exclusion
        case .add: return .plusLighter
        }
    }
}
struct NormalizedPoint: Codable, Equatable { var x: Double; var y: Double }
struct Transform2D: Codable, Equatable {
    var scaleX: Double = 1
    var scaleY: Double = 1
    var skewX: Double = 0
    var skewY: Double = 0
    var perspective = false
    // Clockwise from top-left in a canvas-local coordinate system.
    var corners = [NormalizedPoint(x:0,y:0), NormalizedPoint(x:1,y:0), NormalizedPoint(x:1,y:1), NormalizedPoint(x:0,y:1)]
}
enum MaskKind: String, Codable, CaseIterable {
    case rectangle, ellipse, polygon, image
    var title: String { switch self { case .rectangle: return "矩形"; case .ellipse: return "楕円"; case .polygon: return "多角形"; case .image: return "画像のアルファ" } }
}
struct ClipMask: Codable, Equatable, Identifiable {
    var path:AnimatedBezierShape?
    var id = UUID()
    var kind = MaskKind.rectangle
    var enabled = true
    var inverted = false
    var x: Double = 0.5
    var y: Double = 0.5
    var width: Double = 0.5
    var height: Double = 0.5
    var feather: Double = 0
    var assetID: UUID?
    var points = [NormalizedPoint(x:0,y:0), NormalizedPoint(x:1,y:0), NormalizedPoint(x:1,y:1), NormalizedPoint(x:0,y:1)]
}
enum ParticleShape: String, Codable, CaseIterable {
    case circle, square, star
    var title: String { switch self { case .circle: return "丸"; case .square: return "四角"; case .star: return "星" } }
}
struct ParticleSettings: Codable, Equatable {
    var seed: UInt64 = 42
    var count: Int = 100
    var lifetime: Double = 2
    var velocity: Double = 0.25
    var angle: Double = -90
    var spread: Double = 60
    var gravity: Double = 0.1
    var size: Double = 12
    var emitterWidth: Double = 0
    var emitterHeight: Double = 0
    var burst = false
    var shape = ParticleShape.circle
    var endColor = "FF7733"
}
struct EQBand: Codable, Equatable, Identifiable {
    var id = UUID()
    var frequency: Double
    var gain: Double = 0
    var bandwidth: Double = 1
    var enabled = true
}
struct Equalizer: Codable, Equatable {
    var enabled = true
    var bands = [60.0,250,1000,4000,12000].map { EQBand(frequency:$0) }
}

extension Clip {
    var mediaRate: Double { playbackRate ?? 1 }
    var timeWarpCurve: SpeedCurve { (try? SpeedCurve(points: speedPoints ?? [.init(time:0,rate:mediaRate)])) ?? (try! SpeedCurve(points:[.init(time:0,rate:1)])) }
    var sourceDuration: Double { timeWarpCurve.distance(at:duration) }
    var hasTimeWarp: Bool { reversed == true || speedPoints != nil }
    var sourceTimeMapping: SourceTimeMapping { SourceTimeMapping(clip:self) }
    func sourceTime(at time: Double) -> Double { sourceTimeMapping.sourceTime(at:time) }
    var supportsParent: Bool { ![.audio,.transition,.adjustment].contains(kind) }
    func validateAdvanced(project: Project,index:ProjectValidationIndex?=nil) throws {
        func asset(_ id:UUID)->MediaAsset? {if let index{return index.assets[id]};return project.assets.first{$0.id==id}}
        func clip(_ id:UUID)->Clip? {if let index{return index.clips[id]};return project.clips.first{$0.id==id}}
        if let id=tracking?.assetID,asset(id)?.kind != .video {throw VMMError.message("追跡元の動画が見つかりません。")}
        if let id=audioReactive?.assetID,!(asset(id).map{[.audio,.video].contains($0.kind)} ?? false) {throw VMMError.message("音声連動の素材が見つかりません。")}
        func finite(_ value: Double, _ range: ClosedRange<Double>) -> Bool { value.isFinite && range.contains(value) }
        if let parentID {
            guard parentID != id, ![.transition,.adjustment].contains(kind), let parent = clip(parentID), parent.supportsParent else { throw VMMError.message("親アイテムが不正です。") }
            var seen: Set<UUID> = [id]; var next: UUID? = parentID
            while let current = next {
                guard seen.insert(current).inserted else { throw VMMError.message("親子関係が循環しています。") }
                guard seen.count <= 16 else { throw VMMError.message("親子関係は15段までにしてください。") }
                next = clip(current)?.parentID
            }
        }
        if let region = adjustmentRegion {
            guard finite(region.width,0.001...4), finite(region.height,0.001...4), finite(region.feather,0...200) else { throw VMMError.message("エフェクト範囲が不正です。") }
        }
        if let pitchSemitones {guard finite(pitchSemitones,-24...24) else {throw VMMError.message("音声ピッチが不正です。")}}
        if let playbackRate { guard finite(playbackRate,0.25...4) else { throw VMMError.message("再生速度が不正です。") } }
        if let speedPoints { _ = try SpeedCurve(points:speedPoints) }
        if let transform {
            guard finite(transform.scaleX,0.01...10), finite(transform.scaleY,0.01...10), finite(transform.skewX,-75...75), finite(transform.skewY,-75...75),
                  transform.corners.count == 4, transform.corners.allSatisfy({ finite($0.x,-2...3) && finite($0.y,-2...3) }) else { throw VMMError.message("変形の設定が不正です。") }
            // Reject crossing/degenerate quads, which have an undefined homography.
            if transform.perspective {
                let points = transform.corners
                let cross = (0..<4).map { i -> Double in
                    let a=points[i], b=points[(i+1)%4], c=points[(i+2)%4]
                    return (b.x-a.x)*(c.y-b.y)-(b.y-a.y)*(c.x-b.x)
                }
                guard cross.allSatisfy({ $0 > 0.0001 }) || cross.allSatisfy({ $0 < -0.0001 }) else { throw VMMError.message("透視変形の四隅は交差しない四角形にしてください。") }
            }
        }
        if let masks {
            guard masks.count <= 8, Set(masks.map(\.id)).count == masks.count else { throw VMMError.message("マスクは8個までです。") }
            for mask in masks {
                guard finite(mask.x,-2...3),finite(mask.y,-2...3),finite(mask.width,0.001...4),finite(mask.height,0.001...4),finite(mask.feather,0...200),
                      (3...32).contains(mask.points.count), mask.points.allSatisfy({finite($0.x,-2...3) && finite($0.y,-2...3)}),
                      mask.assetID.map({asset($0)?.kind == .image}) ?? true else { throw VMMError.message("マスクの設定が不正です。") }
            }
        }
        if let particles {
            guard (1...1000).contains(particles.count),finite(particles.lifetime,0.1...30),finite(particles.velocity,0...3),finite(particles.angle,-360...360),finite(particles.spread,0...360),finite(particles.gravity,-3...3),finite(particles.size,1...200),finite(particles.emitterWidth,0...3),finite(particles.emitterHeight,0...3),particles.endColor.count == 6,UInt32(particles.endColor,radix:16) != nil else { throw VMMError.message("パーティクルの設定が不正です。") }
        }
        if let equalizer {
            guard (1...10).contains(equalizer.bands.count),Set(equalizer.bands.map(\.id)).count == equalizer.bands.count,equalizer.bands.allSatisfy({finite($0.frequency,20...20000) && finite($0.gain,-24...24) && finite($0.bandwidth,0.1...5)}) else { throw VMMError.message("イコライザーの設定が不正です。") }
        }
    }
}
extension Project {
    func descendants(of id: UUID) -> Set<UUID> {
        var result: Set<UUID> = [], frontier: Set<UUID> = [id]
        while !frontier.isEmpty {
            let members=Set(clips.filter{frontier.contains($0.id)}.flatMap{$0.sceneMembers ?? []})
            let found = Set(clips.filter { $0.parentID.map(frontier.contains) == true }.map(\.id)).union(members).subtracting(result)
            result.formUnion(found); frontier = found
        }
        return result
    }
    func audioIsActive(_ clip: Clip, at time: Double) -> Bool {
        guard clip.audioDisabled != true,clip.active(at:time), !tracks[clip.track].muted else { return false }
        var parentID = clip.parentID, seen: Set<UUID> = []
        while let id = parentID, seen.insert(id).inserted {
            guard let parent = clips.first(where: { $0.id == id }), parent.active(at:time),parent.audioDisabled != true, !tracks[parent.track].muted else { return false }
            parentID = parent.parentID
        }
        return true
    }
    func audioHeadroom(for clip:Clip) -> Double {
        // Offline audio is amplified here, then AVAudioMix applies a <=1 gain.
        // Include every possible parent/animated gain so export matches realtime.
        var maximum=1.0
        var next:Clip?=clip,seen:Set<UUID>=[]
        while let current=next,seen.insert(current.id).inserted {
            let keyed=current.animation?.tracks.contains(where:{$0.property == .volume && $0.enabled && !$0.keys.isEmpty}) == true
            maximum *= keyed ? 2:current.volume
            next=current.parentID.flatMap{id in clips.first{$0.id==id}}
        }
        return max(1,min(128,min(2,maximum)*(masterVolume ?? 1)*(clip.normalizationGain ?? 1)))
    }
    func effectiveAudioVolume(_ clip: Clip, at time: Double) -> Double {
        guard audioIsActive(clip,at:time) else { return 0 }
        var value = clip.audioVolume(at:time), parentID = clip.parentID, seen: Set<UUID> = []
        while let id = parentID, seen.insert(id).inserted, let parent = clips.first(where: { $0.id == id }) {
            value *= parent.audioVolume(at:time); parentID = parent.parentID
        }
        if let remaining=clip.ducking,clip.kind != .speech {
            var activity=0.0
            for speech in clips where speech.kind == .speech && speech.assetID != nil && !speech.speechDirty && !tracks[speech.track].muted && speech.volume>0 {
                let probe=min(speech.end-0.001,max(speech.start,time))
                guard audioIsActive(speech,at:probe),speech.audioVolume(at:probe)>0 else {continue}
                let amount=min(1,max(0,(time-speech.start+0.15)/0.15))*min(1,max(0,(speech.end+0.25-time)/0.25))
                activity=max(activity,amount)
            }
            value *= 1-activity*(1-remaining)
        }
        return min(128,min(2,max(0,value))*(masterVolume ?? 1)*(clip.normalizationGain ?? 1))
    }
}

// Optional on Clip so existing projects retain their full-frame adjustment behavior.
enum AdjustmentShape: String, Codable, CaseIterable {
    case rectangle, ellipse, roundedRectangle
    var title: String { switch self { case .rectangle: return "四角"; case .ellipse: return "楕円"; case .roundedRectangle: return "角丸" } }
}
struct AdjustmentRegion: Codable, Equatable {
    var shape = AdjustmentShape.rectangle
    var width: Double = 0.3
    var height: Double = 0.3
    var feather: Double = 0
}
extension Clip {
    var availableAnimatedProperties: [AnimatedProperty] {
        if kind == .audio { return [.volume] }
        if kind == .adjustment { return [.x, .y, .regionWidth, .regionHeight, .rotation, .opacity] }
        return AnimatedProperty.allCases.filter { (!$0.isTemporal || temporalMotion != nil) && ![.regionWidth,.regionHeight].contains($0) && ($0 != .volume || [.speech,.video,.group].contains(kind)) }
    }
}
