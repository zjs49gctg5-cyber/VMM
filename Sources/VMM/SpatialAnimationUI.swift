import SwiftUI

struct SpatialAnimationControls:View {
    @ObservedObject var store:EditorStore;let clip:Clip
    var focusedKeyID:UUID?=nil;var timelineMode=false
    @State private var selected:UUID?
    private func change(_ body:(inout Clip)throws->Void){do{try store.mutateMotion(clip.id,body)}catch{store.error=error.localizedDescription}}
    private func pointBinding(_ id:UUID,_ field:Int)->Binding<Double> {Binding(get:{guard let key=clip.spatialAnimation?.keys.first(where:{$0.id==id}) else{return 0};return field==0 ? key.point.x:key.point.y},set:{v in change{c in guard let i=c.spatialAnimation?.keys.firstIndex(where:{$0.id==id}) else{return};if field==0{c.spatialAnimation!.keys[i].point.x=v}else{c.spatialAnimation!.keys[i].point.y=v}}})}
    var body:some View {VStack(alignment:.leading,spacing:12){
        Text(L("移動パス・支点")).fontWeight(.semibold)
        VStack{NumberInput(title:"支点 X",value:Binding(get:{clip.anchorPoint?.x ?? 0.5},set:{v in change{$0.anchorPoint=NormalizedPoint(x:v,y:clip.anchorPoint?.y ?? 0.5)}}),range:-2...3,percent:true)
            NumberInput(title:"支点 Y",value:Binding(get:{clip.anchorPoint?.y ?? 0.5},set:{v in change{$0.anchorPoint=NormalizedPoint(x:clip.anchorPoint?.x ?? 0.5,y:v)}}),range:-2...3,percent:true)
            Button(L("中央に戻す")){change{$0.anchorPoint=nil}}
        }
        Text(L("50%が素材の中心です。上部の「支点を編集」を有効にし、橙色の支点をドラッグすると、見た目の位置を保って変更します。")).foregroundColor(.secondary)
        if let path=clip.spatialAnimation {
            Toggle(L("進行方向へ回転"),isOn:Binding(get:{path.orientToPath},set:{v in change{$0.spatialAnimation?.orientToPath=v}}))
            HStack{Button(L("現在位置に点を追加")){change{c in var p=c.spatialAnimation!;let t=min(c.motionEnd,max(c.motionStart,(c.motionTime(at:store.playhead)*Double(store.project.fps)).rounded()/Double(store.project.fps)));guard !p.keys.contains(where:{abs($0.time-t)<0.000001}) else{throw VMMError.message("この時刻には点があります。")};p.insertPoint(at:t);c.spatialAnimation=p}}
                Button(L("パスを解除")){change{c in let pos=c.spatialAnimation!.sample(at:c.motionTime(at:store.playhead)).point;c.x=pos.x;c.y=pos.y;c.spatialAnimation=nil}}
            }
            Text(L("丸い点は位置、四角い点は曲線のハンドルです。パス設定中はX/Yのキーフレームよりパスが優先されます。")).foregroundColor(.secondary)
            if timelineMode && focusedKeyID==nil{Text(L("下の移動パスの◆を選択して、点とハンドルを編集してください。")).foregroundColor(.secondary)}
            ForEach(path.keys.filter{!timelineMode || $0.id==focusedKeyID}.sorted{$0.time<$1.time}){key in
                VStack(alignment:.leading,spacing:5){
                    HStack{Button(String(format:"%.3f s",key.time-clip.motionStart)){selected=key.id;store.seek(clip.start+key.time-clip.motionStart)};Spacer();if path.keys.count>2{Button(L("削除")){change{$0.spatialAnimation?.keys.removeAll{$0.id==key.id}}}}}
                    VStack{NumberInput(title:"時刻",value:Binding(get:{key.time-clip.motionStart},set:{v in change{c in guard let i=c.spatialAnimation?.keys.firstIndex(where:{$0.id==key.id}) else{return};let t=c.motionStart+(v*Double(store.project.fps)).rounded()/Double(store.project.fps);guard !c.spatialAnimation!.keys.contains(where:{$0.id != key.id && abs($0.time-t)<0.000001}) else{throw VMMError.message("同じ時刻に点があります。")};c.spatialAnimation!.keys[i].time=t;c.spatialAnimation!.keys.sort{$0.time<$1.time}}}),range:0...clip.duration,unit:"秒");NumberInput(title:"X",value:pointBinding(key.id,0),range:-2...3,percent:true);NumberInput(title:"Y",value:pointBinding(key.id,1),range:-2...3,percent:true)}
                    VMMMenuPicker(L("補間"),selection:Binding(get:{key.easing},set:{v in change{c in if let i=c.spatialAnimation?.keys.firstIndex(where:{$0.id==key.id}){c.spatialAnimation!.keys[i].easing=v}}})){VMMOptions(Easing.allCases,id:\.self){VMMChoice(text:L($0.title),value:$0)}}
                    Button(L("この点のハンドルをリセット")){change{c in if let i=c.spatialAnimation?.keys.firstIndex(where:{$0.id==key.id}){c.spatialAnimation!.keys[i].incoming=NormalizedPoint(x:0,y:0);c.spatialAnimation!.keys[i].outgoing=NormalizedPoint(x:0,y:0)}}}
                }.padding(8).background(selected==key.id ? Color.cyan.opacity(0.1):Color.primary.opacity(0.025)).cornerRadius(6)
            }
        }else{Button(L("曲線の移動パスを作成")){change{c in let a=c.animated(at:c.start),b=c.animated(at:c.end);c.spatialAnimation=SpatialAnimation(keys:[SpatialKey(time:c.motionStart,point:NormalizedPoint(x:a.x,y:a.y)),SpatialKey(time:c.motionEnd,point:NormalizedPoint(x:b.x==a.x ? min(1,a.x+0.3):b.x,y:b.y))],orientationAspect:Double(store.project.width)/Double(store.project.height))}}}
    }}
}
struct EditableSpatialOverlay:View {
    @ObservedObject var store:EditorStore;let clip:Clip
    @State private var dragging:UUID?;@State private var field=0;@State private var draft:SpatialAnimation?
    var body:some View {GeometryReader{g in
        if let path=draft ?? clip.spatialAnimation,let parent=PreviewGeometry().parentTransform(clip,project:store.project,time:store.playhead) {
            let transform=CGAffineTransform(scaleX:Double(store.project.width),y:Double(store.project.height)).concatenating(parent).concatenating(CGAffineTransform(scaleX:g.size.width/Double(store.project.width),y:g.size.height/Double(store.project.height)))
            ZStack{
                Path{p in let keys=path.keys.sorted{$0.time<$1.time};if let first=keys.first{p.move(to:CGPoint(x:first.point.x,y:first.point.y).applying(transform))};for (a,b) in zip(keys,keys.dropFirst()){p.addCurve(to:CGPoint(x:b.point.x,y:b.point.y).applying(transform),control1:CGPoint(x:a.point.x+a.outgoing.x,y:a.point.y+a.outgoing.y).applying(transform),control2:CGPoint(x:b.point.x+b.incoming.x,y:b.point.y+b.incoming.y).applying(transform))}}.stroke(Color.orange,lineWidth:2).allowsHitTesting(false)
                ForEach(path.keys){key in
                    Path{p in p.move(to:CGPoint(x:key.point.x+key.incoming.x,y:key.point.y+key.incoming.y).applying(transform));p.addLine(to:CGPoint(x:key.point.x,y:key.point.y).applying(transform));p.addLine(to:CGPoint(x:key.point.x+key.outgoing.x,y:key.point.y+key.outgoing.y).applying(transform))}.stroke(Color.orange.opacity(0.5),lineWidth:1).allowsHitTesting(false)
                    ForEach(0..<3,id:\.self){f in
                        let delta=f==1 ? key.incoming:f==2 ? key.outgoing:NormalizedPoint(x:0,y:0),point=CGPoint(x:key.point.x+delta.x,y:key.point.y+delta.y).applying(transform)
                        Image(systemName:f==0 ? "circle.fill":"square.fill").foregroundColor(f==0 ? .orange:.white).frame(width:22,height:22).contentShape(Rectangle()).position(point)
                            .onTapGesture{if f==0{store.seek(clip.start+key.time-clip.motionStart)}}
                            .onHover{if $0{NSCursor.crosshair.set()}else{NSCursor.arrow.set()}}
                            .gesture(DragGesture(minimumDistance:1,coordinateSpace:.named("spatialCanvas")).onChanged{v in
                                guard !store.busy,!store.playing,!store.project.tracks[clip.track].locked else{return}
                                if dragging==nil{dragging=key.id;field=f;draft=clip.spatialAnimation}
                                guard let i=draft?.keys.firstIndex(where:{$0.id==key.id}) else{return}
                                let local=v.location.applying(transform.inverted())
                                if f==0{draft!.keys[i].point=NormalizedPoint(x:min(3,max(-2,local.x)),y:min(3,max(-2,local.y)))}else{let d=NormalizedPoint(x:min(4,max(-4,local.x-key.point.x)),y:min(4,max(-4,local.y-key.point.y)));if f==1{draft!.keys[i].incoming=d}else{draft!.keys[i].outgoing=d}}
                            }.onEnded{_ in defer{draft=nil;dragging=nil};guard let draft else{return};do{try store.mutateMotion(clip.id){$0.spatialAnimation=draft}}catch{store.error=error.localizedDescription}})
                            .help(f==0 ? L("位置をドラッグ"):L("曲線のハンドルをドラッグ"))
                    }
                }
            }.coordinateSpace(name:"spatialCanvas")
        }
    }}
}
