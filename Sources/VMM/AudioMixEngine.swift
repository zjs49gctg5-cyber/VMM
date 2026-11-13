import AVFoundation
import AudioToolbox

struct MasterDynamics:Codable,Equatable {
    var limiterEnabled=false
    var ceilingDB:Double = -1
    var compressorEnabled=false
    var thresholdDB:Double = -18
    var headroomDB:Double=5
    var active:Bool {limiterEnabled || compressorEnabled}
    func validate()throws {
        guard ceilingDB.isFinite,(-12...0).contains(ceilingDB),thresholdDB.isFinite,(-60...0).contains(thresholdDB),headroomDB.isFinite,(0.1...40).contains(headroomDB) else{throw VMMError.message("マスター音声処理の設定が不正です。")}
    }
}
/// One hardware engine for a playback session; each clip only owns its nodes.
final class PlaybackAudioEngine {
    let engine=AVAudioEngine(),input=AVAudioMixerNode(),meter=AudioMeterProbe()
    private var effects:[AVAudioNode]=[]
    private let settings:MasterDynamics
    init(settings:MasterDynamics?=nil) {
        self.settings=settings ?? MasterDynamics()
        engine.attach(input)
        var tail:AVAudioNode=input
        func effect(_ subtype:OSType)->AVAudioUnitEffect {
            let node=AVAudioUnitEffect(audioComponentDescription:AudioComponentDescription(componentType:kAudioUnitType_Effect,componentSubType:subtype,componentManufacturer:kAudioUnitManufacturer_Apple,componentFlags:0,componentFlagsMask:0))
            engine.attach(node);engine.connect(tail,to:node,format:Self.format);effects.append(node);tail=node;return node
        }
        if self.settings.compressorEnabled {
            let unit=effect(kAudioUnitSubType_DynamicsProcessor)
            Self.parameter(unit,kDynamicsProcessorParam_Threshold,self.settings.thresholdDB)
            Self.parameter(unit,kDynamicsProcessorParam_HeadRoom,self.settings.headroomDB)
            Self.parameter(unit,kDynamicsProcessorParam_ExpansionRatio,1)
            Self.parameter(unit,kDynamicsProcessorParam_AttackTime,0.01)
            Self.parameter(unit,kDynamicsProcessorParam_ReleaseTime,0.1)
        }
        if self.settings.limiterEnabled {
            let limiter=effect(kAudioUnitSubType_PeakLimiter)
            Self.parameter(limiter,kLimiterParam_PreGain,-self.settings.ceilingDB)
            Self.parameter(limiter,kLimiterParam_AttackTime,0.001)
            Self.parameter(limiter,kLimiterParam_DecayTime,0.024)
            let ceiling=AVAudioMixerNode();engine.attach(ceiling);engine.connect(tail,to:ceiling,format:Self.format)
            ceiling.outputVolume=Float(pow(10,self.settings.ceilingDB/20));effects.append(ceiling);tail=ceiling
        }
        engine.connect(tail,to:engine.mainMixerNode,format:Self.format)
    }
    static var format:AVAudioFormat {AVAudioFormat(standardFormatWithSampleRate:48000,channels:2)!}
    private static func parameter(_ unit:AVAudioUnitEffect,_ id:AudioUnitParameterID,_ value:Double){AudioUnitSetParameter(unit.audioUnit,id,kAudioUnitScope_Global,0,Float(value),0)}
    func start()throws {
        guard !engine.isRunning else{return}
        let probe=meter
        engine.mainMixerNode.installTap(onBus:0,bufferSize:1024,format:nil){buffer,_ in probe.accept(buffer)}
        try engine.start()
    }
    func stop(){engine.stop()}
    deinit {engine.stop()}
    /// Same native master units offline; preserve float headroom until delivery encoding.
    static func process(_ source:URL,to destination:URL,settings:MasterDynamics)throws {
        let file=try AVAudioFile(forReading:source),graph=PlaybackAudioEngine(settings:settings),player=AVAudioPlayerNode()
        let engine=graph.engine;engine.attach(player);engine.connect(player,to:graph.input,format:file.processingFormat)
        defer{graph.stop()}
        try engine.enableManualRenderingMode(.offline,format:Self.format,maximumFrameCount:4096)
        player.scheduleFile(file,at:nil);try engine.start();player.play()
        var outputSettings=Self.format.settings;outputSettings[AVLinearPCMIsNonInterleaved]=false
        var output:AVAudioFile?=try AVAudioFile(forWriting:destination,settings:outputSettings)
        let buffer=AVAudioPCMBuffer(pcmFormat:Self.format,frameCapacity:4096)!
        // The native limiter has lookahead. Flush its tail and trim the reported latency
        // so the delivered waveform retains its original sample positions and duration.
        let latency=Int64((graph.effects.compactMap{($0 as? AVAudioUnit)?.auAudioUnit.latency}.reduce(0,+)*48000).rounded())
        var stalls=0,written:Int64=0
        let wanted=file.length+latency
        while engine.manualRenderingSampleTime<wanted {
            try Task.checkCancellation()
            let count=AVAudioFrameCount(min(4096,wanted-engine.manualRenderingSampleTime)),before=engine.manualRenderingSampleTime
            let status=try engine.renderOffline(count,to:buffer)
            if status == .success || status == .insufficientDataFromInputNode {
                let skip=Int(min(Int64(buffer.frameLength),max(0,latency-before)))
                let frames=Int(min(Int64(Int(buffer.frameLength)-skip),max(0,file.length-written)))
                if frames>0 {
                    for c in 0..<2 {memmove(buffer.floatChannelData![c],buffer.floatChannelData![c]+skip,frames*MemoryLayout<Float>.size)}
                    buffer.frameLength=AVAudioFrameCount(frames);try output?.write(from:buffer);written+=Int64(frames)
                }
            }
            else if status == .error {throw VMMError.message("マスター音声処理に失敗しました。")}
            stalls=engine.manualRenderingSampleTime>before ? 0:stalls+1
            guard stalls<100 else{throw VMMError.message("マスター音声処理が停止しました。")}
        }
        output=nil
    }
}
