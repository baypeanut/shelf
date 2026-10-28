import AppKit

MainActor.assumeIsolated {
    if CommandLine.arguments.dropFirst().contains("--check-launch") {
        AppLaunchCheck.run()
    } else {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
