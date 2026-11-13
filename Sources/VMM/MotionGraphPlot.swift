import AppKit
import SwiftUI

struct MotionGraphPlot:NSViewRepresentable {
    @ObservedObject var store:EditorStore
    let clip:Clip;let tracks:[AnimationTrack];let speed:Bool;let domain:ClosedRange<Double>;let low:Double;let high:Double
    let activeProperty:AnimatedProperty?;let onSelect:(AnimatedProperty,Double)->Void
    func makeNSView(context:Context)->MotionGraphPlotView{MotionGraphPlotView()}
    func updateNSView(_ view:MotionGraphPlotView,context:Context){if view.clip?.id != clip.id || view.speed != speed{view.cancelDrag()};view.store=store;view.clip=clip;view.tracks=tracks;view.speed=speed;view.domain=domain;view.low=low;view.high=high;view.activeProperty=activeProperty;view.onSelect=onSelect;view.needsDisplay=true;view.window?.invalidateCursorRects(for:view)}
}
final class MotionGraphPlotView:NSView {
    weak var store:EditorStore?;var clip:Clip?;var tracks:[AnimationTrack]=[];var speed=false;var domain:ClosedRange<Double>=0...1;var low:Double=0;var high:Double=100
    var activeProperty:AnimatedProperty?;var onSelect:((AnimatedProperty,Double)->Void)?
    private var selected:(AnimatedProperty,UUID)?
    private struct Drag {var clip:Clip;var track:AnimationTrack;var key:AnimationKeyframe;var origin:CGPoint;var domain:ClosedRange<Double>;var low:Double;var high:Double;var value:Double;var time:Double;var changed=false}
    private var drag:Drag?;private var actions:[()->Void]=[]
    private let colors:[NSColor]=[.systemCyan,.systemOrange,.systemGreen,.systemPink,.systemPurple,.systemYellow]
    override var isFlipped:Bool{true};override var acceptsFirstResponder:Bool{true}
    var plotWidth:Double{max(1,bounds.width-24)}
    func point(_ key:AnimationKeyframe,track:AnimationTrack)->CGPoint {
        guard let clip else{return .zero};let r=drag?.domain ?? domain,l=drag?.low ?? low,h=drag?.high ?? high
        let value=MotionGraph.value(track,clip:clip,time:key.time,speed:speed,domain:r)
        return CGPoint(x:12+(key.time-r.lowerBound)/max(0.000001,r.upperBound-r.lowerBound)*plotWidth,y:bounds.height*(1-(value-l)/max(0.000001,h-l)))
    }
    func hit(_ point:CGPoint)->(AnimationTrack,AnimationKeyframe)? {
        guard clip != nil else{return nil};var hits:[(AnimationTrack,AnimationKeyframe,Double)]=[]
        for track in tracks{for key in track.keys where key.time>=domain.lowerBound && key.time<=domain.upperBound{let p=self.point(key,track:track),distance=hypot(p.x-point.x,p.y-point.y);if distance<=13{hits.append((track,key,distance))}}}
        // A chosen channel makes identical overlapping points unambiguous.
        if let activeProperty,let chosen=hits.filter({$0.0.property==activeProperty}).min(by:{$0.2<$1.2}){return(chosen.0,chosen.1)}
        guard let nearest=hits.min(by:{$0.2<$1.2}) else{return nil};return(nearest.0,nearest.1)
    }
    func cancelDrag(){drag=nil;needsDisplay=true}
    override func draw(_ dirtyRect:NSRect){guard let clip,let ctx=NSGraphicsContext.current?.cgContext else{return};ctx.saveGState();defer{ctx.restoreGState()};ctx.clip(to:bounds);NSColor.labelColor.withAlphaComponent(0.06).setFill();bounds.fill()
        let range=drag?.domain ?? domain,l=drag?.low ?? low,h=drag?.high ?? high
        ctx.setStrokeColor(NSColor.labelColor.withAlphaComponent(0.16).cgColor);ctx.setLineWidth(1)
        for n in 0...4{let y=bounds.height*Double(n)/4;ctx.move(to:CGPoint(x:0,y:y));ctx.addLine(to:CGPoint(x:bounds.width,y:y))};for n in 0...8{let x=12+plotWidth*Double(n)/8;ctx.move(to:CGPoint(x:x,y:0));ctx.addLine(to:CGPoint(x:x,y:bounds.height))};ctx.strokePath()
        for (index,original) in tracks.enumerated(){var track=original;if let d=drag,d.track.property==track.property,let i=track.keys.firstIndex(where:{$0.id==d.key.id}){track.keys[i].time=d.time;track.keys[i].value=d.value}
            ctx.setStrokeColor(colors[index%colors.count].cgColor);ctx.setLineWidth(2)
            for n in 0...240{let time=range.lowerBound+(range.upperBound-range.lowerBound)*Double(n)/240,value=MotionGraph.value(track,clip:clip,time:time,speed:speed,domain:range),point=CGPoint(x:12+plotWidth*Double(n)/240,y:bounds.height*(1-(value-l)/max(0.000001,h-l)));if n==0{ctx.move(to:point)}else{ctx.addLine(to:point)}};ctx.strokePath()
            for key in track.keys where key.time>=range.lowerBound && key.time<=range.upperBound{let p=point(key,track:track),chosen=selected?.0==track.property && selected?.1==key.id;ctx.setFillColor((chosen ? NSColor.labelColor:colors[index%colors.count]).cgColor);ctx.move(to:CGPoint(x:p.x,y:p.y-6));ctx.addLine(to:CGPoint(x:p.x+6,y:p.y));ctx.addLine(to:CGPoint(x:p.x,y:p.y+6));ctx.addLine(to:CGPoint(x:p.x-6,y:p.y));ctx.closePath();ctx.fillPath()}
        }
        // Keep the selected handle visible when curves or other keys overlap.
        if let selected,let original=tracks.first(where:{$0.property==selected.0}){var track=original;if let d=drag,let i=track.keys.firstIndex(where:{$0.id==d.key.id}),d.track.property==track.property{track.keys[i].time=d.time;track.keys[i].value=d.value};if let key=track.keys.first(where:{$0.id==selected.1}),range.contains(key.time){let p=point(key,track:track);ctx.setFillColor(NSColor.white.cgColor);ctx.setStrokeColor(NSColor.black.cgColor);ctx.setLineWidth(1);ctx.move(to:CGPoint(x:p.x,y:p.y-7));ctx.addLine(to:CGPoint(x:p.x+7,y:p.y));ctx.addLine(to:CGPoint(x:p.x,y:p.y+7));ctx.addLine(to:CGPoint(x:p.x-7,y:p.y));ctx.closePath();ctx.drawPath(using:.fillStroke)}}
        ctx.setStrokeColor(NSColor.systemOrange.cgColor);ctx.setLineWidth(1);let x=12+(clip.motionTime(at:store?.playhead ?? clip.start)-range.lowerBound)/max(0.000001,range.upperBound-range.lowerBound)*plotWidth;ctx.move(to:CGPoint(x:x,y:0));ctx.addLine(to:CGPoint(x:x,y:bounds.height));ctx.strokePath()
    }
    override func resetCursorRects(){for track in tracks{for key in track.keys where key.time>=domain.lowerBound && key.time<=domain.upperBound{let p=point(key,track:track);addCursorRect(CGRect(x:p.x-12,y:p.y-12,width:24,height:24),cursor:store?.busy==true || clip.map({store?.project.tracks[$0.track].locked==true})==true ? .arrow:.openHand)}}}
    override func mouseDown(with event:NSEvent){guard let clip,let store else{return};window?.makeFirstResponder(self);let position=convert(event.locationInWindow,from:nil);guard let (track,key)=hit(position) else{return};selected=(track.property,key.id);onSelect?(track.property,key.time);store.seek(min(clip.end-0.000001,max(clip.start,clip.start+key.time-clip.motionStart)))
        if !store.busy,!store.project.tracks[clip.track].locked{drag=Drag(clip:clip,track:track,key:key,origin:position,domain:domain,low:low,high:high,value:key.value,time:key.time)};needsDisplay=true
    }
    override func mouseDragged(with event:NSEvent){guard var d=drag,let store else{return};let p=convert(event.locationInWindow,from:nil),delta=CGPoint(x:p.x-d.origin.x,y:p.y-d.origin.y),factor=d.track.property.percent ? 100.0:1.0,step=1/Double(store.project.fps)
        let keys=d.track.keys.sorted{$0.time<$1.time},index=keys.firstIndex{$0.id==d.key.id}!,lo=index>0 ? keys[index-1].time+step:d.domain.lowerBound,hi=index+1<keys.count ? keys[index+1].time-step:d.domain.upperBound
        let proposed=d.key.time+delta.x/plotWidth*(d.domain.upperBound-d.domain.lowerBound)
        d.time=lo<=hi ? min(hi,max(lo,d.clip.motionStart+((proposed-d.clip.motionStart)/step).rounded()*step)):d.key.time
        if !speed{d.value=min(d.track.property.range.upperBound,max(d.track.property.range.lowerBound,d.key.value-delta.y/max(1,bounds.height)*(d.high-d.low)/factor))}
        d.changed=abs(d.time-d.key.time)>0.000001 || abs(d.value-d.key.value)>0.000001;drag=d;NSCursor.closedHand.set();needsDisplay=true
    }
    override func mouseUp(with event:NSEvent){defer{cancelDrag();NSCursor.openHand.set()};guard let d=drag,d.changed,let store else{return}
        guard store.project.clips.first(where:{$0.id==d.clip.id})==d.clip else{store.error=L("ドラッグ中に設定が変更されました。もう一度操作してください。");return}
        do{try store.editGraphKey(d.clip.id,property:d.track.property,keyID:d.key.id,time:d.time,value:d.value);if let key=store.project.clips.first(where:{$0.id==d.clip.id})?.animation?.tracks.first(where:{$0.property==d.track.property})?.keys.first(where:{$0.id==d.key.id}){onSelect?(d.track.property,key.time);store.seek(min(d.clip.end-0.000001,max(d.clip.start,d.clip.start+key.time-d.clip.motionStart)))}}catch{store.error=error.localizedDescription}
    }
    override func menu(for event:NSEvent)->NSMenu? {guard let clip,let store,let (track,key)=hit(convert(event.locationInWindow,from:nil)) else{return nil};let menu=NSMenu();menu.autoenablesItems=false;actions=[]
        func item(_ title:String,_ action:@escaping ()throws->Void){let item=NSMenuItem(title:L(title),action:#selector(run(_:)),keyEquivalent:"");item.target=self;item.tag=actions.count;item.isEnabled = !store.busy && !store.project.tracks[clip.track].locked;actions.append{do{try action()}catch{store.error=error.localizedDescription}};menu.addItem(item)}
        item("複製"){_=try store.duplicateAnimationKey(clip.id,lane:.property(track.property),keyID:key.id)}
        item("削除"){try store.deleteAnimationKey(clip.id,lane:.property(track.property),keyID:key.id)};return menu
    }
    @objc private func run(_ item:NSMenuItem){if actions.indices.contains(item.tag){actions[item.tag]()}}
}
