import AppKit
import SlideSenseCore

// Diagnostic mode: stream raw trackpad contacts to stdout.
if CommandLine.arguments.contains("--dump-touches") {
    TrackpadDiagnostics.dump()
    exit(0)
}

if CommandLine.arguments.contains("--diagnose") {
    Diagnostics.printReport()
    exit(0)
}

// Development aid: cycle the HUD on screen (`--demo-hud`).
if CommandLine.arguments.contains("--demo-hud") {
    let demoApp = NSApplication.shared
    demoApp.setActivationPolicy(.accessory)
    let defaults = UserDefaults(suiteName: "io.github.slidesense.demo") ?? .standard
    let store = SettingsStore(defaults: defaults)
    let hud = HUDController(store: store)
    hud.show(edge: .volume, level: 0.64, muted: false)
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
        hud.show(edge: .brightness, level: 0.86, muted: false)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
        hud.dismiss()
        exit(0)
    }
    demoApp.run()
}

// Development aids for the update path.
if CommandLine.arguments.contains("--update-check") || CommandLine.arguments.contains("--update-install") {
    let install = CommandLine.arguments.contains("--update-install")
    let done = DispatchSemaphore(value: 0)

    Task {
        do {
            guard let release = try await UpdateController.shared.checkForUpdate() else {
                print("up to date (version \(UpdateController.shared.currentVersion))")
                done.signal()
                return
            }
            print("available: \(release.version) -> \(release.downloadURL.absoluteString)")
            if install {
                let app = try await UpdateController.shared.download(release)
                try UpdateController.shared.install(app)
                print("installed: \(app.lastPathComponent) — quitting to finish the swap")
            }
        } catch {
            print("failed: \(error.localizedDescription)")
        }
        done.signal()
    }

    done.wait()
    if install {
        exit(0)
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
