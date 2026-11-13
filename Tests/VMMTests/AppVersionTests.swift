import XCTest
@testable import VMM

final class AppVersionTests:XCTestCase {
    func testBundleMetadataAndMissingValues() {
        let beta=AppVersion(info:["CFBundleShortVersionString":"0.1.0","CFBundleVersion":"1","VMMReleaseChannel":"beta"])
        XCTAssertEqual(beta.display,"0.1.0 β")
        XCTAssertEqual(beta.protocolVersion,"0.1.0-beta+build.1")
        XCTAssertTrue(beta.fullDisplay.contains("1"))
        let stable=AppVersion(info:["CFBundleShortVersionString":"1.2.3","CFBundleVersion":"  "])
        XCTAssertEqual(stable.fullDisplay,"1.2.3")
        XCTAssertEqual(AppVersion(info:nil).display,L("開発版"))
        XCTAssertEqual(AppVersion(info:nil).protocolVersion,"0.0.0-dev")
    }
}
