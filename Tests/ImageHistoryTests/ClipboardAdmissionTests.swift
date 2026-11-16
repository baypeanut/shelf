import AppKit
#if !STANDALONE_TESTS
import XCTest
@testable import Shelf
#endif

@MainActor private final class AdmissionClipboard: ClipboardSource {
    var count = 790000
    var values = [[NSPasteboard.PasteboardType: Data]]()
    var reads = 0
    var duringRead: (() -> Void)?
    var changeCount: Int { count }
    var itemTypes: [[NSPasteboard.PasteboardType]] { values.map { Array($0.keys) } }
    func data(forType type: NSPasteboard.PasteboardType, at index: Int) -> Data? {
        reads += 1; let value = values[index][type]; duringRead?(); return value
    }
    func copy(_ values: [[NSPasteboard.PasteboardType: Data]]) { count += 1; self.values = values }
}

@MainActor final class ClipboardAdmissionTests: HistoryTestCase {
    func testFreshPreferencesRequireSeparateClipboardLinkAndMetadataOptIns() {
        let suite = "synthetic-privacy-defaults-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(LinkHistory.captureEnabled(in: defaults))
        XCTAssertFalse(LinkMetadataService.metadataEnabled(in: defaults))
        defaults.set(true, forKey: "linkClipboardEnabled")
        XCTAssertTrue(LinkHistory.captureEnabled(in: defaults))
        XCTAssertFalse(LinkMetadataService.metadataEnabled(in: defaults))
        defaults.set(true, forKey: "linkMetadataEnabled")
        XCTAssertTrue(LinkMetadataService.metadataEnabled(in: defaults))
        defaults.set(false, forKey: "linkClipboardEnabled")
        XCTAssertFalse(LinkHistory.captureEnabled(in: defaults))
    }

    private struct Contract: Decodable {
        struct TextCase: Decodable { let name: String; let value: String; let capture: Bool }
        struct SourceCase: Decodable { let name: String; let declared: String?; let frontmost: String?; let ignored: [String]; let capture: Bool; let source: String? }
        let privateMarkers: [String]
        let sourceMarker: String
        let ownBundleIdentifier: String
        let sourceCases: [SourceCase]
        let textCases: [TextCase]
    }
    private func contract() throws -> Contract {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode(Contract.self, from: Data(contentsOf: root.appendingPathComponent("contracts/clipboard-admission.json")))
    }
    func testExternalMarkerContractRejectsEveryItemBeforeReadingTextLinksOrImages() throws {
        let oldOwn = ClipboardWatcher.ownChangeCount; defer { ClipboardWatcher.recordOwnCopy(changeCount: oldOwn) }
        XCTAssertEqual(Set(try contract().privateMarkers), Set(ClipboardWatcher.privateTypes.map(\.rawValue)))
        for marker in try contract().privateMarkers {
            for separate in [false, true] {
                let source = AdmissionClipboard(), folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                var text = [String](), links = [URL](), images = [URL]()
                let image = ClipboardWatcher(source: source, folder: folder, onImage: { images.append($0) })
                let watcher = TextClipboardWatcher(source: source, onText: { text.append($0) }, onLink: { links.append($0) }, capturesLinks: { true })
                defer { watcher.stop(); image.stop(); try? FileManager.default.removeItem(at: folder) }
                image.start(); watcher.start()
                let type = NSPasteboard.PasteboardType(marker)
                for payload in [[NSPasteboard.PasteboardType.string: Data("synthetic private text".utf8)], [.URL: Data("https://example.invalid/private".utf8)], [.png: Data([1,2,3])]] {
                    source.copy(separate ? [payload, [type: Data()]] : [payload.merging([type: Data()]) { _, new in new }])
                    let reads = source.reads
                    image.check(); watcher.check()
                    XCTAssertEqual(source.reads, reads, marker)
                }
                XCTAssertTrue(text.isEmpty && links.isEmpty && images.isEmpty, marker)
                XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), marker)
            }
        }
    }
    private func png() throws -> Data {
        let provider = try XCTUnwrap(CGDataProvider(data: Data([40, 160, 210, 255]) as CFData))
        let image = try XCTUnwrap(CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: 1), provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent))
        return try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    }
    /// Images, text and links reach the same decision for every contract row,
    /// and the callbacks see the source the contract names.
    func testSourceContractDecidesIgnoredAppsAndAttributionForImagesTextAndLinks() throws {
        let oldOwn = ClipboardWatcher.ownChangeCount; defer { ClipboardWatcher.recordOwnCopy(changeCount: oldOwn) }
        let contract = try contract(), image = try png()
        XCTAssertEqual(contract.sourceMarker, CaptureControl.sourceType.rawValue)
        XCTAssertFalse(contract.sourceCases.isEmpty)
        for row in contract.sourceCases {
            let suite = "synthetic-admission-\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let control = CaptureControl(defaults: defaults, frontmost: { row.frontmost.map { SourceApp(bundleID: $0, name: "Front") } },
                appName: { _ in "Declared" }, ownBundleID: contract.ownBundleIdentifier)
            row.ignored.forEach(control.ignore)
            XCTAssertEqual(control.ignoredBundleIDs, row.ignored, row.name)
            let source = AdmissionClipboard(), folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            var text = [SourceApp?](), links = [SourceApp?](), images = [SourceApp?]()
            var imageWatcher: ClipboardWatcher!, watcher: TextClipboardWatcher!
            imageWatcher = ClipboardWatcher(source: source, folder: folder, capture: control, onImage: { _ in images.append(imageWatcher.admittedSource) })
            watcher = TextClipboardWatcher(source: source, capture: control, onText: { _ in text.append(watcher.admittedSource) },
                onLink: { _ in links.append(watcher.admittedSource) }, capturesLinks: { true })
            defer { watcher.stop(); imageWatcher.stop(); try? FileManager.default.removeItem(at: folder) }
            imageWatcher.start(); watcher.start()
            let marker = row.declared.map { [CaptureControl.sourceType: Data($0.utf8)] } ?? [:]
            for payload in [[NSPasteboard.PasteboardType.string: Data("synthetic source text".utf8)], [.string: Data("https://example.com/source".utf8)], [.png: image]] {
                source.copy([payload.merging(marker) { _, new in new }])
                imageWatcher.check(); watcher.check()
            }
            let expected = row.capture ? [row.source] : []
            XCTAssertEqual(text.map { $0?.bundleID }, expected, row.name)
            XCTAssertEqual(links.map { $0?.bundleID }, expected, row.name)
            XCTAssertEqual(images.map { $0?.bundleID }, expected, row.name)
            XCTAssertNil(imageWatcher.admittedSource, row.name); XCTAssertNil(watcher.admittedSource, row.name)
            if row.source != nil, row.declared == row.source { XCTAssertEqual(text.first??.name, "Declared", row.name) }
            if row.source != nil, row.declared != row.source { XCTAssertEqual(text.first??.name, "Front", row.name) }
        }
    }
    func testPrivateCopyIsRejectedWithoutReadingItsSourceMarkerOrAskingForTheFrontmostApp() throws {
        let oldOwn = ClipboardWatcher.ownChangeCount; defer { ClipboardWatcher.recordOwnCopy(changeCount: oldOwn) }
        let suite = "synthetic-admission-\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var asked = 0
        let control = CaptureControl(defaults: defaults, frontmost: { asked += 1; return nil }, appName: { _ in nil }, ownBundleID: "com.baypeanut.Shelf")
        let source = AdmissionClipboard(); var received = [String]()
        let watcher = TextClipboardWatcher(source: source, capture: control, onText: { received.append($0) })
        defer { watcher.stop() }; watcher.start()
        source.copy([[.string: Data("synthetic secret".utf8), CaptureControl.sourceType: Data("com.example.editor".utf8), NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"): Data()]])
        watcher.check()
        XCTAssertTrue(received.isEmpty); XCTAssertEqual(source.reads, 0); XCTAssertEqual(asked, 0)
    }
    func testSharedTextContractSkipsOnlyWhitespaceAndKeepsAcceptedBytesExact() throws {
        let source = AdmissionClipboard(); var received = [String]()
        let watcher = TextClipboardWatcher(source: source, onText: { received.append($0) })
        defer { watcher.stop() }; watcher.start()
        for row in try contract().textCases {
            let before = received.count
            source.copy([[.string: Data(row.value.utf8)]])
            watcher.check()
            XCTAssertEqual(received.count, before + (row.capture ? 1 : 0), row.name)
            if row.capture { XCTAssertEqual(Array(received.last!.utf8), Array(row.value.utf8), row.name) }
        }
    }
    func testPublicToPrivateReplacementDuringReadIsDiscardedAndFreshCopyCanFollow() {
        let source = AdmissionClipboard(); var received = [String]()
        let watcher = TextClipboardWatcher(source: source, onText: { received.append($0) })
        defer { watcher.stop() }; watcher.start()
        source.copy([[.string: Data("public synthetic".utf8)]])
        source.duringRead = { source.duringRead = nil; source.copy([[.string: Data("private synthetic".utf8), NSPasteboard.PasteboardType("com.agilebits.onepassword"): Data()]]) }
        watcher.check(); watcher.check()
        XCTAssertTrue(received.isEmpty)
        source.copy([[.string: Data("fresh synthetic".utf8)]]); watcher.check()
        XCTAssertEqual(received, ["fresh synthetic"])
    }
}
