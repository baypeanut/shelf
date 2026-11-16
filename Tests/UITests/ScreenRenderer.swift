import AppKit
import SwiftUI

/// Draws every screen of the synthetic harness into PNG files without showing
/// anything on a display, so the interface can be reviewed on a Mac whose
/// screen is locked or in use. Started by `scripts/render-screens.sh`.
///
/// Views draw themselves through `cacheDisplay(in:to:)`. Window-server
/// compositing is therefore missing: materials that blend with what is behind
/// the window come out flat, and window shadows are not drawn. Menus cannot be
/// drawn this way at all, so the menu bar menu is written as text.
@MainActor final class ScreenRenderer {
    /// The folder named after `--render-screens`, or nil in an ordinary run.
    static let outputFolder: URL? = {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--render-screens"), arguments.indices.contains(index + 1) else { return nil }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }()
    /// Fixtures of a render never share the folder of an interactive session.
    static let fixtureFolder = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-render-\(UUID().uuidString)")

    private let harness: HarnessDelegate
    private let root: URL
    private var folder: URL
    private var delegate: AppDelegate { harness.delegate }
    private var line: Line { harness.line }
    private var written = [String]()
    private var skipped = [String]()

    init(harness: HarnessDelegate, output: URL) {
        self.harness = harness
        root = output
        folder = output
    }

    func run() async {
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        await seedSources()
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            NSApp.appearance = NSAppearance(named: appearance)
            folder = root.appendingPathComponent("\(language)-\(appearance == .aqua ? "light" : "dark")", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            await settle()
            await renderShelves()
            await renderLibrary()
            await renderPreviews()
            await renderSettings()
            await renderPickers()
            renderAlerts()
            renderMenu()
        }
        let report = (["written:"] + written + ["", "not drawn:"] + skipped).joined(separator: "\n") + "\n"
        try? report.write(to: root.appendingPathComponent("render-\(language).txt"), atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    // MARK: Fixtures

    /// Items with a source application, an ignored application and items in
    /// Trash, which the ordinary harness seed does not have.
    private func seedSources() async {
        let notes = SourceApp(bundleID: "com.apple.Notes", name: "Notes")
        let browser = SourceApp(bundleID: "com.apple.Safari", name: "Safari")
        harness.f.date.addTimeInterval(60)
        _ = line.texts.add("Meeting notes for the synthetic review\nAgenda, owners and dates", source: notes)
        harness.f.date.addTimeInterval(1)
        _ = line.texts.add(
            "A long single paragraph that runs past the card so that truncation can be judged in every language.", source: browser)
        harness.f.date.addTimeInterval(1)
        _ = line.links.add(URL(string: "https://example.org/articles/native-interfaces")!, source: browser)
        delegate.capture.ignore("com.apple.keychainaccess")
        delegate.capture.ignore("com.example.synthetic-passwords")
        if let store = line.library {
            let doomed = line.texts.entries.suffix(3).map(\.id)
            try? store.trash(doomed)
        }
        await settle()
    }

    // MARK: Screens

    private func renderShelves() async {
        guard let panel = delegate.panel, let host = panel.contentView?.subviews.first else {
            skipped.append("shelves")
            return
        }
        line.setPresentation(.all, requestFocus: false)
        panel.contentHeight = line.panelHeight
        panel.setFrame(NSRect(x: 0, y: 0, width: 1280, height: line.panelHeight), display: false)
        line.setViewportWidth(1280)
        line.focusShelf(.images, requestFocus: false)
        if let first = line.items.first?.id { line.select(first) }
        await settle()
        write(host, "shelves", backdrop: true)
        line.focusShelf(.texts, requestFocus: false)
        if let first = line.texts.entries.first?.id { line.texts.select(first, width: 1280) }
        await settle()
        write(host, "shelves-text-active", backdrop: true)
        line.focusShelf(.links, requestFocus: false)
        line.beginShelfSearch()
        line.updateShelfSearch("synthetic", for: .links)
        await settle(1.0)
        write(host, "shelves-search", backdrop: true)
        _ = line.closeShelfSearch(requestFocus: false)
        line.focusShelf(.images, requestFocus: false)
        await settle()
        // The empty rows of a first run, from a library with nothing in it.
        if let empty = try? SyntheticFixture(
            folderRoot: ScreenRenderer.fixtureFolder, suiteName: "shelf-render-empty-\(UUID().uuidString)"),
            let store = try? LibraryStore(
                defaults: empty.defaults, inbox: empty.inbox, now: { empty.date }, moveToTrash: fixtureTrash(empty.folder))
        {
            let blank = Line(
                defaults: empty.defaults, inbox: empty.inbox, now: { empty.date }, breeze: false, moveToTrash: fixtureTrash(empty.folder),
                copyImage: { _ in }, copyText: { _ in }, library: store)
            blank.setPresentation(.all, requestFocus: false)
            let view = NSHostingView(rootView: LineView(line: blank))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1280, height: blank.panelHeight), styleMask: [.borderless], backing: .buffered,
                defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            await settle()
            write(view, "shelves-empty", backdrop: true)
            window.close()
            empty.cleanup()
        }
    }

    private func renderLibrary() async {
        delegate.showLibrary()
        guard let controller = delegate.libraryController, let window = controller.window else {
            skipped.append("library")
            return
        }
        let model = controller.model
        window.setFrame(NSRect(x: 0, y: 0, width: 1120, height: 760), display: true)
        model.listMode = false
        model.inspectorVisible = true
        model.changeScope(.recent)
        await settle(1.0)
        if let first = model.ids.first { model.select(first) }
        await settle()
        write(window, "library-grid")
        model.listMode = true
        await settle(1.0)
        write(window, "library-list")
        model.setSource("com.apple.Safari")
        await settle(1.0)
        write(window, "library-copied-from")
        model.clearFilters()
        model.changeScope(.trash)
        await settle(1.0)
        if let first = model.ids.first { model.select(first) }
        await settle()
        write(window, "library-trash")
        model.listMode = false
        model.changeScope(.tag(UUID()))
        await settle(1.0)
        write(window, "library-empty")
        model.changeScope(.saved)
        await settle(1.0)
        write(window, "library-saved")
        window.orderOut(nil)
    }

    private func renderPreviews() async {
        if let id = line.items.first(where: { !$0.isRecording })?.id {
            delegate.showPreview(id)
            await settle(0.8)
            write(delegate.previewWindow, "preview-image")
            delegate.preview?.beginMarkup()
            await settle(0.8)
            write(delegate.previewWindow, "preview-markup")
            delegate.preview?.beginCrop()
            await settle(0.8)
            write(delegate.previewWindow, "preview-crop")
            delegate.preview?.canvas.cancelCrop()
            _ = delegate.preview?.performMarkupCommand(.finishEditing)
            await settle()
        }
        if let id = line.texts.entries.first?.id {
            delegate.showTextPreview(id)
            await settle(0.8)
            write(delegate.previewWindow, "preview-text")
        }
        if let id = line.links.entries.last?.id {
            delegate.showLinkPreview(id)
            await settle(0.8)
            write(delegate.previewWindow, "preview-link")
        }
        delegate.previewWindow?.close()
        await settle()
    }

    private func renderSettings() async {
        delegate.showSettings()
        guard let controller = delegate.settingsController, let window = controller.window else {
            skipped.append("settings")
            return
        }
        for section in SettingsSection.allCases {
            controller.model.section = section
            await settle(0.6)
            write(window, "settings-\(section.rawValue)")
            // The grouped form scrolls. A second, taller pass shows what is below the fold.
            let frame = window.frame
            window.setFrame(NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: 1500), display: true)
            await settle(0.4)
            write(window, "settings-\(section.rawValue)-full")
            window.setFrame(frame, display: true)
        }
        let recorder = ShortcutRecorder(allowPlain: true)
        write(recorder.window, "shortcut-recorder")
        window.orderOut(nil)
    }

    private func renderPickers() async {
        delegate.showCommands(origin: .line)
        await settle(0.6)
        write(delegate.commandPalette?.window, "actions", backdrop: true)
        delegate.commandPalette?.updateQuery("pin")
        await settle()
        write(delegate.commandPalette?.window, "actions-filtered", backdrop: true)
        delegate.commandPalette?.window.close()
        await settle()
        let ids = Array(line.texts.entries.prefix(2).map(\.id))
        if !ids.isEmpty {
            delegate.showNameAndPin(ids)
            await settle(0.6)
            write(delegate.nameAndPinPicker?.window, "name-and-pin", backdrop: true)
            delegate.nameAndPinPicker?.window.close()
            await settle()
            line.onPinToFolderRequested?(ids)
            await settle(0.6)
            write(delegate.pinFolderPicker?.window, "pin-to-folder", backdrop: true)
            delegate.pinFolderPicker?.window.close()
            await settle()
            line.onTagRequested?(ids)
            await settle(0.6)
            write(delegate.tagPicker?.window, "tag-picker", backdrop: true)
            delegate.tagPicker?.window.close()
            await settle()
        }
    }

    private func renderAlerts() {
        for (name, alert) in [
            ("alert-empty-trash", AppDelegate.emptyTrashAlert(count: 12)),
            ("alert-clear-history", AppDelegate.clearHistoryAlert(count: 48)),
            ("alert-screenshots", AppDelegate.inboxOfferAlert()),
        ] {
            alert.layout()
            write(alert.window, name)
        }
    }

    /// Menus are drawn by the window server. Their wording, order, state and
    /// key equivalents are what a review needs, so those are written as text.
    private func renderMenu() {
        var lines = [String]()
        func describe(_ menu: NSMenu, indent: String) {
            for item in menu.items {
                if item.isSeparatorItem {
                    lines.append(indent + "────")
                    continue
                }
                var modifiers = ""
                if item.keyEquivalentModifierMask.contains(.control) { modifiers += "⌃" }
                if item.keyEquivalentModifierMask.contains(.option) { modifiers += "⌥" }
                if item.keyEquivalentModifierMask.contains(.shift) { modifiers += "⇧" }
                if item.keyEquivalentModifierMask.contains(.command) { modifiers += "⌘" }
                let key = item.keyEquivalent.isEmpty ? "" : "   [\(modifiers)\(item.keyEquivalent.uppercased())]"
                let state = item.state == .on ? "✓ " : "  "
                let flags = (item.isEnabled ? "" : "   (disabled)") + (item.image == nil ? "" : "   (image)")
                lines.append(indent + state + item.title + key + flags)
                if let submenu = item.submenu { describe(submenu, indent: indent + "      ") }
            }
        }
        let menu = NSMenu()
        delegate.menuNeedsUpdate(menu)
        lines.append("# Menu bar menu")
        describe(menu, indent: "")
        delegate.capture.pause(for: 3600)
        delegate.menuNeedsUpdate(menu)
        lines.append("")
        lines.append("# Menu bar menu while capture is paused")
        describe(menu, indent: "")
        if let image = delegate.statusItemImageForRendering { write(image: image, "status-item-paused") }
        delegate.capture.resume()
        if let image = delegate.statusItemImageForRendering { write(image: image, "status-item") }
        if let main = NSApp.mainMenu {
            lines.append("")
            lines.append("# Main menu")
            describe(main, indent: "")
        }
        try? (lines.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("menus.txt"), atomically: true, encoding: .utf8)
        written.append(folder.lastPathComponent + "/menus.txt")
    }

    // MARK: Drawing

    /// SwiftUI, Combine and the store's queues finish on later turns of the run loop.
    private func settle(_ seconds: TimeInterval = 0.35) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// A window with its title bar and toolbar: the frame view is drawn, not only the content.
    private func write(_ window: NSWindow?, _ name: String, backdrop: Bool = false) {
        guard let window, let view = window.contentView?.superview ?? window.contentView else {
            skipped.append(name)
            return
        }
        window.displayIfNeeded()
        write(view, name, backdrop: backdrop || !window.isOpaque)
    }

    private func write(_ view: NSView, _ name: String, backdrop: Bool = false) {
        view.layoutSubtreeIfNeeded()
        guard view.bounds.width > 0, view.bounds.height > 0, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            skipped.append(name)
            return
        }
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
        var output = bitmap
        // Transparent windows are placed on a plain desktop-like grey so their edges can be judged.
        if backdrop,
            let canvas = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: bitmap.pixelsWide, pixelsHigh: bitmap.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: canvas)
        {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            let area = NSRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
            (NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(white: 0.22, alpha: 1) : NSColor(white: 0.62, alpha: 1))
                .setFill()
            area.fill()
            bitmap.draw(in: area, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            output = canvas
        }
        save(output, name)
    }

    private func write(image: NSImage, _ name: String) {
        let size = NSSize(width: image.size.width * 4, height: image.size.height * 4)
        guard
            let canvas = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: canvas)
        else {
            skipped.append(name)
            return
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: size).fill()
            // A template image takes the menu bar's text colour.
            let tinted = NSImage(size: size, flipped: false) { rect in
                image.draw(in: rect)
                if image.isTemplate {
                    NSColor.labelColor.set()
                    rect.fill(using: .sourceAtop)
                }
                return true
            }
            tinted.draw(in: NSRect(origin: .zero, size: size))
        }
        NSGraphicsContext.restoreGraphicsState()
        save(canvas, name)
    }

    private func save(_ bitmap: NSBitmapImageRep, _ name: String) {
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            skipped.append(name)
            return
        }
        do {
            try data.write(to: folder.appendingPathComponent(name + ".png"))
            written.append(folder.lastPathComponent + "/" + name + ".png")
        } catch { skipped.append(name) }
    }
}
