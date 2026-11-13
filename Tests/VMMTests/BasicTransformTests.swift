import XCTest
import SwiftUI
import AppKit
@testable import VMM

final class BasicTransformTests:XCTestCase {
    func testAnimationCategoriesContainEverySectionOnce() {
        let items=MotionCategory.allCases.flatMap(\.tabs)
        XCTAssertEqual(Set(items),Set(MotionTab.allCases))
        XCTAssertEqual(items.count,Set(items).count)
    }
    @MainActor func testStaticAnimatedDisabledAndSelectedKeyEditing()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),s=EditorStore(preferencesDirectory:root);defer{try? FileManager.default.removeItem(at:root)};s.autoSpeech=false;s.settings.autosaveSeconds=0
        var c=Clip(kind:.shape,name:"basic",track:0,start:0,duration:2);s.project.clips=[c]
        try s.setBasicTransformValue(c.id,property:.scale,time:1,value:1.25);XCTAssertEqual(s.project.clips[0].scale,1.25);XCTAssertNil(s.project.clips[0].animation);s.undo();XCTAssertEqual(s.project.clips[0],c)
        c.putMotionKey(.x,time:0,value:0.2,easing:.linear);c.putMotionKey(.x,time:2,value:0.8);s.project.clips=[c]
        try s.setBasicTransformValue(c.id,property:.x,time:1,value:0.6);let keys=s.project.clips[0].animation!.tracks[0].keys;XCTAssertEqual(keys.count,3);XCTAssertEqual(keys[1].time,1);XCTAssertEqual(keys[1].value,0.6);s.undo();XCTAssertEqual(s.project.clips[0],c)
        let key=c.animation!.tracks[0].keys[0];try s.setBasicTransformValue(c.id,property:.x,time:1,value:0.3,keyID:key.id);XCTAssertEqual(s.project.clips[0].animation!.tracks[0].keys[0].id,key.id);XCTAssertEqual(s.project.clips[0].animation!.tracks[0].keys[0].time,0);XCTAssertEqual(s.project.clips[0].animation!.tracks[0].keys[0].easing,.linear);XCTAssertEqual(s.project.clips[0].animation!.tracks[0].keys.count,2);s.undo()
        c.animation!.tracks[0].enabled=false;s.project.clips=[c];try s.setBasicTransformValue(c.id,property:.x,time:1,value:0.4);XCTAssertEqual(s.project.clips[0].x,0.4);XCTAssertEqual(s.project.clips[0].animation,c.animation)
        let saved=try s.project.validated();XCTAssertEqual(try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(saved)),saved)
        s.project.tracks[0].locked=true;let before=s.project;XCTAssertThrowsError(try s.setBasicTransformValue(c.id,property:.scale,time:1,value:2));XCTAssertEqual(s.project,before)
    }
    @MainActor func testCompactWorkspaceNativeFieldsAndPersistentKeys()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),s=EditorStore(preferencesDirectory:root);defer{try? FileManager.default.removeItem(at:root)};s.autoSpeech=false;s.settings.autosaveSeconds=0
        var c=Clip(kind:.shape,name:"基本変形をまとめて編集",track:0,start:0,duration:2);c.putMotionKey(.x,time:0,value:0.2);c.putMotionKey(.x,time:2,value:0.8);c.putMotionKey(.rotation,time:0,value:0);c.putMotionKey(.rotation,time:2,value:180);s.project.clips=[c];s.selectedID=c.id
        let before=s.project,output=ProcessInfo.processInfo.environment["VMM_BASIC_LAYOUT_ROOT"].map{URL(fileURLWithPath:$0)}
        for (name,size,graph) in [("basic-small",CGSize(width:840,height:620),false),("basic-large",CGSize(width:1320,height:880),false),("graph-small",CGSize(width:840,height:620),true),("graph-large",CGSize(width:1320,height:880),true)] {
            let host=NSHostingView(rootView:AnimationWorkspace(store:s,onClose:{},initialGraph:graph));host.frame=CGRect(origin:.zero,size:size)
            let window=NSWindow(contentRect:host.frame,styleMask:[.titled,.resizable],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.appearance=NSAppearance(named:.darkAqua);window.contentView=host;window.makeKeyAndOrderFront(nil);defer{window.close()};host.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:200_000_000);host.layoutSubtreeIfNeeded()
            XCTAssertEqual(descendants(host).filter{$0 is UnifiedAnimationTimelineView}.count,2);XCTAssertEqual(s.project,before)
            if !graph{let fields=descendants(host).compactMap{$0 as? NSTextField}.filter{$0.isEditable};XCTAssertEqual(fields.count,5);XCTAssertFalse(fields.contains{$0.accessibilityLabel()==L("横の拡大率")});XCTAssertTrue(fields.contains{$0.accessibilityLabel()==L("回転")});for field in fields{XCTAssertGreaterThan(field.bounds.width,65);XCTAssertGreaterThan(field.bounds.height,10)}}
            if name=="basic-small"{let field=try XCTUnwrap(descendants(host).compactMap{$0 as? NSTextField}.first{$0.isEditable && $0.accessibilityLabel()==L("拡大率")});field.stringValue="125";field.delegate?.controlTextDidEndEditing?(Notification(name:NSControl.textDidEndEditingNotification,object:field));XCTAssertEqual(s.project.clips[0].scale,1.25);XCTAssertFalse(s.project.clips[0].animation!.tracks.contains{$0.property == .scale});s.undo();XCTAssertEqual(s.project,before);try await Task.sleep(nanoseconds:100_000_000)}
            if let output{try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true);let bitmap=try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds));host.cacheDisplay(in:host.bounds,to:bitmap);try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:output.appendingPathComponent(name+".png"))}
        }
    }
    @MainActor func testEmbeddedWorkspaceTracksSelection()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-embedded-ui-\(UUID())"),s=EditorStore(preferencesDirectory:root)
        defer{try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:s.directory)}
        s.autoSpeech=false;s.settings.autosaveSeconds=0
        var first=Clip(kind:.shape,name:"First",track:0,start:0,duration:2)
        first.putMotionKey(.x,time:0,value:0.2);first.putMotionKey(.x,time:2,value:0.8)
        let second=Clip(kind:.text,name:"Second",track:0,start:3,duration:2)
        s.project.clips=[first,second];s.selectedID=first.id
        let host=NSHostingView(rootView:AnimationWorkspace(store:s,onClose:{}))
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1100,height:330),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.appearance=NSAppearance(named:.darkAqua);window.contentView=host;window.makeKeyAndOrderFront(nil);defer{window.close()}
        host.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:300_000_000)
        var timelines=descendants(host).compactMap{$0 as? UnifiedAnimationTimelineView}
        XCTAssertEqual(timelines.count,2);XCTAssertTrue(timelines.allSatisfy{$0.clipID==first.id})
        if let output=testArtifactDirectory(){try FileManager.default.createDirectory(atPath:output,withIntermediateDirectories:true);let bitmap=try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds));host.cacheDisplay(in:host.bounds,to:bitmap);try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:URL(fileURLWithPath:output).appendingPathComponent("embedded-animation.png"))}
        s.selectedID=second.id;try await Task.sleep(nanoseconds:300_000_000);host.layoutSubtreeIfNeeded()
        timelines=descendants(host).compactMap{$0 as? UnifiedAnimationTimelineView}
        XCTAssertEqual(timelines.count,2);XCTAssertTrue(timelines.allSatisfy{$0.clipID==second.id})
    }
    @MainActor private func descendants(_ view:NSView)->[NSView]{[view]+view.subviews.flatMap{descendants($0)}}
}
