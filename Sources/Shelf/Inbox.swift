import Foundation
import Darwin

/// Screenshot routing is opt-in. Save the user's values before applying ours,
/// and restore only values Shelf still owns so later user changes survive.
enum Inbox {
    private static let domain = "com.apple.screencapture" as CFString
    private static let enabledKey = "inboxEnabled"
    private static let offeredKey = "inboxOffered"
    private static let savedKey = "inboxSavedSettings"

    static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Shelf/Screenshots", isDirectory: true)
    }()

    /// Injectable system boundary keeps tests away from screenshot preferences.
    struct Environment {
        var folder: URL
        var defaults: UserDefaults
        var read: (String) -> Any?
        var write: (String, Any?) -> Void
        var prepareFolder: (URL) throws -> Void
        static var system: Self {
            .init(folder: Inbox.folder, defaults: .standard,
                  read: { CFPreferencesCopyAppValue($0 as CFString, domain) },
                  write: { key, value in
                      CFPreferencesSetAppValue(key as CFString, value as CFPropertyList?, domain)
                      CFPreferencesAppSynchronize(domain)
                  }, prepareFolder: Inbox.prepareFolder)
        }
    }

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
    static var wasOffered: Bool {
        get { UserDefaults.standard.bool(forKey: offeredKey) }
        set { UserDefaults.standard.set(newValue, forKey: offeredKey) }
    }
    static var isApplied: Bool { isApplied(in: .system) }

    private static func ownedValues(in environment: Environment) -> [String: Any] {
        ["location": environment.folder.path,
         "location-screenshot": environment.folder.path,
         "location-screenrecording": environment.folder.path,
         "target": "file", "target-screenshot": "file",
         "target-screenrecording": "file", "show-thumbnail": false]
    }
    private static func matches(_ current: Any?, _ expected: Any) -> Bool {
        guard let current = current as? NSObject, let expected = expected as? NSObject else { return false }
        return current.isEqual(expected)
    }
    static func isApplied(in environment: Environment) -> Bool {
        // New macOS versions read the screenshot-specific key; older systems
        // use location. Never mistake an unrelated newer path for our folder.
        let current = environment.read("location-screenshot") as? String
            ?? environment.read("location") as? String
        guard let current else { return false }
        return URL(fileURLWithPath: (current as NSString).expandingTildeInPath).standardizedFileURL
            == environment.folder.standardizedFileURL
    }

    private static func prepareFolder(_ folder: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let attributes = try fm.attributesOfItem(atPath: folder.path)
        guard values.isDirectory == true, values.isSymbolicLink != true,
              folder.resolvingSymlinksInPath().path == folder.standardizedFileURL.path,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
            throw HistoryFiles.Failure.unsafeFile
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    }

    /// Return false without modifying screenshot preferences if the destination
    /// cannot safely receive files. Never redirect captures to an unavailable folder.
    @discardableResult static func apply(environment: Environment = .system) -> Bool {
        do { try environment.prepareFolder(environment.folder) }
        catch { return false }
        let owned = ownedValues(in: environment)
        // A saved snapshot also survives a crash or partial external edit. Do
        // not overwrite it with our own previously applied values on relaunch.
        if environment.defaults.dictionary(forKey: savedKey) == nil {
            var previous = [String: Any]()
            for key in owned.keys { previous[key] = environment.read(key) }
            environment.defaults.set(previous, forKey: savedKey)
        }
        for (key, value) in owned { environment.write(key, value) }
        return true
    }

    static func restore(environment: Environment = .system) {
        guard let saved = environment.defaults.dictionary(forKey: savedKey) else { return }
        for (key, value) in ownedValues(in: environment) where matches(environment.read(key), value) {
            // Missing originals are removed, returning them to system defaults.
            environment.write(key, saved[key])
        }
        environment.defaults.removeObject(forKey: savedKey)
    }
}
