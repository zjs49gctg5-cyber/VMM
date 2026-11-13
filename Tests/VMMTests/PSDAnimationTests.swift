import XCTest
import AppKit
import AVFoundation
@testable import VMM

final class PSDAnimationTests:XCTestCase {
    func fixture(_ root:URL)throws->Project {
        let media=root.appendingPathComponent("Media");try FileManager.default.createDirectory(at:media,withIntermediateDirectories:true)
        for (name,color) in [("red.png",NSColor.red),("blue.png",NSColor.blue)] {
            let context=try XCTUnwrap(RasterTools.bitmap(CGSize(width:320,height:180)))
            context.setFillColor(color.cgColor);context.fill(CGRect(x:0,y:0,width:320,height:180))
            try XCTUnwrap(NSBitmapImageRep(cgImage:try XCTUnwrap(context.makeImage())).representation(using:.png,properties:[:])).write(to:media.appendingPathComponent(name))
        }
        try Data("fixture".utf8).write(to:media.appendingPathComponent("sample.psd"))
        let doc=PSDDocument(width:320,height:180,layers:[
            PSDLayer(id:0,name:"*赤",group:false,visible:true,opacity:1,x:0,y:0,width:320,height:180,file:"red.png"),
            PSDLayer(id:1,name:"*青",group:false,visible:false,opacity:1,x:0,y:0,width:320,height:180,file:"blue.png")])
        let asset=MediaAsset(name:"test",file:"sample.psd",kind:.image,duration:4,psd:doc)
        var clip=Clip(kind:.image,name:"立ち絵",track:0,start:0,duration:4);clip.assetID=asset.id;clip.psd = .initial(doc)
        clip.psd?.selectionKeys=[PSDSelectionKeyframe(time:1,name:"青",selected:[1]),PSDSelectionKeyframe(time:2,name:"赤",selected:[0])]
        var p=Project();p.width=320;p.height=180;p.assets=[asset];p.clips=[clip];return try p.validated()
    }
    func testPreviewAndActualMP4SwitchAtSpecifiedTimes()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-psd-animation-\(UUID())")
        defer{try? FileManager.default.removeItem(at:root)}
        let p=try await MainActor.run {
            let store=EditorStore(preferencesDirectory:root.appendingPathComponent("Prefs"));store.autoSpeech=false;store.settings.autosaveSeconds=0
            defer{store.pause();try? FileManager.default.removeItem(at:store.directory)}
            store.project=try fixture(root);let c=store.project.clips[0]
            _=try store.movePSDPoint(c.id,keyID:try XCTUnwrap(c.psd?.selectionKeys?.first).id,to:1.5)
            return store.project
        },renderer=FrameRenderer()
        for (time,blue) in [(1.4,false),(1.5,true),(1.9,true),(2.0,false)] {
            let context=try XCTUnwrap(RasterTools.bitmap(CGSize(width:320,height:180)))
            renderer.draw(project:p,directory:root,time:time,context:context,size:CGSize(width:320,height:180))
            let color=try XCTUnwrap(NSBitmapImageRep(cgImage:try XCTUnwrap(context.makeImage())).colorAt(x:160,y:90)?.usingColorSpace(.sRGB))
            XCTAssertGreaterThan(blue ? color.blueComponent:color.redComponent,0.9)
        }
        let output=root.appendingPathComponent("switch.mp4")
        try await MovieExporter.export(project:p,directory:root,destination:output){_ in}
        let generator=AVAssetImageGenerator(asset:AVURLAsset(url:output));generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
        for (time,blue) in [(1.4,false),(1.6,true),(2.1,false)] {
            let image=try generator.copyCGImage(at:CMTime(seconds:time,preferredTimescale:600),actualTime:nil)
            let color=try XCTUnwrap(NSBitmapImageRep(cgImage:image).colorAt(x:160,y:90)?.usingColorSpace(.sRGB))
            XCTAssertGreaterThan(blue ? color.blueComponent:color.redComponent,0.8)
        }
        XCTAssertEqual(try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(p)),p)
        var legacy=p;legacy.clips[0].psd?.selectionKeys=nil
        XCTAssertNil(try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(legacy)).clips[0].psd?.selectionKeys)
        var invalid=p;invalid.clips[0].psd?.selectionKeys?[0].selected=[999];XCTAssertThrowsError(try invalid.validated())
        invalid=p;invalid.clips[0].psd?.selectionKeys?[1].time=1.5;XCTAssertThrowsError(try invalid.validated())
    }
    @MainActor func testEditingFavoritesUndoSplitTrimAndPlayback()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-psd-edit-\(UUID())")
        let store=EditorStore(preferencesDirectory:root.appendingPathComponent("Prefs"));store.autoSpeech=false
        defer{store.pause();try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        store.project=try fixture(root);let original=store.project.clips[0];store.selectedID=original.id
        let doc=try XCTUnwrap(store.project.assets[0].psd)
        store.seek(3)
        store.addPSDSelectionKey(original.id,favorite:PSDFavorite(name:"青",paths:[doc.path(for:1)]))
        XCTAssertEqual(store.selected?.psd?.selection(at:3),[1]);XCTAssertEqual(store.selected?.psd?.selectionKeys?.count,3)
        store.undo();XCTAssertEqual(store.selected?.psd?.selectionKeys?.count,2)
        store.seek(1.5);store.splitSelected()
        let right=try XCTUnwrap(store.selected)
        XCTAssertEqual(right.psd?.selection(at:right.motionTime(at:1.5)),[1])
        XCTAssertEqual(right.psd?.selection(at:right.motionTime(at:2.1)),[0])
        store.undo()
        let trimmed=store.timelineChange(original,delta:1.5,track:0,edge:-1)
        XCTAssertEqual(trimmed.animationTimeOffset,1.5,accuracy:0.000001)
        XCTAssertEqual(trimmed.psd?.selection(at:trimmed.motionTime(at:trimmed.start)),[1])
        let key=try XCTUnwrap(original.psd?.selectionKeys?.first)
        store.editPSDSelectionKey(original.id,key.id){$0.time=2}
        XCTAssertEqual(store.project.clips[0].psd?.selectionKeys?.first?.time,1)
        store.error=nil;store.seek(8);store.toggleAnimationPlayback(original.id)
        XCTAssertEqual(store.playhead,0);XCTAssertTrue(store.playing)
        store.toggleAnimationPlayback(original.id);XCTAssertFalse(store.playing)
    }
    @MainActor func testTimelineMoveDuplicateDeleteOffsetsLocksAndUndo()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("psd-points-\(UUID())")
        let s=EditorStore(preferencesDirectory:root.appendingPathComponent("Prefs"));s.autoSpeech=false;s.settings.autosaveSeconds=0
        defer{s.pause();try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:s.directory)}
        s.project=try fixture(root);s.project.clips[0].animationOffset=0.125
        let c=s.project.clips[0],key=try XCTUnwrap(c.psd?.selectionKeys?.first),original=s.project
        let t=try s.movePSDPoint(c.id,keyID:key.id,to:c.motionStart+0.74)
        XCTAssertEqual(t,0.125+22.0/30,accuracy:0.000001);XCTAssertEqual(s.project.clips[0].psd?.selection(at:t),[1])
        s.undo();XCTAssertEqual(s.project,original);s.redo()
        let moved=s.project;XCTAssertThrowsError(try s.movePSDPoint(c.id,keyID:key.id,to:2));XCTAssertEqual(s.project,moved)
        let duplicate=try s.duplicatePSDPoint(c.id,keyID:key.id),copy=try XCTUnwrap(s.project.clips[0].psd?.selectionKeys?.first{$0.id==duplicate})
        XCTAssertEqual(copy.selected,key.selected);XCTAssertEqual(copy.time,t+1.0/30,accuracy:0.000001)
        try s.deletePSDPoint(c.id,keyID:duplicate);XCTAssertEqual(s.project,moved);s.undo();XCTAssertNotNil(s.project.clips[0].psd?.selectionKeys?.first{$0.id==duplicate})
        let startID=try s.insertPSDPoint(c.id,at:c.motionStart);_=try s.movePSDPoint(c.id,keyID:startID,to:c.motionEnd);try s.deletePSDPoint(c.id,keyID:startID)
        s.project.tracks[0].locked=true;let locked=s.project
        XCTAssertThrowsError(try s.deletePSDPoint(c.id,keyID:key.id));XCTAssertThrowsError(try s.insertPSDPoint(c.id,at:1.5));XCTAssertThrowsError(try s.movePSDPoint(c.id,keyID:key.id,to:1.5));XCTAssertEqual(s.project,locked)
    }
    func testAutomaticMouthOverridesScheduledExpression() {
        let doc=PSDTests().sample()
        var state=PSDState.initial(doc);state.selectionKeys=[PSDSelectionKeyframe(time:1,name:"閉じ口",selected:[0,2,3])]
        state.mouthClosed=2;state.mouthOpen=1;state.mouthAnimation=true
        XCTAssertTrue(state.visibility(document:doc,speaking:false,time:1.5).contains(2))
        XCTAssertTrue(state.visibility(document:doc,speaking:true,time:1.5).contains(1))
        XCTAssertFalse(state.visibility(document:doc,speaking:true,time:1.5).contains(2))
    }
}
