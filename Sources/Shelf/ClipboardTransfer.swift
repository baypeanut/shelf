import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Build the entire transfer before replacing a pasteboard. Tests use a named
/// pasteboard; constructing these objects never reads the system clipboard.
@MainActor enum ClipboardTransfer {
    enum Failure: Error, LocalizedError {
        case unreadableImage, tooLarge
        var errorDescription: String? { self == .tooLarge ? L("This selection is too large to copy; select fewer items") : L("Selected files could not be read; nothing was copied") }
    }
    static func imageItems(_ urls: [URL]) throws -> [NSPasteboardItem] {
        var total = 0
        return try imageItems(urls, total: &total)
    }
    /// The original bytes go on the pasteboard under their own type at once.
    /// PNG, when it is not the original format, is made only if a receiver
    /// asks for it. `total` counts the bytes written across calls.
    static func imageItems(_ urls: [URL], total: inout Int) throws -> [NSPasteboardItem] {
        try urls.map { url in
            guard HistoryFiles(inbox: url.deletingLastPathComponent()).isRegularFile(url),
                  let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  (isRecordingFile(url) || size <= ClipboardWatcher.maximumDataBytes) else { throw Failure.unreadableImage }
            if isRecordingFile(url) {
                let item = NSPasteboardItem()
                item.setString(url.absoluteString, forType: .fileURL)
                return item
            }
            guard let data = try? Data(contentsOf: url), let image = CopiedImage(data) else { throw Failure.unreadableImage }
            total += data.count
            guard total <= 128 * 1024 * 1024 else { throw Failure.tooLarge }
            let item = NSPasteboardItem()
            item.setData(data, forType: NSPasteboard.PasteboardType(image.type))
            if image.type != UTType.png.identifier, image.mayConvert { item.setDataProvider(LazyPNG(image), forTypes: [.png]) }
            item.setString(url.absoluteString, forType: .fileURL)
            return item
        }
    }
    /// PNG bytes for a copy: the original bytes when they are PNG, otherwise a
    /// conversion within the capture pixel limit.
    nonisolated static func pngData(_ url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url), let image = CopiedImage(data) else { return nil }
        return image.type == UTType.png.identifier ? data : image.png()
    }
    static func textItems(_ values: [String]) -> [NSPasteboardItem] {
        guard !values.isEmpty else { return [] }
        // Most text editors request only the first plain-text representation.
        // It therefore contains every selected entry in shelf order.
        let item = NSPasteboardItem()
        item.setString(values.joined(separator: "\n\n"), forType: .string)
        return [item]
    }
    static func linkItems(_ urls: [String]) -> [NSPasteboardItem] {
        guard !urls.isEmpty else { return [] }
        let item = NSPasteboardItem()
        item.setString(urls.joined(separator: "\n\n"), forType: .string)
        if urls.count == 1 { item.setString(urls[0], forType: .URL) }
        return [item]
    }
    @MainActor @discardableResult
    static func write(_ items: [NSPasteboardItem], to pasteboard: NSPasteboard = .general) -> Bool {
        guard !items.isEmpty else { return false }
        pasteboard.clearContents()
        let success = pasteboard.writeObjects(items)
        if success, pasteboard.name == NSPasteboard.general.name {
            ClipboardWatcher.recordOwnCopy(changeCount: pasteboard.changeCount)
        }
        return success
    }
}

/// An image read from its header only. The format comes from the bytes, not
/// the file name, and nothing is decoded until PNG is requested.
struct CopiedImage: Sendable {
    let data: Data, type: String, width: Int, height: Int
    /// Larger images are still copied in their own format, but never decoded.
    var mayConvert: Bool { width <= ClipboardWatcher.maximumPixelCount * 4 / height }
    init?(_ data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?, CGImageSourceGetCount(source) > 0,
              UTType(type)?.conforms(to: .image) == true,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return nil }
        self.data = data; self.type = type; self.width = width; self.height = height
    }
    /// PNG with the EXIF orientation applied, scaled down to the capture pixel
    /// limit when the original is larger.
    func png() -> Data? {
        guard mayConvert, let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let pixels = Double(width) * Double(height), budget = Double(ClipboardWatcher.maximumPixelCount)
        let side = pixels <= budget ? max(width, height) : Int((Double(max(width, height)) * (budget / pixels).squareRoot()).rounded(.down))
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: max(side, 1), kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(result, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? result as Data : nil
    }
}

/// Supplies PNG for one pasteboard item when a receiver asks for it. The item
/// keeps this provider, and the provider keeps the copied bytes, so the result
/// matches the copy even if the file changes later.
final class LazyPNG: NSObject, NSPasteboardItemDataProvider {
    private let image: CopiedImage
    init(_ image: CopiedImage) { self.image = image }
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .png, let png = image.png() else { return }
        item.setData(png, forType: .png)
    }
}

struct ShelfDragItem {
    let id: UUID
    let sourceURL: URL
    let writer: NSPasteboardWriting
    let image: NSImage?
}
