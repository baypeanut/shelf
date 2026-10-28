import AppKit
#if !STANDALONE_TESTS
import XCTest
@testable import Shelf
#endif

@MainActor final class PreviewWindowTests: HistoryTestCase {
    private func assertChrome(_ window: NSWindow) throws {
        for mask in [NSWindow.StyleMask.titled, .closable, .miniaturizable, .resizable] {
            XCTAssertTrue(window.styleMask.contains(mask))
        }
        let close = try XCTUnwrap(window.standardWindowButton(.closeButton))
        let minimize = try XCTUnwrap(window.standardWindowButton(.miniaturizeButton))
        XCTAssertTrue(close.isEnabled); XCTAssertTrue(minimize.isEnabled)
        let frameView = try XCTUnwrap(window.contentView?.superview)
        let closeFrame = close.convert(close.bounds, to: frameView)
        let minimizeFrame = minimize.convert(minimize.bounds, to: frameView)
        XCTAssertTrue(closeFrame.minX < minimizeFrame.minX)
        XCTAssertTrue(closeFrame.minX < window.frame.width / 2)
    }
    private func edit(_ preview: TextPreview) {
        preview.beginEditing(); preview.textView.string = "Unsaved synthetic draft İstanbul 👋"
        preview.textDidChange(Notification(name: NSText.didChangeNotification))
    }
    func testNativeTrafficLightsCloseTextAndReusedImagePreview() throws {
        _ = NSApplication.shared
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let text = TextPreview(text: "Synthetic text"); defer { text.window.close() }
        try assertChrome(text.window)
        let panel = try XCTUnwrap(text.window as? ActionPreviewPanel)
        let image = try XCTUnwrap(ImagePreview(url: f.image(), window: panel))
        defer { image.window.close() }
        try assertChrome(image.window); XCTAssertTrue(image.window === panel)
        var closed = 0; image.onClose = { closed += 1 }
        image.show()
        try XCTUnwrap(image.window.standardWindowButton(.closeButton)).performClick(nil)
        XCTAssertFalse(image.window.isVisible); XCTAssertEqual(closed, 1)
    }
    func testNativeCloseSavesTextDraftExactlyOnce() throws {
        _ = NSApplication.shared
        let preview = TextPreview(text: "Saved text"); defer { preview.window.close() }
        var saves = [String](); preview.onSave = { saves.append($0); return true }
        var prompts = 0; preview.closeRecovery.present = { _, _ in prompts += 1 }
        preview.show(); edit(preview)
        try XCTUnwrap(preview.window.standardWindowButton(.closeButton)).performClick(nil)
        XCTAssertFalse(preview.window.isVisible)
        XCTAssertEqual(saves, ["Unsaved synthetic draft İstanbul 👋"]); XCTAssertEqual(prompts, 0)
    }
    func testFailedCloseOffersOneRecoveryChoiceAndCancelKeepsDraft() throws {
        _ = NSApplication.shared
        let preview = TextPreview(text: "Saved text"); defer { preview.window.close() }
        preview.onSave = { _ in false }; preview.show(); edit(preview)
        var prompts = 0; var answer: ((PreviewCloseRecovery.Choice) -> Void)?
        preview.closeRecovery.present = { _, completion in prompts += 1; answer = completion }
        preview.requestClose(); preview.requestClose()
        XCTAssertEqual(prompts, 1); XCTAssertTrue(preview.window.isVisible)
        try XCTUnwrap(answer)(.cancel)
        XCTAssertFalse(preview.closeRecovery.isPresenting)
        XCTAssertTrue(preview.window.isVisible)
        XCTAssertEqual(preview.textView.string, "Unsaved synthetic draft İstanbul 👋")
        var saved = ""; preview.onSave = { saved = $0; return true }
        preview.requestClose(); XCTAssertFalse(preview.window.isVisible)
        XCTAssertEqual(saved, "Unsaved synthetic draft İstanbul 👋")
    }
    func testRetryAndDiscardBothLetUserCloseFailedTextSave() throws {
        _ = NSApplication.shared
        for choice in [PreviewCloseRecovery.Choice.retry, .discard] {
            let preview = TextPreview(text: "Saved text"); defer { preview.window.close() }
            var canSave = false, saved = [String]()
            preview.onSave = { if canSave { saved.append($0) }; return canSave }
            var answer: ((PreviewCloseRecovery.Choice) -> Void)?
            preview.closeRecovery.present = { _, completion in answer = completion }
            preview.show(); edit(preview); preview.requestClose()
            XCTAssertTrue(preview.window.isVisible)
            canSave = choice == .retry
            try XCTUnwrap(answer)(choice)
            XCTAssertFalse(preview.window.isVisible)
            XCTAssertEqual(saved.count, choice == .retry ? 1 : 0)
        }
    }
    func testImageSaveFailureCanBeDiscardedWithoutWritingDraft() throws {
        _ = NSApplication.shared
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let preview = try XCTUnwrap(ImagePreview(url: f.image())); defer { preview.window.close() }
        let saved = ImageMarkupDocument(elements: [.init(tool: .line, points: [.init(x: 0.1, y: 0.1), .init(x: 0.8, y: 0.8)])])
        preview.configureMarkup(document: saved, sourceURL: try f.image())
        preview.onSaveMarkup = { _ in false }; preview.show(); preview.beginMarkup()
        preview.canvas.clearMarkup(); XCTAssertTrue(preview.hasUnsavedMarkup)
        var answer: ((PreviewCloseRecovery.Choice) -> Void)?
        preview.closeRecovery.present = { _, completion in answer = completion }
        preview.requestClose(); XCTAssertTrue(preview.window.isVisible)
        XCTAssertTrue(preview.hasUnsavedMarkup)
        try XCTUnwrap(answer)(.discard)
        XCTAssertFalse(preview.window.isVisible); XCTAssertEqual(preview.document, saved)
    }
    func testFloatingDrawingAndToolbarAcceptFirstMouse() {
        _ = NSApplication.shared
        XCTAssertTrue(ImageMarkupCanvas().acceptsFirstMouse(for: nil))
        XCTAssertTrue(PreviewControls().pinButton.acceptsFirstMouse(for: nil))
        XCTAssertTrue(ImageMarkupToolbar().toolButtons[.pen]?.acceptsFirstMouse(for: nil) == true)
    }
    func testNativePanelDispatchesCropReturnFromImageCanvas() throws {
        _ = NSApplication.shared
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let preview = try XCTUnwrap(ImagePreview(url: f.image()))
        defer { preview.window.close() }
        var saves = 0; preview.onSaveMarkup = { _ in saves += 1; return true }
        preview.beginCrop()
        let canvas = preview.canvas, bounds = canvas.bounds
        for (type, x, y) in [(NSEvent.EventType.leftMouseDown, 0.2, 0.2), (.leftMouseDragged, 0.8, 0.8), (.leftMouseUp, 0.8, 0.8)] {
            let point = canvas.convert(NSPoint(x: bounds.width * x, y: bounds.height * y), to: nil)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: preview.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            if type == .leftMouseDown { canvas.mouseDown(with: event) }
            else if type == .leftMouseDragged { canvas.mouseDragged(with: event) }
            else { canvas.mouseUp(with: event) }
        }
        XCTAssertTrue(preview.window.makeFirstResponder(canvas))
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: preview.window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36))
        preview.window.sendEvent(enter)
        XCTAssertFalse(preview.isCropping); XCTAssertNotNil(preview.document.crop); XCTAssertEqual(saves, 1)
    }
    func testNativePanelDoesNotReadKeyCodesFromPointerOrApplicationEvents() throws {
        _ = NSApplication.shared
        let preview = TextPreview(text: "Synthetic text"); defer { preview.window.close() }
        XCTAssertTrue(preview.window.makeFirstResponder(preview.controls.pinButton))
        var keys = 0; preview.onKey = { _ in keys += 1; return true }
        let move = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: preview.window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        let application = try XCTUnwrap(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: preview.window.windowNumber, context: nil, subtype: 0, data1: 0, data2: 0))
        preview.window.sendEvent(move); preview.window.sendEvent(application)
        XCTAssertEqual(keys, 0)
    }
}
