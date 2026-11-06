import CoreGraphics
import Foundation

/// Explicit foreground-player bindings. Unknown apps retain system media keys.
enum PlayerMediaRoute: Equatable {
    case shortcut(CGKeyCode, CGEventFlags)
    case quickTimeSeek(Int)
    case unsupported

    static func resolve(bundleID: String?, name: String?, command: MediaKeyController.Command) -> Self? {
        let isVLC = bundleID == "org.videolan.vlc"
        // SMPlayer distributions use different bundle identifiers.
        let isSMPlayer = name?.lowercased() == "smplayer"
        let isQuickTime = bundleID == "com.apple.QuickTimePlayerX"
        guard isVLC || isSMPlayer || isQuickTime else { return nil }
        switch command {
        case .playPause: return .shortcut(49, []) // Space
        case .next, .previous:
            let forward = command == .next
            if isQuickTime { return .unsupported } // No track playlist.
            if isVLC { return .shortcut(forward ? 124 : 123, .maskCommand) }
            return .shortcut(forward ? 47 : 43, .maskShift) // > / <
        case .seekForward, .seekBackward:
            let forward = command == .seekForward
            if isQuickTime { return .quickTimeSeek(forward ? 5 : -5) }
            return .shortcut(forward ? 124 : 123,
                             isVLC ? [.maskCommand, .maskAlternate] : [])
        default: return nil
        }
    }
}

/// Touch frames renew seeking at device frequency; player commands run at 2 Hz.
struct PlayerSeekThrottle {
    private var target: Int32?
    private var command: MediaKeyController.Command?
    private var lastSent: TimeInterval = -.infinity

    mutating func shouldSend(target: Int32, command: MediaKeyController.Command, now: TimeInterval) -> Bool {
        if self.target != target || self.command != command || now - lastSent >= 0.5 {
            self.target = target
            self.command = command
            lastSent = now
            return true
        }
        return false
    }

    mutating func reset() { self = Self() }
}
