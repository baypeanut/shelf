#if !STANDALONE_TESTS
    import Foundation
    import XCTest
    @testable import Shelf

    /// A regression tool, not a test: it runs only when SHELF_LIBRARY_BENCHMARK
    /// names the library sizes to build, as scripts/benchmark-library.sh does.
    /// Everything lives in a temporary folder and a disposable preferences suite.
    @MainActor final class LibraryBenchmarkTests: XCTestCase {
        private struct Samples {
            var values = [Double]()
            mutating func measure<T>(_ body: () throws -> T) rethrows -> T {
                let start = DispatchTime.now().uptimeNanoseconds
                let result = try body()
                values.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
                return result
            }
            func percentile(_ fraction: Double) -> Double {
                guard !values.isEmpty else { return 0 }
                let sorted = values.sorted()
                return sorted[min(sorted.count - 1, Int((Double(sorted.count) * fraction).rounded(.up)) - 1)]
            }
            var row: String { String(format: "%.2f | %.2f | %.2f", percentile(0.5), percentile(0.95), values.max() ?? 0) }
        }
        private var lines = [String]()
        private func report(_ name: String, _ samples: Samples, _ note: String = "") {
            lines.append("| \(name) | \(samples.row) | \(note) |")
        }

        func testLibraryBenchmark() throws {
            guard let request = ProcessInfo.processInfo.environment["SHELF_LIBRARY_BENCHMARK"], !request.isEmpty else {
                throw XCTSkip("Set SHELF_LIBRARY_BENCHMARK to a list of library sizes, for example 5000,50000")
            }
            for size in request.split(separator: ",").compactMap({ Int($0) }) where size > 0 { try run(size) }
        }

        private func megabytes(_ url: URL) -> Double {
            Double((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) / 1_048_576
        }

        private func run(_ size: Int) throws {
            let f = try SyntheticFixture()
            defer { f.cleanup() }
            f.date = Date(timeIntervalSince1970: 1_800_000_000)
            let trash = fixtureTrash(f.folder)
            func open() throws -> LibraryStore {
                try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date }, moveToTrash: trash)
            }
            lines = [
                "", "## Library benchmark: \(size) items", "", "| measurement | p50 ms | p95 ms | max ms | note |", "|---|---|---|---|---|",
            ]

            // Build through the store's own import, in batches like a large paste of history.
            var store: LibraryStore? = try open()
            let records = try SyntheticLibraryCorpus.records(count: size, seed: 0x5E1F, inbox: f.inbox, end: f.date)
            var build = Samples()
            try build.measure {
                var start = 0
                while start < records.count {
                    let end = min(records.count, start + 500)
                    try store?.importRecords(Array(records[start..<end]))
                    start = end
                }
            }
            // Recognized text for half of the images, written the way the image indexer writes it.
            var generator = SeededGenerator(seed: 0x0C12)
            let analysis = try LibraryDatabase(url: try XCTUnwrap(store).databaseURL, verify: false)
            try analysis.transaction {
                for record in records where record.kind == .image && generator.index(2) == 0 {
                    let text =
                        SyntheticLibraryCorpus.text(&generator, bytes: 300 + generator.index(1_700))
                        + (generator.index(20) == 0 ? " whiteboard" : "")
                    try analysis.execute(
                        "INSERT INTO image_analysis(item,path,fingerprint,version,content,ocr,vectors) VALUES(?,?,?,?,?,?,?)",
                        [
                            .text(record.id.uuidString), .text(record.path ?? ""), .text("synthetic"), .text("vision-ocr-v1"),
                            .text(text.libraryFolded), .text(text), .blob(Data()),
                        ])
                }
            }
            let counts = Dictionary(grouping: records, by: \.kind).mapValues(\.count)
            let textBytes = records.reduce(0) { $0 + ($1.text?.utf8.count ?? 0) }
            lines.insert(
                "\(counts[.text] ?? 0) texts (\(textBytes / 1_048_576) MB), \(counts[.link] ?? 0) links, \(counts[.image] ?? 0) images; built in \(Int(build.values[0])) ms",
                at: 3)
            lines.insert("", at: 4)

            // Close and reopen, as a launch does.
            let databaseURL = try XCTUnwrap(store).databaseURL
            store = nil
            _ = try? LibraryDatabase(url: databaseURL, verify: false).rows("PRAGMA wal_checkpoint(TRUNCATE)")
            var opening = Samples()
            var checking = Samples()
            for _ in 0..<5 {
                store = nil
                store = try opening.measure { try open() }
            }
            for _ in 0..<3 { _ = try checking.measure { try LibraryDatabase(url: databaseURL, readOnly: true, verify: true) } }
            report("open the store (launch)", opening, "LibraryStore.init on the existing library")
            report("integrity check alone", checking, "a connection opened with the check")
            let library = try XCTUnwrap(store)

            // Saves with nothing observing the store.
            var shortSave = Samples()
            var largeSave = Samples()
            var linkSave = Samples()
            var imageSave = Samples()
            for index in 0..<200 {
                f.date.addTimeInterval(1)
                let text = "bench short \(index) " + SyntheticLibraryCorpus.text(&generator, bytes: 40 + generator.index(300))
                _ = try shortSave.measure { try library.captureText(text) }
            }
            for index in 0..<20 {
                f.date.addTimeInterval(1)
                let text = "bench large \(index) " + SyntheticLibraryCorpus.text(&generator, bytes: 100_000)
                _ = try largeSave.measure { try library.captureText(text) }
            }
            for index in 0..<100 {
                f.date.addTimeInterval(1)
                let url = try XCTUnwrap(URL(string: "https://bench.example.com/store/\(index)"))
                _ = try linkSave.measure { try library.captureLink(url) }
            }
            for _ in 0..<100 {
                f.date.addTimeInterval(1)
                let file = f.inbox.appendingPathComponent("Clipboard \(UUID()).png")
                try SyntheticLibraryCorpus.pixel.write(to: file)
                _ = try imageSave.measure { try library.captureImage(file) }
            }
            report("save a short text", shortSave, "store only")
            report("save a 100 KB text", largeSave, "store only")
            report("save a link", linkSave, "store only")
            report("save an image record", imageSave, "store only")

            // Reading each shelf from the store.
            for kind in LibraryKind.allCases {
                var samples = Samples()
                var count = 0
                for _ in 0..<5 { count = try samples.measure { try library.shelfItems(kind).count } }
                report("read the \(kind.rawValue) shelf", samples, "\(count) records")
            }

            // The same saves with the three shelves attached, as in the running app.
            var attach = Samples()
            let line = attach.measure {
                Line(
                    defaults: f.defaults, inbox: f.inbox, now: { f.date }, breeze: false, moveToTrash: trash, copyImage: { _ in },
                    copyText: { _ in }, library: library)
            }
            report(
                "load the three shelves", attach,
                "\(line.items.count) images, \(line.texts.entries.count) texts, \(line.links.entries.count) links")
            var shortShown = Samples()
            var largeShown = Samples()
            var linkShown = Samples()
            var imageShown = Samples()
            var pinShown = Samples()
            var recopyShown = Samples()
            for index in 0..<100 {
                f.date.addTimeInterval(1)
                let text = "bench shown \(index) " + SyntheticLibraryCorpus.text(&generator, bytes: 40 + generator.index(300))
                shortShown.measure { _ = line.texts.add(text) }
            }
            for index in 0..<10 {
                f.date.addTimeInterval(1)
                let text = "bench shown large \(index) " + SyntheticLibraryCorpus.text(&generator, bytes: 100_000)
                largeShown.measure { _ = line.texts.add(text) }
            }
            for index in 0..<50 {
                f.date.addTimeInterval(1)
                let url = try XCTUnwrap(URL(string: "https://bench.example.com/shown/\(index)"))
                linkShown.measure { _ = line.links.add(url) }
            }
            for _ in 0..<50 {
                f.date.addTimeInterval(1)
                let file = f.inbox.appendingPathComponent("Clipboard \(UUID()).png")
                try SyntheticLibraryCorpus.pixel.write(to: file)
                _ = try imageShown.measure { try library.captureImage(file) }
            }
            let oldest = try XCTUnwrap(line.texts.entries.last)
            for _ in 0..<20 {
                f.date.addTimeInterval(1)
                pinShown.measure { line.texts.togglePin(oldest.id) }
            }
            for _ in 0..<20 {
                f.date.addTimeInterval(1)
                recopyShown.measure { _ = line.texts.add(oldest.text) }
            }
            report("save a short text, shelves attached", shortShown, "save and shelf reload")
            report("save a 100 KB text, shelves attached", largeShown, "save and shelf reload")
            report("save a link, shelves attached", linkShown, "save and shelf reload")
            report("save an image record, shelves attached", imageShown, "save and shelf reload")
            report("pin a text, shelves attached", pinShown, "edit and shelf reload")
            report("copy an old text again, shelves attached", recopyShown, "save and shelf reload")

            // Search on the calling thread: every matching ID on one shelf (text,
            // or image for recognized text), as shelf search asks for, and the
            // first Library page across all kinds.
            let shapes: [(String, String)] = [
                ("1 character", "a"), ("2 characters", "st"), ("a word", "invoice"), ("inside a word", "lipboar"),
                ("several words", "meeting budget travel"), ("word and short term", "release of"),
                ("Turkish, dotted capital", "İSTANBUL"), ("Turkish, dotless", "ığdır"), ("diacritics", "creme brulee"),
                ("CJK, 2 characters", "中文"), ("CJK, longer", "東京都渋谷"), ("full width", "ＡＢＣ１２３"),
                ("punctuation", "50%_off"), ("recognized image text", "whiteboard"), ("no match", "zzqqxxjjvv"),
            ]
            for (name, text) in shapes {
                var shelf = Samples()
                var page = Samples()
                var hits = 0
                var shelfQuery = LibraryQuery(scope: .shelf, kind: name.contains("image") ? .image : .text, search: text)
                shelfQuery.searchMode = .text
                var pageQuery = LibraryQuery(scope: .recent, search: text)
                pageQuery.searchMode = .text
                for _ in 0..<7 { hits = try shelf.measure { try library.queryIDs(shelfQuery).count } }
                for _ in 0..<7 { _ = try page.measure { try library.query(pageQuery, limit: 80).count } }
                report("search a shelf: \(name)", shelf, "\(hits) matches for “\(text)”")
                report("search Library page: \(name)", page, "first 80 of unsaved history")
            }

            _ = try? LibraryDatabase(url: databaseURL, verify: false).rows("PRAGMA wal_checkpoint(TRUNCATE)")
            lines.append("")
            lines.append(
                String(
                    format: "Database file: %.1f MB (plus %.1f MB write-ahead log)", megabytes(databaseURL),
                    megabytes(URL(fileURLWithPath: databaseURL.path + "-wal"))))
            if let tables = try? LibraryDatabase(url: databaseURL, readOnly: true, verify: false).rows(
                "SELECT name,sum(pgsize) AS bytes FROM dbstat GROUP BY name ORDER BY bytes DESC LIMIT 8")
            {
                let parts = tables.compactMap { row -> String? in
                    guard let name = row["name"]?.string, let bytes = row["bytes"]?.number else { return nil }
                    return String(format: "%@ %.1f MB", name, Double(bytes) / 1_048_576)
                }
                lines.append("Largest tables: " + parts.joined(separator: ", "))
            }
            print(lines.joined(separator: "\n"))
            withExtendedLifetime(line) {}
        }
    }
#endif
