import XCTest
import AppKit
@testable import VMM

final class ShortcutValidationTests:XCTestCase {
    func testShortcutInputMatchesDispatchOrdering() {
        XCTAssertEqual(ShortcutMap.canonical(" SHIFT + cmd + S "),"cmd+shift+s")
        XCTAssertEqual(ShortcutMap.canonical("Ctrl+Alt+Left"),"ctrl+alt+left")
        XCTAssertEqual(ShortcutMap.canonical(" "),"")
        XCTAssertEqual(ShortcutMap.canonical("space"),"space")
        for invalid in ["cmd+", "cmd+cmd+a", "foo", "ctrl+alt", "a+b", "shift++", "cmd+return"] {
            XCTAssertNil(ShortcutMap.canonical(invalid),invalid)
        }
    }
    func testConflictsIncludePresetsAndCustomOverrides() {
        var settings=UserSettings()
        XCTAssertEqual(ShortcutMap.conflicts(for:.select,key:"b",settings:settings),[.blade])
        settings.shortcuts="Premiere風"
        XCTAssertEqual(ShortcutMap.conflicts(for:.select,key:"c",settings:settings),[.blade])
        XCTAssertTrue(ShortcutMap.conflicts(for:.select,key:"b",settings:settings).isEmpty)
        settings.customShortcuts[ShortcutAction.blade.rawValue]="SHIFT+CMD+S"
        XCTAssertEqual(ShortcutMap.conflicts(for:.select,key:"cmd+shift+s",settings:settings),[.blade])
        XCTAssertTrue(ShortcutMap.conflicts(for:.blade,key:"cmd+shift+s",settings:settings).isEmpty)
        XCTAssertTrue(ShortcutMap.conflicts(for:.select,key:"",settings:settings).isEmpty)
    }
}
