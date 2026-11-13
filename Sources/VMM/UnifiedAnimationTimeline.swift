import AppKit
import SwiftUI

struct UnifiedAnimationTimeline:NSViewRepresentable {
    @ObservedObject var store:EditorStore;let clip:Clip
    @Binding var selection:MotionSelection?
    var onSelect:(AnimationLane)->Void
    var allKeys=true;var zoom=1.0;var position=0.0
    var showRuler=true;var rulerOnly=false
    func makeNSView(context:Context)->UnifiedAnimationTimelineView{UnifiedAnimationTimelineView()}
    func updateNSView(_ view:UnifiedAnimationTimelineView,context:Context){view.store=store;view.clipID=clip.id;view.selection=selection;view.allKeys=allKeys;view.zoom=zoom;view.position=position;view.showRuler=showRuler;view.rulerOnly=rulerOnly;view.onSelect={point in selection=point;if let lane=point?.lane{onSelect(lane)}};view.needsDisplay=true;view.window?.invalidateCursorRects(for:view)}
}
final class UnifiedAnimationTimelineView:NSView {
    weak var store:EditorStore?;var clipID:UUID?;var selection:MotionSelection?;var allKeys=true;var zoom=1.0;var position=0.0;var showRuler=true;var rulerOnly=false;var onSelect:((MotionSelection?)->Void)?
    private var domainClip:Clip?;private var domainAllKeys=false;private var domainZoom=0.0;private var domainPosition = -1.0;private var cachedDomain:ClosedRange<Double>=0...1
    private(set) var domainComputations=0
    private var dragged:MotionSelection?;private var dragX:Double?;private var actions:[()->Void]=[]
    var clip:Clip?{store?.project.clips.first{$0.id==clipID}}
    override var isFlipped:Bool{true};override var acceptsFirstResponder:Bool{true}
    var rowHeight:Double{max(32,(store?.settings.textPoints ?? 12)+18)}
    var labelWidth:Double{min(bounds.width*0.45,max(190,bounds.width*0.24,(store?.settings.textPoints ?? 12)*18))}
    var headerHeight:Double{showRuler ? 30:0}
    var plotWidth:Double{max(1,bounds.width-labelWidth-18)}
    func domain(_ c:Clip)->ClosedRange<Double>{
        // x() is called for every key. Reuse the domain instead of projecting every
        // lane's complete key list again for each point in a tracking result.
        if domainClip != c || domainAllKeys != allKeys || domainZoom != zoom || domainPosition != position {
            let full=allKeys ? c.animationDomain:c.motionStart...c.motionEnd
            let factor=min(32,max(1,zoom)),span=(full.upperBound-full.lowerBound)/factor
            let start=full.lowerBound+(full.upperBound-full.lowerBound-span)*min(1,max(0,position))
            cachedDomain=start...(start+span);domainClip=c;domainAllKeys=allKeys;domainZoom=zoom;domainPosition=position;domainComputations+=1
        }
        return cachedDomain
    }
    func x(_ time:Double,_ c:Clip)->Double{let r=domain(c);return labelWidth+(time-r.lowerBound)/max(0.000001,r.upperBound-r.lowerBound)*plotWidth}
    func time(_ point:CGPoint,_ c:Clip)->Double{let r=domain(c);return r.lowerBound+min(r.upperBound-r.lowerBound,max(0,(point.x-labelWidth)/plotWidth*(r.upperBound-r.lowerBound)))}
    func lane(at point:CGPoint,_ c:Clip)->AnimationLane?{let index=Int(floor((point.y-headerHeight)/rowHeight));return c.animationLanes.indices.contains(index) ? c.animationLanes[index]:nil}
    func key(at point:CGPoint,_ c:Clip)->MotionSelection? {
        guard let lane=lane(at:point,c),let index=c.animationLanes.firstIndex(of:lane) else{return nil}
        let y=headerHeight+Double(index)*rowHeight+rowHeight/2
        return lane.keys(c).filter{$0.time>=domain(c).lowerBound && $0.time<=domain(c).upperBound && hypot(x($0.time,c)-point.x,y-point.y)<=11}.min{hypot(x($0.time,c)-point.x,y-point.y)<hypot(x($1.time,c)-point.x,y-point.y)}.map{selection($0,lane:lane)}
    }
    private func selection(_ key:AnimationKeyframe,lane:AnimationLane)->MotionSelection {MotionSelection(time:key.time,property:{if case .property(let p)=lane{return p};return nil}(),psdKeyID:lane == .psd ? key.id:nil,lane:lane,keyID:key.id)}
    private var selectedLane:AnimationLane?{selection?.lane ?? selection?.property.map{.property($0)} ?? (selection?.psdKeyID != nil ? .psd:nil)}
    private func text(_ s:String,_ rect:CGRect,color:NSColor = .secondaryLabelColor){let paragraph=NSMutableParagraphStyle();paragraph.lineBreakMode = .byTruncatingTail;(s as NSString).draw(in:rect,withAttributes:[.font:NSFont.systemFont(ofSize:store?.settings.textPoints ?? 12),.foregroundColor:color,.paragraphStyle:paragraph])}
    override func draw(_ dirtyRect:NSRect){
        guard let c=clip,let ctx=NSGraphicsContext.current?.cgContext else{return};NSColor.controlBackgroundColor.setFill();bounds.fill()
        let lanes=rulerOnly ? []:c.animationLanes
        let visibleStart=max(domain(c).lowerBound,c.motionStart),visibleEnd=min(domain(c).upperBound,c.motionEnd)
        if visibleEnd>visibleStart {ctx.setFillColor(NSColor.systemCyan.withAlphaComponent(0.035).cgColor);ctx.fill(CGRect(x:x(visibleStart,c),y:headerHeight,width:x(visibleEnd,c)-x(visibleStart,c),height:max(0,bounds.height-headerHeight)))}
        for (index,lane) in lanes.enumerated(){let top=headerHeight+Double(index)*rowHeight;if selectedLane==lane{ctx.setFillColor(NSColor.systemOrange.withAlphaComponent(0.12).cgColor);ctx.fill(CGRect(x:0,y:top,width:bounds.width,height:rowHeight))}
            text(lane.title(c)+(lane.enabled(c) ? "":" · "+L("無効")),CGRect(x:10,y:top+6,width:labelWidth-17,height:rowHeight-6),color:lane.enabled(c) ? .labelColor:.secondaryLabelColor)
            if lane.keys(c).isEmpty{text(L(lane.canKeyframe ? "固定値 · ダブルクリックでキーを追加":"時間指定 · 設定欄で編集"),CGRect(x:labelWidth+8,y:top+6,width:plotWidth-16,height:rowHeight-6))}
            ctx.setStrokeColor(NSColor.separatorColor.cgColor);ctx.move(to:CGPoint(x:0,y:top+rowHeight));ctx.addLine(to:CGPoint(x:bounds.width,y:top+rowHeight));ctx.strokePath()
        }
        let steps=max(2,Int(plotWidth/100))
        for i in 0...steps{let px=labelWidth+plotWidth*Double(i)/Double(steps);if showRuler{text(String(format:"%.2f s",domain(c).lowerBound-c.motionStart+(domain(c).upperBound-domain(c).lowerBound)*Double(i)/Double(steps)),CGRect(x:min(bounds.width-78,max(labelWidth-15,px-15)),y:3,width:75,height:24))};ctx.setStrokeColor(NSColor.separatorColor.cgColor);ctx.move(to:CGPoint(x:px,y:headerHeight));ctx.addLine(to:CGPoint(x:px,y:bounds.height));ctx.strokePath()}
        for (index,lane) in lanes.enumerated(){let y=headerHeight+Double(index)*rowHeight+rowHeight/2;let keys=lane.keys(c).filter{$0.time>=domain(c).lowerBound && $0.time<=domain(c).upperBound}
            if case .timing(let timing)=lane{let range=timing.interval(c),a=max(domain(c).lowerBound,c.motionStart,range.0),b=min(domain(c).upperBound,c.motionEnd,range.1);if b>a{ctx.setFillColor(NSColor.systemBlue.withAlphaComponent(0.18).cgColor);ctx.fill(CGRect(x:x(a,c),y:y-8,width:x(b,c)-x(a,c),height:16))}}
            if let first=keys.min(by:{$0.time<$1.time}),let last=keys.max(by:{$0.time<$1.time}){ctx.setStrokeColor(NSColor.systemCyan.withAlphaComponent(0.4).cgColor);ctx.move(to:CGPoint(x:x(first.time,c),y:y));ctx.addLine(to:CGPoint(x:x(last.time,c),y:y));ctx.strokePath()}
            for key in keys{let chosen=(selectedLane==lane && selection?.keyID==key.id) || (selectedLane==lane && abs((selection?.time ?? -1)-key.time)<0.000001),px=dragged?.lane==lane && dragged?.keyID==key.id ? dragX ?? x(key.time,c):x(key.time,c);ctx.setFillColor((chosen ? NSColor.systemOrange:lane.enabled(c) ? NSColor.systemCyan:NSColor.systemGray).cgColor);ctx.move(to:CGPoint(x:px,y:y-6));ctx.addLine(to:CGPoint(x:px+6,y:y));ctx.addLine(to:CGPoint(x:px,y:y+6));ctx.addLine(to:CGPoint(x:px-6,y:y));ctx.closePath();ctx.fillPath()}
        }
        if lanes.isEmpty && !rulerOnly{text(L("設定項目を追加すると、ここにキーフレームが表示されます。"),CGRect(x:20,y:48,width:bounds.width-40,height:30))}
        let playTime=c.motionTime(at:store?.playhead ?? c.start)
        if domain(c).contains(playTime) {let play=x(playTime,c);ctx.setStrokeColor(NSColor.systemOrange.cgColor);ctx.move(to:CGPoint(x:play,y:headerHeight));ctx.addLine(to:CGPoint(x:play,y:bounds.height));ctx.strokePath()}
    }
    override func resetCursorRects(){guard !rulerOnly,let c=clip else{return};for (i,lane) in c.animationLanes.enumerated(){for key in lane.keys(c) where key.time>=domain(c).lowerBound && key.time<=domain(c).upperBound{addCursorRect(CGRect(x:x(key.time,c)-10,y:headerHeight+Double(i)*rowHeight+rowHeight/2-10,width:20,height:20),cursor:.resizeLeftRight)}}}
    override func mouseDown(with event:NSEvent){guard let c=clip,let store else{return};window?.makeFirstResponder(self);let point=convert(event.locationInWindow,from:nil)
        if rulerOnly{store.seek(min(c.end-0.000001,max(c.start,c.start+time(point,c)-c.motionStart)));return}
        if let key=key(at:point,c){selection=key;onSelect?(key);store.seek(min(c.end-0.000001,max(c.start,c.start+key.time-c.motionStart)));if !store.busy,!store.playing,!store.project.tracks[c.track].locked{dragged=key}}
        else{let t=point.x<labelWidth ? c.motionTime(at:store.playhead):time(point,c),lane=lane(at:point,c);let s=MotionSelection(time:t,property:{if case .property(let p)?=lane{return p};return nil}(),lane:lane);selection=s;onSelect?(s);if point.x>=labelWidth{store.seek(min(c.end-0.000001,max(c.start,c.start+t-c.motionStart)))}
            if event.clickCount==2,let lane,lane.canKeyframe,point.x>=labelWidth{insert(lane,at:t,c)}
        };needsDisplay=true
    }
    override func mouseDragged(with event:NSEvent){guard dragged != nil else{return};dragX=min(bounds.width-18,max(labelWidth,convert(event.locationInWindow,from:nil).x));NSCursor.resizeLeftRight.set();needsDisplay=true}
    override func mouseUp(with event:NSEvent){defer{dragged=nil;dragX=nil;needsDisplay=true};guard let c=clip,let d=dragged,let lane=d.lane,let id=d.keyID,let x=dragX,let store else{return}
        do{try store.editAnimationKey(c.id,lane:lane,keyID:id,time:time(CGPoint(x:x,y:0),c));select(id,lane:lane,c);if let key=lane.keys(store.project.clips.first{$0.id==c.id}!).first(where:{$0.id==id}){store.seek(min(c.end-0.000001,max(c.start,c.start+key.time-c.motionStart)))}}catch{store.error=error.localizedDescription}
    }
    private func select(_ id:UUID,lane:AnimationLane,_ c:Clip){if let current=store?.project.clips.first(where:{$0.id==c.id}),let key=lane.keys(current).first(where:{$0.id==id}){let s=selection(key,lane:lane);selection=s;onSelect?(s)}}
    private func insert(_ lane:AnimationLane,at time:Double,_ c:Clip){do{if let key=try store?.insertAnimationKey(c.id,lane:lane,at:time){select(key.id,lane:lane,c)}}catch{store?.error=error.localizedDescription}}
    override func menu(for event:NSEvent)->NSMenu?{guard !rulerOnly,let c=clip,let store else{return nil};let point=convert(event.locationInWindow,from:nil),hit=key(at:point,c),lane=hit?.lane ?? lane(at:point,c);let menu=NSMenu();menu.autoenablesItems=false;actions=[]
        func item(_ title:String,enabled:Bool,_ action:@escaping ()throws->Void){let entry=NSMenuItem(title:L(title),action:#selector(run(_:)),keyEquivalent:"");entry.target=self;entry.tag=actions.count;entry.isEnabled=enabled;actions.append{do{try action()}catch{store.error=error.localizedDescription}};menu.addItem(entry)}
        let editable = !store.busy && !store.playing && !store.project.tracks[c.track].locked
        if let lane{item("ここにキーフレームを追加",enabled:editable && lane.canKeyframe){self.insert(lane,at:point.x>=self.labelWidth ? self.time(point,c):c.motionTime(at:store.playhead),c)}}
        if let hit,let lane=hit.lane,let id=hit.keyID {item("複製",enabled:editable){let key=try store.duplicateAnimationKey(c.id,lane:lane,keyID:id);self.select(key.id,lane:lane,c)};item("削除",enabled:editable){try store.deleteAnimationKey(c.id,lane:lane,keyID:id);self.selection=nil;self.onSelect?(nil)}}
        return menu
    }
    @objc private func run(_ item:NSMenuItem){if actions.indices.contains(item.tag){actions[item.tag]()}}
    override func keyDown(with event:NSEvent){guard let c=clip,let s=selection,let lane=s.lane,let store else{super.keyDown(with:event);return};guard let id=s.keyID else{if [51,117].contains(event.keyCode){return};if [123,124].contains(event.keyCode){store.seek(store.playhead+(event.keyCode==123 ? -1.0:1.0)/Double(store.project.fps));return};super.keyDown(with:event);return}
        do{if [51,117].contains(event.keyCode){try store.deleteAnimationKey(c.id,lane:lane,keyID:id);selection=nil;onSelect?(nil)}else if [123,124].contains(event.keyCode){let delta=(event.keyCode==123 ? -1.0:1.0)/Double(store.project.fps);if event.modifierFlags.contains(.option){try store.editAnimationKey(c.id,lane:lane,keyID:id,time:s.time+delta);select(id,lane:lane,c)}else{store.seek(store.playhead+delta)}}else{super.keyDown(with:event)}}catch{store.error=error.localizedDescription}
    }
}
