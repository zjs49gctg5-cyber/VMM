import SwiftUI
import AppKit

struct AdjustmentRegionControls: View {
    @ObservedObject var store: EditorStore
    let clip: Clip
    func binding<T>(_ key: WritableKeyPath<AdjustmentRegion,T>) -> Binding<T> {
        store.advancedBinding(clip.id, \.adjustmentRegion, key, default: AdjustmentRegion())
    }
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Text(L("エフェクトの適用範囲")).vmmFont(size:14,weight:.semibold)
            Toggle(L("部分に適用"),isOn:Binding(get:{clip.adjustmentRegion != nil},set:{enabled in store.edit(clip.id){c in
                c.adjustmentRegion = enabled ? AdjustmentRegion() : nil
                if !enabled {c.animation?.tracks.removeAll{[.regionWidth,.regionHeight].contains($0.property)}}
            }}))
            if let region=clip.adjustmentRegion {
                VMMMenuPicker(L("形"),selection:binding(\.shape)) {VMMOptions(AdjustmentShape.allCases,id:\.self){VMMChoice(text:L($0.title),value:$0)}}
                NumberInput(title:"中心 X",value:store.binding(\.x,default:0.5),range:-2...3,percent:true)
                NumberInput(title:"中心 Y",value:store.binding(\.y,default:0.5),range:-2...3,percent:true)
                NumberInput(title:"幅",value:binding(\.width),range:0.001...4,percent:true)
                NumberInput(title:"高さ",value:binding(\.height),range:0.001...4,percent:true)
                Text("約 \(Int(region.width * Double(store.project.width))) × \(Int(region.height * Double(store.project.height))) px").foregroundColor(.secondary)
                NumberInput(title:"回転",value:Binding(get:{clip.rotation ?? 0},set:{v in store.edit(clip.id){$0.rotation=v}}),range:-3600...3600,unit:"°")
                NumberInput(title:"境界のぼかし",value:binding(\.feather),range:0...200,unit:"px")
                Text(L("プレビューの枠をドラッグして移動、四隅でサイズ変更。動きの枠で位置・幅・高さをアニメーションできます。")).vmmFont(size:12).foregroundColor(.secondary)
                Button(L("適用開始へ移動")) {store.seek(clip.start)}
            } else {Text(L("画面全体に適用します。")).foregroundColor(.secondary)}
            NumberInput(title:"不透明度",value:store.binding(\.opacity,default:1),range:0...1,percent:true)
            Button(L("部分モザイクを設定")) { store.edit(clip.id) { c in
                if c.adjustmentRegion == nil {c.adjustmentRegion=AdjustmentRegion()}
                if !(c.effects ?? []).contains(where:{$0.kind == .pixelate}) {var effects=c.effects ?? [];if effects.count<32 {effects.append(VisualEffect(kind:.pixelate))};c.effects=effects}
            };store.seek(clip.start) }
        }.padding(10).background(Color.primary.opacity(0.04)).cornerRadius(8)
    }
}

// The editing outline is a view overlay; it never enters preview/export pixels.
struct AdjustmentRegionOverlay: NSViewRepresentable {
    @ObservedObject var store: EditorStore
    func makeNSView(context:Context)->RegionEditingView {RegionEditingView()}
    func updateNSView(_ view:RegionEditingView,context:Context) {view.store=store;view.needsDisplay=true;view.window?.invalidateCursorRects(for:view)}
}
final class RegionEditingView: NSView {
    weak var store:EditorStore?
    private var original:Clip?
    private var origin=CGPoint.zero
    private var corner:Int?
    override var isFlipped:Bool {true}
    var editable:Clip? {
        guard let store,let clip=store.selected,clip.kind == .adjustment,clip.adjustmentRegion != nil,
              clip.active(at:store.playhead),!store.playing,!store.busy,!store.project.tracks[clip.track].locked else {return nil}
        return clip.animated(at:store.playhead)
    }
    func local(_ point:CGPoint,clip:Clip)->CGPoint {
        let dx=point.x-clip.x*bounds.width,dy=point.y-clip.y*bounds.height,a=(clip.rotation ?? 0)*Double.pi/180
        return CGPoint(x:cos(a)*dx+sin(a)*dy,y:-sin(a)*dx+cos(a)*dy)
    }
    func rect(_ clip:Clip)->CGRect {
        let r=clip.adjustmentRegion!,w=r.width*bounds.width,h=r.height*bounds.height
        return CGRect(x:-w/2,y:-h/2,width:w,height:h)
    }
    func corners(_ rect:CGRect)->[CGPoint] {[CGPoint(x:rect.minX,y:rect.minY),CGPoint(x:rect.maxX,y:rect.minY),CGPoint(x:rect.minX,y:rect.maxY),CGPoint(x:rect.maxX,y:rect.maxY)]}
    override func hitTest(_ point:NSPoint)->NSView? {
        guard let clip=editable else {return nil}
        let p=convert(point,from:superview)
        return rect(clip).insetBy(dx:-8,dy:-8).contains(local(p,clip:clip)) ? self:nil
    }
    override func resetCursorRects() {
        guard let clip=editable else {return}
        let a=(clip.rotation ?? 0)*Double.pi/180
        let points=corners(rect(clip)).map {p in CGPoint(x:clip.x*bounds.width+cos(a)*p.x-sin(a)*p.y,y:clip.y*bounds.height+sin(a)*p.x+cos(a)*p.y)}
        let xs=points.map(\.x),ys=points.map(\.y)
        addCursorRect(CGRect(x:xs.min()!-5,y:ys.min()!-5,width:xs.max()!-xs.min()!+10,height:ys.max()!-ys.min()!+10),cursor:.openHand)
        for p in points {addCursorRect(CGRect(x:p.x-7,y:p.y-7,width:14,height:14),cursor:.crosshair)}
    }
    override func draw(_ dirtyRect:NSRect) {
        guard let clip=editable,let c=NSGraphicsContext.current?.cgContext else {return}
        let r=rect(clip)
        c.saveGState();defer{c.restoreGState()}
        c.translateBy(x:clip.x*bounds.width,y:clip.y*bounds.height);c.rotate(by:(clip.rotation ?? 0)*Double.pi/180)
        let path=RegionOutline(shape:clip.adjustmentRegion!.shape).path(in:r).cgPath
        c.addPath(path);c.setFillColor(NSColor.cyan.withAlphaComponent(0.06).cgColor);c.fillPath()
        c.addPath(path);c.setStrokeColor(NSColor.cyan.cgColor);c.setLineWidth(1.5);c.setLineDash(phase:0,lengths:[5,3]);c.strokePath();c.setLineDash(phase:0,lengths:[])
        for p in corners(r) {let handle=CGRect(x:p.x-4,y:p.y-4,width:8,height:8);c.setFillColor(NSColor.white.cgColor);c.fill(handle);c.stroke(handle)}
    }
    override func mouseDown(with event:NSEvent) {
        guard let store,let clip=editable else {return}
        original=clip;origin=convert(event.locationInWindow,from:nil)
        let p=local(origin,clip:clip)
        corner=corners(rect(clip)).firstIndex{hypot(p.x-$0.x,p.y-$0.y)<10}
        store.checkpoint();store.pause()
    }
    override func mouseDragged(with event:NSEvent) {
        guard let store,let base=original,let region=base.adjustmentRegion,bounds.width>0,bounds.height>0 else {return}
        let p=convert(event.locationInWindow,from:nil),dx=p.x-origin.x,dy=p.y-origin.y
        store.edit(base.id,record:false) {c in
            if let corner {
                let a=(base.rotation ?? 0)*Double.pi/180,lx=cos(a)*dx+sin(a)*dy,ly = -sin(a)*dx+cos(a)*dy
                set(.regionWidth,region.width+2*lx/bounds.width*(corner%2 == 0 ? -1:1),on:&c)
                set(.regionHeight,region.height+2*ly/bounds.height*(corner<2 ? -1:1),on:&c)
            } else {set(.x,base.x+dx/bounds.width,on:&c);set(.y,base.y+dy/bounds.height,on:&c)}
        }
    }
    override func mouseUp(with event:NSEvent) {original=nil;corner=nil}
    func set(_ property:AnimatedProperty,_ value:Double,on clip:inout Clip) {
        guard let store else {return}
        let value=min(property.range.upperBound,max(property.range.lowerBound,value))
        if let t=clip.animation?.tracks.firstIndex(where:{$0.property == property && $0.enabled}) {
            let time=(max(clip.animationTimeOffset,min(clip.duration+clip.animationTimeOffset,clip.motionTime(at:store.playhead)))*Double(store.project.fps)).rounded()/Double(store.project.fps)
            if let k=clip.animation!.tracks[t].keys.firstIndex(where:{abs($0.time-time)<0.5/Double(store.project.fps)}) {clip.animation!.tracks[t].keys[k].value=value}
            else if clip.animation!.tracks[t].keys.count<500 {clip.animation!.tracks[t].keys.append(AnimationKeyframe(time:time,value:value))}
        } else {property.set(value,on:&clip)}
    }
}
struct RegionOutline: Shape {
    let shape:AdjustmentShape
    func path(in rect:CGRect)->Path {
        switch shape {case .rectangle:return Path(rect);case .ellipse:return Path(ellipseIn:rect)
        case .roundedRectangle:return Path(roundedRect:rect,cornerRadius:min(rect.width,rect.height)*0.15)}
    }
}
