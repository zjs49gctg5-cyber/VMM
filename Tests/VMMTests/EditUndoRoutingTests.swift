import XCTest
import AppKit
@testable import VMM

@MainActor private final class UndoTextView:NSTextView {
    let history=UndoManager()
    override var undoManager:UndoManager? {history}
}

final class EditUndoRoutingTests:XCTestCase {
    @MainActor func testTextHistoryNeverFallsThroughToProject() {
        let text=UndoTextView();text.allowsUndo=true
        var projectEdits=0
        EditUndoRouting.perform(redo:false,responder:text){projectEdits+=1}
        XCTAssertEqual(projectEdits,0)
        text.insertText("abc",replacementRange:NSRange(location:0,length:0))
        EditUndoRouting.perform(redo:false,responder:text){projectEdits+=1}
        XCTAssertEqual(text.string,"")
        EditUndoRouting.perform(redo:true,responder:text){projectEdits+=1}
        XCTAssertEqual(text.string,"abc");XCTAssertEqual(projectEdits,0)
        EditUndoRouting.perform(redo:false,responder:NSResponder()){projectEdits+=1}
        XCTAssertEqual(projectEdits,1)
    }
}
