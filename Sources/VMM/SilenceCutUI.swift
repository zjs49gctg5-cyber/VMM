import AppKit
import SwiftUI

@MainActor final class SilenceCutWindowController {
    weak var store: EditorStore?
    private var window: NSWindow?
    init(store: EditorStore) { self.store = store }
    func show(_ id: UUID) {
        guard let store else { return }
        window?.close()
        let panel = NSWindow(contentRect: NSRect(x:0,y:0,width:640,height:540), styleMask:[.titled,.closable,.resizable], backing:.buffered, defer:false)
        panel.title = "VMM — \(L("無音カット"))"; panel.minSize = NSSize(width:520,height:420); panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: SilenceCutView(store:store,clipID:id).vmmAppearance(store.settings))
        panel.center(); panel.makeKeyAndOrderFront(nil); window = panel
    }
}

struct SilenceCutView: View {
    @ObservedObject var store: EditorStore
    let clipID: UUID
    @State private var threshold = -40.0
    @State private var minimum = 0.5
    @State private var margin = 0.1
    @State private var ranges: [SilenceCutRange] = []
    @State private var chosen: Set<Double> = []
    @State private var snapshot: Project?
    @State private var snapshotDirectory:URL?
    @State private var ids: Set<UUID> = []
    @State private var analyzing = false
    @State private var message = ""
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text(L("無音カット")).font(.headline)
            Text(L("選択した音声・映像とリンク先を同時にカットします。後続のアイテムやマーカーは移動しません。" )).foregroundColor(.secondary)
            Text(L("速度・EQ・ピッチ処理を使う場合、切断点付近の音が変わる場合があります。" )).foregroundColor(.secondary)
            HStack {
                NumberInput(title:"閾値",value:$threshold,range: -90...0,unit:"dB")
                NumberInput(title:"最短無音",value:$minimum,range:0.05...60,unit:"秒")
                NumberInput(title:"前後の余白",value:$margin,range:0...5,unit:"秒")
            }.disabled(analyzing)
            HStack { Button(L("無音を解析")){ analyze() }.disabled(analyzing || store.busy)
                if analyzing { ProgressView().controlSize(.small) }; Text(L(message)).foregroundColor(.secondary); Spacer() }
            List(ranges) { item in
                Toggle(isOn: Binding(get:{chosen.contains(item.start)},set:{if $0 {chosen.insert(item.start)} else {chosen.remove(item.start)}})) {
                    Text(String(format:"%.2f 〜 %.2f 秒",item.start,item.end)).monospacedDigit()
                }
            }
            HStack { Spacer(); Button(L("選択した区間をカット")){ apply() }.disabled(analyzing || chosen.isEmpty || store.busy) }
        }.padding(18).onChange(of:threshold){_ in resetResults()}.onChange(of:minimum){_ in resetResults()}.onChange(of:margin){_ in resetResults()}
    }
    private func resetResults() { ranges=[];chosen=[];snapshot=nil;snapshotDirectory=nil;message="" }
    private func analyze() {
        guard let clip=store.project.clips.first(where:{$0.id==clipID}), let asset=store.project.asset(for:clip), [.audio,.video].contains(clip.kind) else {message="音声または動画を選択してください。";return}
        let folder=store.directory, project=store.project, selection=store.selection.contains(clipID) ? store.selection:[clipID]
        let url=folder.appendingPathComponent("Media").appendingPathComponent(asset.file)
        let fps=project.fps, db=threshold, seconds=minimum, pad=margin
        analyzing=true;ranges=[];chosen=[];snapshot=nil;snapshotDirectory=nil;message="解析中…"
        Task {
            do {
                let result=try await Task.detached(priority:.userInitiated){try await SilenceAnalysis.analyze(url:url,clip:clip,fps:fps,thresholdDB:db,minimum:seconds,margin:pad)}.value
                guard store.directory==folder,store.project==project else {message="解析中にプロジェクトが変更されました。再解析してください。";analyzing=false;return}
                ranges=result;chosen=Set(result.map(\.start));snapshot=project;snapshotDirectory=folder;ids=selection;message=result.isEmpty ? "対象となる無音はありません。":"区間を確認してください。"
            } catch {message=error.localizedDescription}
            analyzing=false
        }
    }
    private func apply() {
        guard let snapshot,let snapshotDirectory,store.directory==snapshotDirectory,store.project==snapshot else {message="プロジェクトが変更されました。再解析してください。";return}
        do {
            try store.commitSilenceCut(snapshot:snapshot,directory:snapshotDirectory,ids:ids,cuts:ranges.filter{chosen.contains($0.start)})
            self.snapshot=nil;self.snapshotDirectory=nil;ranges=[];chosen=[];message="無音をカットしました。"
        } catch {message=error.localizedDescription}
    }
}
