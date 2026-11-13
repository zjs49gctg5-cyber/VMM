import AppKit
import Combine

/// Keep the document name, file proxy, and native unsaved indicator in the title bar.
@MainActor final class ProjectWindowTitleController {
    private var observer:AnyCancellable?
    init(window:NSWindow,store:EditorStore){
        observer=Publishers.CombineLatest3(store.$project.map(\.name).removeDuplicates(),
                                          store.$dirty.removeDuplicates(),store.$savedURL.removeDuplicates())
            .sink{[weak window] name,dirty,url in
                window?.title="\(name) — VMM"
                window?.representedURL=url
                window?.isDocumentEdited=dirty
            }
    }
}
