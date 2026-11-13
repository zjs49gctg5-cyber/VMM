import AppKit
import SwiftUI

/// Optional per-image frame dimensions and border fractions in source coordinates.
struct NineSliceSettings:Codable,Equatable {
    var width:Double=0.5
    var height:Double=0.3
    var left:Double=0.15
    var right:Double=0.15
    var top:Double=0.15
    var bottom:Double=0.15
    var exceedsCanvas:Bool {width>1 || height>1}
    /// Existing oversized values remain readable; user size edits are limited to the canvas.
    static func userSize(_ value:Double,current:Double)->Double {value == current ? current:min(1,max(0.01,value))}
    func validate() throws {
        guard [width,height,left,right,top,bottom].allSatisfy(\.isFinite),
              (0.01...4).contains(width),(0.01...4).contains(height),
              [left,right,top,bottom].allSatisfy({(0...1).contains($0)}),left+right<1,bottom+top<1 else {throw VMMError.message("9スライスのサイズ・余白が不正です。")}
    }
    func rect(project:Project)->CGRect {
        let w=width*Double(project.width),h=height*Double(project.height)
        return CGRect(x:-w/2,y:-h/2,width:w,height:h)
    }
}

enum NineSlicePainter {
    struct Patch {var source:CGRect;var destination:CGRect}
    static func patches(imageSize:CGSize,destination:CGRect,fit:Double,settings:NineSliceSettings)->[Patch] {
        let w=imageSize.width,h=imageSize.height
        guard w>0,h>0,destination.width>0,destination.height>0,fit>0 else{return []}
        let sourceX:[Double]=[0,w*settings.left,w*(1-settings.right),w]
        // NSImage's source rectangles use an unflipped origin.
        let sourceY:[Double]=[h,h*(1-settings.top),h*settings.bottom,0]
        let left=w*settings.left*fit,right=w*settings.right*fit,top=h*settings.top*fit,bottom=h*settings.bottom*fit
        let sx=min(1,Double(destination.width)/max(0.000001,left+right)),sy=min(1,Double(destination.height)/max(0.000001,top+bottom))
        let destX:[Double]=[destination.minX,destination.minX+left*sx,destination.maxX-right*sx,destination.maxX]
        let destY:[Double]=[destination.minY,destination.minY+top*sy,destination.maxY-bottom*sy,destination.maxY]
        var patches:[Patch]=[]
        for row in 0..<3 {for column in 0..<3 {
            let source=CGRect(x:sourceX[column],y:sourceY[row+1],width:sourceX[column+1]-sourceX[column],height:sourceY[row]-sourceY[row+1])
            let target=CGRect(x:destX[column],y:destY[row],width:destX[column+1]-destX[column],height:destY[row+1]-destY[row])
            if source.width>0,source.height>0,target.width>0,target.height>0 {patches.append(Patch(source:source,destination:target))}
        }}
        return patches
    }
    static func draw(_ image:NSImage,in rect:CGRect,project:Project,settings:NineSliceSettings) {
        let fit=min(Double(project.width)/image.size.width,Double(project.height)/image.size.height)
        for patch in patches(imageSize:image.size,destination:rect,fit:fit,settings:settings) {
            image.draw(in:patch.destination,from:patch.source,operation:.sourceOver,fraction:1,respectFlipped:true,hints:[.interpolation:NSImageInterpolation.high])
        }
    }
}

struct NineSliceControls:View {
    @ObservedObject var store:EditorStore
    let clip:Clip
    private var value:NineSliceSettings {clip.nineSlice ?? NineSliceSettings()}
    private func binding(_ key:WritableKeyPath<NineSliceSettings,Double>)->Binding<Double> {
        Binding(get:{value[keyPath:key]},set:{newValue in store.edit(clip.id){item in var settings=item.nineSlice ?? NineSliceSettings();settings[keyPath:key]=newValue;item.nineSlice=settings}})
    }
    var body:some View {
        PanelDisclosure(L("9スライス（枠の伸縮）")) {
            VStack(alignment:.leading,spacing:8) {
                Toggle(L("9スライスを使用"),isOn:Binding(get:{clip.nineSlice != nil},set:{enabled in store.edit(clip.id){$0.nineSlice=enabled ? NineSliceSettings():nil}}))
                if clip.nineSlice != nil {
                    NumberInput(title:"表示幅",value:Binding(get:{value.width},set:{binding(\.width).wrappedValue=NineSliceSettings.userSize($0,current:value.width)}),range:0.01...max(1,value.width),percent:true)
                    NumberInput(title:"表示高さ",value:Binding(get:{value.height},set:{binding(\.height).wrappedValue=NineSliceSettings.userSize($0,current:value.height)}),range:0.01...max(1,value.height),percent:true)
                    if value.exceedsCanvas {Text(L("保存済みの表示幅または高さが100%を超えています。画像が切れる場合があります。サイズを変更すると最大100%になります。" )).foregroundColor(.orange)}
                    Text(L("余白は元画像の幅・高さに対する割合です。" )).foregroundColor(.secondary)
                    NumberInput(title:"左の余白",value:binding(\.left),range:0...max(0,1-value.right-0.00001),percent:true)
                    NumberInput(title:"右の余白",value:binding(\.right),range:0...max(0,1-value.left-0.00001),percent:true)
                    NumberInput(title:"上の余白",value:binding(\.top),range:0...max(0,1-value.bottom-0.00001),percent:true)
                    NumberInput(title:"下の余白",value:binding(\.bottom),range:0...max(0,1-value.top-0.00001),percent:true)
                    Text(L("プレビューのハンドルで枠の幅と高さを変更できます。枠が小さい場合は角も縮小されます。" )).vmmFont(size:12).foregroundColor(.secondary)
                }
            }.padding(.top,8)
        }
    }
}
