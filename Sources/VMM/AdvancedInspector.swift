import SwiftUI
import AppKit

struct AdvancedInspector:View {
    @ObservedObject var store:EditorStore
    let clip:Clip
    var body:some View {
        VStack(alignment:.leading,spacing:12) {

            if ![.audio,.transition].contains(clip.kind) {
                if store.project.camera3D?.enabled == true && clip.parentID == nil {
                    NumberInput(title:"3D奥行き",value:Binding(get:{clip.cameraDepth ?? 0},set:{value in store.edit(clip.id){$0.cameraDepth=value}}),range:-8...8)
                }
                VMMMenuPicker(L("合成モード"),selection:Binding(get:{clip.blendMode ?? .normal},set:{v in store.edit(clip.id){$0.blendMode=v}})) {
                    VMMOptions(CompositeMode.allCases,id:\.self) {VMMChoice(text:L($0.title),value:$0)}
                }
                MaskControls(store:store,clip:clip)
                if clip.kind != .adjustment {TransformControls(store:store,clip:clip)}
            }
            if clip.kind == .particles {ParticleControls(store:store,clip:clip)}
            if [.audio,.video,.speech].contains(clip.kind) {EqualizerControls(store:store,clip:clip)}
            if clip.kind == .adjustment {
                VMMMenuPicker(L("調整の対象"),selection:Binding(get:{clip.adjustmentOwnLayer ?? false},set:{v in store.edit(clip.id){$0.adjustmentOwnLayer=v}})) {
                    VMMChoice(text:L("下のレイヤーと直前のアイテム"),value:false);VMMChoice(text:L("同じレイヤーの直前のアイテム"),value:true)
                }
                Text(L("開始・長さの範囲で作用します。手前のアイテムは影響を受けません。")).vmmFont(size:12).foregroundColor(.secondary)
            }
        }
    }
}
struct ParentControls:View {
    @ObservedObject var store:EditorStore;let clip:Clip
    var body:some View {
        PanelDisclosure(L("親子関係・グループ制御")) {
            VStack(alignment:.leading,spacing:8) {
                VMMMenuPicker(L("親アイテム"),selection:Binding(get:{clip.parentID},set:{store.setParent($0,clipID:clip.id)})) {
                    VMMChoice(text:L("なし"),value:Optional<UUID>.none)
                    VMMOptions(store.project.clips.filter {$0.supportsParent && $0.id != clip.id && !store.project.descendants(of:clip.id).contains($0.id)}) {VMMChoice(text:$0.name,value:Optional($0.id))}
                }
                Text(L("子の位置は画面座標で指定します。親の50%位置・100%拡大が基準で、親の変形・不透明度・表示範囲・エフェクトをまとめて適用します。親を解除すると子の元の設定に戻ります。")).vmmFont(size:12).foregroundColor(.secondary)
                if clip.kind == .group {Text("子アイテム：\(store.project.clips.filter {$0.parentID==clip.id}.count)個").foregroundColor(.secondary)}
                Button(L("同じレイヤーのアイテムをグループ化")) {store.selectedTrack=clip.track;store.groupSelectedLayer()}
            }.padding(.top,8)
        }
    }
}
struct TransformControls:View {
    @ObservedObject var store:EditorStore;let clip:Clip
    func binding<T>(_ key:WritableKeyPath<Transform2D,T>)->Binding<T> {store.advancedBinding(clip.id,\.transform,key,default:Transform2D())}
    var body:some View {
        PanelDisclosure(L("詳細な変形")) {
            VStack(spacing:8) {
                NumberInput(title:"横の拡大率",value:binding(\.scaleX),range:0.01...10,percent:true)
                NumberInput(title:"縦の拡大率",value:binding(\.scaleY),range:0.01...10,percent:true)
                NumberInput(title:"横の傾斜",value:binding(\.skewX),range:-75...75,unit:"°")
                NumberInput(title:"縦の傾斜",value:binding(\.skewY),range:-75...75,unit:"°")
                Toggle(L("四隅の透視変形"),isOn:binding(\.perspective))
                if clip.transform?.perspective == true {
                    ForEach(0..<4,id:\.self) {i in
                        Text(["左上","右上","右下","左下"][i]).foregroundColor(.secondary)
                        point(i,\.x,title:"X");point(i,\.y,title:"Y")
                    }
                    Text(L("変形前の画面座標に対する四隅です。交差する値は適用できません。")).vmmFont(size:12).foregroundColor(.secondary)
                }
                Button(L("変形をリセット")) {store.edit(clip.id){$0.transform=nil}}
            }.padding(.top,8)
        }
    }
    func point(_ i:Int,_ key:WritableKeyPath<NormalizedPoint,Double>,title:String)->some View {
        NumberInput(title:title,value:Binding(get:{(clip.transform ?? Transform2D()).corners[i][keyPath:key]},set:{v in
            var candidate=store.project.clips.first{$0.id==clip.id} ?? clip
            var t=candidate.transform ?? Transform2D();t.corners[i][keyPath:key]=v;candidate.transform=t
            do {try candidate.validateAdvanced(project:store.project);store.edit(clip.id){$0.transform=t}}
            catch {store.status=error.localizedDescription}
        }),range:-2...3,percent:true)
    }
}
struct MaskControls:View {
    @ObservedObject var store:EditorStore;let clip:Clip
    var body:some View {
        PanelDisclosure(L("マスク")) {
            VStack(alignment:.leading,spacing:8) {
                Menu(L("マスクを追加")) {ForEach(MaskKind.allCases,id:\.self) {kind in Button(kind.title) {store.edit(clip.id){c in var list=c.masks ?? [];if list.count<8 {list.append(ClipMask(kind:kind))};c.masks=list}}}}
                Text(L("マスクはアイテムの変形前に適用します。複数のマスクは交差部分を残します。画像は透明部分を抜きます。")).vmmFont(size:12).foregroundColor(.secondary)
                ForEach(clip.masks ?? []) {mask in MaskRow(store:store,clip:clip,mask:mask)}
            }.padding(.top,8)
        }
    }
}
struct MaskRow:View {
    @ObservedObject var store:EditorStore;let clip:Clip;let mask:ClipMask
    func binding<T>(_ key:WritableKeyPath<ClipMask,T>)->Binding<T> {
        Binding(get:{(store.project.clips.first{$0.id==clip.id}?.masks?.first{$0.id==mask.id} ?? mask)[keyPath:key]},set:{v in store.edit(clip.id){c in guard let i=c.masks?.firstIndex(where:{$0.id==mask.id}) else{return};c.masks?[i][keyPath:key]=v}})
    }
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            HStack {Toggle(mask.kind.title,isOn:binding(\.enabled));Spacer();Button {store.edit(clip.id){$0.masks?.removeAll{$0.id==mask.id}}} label:{UIIcon(systemName:"trash")}.buttonStyle(.borderless)}
            Toggle(L("反転して外側を残す"),isOn:binding(\.inverted))
            NumberInput(title:"中心X",value:binding(\.x),range:-2...3,percent:true)
            NumberInput(title:"中心Y",value:binding(\.y),range:-2...3,percent:true)
            NumberInput(title:"幅",value:binding(\.width),range:0.001...4,percent:true)
            NumberInput(title:"高さ",value:binding(\.height),range:0.001...4,percent:true)
            NumberInput(title:"境界のぼかし",value:binding(\.feather),range:0...200,unit:"px")
            if mask.kind == .image {
                VMMMenuPicker(L("マスク画像"),selection:binding(\.assetID)) {VMMChoice(text:L("選択してください"),value:Optional<UUID>.none);VMMOptions(store.libraryAssets.filter{$0.kind == .image}) {VMMChoice(text:$0.name,value:Optional($0.id))}}
            }
            if mask.kind == .polygon {
                ForEach(Array(mask.points.enumerated()),id:\.offset) {index,point in
                    Text("頂点\(index+1)").foregroundColor(.secondary)
                    pointInput(index,\.x,title:"X");pointInput(index,\.y,title:"Y")
                }
                HStack {
                    Button(L("頂点を追加")) {store.edit(clip.id){c in guard let i=c.masks?.firstIndex(where:{$0.id==mask.id}),c.masks![i].points.count<32 else{return};c.masks?[i].points.append(NormalizedPoint(x:0.5,y:0.5))}}
                    Button(L("最後の頂点を削除")) {store.edit(clip.id){c in guard let i=c.masks?.firstIndex(where:{$0.id==mask.id}),c.masks![i].points.count>3 else{return};c.masks?[i].points.removeLast()}}
                }.vmmFont(size:12)
            }
        }.padding(8).background(Color.primary.opacity(0.04)).cornerRadius(5)
    }
    func pointInput(_ i:Int,_ key:WritableKeyPath<NormalizedPoint,Double>,title:String)->some View {
        NumberInput(title:title,value:Binding(get:{mask.points[i][keyPath:key]},set:{v in store.edit(clip.id){c in guard let m=c.masks?.firstIndex(where:{$0.id==mask.id}),c.masks![m].points.indices.contains(i) else{return};c.masks?[m].points[i][keyPath:key]=v}}),range:-2...3,percent:true)
    }
}
struct ParticleControls:View {
    @ObservedObject var store:EditorStore;let clip:Clip
    func binding<T>(_ key:WritableKeyPath<ParticleSettings,T>)->Binding<T> {store.advancedBinding(clip.id,\.particles,key,default:ParticleSettings())}
    var body:some View {
        PanelDisclosure(L("パーティクル設定")) {
            VStack(alignment:.leading,spacing:8) {
                Menu(L("パーティクルプリセット")) {
                    Button(L("火の粉")) {var s=ParticleSettings();s.gravity = -0.08;s.endColor="FF3300";apply(s,"FFDD33",y:0.8)}
                    Button(L("雪")) {var s=ParticleSettings();s.angle=90;s.spread=25;s.emitterWidth=2;s.velocity=0.1;s.gravity=0;s.lifetime=8;s.size=8;s.endColor="FFFFFF";apply(s,"FFFFFF",y:0)}
                    Button(L("紙吹雪")) {var s=ParticleSettings();s.shape = .square;s.spread=180;s.gravity=0.4;s.burst=true;s.velocity=0.45;s.count=200;s.lifetime=4;s.endColor="DD55FF";apply(s,"FFDD33")}
                }
                VMMMenuPicker(L("形"),selection:binding(\.shape)) {VMMOptions(ParticleShape.allCases,id:\.self){VMMChoice(text:L($0.title),value:$0)}}
                NumberInput(title:"粒子数",value:Binding(get:{Double((clip.particles ?? ParticleSettings()).count)},set:{binding(\.count).wrappedValue=Int($0)}),range:1...1000)
                NumberInput(title:"寿命",value:binding(\.lifetime),range:0.1...30,step:0.1,unit:"秒")
                NumberInput(title:"速度（画面/秒）",value:binding(\.velocity),range:0...3,percent:true)
                NumberInput(title:"方向",value:binding(\.angle),range:-360...360,unit:"°")
                NumberInput(title:"広がり",value:binding(\.spread),range:0...360,unit:"°")
                NumberInput(title:"重力（画面/秒²）",value:binding(\.gravity),range:-3...3,percent:true)
                NumberInput(title:"粒の大きさ",value:binding(\.size),range:1...200,unit:"px")
                NumberInput(title:"発生範囲の幅",value:binding(\.emitterWidth),range:0...3,percent:true)
                NumberInput(title:"発生範囲の高さ",value:binding(\.emitterHeight),range:0...3,percent:true)
                Toggle(L("先頭で一度に発生"),isOn:binding(\.burst))
                ColorPicker(L("終わりの色"),selection:Binding(get:{Color(nsColor:NSColor(hex:binding(\.endColor).wrappedValue))},set:{binding(\.endColor).wrappedValue=NSColor($0).hex}),supportsOpacity:false)
                NumberInput(title:"ランダム種",value:Binding(get:{Double((clip.particles ?? ParticleSettings()).seed)},set:{binding(\.seed).wrappedValue=UInt64($0)}),range:0...999999)
            }.padding(.top,8)
        }
    }
    func apply(_ settings:ParticleSettings,_ color:String,y:Double=0.5) {store.edit(clip.id){$0.particles=settings;$0.color=color;$0.y=y}}
}
struct MediaTimingControls:View {
    @ObservedObject var store:EditorStore;let clip:Clip
    var body:some View {
        RhythmClipControls(store:store,clip:clip)
        PanelDisclosure(L("再生速度")) {
            VStack(alignment:.leading,spacing:8) {
                Toggle(L("逆再生"),isOn:Binding(get:{clip.reversed == true},set:{v in store.edit(clip.id){$0.reversed=v ? true:nil}}))
                Toggle(L("速度を変化させる"),isOn:Binding(get:{clip.speedPoints != nil},set:{v in
                    store.edit(clip.id){c in c.speedPoints=v ? [.init(time:0,rate:c.mediaRate),.init(time:c.duration,rate:c.mediaRate)]:nil}
                }))
                if let points=clip.speedPoints,let first=points.first,let last=points.last {
                    NumberInput(title:"開始速度",value:Binding(get:{first.rate},set:{setRamp($0,last.rate)}),range:0.25...4,percent:true)
                    NumberInput(title:"終了速度",value:Binding(get:{last.rate},set:{setRamp(first.rate,$0)}),range:0.25...4,percent:true)
                    Text(L("速度に応じて音の高さも変化します。" )).vmmFont(size:12).foregroundColor(.secondary)
                } else {
                    NumberInput(title:"速度",value:Binding(get:{clip.mediaRate},set:{store.setMediaRate($0,clipID:clip.id)}),range:0.25...4,percent:true)
                    if clip.reversed == true {
                        Text(L("逆再生中は速度に応じて音の高さも変化します。" )).vmmFont(size:12).foregroundColor(.secondary)
                    } else {
                        Toggle(L("音声の高さを維持"),isOn:Binding(get:{clip.preservePitch ?? true},set:{v in store.edit(clip.id){$0.preservePitch=v}}))
                    }
                }
                Text(L("速度を変えると素材の使用区間を保って長さを調整します。VOICEVOXの話速とは別に、生成済み音声にも作用します。")).vmmFont(size:12).foregroundColor(.secondary)
            }.padding(.top,8)
        }
    }
    func setRamp(_ start:Double,_ end:Double) {
        let length=clip.duration*(start+end)/2
        if let asset=store.project.asset(for:clip),clip.sourceOffset+length>asset.duration+0.000001 {
            store.error="速度を変更すると素材の末尾を超えます。アイテムを短くしてから設定してください。";return
        }
        store.edit(clip.id){$0.speedPoints=[.init(time:0,rate:start),.init(time:$0.duration,rate:end)]}
    }
}
struct EqualizerControls:View {
    @ObservedObject var store:EditorStore;let clip:Clip
    var body:some View {
        PanelDisclosure(L("イコライザー")) {
            VStack(spacing:8) {
                Toggle(L("EQを有効にする"),isOn:Binding(get:{clip.equalizer?.enabled ?? false},set:{v in store.edit(clip.id){c in var eq=c.equalizer ?? Equalizer();eq.enabled=v;c.equalizer=eq}}))
                ForEach(clip.equalizer?.bands ?? Equalizer().bands) {band in EQBandControls(store:store,clipID:clip.id,band:band)}
                Button(L("帯域を追加")) {store.edit(clip.id){c in var eq=c.equalizer ?? Equalizer();if eq.bands.count<10 {eq.bands.append(EQBand(frequency:1000))};c.equalizer=eq}}
                Button(L("EQをリセット")) {store.edit(clip.id){$0.equalizer=Equalizer()}}
            }.padding(.top,8)
        }.onAppear { }
    }
}
struct EQBandControls:View {
    @ObservedObject var store:EditorStore;let clipID:UUID;let band:EQBand
    func binding(_ key:WritableKeyPath<EQBand,Double>)->Binding<Double> {
        Binding(get:{(store.project.clips.first{$0.id==clipID}?.equalizer?.bands.first{$0.id==band.id} ?? band)[keyPath:key]},set:{v in store.edit(clipID){c in
            // Defaults have fresh UUIDs until the first edit. Match frequency in that case.
            var eq=c.equalizer ?? Equalizer();guard let i=eq.bands.firstIndex(where:{$0.id==band.id || (c.equalizer==nil && $0.frequency==band.frequency)}) else{return}
            eq.bands[i][keyPath:key]=v;c.equalizer=eq
        }})
    }
    var body:some View {
        VStack(spacing:6) {
            HStack {
                Text(L("EQ帯域")).foregroundColor(.secondary);Spacer()
                Button {store.edit(clipID){c in var eq=c.equalizer ?? Equalizer();guard eq.bands.count>1,let i=eq.bands.firstIndex(where:{$0.id==band.id || (c.equalizer==nil && $0.frequency==band.frequency)}) else{return};eq.bands.remove(at:i);c.equalizer=eq}} label:{UIIcon(systemName:"trash")}.buttonStyle(.borderless)
            }
            NumberInput(title:"周波数",value:binding(\.frequency),range:20...20000,step:10,unit:"Hz")
            NumberInput(title:"ゲイン",value:binding(\.gain),range:-24...24,step:0.5,unit:"dB")
            NumberInput(title:"帯域幅",value:binding(\.bandwidth),range:0.1...5,step:0.1,unit:"oct")
        }.padding(8).background(Color.primary.opacity(0.04)).cornerRadius(5)
    }
}
