import XCTest
import SwiftUI
import AppKit
@testable import VMM

final class APILockRegressionTests:XCTestCase {
    @MainActor func testAPIAddMustProtectPatchedDestinationLock()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vmm-review-api-\(UUID())"),s=EditorStore(preferencesDirectory:root)
        defer{try? FileManager.default.removeItem(at:s.directory);try? FileManager.default.removeItem(at:root)}
        s.autoSpeech=false;s.project=Project();s.project.tracks[1].locked=true
        let api=EditorCommands();api.store=s
        let result=api.execute(body:try JSONSerialization.data(withJSONObject:["command":"clip.add","kind":"shape","track":0,"properties":["track":1]]))
        XCTAssertGreaterThanOrEqual(result.status,400,"The final destination is locked, even though the initial track is unlocked.")
        XCTAssertTrue(s.project.clips.isEmpty)
    }
}
