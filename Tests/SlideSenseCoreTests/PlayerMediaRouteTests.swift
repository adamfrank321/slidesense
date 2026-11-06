import CoreGraphics
import XCTest
@testable import SlideSenseCore

final class PlayerMediaRouteTests: XCTestCase {
    func testVLCUsesDistinctSeekAndPlaylistShortcuts() {
        XCTAssertEqual(PlayerMediaRoute.resolve(bundleID: "org.videolan.vlc", name: nil, command: .seekForward),
                       .shortcut(124, [.maskCommand, .maskAlternate]))
        XCTAssertEqual(PlayerMediaRoute.resolve(bundleID: "org.videolan.vlc", name: nil, command: .seekBackward),
                       .shortcut(123, [.maskCommand, .maskAlternate]))
        XCTAssertEqual(PlayerMediaRoute.resolve(bundleID: "org.videolan.vlc", name: nil, command: .next),
                       .shortcut(124, .maskCommand))
        XCTAssertEqual(PlayerMediaRoute.resolve(bundleID: "org.videolan.vlc", name: nil, command: .previous),
                       .shortcut(123, .maskCommand))
    }

    func testSMPlayerUsesArrowsAndPlaylistKeys() {
        XCTAssertEqual(PlayerMediaRoute.resolve(bundleID: nil, name: "SMPlayer", command: .seekForward), .shortcut(124, []))
        XCTAssertEqual(PlayerMediaRoute.resolve(bundleID: nil, name: "SMPlayer", command: .seekBackward), .shortcut(123, []))
        XCTAssertEqual(PlayerMediaRoute.resolve(bundleID: nil, name: "SMPlayer", command: .next), .shortcut(47, .maskShift))
        XCTAssertEqual(PlayerMediaRoute.resolve(bundleID: nil, name: "SMPlayer", command: .previous), .shortcut(43, .maskShift))
    }

    func testQuickTimeSeeksWithoutPretendingToHaveAPlaylist() {
        let id = "com.apple.QuickTimePlayerX"
        XCTAssertEqual(PlayerMediaRoute.resolve(bundleID: id, name: nil, command: .seekForward), .quickTimeSeek(5))
        XCTAssertEqual(PlayerMediaRoute.resolve(bundleID: id, name: nil, command: .seekBackward), .quickTimeSeek(-5))
        XCTAssertEqual(PlayerMediaRoute.resolve(bundleID: id, name: nil, command: .next), .unsupported)
        XCTAssertEqual(PlayerMediaRoute.resolve(bundleID: id, name: nil, command: .previous), .unsupported)
        XCTAssertEqual(PlayerMediaRoute.resolve(bundleID: id, name: nil, command: .playPause), .shortcut(49, []))
    }

    func testUnknownAppsAndSystemControlsDoNotReceivePlayerShortcuts() {
        XCTAssertNil(PlayerMediaRoute.resolve(bundleID: "com.apple.finder", name: "Finder", command: .seekForward))
        XCTAssertNil(PlayerMediaRoute.resolve(bundleID: "org.videolan.vlc", name: "VLC", command: .volumeUp))
        XCTAssertNil(PlayerMediaRoute.resolve(bundleID: nil, name: nil, command: .next))
    }

    func testSeekFramesAreThrottledAndDirectionReleaseAndTargetResetImmediately() {
        var throttle = PlayerSeekThrottle()
        XCTAssertTrue(throttle.shouldSend(target: 1, command: .seekForward, now: 0))
        XCTAssertFalse(throttle.shouldSend(target: 1, command: .seekForward, now: 0.01))
        XCTAssertFalse(throttle.shouldSend(target: 1, command: .seekForward, now: 0.49))
        XCTAssertTrue(throttle.shouldSend(target: 1, command: .seekForward, now: 0.5))
        XCTAssertTrue(throttle.shouldSend(target: 1, command: .seekBackward, now: 0.51))
        XCTAssertTrue(throttle.shouldSend(target: 2, command: .seekBackward, now: 0.52))
        throttle.reset()
        XCTAssertTrue(throttle.shouldSend(target: 2, command: .seekBackward, now: 0.53))
    }
}
