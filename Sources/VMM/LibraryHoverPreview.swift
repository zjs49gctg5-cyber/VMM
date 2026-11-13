import SwiftUI
import AVKit

/// One muted player per browser. Delayed entry avoids loading every video while scanning a list.
@MainActor final class LibraryHoverPreview:ObservableObject {
    @Published private(set) var assetID:UUID?
    @Published private(set) var player:AVPlayer?
    private var hoveredID:UUID?
    private var session=UUID()
    private var task:Task<Void,Never>?
    private var endObserver:NSObjectProtocol?
    private var statusObserver:NSKeyValueObservation?
    func enter(_ asset:MediaAsset,directory:URL,seconds:Double=3,delay:Double=0.35) {
        guard asset.kind == .video,seconds.isFinite,delay.isFinite,hoveredID != asset.id else{return}
        stop();hoveredID=asset.id
        let token=session,url=directory.appendingPathComponent("Media").appendingPathComponent(asset.file)
        task=Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds:UInt64(max(0,delay)*1_000_000_000))
                guard let self,self.session==token,!Task.isCancelled,FileManager.default.fileExists(atPath:url.path) else{return}
                let item=AVPlayerItem(url:url)
                item.forwardPlaybackEndTime=CMTime(seconds:max(0.01,min(asset.duration,max(1,min(10,seconds)))),preferredTimescale:600)
                item.preferredForwardBufferDuration=1
                let player=AVPlayer(playerItem:item);player.isMuted=true
                self.assetID=asset.id;self.player=player
                self.endObserver=NotificationCenter.default.addObserver(forName:.AVPlayerItemDidPlayToEndTime,object:item,queue:.main){[weak self] _ in
                    Task{@MainActor in if self?.session==token {self?.finish()}}
                }
                self.statusObserver=item.observe(\.status,options:[.new]){[weak self] item,_ in
                    if item.status == .failed {Task{@MainActor in if self?.session==token {self?.finish()}}}
                }
                player.play()
                // Also release a stalled decoder instead of retaining it indefinitely.
                try await Task.sleep(nanoseconds:UInt64(max(1,min(10,seconds))+5)*1_000_000_000)
                if self.session==token {self.finish()}
            } catch { }
        }
    }
    func exit(_ id:UUID) {if hoveredID==id {stop()}}
    private func finish() {
        let id=hoveredID;stop();hoveredID=id // No automatic restart until the pointer leaves.
    }
    func stop() {
        session=UUID();task?.cancel();task=nil
        player?.pause();player?.replaceCurrentItem(with:nil)
        if let endObserver {NotificationCenter.default.removeObserver(endObserver)}
        endObserver=nil;statusObserver=nil;player=nil;assetID=nil;hoveredID=nil
    }
    deinit {task?.cancel();if let endObserver{NotificationCenter.default.removeObserver(endObserver)}}
}

struct LibraryDisplaySettings:View {
    @ObservedObject var store:EditorStore
    var body:some View {VStack(alignment:.leading,spacing:16) {
        Toggle(L("素材ライブラリのサムネイルを表示"),isOn:Binding(get:{store.settings.libraryThumbnails ?? true},set:{store.setLibraryThumbnails($0)}))
        Toggle(L("動画をホバーでプレビュー"),isOn:Binding(get:{store.settings.libraryHoverPreview ?? true},set:{store.settings.libraryHoverPreview=$0;store.persistSettings()}))
        NumberInput(title:"ホバー再生の長さ",value:Binding(get:{store.settings.libraryHoverSeconds ?? 3},set:{store.settings.libraryHoverSeconds=$0;store.persistSettings()}),range:1...10,unit:"秒").disabled(store.settings.libraryHoverPreview == false)
        Text(L("動画の上にポインターを置くと、音声なしで数秒再生します。離れると停止します。")).foregroundColor(.secondary)
        Button(L("サムネイルを再読み込み")){TimelineMediaCache.shared.clear()}
    }}
}
@MainActor extension EditorStore {
    func setLibraryThumbnails(_ enabled:Bool) {
        settings.libraryThumbnails=enabled
        if enabled {TimelineMediaCache.shared.clear()}
        persistSettings()
    }
}
