import XCTest
import AppKit
@testable import VMM

final class PreviewDraftSafetyTests:XCTestCase {
    @MainActor func fixture()throws->(EditorStore,ObjectEditingView,NSWindow,Clip,URL) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-preview-draft-\(UUID())"),store=EditorStore(preferencesDirectory:root)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        var clip=Clip(kind:.text,name:"caption",track:0,start:0,duration:2,text:"元の字幕");clip.fontSize=48
        store.autoSpeech=false;store.project=Project();store.project.width=400;store.project.height=300;store.project.clips=[clip];store.selectedID=clip.id;store.dirty=false
        let view=ObjectEditingView(frame:CGRect(x:0,y:0,width:400,height:300));view.store=store
        let window=NSWindow(contentRect:view.bounds,styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.contentView=view;window.orderBack(nil)
        return (store,view,window,clip,root)
    }
    @MainActor func testSaveAndPlaybackCommitDraftWithOneUndo()async throws {
        let (store,view,window,clip,root)=try fixture();defer{store.pause();window.close();try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        view.beginTextEditing(clip);try XCTUnwrap(view.textInput).string="保存する字幕"
        let destination=root.appendingPathComponent("saved.vmm")
        let savedOK=await store.saveProject(to:destination);XCTAssertTrue(savedOK);XCTAssertNil(view.textInput)
        let saved=try JSONDecoder().decode(Project.self,from:Data(contentsOf:destination.appendingPathComponent("project.json")))
        XCTAssertEqual(saved.clips.first?.text,"保存する字幕")
        store.undo();XCTAssertEqual(store.project.clips.first?.text,"元の字幕")
        let current=try XCTUnwrap(store.selected);view.beginTextEditing(current);try XCTUnwrap(view.textInput).string="再生する字幕"
        store.play();XCTAssertTrue(store.playing);XCTAssertEqual(store.project.clips.first?.text,"再生する字幕");XCTAssertNil(view.textInput);store.pause()
    }
    @MainActor func testConflictAndLockedDraftNeverDiscarded()throws {
        let (store,view,window,clip,root)=try fixture();defer{window.close();try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        view.beginTextEditing(clip);try XCTUnwrap(view.textInput).string="草稿"
        store.project.clips[0].text="外部変更"
        XCTAssertFalse(store.finishPendingPreviewText());XCTAssertEqual(view.textInput?.string,"草稿");XCTAssertEqual(store.project.clips[0].text,"外部変更")
        store.play();XCTAssertFalse(store.playing);XCTAssertEqual(view.textInput?.string,"草稿")
        store.project.clips[0].text=clip.text;store.project.tracks[0].locked=true
        XCTAssertFalse(store.finishPendingPreviewText());XCTAssertEqual(view.textInput?.string,"草稿")
        store.project.tracks[0].locked=false;XCTAssertTrue(store.finishPendingPreviewText());XCTAssertEqual(store.project.clips[0].text,"草稿")
        store.undo();XCTAssertEqual(store.project.clips[0].text,clip.text)
    }
    @MainActor func testMarkedTextIsCommittedBeforeDocumentAction()throws {
        let (store,view,window,clip,root)=try fixture();defer{window.close();try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        view.beginTextEditing(clip);let input=try XCTUnwrap(view.textInput)
        input.setSelectedRange(NSRange(location:(input.string as NSString).length,length:0))
        input.setMarkedText("かな",selectedRange:NSRange(location:2,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
        XCTAssertTrue(input.hasMarkedText());let composed=input.string
        XCTAssertTrue(store.finishPendingPreviewText());XCTAssertEqual(store.project.clips[0].text,composed);XCTAssertTrue(composed.hasSuffix("かな"))
    }
    @MainActor func testCanceledSaveKeepsCommittedDraftAndUndo()throws {
        let (store,view,window,clip,root)=try fixture();defer{window.close();try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        view.beginTextEditing(clip);try XCTUnwrap(view.textInput).string="保存取消後も残る"
        store.requestSave(chooseDestination:{nil})
        XCTAssertEqual(store.project.clips[0].text,"保存取消後も残る");XCTAssertTrue(store.dirty);XCTAssertNil(view.textInput)
        store.undo();XCTAssertEqual(store.project.clips[0].text,"元の字幕")
    }
    @MainActor func testDetachedPreviewRetainsDraftIfCommitIsBlocked()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-detached-draft-\(UUID())"),store=EditorStore(preferencesDirectory:root)
        defer{try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        let clip=Clip(kind:.text,name:"caption",track:0,start:0,duration:2,text:"元")
        store.project=Project();store.project.width=400;store.project.height=300;store.project.clips=[clip];store.selectedID=clip.id
        var editor:ObjectEditingView?=ObjectEditingView(frame:CGRect(x:0,y:0,width:400,height:300));editor?.store=store;editor?.beginTextEditing(clip)
        try XCTUnwrap(editor?.textInput).string="保持する"
        store.project.tracks[0].locked=true;ObjectEditingOverlay.dismantleNSView(try XCTUnwrap(editor),coordinator:());editor=nil
        XCTAssertEqual(store.previewTextEditor?.textInput?.string,"保持する")
        store.project.tracks[0].locked=false;XCTAssertTrue(store.finishPendingPreviewText());XCTAssertEqual(store.project.clips[0].text,"保持する");XCTAssertNil(store.previewTextEditor)
    }
    @MainActor func testTwoPreviewWindowsAndFailedSaveRetainChanges()async throws {
        let (store,first,window,clip,root)=try fixture();defer{window.close();try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:store.directory)}
        let second=ObjectEditingView(frame:first.frame);second.store=store
        first.beginTextEditing(clip);try XCTUnwrap(first.textInput).string="最初"
        second.beginTextEditing(clip);XCTAssertNil(first.textInput);XCTAssertEqual(store.project.clips[0].text,"最初")
        XCTAssertEqual(second.textInput?.string,"最初");try XCTUnwrap(second.textInput).string="次"
        let blocker=root.appendingPathComponent("not-a-directory");try Data().write(to:blocker)
        let invalid=blocker.appendingPathComponent("fail.vmm")
        let failed=await store.saveProject(to:invalid);XCTAssertFalse(failed);XCTAssertEqual(store.project.clips[0].text,"次");XCTAssertTrue(store.dirty)
        store.undo();XCTAssertEqual(store.project.clips[0].text,"最初");store.undo();XCTAssertEqual(store.project.clips[0].text,"元の字幕")
    }
    @MainActor func testPrecompositionApplyIncludesPendingDraft()async throws {
        let (owner,_,window,clip,root)=try fixture();defer{window.close();try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:owner.directory)}
        owner.selectedID=clip.id;_=try owner.createPrecomposition(name:"字幕コンポ")
        let composition=try XCTUnwrap(owner.project.precompositions?.first),session=try await PrecompositionSession(owner:owner,composition:composition,onClose:{})
        defer{session.window.close()}
        let draftClip=try XCTUnwrap(session.draft.project.clips.first),editor=ObjectEditingView(frame:CGRect(x:0,y:0,width:400,height:300));editor.store=session.draft;session.draft.selectedID=draftClip.id
        editor.beginTextEditing(draftClip);try XCTUnwrap(editor.textInput).string="コンポ内の修正"
        session.apply()
        for _ in 0..<100 where session.applying {try await Task.sleep(nanoseconds:20_000_000)}
        XCTAssertFalse(session.applying);XCTAssertNil(session.draft.error);XCTAssertEqual(owner.project.precompositions?.first?.clips.first?.text,"コンポ内の修正")
    }
}
