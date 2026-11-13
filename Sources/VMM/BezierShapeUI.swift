import SwiftUI

struct BezierShapeControls:View {
    @ObservedObject var store:EditorStore;let clip:Clip
    var targetID:UUID?=nil;var onSelectLane:((AnimationLane)->Void)?=nil
    @State private var target="shape";@State private var selected=0;@State private var field=0
    @State private var draft:AnimatedBezierShape?
    private var mask:ClipMask?{clip.masks?.first{$0.id.uuidString==target}}
    private var path:AnimatedBezierShape?{target=="shape" ? clip.shapeStyle?.path:mask?.path}
    private var time:Double{min(clip.motionEnd,max(clip.motionStart,clip.motionTime(at:store.playhead)))}
    private var keyIndex:Int{let keys=(draft ?? path)?.keys ?? [];return keys.indices.filter{keys[$0].time<=time+0.000001}.max(by:{keys[$0].time<keys[$1].time}) ?? keys.indices.min(by:{keys[$0].time<keys[$1].time}) ?? 0}
    private func update(_ body:(inout AnimatedBezierShape)throws->Void){do{try store.mutateMotion(clip.id){c in var p=path ?? AnimatedBezierShape();if path==nil{p.keys[0].time=clip.motionStart};try body(&p);try p.validated();if target=="shape"{var style=c.shapeStyle ?? ShapeStyle();style.path=p;c.shapeStyle=style}else if let i=c.masks?.firstIndex(where:{$0.id.uuidString==target}){c.masks![i].path=p}}}catch{store.error=error.localizedDescription}}
    private func coordinate(_ axis:Int)->Binding<Double>{Binding(get:{guard let p=path,p.keys.indices.contains(keyIndex),p.keys[keyIndex].vertices.indices.contains(selected) else{return 0};let v=p.keys[keyIndex].vertices[selected],point=field==1 ? v.incoming:field==2 ? v.outgoing:v.point;return axis==0 ? point.x:point.y},set:{value in update{p in guard p.keys[keyIndex].vertices.indices.contains(selected) else{return};if field==0{if axis==0{p.keys[keyIndex].vertices[selected].point.x=value}else{p.keys[keyIndex].vertices[selected].point.y=value}}else if field==1{if axis==0{p.keys[keyIndex].vertices[selected].incoming.x=value}else{p.keys[keyIndex].vertices[selected].incoming.y=value}}else{if axis==0{p.keys[keyIndex].vertices[selected].outgoing.x=value}else{p.keys[keyIndex].vertices[selected].outgoing.y=value}}}})}
    var body:some View{VStack(alignment:.leading,spacing:12){
        Text(L("図形・マスクのベジェパス")).fontWeight(.semibold)
        VMMMenuPicker(L("編集対象"),selection:Binding(get:{target},set:{target=$0;onSelectLane?(.shape(UUID(uuidString:$0)))})){if clip.kind == .shape{VMMChoice(text:L("図形"),value:"shape")};VMMOptions(clip.masks ?? [],id:\.id){m in VMMChoice(text:L("マスク")+" · "+String(m.id.uuidString.prefix(6)),value:m.id.uuidString)}}
        HStack{Button(L("パスマスクを追加")){do{var m=ClipMask();m.path=AnimatedBezierShape();m.path?.keys[0].time=clip.motionStart;try store.mutateMotion(clip.id){$0.masks=($0.masks ?? [])+[m]};target=m.id.uuidString;onSelectLane?(.shape(m.id))}catch{store.error=error.localizedDescription}};if path==nil{Button(L("パスを作成")){update{_ in}}}else{Button(L("パスを解除")){do{try store.mutateMotion(clip.id){c in if target=="shape"{c.shapeStyle?.path=nil}else if let i=c.masks?.firstIndex(where:{$0.id.uuidString==target}){c.masks?[i].path=nil}}}catch{store.error=error.localizedDescription}}}}
        if let p=draft ?? path {
            editor(p).frame(height:280).background(Color.black.opacity(0.25)).cornerRadius(8)
            Text(L("丸い点と四角いハンドルをドラッグ。空白をダブルクリックして点を追加します。形の中間点を選ぶとその形を編集します。")).foregroundColor(.secondary)
            if target=="shape"{Toggle(L("閉じたパス"),isOn:Binding(get:{p.closed},set:{v in update{$0.closed=v}}))}
            HStack{Button(L("現在位置に形の中間点")){update{p in guard !p.keys.contains(where:{abs($0.time-time)<0.000001}) else{return};p.keys.append(BezierShapeKey(time:time,vertices:p.vertices(at:time)));p.keys.sort{$0.time<$1.time}}};Button(L("選択点を削除")){update{p in guard p.keys[0].vertices.count>2 else{return};for i in p.keys.indices{p.keys[i].vertices.remove(at:selected)};selected=max(0,selected-1)}}}
            VMMMenuPicker(L("編集する形"),selection:Binding(get:{p.keys[keyIndex].id},set:{id in if let key=p.keys.first(where:{$0.id==id}){store.seek(clip.start+key.time-clip.motionStart)}})){VMMOptions(p.keys,id:\.id){k in VMMChoice(text:String(format:"%.3f s",k.time-clip.motionStart),value:k.id)}}
            if keyIndex>0{Button(L("この形の中間点を削除")){update{$0.keys.remove(at:keyIndex)}}}
            VMMMenuPicker(L("補間"),selection:Binding(get:{p.keys[keyIndex].easing},set:{v in update{$0.keys[keyIndex].easing=v}})){VMMOptions(Easing.allCases,id:\.self){VMMChoice(text:L($0.title),value:$0)}}
            Button(L("選択点の曲線ハンドルを作成")){update{p in for k in p.keys.indices{let vertices=p.keys[k].vertices,previous=vertices[(selected+vertices.count-1)%vertices.count].point,next=vertices[(selected+1)%vertices.count].point,point=vertices[selected].point;p.keys[k].vertices[selected].incoming=NormalizedPoint(x:(previous.x-point.x)/4,y:(previous.y-point.y)/4);p.keys[k].vertices[selected].outgoing=NormalizedPoint(x:(next.x-point.x)/4,y:(next.y-point.y)/4)}}}
            VMMMenuPicker(L("点・ハンドル"),selection:$field){VMMChoice(text:L("点"),value:0);VMMChoice(text:L("入射ハンドル"),value:1);VMMChoice(text:L("出射ハンドル"),value:2)}
            NumberInput(title:"X",value:coordinate(0),range:-4...4,percent:true);NumberInput(title:"Y",value:coordinate(1),range:-4...4,percent:true)
            if target=="shape"{
                Text(L("線の描画範囲（縁取りを有効にしてください）")).fontWeight(.semibold)
                trimRow("開始",start:true);trimRow("終了",start:false)
                Button(L("区間全体で線を描く")){update{$0.trimStart=[];$0.trimEnd=[AnimationKeyframe(time:clip.motionStart,value:0,easing:.linear),AnimationKeyframe(time:clip.motionEnd,value:1,easing:.linear)]}}
                Button(L("線の描画範囲をリセット")){update{$0.trimStart=[];$0.trimEnd=[]}}
            }
        }
    }.onAppear{if let targetID{target=targetID.uuidString}else if clip.kind != .shape{target=clip.masks?.first?.id.uuidString ?? "none"}}.onChange(of:targetID){id in target=id?.uuidString ?? (clip.kind == .shape ? "shape":clip.masks?.first?.id.uuidString ?? "none") }.onChange(of:target){_ in selected=0;draft=nil}}
    private func trimRow(_ title:String,start:Bool)->some View{NumberInput(title:title,value:Binding(get:{interpolate(start ? path?.trimStart ?? []:path?.trimEnd ?? [],at:time,fallback:start ? 0:1)},set:{v in update{p in var keys=start ? p.trimStart:p.trimEnd;if let i=keys.firstIndex(where:{abs($0.time-time)<0.000001}){keys[i].value=v}else{keys.append(AnimationKeyframe(time:time,value:v,easing:.linear))};keys.sort{$0.time<$1.time};if start{p.trimStart=keys}else{p.trimEnd=keys}}}),range:0...1,percent:true)}
    private func editor(_ p:AnimatedBezierShape)->some View{GeometryReader{g in
        let rect=CGRect(x:24,y:24,width:g.size.width-48,height:g.size.height-48),vertices=p.keys[keyIndex].vertices
        ZStack{
            Color.clear.contentShape(Rectangle()).gesture(SpatialTapGesture(count:2).onEnded{v in update{p in guard p.keys[0].vertices.count<64 else{return};let point=NormalizedPoint(x:min(4,max(-4,(v.location.x-rect.minX)/rect.width)),y:min(4,max(-4,(v.location.y-rect.minY)/rect.height)));for i in p.keys.indices{p.keys[i].vertices.append(BezierVertex(point:point))};selected=p.keys[0].vertices.count-1}})
            Path(p.path(in:rect,time:p.keys[keyIndex].time)).stroke(Color.cyan,lineWidth:2).allowsHitTesting(false)
            ForEach(vertices.indices,id:\.self){i in let v=vertices[i]
                Path{path in path.move(to:CGPoint(x:rect.minX+(v.point.x+v.incoming.x)*rect.width,y:rect.minY+(v.point.y+v.incoming.y)*rect.height));path.addLine(to:CGPoint(x:rect.minX+v.point.x*rect.width,y:rect.minY+v.point.y*rect.height));path.addLine(to:CGPoint(x:rect.minX+(v.point.x+v.outgoing.x)*rect.width,y:rect.minY+(v.point.y+v.outgoing.y)*rect.height))}.stroke(Color.orange.opacity(0.5)).allowsHitTesting(false)
                ForEach(0..<3,id:\.self){f in let offset=f==1 ? v.incoming:f==2 ? v.outgoing:NormalizedPoint(x:0,y:0)
                    if f==0 || offset.x != 0 || offset.y != 0 {Image(systemName:f==0 ? "circle.fill":"square.fill").foregroundColor(i==selected ? .orange:.white).frame(width:22,height:22).contentShape(Rectangle()).position(x:rect.minX+(v.point.x+offset.x)*rect.width,y:rect.minY+(v.point.y+offset.y)*rect.height)
                        .onHover{if $0{NSCursor.crosshair.set()}else{NSCursor.arrow.set()}}.onTapGesture{selected=i;field=f}
                        .gesture(DragGesture(minimumDistance:1,coordinateSpace:.named("bezierEditor")).onChanged{event in if draft==nil{draft=path};selected=i;field=f;let point=NormalizedPoint(x:min(4,max(-4,(event.location.x-rect.minX)/rect.width)),y:min(4,max(-4,(event.location.y-rect.minY)/rect.height)));if f==0{draft?.keys[keyIndex].vertices[i].point=point}else{let delta=NormalizedPoint(x:min(4,max(-4,point.x-v.point.x)),y:min(4,max(-4,point.y-v.point.y)));if f==1{draft?.keys[keyIndex].vertices[i].incoming=delta}else{draft?.keys[keyIndex].vertices[i].outgoing=delta}}}.onEnded{_ in if let draft{update{$0=draft}};draft=nil})
                    }
                }
            }
        }.coordinateSpace(name:"bezierEditor")
    }}
}
