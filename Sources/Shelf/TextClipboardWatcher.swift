import AppKit
import UniformTypeIdentifiers

@MainActor
final class TextClipboardWatcher {
    static let maximumDataBytes = 1024 * 1024
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "textClipboardEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "textClipboardEnabled") }
    }
    private let source: any ClipboardSource
    private let onText: (String) -> Void
    private let onLink: ((URL) -> Void)?
    private let capturesText: () -> Bool
    private let capturesLinks: () -> Bool
    private let capture: (any ClipboardAdmission)?
    private var timer: Timer?
    private var lastCount: Int?
    private var wasPaused = false
    /// The source of the text or link being delivered. Only meaningful inside the callbacks.
    private(set) var admittedSource: SourceApp?

    convenience init(capture: (any ClipboardAdmission)? = nil, onText: @escaping (String) -> Void, onLink: ((URL) -> Void)? = nil,
                     capturesText: @escaping () -> Bool = { true }, capturesLinks: @escaping () -> Bool = { false }) {
        self.init(source: SystemClipboardSource(), capture: capture, onText: onText, onLink: onLink, capturesText: capturesText, capturesLinks: capturesLinks)
    }
    init(source: any ClipboardSource, capture: (any ClipboardAdmission)? = nil, onText: @escaping (String) -> Void, onLink: ((URL) -> Void)? = nil,
         capturesText: @escaping () -> Bool = { true }, capturesLinks: @escaping () -> Bool = { false }) {
        self.source = source; self.capture = capture; self.onText = onText; self.onLink = onLink; self.capturesText = capturesText; self.capturesLinks = capturesLinks
    }
    /// Enabling a source starts with the next copy, never the existing board.
    func skipCurrent() { lastCount = source.changeCount; wasPaused = false }
    func start() {
        guard timer == nil else { return }
        lastCount = source.changeCount
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
    func stop() { timer?.invalidate(); timer = nil; lastCount = nil; wasPaused = false }
    func check() {
        guard timer != nil else { return }
        guard capturesText() || capturesLinks() else { return }
        guard let count = ClipboardWatcher.changedCount(in: source, capture: capture, lastCount: &lastCount, wasPaused: &wasPaused),
              let admission = ClipboardWatcher.admission(of: count, in: source, capture: capture) else { return }
        let items = admission.items
        guard !items.contains(where: { types in
            types.contains(where: { UTType($0.rawValue)?.conforms(to: .image) == true })
        }), source.changeCount == count else { return }
        admittedSource = admission.source
        defer { admittedSource = nil }
        for (index, types) in items.enumerated() where types.contains(.string) || (capturesLinks() && types.contains(.URL)) {
            guard source.changeCount == count else { return }
            let data = source.data(forType: types.contains(.string) ? .string : .URL, at: index)
            guard source.changeCount == count else { return }
            guard let data,
                  !data.isEmpty, data.count <= Self.maximumDataBytes,
                  String(data: data, encoding: .utf8) != nil else { continue }
            // Decode the validated UTF-8 literally; Foundation's encoding initializer
            // consumes a leading BOM, which changes an otherwise valid copy.
            let text = String(decoding: data, as: UTF8.self)
            guard text.unicodeScalars.contains(where: { !$0.properties.isWhitespace }) else { continue }
            guard source.changeCount == count else { return }
            if capturesLinks(), let onLink, let url = LinkIdentity.standalone(text) {
                // A sign-in link, a presigned download or a link with a password
                // is kept neither as a link nor as text.
                if !LinkSensitivity.carriesCredentials(url) { onLink(url) }
            }
            else if capturesText() { onText(text) }
            return
        }
    }
}
