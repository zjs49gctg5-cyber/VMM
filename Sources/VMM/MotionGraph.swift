import SwiftUI

/// Samples the evaluated easing (including overshoot), rather than only key values.
enum MotionGraph {
    static func value(_ track:AnimationTrack,clip:Clip,time:Double,speed:Bool,domain:ClosedRange<Double>?=nil)->Double {
        let factor=track.property.percent ? 100.0:1.0
        if !speed{return interpolate(track.keys,at:time,fallback:track.property.get(clip))*factor}
        let range=domain ?? clip.motionStart...clip.motionEnd
        let h=min(0.001,clip.duration/1000),a=max(range.lowerBound,time-h),b=min(range.upperBound,time+h)
        guard b>a else{return 0}
        return (interpolate(track.keys,at:b,fallback:track.property.get(clip))-interpolate(track.keys,at:a,fallback:track.property.get(clip)))/(b-a)*factor
    }
}
@MainActor extension EditorStore {
    func editGraphKey(_ clipID:UUID,property:AnimatedProperty,keyID:UUID,time:Double,value:Double)throws {
        try mutateMotion(clipID){c in
            guard let i=c.animation?.tracks.firstIndex(where:{$0.property==property}),let j=c.animation?.tracks[i].keys.firstIndex(where:{$0.id==keyID}),time.isFinite,value.isFinite,property.range.contains(value) else{throw VMMError.message("キーフレームが見つかりません。")}
            let keys=c.animation!.tracks[i].keys.sorted{$0.time<$1.time},key=keys.first{$0.id==keyID}!,step=1/Double(project.fps)
            let index=keys.firstIndex{$0.id==keyID}!,lo=index>0 ? keys[index-1].time+step:c.animationDomain.lowerBound,hi=index+1<keys.count ? keys[index+1].time-step:c.animationDomain.upperBound
            // Sub-frame keys can leave no free frame. Their values remain editable.
            let t=lo<=hi ? min(hi,max(lo,c.motionStart+((time-c.motionStart)/step).rounded()*step)):key.time
            c.animation!.tracks[i].keys[j].time=t;c.animation!.tracks[i].keys[j].value=value
            c.animation!.tracks[i].keys.sort{$0.time<$1.time}
        }
    }
}
struct MotionGraphEditor:View {
    @ObservedObject var store:EditorStore
    let clip:Clip
    var plotHeight:Double=210
    var focusedProperty:AnimatedProperty?=nil
    var onSelect:((AnimatedProperty,Double)->Void)?=nil
    @State private var properties:Set<AnimatedProperty>=[.x,.y]
    @State private var speed=false
    @State private var allKeys=true
    @State private var activeProperty:AnimatedProperty?
    private let colors:[Color]=[.cyan,.orange,.green,.pink,.purple,.yellow]
    private var tracks:[AnimationTrack]{(clip.animation?.tracks ?? []).filter{$0.enabled && properties.contains($0.property)}}
    private var domain:ClosedRange<Double>{let times=tracks.flatMap(\.keys).map(\.time);return allKeys ? min(clip.motionStart,times.min() ?? clip.motionStart)...max(clip.motionEnd,times.max() ?? clip.motionEnd):clip.motionStart...clip.motionEnd}
    var body:some View {
        VStack(alignment:.leading,spacing:8){
            HStack{Text(L("グラフエディタ")).fontWeight(.semibold);Spacer();Picker(L("表示"),selection:$speed){Text(L("値")).tag(false);Text(L("速度 / 秒")).tag(true)}.pickerStyle(.segmented).frame(width:220)}
            HStack{Menu{ForEach(clip.availableAnimatedProperties,id:\.self){p in Toggle(L(p.title),isOn:Binding(get:{properties.contains(p)},set:{if $0{properties.insert(p)}else{properties.remove(p)}}))}}label:{Label(L("表示する項目"),systemImage:"line.3.horizontal.decrease")};VMMMenuPicker(L("操作対象"),selection:$activeProperty){VMMChoice(text:L("自動"),value:Optional<AnimatedProperty>.none);VMMOptions(tracks,id:\.property){VMMChoice(text:L($0.property.title),value:Optional($0.property))}}.frame(maxWidth:300);Spacer();Toggle(L("全キーを表示"),isOn:$allKeys)}
            let samples=tracks.flatMap{track in (0...240).map{MotionGraph.value(track,clip:clip,time:domain.lowerBound+(domain.upperBound-domain.lowerBound)*Double($0)/240,speed:speed,domain:domain)}}
            let minimum=min(0,samples.min() ?? 0),maximum=max(0,samples.max() ?? 100),padding=max(1,(maximum-minimum)*0.08),low=minimum-padding,high=maximum+padding
            HStack(spacing:8){VStack{Text(String(format:"%.1f",high));Spacer();Text(String(format:"%.1f",(low+high)/2));Spacer();Text(String(format:"%.1f",low))}.monospacedDigit().frame(width:55)
                MotionGraphPlot(store:store,clip:clip,tracks:tracks,speed:speed,domain:domain,low:low,high:high,activeProperty:activeProperty,onSelect:{p,t in activeProperty=p;onSelect?(p,t)}).frame(minHeight:plotHeight)
            }
            HStack{Text(String(format:"%.3f s",domain.lowerBound-clip.motionStart));Spacer();Text(L(speed ? "左右：時刻 · 値の変更は値表示で":"左右：時刻 · 上下：値"));Spacer();Text(String(format:"%.3f s",domain.upperBound-clip.motionStart))}.font(.caption).foregroundColor(.secondary)
            if clip.spatialAnimation != nil,tracks.contains(where:{[.x,.y].contains($0.property)}){Text(L("移動パスが有効なため、X/Yのキーよりパスが優先されます。")).font(.caption).foregroundColor(.secondary)}
            ScrollView(.horizontal){HStack{ForEach(Array(tracks.enumerated()),id:\.element.property){i,t in Label(L(t.property.title)+(t.property.percent ? (speed ? " (%/s)":" (%)"):(speed ? " ("+L(t.property.unit)+"/s)":" ("+L(t.property.unit)+")")),systemImage:"minus").foregroundColor(colors[i%colors.count])}}}
        }.onAppear{if tracks.isEmpty{properties=Set((clip.animation?.tracks ?? []).prefix(3).map(\.property))};focusProperty()}
        .onChange(of:focusedProperty){_ in focusProperty()}
        .onChange(of:tracks.map(\.property)){props in if let activeProperty,!props.contains(activeProperty){self.activeProperty=nil}}
    }
    private func focusProperty(){if let p=focusedProperty,clip.animation?.tracks.contains(where:{$0.property==p && $0.enabled})==true{properties.insert(p);activeProperty=p}}
}
