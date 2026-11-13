import Foundation

enum SilenceCut {
    /// Cut matching clips together. Other clips and timeline markers do not move.
    static func apply(project: Project, ids: Set<UUID>, cuts: [SilenceCutRange]) throws -> (Project, Set<UUID>) {
        let targets = LinkedMedia.expanded(ids, in: project)
        let clips = project.clips.filter { targets.contains($0.id) }
        guard !clips.isEmpty, clips.count == targets.count, let base = clips.first, !cuts.isEmpty else { throw VMMError.message("無音カットの対象がありません。") }
        guard clips.allSatisfy({($0.audioFade?.fadeIn ?? 0)==0 && ($0.audioFade?.fadeOut ?? 0)==0}) else {
            throw VMMError.message("音声フェードのあるアイテムは無音カットできません。対象とリンク先のフェードを解除してください。")
        }
        let frame = 1 / Double(project.fps)
        guard clips.allSatisfy({ [.audio, .video].contains($0.kind) && !project.tracks[$0.track].locked && abs($0.start - base.start) <= 0.000001 && abs($0.duration - base.duration) <= 0.000001 && $0.parentID == nil && $0.sceneMembers == nil }) else {
            throw VMMError.message("対象の開始・長さを揃え、ロックと親子関係を解除してください。")
        }
        for clip in clips {
            try SourceEditing.checkSource(clip,in:project)
            guard !project.clips.contains(where: { other in other.parentID == clip.id || (other.sceneMembers ?? []).contains(clip.id) }) else { throw VMMError.message("親子・シーン制御のアイテムは無音カットできません。") }
        }
        let sorted = cuts.sorted { $0.start < $1.start }
        var end = 0.0, segments: [(Double, Double)] = []
        for cut in sorted {
            guard cut.start.isFinite, cut.end.isFinite, cut.start >= end, cut.end > cut.start, cut.end <= base.duration + 0.000001,
                  abs(cut.start / frame - (cut.start / frame).rounded()) < 0.00001,
                  abs(cut.end / frame - (cut.end / frame).rounded()) < 0.00001 else { throw VMMError.message("無音カットの範囲が不正です。") }
            if cut.start - end >= frame - 0.000001 { segments.append((end, cut.start)) }
            else if cut.start > end + 0.000001 { throw VMMError.message("残る区間が1フレーム未満です。") }
            end = cut.end
        }
        if base.duration - end >= frame - 0.000001 { segments.append((end, base.duration)) }
        else if base.duration > end + 0.000001 { throw VMMError.message("残る区間が1フレーム未満です。") }
        guard !segments.isEmpty else { throw VMMError.message("すべての音声を削除することはできません。") }
        var candidate = project, output: [Clip] = [], selected = Set<UUID>()
        var links: [UUID: [UUID]] = [:]
        for link in Set(clips.compactMap(\.linkID)) { links[link] = segments.map { _ in UUID() } }
        for clip in clips {
            var targetStart = clip.start
            for (index, segment) in segments.enumerated() {
                var part = SourceEditing.fragment(clip, start: clip.start + segment.0, end: clip.start + segment.1, newID: index != 0)
                part.start = targetStart
                try SourceEditing.checkSource(part,in:candidate)
                if let link = clip.linkID { part.linkID = links[link]?[index] }
                targetStart += part.duration; output.append(part); selected.insert(part.id)
            }
        }
        candidate.clips.removeAll { targets.contains($0.id) }
        candidate.clips.append(contentsOf: output)
        _ = try candidate.validated()
        return (candidate, selected)
    }
}

@MainActor extension EditorStore {
    func commitSilenceCut(snapshot: Project, directory snapshotDirectory:URL, ids: Set<UUID>, cuts: [SilenceCutRange]) throws {
        guard !busy, directory == snapshotDirectory, project == snapshot else { throw VMMError.message("プロジェクトが変更されました。再解析してください。") }
        let (candidate, newIDs) = try SilenceCut.apply(project:snapshot, ids:ids, cuts:cuts)
        pause(); checkpoint(); project = candidate
        selectedIDs = newIDs; selectedID = candidate.clips.first { newIDs.contains($0.id) }?.id
    }
}
