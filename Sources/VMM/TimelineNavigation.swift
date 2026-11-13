import SwiftUI

struct TimelineMarker:Codable,Equatable,Identifiable {
    var id=UUID()
    var time:Double
    var name:String
}
struct TimelineRange:Codable,Equatable {
    var start:Double
    var end:Double
    var loop=false
}
@MainActor extension EditorStore {
    func addMarker(at time:Double?=nil,name:String?=nil) {
        guard !busy,(project.markers ?? []).count<2000,(time ?? playhead).isFinite else{return}
        let title=name?.trimmingCharacters(in:.whitespacesAndNewlines)
        guard title == nil || (!title!.isEmpty && title!.count<=200) else{return}
        checkpoint()
        let t=(max(0,min(86400,time ?? playhead))*Double(project.fps)).rounded()/Double(project.fps)
        var markers=project.markers ?? [];let marker=TimelineMarker(time:t,name:title ?? "\(L("マーカー")) \(markers.count+1)");markers.append(marker);project.markers=markers.sorted{$0.time<$1.time};selectedMarkerID=marker.id
    }
    func updateMarker(_ id:UUID,time:Double,name:String)throws {
        let title=name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !busy,let index=project.markers?.firstIndex(where:{$0.id==id}),time.isFinite,(0...86400).contains(time),!title.isEmpty,title.count<=200 else{throw VMMError.message("マーカーの名前・時刻を確認してください。")}
        let changed=TimelineMarker(id:id,time:(time*Double(project.fps)).rounded()/Double(project.fps),name:title)
        guard project.markers?[index] != changed else{return}
        checkpoint();project.markers?[index]=changed;project.markers?.sort{$0.time == $1.time ? $0.id.uuidString<$1.id.uuidString:$0.time<$1.time}
    }
    func seekMarker(forward:Bool) {
        let frame=0.5/Double(project.fps),markers=(project.markers ?? []).sorted{$0.time<$1.time}
        if let marker=forward ? markers.first(where:{$0.time>playhead+frame}):markers.last(where:{$0.time<playhead-frame}) {seek(marker.time)}
    }
    func removeMarker(_ id:UUID){guard !busy,project.markers?.contains(where:{$0.id==id}) == true else{return};checkpoint();project.markers?.removeAll{$0.id==id};if selectedMarkerID==id{selectedMarkerID=nil}}
    func setRange(inPoint:Bool,at time:Double?=nil) {
        guard !busy,project.duration>0 else{return};pause();checkpoint()
        let frame=1/Double(project.fps),t=(max(0,min(project.duration,time ?? playhead))*Double(project.fps)).rounded()/Double(project.fps)
        var range=project.timelineRange ?? TimelineRange(start:0,end:project.duration)
        if inPoint {range.start=min(t,max(0,project.duration-frame));range.end=max(range.end,range.start+frame)}
        else {range.end=max(frame,t);range.start=min(range.start,range.end-frame)}
        project.timelineRange=range
    }
    func advancePlayback(to proposed:Double,clockTime:Double=ProcessInfo.processInfo.systemUptime) {
        if let range=animationPlaybackRange,!range.loop,proposed>=range.end {playhead=range.end;pause();return}
        if let range=animationPlaybackRange ?? project.timelineRange,range.loop,min(range.end,project.duration)>range.start {
            let end=min(range.end,project.duration),length=end-range.start
            if proposed>=end || proposed<range.start {
                playhead=range.start+max(0,proposed-range.start).truncatingRemainder(dividingBy:length)
                playbackOffset=playhead;playbackStart=clockTime
                players.values.forEach{$0.pause()};players.removeAll()
                audioTasks.values.forEach{$0.cancel()};audioTasks.removeAll();audioTokens.removeAll()
            } else {playhead=proposed}
        } else {
            playhead=min(proposed,project.duration)
            if proposed>=project.duration {pause();return}
        }
        updateAudio()
    }
}
struct TimelineNavigationControls:View {
    @ObservedObject var store:EditorStore
    var body:some View {
        HStack(spacing:8) {
            Button{store.seekMarker(forward:false)} label:{Image(systemName:"backward.end")}.help(L("前のマーカー"))
            Button{store.addMarker()} label:{Image(systemName:"flag.badge.plus")}.help(L("現在位置に追加")+" ("+ShortcutMap.key(.marker,settings:store.settings)+")")
            Button{store.seekMarker(forward:true)} label:{Image(systemName:"forward.end")}.help(L("次のマーカー"))
            Button(L("マーカー一覧")){store.markerWindow.show()}
            Menu {
                Button(L("インを設定")){store.setRange(inPoint:true)}
                Button(L("アウトを設定")){store.setRange(inPoint:false)}
                if let range=store.project.timelineRange {
                    Text("IN \(timecode(range.start,fps:store.project.fps)) / OUT \(timecode(range.end,fps:store.project.fps))")
                    Toggle(L("範囲ループ"),isOn:Binding(get:{store.project.timelineRange?.loop ?? false},set:{v in store.pause();store.checkpoint();store.project.timelineRange?.loop=v}))
                    Button(L("範囲を解除")){store.pause();store.checkpoint();store.project.timelineRange=nil}
                }
            } label:{Text(L("範囲"))}
        }.disabled(store.busy)
    }
}
@MainActor final class MarkerWindowController {
    weak var store:EditorStore?
    private var window:NSWindow?
    init(store:EditorStore){self.store=store}
    func show(_ id:UUID?=nil) {
        guard let store else{return}
        if let id {store.selectedMarkerID=id}
        if let window {window.title="VMM — \(L("マーカー一覧"))";window.makeKeyAndOrderFront(nil);return}
        let panel=NSWindow(contentRect:NSRect(x:0,y:0,width:780,height:480),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        panel.title="VMM — \(L("マーカー一覧"))";panel.minSize=NSSize(width:660,height:420);panel.isReleasedWhenClosed=false;panel.tabbingMode = .disallowed
        panel.contentView=NSHostingView(rootView:MarkerListView(store:store).vmmAppearance(store.settings))
        panel.center();panel.makeKeyAndOrderFront(nil);window=panel
    }
}
struct MarkerListView:View {
    @ObservedObject var store:EditorStore
    var body:some View {VStack(alignment:.leading,spacing:14) {
        HStack {Text(L("マーカー一覧")).bold();Spacer();Button(L("現在位置に追加")){store.addMarker()}}
        HSplitView {
            List(selection:$store.selectedMarkerID){ForEach(store.project.markers ?? []){marker in HStack {Text(timecode(marker.time,fps:store.project.fps)).monospacedDigit();Text(marker.name);Spacer();Button(L("移動")){store.seek(marker.time)}}.tag(marker.id)}}.frame(minWidth:260)
            if let marker=store.project.markers?.first(where:{$0.id==store.selectedMarkerID}) {MarkerDetailView(store:store,marker:marker).id(marker.id).frame(minWidth:270,maxWidth:.infinity)}
            else {Text(L("マーカーを選択して名前と時刻を編集します。")).foregroundColor(.secondary).frame(maxWidth:.infinity,maxHeight:.infinity)}
        }
        Text(L("マーカー行をドラッグして時刻を変更、ダブルクリックで編集します。")).foregroundColor(.secondary)
    }.padding(20).disabled(store.busy).alert(L("確認してください"),isPresented:Binding(get:{store.error != nil},set:{if !$0{store.error=nil}})){Button("OK"){store.error=nil}} message:{Text(L(store.error ?? ""))}}
}
struct MarkerDetailView:View {
    @ObservedObject var store:EditorStore
    let marker:TimelineMarker
    @State private var name:String
    @State private var time:Double
    init(store:EditorStore,marker:TimelineMarker){self.store=store;self.marker=marker;_name=State(initialValue:marker.name);_time=State(initialValue:marker.time)}
    var body:some View {VStack(alignment:.leading,spacing:16) {
        TextField(L("マーカー名"),text:$name).textFieldStyle(.roundedBorder)
        NumberInput(title:"時刻",value:$time,range:0...86400,unit:"秒")
        Text(timecode(time,fps:store.project.fps)).monospacedDigit().foregroundColor(.secondary)
        Button(L("再生位置の時刻を使う")){time=store.playhead}
        HStack {Button(L("適用")){store.reportEditing{try store.updateMarker(marker.id,time:time,name:name)}}.disabled(name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty);Button(L("移動")){store.seek(marker.time)};Button(L("削除")){store.removeMarker(marker.id)}}
        Spacer()
    }.padding(16).onChange(of:marker){value in name=value.name;time=value.time}}
}
