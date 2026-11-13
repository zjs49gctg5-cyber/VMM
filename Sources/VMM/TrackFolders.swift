import Foundation

/// Visible rows retain the project's compositing order, including when a folder's tracks are not contiguous.
enum TrackFolderRow:Equatable {
    case folder(UUID)
    case track(Int)
}

struct TrackFolderLayout {
    let rows:[TrackFolderRow]
    private let trackRows:[Int:Int]
    init(project:Project,collapsed:Set<UUID>) {
        var result:[TrackFolderRow]=[], previous:UUID?
        for (index,track) in project.tracks.enumerated() {
            if let id=track.folderID {
                if previous != id {result.append(.folder(id))}
                if !collapsed.contains(id) {result.append(.track(index))}
                previous=id
            } else {result.append(.track(index));previous=nil}
        }
        rows=result
        var lookup:[Int:Int]=[:]
        for (row,entry) in result.enumerated() {
            if case .track(let track)=entry {lookup[track]=row}
        }
        trackRows=lookup
    }
    func row(forTrack index:Int)->Int? {trackRows[index]}
    func track(atRow index:Int)->Int? {
        guard rows.indices.contains(index),case .track(let track)=rows[index] else{return nil};return track
    }
}

@MainActor extension EditorStore {
    /// Explicit selection, including through MCP, must never leave its items hidden.
    func revealSelectedTracks(_ ids:Set<UUID>) {
        guard !collapsedTrackFolders.isEmpty,!ids.isEmpty else{return}
        let folders=Set(project.clips.filter{ids.contains($0.id) && project.tracks.indices.contains($0.track)}.compactMap{project.tracks[$0.track].folderID})
        collapsedTrackFolders.subtract(folders)
    }
    func createTrackFolder(name:String,trackID:UUID)throws {
        let name=name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !busy,!name.isEmpty,name.count<=100,let index=project.tracks.firstIndex(where:{$0.id==trackID}) else{throw VMMError.message("レイヤーフォルダを作成できません。")}
        let folder=TrackFolder(name:name)
        var candidate=project;candidate.tracks[index].folder=folder
        _=try candidate.validated();checkpoint();project=candidate
    }
    func assignTrackFolder(_ trackID:UUID,folderID:UUID?)throws {
        guard !busy,let index=project.tracks.firstIndex(where:{$0.id==trackID}),folderID == nil || project.trackFolders.contains(where:{$0.id==folderID}) else{throw VMMError.message("レイヤーフォルダがありません。")}
        guard project.tracks[index].folderID != folderID else{return}
        checkpoint();project.tracks[index].folder=project.trackFolders.first{$0.id==folderID}
        if let folderID {collapsedTrackFolders.remove(folderID)}
    }
    func renameTrackFolder(_ id:UUID,name:String)throws {
        let name=name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !busy,!name.isEmpty,name.count<=100,let folder=project.trackFolders.first(where:{$0.id==id}) else{throw VMMError.message("レイヤーフォルダ名が不正です。")}
        guard folder.name != name else{return}
        checkpoint();for index in project.tracks.indices where project.tracks[index].folderID==id {project.tracks[index].folder?.name=name}
    }
    func deleteTrackFolder(_ id:UUID)throws {
        guard !busy,project.trackFolders.contains(where:{$0.id==id}) else{throw VMMError.message("レイヤーフォルダがありません。")}
        checkpoint();for index in project.tracks.indices where project.tracks[index].folderID==id {project.tracks[index].folder=nil}
        collapsedTrackFolders.remove(id)
    }
    func toggleTrackFolder(_ id:UUID) {
        guard !busy,project.trackFolders.contains(where:{$0.id==id}) else{return}
        if collapsedTrackFolders.remove(id) == nil {
            collapsedTrackFolders.insert(id)
            let hidden=Set(project.clips.filter{project.tracks[$0.track].folderID==id}.map(\.id))
            selectedIDs.subtract(hidden)
            if let selectedID,hidden.contains(selectedID) {self.selectedID=selectedIDs.first}
            let layout=TrackFolderLayout(project:project,collapsed:collapsedTrackFolders)
            if layout.row(forTrack:selectedTrack)==nil,let first=layout.rows.compactMap({if case .track(let i)=$0{return i};return nil}).first {selectedTrack=first}
        }
    }
}
