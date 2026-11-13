import SwiftUI
import AppKit

enum MotionTab:String,CaseIterable {case keyframes="基本変形",temporal="ブラー・残像",effects="エフェクト",paths="図形・マスク",spatial="移動パス・支点",characters="文字",custom="カスタム",intervals="区間編集",entrances="登場・退場",motions="反復",audio="音声フェード",transition="場面切替",psd="立ち絵・表情",reactive="音声連動",tracking="追跡"}
enum MotionCategory:String,CaseIterable {
    case transform="変形",appearance="見た目",character="文字・立ち絵",presets="動きのプリセット",advanced="高度な操作"
    var tabs:[MotionTab] {
        switch self {
        case .transform:return [.keyframes,.spatial]
        case .appearance:return [.effects,.temporal,.paths]
        case .character:return [.characters,.psd]
        case .presets:return [.entrances,.motions,.audio,.transition]
        case .advanced:return [.custom,.intervals,.reactive,.tracking]
        }
    }
}
struct AnimationWorkspace:View {
    @ObservedObject var store:EditorStore;var onClose:()->Void
    @State private var tab=MotionTab.keyframes
    @State private var added:Set<MotionTab>=[]
    @State private var selection:MotionSelection?
    @State private var allKeys=true
    @State private var graphOpen=false;@State private var timelineZoom=1.0;@State private var timelinePosition=0.0
    init(store:EditorStore,onClose:@escaping ()->Void,initialTab:String="キーフレーム",initialGraph:Bool=false) {self.store=store;self.onClose=onClose;_graphOpen=State(initialValue:initialGraph);_tab=State(initialValue:initialTab=="キーフレーム" ? .keyframes:MotionTab(rawValue:initialTab) ?? .keyframes)}
    private var target:Clip?{store.selected}
    private var chosenLane:AnimationLane?{selection?.lane ?? selection?.property.map{.property($0)} ?? (selection?.psdKeyID != nil ? .psd:nil)}
    var body:some View{PlaybackContent(clock:store.playbackClock){_ in content}}
    private func supported(_ c:Clip)->[MotionTab]{if c.kind == .transition{return [.transition]};var t:[MotionTab]=[.keyframes,.custom];if ![.audio,.adjustment].contains(c.kind){t += [.entrances,.motions]};if c.supportsParent || c.kind == .adjustment{t += [.spatial,.tracking,.paths,.effects];if c.kind != .adjustment{t += [.reactive,.temporal]}};if [.text,.speech].contains(c.kind){t.append(.characters)};if [.audio,.video,.speech,.group].contains(c.kind){t.append(.audio)};if store.project.asset(for:c)?.psd != nil{t.append(.psd)};return t}
    private func items(_ c:Clip)->[MotionTab]{supported(c).filter{t in added.contains(t) || t==tab || t == .keyframes || {
        switch t{case .temporal:return c.temporalMotion != nil;case .effects:return !(c.effects ?? []).isEmpty;case .spatial:return c.spatialAnimation != nil || c.anchorPoint != nil;case .paths:return c.shapeStyle?.path != nil || (c.masks ?? []).contains{$0.path != nil};case .characters:return c.textAnimation != nil;case .custom:return c.customAnimation != nil;case .entrances:return (c.animation?.entrance.kind ?? .none) != .none || (c.animation?.exit.kind ?? .none) != .none;case .motions:return !(c.animation?.motions ?? []).isEmpty;case .audio:return c.audioFade != nil;case .psd:return c.psd != nil;case .reactive:return c.audioReactive != nil;case .tracking:return c.tracking != nil;case .transition:return true;default:return false}
    }()}}
    private var content:some View {VStack(spacing:0){
        HStack{Text(L("アニメーション編集")).fontWeight(.semibold);targetPicker.frame(minWidth:160,maxWidth:340);Spacer();Button(L("閉じる"),action:onClose)}.padding(8)
        Divider()
        if let c=target {
            HStack{addMenu(c);Menu{ForEach(MotionCategory.allCases,id:\.self){category in let choices=category.tabs.filter{items(c).contains($0)};if !choices.isEmpty{Menu(L(category.rawValue)){ForEach(choices,id:\.self){item in Button{tab=item}label:{if item==tab{Label(L(item.rawValue),systemImage:"checkmark")}else{Text(L(item.rawValue))}}}}}}}label:{Label(L(tab.rawValue),systemImage:"slider.horizontal.3")}.help(L("編集する設定項目"));Spacer();Menu{Toggle(L("全キーを表示"),isOn:$allKeys)}label:{Label(L("表示・編集"),systemImage:"slider.horizontal.3")}}.padding(.horizontal,12).padding(.vertical,8)
            HSplitView {
                    ScrollView(.vertical){VStack(alignment:.leading,spacing:14){
                        if tab != .keyframes,let lane=chosenLane,lane.canKeyframe,c.animationLanes.contains(lane){UnifiedKeyControls(store:store,clip:c,lane:lane,selection:$selection)}
                        settings(c)
                    }.padding(12)}.frame(minWidth:290,idealWidth:350,maxWidth:.infinity).disabled(store.busy || store.project.tracks[c.track].locked).id(c.id)
                    timeline(c).frame(minWidth:360,maxWidth:.infinity,maxHeight:.infinity)
                }

        }else{Text(L("タイムラインでアイテムを選択してください。")).padding();Spacer()}
    }.onAppear{added.insert(tab);resetTarget()}.onChange(of:target?.id){_ in added=[];resetTarget()}.onChange(of:tab){_ in if let lane=chosenLane,section(lane) != tab{selection=nil}}
    .onChange(of:store.projectRevision){_ in if let c=target,let lane=chosenLane,let id=selection?.keyID{if let key=lane.keys(c).first(where:{$0.id==id}){selection?.time=key.time}else{selection?.keyID=nil;selection?.psdKeyID=nil}}}
    .background(Color(nsColor:.windowBackgroundColor)).vmmAppearance(store.settings)
    .alert(L("確認してください"),isPresented:Binding(get:{store.error != nil},set:{if !$0{store.error=nil}})){Button("OK"){store.error=nil}}message:{Text(L(store.error ?? ""))}}
    private var targetPicker:some View{VMMMenuPicker(L("編集対象"),selection:Binding<UUID?>(get:{target?.id},set:{id in guard let c=store.project.clips.first(where:{$0.id==id}) else{return};store.selectedIDs=[];store.selectedTrack=c.track;store.selectedID=c.id})){VMMChoice(text:L("アイテムを選択"),value:Optional<UUID>.none);VMMOptions(store.project.clips.sorted{$0.track == $1.track ? $0.start<$1.start:$0.track<$1.track},id:\.id){c in VMMChoice(text:"\(store.project.tracks[c.track].name) · \(c.name)",value:Optional(c.id))}}.disabled(store.busy)}
    private func resetTarget(){selection=nil;if store.animationPlaybackRange != nil{store.pause()};if let c=target{if !supported(c).contains(tab){tab=supported(c)[0]};if store.playhead<c.start || store.playhead>=c.end{store.seek(c.start)}}}
    private func section(_ lane:AnimationLane)->MotionTab{switch lane{case .property(let p):return p.isTemporal ? .temporal:.keyframes;case .effect:return .effects;case .spatial:return .spatial;case .shape,.trim:return .paths;case .psd:return .psd;case .timing(let t):switch t{case .entrance,.exit:return .entrances;case .characters:return .characters;case .motions:return .motions;case .audioIn,.audioOut:return .audio;case .transition:return .transition}}}
    private func focus(_ lane:AnimationLane){tab=section(lane);added.insert(tab)}
    private func pick(_ lane:AnimationLane,_ c:Clip){let now=min(c.motionEnd,max(c.motionStart,c.motionTime(at:store.playhead)));selection=MotionSelection(time:now,property:{if case .property(let p)=lane{return p};return nil}(),lane:lane);focus(lane)}
    private func attempt(_ action:()throws->Void){do{try action()}catch{store.error=error.localizedDescription}}
    private func addMenu(_ c:Clip)->some View {
        Menu {
            ForEach(MotionCategory.allCases,id:\.self) { category in
                let options=category.tabs.filter{supported(c).contains($0)}
                if !options.isEmpty {
                    Menu(L(category.rawValue)) {
                        ForEach(options,id:\.self) { item in
                            if item == .keyframes && c.kind != .transition {
                                Menu(L("基本変形の項目")) {
                                    ForEach(c.availableAnimatedProperties.filter{!$0.isTemporal},id:\.self) { p in
                                        Button(L(p.title)) {attempt{let lane=AnimationLane.property(p),key=try store.insertAnimationKey(c.id,lane:lane,at:c.motionTime(at:store.playhead));selection=MotionSelection(time:key.time,property:p,lane:lane,keyID:key.id);focus(lane)}}
                                    }
                                }
                            } else if item == .temporal {
                                Button(L("モーションブラー")){addTemporal(c,trails:false)}
                                Button(L("残像")){addTemporal(c,trails:true)}
                            } else if item == .effects {
                                Menu(L("エフェクト")) {
                                    ForEach(EffectKind.allCases,id:\.self) { kind in
                                        Button(L(kind.title)){attempt{let effect=VisualEffect(kind:kind);try store.mutateMotion(c.id){$0.effects=($0.effects ?? [])+[effect]};pick(.effect(effect.id),c)}}
                                    }
                                }
                            } else {
                                Button(L(item.rawValue)){added.insert(item);tab=item;selection=nil}
                            }
                        }
                    }
                }
            }
            Divider()
            Menu(L("VMMプリセット")){ForEach(EffectPreset.builtins,id:\.name){p in Button(L(p.name)){store.applyPreset(p,clipID:c.id)}};Button(L("プリセットを読み込む…")){store.importEffectPreset(clipID:c.id)};Button(L("現在の設定を保存…")){store.exportEffectPreset(clipID:c.id)}}
        } label:{Label(L("設定項目を追加"),systemImage:"plus")}.disabled(store.busy || store.project.tracks[c.track].locked)
    }
    private func addTemporal(_ c:Clip,trails:Bool){attempt{try store.mutateMotion(c.id){clip in var t=clip.temporalMotion ?? TemporalMotion(shutterAngle:trails ? 0:180);if trails{t.trailCount=max(3,t.trailCount)};clip.temporalMotion=t;let p:AnimatedProperty=trails ? .trailCount:.shutterAngle;if clip.animation?.tracks.first(where:{$0.property==p})==nil{clip.putMotionKey(p,time:clip.motionStart,value:p.get(clip),easing:trails ? .hold:.linear);clip.putMotionKey(p,time:clip.motionEnd,value:p.get(clip),easing:trails ? .hold:.linear)}};pick(.property(trails ? .trailCount:.shutterAngle),c)}}
    @ViewBuilder private func settings(_ c:Clip)->some View {switch tab {
        case .keyframes:
            Picker(L("編集"),selection:$graphOpen){Text(L("数値")).tag(false);Text(L("グラフ")).tag(true)}.pickerStyle(.segmented)
            if graphOpen{MotionGraphEditor(store:store,clip:c,plotHeight:140,focusedProperty:selection?.property,onSelect:{p,t in selection=MotionSelection(time:t,property:p,lane:.property(p))});if let lane=chosenLane,lane.canKeyframe,c.animationLanes.contains(lane){PanelDisclosure(L("選択したキーの設定")){UnifiedKeyControls(store:store,clip:c,lane:lane,selection:$selection)}}}
            else{BasicTransformControls(store:store,clip:c,selection:$selection)}
        case .temporal:
            if c.temporalMotion != nil{TemporalMotionControls(store:store,clip:c,onSelect:{pick(.property($0),c)});Button(L("ブラー・残像を削除")){attempt{try store.mutateMotion(c.id){$0.animation?.tracks.removeAll{$0.property.isTemporal};$0.temporalMotion=nil};selection=nil;tab = .keyframes}}}
            else{Button(L("モーションブラーを追加")){addTemporal(c,trails:false)};Button(L("残像を追加")){addTemporal(c,trails:true)}}
        case .effects:EffectStackControls(store:store,clip:c)
        case .spatial:SpatialAnimationControls(store:store,clip:c,focusedKeyID:chosenLane == .spatial ? selection?.keyID:nil,timelineMode:true)
        case .paths:BezierShapeControls(store:store,clip:c,targetID:{switch chosenLane{case .shape(let id)?,.trim(let id,_)? :return id;default:return nil}}(),onSelectLane:{pick($0,c)})
        case .characters:CharacterAnimationControls(store:store,clip:c)
        case .custom:CustomAnimationControls(store:store,clip:c)
        case .intervals:AnimationInspectorView(store:store,clip:c,section:.keyframes)
        case .entrances:AnimationInspectorView(store:store,clip:c,section:.entrances)
        case .motions:AnimationInspectorView(store:store,clip:c,section:.motions)
        case .audio:AudioFadeControls(store:store,clip:c)
        case .transition:SceneTransitionControls(store:store,clip:c)
        case .psd:PSDAnimationControls(store:store,clip:c,selection:$selection)
        case .reactive:AudioReactiveControls(store:store,clip:c)
        case .tracking:MotionTrackingControls(store:store,clip:c)
    }}
    private var zoomControl:some View {HStack(spacing:6){Text(L("時間軸の拡大"));Slider(value:$timelineZoom,in:1...32).frame(minWidth:60,idealWidth:100).accessibilityLabel(L("時間軸の拡大"));Text(String(format:"%.1f×",timelineZoom)).monospacedDigit()}}
    private var positionControl:some View {HStack(spacing:6){Text(L("表示位置"));Slider(value:$timelinePosition,in:0...1).frame(minWidth:60,idealWidth:100).disabled(timelineZoom<=1).accessibilityLabel(L("表示位置"))}}
    private var zoomReset:some View {Button(L("時間軸を全体表示")){timelineZoom=1;timelinePosition=0}.disabled(timelineZoom<=1)}
    private func timeline(_ c:Clip)->some View{VStack(alignment:.leading,spacing:6){HStack{Text(L("キーフレーム")).fontWeight(.semibold);if let lane=chosenLane{Text(lane.title(c)).foregroundColor(.secondary);Spacer();Button(L("現在位置にキーを追加")){attempt{let key=try store.insertAnimationKey(c.id,lane:lane,at:c.motionTime(at:store.playhead));selection=MotionSelection(time:key.time,property:{if case .property(let p)=lane{return p};return nil}(),psdKeyID:lane == .psd ? key.id:nil,lane:lane,keyID:key.id)}}.disabled(!lane.canKeyframe)}else{Spacer();Text(L("行を選んで項目を指定")).foregroundColor(.secondary)}}
        ViewThatFits(in:.horizontal) {
            HStack(spacing:8) {zoomControl;positionControl;zoomReset}.fixedSize(horizontal:true,vertical:false)
            VStack(alignment:.leading,spacing:4) {HStack {zoomControl;zoomReset};positionControl}
        }.vmmFont(size:12)
        UnifiedAnimationTimeline(store:store,clip:c,selection:$selection,onSelect:focus,allKeys:allKeys,zoom:timelineZoom,position:timelinePosition,rulerOnly:true).frame(height:30)
        ScrollView(.vertical){UnifiedAnimationTimeline(store:store,clip:c,selection:$selection,onSelect:focus,allKeys:allKeys,zoom:timelineZoom,position:timelinePosition,showRuler:false).frame(height:max(70,Double(c.animationLanes.count)*max(32,store.settings.textPoints+18)))}
        Text(L("◆をドラッグで移動 · ダブルクリックで追加 · 右クリックで複製／削除 · ⌥←／→で1フレーム移動")).vmmFont(size:12).foregroundColor(.secondary)
    }.padding(12).background(Color.primary.opacity(0.025))}
}
struct KeyframeGraph: View {
    @ObservedObject var store:EditorStore
    let clip:Clip
    let track:AnimationTrack
    var body:some View {PlaybackContent(clock:store.playbackClock){_ in content}}
    private var content:some View {
        let start=clip.animationTimeOffset,end=start+clip.duration
        let values=track.keys.map(\.value)+[track.property.get(clip)]
        let low=values.min() ?? 0,high=values.max() ?? 1,span=max(0.01,high-low)
        return VStack(spacing:3) {
            GeometryReader { g in
                ZStack {
                    Rectangle().fill(Color.black.opacity(0.18))
                    Path { path in
                        for i in 0...100 {
                            let t=start+Double(i)/100*(end-start)
                            let value=interpolate(track.keys,at:t,fallback:track.property.get(clip))
                            let point=CGPoint(x:Double(i)/100*g.size.width,y:8+(1-(value-low)/span)*(g.size.height-16))
                            if i == 0 {path.move(to:point)} else {path.addLine(to:point)}
                        }
                    }.stroke(Color.cyan,lineWidth:1.5)
                    Rectangle().fill(Color.orange).frame(width:1)
                        .position(x:max(0,min(1,(clip.motionTime(at:store.playhead)-start)/clip.duration))*g.size.width,y:g.size.height/2)
                    ForEach(track.keys.filter{$0.time>=start && $0.time<=end}) { key in
                        Button {store.seek(clip.start+key.time-start)} label: {UIIcon(systemName:"diamond.fill").foregroundColor(.cyan).vmmFont(size:12).frame(width:18,height:18)}.buttonStyle(.borderless)
                            .position(x:(key.time-start)/clip.duration*g.size.width,y:8+(1-(key.value-low)/span)*(g.size.height-16))
                            .help(String(format:"%.3f秒の中間点へ移動",key.time))
                            .accessibilityLabel("\(track.property.title)の中間点 \(String(format:"%.3f",key.time))秒")
                    }
                }.clipped()
            }.frame(height:70)
            HStack {Text(String(format:"%.2f秒",start));Spacer();Text(L("◆ をクリックして移動"));Spacer();Text(String(format:"%.2f秒",end))}.vmmFont(size:12).foregroundColor(.secondary)
        }
    }
}
