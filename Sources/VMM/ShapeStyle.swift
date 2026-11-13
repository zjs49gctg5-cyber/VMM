import AppKit
import SwiftUI

enum ShapeKind:String,Codable,CaseIterable {
    case rectangle,ellipse,triangle,diamond,pentagon,hexagon,star,arrow,heart
    var title:String {switch self {case .rectangle:return "四角形";case .ellipse:return "円・楕円";case .triangle:return "三角形";case .diamond:return "ひし形";case .pentagon:return "五角形";case .hexagon:return "六角形";case .star:return "星";case .arrow:return "矢印";case .heart:return "ハート"}}
}
struct ShapeStyle:Codable,Equatable {
    var path:AnimatedBezierShape?
    var kind=ShapeKind.rectangle
    var width:Double=0.72
    var height:Double=0.32
    var cornerRadius:Double=28
    var arrowHeadLength:Double?
    var arrowHeadHeight:Double?
    var fill=true
    var outline=false
    var outlineColor="FFFFFF"
    var outlineWidth:Double=4
    var shadow=false
    var shadowColor="000000"
    var shadowOpacity:Double=0.5
    var shadowBlur:Double=10
    var shadowX:Double=8
    var shadowY:Double=8
    func validate()throws {
        try path?.validated()
        for value in [arrowHeadLength,arrowHeadHeight].compactMap({$0}) {
            guard value.isFinite,(0.01...1).contains(value) else {throw VMMError.message("矢印の先端サイズは1〜100%で指定してください。")}
        }
        guard width.isFinite,(0.001...4).contains(width),height.isFinite,(0.001...4).contains(height),
              cornerRadius.isFinite,(0...1000).contains(cornerRadius),outlineWidth.isFinite,(0...200).contains(outlineWidth),
              shadowOpacity.isFinite,(0...1).contains(shadowOpacity),shadowBlur.isFinite,(0...200).contains(shadowBlur),
              shadowX.isFinite,(-500...500).contains(shadowX),shadowY.isFinite,(-500...500).contains(shadowY),
              [outlineColor,shadowColor].allSatisfy({$0.count==6 && UInt32($0,radix:16) != nil}) else {throw VMMError.message("図形の設定が不正です。")}
    }
}
enum ShapePainter {
    static func rect(_ style:ShapeStyle,project:Project)->CGRect {CGRect(x:-style.width*Double(project.width)/2,y:-style.height*Double(project.height)/2,width:style.width*Double(project.width),height:style.height*Double(project.height))}
    static func path(_ style:ShapeStyle,in rect:CGRect,time:Double=0,trim:Bool=false)->CGPath {
        if let path=style.path{return path.path(in:rect,time:time,trim:trim)}
        let radius=min(style.cornerRadius,min(rect.width,rect.height)/2)
        switch style.kind {
        case .rectangle:return CGPath(roundedRect:rect,cornerWidth:radius,cornerHeight:radius,transform:nil)
        case .ellipse:return CGPath(ellipseIn:rect,transform:nil)
        case .heart:
            let p=CGMutablePath()
            func point(_ x:Double,_ y:Double)->CGPoint {CGPoint(x:rect.minX+x*rect.width,y:rect.minY+y*rect.height)}
            p.move(to:point(0.5,1));p.addCurve(to:point(0.5,0.18),control1:point(-0.3,0.45),control2:point(0.05,-0.35));p.addCurve(to:point(0.5,1),control1:point(0.95,-0.35),control2:point(1.3,0.45));p.closeSubpath();return p
        default:
            let normalized:[CGPoint]
            switch style.kind {
            case .triangle:normalized=[CGPoint(x:0.5,y:0),CGPoint(x:1,y:1),CGPoint(x:0,y:1)]
            case .diamond:normalized=[CGPoint(x:0.5,y:0),CGPoint(x:1,y:0.5),CGPoint(x:0.5,y:1),CGPoint(x:0,y:0.5)]
            case .arrow:
                let base=1-(style.arrowHeadLength ?? 0.35),halfHeight=(style.arrowHeadHeight ?? 1)/2
                normalized=[CGPoint(x:0,y:0.3),CGPoint(x:base,y:0.3),CGPoint(x:base,y:0.5-halfHeight),CGPoint(x:1,y:0.5),CGPoint(x:base,y:0.5+halfHeight),CGPoint(x:base,y:0.7),CGPoint(x:0,y:0.7)]
            default:
                let count=style.kind == .star ? 10:style.kind == .pentagon ? 5:6
                normalized=(0..<count).map {i in let angle=Double(i)*2*Double.pi/Double(count)-Double.pi/2;let r=style.kind == .star && i%2==1 ? 0.22:0.5;return CGPoint(x:0.5+cos(angle)*r,y:0.5+sin(angle)*r)}
            }
            let points=normalized.map{CGPoint(x:rect.minX+$0.x*rect.width,y:rect.minY+$0.y*rect.height)},p=CGMutablePath()
            for i in points.indices {
                let previous=points[(i+points.count-1)%points.count],v=points[i],next=points[(i+1)%points.count]
                let beforeDistance=hypot(previous.x-v.x,previous.y-v.y),afterDistance=hypot(next.x-v.x,next.y-v.y)
                let r=min(radius,min(beforeDistance,afterDistance)/2)
                let before=CGPoint(x:v.x+(previous.x-v.x)*r/max(0.001,beforeDistance),y:v.y+(previous.y-v.y)*r/max(0.001,beforeDistance))
                let after=CGPoint(x:v.x+(next.x-v.x)*r/max(0.001,afterDistance),y:v.y+(next.y-v.y)*r/max(0.001,afterDistance))
                if i==0 {p.move(to:before)} else {p.addLine(to:before)}
                p.addQuadCurve(to:after,control:v)
            }
            p.closeSubpath();return p
        }
    }
    static func draw(_ clip:Clip,project:Project,center:CGPoint,context:CGContext,time:Double=0) {
        let style=clip.shapeStyle ?? ShapeStyle(),path=path(style,in:rect(style,project:project),time:time)
        let stroke=ShapePainter.path(style,in:rect(style,project:project),time:time,trim:true)
        context.saveGState();defer{context.restoreGState()};context.translateBy(x:center.x,y:center.y)
        context.setLineWidth(style.outlineWidth);context.setLineJoin(.round)
        if style.shadow && (style.fill || style.outline) {
            context.saveGState();context.setShadow(offset:CGSize(width:style.shadowX,height:-style.shadowY),blur:style.shadowBlur,color:NSColor(hex:style.shadowColor).withAlphaComponent(style.shadowOpacity).cgColor)
            context.setFillColor(NSColor(hex:clip.color).cgColor);context.setStrokeColor(NSColor(hex:style.outlineColor).cgColor)
            if style.path==nil || (style.path!.trimStart.isEmpty && style.path!.trimEnd.isEmpty) {context.addPath(path);context.drawPath(using:style.fill ? (style.outline ? .fillStroke:.fill):.stroke)}
            else {if style.fill{context.addPath(path);context.fillPath()};if style.outline{context.addPath(stroke);context.strokePath()}}
            context.restoreGState()
        }
        if style.fill {context.setFillColor(NSColor(hex:clip.color).cgColor);context.addPath(path);context.fillPath()}
        if style.outline {context.setStrokeColor(NSColor(hex:style.outlineColor).cgColor);context.addPath(stroke);context.strokePath()}
    }
}
struct ShapeControls:View {
    @ObservedObject var store:EditorStore
    let clip:Clip
    @State private var expanded=true
    func binding<T>(_ key:WritableKeyPath<ShapeStyle,T>)->Binding<T> {store.advancedBinding(clip.id,\.shapeStyle,key,default:ShapeStyle())}
    func optionalBinding(_ key:WritableKeyPath<ShapeStyle,Double?>,default value:Double)->Binding<Double> {
        Binding(get:{binding(key).wrappedValue ?? value},set:{binding(key).wrappedValue=$0})
    }
    func color(_ title:String,_ key:WritableKeyPath<ShapeStyle,String>)->some View {ColorPicker(L(title),selection:Binding(get:{Color(nsColor:NSColor(hex:binding(key).wrappedValue))},set:{binding(key).wrappedValue=NSColor($0).hex}),supportsOpacity:false)}
    var body:some View {
        PanelDisclosure(L("図形の設定"),isExpanded:$expanded) {
            VMMMenuPicker(L("形"),selection:Binding(get:{clip.shapeStyle?.kind ?? .rectangle},set:{kind in store.edit(clip.id){var s=$0.shapeStyle ?? ShapeStyle();s.kind=kind;s.cornerRadius=kind == .rectangle ? 28:0;$0.shapeStyle=s}})) {VMMOptions(ShapeKind.allCases,id:\.self){VMMChoice(text:L($0.title),value:$0)}}
            NumberInput(title:"幅",value:binding(\.width),range:0.001...4,percent:true)
            NumberInput(title:"高さ",value:binding(\.height),range:0.001...4,percent:true)
            if clip.shapeStyle?.kind == .arrow {
                NumberInput(title:"先端の長さ",value:optionalBinding(\.arrowHeadLength,default:0.35),range:0.01...1,percent:true)
                NumberInput(title:"先端の高さ",value:optionalBinding(\.arrowHeadHeight,default:1),range:0.01...1,percent:true)
                Text(L("矢印全体の幅・高さに対する割合です。")).vmmFont(size:12).foregroundColor(.secondary)
            }
            if ![ShapeKind.ellipse,.heart].contains(clip.shapeStyle?.kind ?? .rectangle) {NumberInput(title:"角の丸み",value:binding(\.cornerRadius),range:0...1000,unit:"px")}
            Toggle(L("塗りつぶし"),isOn:binding(\.fill))
            Toggle(L("縁取り"),isOn:binding(\.outline))
            if clip.shapeStyle?.outline == true {color("縁の色",\.outlineColor);NumberInput(title:"縁の太さ",value:binding(\.outlineWidth),range:0...200,unit:"px")}
            Toggle(L("影"),isOn:binding(\.shadow))
            if clip.shapeStyle?.shadow == true {
                color("影の色",\.shadowColor)
                NumberInput(title:"影の不透明度",value:binding(\.shadowOpacity),range:0...1,percent:true)
                NumberInput(title:"影のぼかし",value:binding(\.shadowBlur),range:0...200,unit:"px")
                NumberInput(title:"影のX位置",value:binding(\.shadowX),range:-500...500,unit:"px")
                NumberInput(title:"影のY位置",value:binding(\.shadowY),range:-500...500,unit:"px")
            }
        }
    }
}
