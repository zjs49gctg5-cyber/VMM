import Foundation

extension Project {
    mutating func removeClips(_ ids:Set<UUID>) {
        clips.removeAll{ids.contains($0.id)}
        for i in clips.indices {clips[i].sceneMembers?.removeAll{ids.contains($0)}}
    }
    /// Copies/splits of a scene's internal item remain in every owning scene.
    mutating func registerSceneCopies(_ copies:[UUID:[UUID]]) {
        for i in clips.indices {
            // A copied owner has its own remapped children; do not attach them to the original owner.
            guard copies[clips[i].id]==nil else{continue}
            guard let members=clips[i].sceneMembers else{continue}
            clips[i].sceneMembers=members.flatMap{[$0]+(copies[$0] ?? [])}
        }
    }
    /// Keep original files in the editing session for Undo, omit obsolete hidden audio from packages.
    var packageSnapshot:Project {
        var result=self;let used=usedAssetIDs
        result.assets.removeAll{$0.generatedSpeech == true && !used.contains($0.id)}
        return result
    }
}
