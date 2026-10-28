import AppKit
import SwiftUI

/// Exercises the packaged executable, its dynamic loader and a native window.
/// It never constructs the normal delegate, watches folders, accesses a
/// pasteboard, opens the library, changes preferences or starts networking.
@MainActor
final class AppLaunchCheck: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    static func run() {
        let app = NSApplication.shared
        let delegate = AppLaunchCheck()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Shelf launch verification"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Text("Shelf launch verification")
            .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity))
        self.window = window
        window.orderFront(nil)
        DispatchQueue.main.async {
            guard window.isVisible, window.contentView?.window === window else { exit(1) }
            print("SHELF_LAUNCH_OK")
            window.close()
            NSApp.terminate(nil)
        }
    }
}
