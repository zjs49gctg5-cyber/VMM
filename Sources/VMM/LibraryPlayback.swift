import SwiftUI
import AVKit

final class LibraryPlayback:ObservableObject {
    @Published private(set) var asset:MediaAsset?
    @Published private(set) var player:AVPlayer?
    @Published private(set) var playing=false
    @Published private(set) var position=0.0
    @Published private(set) var error:String?
    @Published private(set) var auditionRange:ClosedRange<Double>?
    @Published var sourceIn=0.0
    @Published var sourceOut=0.0
    var start:Double {auditionRange?.lowerBound ?? 0}
    var end:Double {auditionRange?.upperBound ?? asset?.duration ?? 0}
    private var session=UUID()
    private var timeObserver:Any?
    private var rateObserver:NSKeyValueObservation?
    private var statusObserver:NSKeyValueObservation?
    private var endObserver:NSObjectProtocol?
    func open(_ asset:MediaAsset,directory:URL,range:ClosedRange<Double>?=nil) {
        stop()
        guard [.video,.audio].contains(asset.kind) else{return}
        let url=directory.appendingPathComponent("Media").appendingPathComponent(asset.file)
        guard FileManager.default.fileExists(atPath:url.path) else {error="素材ファイルが見つかりません。";return}
        self.asset=asset
        sourceIn=0;sourceOut=asset.duration
        if let range {
            let lower=max(0,range.lowerBound),upper=min(asset.duration,range.upperBound)
            guard lower.isFinite,upper.isFinite,upper>lower else {self.asset=nil;error="音素の試聴範囲が不正です。";return}
            auditionRange=lower...upper;position=lower
        }
        let token=session
        let item=AVPlayerItem(url:url),player=AVPlayer(playerItem:item);self.player=player
        if let range=auditionRange {item.forwardPlaybackEndTime=CMTime(seconds:range.upperBound,preferredTimescale:48000)}
        rateObserver=player.observe(\.rate,options:[.new]) {[weak self] p,_ in
            let active=p.rate != 0
            Task {@MainActor in if self?.session==token {self?.playing=active}}
        }
        statusObserver=item.observe(\.status,options:[.new]) {[weak self] item,_ in
            if item.status == .failed {let message=item.error?.localizedDescription ?? "素材を再生できません。";Task {@MainActor in if self?.session==token {self?.error=message;self?.player?.pause()}}}
        }
        timeObserver=player.addPeriodicTimeObserver(forInterval:CMTime(seconds:0.1,preferredTimescale:600),queue:.main) {[weak self] time in
            Task {@MainActor in guard let self,self.session==token else{return};if time.seconds.isFinite {self.position=max(self.start,min(self.end,time.seconds))}}
        }
        endObserver=NotificationCenter.default.addObserver(forName:.AVPlayerItemDidPlayToEndTime,object:item,queue:.main) {[weak self] _ in Task {@MainActor in if self?.session==token {self?.playing=false;self?.position=self?.end ?? 0}}}
        if let range=auditionRange {
            player.seek(to:CMTime(seconds:range.lowerBound,preferredTimescale:48000),toleranceBefore:.zero,toleranceAfter:.zero) {[weak self] completed in
                Task {@MainActor in if completed,self?.session==token {self?.player?.play()}}
            }
        } else {player.play()}
    }
    func toggle() {
        guard let player,asset != nil else{return}
        if playing {player.pause()} else {if position>=end-0.005 {seek(start)};player.play()}
    }
    func seek(_ seconds:Double) {
        guard seconds.isFinite,asset != nil else{return}
        position=max(start,min(end,seconds))
        player?.seek(to:CMTime(seconds:position,preferredTimescale:48000),toleranceBefore:.zero,toleranceAfter:.zero)
    }
    func stop() {
        session=UUID()
        player?.pause()
        if let observer=timeObserver {player?.removeTimeObserver(observer)}
        if let observer=endObserver {NotificationCenter.default.removeObserver(observer)}
        timeObserver=nil;endObserver=nil;rateObserver=nil;statusObserver=nil
        player=nil;asset=nil;auditionRange=nil;position=0;playing=false;error=nil
    }
    deinit {
        if let observer=timeObserver {player?.removeTimeObserver(observer)}
        if let observer=endObserver {NotificationCenter.default.removeObserver(observer)}
        player?.pause()
    }
}
struct LibraryPlaybackPanel:View {
    @ObservedObject var playback:LibraryPlayback
    @ObservedObject var store:EditorStore
    var body:some View {
        if let asset=playback.asset,let player=playback.player {
            VStack(alignment:.leading,spacing:8) {
                HStack {Text(asset.name).lineLimit(1);Spacer();Button {playback.stop()} label:{UIIcon(systemName:"xmark")}.buttonStyle(.borderless).accessibilityLabel(L("素材の再生を閉じる"))}
                if asset.kind == .video {LibraryVideoView(player:player).frame(height:180)}
                HStack {
                    Button {playback.toggle()} label:{UIIcon(systemName:playback.playing ? "pause.fill":"play.fill")}.buttonStyle(.borderless).accessibilityLabel(playback.playing ? "素材を一時停止":"素材を再生")
                    Slider(value:Binding(get:{max(playback.start,min(playback.end,playback.position))},set:{playback.seek($0)}),in:playback.start...max(playback.start+0.001,playback.end)).accessibilityLabel(L("素材の再生位置"))
                    Text(String(format:"%.2f / %.2f秒",max(0,playback.position-playback.start),playback.end-playback.start)).monospacedDigit()
                }
                if playback.auditionRange==nil {
                    HStack {
                        Button(L("In設定")){playback.sourceIn=min(playback.position,playback.sourceOut)}
                        Button(L("Out設定")){playback.sourceOut=max(playback.position,playback.sourceIn)}
                        Button(L("全範囲")){playback.sourceIn=0;playback.sourceOut=asset.duration}
                    }
                    NumberInput(title:"素材In",value:$playback.sourceIn,range:0...asset.duration,unit:"秒",fractionalDigits:asset.kind == .audio ? 6:3)
                    NumberInput(title:"素材Out",value:$playback.sourceOut,range:0...asset.duration,unit:"秒",fractionalDigits:asset.kind == .audio ? 6:3)
                    HStack {ForEach(SourcePlacement.allCases,id:\.self){mode in
                        Button(L(mode.title)){store.reportEditing{try store.placeSource(asset.id,sourceIn:playback.sourceIn,sourceOut:playback.sourceOut,mode:mode)}}
                    }}.disabled(store.busy || playback.sourceOut<=playback.sourceIn)
                    Text(L("挿入は全レイヤーの後続を移動、上書きは選択レイヤーの範囲を置換します。")).foregroundColor(.secondary)
                }
            }.padding(8).background(Color.black.opacity(0.2)).cornerRadius(6)
        }
        if let error=playback.error {Text(error).foregroundColor(.red)}
    }
}

struct LibraryVideoView:NSViewRepresentable {
    let player:AVPlayer
    func makeNSView(context:Context)->AVPlayerView {
        let view=AVPlayerView();view.controlsStyle = .none;view.videoGravity = .resizeAspect;view.player=player;return view
    }
    func updateNSView(_ view:AVPlayerView,context:Context) {if view.player !== player {view.player=player}}
    static func dismantleNSView(_ view:AVPlayerView,coordinator:()) {view.player=nil}
}
