import SwiftUI

struct AudioMasterControls:View {
    @ObservedObject var store:EditorStore
    @State private var processing=false
    @State private var waveform=false
    var body:some View {
        NumberInput(title:"マスター音量",value:Binding(get:{store.project.masterVolume ?? 1},set:{v in store.pause();store.checkpoint();store.project.masterVolume=v}),range:0...2,percent:true)
        AudioMeterSummary(clock:store.playbackClock)
        Button(L("ミックス全体の波形…")){waveform=true}.sheet(isPresented:$waveform){MixWaveformSheet(store:store)}
        Button(L("ミックス解析・音声処理…")){processing=true}
            .popover(isPresented:$processing){AudioProcessingPanel(store:store).frame(width:460,height:500)}
    }
}
struct AudioMeterSummary:View {
    @ObservedObject var clock:PlaybackClock
    @State private var details=false
    var body:some View {
        Button{details=true} label:{
            HStack(spacing:8){Image(systemName:"waveform.path");Text(L("音量メーター"));Spacer(minLength:0);Text(meterDB(clock.masterMeter.current.peak)).monospacedDigit();if clock.masterMeter.overload{Image(systemName:"exclamationmark.triangle.fill").foregroundColor(.red)}}.vmmFont(size:12)
        }.buttonStyle(.borderless).help(L("L/R・RMS・ピーク保持・レイヤー別の音量を表示"))
        .popover(isPresented:$details){AudioMeterPanel(clock:clock).padding(18).frame(width:440)}
    }
}
/// Kept outside the scrolling canvas so levels remain visible while navigating layers.
struct TimelineAudioMeter:View {
    @ObservedObject var clock:PlaybackClock
    @State private var details=false
    var body:some View {
        VStack(spacing:5){
            HStack(spacing:4){Text(L("音量メーター")).vmmFont(size:12,weight:.semibold);if clock.masterMeter.overload{Image(systemName:"exclamationmark.triangle.fill").foregroundColor(.red)}}
            Text(L("実ミックス")).vmmFont(size:12).foregroundColor(.secondary)
            HStack(alignment:.top,spacing:5){
                GeometryReader{g in ZStack(alignment:.topLeading){
                    ForEach([0.0,-12.0,-24.0,-48.0,-60.0],id:\.self){db in
                        Text(String(Int(db))).vmmFont(size:12,design:.monospaced).foregroundColor(.secondary).position(x:14,y:max(7,min(g.size.height-7,g.size.height * (-db/60))))
                    }
                }}.frame(width:28).padding(.bottom,21)
                VStack(spacing:3){VerticalAudioMeter(peak:clock.masterMeter.current.leftPeak,rms:clock.masterMeter.current.leftRMS,hold:clock.masterMeter.hold.leftPeak);Text("L").vmmFont(size:12).frame(height:18)}
                VStack(spacing:3){VerticalAudioMeter(peak:clock.masterMeter.current.rightPeak,rms:clock.masterMeter.current.rightRMS,hold:clock.masterMeter.hold.rightPeak);Text("R").vmmFont(size:12).frame(height:18)}
            }.frame(maxHeight:.infinity)
            Text(meterDB(clock.masterMeter.hold.peak)).vmmFont(size:12,design:.monospaced).foregroundColor(clock.masterMeter.overload ? .red:.secondary).lineLimit(1).minimumScaleFactor(0.8).help(L("保持"))
            HStack{
                Button{details=true}label:{Image(systemName:"slider.horizontal.3")}.help(L("音量メーターの詳細")).accessibilityLabel(L("音量メーターの詳細"))
                Spacer()
                Button{clock.resetMeters()}label:{Image(systemName:"arrow.counterclockwise")}.help(L("保持・警告をリセット")).accessibilityLabel(L("保持・警告をリセット"))
            }.buttonStyle(.borderless).vmmFont(size:12)
        }.padding(8).background(Color(nsColor:.controlBackgroundColor)).help(L("マスター（実ミックス）"))
        .popover(isPresented:$details){AudioMeterPanel(clock:clock).padding(18).frame(width:440)}
    }
}
private struct VerticalAudioMeter:View {
    let peak:Double,rms:Double,hold:Double
    private func position(_ value:Double)->Double {max(0,min(1,(AudioMeterReading.decibels(value)+60)/60))}
    var body:some View {
        GeometryReader{g in
            ZStack(alignment:.bottom){
                Rectangle().fill(Color.black.opacity(0.45))
                Rectangle().fill(peak>=1 ? Color.red:peak>=pow(10,-6/20) ? Color.orange:Color.green).frame(height:g.size.height*position(peak))
                Rectangle().fill(Color.white.opacity(0.55)).frame(width:4,height:g.size.height*position(rms))
                ForEach([-12.0,-24.0,-48.0],id:\.self){db in Rectangle().fill(Color.black.opacity(0.45)).frame(height:1).position(x:g.size.width/2,y:g.size.height*(-db/60))}
                if hold>0{Rectangle().fill(hold>=1 ? Color.red:Color.white).frame(height:2).position(x:g.size.width/2,y:max(1,min(g.size.height-1,g.size.height*(1-position(hold)))))}
            }.clipped()
        }.frame(minHeight:20).accessibilityLabel("Peak "+meterDB(peak)+", RMS "+meterDB(rms)+", "+L("保持")+" "+meterDB(hold))
    }
}
private func meterDB(_ amplitude:Double)->String {amplitude>0.000001 ? String(format:"%.1f dBFS",AudioMeterReading.decibels(amplitude)):"−∞ dBFS"}
struct AudioMeterPanel:View {
    @ObservedObject var clock:PlaybackClock
    var body:some View {
        VStack(alignment:.leading,spacing:12){
            HStack{Text(L("音量メーター")).vmmFont(weight:.semibold);Spacer();Button(L("保持・警告をリセット")){clock.resetMeters()}}
            Text(L("マスター（実ミックス）")).vmmFont(size:12).foregroundColor(.secondary)
            stereo(clock.masterMeter)
            if clock.masterMeter.overload{Label(L("0 dBFS以上になる可能性があります"),systemImage:"exclamationmark.triangle.fill").vmmFont(size:12).foregroundColor(.red)}
            Divider()
            ScrollView {
                VStack(alignment:.leading,spacing:14){
                    ForEach(clock.trackMeters){track in
                        VStack(alignment:.leading,spacing:4){Text(track.name).vmmFont(size:12,weight:.semibold);stereo(track.display)}
                    }
                    if clock.trackMeters.isEmpty{Text(L("再生すると音声レイヤーを表示します")).vmmFont(size:12).foregroundColor(.secondary)}
                }
            }.frame(maxHeight:250)
            Text(L("マスターは実ミックスのピークとRMS、レイヤー別は振幅の合計上限です。LUFS・True Peakはプロジェクト設定の解析で確認できます。")).vmmFont(size:12).foregroundColor(.secondary).fixedSize(horizontal:false,vertical:true)
        }
    }
    private func stereo(_ value:AudioMeterDisplay)->some View {
        VStack(spacing:5){
            meter("L",peak:value.current.leftPeak,rms:value.current.leftRMS,hold:value.hold.leftPeak)
            meter("R",peak:value.current.rightPeak,rms:value.current.rightRMS,hold:value.hold.rightPeak)
        }
    }
    private func meter(_ channel:String,peak:Double,rms:Double,hold:Double)->some View {
        VStack(alignment:.leading,spacing:3){
            HStack{Text(channel).vmmFont(size:12,weight:.semibold);MeterBar(peak:peak,rms:rms,hold:hold).frame(height:12);Text(meterDB(peak)).vmmFont(size:12,design:.monospaced).frame(width:85,alignment:.trailing)}
            GeometryReader{g in
                ZStack(alignment:.topLeading){ForEach([-60.0,-24.0,-12.0,0.0],id:\.self){db in
                    Text(db==0 ? "0":String(Int(db))).vmmFont(size:12).foregroundColor(.secondary).position(x:max(12,min(g.size.width-12,g.size.width*(db+60)/60)),y:8)
                }}
            }.frame(height:18).padding(.leading,20).padding(.trailing,95)
            HStack{Text("RMS: "+meterDB(rms));Spacer();Text(L("保持")+": "+meterDB(hold))}.vmmFont(size:12,design:.monospaced).foregroundColor(hold>=1 ? .red:.secondary)
        }.accessibilityElement(children:.combine)
    }
}
private struct MeterBar:View {
    let peak:Double,rms:Double,hold:Double
    private func position(_ value:Double)->Double {max(0,min(1,(AudioMeterReading.decibels(value)+60)/60))}
    var body:some View {
        GeometryReader{g in
            ZStack(alignment:.leading){
                RoundedRectangle(cornerRadius:2).fill(Color.black.opacity(0.4))
                Rectangle().fill(peak>=1 ? Color.red:peak>=pow(10,-6/20) ? Color.orange:Color.green).frame(width:g.size.width*position(peak))
                Rectangle().fill(Color.white.opacity(0.5)).frame(width:g.size.width*position(rms),height:3).offset(y:4)
                ForEach([-24.0,-12.0,-6.0],id:\.self){db in Rectangle().fill(Color.black.opacity(0.4)).frame(width:1).offset(x:g.size.width*(db+60)/60)}
                if hold>0{Rectangle().fill(hold>=1 ? Color.red:Color.white).frame(width:2).offset(x:max(0,min(g.size.width-2,g.size.width*position(hold))))}
            }.clipped()
        }.accessibilityLabel("Peak "+meterDB(peak)+", RMS "+meterDB(rms))
    }
}
struct LoudnessControls:View {
    @ObservedObject var store:EditorStore
    let clip:Clip
    @State private var target:Double = -16
    @State private var analyzing=false
    var body:some View {
        VStack(alignment:.leading) {
            NumberInput(title:"目標LUFS",value:$target,range:(-30)...(-9))
            HStack {
                Button(L("LUFS正規化")){normalize()}.disabled(analyzing || store.busy || clip.assetID==nil || clip.speechDirty)
                if clip.normalizationGain != nil {Button(L("解除")){store.edit(clip.id){$0.normalizationGain=nil;$0.measuredLUFS=nil}}}
            }
            if analyzing{ProgressView()}
            if let measured=clip.measuredLUFS {Text(String(format:"%.1f LUFS → %.1f dB",measured,20*log10(max(1e-9,clip.normalizationGain ?? 1)))).vmmFont(size:12)}
            Text(L("選択音声を解析。サンプルピーク−1dBでゲインを制限します。短い音声・無音は正規化しません。")).vmmFont(size:12).foregroundColor(.secondary)
        }
    }
    private func normalize() {
        guard let asset=store.project.asset(for:clip) else{return}
        store.pause();analyzing=true
        let folder=store.directory,snapshot=store.project,source=folder.appendingPathComponent("Media").appendingPathComponent(asset.file),target=target
        Task { @MainActor in
            defer{analyzing=false}
            do {
                let result=try await Task.detached(priority:.utility) {
                    let temp=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-lufs-\(UUID())")
                    try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:temp)}
                    let decoded=temp.appendingPathComponent("decoded.caf"),processed=temp.appendingPathComponent("processed.caf")
                    guard try await AudioProcessor.decode(source:source,destination:decoded) else{throw VMMError.message("音声トラックがありません。")}
                    _=try AudioProcessor.process(decoded:decoded,clip:snapshot.audioProcessingClip(clip),destination:processed)
                    var unnormalized=clip;unnormalized.normalizationGain=nil
                    return try LoudnessAnalyzer.analyze(processed,clip:unnormalized)
                }.value
                guard store.directory==folder,store.project.clips.first(where:{$0.id==clip.id})==clip else{return}
                guard result.integratedLUFS != nil else{store.error="400ms以上の有効な音声がありません。";return}
                store.edit(clip.id){$0.normalizationGain=result.gain(target:target);$0.measuredLUFS=result.integratedLUFS}
            } catch{store.error=error.localizedDescription}
        }
    }
}

struct MasterDynamicsControls:View {
    @ObservedObject var store:EditorStore
    private var settings:MasterDynamics {store.project.masterDynamics ?? MasterDynamics()}
    private func update(_ edit:(inout MasterDynamics)->Void){store.pause();store.checkpoint();var value=settings;edit(&value);store.project.masterDynamics=value}
    var body:some View {
        VStack(alignment:.leading,spacing:6){
            Toggle(L("マスターコンプレッサー"),isOn:Binding(get:{settings.compressorEnabled},set:{v in update{$0.compressorEnabled=v}}))
            if settings.compressorEnabled {
                NumberInput(title:"圧縮しきい値",value:Binding(get:{settings.thresholdDB},set:{v in update{$0.thresholdDB=v}}),range:(-60)...0,unit:"dB")
                NumberInput(title:"圧縮ヘッドルーム",value:Binding(get:{settings.headroomDB},set:{v in update{$0.headroomDB=v}}),range:0.1...40,unit:"dB")
                Text(L("ヘッドルームを小さくすると圧縮が強くなります。")).vmmFont(size:12).foregroundColor(.secondary)
            }
            Toggle(L("マスターリミッター"),isOn:Binding(get:{settings.limiterEnabled},set:{v in update{$0.limiterEnabled=v}}))
            if settings.limiterEnabled {
                NumberInput(title:"出力上限",value:Binding(get:{settings.ceilingDB},set:{v in update{$0.ceilingDB=v}}),range:(-12)...0,unit:"dBFS")
                Text(L("サンプルピークを制限します。圧縮音声のTrue Peakは保証しません。")).vmmFont(size:12).foregroundColor(.secondary)
            }
        }
    }
}

struct AudioProcessingPanel:View {
    @ObservedObject var store:EditorStore
    var body:some View {
        ScrollView{VStack(alignment:.leading,spacing:14){
            Text(L("ミックス解析・音声処理")).vmmFont(weight:.semibold)
            MasterDynamicsControls(store:store)
            Divider()
            MixLoudnessControls(store:store)
        }.padding(18).frame(maxWidth:.infinity,alignment:.leading)}
    }
}
