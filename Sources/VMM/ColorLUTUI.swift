import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor extension EditorStore {
    func setClipLUT(_ cube:ColorLUT,clipID:UUID,effectID:UUID)throws {
        guard !busy,let i=project.clips.firstIndex(where:{$0.id==clipID}),!project.tracks[project.clips[i].track].locked,let e=project.clips[i].effects?.firstIndex(where:{$0.id==effectID && $0.kind == .colorLUT}) else{throw VMMError.message("LUTの対象を編集できません。")}
        var candidate=project;candidate.clips[i].effects?[e].lut=cube;_=try candidate.validated();pause();checkpoint();project=candidate
    }
    func setTrackLUT(_ cube:ColorLUT,trackID:UUID,effectID:UUID)throws {
        guard !busy,let i=project.tracks.firstIndex(where:{$0.id==trackID}),!project.tracks[i].locked,let e=project.tracks[i].effects?.firstIndex(where:{$0.id==effectID && $0.kind == .colorLUT}) else{throw VMMError.message("LUTの対象を編集できません。")}
        var candidate=project;candidate.tracks[i].effects?[e].lut=cube;_=try candidate.validated();pause();checkpoint();project=candidate
    }
}
struct ColorLUTPicker:View {
    @ObservedObject var store:EditorStore
    let cube:ColorLUT?
    let apply:(ColorLUT)throws->Void
    var body:some View {
        HStack {
            Button(L("LUTを読み込む…")) {
                let panel=NSOpenPanel();panel.allowedContentTypes=[UTType(filenameExtension:"cube") ?? .plainText];panel.allowsMultipleSelection=false
                guard panel.runModal() == .OK,let url=panel.url else{return}
                store.reportEditing{try apply(ColorLUT.load(url))}
            }
            Text(cube.map{"\($0.name) (\($0.size)³)"} ?? L("LUT未選択")).lineLimit(1).truncationMode(.middle).foregroundColor(.secondary)
        }
    }
}
