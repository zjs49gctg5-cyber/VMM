import AVFoundation

struct LoudnessResult:Equatable {
    var integratedLUFS:Double?
    var samplePeak:Double
    var truePeakEstimate:Double?
    var clippedFrames:Int64=0
    func gain(target:Double,ceilingDB:Double = -1)->Double {
        guard let integratedLUFS,samplePeak>0 else{return 1}
        return min(64,pow(10,(target-integratedLUFS)/20),pow(10,ceilingDB/20)/samplePeak)
    }
}
/// BS.1770 K-weighting and two-stage gating for decoded 48 kHz mono/stereo.
/// The peak ceiling is a sample-peak ceiling, not a true-peak limiter.
enum LoudnessAnalyzer {
    private struct Biquad {
        var b0:Double,b1:Double,b2:Double,a1:Double,a2:Double
        var z1=0.0,z2=0.0
        mutating func process(_ x:Double)->Double {let y=b0*x+z1;z1=b1*x-a1*y+z2;z2=b2*x-a2*y;return y}
    }
    static func analyze(_ url:URL,clip:Clip?=nil)throws->LoudnessResult {
        let file=try AVAudioFile(forReading:url),format=file.processingFormat
        guard format.sampleRate==48000,(1...2).contains(format.channelCount) else{throw VMMError.message("LUFS解析は48kHzのモノラル／ステレオ音声に対応しています。")}
        let channels=Int(format.channelCount),buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:4096)!
        var shelf=Array(repeating:Biquad(b0:1.53512485958697,b1:-2.69169618940638,b2:1.19839281085285,a1:-1.69065929318241,a2:0.73248077421585),count:channels)
        var highpass=Array(repeating:Biquad(b0:1,b1:-2,b2:1,a1:-1.99004745483398,a2:0.99007225036621),count:channels)
        let window=19200,hop=4800
        var ring=Array(repeating:0.0,count:window),sum=0.0,peak=0.0,index=0,blocks:[Double]=[],clipped:Int64=0
        while file.framePosition<file.length {
            try Task.checkCancellation();try file.read(into:buffer)
            guard let samples=buffer.floatChannelData,buffer.frameLength>0 else{break}
            for frame in 0..<Int(buffer.frameLength) {
                let gain=clip.map{$0.audioVolume(at:$0.start+Double(index)/48000)} ?? 1
                var energy=0.0,over=false
                for channel in 0..<channels {
                    let x=Double(samples[channel][frame])*gain;peak=max(peak,abs(x));over = over || abs(x)>=1
                    let y=highpass[channel].process(shelf[channel].process(x));energy+=y*y
                }
                if over {clipped+=1}
                let slot=index%window;sum+=energy-ring[slot];ring[slot]=energy;index+=1
                if index>=window,(index-window)%hop==0{blocks.append(max(0,sum/Double(window)))}
            }
        }
        func level(_ energy:Double)->Double {-0.691+10*log10(max(energy,1e-30))}
        let absolute=blocks.filter{level($0) > -70}
        guard !absolute.isEmpty else{return LoudnessResult(integratedLUFS:nil,samplePeak:peak,truePeakEstimate:clip == nil ? try oversampledPeak(url):nil,clippedFrames:clipped)}
        let relative=level(absolute.reduce(0,+)/Double(absolute.count))-10
        let gated=absolute.filter{level($0)>relative}
        return LoudnessResult(integratedLUFS:gated.isEmpty ? nil:level(gated.reduce(0,+)/Double(gated.count)),samplePeak:peak,truePeakEstimate:clip == nil ? try oversampledPeak(url):nil,clippedFrames:clipped)
    }
    /// Native high-quality 4x sample-rate conversion estimates intersample peaks.
    /// This is a diagnostic estimate, not a certified BS.1770 true-peak instrument.
    static func oversampledPeak(_ url:URL)throws->Double {
        let file=try AVAudioFile(forReading:url),input=file.processingFormat
        let output=AVAudioFormat(standardFormatWithSampleRate:192000,channels:input.channelCount)!
        guard let converter=AVAudioConverter(from:input,to:output) else{throw VMMError.message("ピーク解析の変換器を作成できません。")}
        converter.sampleRateConverterQuality=127
        let source=AVAudioPCMBuffer(pcmFormat:input,frameCapacity:4096)!,target=AVAudioPCMBuffer(pcmFormat:output,frameCapacity:16384)!
        var peak=0.0,readError:Error?
        while true {
            try Task.checkCancellation()
            var error:NSError?
            let state=converter.convert(to:target,error:&error){count,status in
                do {
                    if file.framePosition>=file.length {status.pointee = .endOfStream;return nil}
                    try file.read(into:source,frameCount:min(count,4096));status.pointee = .haveData;return source
                } catch {readError=error;status.pointee = .endOfStream;return nil}
            }
            if let readError {throw readError};if let error {throw error}
            if let samples=target.floatChannelData {for c in 0..<Int(output.channelCount) {for i in 0..<Int(target.frameLength){peak=max(peak,abs(Double(samples[c][i])))}}}
            if state == .endOfStream {break}
            guard state != .error else{throw VMMError.message("ピーク解析に失敗しました。")}
        }
        return peak
    }

}
struct AudioMeterReading:Equatable,Sendable {
    var leftPeak=0.0,rightPeak=0.0,leftRMS=0.0,rightRMS=0.0
    var peak:Double {max(leftPeak,rightPeak)}
    static func upperBound(_ values:[Self])->Self {
        values.reduce(Self()){a,b in Self(leftPeak:a.leftPeak+b.leftPeak,rightPeak:a.rightPeak+b.rightPeak,leftRMS:a.leftRMS+b.leftRMS,rightRMS:a.rightRMS+b.rightRMS)}
    }
    static func decibels(_ amplitude:Double)->Double {amplitude>0 && amplitude.isFinite ? 20*log10(amplitude): -Double.infinity}
}
/// Reads only PCM samples in the audio tap. UI publication happens on the main actor.
final class AudioMeterProbe {
    private let lock=NSLock()
    private var latest=AudioMeterReading(),pending=AudioMeterReading(),squaresL=0.0,squaresR=0.0,frames=0,lastTime=0.0,attenuation=1.0
    func setOutputAttenuation(_ value:Double){lock.lock();attenuation=value.isFinite ? min(1,max(0,value)):0;lock.unlock()}
    var reading:AudioMeterReading {lock.lock();defer{lock.unlock()};return ProcessInfo.processInfo.systemUptime-lastTime<0.3 ? latest:AudioMeterReading()}
    var peak:Double {reading.peak}
    func drain()->AudioMeterReading {
        lock.lock();defer{lock.unlock()}
        guard frames>0 else{
            // A display tick can fall between tap buffers; retain the last RMS briefly.
            guard ProcessInfo.processInfo.systemUptime-lastTime<0.3 else{return AudioMeterReading()}
            return AudioMeterReading(leftRMS:latest.leftRMS,rightRMS:latest.rightRMS)
        }
        var result=pending;result.leftRMS=sqrt(squaresL/Double(frames));result.rightRMS=sqrt(squaresR/Double(frames))
        pending=AudioMeterReading();squaresL=0;squaresR=0;frames=0
        return ProcessInfo.processInfo.systemUptime-lastTime<0.3 ? result:AudioMeterReading()
    }
    func accept(_ buffer:AVAudioPCMBuffer) {
        guard let channels=buffer.floatChannelData,buffer.frameLength>0,buffer.format.channelCount>0 else{return}
        lock.lock();let gain=attenuation;lock.unlock()
        var value=AudioMeterReading(),l2=0.0,r2=0.0
        let right=Int(buffer.format.channelCount)>1 ? 1:0,count=Int(buffer.frameLength)
        for i in 0..<count {
            let l=Double(channels[0][i])*gain,r=Double(channels[right][i])*gain
            guard l.isFinite,r.isFinite else{continue}
            value.leftPeak=max(value.leftPeak,abs(l));value.rightPeak=max(value.rightPeak,abs(r));l2+=l*l;r2+=r*r
        }
        value.leftRMS=sqrt(l2/Double(count));value.rightRMS=sqrt(r2/Double(count))
        lock.lock();latest=value;pending.leftPeak=max(pending.leftPeak,value.leftPeak);pending.rightPeak=max(pending.rightPeak,value.rightPeak)
        squaresL+=l2;squaresR+=r2;frames+=count;lastTime=ProcessInfo.processInfo.systemUptime;lock.unlock()
    }
}
