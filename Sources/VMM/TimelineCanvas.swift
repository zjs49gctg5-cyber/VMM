import SwiftUI
import AppKit

/// AppKit owns hit testing and drag coordinates so changing a clip cannot move
/// the gesture's coordinate system. The project is committed once on mouse-up.
struct TimelineCanvas: NSViewRepresentable {
    @ObservedObject var store: EditorStore
    @ObservedObject var clock:PlaybackClock
    init(store:EditorStore){self.store=store;self.clock=store.playbackClock}
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true; scroll.drawsBackground = false
        let canvas = TimelineNSView(); canvas.store = store
        scroll.documentView = canvas
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let canvas = scroll.documentView as? TimelineNSView else { return }
        let oldBounds=scroll.contentView.bounds
        let oldPlayhead=canvas.previousHeader+store.playhead*canvas.previousZoom
        let anchor=oldBounds.minX...oldBounds.maxX ~= oldPlayhead ? oldPlayhead:oldBounds.midX
        let anchorTime=max(0,(anchor-canvas.previousHeader)/canvas.previousZoom)
        canvas.store = store
        let changed=canvas.hasLayout && (canvas.previousZoom != store.zoom || canvas.previousHeader != canvas.header)
        let verticalChanged=canvas.hasLayout && canvas.previousRow != canvas.row
        let anchorTrack=max(0,(oldBounds.midY-canvas.previousRuler)/canvas.previousRow)
        canvas.frame.size = NSSize(width: max(scroll.contentSize.width, canvas.header + max(20, max(store.project.duration,store.project.markers?.map(\.time).max() ?? 0) + 8) * store.zoom), height: max(scroll.contentSize.height, canvas.ruler + CGFloat(canvas.folderLayout.rows.count) * canvas.row))
        if changed || verticalChanged {
            let origin=changed ? canvas.header+anchorTime*store.zoom-(anchor-oldBounds.minX):oldBounds.minX
            let verticalOrigin=verticalChanged ? canvas.ruler+anchorTrack*canvas.row-oldBounds.height/2:oldBounds.minY
            scroll.contentView.scroll(to:NSPoint(x:max(0,min(canvas.frame.width-scroll.contentSize.width,origin)),y:max(0,min(canvas.frame.height-scroll.contentSize.height,verticalOrigin))))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        canvas.previousZoom=store.zoom;canvas.previousHeader=canvas.header;canvas.previousRow=canvas.row;canvas.previousRuler=canvas.ruler;canvas.hasLayout=true
        canvas.needsDisplay = true
        canvas.window?.invalidateCursorRects(for: canvas)
    }
}

final class TimelineNSView: NSView {
    weak var store: EditorStore?
    var hasLayout=false
    var previousZoom:Double=72
    var previousHeader:Double=160
    var previousRow:CGFloat=47
    var previousRuler:CGFloat=27
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    private var markerOriginal:TimelineMarker?
    private var markerPreview:TimelineMarker?
    private var markerFocused=false
    private var origin = NSPoint.zero
    private var original: Clip?
    private var preview: Clip?
    private var originals: [Clip] = []
    private var previews: [UUID:Clip] = [:]
    private var dragTargets:Set<UUID>=[]
    private var assetPreview: Clip?
    private var edge = 0
    private var layerDrag: Int?
    private var layerTarget: Int?
    private var didDrag = false
    private var menuActions: [() -> Void] = []
    private var uiScale:CGFloat {max(1,max(store?.settings.textPoints ?? 12,store?.settings.iconPoints ?? 12)/12)}
    var header:CGFloat {160*uiScale}
    var row:CGFloat {47*uiScale*max(0.65,min(3,store?.layerZoom ?? 1))}
    var ruler:CGFloat {49*uiScale}
    private var trackIcons:[String:NSImage]=[:]
    var folderLayout:TrackFolderLayout {TrackFolderLayout(project:store?.project ?? Project(),collapsed:store?.collapsedTrackFolders ?? [])}
    private var dark:Bool {effectiveAppearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua}
    private var accent:NSColor {dark ? NSColor(calibratedRed:0.4,green:0.8,blue:0.98,alpha:1):.systemBlue}
    override func viewDidChangeEffectiveAppearance() {super.viewDidChangeEffectiveAppearance();trackIcons.removeAll();needsDisplay=true}
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.string,.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }
    func rect(_ c: Clip) -> NSRect {
        rect(c,layout:folderLayout)
    }
    private func rect(_ c:Clip,layout:TrackFolderLayout)->NSRect {
        guard let visibleRow=layout.row(forTrack:c.track) else{return .null}
        return NSRect(x: header + c.start * (store?.zoom ?? 72), y: ruler + CGFloat(visibleRow) * row + 4*uiScale, width: max(2, c.duration * (store?.zoom ?? 72)), height:row-10*uiScale)
    }
    func track(at p: NSPoint) -> Int? {
        guard store != nil, p.y >= ruler else { return nil }
        let index = Int((p.y - ruler) / row)
        return folderLayout.track(atRow:index)
    }
    private func folder(at p:NSPoint)->UUID? {
        guard p.y>=ruler else{return nil}
        let index=Int((p.y-ruler)/row),rows=folderLayout.rows
        guard rows.indices.contains(index),case .folder(let id)=rows[index] else{return nil};return id
    }
    private func dragTrack(at p:NSPoint)->Int? {
        let rows=folderLayout.rows
        if p.y<ruler {return rows.compactMap{if case .track(let i)=$0{return i};return nil}.first}
        if p.y>=ruler+CGFloat(rows.count)*row {return rows.compactMap{if case .track(let i)=$0{return i};return nil}.last}
        return track(at:p)
    }
    private func clip(at p: NSPoint) -> Clip? {
        guard let store else{return nil}
        let layout=folderLayout
        return store.project.clips.reversed().first { rect($0,layout:layout).contains(p) }
    }
    private func text(_ value: String, _ rect: NSRect, color: NSColor = .secondaryLabelColor, size: CGFloat = 12) {
        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
        (value as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize:max(12,size)/12*(store?.settings.textPoints ?? 12)), .foregroundColor: color, .paragraphStyle: style])
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let store else { return }
        let selection=store.selection
        let layout=folderLayout
        let assetsByID=Dictionary(store.project.assets.map{($0.id,$0)},uniquingKeysWith:{first,_ in first})
        NSColor(calibratedWhite:dark ? 0.065:0.91,alpha:1).setFill(); bounds.fill()
        for (rowIndex,entry) in layout.rows.enumerated() {
            let y = ruler + CGFloat(rowIndex) * row
            guard NSRect(x:0,y:y,width:bounds.width,height:row).intersects(visibleRect) else {continue}
            if case .folder(let id)=entry {
                NSColor(calibratedWhite:dark ? 0.15:0.83,alpha:1).setFill();NSRect(x:0,y:y,width:bounds.width,height:row-1).fill()
                let folder=store.project.trackFolders.first{$0.id==id}
                text((store.collapsedTrackFolders.contains(id) ? "▸ ":"▾ ") + (folder?.name ?? ""),NSRect(x:9*uiScale,y:y+(row-20*uiScale)/2,width:header-18*uiScale,height:20*uiScale),color:.labelColor)
                continue
            }
            guard case .track(let i)=entry else{continue}
            let track=store.project.tracks[i]
            NSColor(calibratedWhite:dark ? (i % 2 == 0 ? 0.095:0.08):(i % 2 == 0 ? 0.96:0.93),alpha:1).setFill()
            NSRect(x: 0, y: y, width: bounds.width, height: row - 1).fill()
            if store.selectedTrack == i { accent.withAlphaComponent(0.12).setFill(); NSRect(x: 0, y: y, width: header, height: row - 1).fill() }
            text((track.folderID == nil ? "≡  ":"  ≡  ") + track.name, NSRect(x:9*uiScale,y:y+(row-20*uiScale)/2,width:85*uiScale,height:20*uiScale), color: .labelColor)
            for (x, symbol) in [(CGFloat(102), track.visible ? "eye" : "eye.slash"), (CGFloat(123), track.muted ? "speaker.slash" : "speaker.wave.2"), (CGFloat(144), track.locked ? "lock.fill" : "lock.open")] {
                if trackIcons[symbol] == nil {trackIcons[symbol]=NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(paletteColors: [.labelColor]))}
                let image=trackIcons[symbol]
                image?.draw(in: NSRect(x:x*uiScale-CGFloat(store.settings.iconPoints)/2,y:y+(row-CGFloat(store.settings.iconPoints))/2,width:store.settings.iconPoints,height:store.settings.iconPoints))
            }
        }
        text(L("レイヤー")+"  ＋", NSRect(x:10*uiScale,y:5*uiScale,width:140*uiScale,height:22*uiScale))
        let ticks=TimelineRuler(zoom:store.zoom,fps:store.project.fps,textSize:store.settings.textPoints)
        let from=max(0,(visibleRect.minX-header)/store.zoom),to=max(0,(visibleRect.maxX-header)/store.zoom)
        for frame in ticks.ticks(from:from,to:to) {
            let x=header+Double(frame)/Double(store.project.fps)*store.zoom
            let major=frame % ticks.majorFrames == 0
            NSColor.gray.withAlphaComponent(major ? 0.3:0.14).setFill()
            NSRect(x:x,y:major ? ruler-6:ruler-3,width:1,height:major ? bounds.height-ruler+6:3).fill()
            if major {
                text(ticks.label(frame:frame),NSRect(x:x+3,y:3,width:Double(ticks.majorFrames)/Double(store.project.fps)*store.zoom-6,height:ruler-6),size:12)
            }
        }
        if let rhythm=store.project.rhythm,store.project.rhythmEnabled,rhythm.visible {
            var stride=1
            while rhythm.interval*Double(stride)*store.zoom<12 {stride*=2}
            let first=max(0,Int(floor((from-rhythm.offset)/rhythm.interval/Double(stride))))
            let last=max(first,Int(ceil((to-rhythm.offset)/rhythm.interval/Double(stride))))
            for tick in first...min(last,first+512) {
                let n=tick*stride,time=rhythm.offset+Double(n)*rhythm.interval
                let x=header+(time*Double(store.project.fps)).rounded()/Double(store.project.fps)*store.zoom
                NSColor.systemOrange.withAlphaComponent(n % (rhythm.division*4)==0 ? 0.4:0.17).setFill()
                NSRect(x:x,y:ruler-3,width:1,height:bounds.height-ruler+3).fill()
            }
        }
        for stored in store.project.clips {
            let c = previews[stored.id] ?? (preview?.id == stored.id ? preview! : stored)
            let r = rect(c,layout:layout)
            guard r.intersects(visibleRect) else { continue }
            let tint = NSColor(c.kind.tint)
            let clipColor=dark ? tint:(tint.blended(withFraction:0.5,of:.black) ?? tint)
            clipColor.withAlphaComponent(dark ? (selection.contains(c.id) ? 0.75:0.4):(selection.contains(c.id) ? 0.95:0.85)).setFill()
            let path = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4); path.fill()
            (selection.contains(c.id) ? NSColor.white : tint).setStroke(); path.lineWidth = 1; path.stroke()
            if let asset=c.assetID.flatMap({assetsByID[$0]}) {
                let mapping=c.sourceTimeMapping
                NSGraphicsContext.saveGraphicsState();path.addClip()
                if store.settings.thumbnails && [.image,.video].contains(asset.kind) {
                    let interval=[0.5,1.0,2,5,10,30,60,120,300,600].first{$0*store.zoom>=64} ?? 600
                    let cell=asset.kind == .image ? 64:interval*store.zoom
                    var x=r.minX+floor(max(0,visibleRect.minX-r.minX)/cell)*cell
                    while x<min(r.maxX,visibleRect.maxX) {
                        let sample=mapping.sourceTime(at:c.start+max(0,(x-r.minX)/store.zoom))
                        if let image=TimelineMediaCache.shared.thumbnail(asset:asset,directory:store.directory,time:sample,limitMB:store.settings.cacheMB,onReady:{[weak self] in self?.needsDisplay=true}) {
                            image.draw(in:NSRect(x:x,y:r.minY,width:cell,height:r.height),from:.zero,operation:.sourceOver,fraction:0.65,respectFlipped:true,hints:nil)
                        }
                        x+=cell
                    }
                }
                if store.settings.waveforms && [.audio,.speech,.video].contains(c.kind),let values=TimelineMediaCache.shared.envelope(asset:asset,directory:store.directory,onReady:{[weak self] in self?.needsDisplay=true}),!values.isEmpty,asset.duration>0 {
                    let wave=NSBezierPath();NSColor.white.withAlphaComponent(0.65).setStroke();wave.lineWidth=1
                    let peak=max(0.001,values.max() ?? 0.001)
                    var x=max(r.minX,visibleRect.minX)
                    while x<min(r.maxX,visibleRect.maxX) {
                        let sample=mapping.sourceTime(at:c.start+max(0,(x-r.minX)/store.zoom))
                        let index=Int(sample/asset.duration*Double(values.count))
                        if values.indices.contains(index) {let h=max(1,values[index]/peak*max(1,r.height/2-3));wave.move(to:NSPoint(x:x,y:r.midY-h));wave.line(to:NSPoint(x:x,y:r.midY+h))}
                        x+=2
                    }
                    wave.stroke()
                }
                NSColor.black.withAlphaComponent(0.42).setFill();NSRect(x:r.minX,y:r.minY+7*uiScale,width:r.width,height:20*uiScale).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            let showTransitionDetail=c.kind == .transition && r.height>=36*uiScale
            text((c.sceneMembers != nil ? "▣ ":(c.parentID != nil ? "↳ ":"")) + (c.linkID != nil ? "↔ ":"") + (c.speechDirty ? "◌ " : "") + c.timelineTitle, NSRect(x: r.minX + 12, y:showTransitionDetail ? r.minY+2*uiScale:r.midY-9*uiScale,width:max(0,r.width-24),height:20*uiScale), color: .white)
            if showTransitionDetail {
                text(c.sceneTransition?.kind.title ?? "クロスフェード", NSRect(x: r.minX + 12, y:r.minY+19*uiScale,width:max(0,r.width-24),height:18*uiScale), color: .white, size: 8)
            }
            let motionKeys:[Double]=c.animation?.tracks.filter(\.enabled).flatMap{$0.keys.map(\.time)} ?? []
            let effectKeys:[Double]=c.effects?.filter(\.enabled).flatMap{$0.keys.map(\.time)} ?? []
            let selectionKeys:[Double]=c.psd?.selectionKeys?.map(\.time) ?? []
            let keyTimes=Set(motionKeys+effectKeys+selectionKeys)
            NSColor.white.withAlphaComponent(0.85).setFill()
            for key in keyTimes where key >= c.animationTimeOffset && key <= c.animationTimeOffset + c.duration {
                let x = r.minX + (key - c.animationTimeOffset) * store.zoom, y = r.maxY - 5
                let diamond = NSBezierPath(); diamond.move(to: NSPoint(x: x, y: y - 3)); diamond.line(to: NSPoint(x: x + 3, y: y)); diamond.line(to: NSPoint(x: x, y: y + 3)); diamond.line(to: NSPoint(x: x - 3, y: y)); diamond.close(); diamond.fill()
            }
            NSColor.white.withAlphaComponent(store.project.tracks[c.track].locked ? 0.2 : 0.7).setFill()
            let handleHeight=min(17*uiScale,r.height-6)
            for x in r.width>=14 ? [r.minX + 4, r.maxX - 7]:[] { NSBezierPath(roundedRect: NSRect(x: x, y: r.midY-handleHeight/2, width: 3, height: handleHeight), xRadius: 1.5, yRadius: 1.5).fill() }
        }
        if let c = assetPreview {
            accent.withAlphaComponent(0.3).setFill(); let r = rect(c); r.fill()
            accent.setStroke(); NSBezierPath(rect: r).stroke()
            text(c.name, r.insetBy(dx: 10, dy: 10), color: .white)
        }
        if let range=store.project.timelineRange {
            NSColor.systemYellow.withAlphaComponent(0.2).setFill()
            NSRect(x:header+range.start*store.zoom,y:0,width:(range.end-range.start)*store.zoom,height:ruler).fill()
        }
        for (marker,box) in markerRects() where box.intersects(visibleRect) {
            let x=header+marker.time*store.zoom
            NSColor.systemYellow.withAlphaComponent(0.5).setFill();NSRect(x:x,y:ruler,width:1,height:bounds.height-ruler).fill()
            NSColor.systemYellow.withAlphaComponent(store.selectedMarkerID==marker.id ? 0.4:0.16).setFill();NSBezierPath(roundedRect:box,xRadius:3,yRadius:3).fill()
            NSColor.systemYellow.setFill();let flag=NSBezierPath();flag.move(to:NSPoint(x:x-4,y:box.minY+3));flag.line(to:NSPoint(x:x+5,y:box.minY+3));flag.line(to:NSPoint(x:x+5,y:box.maxY-6));flag.line(to:NSPoint(x:x,y:box.maxY-2));flag.line(to:NSPoint(x:x-4,y:box.maxY-6));flag.close();flag.fill()
            if box.width>35 {text(marker.name,NSRect(x:x+9,y:box.minY+1,width:box.width-15,height:box.height-2),color:.systemYellow)}
        }
        accent.setFill(); NSRect(x: header + store.playhead * store.zoom, y:ruler-8,width:1.5,height:bounds.height-ruler+8).fill()
        if let target = layerTarget {
            if let visibleRow=layout.row(forTrack:target) {accent.withAlphaComponent(0.7).setFill(); NSRect(x: 0, y: ruler + CGFloat(visibleRow) * row, width: bounds.width, height: 3).fill()}
        }
    }
    func markerRects()->[(TimelineMarker,NSRect)] {
        guard let store else{return []}
        var markers:[TimelineMarker]=store.project.markers ?? []
        if let preview=markerPreview,let index=markers.firstIndex(where:{$0.id==preview.id}) {markers[index]=preview}
        markers.sort {a,b in if a.time==b.time{return a.id.uuidString<b.id.uuidString};return a.time<b.time}
        return markers.enumerated().map {i,marker in
            let x=header+marker.time*store.zoom,next=i+1<markers.count ? header+markers[i+1].time*store.zoom:x+140*uiScale
            return (marker,NSRect(x:x-5,y:27*uiScale,width:max(10,min(140*uiScale,next-x-2)),height:20*uiScale))
        }
    }
    func marker(at point:NSPoint)->TimelineMarker? {
        let boxes=markerRects().filter{$0.1.contains(point)}
        return boxes.min{abs($0.1.minX+5-point.x)<abs($1.1.minX+5-point.x)}?.0
    }
    func handleMarkerKey(_ event:NSEvent)->Bool {
        guard markerFocused,let store,!store.busy,let id=store.selectedMarkerID,store.project.markers?.contains(where:{$0.id==id}) == true else{return false}
        if event.keyCode==51 || event.keyCode==117 {store.removeMarker(id);markerFocused=false;needsDisplay=true;return true}
        return false
    }
    override func resetCursorRects() {
        guard let store, !store.busy else { return }
        let layout=folderLayout
        for (_,box) in markerRects() where box.intersects(visibleRect) {addCursorRect(box,cursor:.openHand)}
        for c in store.project.clips where !store.project.tracks[c.track].locked {
            let r = rect(c,layout:layout)
            guard r.intersects(visibleRect) else {continue}
            let handle=min(10,r.width/3)
            addCursorRect(NSRect(x:r.minX+handle,y:r.minY,width:r.width-2*handle,height:r.height),cursor:.openHand)
            addCursorRect(NSRect(x:r.minX,y:r.minY,width:handle,height:r.height),cursor:.resizeLeftRight)
            addCursorRect(NSRect(x:r.maxX-handle,y:r.minY,width:handle,height:r.height),cursor:.resizeLeftRight)
        }
        for (rowIndex,entry) in layout.rows.enumerated() {
            guard case .track = entry else{continue}
            let r=NSRect(x:0,y:ruler+CGFloat(rowIndex)*row,width:92*uiScale,height:row)
            if r.intersects(visibleRect){addCursorRect(r,cursor:.openHand)}
        }
    }
    override func mouseDown(with event: NSEvent) {
        guard let store, !store.busy else { return }
        window?.makeFirstResponder(self)
        origin = convert(event.locationInWindow, from: nil); didDrag = false
        original = nil; preview = nil; originals = []; previews = [:]; dragTargets=[]; layerDrag = nil; layerTarget = nil
        markerOriginal=nil;markerPreview=nil;markerFocused=false
        if let marker=marker(at:origin) {
            store.pause();store.selectedMarkerID=marker.id;markerFocused=true;store.seek(marker.time)
            if event.clickCount>=2 {store.markerWindow.show(marker.id)}else{markerOriginal=marker}
            needsDisplay=true;return
        }
        if origin.x>=header,origin.y>=27*uiScale,origin.y<ruler,event.clickCount>=2 {
            let time=max(0,(origin.x-header)/store.zoom);store.addMarker(at:time);needsDisplay=true;return
        }
        if let folder=folder(at:origin) {
            if origin.x<header {store.toggleTrackFolder(folder)}
            else {store.seek(max(0,(origin.x-header)/store.zoom))}
            needsDisplay=true;return
        }
        if origin.x < header {
            if let i = track(at: origin) {
                store.selectedTrack = i
                if origin.x >= 92*uiScale {
                    store.pause(); store.checkpoint()
                    if origin.x < 113*uiScale { store.project.tracks[i].visible.toggle() }
                    else if origin.x < 134*uiScale { store.project.tracks[i].muted.toggle() }
                    else { store.project.tracks[i].locked.toggle() }
                } else { layerDrag = i }
            } else if origin.y < ruler, store.project.tracks.count < 32 {
                store.checkpoint(); store.project.tracks.append(Track(name: "レイヤー \(store.project.tracks.count + 1)"))
            }
        } else if let c = clip(at: origin) {
            if event.clickCount>=2,c.precompositionID != nil,!store.project.tracks[c.track].locked {store.selectedID=c.id;store.precompositionWindows.show(c.id);return}
            if store.tool == .blade {store.selectedID=c.id;store.selectedIDs=[];store.seek((origin.x-header)/store.zoom);store.splitSelected();needsDisplay=true;return}
            let extending=event.modifierFlags.contains(.command) || event.modifierFlags.contains(.shift)
            if extending {var ids=store.selection;if ids.contains(c.id){ids.remove(c.id)}else{ids.insert(c.id)};store.selectedIDs=ids;store.selectedID=ids.contains(c.id) ? c.id:ids.first;needsDisplay=true;return}
            if !store.selection.contains(c.id){store.selectedIDs=[]}
            store.selectedID = c.id; store.selectedTrack = c.track
            guard !store.project.tracks[c.track].locked else { return }
            original = c; let r = rect(c)
            let handle=min(10,r.width/3)
            edge = origin.x < r.minX + handle ? -1 : (origin.x > r.maxX - handle ? 1 : 0)
            let linkedSelection=LinkedMedia.expanded(store.selection,in:store.project)
            originals=store.project.clips.filter{linkedSelection.contains($0.id)}
            let affected=LinkedMedia.expandedHierarchy(store.selection,in:store.project)
            let layout=folderLayout
            if store.project.clips.contains(where:{affected.contains($0.id) && layout.row(forTrack:$0.track)==nil}) {
                original=nil;originals=[];store.error=L("連動するアイテムが折りたたまれたフォルダにあります。フォルダを開いてください。");needsDisplay=true;return
            }
            store.pause()
        } else {
            if let i = track(at: origin) { store.selectedTrack = i; store.selectedID = nil;store.selectedIDs=[] }
            store.seek((origin.x - header) / store.zoom)
            if store.tool == .text {store.add(.text)} else if store.tool == .shape {store.add(.shape)}
        }
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let store, !store.busy else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard didDrag || hypot(p.x - origin.x, p.y - origin.y) >= 3 else { return }
        didDrag = true
        autoscroll(with: event)
        if let marker=markerOriginal {
            var changed=marker;changed.time=(max(0,min(86400,marker.time+(p.x-origin.x)/store.zoom))*Double(store.project.fps)).rounded()/Double(store.project.fps);markerPreview=changed;NSCursor.closedHand.set()
        } else if layerDrag != nil {
            layerTarget = dragTrack(at:p)
        } else if let original {
            guard let target=edge == 0 ? dragTrack(at:p):original.track else {preview=nil;previews=[:];dragTargets=[];needsDisplay=true;return}
            preview = store.timelineChange(original, delta: (p.x - origin.x) / store.zoom, track: target, edge: edge)
            if edge == 0 && originals.count>1 {
                let layout=folderLayout
                let hasHierarchy=store.project.clips.contains{$0.parentID != nil || !($0.sceneMembers ?? []).isEmpty}
                let descendants=hasHierarchy ? originals.map{($0.id,LinkedMedia.expanded(store.project.descendants(of:$0.id),in:store.project))}:[]
                let roots=hasHierarchy ? originals.filter{child in !descendants.contains(where:{$0.0 != child.id && $0.1.contains(child.id)})}:originals
                let minimumStart=roots.map(\.start).min() ?? 0
                let delta=max((p.x-origin.x)/store.zoom,-minimumStart)
                let shift=target-original.track
                if roots.allSatisfy({store.project.tracks.indices.contains($0.track+shift) && layout.row(forTrack:$0.track+shift) != nil && !store.project.tracks[$0.track].locked && !store.project.tracks[$0.track+shift].locked}) {
                    let anchor=store.timelineChange(original,delta:delta,track:target,edge:0)
                    let common=max(anchor.start-original.start,-minimumStart)
                    previews=Dictionary(uniqueKeysWithValues:roots.map{c in var changed=c;changed.start=c.start+common;changed.track=c.track+shift;return (changed.id,changed)})
                    dragTargets=Set(roots.map(\.id))
                    if hasHierarchy {
                        let rootsByID=Dictionary(uniqueKeysWithValues:roots.map{($0.id,$0)})
                        for changed in Array(previews.values) {
                            if let old=rootsByID[changed.id] {
                                let descendants=store.project.descendants(of:changed.id)
                                for var child in store.project.clips where descendants.contains(child.id) {child.start=max(0,child.start+changed.start-old.start);previews[child.id]=child}
                            }
                        }
                    }
                    preview=nil
                } else {previews=[:];dragTargets=[];preview=nil}
            }
            (edge == 0 ? NSCursor.closedHand : NSCursor.resizeLeftRight).set()
        } else if origin.x >= header { store.seek((p.x - header) / store.zoom) }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        if let store, !store.busy, didDrag {
            if let marker=markerPreview {store.reportEditing{try store.updateMarker(marker.id,time:marker.time,name:marker.name)}}
            if let from = layerDrag, let to = layerTarget { store.moveTrack(from: from, to: to) }
            if !previews.isEmpty {
                store.pause();store.checkpoint()
                var applied:Set<UUID>=[]
                for c in previews.values where dragTargets.contains(c.id) {
                    if !applied.contains(c.id) {store.edit(c.id,record:false){$0.start=c.start};applied.formUnion(LinkedMedia.expandedHierarchy([c.id],in:store.project))}
                }
                for c in previews.values where dragTargets.contains(c.id) {store.edit(c.id,record:false){$0.track=c.track}}
            }
            if let changed = preview, changed != original {
                // Preserve settings changed by automatic synthesis during the gesture.
                store.edit(changed.id) { $0.start = changed.start; $0.duration = changed.duration; $0.sourceOffset = changed.sourceOffset; $0.track = changed.track; $0.animationOffset = changed.animationOffset; $0.animation = changed.animation }
                store.selectedTrack = changed.track
            }
        }
        markerOriginal=nil;markerPreview=nil
        original = nil; preview = nil; originals = []; previews = [:]; dragTargets=[]; layerDrag = nil; layerTarget = nil; didDrag = false
        needsDisplay = true; window?.invalidateCursorRects(for: self)
    }
    override func keyDown(with event: NSEvent) {
        if handleMarkerKey(event){return}
        if event.keyCode == 53 { markerOriginal=nil;markerPreview=nil;original = nil; preview = nil; originals = []; previews = [:]; dragTargets=[]; layerDrag = nil; layerTarget = nil; needsDisplay = true }
        else { super.keyDown(with: event) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let store, !store.busy else { return nil }
        let p = convert(event.locationInWindow, from: nil), menu = NSMenu()
        menuActions = []
        func item(_ title: String, enabled: Bool = true, action: @escaping () -> Void) {
            let item = NSMenuItem(title:L(title), action: #selector(runMenu(_:)), keyEquivalent: "")
            item.target = self; item.tag = menuActions.count; item.isEnabled = enabled; menuActions.append(action); menu.addItem(item)
        }
        menu.autoenablesItems = false
        if let marker=marker(at:p) {
            store.selectedMarkerID=marker.id;markerFocused=true
            item("マーカーを編集"){store.markerWindow.show(marker.id)}
            item("再生位置へマーカーを移動"){store.reportEditing{try store.updateMarker(marker.id,time:store.playhead,name:marker.name)}}
            item("削除"){store.removeMarker(marker.id)}
            return menu
        }
        if let id=folder(at:p),let folder=store.project.trackFolders.first(where:{$0.id==id}) {
            item(store.collapsedTrackFolders.contains(id) ? "フォルダを開く":"フォルダを折りたたむ"){store.toggleTrackFolder(id)}
            item("フォルダ名を変更") {
                let alert=NSAlert();alert.messageText=L("フォルダ名")
                let field=NSTextField(string:folder.name);field.frame=NSRect(x:0,y:0,width:240,height:24);alert.accessoryView=field
                alert.addButton(withTitle:L("変更"));alert.addButton(withTitle:L("キャンセル"))
                if alert.runModal() == .alertFirstButtonReturn {store.reportEditing{try store.renameTrackFolder(id,name:field.stringValue)}}
            }
            item("フォルダを解除") {store.reportEditing{try store.deleteTrackFolder(id)}}
            return menu
        }
        if p.x>=header {item("マーカー一覧"){store.markerWindow.show()}}
        if p.x >= header, let c = clip(at: p) {
            if !store.selection.contains(c.id){store.selectedIDs=[]};store.selectedID = c.id; store.selectedTrack = c.track
            let unlocked = !store.project.tracks[c.track].locked
            if c.sceneMembers != nil {item("シーン制御を解除",enabled:unlocked){store.reportEditing{try store.dissolveScene(c.id)}}}
            item("コピー"){store.reportEditing{try store.copyClips()}}
            item("ペースト",enabled:unlocked){store.reportEditing{try store.pasteClips()}}
            item("リップル削除",enabled:unlocked){store.reportEditing{try store.rippleDelete()}}
            if [.audio,.video].contains(c.kind) {item("無音カット",enabled:unlocked && c.assetID != nil){store.silenceCutWindow.show(c.id)}}
            if c.kind == .video {item("映像と音声を分離",enabled:unlocked && c.audioDisabled != true){Task{do{try await store.separateAudio(c.id)}catch{store.error=error.localizedDescription}}}}
            item("映像・音声をリンク",enabled:unlocked && store.selection.count>1){store.reportEditing{try store.linkSelection()}}
            item("リンクを解除",enabled:unlocked && c.linkID != nil){store.reportEditing{try store.unlinkSelection()}}
            item("選択した2音声をクロスフェード",enabled:unlocked && store.selection.count==2){store.reportEditing{try store.crossfadeSelection()}}
            item("プリコンポジションにまとめる…",enabled:unlocked){store.promptPrecomposition()}
            if c.precompositionID != nil {item("プリコンポジションを編集…",enabled:unlocked){store.precompositionWindows.show(c.id)};item("独立したコピーにする",enabled:unlocked){store.reportEditing{try store.makePrecompositionUnique(c.id)}}}
            item("複製", enabled: unlocked) { store.duplicateSelected() }
            item("再生位置で分割", enabled: unlocked && store.playhead > c.start && store.playhead < c.end) { store.splitSelected() }
            if [.video,.audio,.speech].contains(c.kind) {
                item("素材をスリップ編集…",enabled:unlocked){store.promptSourceEdit(c.id,roll:false)}
                item("右隣との境界をロール編集…",enabled:unlocked){store.promptSourceEdit(c.id,roll:true)}
            }
            item("クリップの先頭へ") { store.seek(c.start) }
            item("1つ上のレイヤーへ", enabled: unlocked && c.track > 0 && !store.project.tracks[max(0, c.track - 1)].locked) { store.edit(c.id) { $0.track -= 1 } }
            item("1つ下のレイヤーへ", enabled: unlocked && c.track + 1 < store.project.tracks.count && !store.project.tracks[min(store.project.tracks.count - 1, c.track + 1)].locked) { store.edit(c.id) { $0.track += 1 } }
            item("選択したアイテムを削除", enabled: unlocked) { store.deleteSelection() }
            item("選択した字幕にスタイルを適用",enabled:unlocked){store.bulkStyle()}
            item("選択したアイテムを順番に配置",enabled:unlocked){store.arrange("順番") }
        } else if let i = track(at: p) {
            store.selectedTrack = i
            if p.x >= header {
                let time = max(0, (p.x - header) / store.zoom)
                item("ここに貼り付け",enabled:!store.project.tracks[i].locked){store.seek(time);store.reportEditing{try store.pasteClips()}}
                item("ここにセリフを追加", enabled: !store.project.tracks[i].locked) { store.seek(time); store.add(.speech) }
                item("ここにテキストを追加", enabled: !store.project.tracks[i].locked) { store.seek(time); store.add(.text) }
                item("ここにグループ制御を追加", enabled: !store.project.tracks[i].locked) {store.seek(time);store.add(.group)}
                item("ここにパーティクルを追加", enabled: !store.project.tracks[i].locked) {store.seek(time);store.add(.particles)}
                item("ここに調整エフェクトを追加", enabled: !store.project.tracks[i].locked) {store.seek(time);store.add(.adjustment)}
                item("このレイヤーをグループ化", enabled: !store.project.tracks[i].locked) {store.groupSelectedLayer()}
                item("ここに場面切り替えを追加", enabled: !store.project.tracks[i].locked) { store.seek(time); store.add(.transition) }
                item("ここに図形を追加", enabled: !store.project.tracks[i].locked) { store.seek(time); store.add(.shape) }
                menu.addItem(.separator())
            }
            let trackID=store.project.tracks[i].id
            item("新しいフォルダに入れる") {
                let alert=NSAlert();alert.messageText=L("新しいフォルダ名")
                let field=NSTextField(string:L("フォルダ"));field.frame=NSRect(x:0,y:0,width:240,height:24);alert.accessoryView=field
                alert.addButton(withTitle:L("作成"));alert.addButton(withTitle:L("キャンセル"))
                if alert.runModal() == .alertFirstButtonReturn {store.reportEditing{try store.createTrackFolder(name:field.stringValue,trackID:trackID)}}
            }
            let otherFolders=store.project.trackFolders.filter{$0.id != store.project.tracks[i].folderID}
            if !otherFolders.isEmpty {
                let submenu=NSMenu(title:L("フォルダに入れる")),parent=NSMenuItem(title:L("フォルダに入れる"),action:nil,keyEquivalent:"")
                for folder in otherFolders {
                    let entry=NSMenuItem(title:folder.name,action:#selector(runMenu(_:)),keyEquivalent:"");entry.target=self;entry.tag=menuActions.count
                    menuActions.append{store.reportEditing{try store.assignTrackFolder(trackID,folderID:folder.id)}};submenu.addItem(entry)
                }
                parent.submenu=submenu;menu.addItem(parent)
            }
            if store.project.tracks[i].folderID != nil {item("フォルダから外す"){store.reportEditing{try store.assignTrackFolder(trackID,folderID:nil)}}}
            menu.addItem(.separator())
            item("レイヤーを上へ", enabled: i > 0) { store.moveTrack(from: i, to: i - 1) }
            item("レイヤーを下へ", enabled: i + 1 < store.project.tracks.count) { store.moveTrack(from: i, to: i + 1) }
            item("レイヤー名を変更") {
                let alert = NSAlert(); alert.messageText = "レイヤー名"
                let field = NSTextField(string: store.project.tracks[i].name); field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
                alert.accessoryView = field; alert.addButton(withTitle: "変更"); alert.addButton(withTitle: "キャンセル")
                if alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty { store.checkpoint(); store.project.tracks[i].name = field.stringValue }
            }
            item("レイヤーを削除",enabled:store.project.tracks.count>1 && !store.project.tracks[i].locked){store.confirmDeleteTrack(i)}
            item(store.project.tracks[i].locked ? "ロック解除" : "レイヤーをロック") { store.checkpoint(); store.project.tracks[i].locked.toggle() }
            item(store.project.tracks[i].muted ? "ミュート解除" : "ミュート") { store.pause(); store.checkpoint(); store.project.tracks[i].muted.toggle() }
            item(store.project.tracks[i].visible ? "レイヤーを非表示" : "レイヤーを表示") { store.pause(); store.checkpoint(); store.project.tracks[i].visible.toggle() }
        }
        if p.x>=header {
            menu.addItem(.separator())
            let time=max(0,(p.x-header)/store.zoom)
            item("マーカーを追加"){store.addMarker(at:time)}
            item("インを設定"){store.setRange(inPoint:true,at:time)}
            item("アウトを設定"){store.setRange(inPoint:false,at:time)}
        }
        menu.addItem(.separator())
        item("元に戻す", enabled: store.canUndo) { store.undo() }
        item("やり直す", enabled: store.canRedo) { store.redo() }
        return menu
    }
    @objc private func runMenu(_ sender: NSMenuItem) { if menuActions.indices.contains(sender.tag) { menuActions[sender.tag]() } }
    private func assetPosition(_ windowPoint: NSPoint) -> (Int, Double)? {
        guard let store, !store.busy else { return nil }
        let p = convert(windowPoint, from: nil)
        guard visibleRect.contains(p), p.x >= header, let i = track(at: p), !store.project.tracks[i].locked else { return nil }
        return (i, max(0, (p.x - header) / store.zoom))
    }
    func previewAsset(_ asset: MediaAsset, windowPoint: NSPoint) {
        assetPreview = nil
        if let (track, time) = assetPosition(windowPoint), let store {
            assetPreview = Clip(kind: asset.kind, name: asset.name, track: track, start: store.snapped(time), duration: asset.kind == .image ? 5 : max(0.1, asset.duration))
        }
        needsDisplay = true
    }
    func clearAssetPreview() { assetPreview = nil; needsDisplay = true }
    func dropAsset(_ asset: MediaAsset, windowPoint: NSPoint) {
        defer { clearAssetPreview() }
        guard let (track, time) = assetPosition(windowPoint), let store else { return }
        store.selectedTrack = track; store.seek(time); store.add(asset.kind, asset: asset)
    }
    private func droppedAsset(_ sender: NSDraggingInfo) -> MediaAsset? {
        guard let value = sender.draggingPasteboard.string(forType: .string), value.hasPrefix("vmm-asset:"), let id = UUID(uuidString: String(value.dropFirst(10))) else { return nil }
        return store?.libraryAssets.first { $0.id == id }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let store,let (track,time)=assetPosition(sender.draggingLocation) else {clearAssetPreview();return []}
        if let asset=droppedAsset(sender){previewAsset(asset,windowPoint:sender.draggingLocation);return .copy}
        let urls=FinderFiles.urls(sender.draggingPasteboard)
        guard FinderFiles.valid(urls) else{clearAssetPreview();return []}
        assetPreview=Clip(kind:.image,name:urls.count==1 ? urls[0].lastPathComponent:"\(urls.count)個のファイル",track:track,start:store.snapped(time),duration:5)
        needsDisplay=true;return .copy
    }
    override func draggingExited(_ sender:NSDraggingInfo?) {clearAssetPreview()}
    override func concludeDragOperation(_ sender:NSDraggingInfo?) {clearAssetPreview()}
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer{clearAssetPreview()}
        guard let store,let (track,time)=assetPosition(sender.draggingLocation) else {return false}
        if let asset=droppedAsset(sender) {store.selectedTrack=track;store.seek(time);store.add(asset.kind,asset:asset);return true}
        return store.acceptFinderDrop(FinderFiles.urls(sender.draggingPasteboard),at:MediaDropPosition(track:track,time:time))
    }
}
