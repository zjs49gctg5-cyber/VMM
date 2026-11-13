import XCTest
import SwiftUI
import AppKit
@testable import VMM
final class AdvancedMotionLayoutTests:XCTestCase {
    @MainActor func testAnimationViewsAtTwoSizes()async throws {
        guard let output=ProcessInfo.processInfo.environment["VMM_MOTION_LAYOUT_ROOT"] else{throw XCTSkip("Opt-in animation UI snapshots")}
        let root=URL(fileURLWithPath:output);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let prefs=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),s=EditorStore(preferencesDirectory:prefs);defer{try? FileManager.default.removeItem(at:prefs);try? FileManager.default.removeItem(at:s.directory)};s.autoSpeech=false;s.settings.autosaveSeconds=0
        var c=Clip(kind:.text,name:"文字",track:0,start:0,duration:2);c.text="VMM アニメーション";c.textAnimation=CharacterAnimation();c.spatialAnimation=SpatialAnimation(keys:[SpatialKey(time:0,point:NormalizedPoint(x:0.2,y:0.5)),SpatialKey(time:2,point:NormalizedPoint(x:0.8,y:0.5))]);c.putMotionKey(.x,time:0,value:0.2);c.putMotionKey(.x,time:2,value:0.8);c.putMotionKey(.rotation,time:0,value:0);c.putMotionKey(.rotation,time:2,value:180);s.project.clips=[c];s.selectedID=c.id
        NSApplication.shared.setActivationPolicy(.regular)
        for (name,view,size) in [("workspace",AnyView(AnimationWorkspace(store:s,onClose:{})),CGSize(width:1320,height:880)),("keyframes-large",AnyView(AnimationWorkspace(store:s,onClose:{},initialTab:"キーフレーム")),CGSize(width:1320,height:880)),("keyframes-small",AnyView(AnimationWorkspace(store:s,onClose:{},initialTab:"キーフレーム")),CGSize(width:900,height:750)),("path-workspace",AnyView(AnimationWorkspace(store:s,onClose:{},initialTab:"移動パス・支点")),CGSize(width:1320,height:880)),("text-workspace",AnyView(AnimationWorkspace(store:s,onClose:{},initialTab:"文字")),CGSize(width:1100,height:800)),("workspace-small",AnyView(AnimationWorkspace(store:s,onClose:{})),CGSize(width:900,height:650)),("graph",AnyView(MotionGraphEditor(store:s,clip:c)),CGSize(width:1100,height:350)),("path",AnyView(ScrollView{SpatialAnimationControls(store:s,clip:c).padding()}),CGSize(width:620,height:600)),("text",AnyView(CharacterAnimationControls(store:s,clip:c).padding()),CGSize(width:620,height:600))] {
            let host=NSHostingView(rootView:view.frame(width:size.width,height:size.height).background(Color(nsColor:.windowBackgroundColor)).preferredColorScheme(.dark).vmmAppearance(s.settings));let window=NSWindow(contentRect:CGRect(origin:.zero,size:size),styleMask:[.titled,.resizable],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.appearance=NSAppearance(named:.darkAqua);window.contentView=host;window.makeKeyAndOrderFront(nil);defer{window.close()};host.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:300_000_000)
            let bitmap=try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds));host.cacheDisplay(in:host.bounds,to:bitmap);try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:root.appendingPathComponent(name+".png"))
        }
    }
}
