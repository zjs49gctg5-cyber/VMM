import SwiftUI

@MainActor final class PlaybackClock:ObservableObject {
    @Published var time:Double=0
    @Published var masterMeter=AudioMeterDisplay()
    @Published var trackMeters:[TrackAudioMeter]=[]
    private var meterTime=ProcessInfo.processInfo.systemUptime
    func updateMeters(_ reading:AudioMeterReading,tracks:[TrackAudioMeter]) {
        let now=ProcessInfo.processInfo.systemUptime,elapsed=max(0,min(1,now-meterTime));meterTime=now
        masterMeter.update(reading,elapsed:elapsed)
        trackMeters=tracks.map {track in var value=track;value.display=trackMeters.first{$0.id==track.id}?.display ?? AudioMeterDisplay();value.display.update(track.reading,elapsed:elapsed);return value}
    }
    func stopMeters(){masterMeter.clearCurrent();for i in trackMeters.indices{trackMeters[i].display.clearCurrent()}}
    func resetMeters(){masterMeter.reset();for i in trackMeters.indices{trackMeters[i].display.reset()}}
    @Published var performance:PreviewPerformance?
}
/// Only views which consume playback state subscribe to frame-rate updates.
struct PlaybackContent<Content:View>:View {
    @ObservedObject var clock:PlaybackClock
    @ViewBuilder var content:(PlaybackClock)->Content
    var body:some View {content(clock)}
}

struct AudioMeterDisplay:Equatable {
    var current=AudioMeterReading(),hold=AudioMeterReading(),overload=false
    mutating func update(_ reading:AudioMeterReading,elapsed:Double) {
        // 18 dB/second release; peaks between UI refreshes are captured by the probe.
        let release=pow(10,-18*elapsed/20)
        current=AudioMeterReading(leftPeak:max(reading.leftPeak,current.leftPeak*release),rightPeak:max(reading.rightPeak,current.rightPeak*release),leftRMS:reading.leftRMS,rightRMS:reading.rightRMS)
        hold.leftPeak=max(hold.leftPeak,reading.leftPeak);hold.rightPeak=max(hold.rightPeak,reading.rightPeak)
        overload=overload || reading.peak>=1
    }
    mutating func clearCurrent(){current=AudioMeterReading()}
    mutating func reset(){hold=AudioMeterReading();overload=false}
}
struct TrackAudioMeter:Identifiable,Equatable {
    var id:Int,name:String,reading:AudioMeterReading
    var display=AudioMeterDisplay()
}
