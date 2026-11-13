import XCTest
import AppKit
import SwiftUI
@testable import VMM

final class TimelineNavigationTests:XCTestCase {
    @MainActor func testMarkersRangeLoopAndUndo()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-navigation-\(UUID())"),s=EditorStore(preferencesDirectory:root)
        defer{s.pause();try? FileManager.default.removeItem(at:s.directory)}
        s.project=Project();s.project.clips=[Clip(kind:.shape,name:"base",track:0,start:0,duration:10)]
        s.addMarker(at:1.012,name:"beat");XCTAssertEqual(s.project.markers?.first?.time,1)
        s.playhead=2;s.setRange(inPoint:true);s.playhead=4;s.setRange(inPoint:false);s.project.timelineRange?.loop=true
        XCTAssertEqual(s.project.timelineRange,TimelineRange(start:2,end:4,loop:true))
        s.advancePlayback(to:4.1,clockTime:99);XCTAssertEqual(s.playhead,2.1,accuracy:0.001);XCTAssertEqual(s.playbackOffset,2.1,accuracy:0.001);XCTAssertEqual(s.playbackStart,99)
        s.advancePlayback(to:8.25,clockTime:100);XCTAssertEqual(s.playhead,2.25,accuracy:0.001)
        s.removeMarker(try XCTUnwrap(s.project.markers?.first?.id));XCTAssertTrue(s.project.markers?.isEmpty==true);s.undo();XCTAssertEqual(s.project.markers?.count,1)
        s.project.timelineRange?.loop=false;s.advancePlayback(to:11);XCTAssertEqual(s.playhead,10);XCTAssertFalse(s.playing)
        _=try s.project.validated();s.project.timelineRange?.end=1;XCTAssertThrowsError(try s.project.validated())
    }
    func testLegacyCompatibilityAndShortcuts()throws {
        let legacy=try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(Project()))
        XCTAssertNil(legacy.markers);XCTAssertNil(legacy.timelineRange)
        for preset in ["VMM標準","Premiere風","Final Cut風"] {
            var settings=UserSettings();settings.shortcuts=preset
            XCTAssertEqual(ShortcutMap.key(.marker,settings:settings),"m");XCTAssertEqual(ShortcutMap.key(.setIn,settings:settings),"i");XCTAssertEqual(ShortcutMap.key(.setOut,settings:settings),"o")
        }
    }
    @MainActor func testMarkerEditingValidationNavigationAndDuplicates()throws {
        let s=EditorStore(preferencesDirectory:FileManager.default.temporaryDirectory.appendingPathComponent("vmm-marker-model-\(UUID())"))
        defer{try? FileManager.default.removeItem(at:s.directory)}
        s.project=Project();s.addMarker(at:2,name:"First");let id=try XCTUnwrap(s.selectedMarkerID)
        s.addMarker(at:2,name:"Duplicate");XCTAssertNotEqual(s.selectedMarkerID,id)
        let before=s.project
        XCTAssertThrowsError(try s.updateMarker(id,time:.nan,name:"Bad"));XCTAssertThrowsError(try s.updateMarker(id,time:4,name:" "));XCTAssertEqual(s.project,before)
        try s.updateMarker(id,time:5.012,name:" Renamed ");XCTAssertEqual(s.project.markers?.last?.time,5);XCTAssertEqual(s.project.markers?.last?.name,"Renamed")
        s.undo();XCTAssertEqual(s.project,before);s.redo()
        s.playhead=2;s.seekMarker(forward:true);XCTAssertEqual(s.playhead,5);s.seekMarker(forward:false);XCTAssertEqual(s.playhead,2)
        try s.updateMarker(id,time:100,name:"Future");s.seekMarker(forward:true);XCTAssertEqual(s.playhead,100)
        _=try s.project.validated()
    }
    @MainActor func testNativeMarkerDragCancelContextAndDeleteProtectClips()throws {
        let s=EditorStore(preferencesDirectory:FileManager.default.temporaryDirectory.appendingPathComponent("vmm-marker-drag-\(UUID())"))
        defer{try? FileManager.default.removeItem(at:s.directory)}
        s.project=Project();let marker=TimelineMarker(time:2,name:"Drag");s.project.markers=[marker];s.project.clips=[Clip(kind:.shape,name:"Keep",track:0,start:0,duration:10)]
        s.selectedID=s.project.clips[0].id;s.zoom=72
        let canvas=TimelineNSView(frame:NSRect(x:0,y:0,width:1000,height:400));canvas.store=s
        let window=NSWindow(contentRect:canvas.frame,styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.contentView=canvas;defer{window.close()}
        let point=NSPoint(x:canvas.header+144,y:35)
        func mouse(_ type:NSEvent.EventType,_ p:NSPoint)throws->NSEvent {try XCTUnwrap(NSEvent.mouseEvent(with:type,location:canvas.convert(p,to:nil),modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1))}
        XCTAssertEqual(canvas.marker(at:point)?.id,marker.id)
        if let output=testArtifactDirectory() {
            try FileManager.default.createDirectory(atPath:output,withIntermediateDirectories:true)
            let frame=try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in:canvas.bounds));canvas.cacheDisplay(in:canvas.bounds,to:frame)
            try XCTUnwrap(frame.representation(using:.png,properties:[:])).write(to:URL(fileURLWithPath:output).appendingPathComponent("marker-timeline.png"))
        }
        canvas.mouseDown(with:try mouse(.leftMouseDown,point));canvas.mouseDragged(with:try mouse(.leftMouseDragged,NSPoint(x:point.x+72,y:point.y)))
        XCTAssertEqual(s.project.markers?.first?.time,2)
        canvas.mouseUp(with:try mouse(.leftMouseUp,point));XCTAssertEqual(s.project.markers?.first?.time,3);s.undo();XCTAssertEqual(s.project.markers?.first?.time,2);XCTAssertFalse(s.canUndo)
        canvas.mouseDown(with:try mouse(.leftMouseDown,point));canvas.mouseDragged(with:try mouse(.leftMouseDragged,NSPoint(x:point.x+72,y:point.y)))
        let escape=try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:53));canvas.keyDown(with:escape);canvas.mouseUp(with:try mouse(.leftMouseUp,point));XCTAssertEqual(s.project.markers?.first?.time,2)
        XCTAssertTrue(canvas.menu(for:try mouse(.rightMouseDown,point))?.items.contains(where:{$0.title==L("マーカーを編集")}) == true)
        let delete=try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:51));XCTAssertTrue(canvas.handleMarkerKey(delete));XCTAssertEqual(s.project.clips.count,1);XCTAssertEqual(s.project.markers?.count,0)
    }
    @MainActor func testMarkerPanelSnapshot()async throws {
        guard let output=testArtifactDirectory() else{throw XCTSkip("Opt-in marker editor snapshot")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-marker-panel-\(UUID())"),s=EditorStore(preferencesDirectory:root)
        defer{try? FileManager.default.removeItem(at:s.directory);try? FileManager.default.removeItem(at:root)}
        s.project=Project();s.addMarker(at:3.5,name:"セリフ開始");s.addMarker(at:8,name:"場面転換");s.selectedMarkerID=s.project.markers?.first?.id
        try FileManager.default.createDirectory(atPath:output,withIntermediateDirectories:true)
        let host=NSHostingView(rootView:MarkerListView(store:s).frame(width:780,height:480).background(Color.white).environment(\.colorScheme,.light))
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:780,height:480),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.appearance=NSAppearance(named:.aqua);host.appearance=NSAppearance(named:.aqua);window.contentView=host;defer{window.close()}
        host.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:100_000_000)
        let rep=try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds));host.cacheDisplay(in:host.bounds,to:rep)
        try XCTUnwrap(rep.representation(using:.png,properties:[:])).write(to:URL(fileURLWithPath:output).appendingPathComponent("marker-editor.png"))
    }

}
