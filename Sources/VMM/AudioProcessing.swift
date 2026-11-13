import AVFoundation

/// The same native EQ and time/pitch nodes drive realtime playback and offline export.
final class AudioGraph {
    let engine:AVAudioEngine,player=AVAudioPlayerNode(),eq:AVAudioUnitEQ,mixer=AVAudioMixerNode()
    private let ownsEngine:Bool
    private var stopped=false
    private(set) var pitch:AVAudioUnitTimePitch?
    private var varispeed:AVAudioUnitVarispeed?
    init(format:AVAudioFormat,clip:Clip,shared:PlaybackAudioEngine?=nil) {
        engine=shared?.engine ?? AVAudioEngine();ownsEngine=shared==nil
        engine.attach(mixer);engine.connect(mixer,to:shared?.input ?? engine.mainMixerNode,format:format)
        player.pan=Float(clip.pan ?? 0)
        let settings=clip.equalizer ?? Equalizer(enabled:false)
        eq=AVAudioUnitEQ(numberOfBands:settings.enabled ? settings.bands.count:0)
        for (i,band) in settings.bands.enumerated() where settings.enabled {
            eq.bands[i].filterType = .parametric;eq.bands[i].frequency=Float(min(band.frequency,format.sampleRate*0.45))
            eq.bands[i].gain=Float(band.gain);eq.bands[i].bandwidth=Float(band.bandwidth)
            eq.bands[i].bypass = !settings.enabled || !band.enabled
        }
        engine.attach(player);engine.attach(eq);engine.connect(player,to:eq,format:format)
        if clip.mediaRate==1 && (clip.pitchSemitones ?? 0)==0 {
            engine.connect(eq,to:mixer,format:format)
        } else if clip.preservePitch != false {
            let pitch=AVAudioUnitTimePitch();self.pitch=pitch;pitch.pitch=Float((clip.pitchSemitones ?? 0)*100)
            pitch.rate=Float(clip.mediaRate);engine.attach(pitch);engine.connect(eq,to:pitch,format:format);engine.connect(pitch,to:mixer,format:format)
        } else {
            let varispeed=AVAudioUnitVarispeed();self.varispeed=varispeed
            varispeed.rate=Float(clip.mediaRate);engine.attach(varispeed);engine.connect(eq,to:varispeed,format:format);if (clip.pitchSemitones ?? 0) != 0 {
                let pitch=AVAudioUnitTimePitch();self.pitch=pitch;pitch.pitch=Float((clip.pitchSemitones ?? 0)*100)
                engine.attach(pitch);pitch.rate=1;engine.connect(varispeed,to:pitch,format:format);engine.connect(pitch,to:mixer,format:format)
            } else {engine.connect(varispeed,to:mixer,format:format)}
        }
    }
    func stop() {
        guard !stopped else{return};stopped=true;player.stop()
        if ownsEngine {engine.stop()}
        for node in ([player,eq,mixer] as [AVAudioNode])+[pitch,varispeed].compactMap({$0}) where engine.attachedNodes.contains(node) {engine.detach(node)}
    }
}
final class ClipAudioPlayer {
    private let graph:AudioGraph
    private let file:AVAudioFile
    private let clip:Clip
    private let shared:PlaybackAudioEngine?
    var startTime:Double {clip.start}
    let meter=AudioMeterProbe()
    init(url:URL,clip:Clip,time:Double,volume:Double,shared:PlaybackAudioEngine?=nil,autoplay:Bool=true) throws {
        self.clip=clip;self.shared=shared
        file=try AVAudioFile(forReading:url)
        graph=AudioGraph(format:file.processingFormat,clip:clip,shared:shared)
        setVolume(volume)
        let probe=meter
        graph.mixer.installTap(onBus:0,bufferSize:1024,format:nil){buffer,_ in probe.accept(buffer)}
        if autoplay {try start(at:nil,timelineTime:time)}
    }
    func start(at hostTime:AVAudioTime?,timelineTime:Double)throws {
        let start=max(0,AVAudioFramePosition(clip.sourceTime(at:timelineTime)*file.processingFormat.sampleRate))
        let remaining=min(file.length-start,AVAudioFramePosition(max(0,clip.end-timelineTime)*clip.mediaRate*file.processingFormat.sampleRate))
        guard remaining>0 else {throw VMMError.message("音声素材の終端です。")}
        graph.player.scheduleSegment(file,startingFrame:start,frameCount:AVAudioFrameCount(min(remaining,Int64(UInt32.max))),at:nil)
        if let shared {try shared.start()}else{try graph.engine.start()}
        graph.player.play(at:hostTime)
    }
    func setVolume(_ value:Double) {
        // The mixer tap is before outputVolume; boosts are already applied by EQ.
        meter.setOutputAttenuation(value)
        graph.mixer.outputVolume=Float(min(1,max(0,value)))
        graph.eq.globalGain=Float(value>1 ? 20*log10(value):0)
    }
    func pause() {graph.stop()}
    deinit {graph.stop()}
}
enum AudioProcessor {
    /// A pre-rendered warp already has timeline duration and starts at zero.
    static func warpedPlaybackClip(_ clip: Clip) -> Clip {
        var copy = clip
        copy.sourceOffset = 0
        copy.playbackRate = 1
        copy.reversed = nil
        copy.speedPoints = nil
        return copy
    }
    static func decode(source:URL,destination:URL) async throws -> Bool {
        let asset=AVURLAsset(url:source)
        guard let track=try await asset.loadTracks(withMediaType:.audio).first else {return false}
        let reader=try AVAssetReader(asset:asset)
        let output=AVAssetReaderTrackOutput(track:track,outputSettings:[AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:48000,AVNumberOfChannelsKey:2,AVLinearPCMBitDepthKey:32,AVLinearPCMIsFloatKey:true,AVLinearPCMIsNonInterleaved:true])
        reader.add(output)
        let format=AVAudioFormat(standardFormatWithSampleRate:48000,channels:2)!
        var settings=format.settings;settings[AVLinearPCMIsNonInterleaved]=false
        var file:AVAudioFile?=try AVAudioFile(forWriting:destination,settings:settings)
        guard reader.startReading() else {throw reader.error ?? VMMError.message("音声のデコードを開始できません。")}
        do {
            var written:Int64=0
            func silence(_ frames:Int64) throws {
                var remaining=frames
                let blank=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:4096)!
                for channel in 0..<2 {memset(blank.floatChannelData![channel],0,4096*MemoryLayout<Float>.size)}
                while remaining>0 {
                    try Task.checkCancellation()
                    blank.frameLength=AVAudioFrameCount(min(4096,remaining));try file?.write(from:blank)
                    remaining-=Int64(blank.frameLength);written+=Int64(blank.frameLength)
                }
            }
            while let sample=output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                let count=CMSampleBufferGetNumSamples(sample)
                guard count>0 else {continue}
                let stamp=CMSampleBufferGetPresentationTimeStamp(sample).seconds
                let start=stamp.isFinite ? Int64((stamp*48000).rounded()) : written
                if start>written {try silence(start-written)}
                let skip=Int(min(Int64(count),max(0,written-start))),available=count-skip
                guard available>0 else {continue}
                let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(available))!;buffer.frameLength=AVAudioFrameCount(available)
                let status=CMSampleBufferCopyPCMDataIntoAudioBufferList(sample,at:Int32(skip),frameCount:Int32(available),into:buffer.mutableAudioBufferList)
                guard status==noErr else {throw VMMError.message("音声データの変換に失敗しました（\(status)）。")}
                try file?.write(from:buffer);written+=Int64(available)
            }
            let seconds=try await asset.load(.duration).seconds
            if seconds.isFinite,seconds>0 {let total=Int64((seconds*48000).rounded());if total>written {try silence(total-written)}}
            guard reader.status == .completed else {throw reader.error ?? VMMError.message("音声を読み込めませんでした。")}
            file=nil;return true
        } catch {reader.cancelReading();file=nil;try? FileManager.default.removeItem(at:destination);throw error}
    }
    static func process(decoded:URL,clip:Clip,destination:URL,gain:Double=1) throws -> Double {
        let input=try AVAudioFile(forReading:decoded),format=input.processingFormat
        let start=max(0,AVAudioFramePosition(clip.sourceOffset*format.sampleRate))
        let frames=min(input.length-start,AVAudioFramePosition(clip.duration*clip.mediaRate*format.sampleRate))
        guard frames>0 else {return 0}
        let graph=AudioGraph(format:format,clip:clip);defer {graph.stop()}
        graph.eq.globalGain=Float(20*log10(max(1,gain)))
        try graph.engine.enableManualRenderingMode(.offline,format:format,maximumFrameCount:4096)
        graph.player.scheduleSegment(input,startingFrame:start,frameCount:AVAudioFrameCount(min(frames,Int64(UInt32.max))),at:nil)
        try graph.engine.start();graph.player.play()
        var settings=format.settings;settings[AVLinearPCMIsNonInterleaved]=false
        var output:AVAudioFile?=try AVAudioFile(forWriting:destination,settings:settings)
        let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:4096)!
        let wanted=AVAudioFramePosition((Double(frames)/clip.mediaRate).rounded(.down))
        var stalled=0
        while graph.engine.manualRenderingSampleTime<wanted {
            try Task.checkCancellation()
            let before=graph.engine.manualRenderingSampleTime
            let count=AVAudioFrameCount(min(4096,wanted-before))
            switch try graph.engine.renderOffline(count,to:buffer) {
            case .success:try output?.write(from:buffer);stalled=0
            case .insufficientDataFromInputNode:
                // Offline time/pitch can request more lookahead at the file tail.
                try output?.write(from:buffer);stalled=0
            case .cannotDoInCurrentContext:
                stalled+=1;guard stalled<100 else {throw VMMError.message("音声加工が停止しました。")}
            case .error:throw VMMError.message("音声の速度・EQ加工に失敗しました。")
            @unknown default:throw VMMError.message("未対応の音声加工状態です。")
            }
            if graph.engine.manualRenderingSampleTime<=before {stalled+=1;guard stalled<100 else {throw VMMError.message("音声加工の時刻が進みません。")}}
        }
        output=nil;return Double(wanted)/format.sampleRate
    }
}
