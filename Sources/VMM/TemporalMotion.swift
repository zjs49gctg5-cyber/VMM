import SwiftUI

struct TemporalMotion:Codable,Equatable {
    var shutterAngle:Double=180
    var samples:Int=6
    var trailCount:Int=0
    var trailDuration:Double=0.25
    var trailOpacity:Double=0.35
    func validated()throws{guard shutterAngle.isFinite,(0...360).contains(shutterAngle),(2...16).contains(samples),(0...12).contains(trailCount),trailDuration.isFinite,(0.001...3).contains(trailDuration),trailOpacity.isFinite,(0...1).contains(trailOpacity) else{throw VMMError.message("モーションブラー・残像の設定が不正です。")}}
    func exposureTimes(at time:Double,clip:Clip,fps:Int,playing:Bool)->[Double]{
        guard shutterAngle>0 else{return [time]};let count=playing ? min(4,samples):samples,width=shutterAngle/360/Double(fps)
        return (0..<count).map{min(clip.end-0.000001,max(clip.start,time+(Double($0)+0.5)/Double(count)*width-width/2))}
    }
}
struct TemporalMotionControls:View {
    @ObservedObject var store:EditorStore;let clip:Clip
    var onSelect:((AnimatedProperty)->Void)?=nil
    private var time:Double{min(clip.motionEnd,max(clip.motionStart,clip.motionTime(at:store.playhead)))}
    private func value(_ p:AnimatedProperty)->Binding<Double>{Binding(get:{clip.motionValue(p,at:time)},set:{v in do{if clip.animation?.tracks.first(where:{$0.property==p})?.enabled==true && !(clip.animation?.tracks.first(where:{$0.property==p})?.keys.isEmpty ?? true) {try store.setMotionValue(clip.id,property:p,time:time,value:v)}else{try store.mutateMotion(clip.id){p.set(v,on:&$0)}}}catch{store.error=error.localizedDescription}})}
    var body:some View{VStack(alignment:.leading,spacing:12){
        Text(L("モーションブラー・残像")).fontWeight(.semibold)
        ForEach([AnimatedProperty.shutterAngle,.blurSamples,.trailCount,.trailDuration,.trailOpacity],id:\.self){p in HStack{
            NumberInput(title:p.title,value:value(p),range:p.range,unit:p.unit,percent:p.percent)
            Button{do{_=try store.insertMotionPoint(clip.id,at:time,property:p);onSelect?(p)}catch{store.error=error.localizedDescription}}label:{Image(systemName:"diamond.fill").foregroundColor(!(clip.animation?.tracks.first(where:{$0.property==p})?.keys.isEmpty ?? true) && clip.animation?.tracks.first(where:{$0.property==p})?.enabled==true ? .orange:.secondary)}.help(L("この項目をキーフレームに追加"))
        }}
        Text(L("◆で項目をキーフレームに追加します。追加後の数値変更は現在時刻のキーへ記録され、下の時間軸で時刻や補間を編集できます。")).foregroundColor(.secondary)
        Text(L("0°でブラーを停止します。再生中のブラーは最大4サンプル、停止中と出力時は設定値で描画します。残像は過去の位置へ描き、シーク後にも再現します。")).foregroundColor(.secondary)
    }}
}
