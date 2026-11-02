import XCTest
@testable import SlideSenseCore

final class UpdateVersionTests: XCTestCase {
    func testNumericComparison() {
        XCTAssertTrue(UpdateVersion.isNewer("0.1.10", than: "0.1.9"))
        XCTAssertTrue(UpdateVersion.isNewer("0.2", than: "0.1.9"))
        XCTAssertTrue(UpdateVersion.isNewer("1.0", than: "0.99.9"))
        XCTAssertFalse(UpdateVersion.isNewer("0.1.0", than: "0.1"))
        XCTAssertFalse(UpdateVersion.isNewer("0.1.2", than: "0.1.2"))
        XCTAssertFalse(UpdateVersion.isNewer("0.1.1", than: "0.1.2"))
    }

    func testLeadingVAndSuffixes() {
        XCTAssertEqual(UpdateVersion.compare("v0.1.2", "0.1.2"), .orderedSame)
        XCTAssertEqual(UpdateVersion.compare("0.1.2-beta.1", "0.1.2"), .orderedSame)
        XCTAssertEqual(UpdateVersion.compare("0.1.3", "v0.1.2"), .orderedDescending)
    }

    func testMissingComponentsAreZero() {
        XCTAssertEqual(UpdateVersion.compare("1", "1.0.0"), .orderedSame)
        XCTAssertEqual(UpdateVersion.compare("1.0.1", "1"), .orderedDescending)
    }

    func testSettingsDecodeDefaultsForOlderFiles() throws {
        let json = #"{"edgeWidth": 0.2}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        XCTAssertTrue(settings.automaticallyChecksForUpdates)
    }
}
