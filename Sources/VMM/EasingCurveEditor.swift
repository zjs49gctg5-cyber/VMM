import SwiftUI
import AppKit

struct MotionCurveControls:View {
    @ObservedObject var store:EditorStore
    let clipID:UUID;let property:AnimatedProperty;let time:Double;let end:Double?
    @State private var open=false
    private var saved:EasingCurve? {store.project.clips.first{$0.id==clipID}?.animation?.tracks.first{$0.property==property}?.keys.first{abs($0.time-time)<0.000001}?.customCurve}
    var body:some View {
        HStack {
            if saved != nil {Text(L("カスタムカーブ適用中")).foregroundColor(.cyan)}
            Spacer()
            Button(L("カーブ編集…")){open=true}.popover(isPresented:$open) {
                EasingCurveEditor(curve:saved ?? EasingCurve(),onApply:{curve in
                    do{try store.setMotionCurve(clipID,property:property,time:time,end:end,curve:curve);open=false}catch{store.error=error.localizedDescription}
                },onCancel:{open=false}).vmmAppearance(store.settings)
            }
            if saved != nil {Button(L("標準補間に戻す")){do{try store.setMotionCurve(clipID,property:property,time:time,end:end,curve:nil)}catch{store.error=error.localizedDescription}}}
        }
    }
}
struct EasingCurveEditor:View {
    @State var curve:EasingCurve
    let onApply:(EasingCurve?)->Void
    let onCancel:()->Void
    @State private var selected=0
    private var index:Int {min(selected,curve.parts.count-1)}
    private func field(_ key:WritableKeyPath<EasingCurveSegment,Double>)->Binding<Double> {Binding(get:{curve.parts[index][keyPath:key]},set:{value in curve.update(index){$0[keyPath:key]=value}})}
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text(L("カーブエディタ")).vmmFont(size:16,weight:.semibold)
            Text(L("横軸は経過時間、縦軸は変化の割合です。制御点をドラッグして動きを調整します。")).foregroundColor(.secondary)
            EasingCurveGraph(curve:$curve,selected:$selected).frame(height:250)
            HStack {ForEach(0..<4,id:\.self){i in preset(i)}}
            HStack {ForEach(4..<EasingCurve.presets.count,id:\.self){i in preset(i)}}
            HStack {
                VMMMenuPicker(L("編集区間"),selection:$selected){VMMOptions(Array(curve.parts.indices),id:\.self){i in VMMChoice(text:"\(i+1) · \(String(format:"%.1f%%",curve.parts[i].endX*100))",value:i)}}
                Button(L("制御点を追加")){_=curve.insertPoint(in:index)}.disabled(curve.parts.count>=32)
                Button(L("通過点を削除")){if curve.removePoint(after:index){selected=min(selected,curve.parts.count-1)}}.disabled(index==curve.parts.count-1)
            }
            if index<curve.parts.count-1 {
                HStack {NumberInput(title:"通過点 X",value:field(\.endX),range:0...1,percent:true);NumberInput(title:"通過点 Y",value:field(\.endY),range:EasingCurve.yRange,percent:true)}
            }
            HStack {NumberInput(title:"制御点1 X",value:field(\.x1),range:0...1,percent:true);NumberInput(title:"制御点1 Y",value:field(\.y1),range:EasingCurve.yRange,percent:true)}
            HStack {NumberInput(title:"制御点2 X",value:field(\.x2),range:0...1,percent:true);NumberInput(title:"制御点2 Y",value:field(\.y2),range:EasingCurve.yRange,percent:true)}
            Text(L("◆は通過点、丸は区間の制御点です。縦方向は−300〜400％に対応します。")).foregroundColor(.secondary)
            HStack {Text(L("適用は次のキーフレームまでの区間です。")).foregroundColor(.secondary);Spacer();Button(L("キャンセル"),action:onCancel);Button(L("適用")){onApply(curve)}.buttonStyle(.borderedProminent)}
        }.padding(20).frame(width:680)
    }
    private func preset(_ i:Int)->some View {Button(L(EasingCurve.presets[i].0)){curve=EasingCurve.presets[i].1;selected=0}}
}
struct EasingCurveGraph:View {
    @Binding var curve:EasingCurve
    @Binding var selected:Int
    @State private var dragRange:ClosedRange<Double>?
    private var yBounds:ClosedRange<Double> {
        let values=[0.0,1.0]+curve.parts.flatMap{[$0.endY,$0.y1,$0.y2]}
        let low=values.min() ?? 0,high=values.max() ?? 1,pad=max(0.15,(high-low)*0.12)
        return (low-pad)...(high+pad)
    }
    var body:some View {GeometryReader {g in
        let inset=CGFloat(26),w=max(1,g.size.width-2*inset),h=max(1,g.size.height-2*inset),range=dragRange ?? yBounds,span=range.upperBound-range.lowerBound
        let parts=curve.parts,index=min(selected,parts.count-1)
        let startX=index==0 ? 0:parts[index-1].endX,startY=index==0 ? 0:parts[index-1].endY
        let part=parts[index]
        let point={(x:Double,y:Double) in CGPoint(x:inset+x*w,y:inset+(range.upperBound-y)/span*h)}
        ZStack(alignment:.topLeading) {
            Rectangle().fill(Color.primary.opacity(0.08)).onTapGesture(count:2){_=curve.insertPoint(in:index)}
            Path {p in for i in 0...4 {let x=inset+Double(i)/4*w,y=inset+Double(i)/4*h;p.move(to:CGPoint(x:x,y:inset));p.addLine(to:CGPoint(x:x,y:inset+h));p.move(to:CGPoint(x:inset,y:y));p.addLine(to:CGPoint(x:inset+w,y:y))}}.stroke(Color.primary.opacity(0.12),lineWidth:1).allowsHitTesting(false)
            Path {p in for y in [0.0,1.0]{p.move(to:point(0,y));p.addLine(to:point(1,y))}}.stroke(Color.primary.opacity(0.3),style:StrokeStyle(lineWidth:1,dash:[4,4])).allowsHitTesting(false)
            Text(String(format:"%.0f%%",range.upperBound*100)).vmmFont(size:12).foregroundColor(.secondary).offset(x:4,y:0).allowsHitTesting(false)
            Text(String(format:"%.0f%%",range.lowerBound*100)).vmmFont(size:12).foregroundColor(.secondary).offset(x:4,y:g.size.height-18).allowsHitTesting(false)
            Path {p in p.move(to:point(0,0));for s in parts{p.addCurve(to:point(s.endX,s.endY),control1:point(s.x1,s.y1),control2:point(s.x2,s.y2))}}.stroke(Color.cyan,lineWidth:3).allowsHitTesting(false)
            Path {p in p.move(to:point(startX,startY));p.addLine(to:point(part.x1,part.y1));p.move(to:point(part.endX,part.endY));p.addLine(to:point(part.x2,part.y2))}.stroke(Color.orange.opacity(0.75),lineWidth:1.5).allowsHitTesting(false)
            // offset keeps each gesture confined to its own 22pt hit region.
            ForEach(Array(parts.indices),id:\.self){i in
                if i<parts.count-1 {handle(kind:0,index:i,at:point(parts[i].endX,parts[i].endY),inset:inset,width:w,height:h,range:range)}
            }
            handle(kind:1,index:index,at:point(part.x1,part.y1),inset:inset,width:w,height:h,range:range)
            handle(kind:2,index:index,at:point(part.x2,part.y2),inset:inset,width:w,height:h,range:range)
        }.coordinateSpace(name:"easing-curve")
    }}
    private func handle(kind:Int,index:Int,at point:CGPoint,inset:CGFloat,width:CGFloat,height:CGFloat,range:ClosedRange<Double>)->some View {
        Group {
            if kind==0 {RoundedRectangle(cornerRadius:2).fill(Color.yellow).rotationEffect(.degrees(45)).frame(width:15,height:15)}
            else {Circle().fill(Color.orange).overlay(Text("\(kind)").font(.system(size:11,weight:.bold)).foregroundColor(.black))}
        }.frame(width:22,height:22).contentShape(Rectangle()).offset(x:point.x-11,y:point.y-11)
            .onHover{hover in if hover{NSCursor.openHand.set()}else{NSCursor.arrow.set()}}
            .gesture(DragGesture(minimumDistance:0,coordinateSpace:.named("easing-curve")).onChanged{v in
                if dragRange==nil{dragRange=range};selected=index;NSCursor.closedHand.set()
                let x=min(1,max(0,(v.location.x-inset)/width)),y=min(4,max(-3,range.upperBound-(v.location.y-inset)/height*(range.upperBound-range.lowerBound)))
                curve.update(index){s in if kind==0{s.endX=x;s.endY=y}else if kind==1{s.x1=x;s.y1=y}else{s.x2=x;s.y2=y}}
            }.onEnded{_ in dragRange=nil;NSCursor.openHand.set()})
            .accessibilityLabel(L(kind==0 ? "通過点":kind==1 ? "制御点1":"制御点2"))
    }
}
