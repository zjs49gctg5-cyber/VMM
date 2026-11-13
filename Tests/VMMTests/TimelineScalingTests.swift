import AppKit
import XCTest
@testable import VMM

final class TimelineScalingTests:XCTestCase {
    @MainActor func testMultiSelectionDragPreservesRelativeTimingAndMovesChild()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-timeline-scaling-\(UUID())")
        let store=EditorStore(preferencesDirectory:root)
        defer{try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        store.autoSpeech=false
        let group=Clip(kind:.group,name:"group",track:0,start:1,duration:3)
        var child=Clip(kind:.text,name:"child",track:1,start:1,duration:2,text:"child")
        child.parentID=group.id
        let other=Clip(kind:.text,name:"other",track:2,start:5,duration:2,text:"other")
        store.project.clips=[group,child,other]
        store.selectedIDs=[group.id,other.id];store.selectedID=group.id
        let canvas=TimelineNSView(frame:NSRect(x:0,y:0,width:1000,height:600));canvas.store=store
        let window=NSWindow(contentRect:canvas.frame,styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.contentView=canvas;defer{window.close()}
        func mouse(_ type:NSEvent.EventType,_ point:NSPoint)throws->NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with:type,location:canvas.convert(point,to:nil),modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1))
        }
        let rect=canvas.rect(group),start=NSPoint(x:rect.midX,y:rect.midY),target=NSPoint(x:start.x+store.zoom,y:start.y)
        canvas.mouseDown(with:try mouse(.leftMouseDown,start))
        canvas.mouseDragged(with:try mouse(.leftMouseDragged,target))
        canvas.mouseUp(with:try mouse(.leftMouseUp,target))
        let moved=try XCTUnwrap(store.project.clips.first{$0.id==group.id}).start-group.start
        XCTAssertGreaterThan(moved,0.5)
        XCTAssertEqual(try XCTUnwrap(store.project.clips.first{$0.id==child.id}).start-child.start,moved,accuracy:0.001)
        XCTAssertEqual(try XCTUnwrap(store.project.clips.first{$0.id==other.id}).start-other.start,moved,accuracy:0.001)
    }

    func testHierarchyExpansionMatchesPreviousTraversal() {
        var project=Project()
        var clips=(0..<8).map{Clip(kind:.text,name:"clip\($0)",track:0,start:0,duration:1)}
        let linkA=UUID(),linkB=UUID(),missing=UUID()
        clips[1].parentID=clips[0].id
        clips[2].parentID=clips[1].id
        clips[2].linkID=linkA;clips[3].linkID=linkA
        clips[3].sceneMembers=[clips[4].id,missing]
        clips[4].linkID=linkB;clips[5].linkID=linkB
        clips[6].sceneMembers=[clips[7].id]
        clips[7].sceneMembers=[clips[6].id]
        project.clips=clips
        func reference(_ ids:Set<UUID>)->Set<UUID> {
            var result=ids,previous:Set<UUID>=[]
            while result != previous {
                previous=result;result=LinkedMedia.expanded(result,in:project)
                for id in Array(result) {result.formUnion(project.descendants(of:id))}
            }
            return result
        }
        for ids in [Set<UUID>(),Set([clips[0].id]),Set([clips[2].id]),Set([clips[6].id]),Set([missing]),Set([clips[1].id,clips[6].id])] {
            XCTAssertEqual(LinkedMedia.expandedHierarchy(ids,in:project),reference(ids))
        }
    }
    func testRowLookupMatchesVisibleRowsWithDiscontinuousFolders() {
        var project=Project()
        let folder=TrackFolder(name:"Cast")
        project.tracks[0].folder=folder
        project.tracks[2].folder=folder
        for collapsed in [Set<UUID>(),Set([folder.id])] {
            let layout=TrackFolderLayout(project:project,collapsed:collapsed)
            for track in -1...project.tracks.count {
                XCTAssertEqual(layout.row(forTrack:track),layout.rows.firstIndex(of:.track(track)))
            }
        }
    }

    func testOptInTimelineScaling()throws {
        guard ProcessInfo.processInfo.environment["VMM_TIMELINE_BENCHMARK"] == "1" else {throw XCTSkip("Opt-in timeline scaling measurement")}
        for count in [1000,5000] {
            var project=Project()
            project.tracks=(0..<32).map{Track(name:"Track \($0)")}
            project.clips=(0..<count).map{Clip(kind:.text,name:"clip\($0)",track:$0 % 32,start:Double($0),duration:1)}
            let selection:Set<UUID>=[project.clips[0].id]
            func timed(_ work:()->Int)->(Double,Int) {
                let start=ProcessInfo.processInfo.systemUptime
                let value=work()
                return ((ProcessInfo.processInfo.systemUptime-start)*1000,value)
            }
            let oldLayout=timed {
                project.clips.reduce(0){sum,clip in
                    var rows:[TrackFolderRow]=[],previous:UUID?
                    for (index,track) in project.tracks.enumerated() {
                        if let id=track.folderID {
                            if previous != id {rows.append(.folder(id))}
                            rows.append(.track(index));previous=id
                        } else {rows.append(.track(index));previous=nil}
                    }
                    return sum+(rows.firstIndex(of:.track(clip.track)) ?? 0)
                }
            }
            let newLayout=timed {
                let layout=TrackFolderLayout(project:project,collapsed:[])
                return project.clips.reduce(0){$0+(layout.row(forTrack:$1.track) ?? 0)}
            }
            XCTAssertEqual(oldLayout.1,newLayout.1)
            let oldSelection=timed {project.clips.filter{LinkedMedia.expanded(selection,in:project).contains($0.id)}.count}
            let newSelection=timed {
                let selected=LinkedMedia.expanded(selection,in:project)
                return project.clips.filter{selected.contains($0.id)}.count
            }
            XCTAssertEqual(oldSelection.1,newSelection.1)
            let all=Set(project.clips.map(\.id))
            let oldHierarchy=timed {
                var result=all,previous:Set<UUID>=[]
                while result != previous {
                    previous=result;result=LinkedMedia.expanded(result,in:project)
                    for id in Array(result) {result.formUnion(project.descendants(of:id))}
                }
                return result.count
            }
            let newHierarchy=timed {LinkedMedia.expandedHierarchy(all,in:project).count}
            XCTAssertEqual(oldHierarchy.1,newHierarchy.1)
            print("TIMELINE_SCALING clips=\(count) tracks=32 old_layout_ms=\(oldLayout.0) new_layout_ms=\(newLayout.0) old_select_ms=\(oldSelection.0) new_select_ms=\(newSelection.0) old_hierarchy_ms=\(oldHierarchy.0) new_hierarchy_ms=\(newHierarchy.0)")
        }
        let assets=(0..<5000).map{MediaAsset(name:"asset\($0)",file:"\($0).png",kind:.image,duration:1)}
        func oldQuery()->[UUID] {
            assets.enumerated().filter{LibraryFilter.all.includes($0.element)}.sorted{$0.offset < $1.offset}.map(\.element.id)
        }
        func newQuery()->[UUID] {
            LibraryQuery.assets(assets,search:"",filter:.all,sort:.imported,descending:false).map(\.id)
        }
        let startOld=ProcessInfo.processInfo.systemUptime,old=oldQuery(),oldTime=(ProcessInfo.processInfo.systemUptime-startOld)*1000
        let startNew=ProcessInfo.processInfo.systemUptime,new=newQuery(),newTime=(ProcessInfo.processInfo.systemUptime-startNew)*1000
        XCTAssertEqual(old,new)
        print("LIBRARY_SCALING assets=5000 old_query_ms=\(oldTime) new_query_ms=\(newTime)")
    }
}
