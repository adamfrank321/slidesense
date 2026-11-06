import AppKit
import CoreGraphics
import Foundation

/// Routes foreground players directly, with system media keys as a fallback.
public final class MediaKeyController {
    public static let shared = MediaKeyController()

    public enum Command: Equatable {
        case playPause
        case next
        case previous
        case volumeUp
        case volumeDown
        case brightnessUp
        case brightnessDown
        case mute
        case seekForward
        case seekBackward
        case endSeek
    }

    // NX_KEYTYPE_* values from IOKit/hidsystem/ev_keymap.h.
    private enum Key: Int32 {
        case soundUp = 0
        case soundDown = 1
        case brightnessUp = 2
        case brightnessDown = 3
        case mute = 7
        case play = 16
        case next = 17
        case previous = 18
        case fast = 19
        case rewind = 20
    }

    private var heldSeekKey: Key?
    private var seekRelease: DispatchWorkItem?

    private var playerSeekThrottle = PlayerSeekThrottle()
    private var quickTimeProcess: Process?

    private init() {}

    public func send(_ command: Command) {
        if command == .endSeek {
            endSeek()
            return
        }
        if let app = NSWorkspace.shared.frontmostApplication,
           let route = PlayerMediaRoute.resolve(bundleID: app.bundleIdentifier,
                                                name: app.localizedName, command: command) {
            // Never send a second, global command as well: it may reach another player.
            if let key = heldSeekKey {
                post(key: key, down: false)
                heldSeekKey = nil
            }
            let seeking = command == .seekForward || command == .seekBackward
            if seeking {
                renewSeekTimeout()
                guard playerSeekThrottle.shouldSend(target: app.processIdentifier,
                                                     command: command,
                                                     now: ProcessInfo.processInfo.systemUptime) else { return }
            } else {
                endSeek()
            }
            switch route {
            case let .shortcut(key, flags):
                cancelQuickTimeSeek()
                postShortcut(key: key, flags: flags, pid: app.processIdentifier)
            case let .quickTimeSeek(seconds): seekQuickTime(seconds: seconds)
            case .unsupported: break
            }
            return
        }
        // A focus change must not leave a player-specific seek in progress.
        playerSeekThrottle.reset()
        cancelQuickTimeSeek()
        switch command {
        case .playPause: press(.play)
        case .next: press(.next)
        case .previous: press(.previous)
        case .volumeUp: press(.soundUp)
        case .volumeDown: press(.soundDown)
        case .brightnessUp: press(.brightnessUp)
        case .brightnessDown: press(.brightnessDown)
        case .mute: press(.mute)
        case .seekForward: holdSeek(.fast)
        case .seekBackward: holdSeek(.rewind)
        case .endSeek: endSeek()
        }
    }

    /// Call on the main queue. A missing release frame cannot leave a key down.
    private func holdSeek(_ key: Key) {
        if heldSeekKey != key {
            endSeek()
            heldSeekKey = key
            post(key: key, down: true)
        }
        renewSeekTimeout()
    }

    private func renewSeekTimeout() {
        seekRelease?.cancel()
        let release = DispatchWorkItem { [weak self] in self?.endSeek() }
        seekRelease = release
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: release)
    }

    public func endSeek() {
        playerSeekThrottle.reset()
        cancelQuickTimeSeek()
        seekRelease?.cancel()
        seekRelease = nil
        if let key = heldSeekKey { post(key: key, down: false) }
        heldSeekKey = nil
    }

    private func postShortcut(key: CGKeyCode, flags: CGEventFlags, pid: pid_t) {
        // Send directly to the selected process, not whichever app wins a focus race.
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
            event.flags = flags
            event.postToPid(pid)
        }
    }

    private func cancelQuickTimeSeek() {
        if let process = quickTimeProcess, process.isRunning { process.terminate() }
        // Keep the reference until termination; never overlap script processes.
    }

    private func seekQuickTime(seconds: Int) {
        guard quickTimeProcess == nil else { return }
        // Run out of process so an Automation permission prompt cannot block
        // the trackpad/main queue. No shell, user input, or looping script.
        let script = """
        with timeout of 2 seconds
            tell application id "com.apple.QuickTimePlayerX"
                if not frontmost then return
                if (count of documents) is 0 then return
                tell front document
                    set newTime to (current time) + \(seconds)
                    if newTime < 0 then set newTime to 0
                    if newTime > duration then set newTime to duration
                    set current time to newTime
                end tell
            end tell
        end timeout
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = FileHandle.nullDevice
        // Errors go to stderr (including denied Automation access).
        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                if self?.quickTimeProcess === finished { self?.quickTimeProcess = nil }
            }
        }
        quickTimeProcess = process
        do {
            try process.run()
        } catch {
            quickTimeProcess = nil
            NSLog("SlideSense: QuickTime seek failed: %@", error.localizedDescription)
        }
    }

    private func press(_ key: Key) {
        post(key: key, down: true)
        post(key: key, down: false)
    }

    private func post(key: Key, down: Bool) {
        let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
        let state: Int = down ? 0xA : 0xB
        let data1 = Int(key.rawValue << 16) | (state << 8)
        guard
            let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            ),
            let cgEvent = event.cgEvent
        else { return }
        cgEvent.post(tap: .cghidEventTap)
    }
}
