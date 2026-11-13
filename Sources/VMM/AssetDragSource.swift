import SwiftUI
import AppKit

struct AssetDragSource: NSViewRepresentable {
    let asset: MediaAsset
    let store:EditorStore
    var preview:()->Void
    var hover:((Bool)->Void)?=nil
    func makeNSView(context: Context) -> AssetDragNSView { AssetDragNSView() }
    func updateNSView(_ view: AssetDragNSView, context: Context) { view.asset = asset;view.store=store;view.preview=preview;view.hover=hover }
}
/// An internal drag shares window coordinates with the timeline, avoiding the
/// competing SwiftUI/AppKit drag destinations around the split views.
final class AssetDragNSView: NSView {
    var asset: MediaAsset?
    weak var store:EditorStore?
    var preview:(()->Void)?
    var hover:((Bool)->Void)?
    private var hoverTracking:NSTrackingArea?
    override func updateTrackingAreas(){
        super.updateTrackingAreas();if let hoverTracking{removeTrackingArea(hoverTracking)}
        let area=NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.activeInActiveApp,.inVisibleRect],owner:self,userInfo:nil)
        addTrackingArea(area);hoverTracking=area
    }
    override func mouseEntered(with event:NSEvent){hover?(true)}
    override func mouseExited(with event:NSEvent){hover?(false)}
    override func viewDidMoveToWindow(){super.viewDidMoveToWindow();if window==nil{hover?(false)}}
    private var menuActions:[()->Void]=[]
    override func menu(for event:NSEvent)->NSMenu? {
        guard let store,let asset else{return nil}
        let menu=NSMenu();menu.autoenablesItems=false;menuActions=[]
        func item(_ title:String,enabled:Bool=true,_ action:@escaping ()->Void){let item=NSMenuItem(title:L(title),action:#selector(runMenu(_:)),keyEquivalent:"");item.target=self;item.tag=menuActions.count;item.isEnabled=enabled;menuActions.append(action);menu.addItem(item)}
        item("タイムラインに追加",enabled:!store.busy){store.add(asset.kind,asset:asset)}
        if [.audio,.video].contains(asset.kind){item("素材を再生",enabled:!store.busy){[weak self] in self?.preview?()}}
        item("Finderで素材を表示"){store.revealMedia(asset)}
        menu.addItem(.separator())
        item("素材タグ",enabled:!store.busy){store.editMediaTags(asset)}
        item("素材を削除",enabled:!store.busy){store.confirmDeleteMedia(asset)}
        return menu
    }
    @objc private func runMenu(_ sender:NSMenuItem){if menuActions.indices.contains(sender.tag){menuActions[sender.tag]()}}
    private var dragging = false
    private var cancelled = false
    private var origin = NSPoint.zero
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private func canvas(in view: NSView?) -> TimelineNSView? {
        guard let view else { return nil }
        if let timeline = view as? TimelineNSView { return timeline }
        for child in view.subviews { if let result = canvas(in: child) { return result } }
        return nil
    }
    override func mouseDown(with event: NSEvent) {
        hover?(false)
        origin = event.locationInWindow; dragging = false; cancelled = false
        window?.makeFirstResponder(self)
    }
    override func mouseDragged(with event: NSEvent) {
        guard !cancelled, let asset, hypot(event.locationInWindow.x - origin.x, event.locationInWindow.y - origin.y) > 3 else { return }
        dragging = true; NSCursor.closedHand.set()
        canvas(in: window?.contentView)?.previewAsset(asset, windowPoint: event.locationInWindow)
    }
    override func mouseUp(with event: NSEvent) {
        if dragging, !cancelled, let asset { canvas(in: window?.contentView)?.dropAsset(asset, windowPoint: event.locationInWindow) }
        canvas(in: window?.contentView)?.clearAssetPreview()
        dragging = false; NSCursor.openHand.set()
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelled = true; canvas(in: window?.contentView)?.clearAssetPreview() }
        else { super.keyDown(with: event) }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}
