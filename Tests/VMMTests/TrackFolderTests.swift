import XCTest
import AppKit
@testable import VMM

final class TrackFolderTests:XCTestCase {
    func testFolderValidationDoesNotDependOnMediaAssets() throws {
        var project=Project();project.assets=[]
        project.tracks[0].folder=TrackFolder(name:"")
        XCTAssertThrowsError(try project.validated())
        project.tracks[0].folder=TrackFolder(name:"Cast")
        XCTAssertNoThrow(try project.validated())
    }
    @MainActor func testFolderLayoutUndoCompatibilityAndHiddenSelection()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-folders-\(UUID())"),store=EditorStore(preferencesDirectory:root)
        defer{try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        store.autoSpeech=false;store.project=Project()
        let ids=store.project.tracks.map(\.id)
        let a=Clip(kind:.text,name:"A",track:1,start:0,duration:2,text:"A"),b=Clip(kind:.text,name:"B",track:2,start:0,duration:2,text:"B")
        store.project.clips=[a,b];store.selectedID=a.id;store.selectedIDs=[a.id,b.id];store.selectedTrack=1
        try store.createTrackFolder(name:"Characters",trackID:ids[1]);let folder=try XCTUnwrap(store.project.tracks[1].folder)
        try store.assignTrackFolder(ids[2],folderID:folder.id)
        XCTAssertEqual(TrackFolderLayout(project:store.project,collapsed:[]).rows,[.track(0),.folder(folder.id),.track(1),.track(2),.track(3),.track(4)])
        store.toggleTrackFolder(folder.id)
        XCTAssertNil(store.selectedID);XCTAssertTrue(store.selectedIDs.isEmpty);XCTAssertEqual(store.selectedTrack,0)
        let canvas=TimelineNSView();canvas.store=store
        XCTAssertTrue(canvas.rect(a).isNull);XCTAssertEqual(canvas.track(at:NSPoint(x:canvas.header+10,y:canvas.ruler+canvas.row*2+2)),3)
        store.selectedIDs=[a.id,b.id];XCTAssertFalse(store.collapsedTrackFolders.contains(folder.id));XCTAssertFalse(canvas.rect(a).isNull)
        try store.renameTrackFolder(folder.id,name:"Cast");XCTAssertEqual(store.project.tracks[1].folder?.name,"Cast");XCTAssertEqual(store.project.tracks[2].folder?.name,"Cast")
        store.undo();XCTAssertEqual(store.project.tracks[1].folder?.name,"Characters");XCTAssertEqual(store.project.tracks[2].folder?.name,"Characters")
        let decoded=try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(store.project));_=try decoded.validated();XCTAssertEqual(decoded,store.project)
        var legacy=Project();legacy.tracks=legacy.tracks.map{var t=$0;t.folder=nil;return t}
        let legacyData=try JSONEncoder().encode(legacy);XCTAssertTrue(try JSONDecoder().decode(Project.self,from:legacyData).tracks.allSatisfy{$0.folder==nil})
        try store.deleteTrackFolder(folder.id);XCTAssertTrue(store.project.tracks.allSatisfy{$0.folder==nil});store.undo();XCTAssertEqual(store.project.tracks[1].folder?.id,folder.id)
    }
    @MainActor func testReorderedFolderRunsAndNativeHitTesting()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-folders-native-\(UUID())"),store=EditorStore(preferencesDirectory:root)
        defer{try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        store.project=Project();store.project.clips=[]
        let ids=store.project.tracks.map(\.id);try store.createTrackFolder(name:"Cast",trackID:ids[0]);let folder=try XCTUnwrap(store.project.tracks[0].folder)
        try store.assignTrackFolder(ids[2],folderID:folder.id)
        let layout=TrackFolderLayout(project:store.project,collapsed:[])
        XCTAssertEqual(layout.rows,[.folder(folder.id),.track(0),.track(1),.folder(folder.id),.track(2),.track(3),.track(4)])
        let canvas=TimelineNSView(frame:NSRect(x:0,y:0,width:1000,height:600));canvas.store=store
        let window=NSWindow(contentRect:canvas.frame,styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.contentView=canvas;defer{window.close()}
        func event(_ type:NSEvent.EventType,_ point:NSPoint)throws->NSEvent{try XCTUnwrap(NSEvent.mouseEvent(with:type,location:canvas.convert(point,to:nil),modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1))}
        let header=NSPoint(x:15,y:canvas.ruler+canvas.row/2)
        canvas.mouseDown(with:try event(.leftMouseDown,header));XCTAssertTrue(store.collapsedTrackFolders.contains(folder.id))
        XCTAssertNil(canvas.track(at:header));XCTAssertEqual(canvas.track(at:NSPoint(x:10,y:canvas.ruler+canvas.row*1.5)),1)
        canvas.mouseDown(with:try event(.leftMouseDown,header));XCTAssertFalse(store.collapsedTrackFolders.contains(folder.id))
        let menu=try XCTUnwrap(canvas.menu(for:try event(.rightMouseDown,header)));XCTAssertTrue(menu.items.contains{$0.title==L("フォルダ名を変更")})
        store.moveTrack(from:0,to:4);_=try store.project.validated()
        XCTAssertEqual(store.project.tracks.map(\.id),[ids[1],ids[2],ids[3],ids[4],ids[0]])
    }
    @MainActor func testFolderSurvivesPrecomposition()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-folders-precomp-\(UUID())"),store=EditorStore(preferencesDirectory:root)
        defer{try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        store.project=Project();let id=store.project.tracks[1].id;try store.createTrackFolder(name:"Inside",trackID:id)
        let internalTracks=[store.project.tracks[1]],comp=Precomposition(name:"test",width:1920,height:1080,fps:30,duration:2,tracks:internalTracks,clips:[])
        store.project.precompositions=[comp];_=try store.project.validated()
        let copy=store.project.compositionProject(comp);_=try copy.validated(validateCompositions:false)
        XCTAssertEqual(copy.trackFolders.first?.name,"Inside")
    }
    @MainActor func testDragTargetsVisibleTracksAndDoesNotMoveHiddenSelection()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-folders-drag-\(UUID())"),store=EditorStore(preferencesDirectory:root)
        defer{try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        store.autoSpeech=false;store.project=Project();store.project.clips=[]
        let ids=store.project.tracks.map(\.id);try store.createTrackFolder(name:"Cast",trackID:ids[1]);let folder=try XCTUnwrap(store.project.tracks[1].folder)
        try store.assignTrackFolder(ids[2],folderID:folder.id)
        let visible=Clip(kind:.text,name:"Visible",track:0,start:1,duration:2,text:"text"),hidden=Clip(kind:.text,name:"Hidden",track:1,start:1,duration:2,text:"text")
        store.project.clips=[visible,hidden];store.selectedIDs=[visible.id,hidden.id];store.selectedID=hidden.id
        store.toggleTrackFolder(folder.id);XCTAssertEqual(store.selectedIDs,[visible.id]);XCTAssertEqual(store.selectedID,visible.id)
        let canvas=TimelineNSView(frame:NSRect(x:0,y:0,width:1000,height:600));canvas.store=store
        let window=NSWindow(contentRect:canvas.frame,styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.contentView=canvas;defer{window.close()}
        func mouse(_ type:NSEvent.EventType,_ p:NSPoint)throws->NSEvent{try XCTUnwrap(NSEvent.mouseEvent(with:type,location:canvas.convert(p,to:nil),modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1))}
        let original=canvas.rect(visible),start=NSPoint(x:original.midX,y:original.midY),target=NSPoint(x:start.x,y:canvas.ruler+canvas.row*2.5)
        XCTAssertEqual(canvas.track(at:target),3)
        canvas.mouseDown(with:try mouse(.leftMouseDown,start));canvas.mouseDragged(with:try mouse(.leftMouseDragged,target));canvas.mouseUp(with:try mouse(.leftMouseUp,target))
        XCTAssertEqual(store.project.clips.first{$0.id==visible.id}?.track,3);XCTAssertEqual(store.project.clips.first{$0.id==hidden.id}?.track,1)
        if let output=testArtifactDirectory(){try FileManager.default.createDirectory(atPath:output,withIntermediateDirectories:true);let rep=try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in:canvas.bounds));canvas.cacheDisplay(in:canvas.bounds,to:rep);try XCTUnwrap(rep.representation(using:.png,properties:[:])).write(to:URL(fileURLWithPath:output).appendingPathComponent("track-folders.png"))}
    }
}
