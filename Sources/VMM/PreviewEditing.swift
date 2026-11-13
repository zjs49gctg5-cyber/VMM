import AppKit
import SwiftUI
import AVFoundation

struct ObjectEditingOverlay:NSViewRepresentable {
    @ObservedObject var store:EditorStore
    var targetID:UUID?=nil
    var autoKey=false
    var editAnchor=false
    func makeNSView(context:Context)->ObjectEditingView {ObjectEditingView()}
    func updateNSView(_ view:ObjectEditingView,context:Context) {view.store=store;view.targetID=targetID;view.autoKey=autoKey;view.editAnchor=editAnchor;view.syncTextEditor();view.prepareGeometry();view.needsDisplay=true;view.window?.invalidateCursorRects(for:view)}
    static func dismantleNSView(_ view:ObjectEditingView,coordinator:()) {_=view.finishTextEditing(commit:true)}
}

/// A real text view preserves macOS input methods and native text shortcuts.
final class PreviewInlineTextView:NSTextView {
    var finish:((Bool)->Void)?
    override func keyDown(with event:NSEvent) {
        if event.keyCode == 53 && !hasMarkedText() {finish?(false);return}
        if (event.keyCode == 36 || event.keyCode == 76) && event.modifierFlags.contains(.command) && !hasMarkedText() {finish?(true);return}
        super.keyDown(with:event)
    }
}
struct PreviewObjectGeometry {
    let rect:CGRect
    let transform:CGAffineTransform
    let parent:CGAffineTransform
    let own:CGAffineTransform
    var camera:Camera3D? = nil
    var cameraDepth:Double = 0
    var canvasSize:CGSize = .zero
    func projected(_ point:CGPoint)->CGPoint? {
        guard let camera else{return point}
        let flipped=CGPoint(x:point.x,y:canvasSize.height-point.y)
        guard let p=camera.project(flipped,depth:cameraDepth,size:canvasSize) else{return nil}
        return CGPoint(x:p.x,y:canvasSize.height-p.y)
    }
    func unprojected(_ point:CGPoint)->CGPoint? {
        guard let camera else{return point}
        let flipped=CGPoint(x:point.x,y:canvasSize.height-point.y)
        guard let p=camera.unproject(flipped,depth:cameraDepth,size:canvasSize) else{return nil}
        return CGPoint(x:p.x,y:canvasSize.height-p.y)
    }
    var points:[CGPoint] {Self.handles(rect).map{projected($0.applying(transform)) ?? CGPoint(x:-1e8,y:-1e8)}}
    var anchor:CGPoint = .zero
    var pivot:CGPoint {projected(anchor.applying(transform)) ?? CGPoint(x:-1e8,y:-1e8)}
    var rotationHandle:CGPoint {
        let top=points[1],bottom=points[5],length=max(0.001,hypot(top.x-bottom.x,top.y-bottom.y))
        return CGPoint(x:top.x+(top.x-bottom.x)*28/length,y:top.y+(top.y-bottom.y)*28/length)
    }
    static func handles(_ r:CGRect)->[CGPoint] {[CGPoint(x:r.minX,y:r.minY),CGPoint(x:r.midX,y:r.minY),CGPoint(x:r.maxX,y:r.minY),CGPoint(x:r.maxX,y:r.midY),CGPoint(x:r.maxX,y:r.maxY),CGPoint(x:r.midX,y:r.maxY),CGPoint(x:r.minX,y:r.maxY),CGPoint(x:r.minX,y:r.midY)]}
}
@MainActor final class PreviewGeometry {
    private let text=TextPainter()
    private var sizes:[String:CGSize]=[:]
    private var loading:Set<String>=[]
    static func matrix(_ clip:Clip,project:Project,canvasInput:Bool)->CGAffineTransform {
        clip.objectMatrix(project:project,canvasInput:canvasInput)
    }
    func parentTransform(_ clip:Clip,project:Project,time:Double)->CGAffineTransform? {
        var result=CGAffineTransform.identity,next=clip.parentID,seen:Set<UUID>=[clip.id]
        while let id=next {
            guard seen.insert(id).inserted,seen.count<=16,let parent=project.clips.first(where:{$0.id==id}),parent.active(at:time),project.tracks[parent.track].visible else {return nil}
            let animated=parent.animated(at:time,aspectRatio:Double(project.width)/Double(project.height))
            // A perspective warp is not affine. Its descendants retain numeric editing.
            guard animated.opacity>0.001,animated.transform?.perspective != true else {return nil}
            result=result.concatenating(Self.matrix(animated,project:project,canvasInput:true));next=parent.parentID
        }
        return result
    }
    func geometry(_ clip:Clip,project:Project,directory:URL,time:Double,size:CGSize,onReady:@escaping ()->Void = {})->PreviewObjectGeometry? {
        guard clip.active(at:time),size.width>0,size.height>0,project.tracks.indices.contains(clip.track),project.tracks[clip.track].visible,let parent=parentTransform(clip,project:project,time:time) else {return nil}
        guard !(clip.kind == .speech && clip.speechCaptionHidden == true) else{return nil}
        let current=clip.animated(at:time,aspectRatio:Double(project.width)/Double(project.height))
        guard current.opacity>0.001,current.transform?.perspective != true else {return nil}
        let rect:CGRect
        switch clip.kind {
        case .shape:rect=ShapePainter.rect(current.shapeStyle ?? ShapeStyle(),project:project)
        case .text,.speech:
            rect=text.bounds(current,projectWidth:project.width)
            guard !rect.isNull,!rect.isEmpty else {return nil}
        case .image,.video:
            guard let asset=project.asset(for:clip) else {return nil}
            let url=directory.appendingPathComponent("Media").appendingPathComponent(asset.file),key=url.path
            let dimensions:CGSize
            if let psd=asset.psd {dimensions=CGSize(width:psd.width,height:psd.height)}
            else if let cached=sizes[key] {dimensions=cached}
            else if asset.kind == .image,let image=NSImage(contentsOf:url) {dimensions=image.size;sizes[key]=dimensions}
            else {
                if !loading.contains(key) {
                    loading.insert(key)
                    Task { [weak self] in
                        defer{self?.loading.remove(key)}
                        guard let track=try? await AVURLAsset(url:url).loadTracks(withMediaType:.video).first,
                              let natural=try? await track.load(.naturalSize),let transform=try? await track.load(.preferredTransform) else {return}
                        let size=natural.applying(transform)
                        self?.sizes[key]=CGSize(width:abs(size.width),height:abs(size.height));onReady()
                    }
                }
                return nil
            }
            guard dimensions.width>0,dimensions.height>0 else {return nil}
            let fit=min(Double(project.width)/dimensions.width,Double(project.height)/dimensions.height)
            rect=clip.nineSlice?.rect(project:project) ?? CGRect(x:-dimensions.width*fit/2,y:-dimensions.height*fit/2,width:dimensions.width*fit,height:dimensions.height*fit)
        case .group:
            let width=Double(project.composition(clip)?.width ?? project.width),height=Double(project.composition(clip)?.height ?? project.height)
            rect=CGRect(x:-width/2,y:-height/2,width:width,height:height)
        default:return nil
        }
        let own=Self.matrix(current,project:project,canvasInput:false)
        let transform=own.concatenating(parent).concatenating(CGAffineTransform(scaleX:size.width/Double(project.width),y:size.height/Double(project.height)))
        guard abs(transform.a*transform.d-transform.b*transform.c)>0.0000001 else {return nil}
        var root=clip
        var seen:Set<UUID>=[root.id]
        while let id=root.parentID,seen.insert(id).inserted,seen.count<=16,let p=project.clips.first(where:{$0.id==id}) {root=p}
        let camera=project.camera3D.flatMap{$0.enabled ? $0.evaluated(at:time):nil}
        return PreviewObjectGeometry(rect:rect,transform:transform,parent:parent,own:own,camera:camera,cameraDepth:root.cameraDepth ?? 0,canvasSize:size,anchor:CGPoint(x:current.anchorOffset.x*Double(project.width),y:current.anchorOffset.y*Double(project.height)))
    }
}
// Offsets the complete animation path so manipulation does not erase keyframes.
extension Clip {
    mutating func previewOffset(_ property:AnimatedProperty,by delta:Double) {
        property.set(property.get(self)+delta,on:&self)
        if [.x,.y].contains(property),spatialAnimation != nil {for i in spatialAnimation!.keys.indices {if property == .x {spatialAnimation!.keys[i].point.x+=delta}else{spatialAnimation!.keys[i].point.y+=delta}}}
        if let index=animation?.tracks.firstIndex(where:{$0.property==property && $0.enabled}) {
            for key in animation!.tracks[index].keys.indices {animation!.tracks[index].keys[key].value=min(property.range.upperBound,max(property.range.lowerBound,animation!.tracks[index].keys[key].value+delta))}
        }
    }
    mutating func previewMultiply(_ property:AnimatedProperty,by factor:Double) {
        property.set(property.get(self)*factor,on:&self)
        if let index=animation?.tracks.firstIndex(where:{$0.property==property && $0.enabled}) {
            for key in animation!.tracks[index].keys.indices {animation!.tracks[index].keys[key].value=min(property.range.upperBound,max(property.range.lowerBound,animation!.tracks[index].keys[key].value*factor))}
        }
    }
}
enum PreviewCursorKind:Equatable {
    case arrow,move,grabbing,horizontal,vertical,diagonalDown,diagonalUp,rotate,crosshair
    @MainActor var cursor:NSCursor {
        switch self {
        case .crosshair:return .crosshair
        case .arrow:return .arrow
        case .move:return .openHand
        case .grabbing:return .closedHand
        case .horizontal:return .resizeLeftRight
        case .vertical:return .resizeUpDown
        case .diagonalDown:return PreviewCursors.diagonalDown
        case .diagonalUp:return PreviewCursors.diagonalUp
        case .rotate:return PreviewCursors.rotate
        }
    }
    static func resize(_ handle:Int,transform:CGAffineTransform)->Self {
        let vectors:[CGPoint]=[CGPoint(x:-1,y:-1),CGPoint(x:0,y:-1),CGPoint(x:1,y:-1),CGPoint(x:1,y:0),CGPoint(x:1,y:1),CGPoint(x:0,y:1),CGPoint(x:-1,y:1),CGPoint(x:-1,y:0)]
        let v=vectors[handle],xLength=max(0.001,hypot(transform.a,transform.b)),yLength=max(0.001,hypot(transform.c,transform.d))
        let x=v.x*transform.a/xLength+v.y*transform.c/yLength,y=v.x*transform.b/xLength+v.y*transform.d/yLength
        let axis=(Int((atan2(y,x)*4/Double.pi).rounded())%4+4)%4
        return [.horizontal,.diagonalDown,.vertical,.diagonalUp][axis]
    }
}
@MainActor private enum PreviewCursors {
    static let diagonalDown=diagonal(up:false)
    static let diagonalUp=diagonal(up:true)
    static let rotate:NSCursor = {
        let image=NSImage(size:NSSize(width:24,height:24),flipped:false) {_ in
            let path=NSBezierPath()
            path.appendArc(withCenter:NSPoint(x:12,y:12),radius:7,startAngle:30,endAngle:330,clockwise:false)
            path.move(to:NSPoint(x:18,y:5));path.line(to:NSPoint(x:18,y:10));path.line(to:NSPoint(x:13,y:9))
            path.lineCapStyle = .round;path.lineJoinStyle = .round
            NSColor.white.setStroke();path.lineWidth=4;path.stroke()
            NSColor.black.setStroke();path.lineWidth=2;path.stroke()
            return true
        }
        return NSCursor(image:image,hotSpot:NSPoint(x:12,y:12))
    }()
    static func diagonal(up:Bool)->NSCursor {
        let image=NSImage(size:NSSize(width:24,height:24),flipped:false) {_ in
            let p=NSBezierPath()
            func point(_ x:Double,_ y:Double)->NSPoint {NSPoint(x:x,y:up ? y:24-y)}
            p.move(to:point(5,5));p.line(to:point(19,19))
            p.move(to:point(5,11));p.line(to:point(5,5));p.line(to:point(11,5))
            p.move(to:point(13,19));p.line(to:point(19,19));p.line(to:point(19,13))
            p.lineJoinStyle = .round;p.lineCapStyle = .round
            NSColor.white.setStroke();p.lineWidth=4;p.stroke()
            NSColor.black.setStroke();p.lineWidth=2;p.stroke()
            return true
        }
        return NSCursor(image:image,hotSpot:NSPoint(x:12,y:12))
    }
}
final class ObjectEditingView:NSView,NSTextViewDelegate {
    weak var store:EditorStore?
    var targetID:UUID?;var autoKey=false;var editAnchor=false
    private var selected:Clip? {targetID.flatMap{id in store?.project.clips.first{$0.id==id}} ?? (targetID == nil ? store?.selected:nil)}
    private let geometryCache=PreviewGeometry()
    private var original:Clip?
    private var originalGeometry:PreviewObjectGeometry?
    private var origin=CGPoint.zero
    private var handle:Int?
    private var rotating=false
    private var anchoring=false
    private var rotationDelta:Double=0
    private var lastRotationAngle:Double?
    private var changed=false
    private var pointerTracking:NSTrackingArea?
    private var textScroll:NSScrollView?
    private(set) var textInput:PreviewInlineTextView?
    private var editingTextID:UUID?
    private var editingOriginalText:String?
    private var editingDirectory:URL?
    private var finishingText=false
    override var isFlipped:Bool {true}
    override var acceptsFirstResponder:Bool {true}
    private var available:Bool {store.map{!$0.busy && !$0.playing} ?? false}
    func geometry(_ clip:Clip)->PreviewObjectGeometry? {guard let store else {return nil};return geometryCache.geometry(clip,project:store.project,directory:store.directory,time:store.playhead,size:bounds.size,onReady:{[weak self] in self?.needsDisplay=true; if let self {self.window?.invalidateCursorRects(for:self)}})}
    func prepareGeometry() {for clip in orderedClips() where [.image,.video].contains(clip.kind) {_=geometry(clip)}}
    private func locked(_ clip:Clip)->Bool {
        guard let store else {return true}
        return store.project.tracks[clip.track].locked || ancestors(clip).contains(where:{store.project.tracks[$0.track].locked})
    }
    private func ancestors(_ clip:Clip)->[Clip] {
        guard let store else {return []};var result:[Clip]=[],next=clip.parentID
        while let id=next,result.count<16,let c=store.project.clips.first(where:{$0.id==id}) {result.append(c);next=c.parentID}
        return result
    }
    private func orderedClips()->[Clip] {
        guard let store else {return []};let clips=store.project.visibleClips(at:store.playhead);var result:[Clip]=[]
        func append(_ clip:Clip,depth:Int) {guard depth<16 else {return};result.append(clip);for child in clips where child.parentID==clip.id {append(child,depth:depth+1)}}
        let roots=clips.filter{$0.parentID==nil}
        for clip in store.project.camera3D?.enabled == true ? CameraDepthOrder.sorted(roots) : roots {append(clip,depth:0)}
        return result
    }
    override func hitTest(_ point:NSPoint)->NSView? {available ? super.hitTest(point):nil}
    override func draw(_ dirtyRect:NSRect) {
        guard available,let clip=selected,let g=geometry(clip),let c=NSGraphicsContext.current?.cgContext else {return}
        let points=g.points,color=locked(clip) ? NSColor.gray:NSColor.cyan
        c.setStrokeColor(color.cgColor);c.setLineWidth(1.5);c.setLineDash(phase:0,lengths:[5,3]);c.move(to:points[0]);for i in [2,4,6] {c.addLine(to:points[i])};c.closePath();c.strokePath();c.setLineDash(phase:0,lengths:[])
        guard !locked(clip) else {return}
        if editAnchor {let p=g.pivot;c.setStrokeColor(NSColor.orange.cgColor);c.strokeEllipse(in:CGRect(x:p.x-6,y:p.y-6,width:12,height:12));c.move(to:CGPoint(x:p.x-10,y:p.y));c.addLine(to:CGPoint(x:p.x+10,y:p.y));c.move(to:CGPoint(x:p.x,y:p.y-10));c.addLine(to:CGPoint(x:p.x,y:p.y+10));c.strokePath();c.setStrokeColor(color.cgColor)}
        c.move(to:points[1]);c.addLine(to:g.rotationHandle);c.strokePath()
        c.setFillColor(NSColor.white.cgColor)
        for p in points {let r=CGRect(x:p.x-4,y:p.y-4,width:8,height:8);c.fill(r);c.stroke(r)}
        let r=CGRect(x:g.rotationHandle.x-5,y:g.rotationHandle.y-5,width:10,height:10);c.fillEllipse(in:r);c.strokeEllipse(in:r)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking {removeTrackingArea(pointerTracking)}
        let tracking=NSTrackingArea(rect:.zero,options:[.mouseMoved,.mouseEnteredAndExited,.cursorUpdate,.activeInKeyWindow,.inVisibleRect],owner:self,userInfo:nil)
        addTrackingArea(tracking);pointerTracking=tracking
    }
    func cursorKind(at point:CGPoint)->PreviewCursorKind {
        guard available,store != nil else {return .arrow}
        if let original,let g=originalGeometry {
            if anchoring {return .crosshair}
            if rotating {return .rotate}
            if let handle {return .resize(handle,transform:g.transform)}
            return locked(original) ? .arrow:.grabbing
        }
        if let clip=selected,let g=geometry(clip),!locked(clip) {
            if editAnchor,hypot(g.pivot.x-point.x,g.pivot.y-point.y)<11{return .crosshair}
            if hypot(g.rotationHandle.x-point.x,g.rotationHandle.y-point.y)<10 {return .rotate}
            if let i=g.points.firstIndex(where:{hypot($0.x-point.x,$0.y-point.y)<9}) {return .resize(i,transform:g.transform)}
            if clip.kind == .group,g.rect.contains((g.unprojected(point) ?? point).applying(g.transform.inverted())) {return .move}
        }
        for clip in orderedClips().reversed() where clip.kind != .group && (targetID == nil || clip.id==targetID) {
            guard let g=geometry(clip) else {continue}
            let local=(g.unprojected(point) ?? point).applying(g.transform.inverted())
            let hit=clip.kind == .shape ? ShapePainter.path(clip.shapeStyle ?? ShapeStyle(),in:g.rect).contains(local):g.rect.contains(local)
            if hit {return locked(clip) ? .arrow:.move}
        }
        return .arrow
    }
    override func cursorUpdate(with event:NSEvent) {cursorKind(at:convert(event.locationInWindow,from:nil)).cursor.set()}
    override func mouseMoved(with event:NSEvent) {cursorUpdate(with:event)}
    override func mouseEntered(with event:NSEvent) {cursorUpdate(with:event)}
    override func mouseExited(with event:NSEvent) {if original == nil {NSCursor.arrow.set()}}
    override func resetCursorRects() {
        guard available,let clip=selected,let g=geometry(clip),!locked(clip) else {return}
        for (i,p) in g.points.enumerated() {addCursorRect(CGRect(x:p.x-9,y:p.y-9,width:18,height:18),cursor:PreviewCursorKind.resize(i,transform:g.transform).cursor)}
        if editAnchor {let p=g.pivot;addCursorRect(CGRect(x:p.x-11,y:p.y-11,width:22,height:22),cursor:.crosshair)}
        let p=g.rotationHandle
        addCursorRect(CGRect(x:p.x-10,y:p.y-10,width:20,height:20),cursor:PreviewCursors.rotate)
    }
    override func mouseDown(with event:NSEvent) {
        guard available,let store else {return}
        window?.makeFirstResponder(self);origin=convert(event.locationInWindow,from:nil);original=nil;changed=false;handle=nil;rotating=false;anchoring=false;rotationDelta=0;lastRotationAngle=nil
        if event.clickCount >= 2 {
            for clip in orderedClips().reversed() where clip.kind != .group && (targetID == nil || clip.id==targetID) {
                guard let g=geometry(clip) else {continue}
                let local=(g.unprojected(origin) ?? origin).applying(g.transform.inverted())
                let hit=clip.kind == .shape ? ShapePainter.path(clip.shapeStyle ?? ShapeStyle(),in:g.rect).contains(local):g.rect.contains(local)
                guard hit else {continue}
                store.selectedID=clip.id;store.selectedIDs=[];store.selectedTrack=clip.track
                if [.text,.speech].contains(clip.kind),!locked(clip) {beginTextEditing(clip)}
                needsDisplay=true;return
            }
        }
        if let selected=selected,let g=geometry(selected),!locked(selected) {
            anchoring=editAnchor && hypot(g.pivot.x-origin.x,g.pivot.y-origin.y)<11
            handle=g.points.firstIndex{hypot($0.x-origin.x,$0.y-origin.y)<9}
            rotating=hypot(g.rotationHandle.x-origin.x,g.rotationHandle.y-origin.y)<10
            if anchoring || handle != nil || rotating || (selected.kind == .group && g.rect.contains((g.unprojected(origin) ?? origin).applying(g.transform.inverted()))) {original=selected;originalGeometry=g;cursorUpdate(with:event);return}
        }
        for clip in orderedClips().reversed() where clip.kind != .group && (targetID == nil || clip.id==targetID) {
            guard let g=geometry(clip) else {continue}
            let local=(g.unprojected(origin) ?? origin).applying(g.transform.inverted())
            let hit=clip.kind == .shape ? ShapePainter.path(clip.shapeStyle ?? ShapeStyle(),in:g.rect).contains(local):g.rect.contains(local)
            guard hit else {continue}
            store.selectedID=clip.id;store.selectedIDs=[];store.selectedTrack=clip.track
            if !locked(clip) {original=clip;originalGeometry=g}
            needsDisplay=true;cursorUpdate(with:event);return
        }
        if targetID == nil{store.selectedID=nil;store.selectedIDs=[]};needsDisplay=true
    }
    override func mouseDragged(with event:NSEvent) {
        guard available,let store,let base=original,let g=originalGeometry,!locked(base) else {return}
        let screenPoint=convert(event.locationInWindow,from:nil)
        guard let point=g.unprojected(screenPoint),let unprojectedOrigin=g.unprojected(origin) else{return}
        guard changed || hypot(screenPoint.x-origin.x,screenPoint.y-origin.y)>2 else {return}
        if !changed {store.checkpoint();store.pause();changed=true}
        cursorUpdate(with:event)
        var candidate=base
        let toProject=CGAffineTransform(scaleX:Double(store.project.width)/bounds.width,y:Double(store.project.height)/bounds.height)
        let parentPoint=point.applying(toProject).applying(g.parent.inverted()),parentOrigin=unprojectedOrigin.applying(toProject).applying(g.parent.inverted())
        if anchoring {
            let local=point.applying(g.transform.inverted())
            candidate.anchorPoint=NormalizedPoint(x:min(3,max(-2,0.5+local.x/Double(store.project.width))),y:min(3,max(-2,0.5+local.y/Double(store.project.height))))
            let actual=CGPoint(x:(candidate.anchorOffset.x-base.anchorOffset.x)*Double(store.project.width),y:(candidate.anchorOffset.y-base.anchorOffset.y)*Double(store.project.height))
            let transformed=actual.applying(CGAffineTransform(a:g.own.a,b:g.own.b,c:g.own.c,d:g.own.d,tx:0,ty:0))
            candidate.previewOffset(.x,by:(transformed.x-actual.x)/Double(store.project.width));candidate.previewOffset(.y,by:(transformed.y-actual.y)/Double(store.project.height))
        } else if rotating {
            let center=g.anchor.applying(g.own)
            let angle=atan2(parentPoint.y-center.y,parentPoint.x-center.x)
            let previous=lastRotationAngle ?? atan2(parentOrigin.y-center.y,parentOrigin.x-center.x)
            var step=angle-previous
            while step>Double.pi {step-=2*Double.pi};while step < -Double.pi {step+=2*Double.pi}
            rotationDelta+=step*180/Double.pi;lastRotationAngle=angle
            var delta=rotationDelta
            let shown=base.animated(at:store.playhead,aspectRatio:Double(store.project.width)/Double(store.project.height)).rotation ?? 0
            if event.modifierFlags.contains(.shift) {delta=((shown+delta)/15).rounded()*15-shown}
            candidate.previewOffset(.rotation,by:delta)
        } else if let handle {
            let local=point.applying(g.transform.inverted()),opposite=PreviewObjectGeometry.handles(g.rect)[(handle+4)%8],r=g.rect
            let start=PreviewObjectGeometry.handles(r)[handle]
            var fx=[1,5].contains(handle) ? 1:max(0.02,(local.x-opposite.x)*(start.x>=opposite.x ? 1:-1)/r.width)
            var fy=[3,7].contains(handle) ? 1:max(0.02,(local.y-opposite.y)*(start.y>=opposite.y ? 1:-1)/r.height)
            if let slice=base.nineSlice,!autoKey {
                if event.modifierFlags.contains(.shift) {let factor=[1,5].contains(handle) ? fy:[3,7].contains(handle) ? fx:abs(fx-1)>abs(fy-1) ? fx:fy;fx=factor;fy=factor}
                candidate.nineSlice?.width=NineSliceSettings.userSize(slice.width*fx,current:slice.width);candidate.nineSlice?.height=NineSliceSettings.userSize(slice.height*fy,current:slice.height)
                fx=(candidate.nineSlice?.width ?? slice.width)/slice.width;fy=(candidate.nineSlice?.height ?? slice.height)/slice.height
            } else {
                if event.modifierFlags.contains(.shift) {let factor=[1,5].contains(handle) ? fy:[3,7].contains(handle) ? fx:abs(fx-1)>abs(fy-1) ? fx:fy;fx=factor;fy=factor;candidate.previewMultiply(.scale,by:factor)}
                else {candidate.previewMultiply(.scaleX,by:fx);candidate.previewMultiply(.scaleY,by:fy)}
                let shown=base.animated(at:store.playhead,aspectRatio:Double(store.project.width)/Double(store.project.height)),resized=candidate.animated(at:store.playhead,aspectRatio:Double(store.project.width)/Double(store.project.height))
                fx=resized.scale*(resized.transform?.scaleX ?? 1)/(shown.scale*(shown.transform?.scaleX ?? 1))
                fy=resized.scale*(resized.transform?.scaleY ?? 1)/(shown.scale*(shown.transform?.scaleY ?? 1))
            }
            let delta=CGPoint(x:(opposite.x-g.anchor.x)*(1-fx),y:(opposite.y-g.anchor.y)*(1-fy)).applying(CGAffineTransform(a:g.own.a,b:g.own.b,c:g.own.c,d:g.own.d,tx:0,ty:0))
            candidate.previewOffset(.x,by:delta.x/Double(store.project.width));candidate.previewOffset(.y,by:delta.y/Double(store.project.height))
        } else {
            candidate.previewOffset(.x,by:(parentPoint.x-parentOrigin.x)/Double(store.project.width));candidate.previewOffset(.y,by:(parentPoint.y-parentOrigin.y)/Double(store.project.height))
        }
        if autoKey && !anchoring {candidate=base.recordingPreviewChange(candidate,at:min(base.motionEnd,max(base.motionStart,(base.motionTime(at:store.playhead)*Double(store.project.fps)).rounded()/Double(store.project.fps))))}
        do {var project=store.project;guard let index=project.clips.firstIndex(where:{$0.id==base.id}) else {return};project.clips[index]=candidate;_=try project.validated();store.edit(base.id,record:false){$0=candidate};needsDisplay=true}
        catch {store.error=error.localizedDescription}
    }
    override func mouseUp(with event:NSEvent) {original=nil;originalGeometry=nil;changed=false;needsDisplay=true;window?.invalidateCursorRects(for:self);cursorUpdate(with:event)}
    override func keyDown(with event:NSEvent) {
        if event.keyCode==53,changed {store?.undo();original=nil;originalGeometry=nil;changed=false;needsDisplay=true}
        else {super.keyDown(with:event)}
    }

    func beginTextEditing(_ clip:Clip) {
        guard available,let store else{return}
        guard store.finishPendingPreviewText() else{return}
        guard let clip=store.project.clips.first(where:{$0.id==clip.id}),!locked(clip),[.text,.speech].contains(clip.kind),let g=geometry(clip) else{return}
        store.previewTextEditor=self
        editingTextID=clip.id;editingOriginalText=clip.text;editingDirectory=store.directory
        let scroll=NSScrollView();scroll.hasVerticalScroller=true;scroll.autohidesScrollers=true;scroll.borderType = .bezelBorder
        scroll.toolTip=L("入力後は他の場所をクリックするか⌘＋Returnで確定、Escで取消。")
        let input=PreviewInlineTextView();input.isRichText=false;input.importsGraphics=false;input.allowsUndo=true
        input.font=NSFont.systemFont(ofSize:max(14,min(32,clip.fontSize * bounds.width / CGFloat(store.project.width))))
        input.textColor = .labelColor;input.backgroundColor = .textBackgroundColor;input.isVerticallyResizable=true;input.isHorizontallyResizable=false
        input.textContainer?.widthTracksTextView=true;input.string=clip.text;input.delegate=self
        input.finish={[weak self] commit in self?.finishTextEditing(commit:commit)}
        scroll.documentView=input;textScroll=scroll;textInput=input;addSubview(scroll)
        positionTextEditor(g);window?.makeFirstResponder(input);input.setSelectedRange(NSRange(location:0,length:(input.string as NSString).length))
    }
    private func positionTextEditor(_ geometry:PreviewObjectGeometry) {
        guard let scroll=textScroll else{return}
        let points=geometry.points
        let minX=points.map(\.x).min() ?? 0,maxX=points.map(\.x).max() ?? 0,minY=points.map(\.y).min() ?? 0,maxY=points.map(\.y).max() ?? 0
        let width=min(bounds.width,max(180,maxX-minX+24)),height=min(bounds.height,max(76,maxY-minY+24))
        let x=max(0,min(bounds.width-width,minX-12)),y=max(0,min(bounds.height-height,minY-12))
        scroll.frame=CGRect(x:x,y:y,width:width,height:height)
        if let input=textInput {input.minSize=NSSize(width:0,height:scroll.contentSize.height);input.maxSize=NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude);input.setFrameSize(NSSize(width:scroll.contentSize.width,height:max(scroll.contentSize.height,input.frame.height)))}
    }
    func syncTextEditor() {
        guard !finishingText,let id=editingTextID,let store else{return}
        guard editingDirectory == store.directory,let clip=store.project.clips.first(where:{$0.id==id}) else {store.error=L("編集中のプロジェクトが変わりました。入力内容をコピーしてから閉じてください。");return}
        if store.selectedID != id || store.playing || locked(clip) || !clip.active(at:store.playhead) {finishTextEditing(commit:true);return}
        if let g=geometry(clip) {positionTextEditor(g)}
    }
    func textDidEndEditing(_ notification:Notification) {if notification.object as? NSTextView === textInput {finishTextEditing(commit:true)}}
    @discardableResult func finishTextEditing(commit:Bool)->Bool {
        guard let id=editingTextID else{return true}
        guard !finishingText else{return false}
        finishingText=true;defer{finishingText=false}
        if commit {
            // NSTextView retains the composed text when the marked range is committed.
            if textInput?.hasMarkedText() == true {textInput?.unmarkText()}
            guard let store,let value=textInput?.string,let original=editingOriginalText,store.directory==editingDirectory,
                  let current=store.project.clips.first(where:{$0.id==id}),!store.busy,!locked(current) else {
                store?.error=L("編集中のテキストを確定できません。ロックや処理状態を確認してください。")
                return false
            }
            if value != original {
                guard current.text == original else {store.error=L("編集中にテキストが変更されたため、プレビューの変更を適用できませんでした。");return false}
                var candidate=current;candidate.text=value;candidate.textRuns=TextRunEditing.rebase(current.textRuns,old:current.text,new:value)
                do {try TextRunEditing.validate(candidate.textRuns,text:value)}catch{store.error=error.localizedDescription;return false}
                store.edit(id){$0.text=value}
                guard store.project.clips.first(where:{$0.id==id})?.text==value else {return false}
            }
        }
        if store?.previewTextEditor === self {store?.previewTextEditor=nil}
        editingTextID=nil;editingOriginalText=nil;editingDirectory=nil
        textInput?.delegate=nil;textInput?.finish=nil;textScroll?.removeFromSuperview();textInput=nil;textScroll=nil
        needsDisplay=true;return true
    }
}
