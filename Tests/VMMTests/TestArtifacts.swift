import Foundation

private let artifactRunID = UUID().uuidString

// Examples may be opened and edited by users. Never overwrite artifacts from earlier runs.
func testArtifactDirectory() -> String? {
    ProcessInfo.processInfo.environment["VMM_TEST_ARTIFACTS"].map {
        URL(fileURLWithPath: $0).appendingPathComponent("run-\(artifactRunID)").path
    }
}
