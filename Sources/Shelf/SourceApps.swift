import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Workspace lookups for source applications: names, icons and the choices
/// offered for the ignored list. Tests inject their own providers instead.
@MainActor
enum SourceApps {
    static func frontmost() -> SourceApp? {
        guard let app = NSWorkspace.shared.frontmostApplication, let bundleID = app.bundleIdentifier else { return nil }
        return SourceApp(bundleID: bundleID, name: app.localizedName ?? bundleID)
    }

    /// A running application answers from memory; otherwise Launch Services
    /// resolves the installed copy.
    static func name(forBundleID bundleID: String) -> String? {
        if let name = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName { return name }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return name(ofApplicationAt: url)
    }

    private static func name(ofApplicationAt url: URL) -> String {
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// Applications with a Dock presence, for the "currently running" menu.
    static func running() -> [SourceApp] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications.compactMap { app -> SourceApp? in
            guard app.activationPolicy == .regular, let bundleID = app.bundleIdentifier,
                  bundleID != Bundle.main.bundleIdentifier, seen.insert(bundleID).inserted else { return nil }
            return SourceApp(bundleID: bundleID, name: app.localizedName ?? bundleID)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Only the chosen bundle's identifier is read.
    static func choose() -> SourceApp? {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.application]
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.prompt = L("Ignore")
        panel.message = L("Copies made in this app will not be captured.")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url, let bundleID = Bundle(url: url)?.bundleIdentifier,
              CaptureControl.isBundleID(bundleID) else { return nil }
        return SourceApp(bundleID: bundleID, name: name(ofApplicationAt: url))
    }

    private static let icons = NSCache<NSString, NSImage>()
    private static let iconQueue = DispatchQueue(label: "com.baypeanut.Shelf.source-icons", qos: .utility)

    /// Icons are read from disk off the main thread, once per application.
    static func icon(forBundleID bundleID: String, completion: @escaping (NSImage?) -> Void) {
        if let cached = icons.object(forKey: bundleID as NSString) { completion(cached); return }
        iconQueue.async {
            let image = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
            DispatchQueue.main.async {
                if let image { icons.setObject(image, forKey: bundleID as NSString) }
                completion(image)
            }
        }
    }
}

/// A small application icon that appears once it has been resolved.
struct SourceAppIcon: View {
    let bundleID: String
    var size: CGFloat = 16
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable() } else { Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary) }
        }
        .frame(width: size, height: size).accessibilityHidden(true)
        .task(id: bundleID) {
            let resolved: NSImage? = await withCheckedContinuation { continuation in
                SourceApps.icon(forBundleID: bundleID) { continuation.resume(returning: $0) }
            }
            if !Task.isCancelled { image = resolved }
        }
    }
}
