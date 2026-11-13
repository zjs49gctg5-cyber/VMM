import XCTest
import AppKit
import AVFoundation
@testable import VMM

final class PreviewEditingTests:XCTestCase {
    @MainActor func testHiddenDialogueCaptionCannotBeSelectedInPreview() {
        let (store,view,_)=fixture();defer{try? FileManager.default.removeItem(at:store.directory)}
        var clip=Clip(kind:.speech,name:"line",track:0,start:0,duration:2,text:"隠した字幕")
        store.project.clips=[clip];XCTAssertNotNil(view.geometry(clip))
        clip.speechCaptionHidden=true;store.project.clips=[clip];XCTAssertNil(view.geometry(clip))
    }
    @MainActor func fixture()->(EditorStore,ObjectEditingView,Clip) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-preview-edit-\(UUID())")
        let store=EditorStore(preferencesDirectory:root);store.autoSpeech=false
        var clip=Clip(kind:.shape,name:"shape",track:0,start:0,duration:2);var style=ShapeStyle();style.width=0.4;style.height=0.3;style.cornerRadius=0;clip.shapeStyle=style
        store.project.width=400;store.project.height=300;store.project.clips=[clip];store.selectedID=clip.id
        let view=ObjectEditingView(frame:NSRect(x:0,y:0,width:400,height:300));view.store=store
        return (store,view,clip)
    }
    @MainActor func event(_ type:NSEvent.EventType,_ point:CGPoint,view:NSView,flags:NSEvent.ModifierFlags=[])->NSEvent {NSEvent.mouseEvent(with:type,location:view.convert(point,to:nil),modifierFlags:flags,timestamp:0,windowNumber:0,context:nil,eventNumber:0,clickCount:1,pressure:1)!}
    @MainActor func drag(_ view:ObjectEditingView,from:CGPoint,to:CGPoint,flags:NSEvent.ModifierFlags=[]) {
        view.mouseDown(with:event(.leftMouseDown,from,view:view));view.mouseDragged(with:event(.leftMouseDragged,to,view:view,flags:flags));view.mouseUp(with:event(.leftMouseUp,to,view:view))
    }
    @MainActor func testDoubleClickTextEditCommitCancelAndLocked()throws {
        let (store,view,_)=fixture();defer{try? FileManager.default.removeItem(at:store.directory)}
        var clip=Clip(kind:.speech,name:"line",track:0,start:0,duration:2,text:"こんにちは");clip.fontSize=48;store.project.clips=[clip];store.selectedID=clip.id
        let g=try XCTUnwrap(view.geometry(clip)),point=CGPoint(x:g.rect.midX,y:g.rect.midY).applying(g.transform)
        func doubleClick() {let event=NSEvent.mouseEvent(with:.leftMouseDown,location:view.convert(point,to:nil),modifierFlags:[],timestamp:0,windowNumber:0,context:nil,eventNumber:0,clickCount:2,pressure:1)!;view.mouseDown(with:event)}
        doubleClick();let input=try XCTUnwrap(view.textInput);XCTAssertEqual(input.string,clip.text)
        input.string="新しい台詞\n二行目";view.finishTextEditing(commit:true)
        XCTAssertEqual(store.selected?.text,"新しい台詞\n二行目");XCTAssertTrue(store.selected?.speechDirty == true)
        store.undo();XCTAssertEqual(store.selected?.text,"こんにちは");XCTAssertFalse(store.canUndo)
        doubleClick();try XCTUnwrap(view.textInput).string="取り消し";view.finishTextEditing(commit:false)
        XCTAssertEqual(store.selected?.text,"こんにちは");XCTAssertFalse(store.canUndo)
        store.project.tracks[0].locked=true;doubleClick();XCTAssertNil(view.textInput);XCTAssertFalse(store.canUndo)
        store.project.tracks[0].locked=false;doubleClick();try XCTUnwrap(view.textInput).string="競合";store.project.clips[0].text="別の変更";view.finishTextEditing(commit:true)
        XCTAssertEqual(store.selected?.text,"別の変更");XCTAssertNotNil(store.error);XCTAssertEqual(view.textInput?.string,"競合")
        view.finishTextEditing(commit:false)
    }
    @MainActor func testPreviewTextEditorSnapshot()throws {
        guard let folder=testArtifactDirectory() else{throw XCTSkip("Opt-in preview editor snapshot")}
        let (store,view,_)=fixture();defer{try? FileManager.default.removeItem(at:store.directory)}
        var clip=Clip(kind:.text,name:"caption",track:0,start:0,duration:2,text:"字幕をプレビューで編集\n二行目");clip.fontSize=32;store.project.clips=[clip];store.selectedID=clip.id
        let window=NSWindow(contentRect:view.bounds,styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.contentView=view;window.orderBack(nil);defer{window.close()}
        view.wantsLayer=true;view.layer?.backgroundColor=NSColor.darkGray.cgColor
        view.beginTextEditing(clip);let input=try XCTUnwrap(view.textInput)
        XCTAssertTrue(window.firstResponder === input);XCTAssertGreaterThan(input.frame.width,100);XCTAssertGreaterThan(input.frame.height,40)
        view.layoutSubtreeIfNeeded();let bitmap=try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds));view.cacheDisplay(in:view.bounds,to:bitmap)
        let destination=URL(fileURLWithPath:folder);try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
        try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:destination.appendingPathComponent("preview-text-editor.png"))
    }
    @MainActor func testMoveRotateStretchAndSingleUndo()throws {
        let (s,v,c)=fixture();defer{try? FileManager.default.removeItem(at:s.directory)}
        drag(v,from:CGPoint(x:200,y:150),to:CGPoint(x:240,y:180))
        XCTAssertEqual(s.selected?.x ?? 0,0.6,accuracy:0.0001);XCTAssertEqual(s.selected?.y ?? 0,0.6,accuracy:0.0001)
        s.undo();XCTAssertEqual(s.project.clips,[c]);XCTAssertFalse(s.canUndo)
        let g=try XCTUnwrap(v.geometry(c));drag(v,from:g.rotationHandle,to:CGPoint(x:200+hypot(g.rotationHandle.x-200,g.rotationHandle.y-150),y:150))
        XCTAssertEqual(s.selected?.rotation ?? 0,90,accuracy:0.0001);s.undo()
        drag(v,from:g.points[4],to:CGPoint(x:320,y:225))
        XCTAssertEqual(s.selected?.transform?.scaleX ?? 0,1.25,accuracy:0.0001);XCTAssertEqual(s.selected?.transform?.scaleY ?? 0,4.0/3,accuracy:0.0001)
        let resized=try XCTUnwrap(v.geometry(try XCTUnwrap(s.selected)))
        XCTAssertEqual(resized.points[0].x,g.points[0].x,accuracy:0.0001);XCTAssertEqual(resized.points[0].y,g.points[0].y,accuracy:0.0001)
        s.undo();XCTAssertEqual(s.project.clips,[c])
    }
    @MainActor func testCursorFollowsHandleDirectionAndDragging()throws {
        let (s,v,c)=fixture();defer{try? FileManager.default.removeItem(at:s.directory)}
        let g=try XCTUnwrap(v.geometry(c))
        let kinds:[PreviewCursorKind]=[.diagonalDown,.vertical,.diagonalUp,.horizontal,.diagonalDown,.vertical,.diagonalUp,.horizontal]
        for i in 0..<8 {XCTAssertEqual(v.cursorKind(at:g.points[i]),kinds[i])}
        XCTAssertEqual(v.cursorKind(at:g.rotationHandle),.rotate)
        XCTAssertEqual(v.cursorKind(at:g.pivot),.move)
        XCTAssertEqual(v.cursorKind(at:CGPoint(x:5,y:5)),.arrow)
        v.mouseDown(with:event(.leftMouseDown,g.pivot,view:v));XCTAssertEqual(v.cursorKind(at:g.pivot),.grabbing)
        v.mouseUp(with:event(.leftMouseUp,g.pivot,view:v));XCTAssertEqual(v.cursorKind(at:g.pivot),.move)
        s.project.clips[0].rotation=90
        let rotated=try XCTUnwrap(v.geometry(s.project.clips[0]))
        XCTAssertEqual(v.cursorKind(at:rotated.points[3]),.vertical)
        XCTAssertEqual(v.cursorKind(at:rotated.points[1]),.horizontal)
        s.project.tracks[0].locked=true;XCTAssertEqual(v.cursorKind(at:rotated.pivot),.arrow)
    }
    @MainActor func testTopmostSelectionLockedLayerAndShiftResize()throws {
        let (s,v,c)=fixture();defer{try? FileManager.default.removeItem(at:s.directory)}
        var top=c;top.id=UUID();top.track=2;top.name="top";s.project.clips.append(top)
        drag(v,from:CGPoint(x:200,y:150),to:CGPoint(x:220,y:150));XCTAssertEqual(s.selectedID,top.id);XCTAssertEqual(s.project.clips[0],c)
        s.undo();s.project.tracks[2].locked=true
        drag(v,from:CGPoint(x:200,y:150),to:CGPoint(x:230,y:160));XCTAssertEqual(s.selectedID,top.id);XCTAssertEqual(s.selected?.x,top.x);XCTAssertFalse(s.canUndo)
        s.project.clips=[c];s.selectedID=c.id
        let g=try XCTUnwrap(v.geometry(c));drag(v,from:g.points[4],to:CGPoint(x:320,y:225),flags:.shift)
        XCTAssertEqual(s.selected?.transform,c.transform);XCTAssertGreaterThan(s.selected?.scale ?? 0,1)
        let resized=try XCTUnwrap(v.geometry(try XCTUnwrap(s.selected)));XCTAssertEqual(resized.points[0].x,g.points[0].x,accuracy:0.0001);XCTAssertEqual(resized.points[0].y,g.points[0].y,accuracy:0.0001)
    }
    @MainActor func testParentCoordinatesAndAnimationArePreserved()throws {
        let (s,v,c)=fixture();defer{try? FileManager.default.removeItem(at:s.directory)}
        var group=Clip(kind:.group,name:"parent",track:0,start:0,duration:2);group.rotation=90;group.scale=0.5
        var child=c;child.parentID=group.id;child.animation=ClipAnimation(tracks:[AnimationTrack(property:.x,keys:[AnimationKeyframe(time:0,value:0.4),AnimationKeyframe(time:2,value:0.6)])])
        s.project.clips=[group,child];s.selectedID=child.id;s.playhead=1
        let g=try XCTUnwrap(v.geometry(child));drag(v,from:g.pivot,to:CGPoint(x:g.pivot.x+20,y:g.pivot.y))
        let edited=try XCTUnwrap(s.selected);XCTAssertEqual(edited.parentID,group.id);XCTAssertEqual(edited.animation?.tracks[0].keys.count,2)
        let moved=try XCTUnwrap(v.geometry(edited));XCTAssertEqual(moved.pivot.x-g.pivot.x,20,accuracy:0.001);XCTAssertEqual(moved.pivot.y,g.pivot.y,accuracy:0.001)
        s.undo();XCTAssertEqual(s.project.clips,[group,child])
    }
    func testShapeLegacyValidationAndTimelineText()throws {
        var p=Project();var c=Clip(kind:.text,name:"generic title",track:0,start:0,duration:1);c.text="字幕の内容\n続き";p.clips=[c]
        XCTAssertEqual(c.timelineTitle,"字幕の内容 続き")
        let decoded=try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(p));XCTAssertNil(decoded.clips[0].shapeStyle)
        var shape=ShapeStyle();shape.width = .nan;p.clips[0].shapeStyle=shape;XCTAssertThrowsError(try p.validated())
        for kind in ShapeKind.allCases {shape=ShapeStyle();shape.kind=kind;try shape.validate();XCTAssertFalse(ShapePainter.path(shape,in:CGRect(x:0,y:0,width:160,height:90)).isEmpty)}
    }
    func testArrowheadSizeAndLegacyCompatibility()throws {
        var style=ShapeStyle();style.kind = .arrow;style.cornerRadius=0
        let rect=CGRect(x:0,y:0,width:100,height:100)
        let legacy=try JSONDecoder().decode(ShapeStyle.self,from:JSONEncoder().encode(style))
        XCTAssertNil(legacy.arrowHeadLength);XCTAssertNil(legacy.arrowHeadHeight)
        XCTAssertTrue(ShapePainter.path(legacy,in:rect).contains(CGPoint(x:70,y:15)))
        style.arrowHeadLength=0.6
        XCTAssertTrue(ShapePainter.path(style,in:rect).contains(CGPoint(x:45,y:15)))
        XCTAssertFalse(ShapePainter.path(legacy,in:rect).contains(CGPoint(x:45,y:15)))
        style.arrowHeadHeight=0.5
        XCTAssertFalse(ShapePainter.path(style,in:rect).contains(CGPoint(x:45,y:15)))
        XCTAssertTrue(ShapePainter.path(style,in:rect).contains(CGPoint(x:45,y:30)))
        let decoded=try JSONDecoder().decode(ShapeStyle.self,from:JSONEncoder().encode(style))
        XCTAssertEqual(decoded,style);try decoded.validate()
        for invalid in [Double.nan,0,1.01] {
            style.arrowHeadLength=invalid;XCTAssertThrowsError(try style.validate())
            style.arrowHeadLength=0.35;style.arrowHeadHeight=invalid;XCTAssertThrowsError(try style.validate());style.arrowHeadHeight=1
        }
    }
    func testShapesInPreviewAndActualMP4()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-shape-export-\(UUID())");try FileManager.default.createDirectory(at:root.appendingPathComponent("Media"),withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        var p=Project();p.width=640;p.height=360;p.background="183040";p.clips=[]
        for (i,kind) in ShapeKind.allCases.enumerated() {
            var clip=Clip(kind:.shape,name:kind.title,track:0,start:0,duration:1);clip.x=Double(i%3+1)/4;clip.y=Double(i/3+1)/4;clip.color="66CCFF"
            var style=ShapeStyle();style.kind=kind;style.width=0.18;style.height=0.18;style.cornerRadius=kind == .rectangle ? 15:0;style.outline=true;style.outlineWidth=3;style.shadow=true;style.shadowBlur=4;style.shadowX=5;style.shadowY=7;if kind == .arrow {style.arrowHeadLength=0.55;style.arrowHeadHeight=0.65};clip.shapeStyle=style;p.clips.append(clip)
        }
        let context=try XCTUnwrap(CGContext(data:nil,width:p.width,height:p.height,bitsPerComponent:8,bytesPerRow:p.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        FrameRenderer().draw(project:p,directory:root,time:0.5,context:context,size:CGSize(width:p.width,height:p.height))
        let preview=try XCTUnwrap(context.makeImage()),output=root.appendingPathComponent("shapes.mp4")
        try await MovieExporter.export(project:p,directory:root,destination:output){_ in}
        let generator=AVAssetImageGenerator(asset:AVURLAsset(url:output));generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
        let frame=try generator.copyCGImage(at:CMTime(seconds:0.5,preferredTimescale:600),actualTime:nil)
        let a=NSBitmapImageRep(cgImage:preview),b=NSBitmapImageRep(cgImage:frame);var difference=0.0;var count=0
        for y in stride(from:4,to:p.height,by:8) {for x in stride(from:4,to:p.width,by:8) {
            let left=try XCTUnwrap(a.colorAt(x:x,y:y)?.usingColorSpace(.sRGB)),right=try XCTUnwrap(b.colorAt(x:x,y:y)?.usingColorSpace(.sRGB))
            difference+=abs(left.redComponent-right.redComponent)+abs(left.greenComponent-right.greenComponent)+abs(left.blueComponent-right.blueComponent);count+=3
        }}
        // H.264 chroma subsampling and the decoder color profile introduce small RGB differences.
        XCTAssertLessThan(difference/Double(count),0.06)
        let ellipse=try XCTUnwrap(a.colorAt(x:320,y:90)?.usingColorSpace(.sRGB));XCTAssertGreaterThan(ellipse.blueComponent,0.8)
        if let destination=testArtifactDirectory() {
            let folder=URL(fileURLWithPath:destination);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            try FileManager.default.copyItem(at:output,to:folder.appendingPathComponent("shapes.mp4"));try a.representation(using:.png,properties:[:])?.write(to:folder.appendingPathComponent("shape-preview.png"));try b.representation(using:.png,properties:[:])?.write(to:folder.appendingPathComponent("shape-export.png"))
        }
    }
}
