import AppKit

/// Pause, skip-next and per-app exclusion for clipboard capture, plus the
/// source application recorded with an admitted copy. Both clipboard watchers
/// consult the same instance, so one decision covers images, text and links.
///
/// Screenshots and watched folders are deliberately outside a pause: taking a
/// screenshot is an explicit act, and in inbox mode macOS saves it inside
/// Shelf's own folder, where an ignored file would be stranded out of sight.
@MainActor
final class CaptureControl: ClipboardAdmission {
    static let shared = CaptureControl()
    /// nspasteboard.org: the bundle identifier of the application that wrote the copy.
    static let sourceType = NSPasteboard.PasteboardType("org.nspasteboard.source")
    /// The timed choices offered in the menu, in seconds.
    static let timedPauses: [TimeInterval] = [5 * 60, 60 * 60]
    static let maximumSourceBytes = 255

    enum PauseState: Equatable {
        case running
        /// `nil` waits for the user to resume.
        case paused(until: Date?)
    }

    private enum Key {
        static let pausedUntil = "capturePausedUntil"
        static let pausedIndefinitely = "capturePausedIndefinitely"
        static let ignoredApps = "captureIgnoredApps"
    }

    private let defaults: UserDefaults
    private let now: () -> Date
    private let frontmost: @MainActor () -> SourceApp?
    private let appName: @MainActor (String) -> String?
    private let ownBundleID: String?
    private var expiry: Timer?
    private var skippedChangeCount: Int?
    /// Armed by "Skip next copy"; the next change that is not Shelf's own disarms it.
    private(set) var skipsNextCopy = false
    /// Pause, skip or the ignored list changed, or a timed pause ran out.
    var onChange: () -> Void = {}
    /// A pause just ended. The watchers start again from the board as it is now.
    var onResume: () -> Void = {}

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init,
         frontmost: @escaping @MainActor () -> SourceApp? = SourceApps.frontmost,
         appName: @escaping @MainActor (String) -> String? = SourceApps.name(forBundleID:),
         ownBundleID: String? = Bundle.main.bundleIdentifier) {
        self.defaults = defaults; self.now = now; self.frontmost = frontmost
        self.appName = appName; self.ownBundleID = ownBundleID
    }

    // MARK: Pause

    /// The deadline is stored, so a pause survives a relaunch until it runs
    /// out. Reading the state is what ends an expired pause.
    var pauseState: PauseState {
        if defaults.bool(forKey: Key.pausedIndefinitely) { return .paused(until: nil) }
        let stored = defaults.double(forKey: Key.pausedUntil)
        guard stored > 0, stored.isFinite else { return .running }
        let current = now(), longest = Self.timedPauses.max() ?? 0
        var until = Date(timeIntervalSince1970: stored)
        guard until > current else { defaults.removeObject(forKey: Key.pausedUntil); return .running }
        // A clock that moved backwards must not stretch a timed pause beyond
        // the longest one that can be asked for.
        if until.timeIntervalSince(current) > longest {
            until = current.addingTimeInterval(longest)
            defaults.set(until.timeIntervalSince1970, forKey: Key.pausedUntil)
        }
        return .paused(until: until)
    }
    var isPaused: Bool { pauseState != .running }

    /// `nil` pauses until `resume()`.
    func pause(for duration: TimeInterval?) {
        if let duration {
            defaults.set(now().addingTimeInterval(max(0, duration)).timeIntervalSince1970, forKey: Key.pausedUntil)
            defaults.removeObject(forKey: Key.pausedIndefinitely)
        } else {
            defaults.set(true, forKey: Key.pausedIndefinitely)
            defaults.removeObject(forKey: Key.pausedUntil)
        }
        skipsNextCopy = false
        scheduleExpiry(); onChange()
    }

    func resume() {
        guard isPaused else { return }
        defaults.removeObject(forKey: Key.pausedUntil)
        defaults.removeObject(forKey: Key.pausedIndefinitely)
        scheduleExpiry(); onResume(); onChange()
    }

    /// Call once at launch: a pause restored from preferences still needs its
    /// expiry announced. The timer only refreshes what is shown; `pauseState`
    /// decides on its own whether capture is paused.
    func scheduleExpiry() {
        expiry?.invalidate(); expiry = nil
        guard case let .paused(until?) = pauseState else { return }
        let timer = Timer(timeInterval: max(0.1, until.timeIntervalSince(now())), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.scheduleExpiry()
                if !self.isPaused { self.onResume() }
                self.onChange()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        expiry = timer
    }

    // MARK: Skip next copy

    func setSkipsNextCopy(_ on: Bool) {
        skipsNextCopy = on && !isPaused
        if skipsNextCopy { skippedChangeCount = nil }
        onChange()
    }

    func skips(changeCount: Int) -> Bool {
        if skipsNextCopy {
            skipsNextCopy = false; skippedChangeCount = changeCount
            onChange()
        }
        return skippedChangeCount == changeCount
    }

    // MARK: Ignored apps

    /// Bundle identifiers, in the order they were added. Never pre-populated.
    private(set) var ignoredBundleIDs: [String] {
        get { defaults.stringArray(forKey: Key.ignoredApps) ?? [] }
        set { defaults.set(newValue, forKey: Key.ignoredApps) }
    }
    func isIgnored(_ bundleID: String) -> Bool {
        ignoredBundleIDs.contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
    }
    func ignore(_ bundleID: String) {
        guard Self.isBundleID(bundleID), !isIgnored(bundleID) else { return }
        ignoredBundleIDs.append(bundleID); onChange()
    }
    func stopIgnoring(_ bundleID: String) {
        ignoredBundleIDs.removeAll { $0.caseInsensitiveCompare(bundleID) == .orderedSame }; onChange()
    }

    // MARK: Admission

    func admit(source: any ClipboardSource, items: [[NSPasteboard.PasteboardType]]) -> ClipboardAdmissionDecision {
        guard let app = sourceApp(of: source, items: items) else { return .admitted(nil) }
        if isIgnored(app.bundleID) { return .rejected }
        // A copy made while Shelf is in front is not attributed to Shelf.
        if let ownBundleID, app.bundleID.caseInsensitiveCompare(ownBundleID) == .orderedSame { return .admitted(nil) }
        return .admitted(app)
    }

    /// The pasteboard's own source marker wins when the copying application
    /// provides one. Otherwise this is a heuristic: the frontmost application
    /// at the moment the change is observed, up to half a second after the
    /// copy. A background tool, or a quick switch between applications, is
    /// then attributed to whichever application was in front.
    func sourceApp(of source: any ClipboardSource, items: [[NSPasteboard.PasteboardType]]) -> SourceApp? {
        let front = frontmost()
        for (index, types) in items.enumerated() where types.contains(Self.sourceType) {
            guard let data = source.data(forType: Self.sourceType, at: index), data.count <= Self.maximumSourceBytes,
                  let text = String(data: data, encoding: .utf8) else { continue }
            let bundleID = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.isBundleID(bundleID) else { continue }
            if let front, front.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame { return front }
            return SourceApp(bundleID: bundleID, name: appName(bundleID) ?? bundleID)
        }
        return front
    }

    static func isBundleID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumSourceBytes && value.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" || $0 == "_")
        }
    }
}
