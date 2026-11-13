import AVFoundation

struct ReactiveAudioData:Codable,Equatable {
    var sampleRate:Double=30
    var amplitude:[Double]
    var bass:[Double]
    var onset:[Double]
    func validated()throws{guard sampleRate.isFinite,(1...120).contains(sampleRate),(1...108000).contains(amplitude.count),bass.count==amplitude.count,onset.count==amplitude.count,[amplitude,bass,onset].allSatisfy({$0.allSatisfy{$0.isFinite && (0...1).contains($0)}}) else{throw VMMError.message("音声連動の解析データが不正です（解析対象は最大1時間）。")}}
}
enum ReactiveSignal:String,Codable,CaseIterable {case amplitude,bass,onset
    var title:String{switch self{case .amplitude:return "音量";case .bass:return "低音（180Hz以下）";case .onset:return "アタック・拍の候補"}}
}
struct AudioReactive:Codable,Equatable {
    var assetID:UUID?
    var data:ReactiveAudioData
    var signal=ReactiveSignal.amplitude
    var sourceOffset:Double=0
    /// Source clip's start relative to the target's original animation domain.
    var timelineOffset:Double=0
    var sourceDuration:Double=1
    var rate:Double=1
    var gain:Double=1
    var threshold:Double=0
    var scaleAmount:Double=0.25
    var shakeAmount:Double=0
    var glowAmount:Double=0
    func value(at time:Double)->Double {
        let local=time-timelineOffset
        guard local>=0,local<sourceDuration else{return 0}
        let index=(sourceOffset+local*rate)*data.sampleRate,values=signal == .bass ? data.bass:signal == .onset ? data.onset:data.amplitude
        guard index>=0,index<Double(values.count) else{return 0};let i=Int(index),j=min(values.count-1,i+1),value=values[i]+(values[j]-values[i])*(index-Double(i))
        return min(1,max(0,(value-threshold)/max(0.001,1-threshold)*gain))
    }
    func validated()throws {
        try data.validated()
        func valid(_ v:Double,_ r:ClosedRange<Double>)->Bool{v.isFinite && r.contains(v)}
        guard valid(sourceOffset,0...86400),valid(timelineOffset,-86400...86400),valid(sourceDuration,0.001...86400),valid(rate,0.1...8),valid(gain,0...10),valid(threshold,0...0.99),valid(scaleAmount,-0.99...4),valid(shakeAmount,0...1),valid(glowAmount,0...100) else{throw VMMError.message("音声連動の設定が不正です。")}
    }
}
enum ReactiveAudioAnalyzer {
    static func analyze(url:URL)async throws->ReactiveAudioData {
        let duration=try await AVURLAsset(url:url).load(.duration).seconds
        guard duration.isFinite,duration>0,duration<=3600 else{throw VMMError.message("音声連動の解析対象は1時間までです。")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-reactive-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let fileURL=root.appendingPathComponent("decoded.wav")
        guard try await AudioProcessor.decode(source:url,destination:fileURL) else{throw VMMError.message("選択した素材に音声がありません。")}
        return try analyzePCM(url:fileURL)
    }
    static func analyzePCM(url:URL)throws->ReactiveAudioData {
        let file=try AVAudioFile(forReading:url),format=file.processingFormat,hop=max(1,Int(format.sampleRate/30)),channels=Int(format.channelCount)
        guard Double(file.length)/format.sampleRate<=3600,channels>0,let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(hop)) else{throw VMMError.message("音声連動の解析対象は1時間までです。")}
        var amplitude=[Double](),bass=[Double](),low=Array(repeating:0.0,count:channels)
        let alpha=1-exp(-2 * .pi * 180/format.sampleRate)
        while file.framePosition<file.length {
            try Task.checkCancellation();try file.read(into:buffer,frameCount:AVAudioFrameCount(hop));guard buffer.frameLength>0,let samples=buffer.floatChannelData else{break}
            var power=0.0,bassPower=0.0
            for channel in 0..<channels{for i in 0..<Int(buffer.frameLength){let s=Double(samples[channel][i]);power+=s*s;low[channel]+=alpha*(s-low[channel]);bassPower+=low[channel]*low[channel]}}
            let n=Double(Int(buffer.frameLength)*channels);amplitude.append(sqrt(power/n));bass.append(sqrt(bassPower/n))
        }
        guard !amplitude.isEmpty else{throw VMMError.message("音声が空です。")}
        func normalize(_ values:[Double])->[Double]{let peak=values.max() ?? 0;guard peak>0.000001 else{return Array(repeating:0,count:values.count)};return values.map{min(1,max(0,$0/peak))}}
        let flux=amplitude.indices.map{i in max(0,amplitude[i]-(i>0 ? amplitude[i-1]:0))}
        func smooth(_ values:[Double],attack:Double,release:Double)->[Double]{var value=0.0;return values.map{next in let factor=1-exp(-1/(30*(next>value ? attack:release)));value+=(next-value)*factor;return value}}
        let result=ReactiveAudioData(sampleRate:format.sampleRate/Double(hop),amplitude:smooth(normalize(amplitude),attack:0.015,release:0.10),bass:smooth(normalize(bass),attack:0.015,release:0.10),onset:smooth(normalize(flux),attack:0.001,release:0.12));try result.validated();return result
    }
}
