import Foundation

/// Standalone copies of the library database, made before its storage format
/// changes so a failed change can be undone by hand. A copy holds everything
/// the library held at that moment, including items deleted for good later,
/// so copies are short-lived: the newest two are kept, none for longer than a
/// week, and Empty Trash removes them all.
struct LibrarySnapshots {
    static let kept = 2
    static let lifetime: TimeInterval = 7 * 86_400
    private static let prefix = "library-before-update-", suffix = ".sqlite", staging = ".partial-"
    let folder: URL

    init(root: URL) { folder = root.appendingPathComponent("Snapshots", isDirectory: true) }

    /// Finished copies, oldest first. The time in the name is the library's
    /// own clock at the moment of the copy.
    func all() -> [URL] { dated().map(\.url) }
    private func dated() -> [(url: URL, date: Date, attempt: Int)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.compactMap { name -> (url: URL, date: Date, attempt: Int)? in
            let url = folder.appendingPathComponent(name)
            guard name.hasPrefix(Self.prefix), name.hasSuffix(Self.suffix) else { return nil }
            let parts = name.dropFirst(Self.prefix.count).dropLast(Self.suffix.count).split(
                separator: "-", omittingEmptySubsequences: false)
            // yyyy-MM-ddTHHmmssZ, then an optional attempt number.
            let stamp = parts.prefix(3).joined(separator: "-")
            let attempt = parts.count > 3 ? Int(parts[3]) ?? 0 : 1
            return (url, Self.formatter.date(from: stamp) ?? .distantPast, attempt)
        }.sorted { ($0.date, $0.attempt, $0.url.lastPathComponent) < ($1.date, $1.attempt, $1.url.lastPathComponent) }
    }
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss'Z'"
        return formatter
    }()

    /// Copies committed content through SQLite's backup interface, so pages
    /// still in the write-ahead log are included and the copy needs no side
    /// files. The copy is checked before it gets its final name, an existing
    /// copy is never replaced, and a failure leaves nothing behind.
    @discardableResult func make(of database: LibraryDatabase, at date: Date) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard folder.resolvingSymlinksInPath().path == folder.standardizedFileURL.path else { throw HistoryFiles.Failure.unsafeFile }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        removeUnfinished()
        let staged = folder.appendingPathComponent(Self.staging + UUID().uuidString + Self.suffix)
        do {
            try database.backup(to: staged)
            let count =
                "SELECT (SELECT count(*) FROM items) AS items,(SELECT count(*) FROM collections) AS folders,(SELECT count(*) FROM tags) AS tags"
            let expected = try database.rows(count).first
            var copied: [String: SQLValue]?
            var mode: String?
            do {
                let copy = try LibraryDatabase(url: staged, readOnly: true)
                copied = try copy.rows(count).first
                mode = try copy.rows("PRAGMA journal_mode").first?.values.first?.string
            }
            guard let expected, let copied, mode == "delete",
                ["items", "folders", "tags"].allSatisfy({ expected[$0]?.number != nil && expected[$0]?.number == copied[$0]?.number })
            else {
                throw HistoryFiles.Failure.unsafeFile
            }
            // The copy no longer uses a write-ahead log; the system's SQLite
            // can leave that log's empty index file behind.
            for side in ["-shm", "-wal"] { try? manager.removeItem(atPath: staged.path + side) }
            let stamp = Self.formatter.string(from: date)
            var target = folder.appendingPathComponent(Self.prefix + stamp + Self.suffix)
            var attempt = 2
            while manager.fileExists(atPath: target.path) {
                target = folder.appendingPathComponent(Self.prefix + stamp + "-\(attempt)" + Self.suffix)
                attempt += 1
            }
            // A move fails rather than replacing a file that appeared meanwhile.
            try manager.moveItem(at: staged, to: target)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            // The copy just made always stays, whatever the clock says.
            for old in all().filter({ $0 != target }).dropLast(Self.kept - 1) { try? manager.removeItem(at: old) }
            return target
        } catch {
            removeUnfinished()
            throw error
        }
    }

    /// Removes copies older than their lifetime. Returns how many went.
    @discardableResult func expire(now: Date) -> Int {
        removeUnfinished()
        let expired = dated().filter { now.timeIntervalSince($0.date) > Self.lifetime }
        for entry in expired { try? FileManager.default.removeItem(at: entry.url) }
        return expired.count
    }

    func removeAll() {
        removeUnfinished()
        for url in all() { try? FileManager.default.removeItem(at: url) }
    }

    /// A copy interrupted before it was named is not a snapshot.
    private func removeUnfinished() {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.lastPathComponent.hasPrefix(Self.staging) { try? FileManager.default.removeItem(at: url) }
    }
}
