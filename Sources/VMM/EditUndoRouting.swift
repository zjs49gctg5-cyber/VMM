import AppKit

/// Field editors own their history even when it is empty; never fall through to the timeline.
@MainActor enum EditUndoRouting {
    static func perform(redo: Bool, responder: NSResponder?, project: () -> Void) {
        if let text = responder as? NSTextView {
            if redo { text.undoManager?.redo() } else { text.undoManager?.undo() }
        } else { project() }
    }
}
