import Foundation

#if !STANDALONE_TESTS
    import XCTest
    @testable import Shelf
#endif

/// A fixed seed gives the same fictional library on every run, so benchmark
/// numbers and differential failures can be reproduced.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
    mutating func index(_ count: Int) -> Int { Int(next() % UInt64(max(1, count))) }
    mutating func uuid() -> UUID {
        let a = next()
        let b = next()
        return UUID(
            uuid: (
                UInt8(truncatingIfNeeded: a), UInt8(truncatingIfNeeded: a >> 8), UInt8(truncatingIfNeeded: a >> 16),
                UInt8(truncatingIfNeeded: a >> 24), UInt8(truncatingIfNeeded: a >> 32), UInt8(truncatingIfNeeded: a >> 40),
                UInt8(truncatingIfNeeded: a >> 48) & 0x0F | 0x40, UInt8(truncatingIfNeeded: a >> 56),
                UInt8(truncatingIfNeeded: b) & 0x3F | 0x80, UInt8(truncatingIfNeeded: b >> 8), UInt8(truncatingIfNeeded: b >> 16),
                UInt8(truncatingIfNeeded: b >> 24), UInt8(truncatingIfNeeded: b >> 32), UInt8(truncatingIfNeeded: b >> 40),
                UInt8(truncatingIfNeeded: b >> 48), UInt8(truncatingIfNeeded: b >> 56)
            ))
    }
}

/// Fictional clipboard content in the scripts search has to handle: Latin,
/// Turkish dotted and dotless I, diacritics, CJK, full-width forms, emoji,
/// punctuation that is special to SQL or to a full-text query, and
/// high-entropy tokens.
enum SyntheticLibraryCorpus {
    static let words: [String] = [
        "meeting", "notes", "of", "to", "in", "a", "draft", "review", "İstanbul", "中文", "shelf", "clipboard",
        "history", "search", "café", "window", "preview", "ISTANBUL", "folder", "library", "çekim", "capture",
        "screen", "你好世界", "report", "budget", "travel", "ticket", "ıstanbul", "istanbul", "password-less", "re-entry",
        "snake_case", "camelCase", "v2.14.3", "user@example.com", "C:\\temp\\file.txt", "IĞDIR", "ığdır", "DİYARBAKIR",
        "diyarbakır", "ÇEKİM", "şarkı", "öğrenci", "güneş", "ılık", "IŞIK", "ışık", "Iİıi", "kağıt", "üzüm", "cafe",
        "naïve", "résumé", "Ångström", "straße", "señor", "crème brûlée", "Zoë", "剪贴板历史", "東京都渋谷区",
        "日本語のテキスト", "クリップボード", "검색어", "한국어", "繁體中文字", "ＡＢＣ１２３", "ｆｕｌｌｗｉｄｔｈ", "👋", "🗂️ files",
        "100%", "50%_off", "a_b%c", "'; DROP TABLE items; --", "\"quoted\"", "(paren)", "AND", "OR", "NOT", "NEAR",
        "x*", "^caret", "{brace}", "a:b", "+plus", "-minus", "ab", "é", "ı", "中", "xy", "invoice", "quarterly",
    ]
    static func word(_ generator: inout SeededGenerator) -> String {
        // One word in twelve is unique-looking, like an identifier or a key.
        if generator.index(12) == 0 { return String(generator.next(), radix: 36) }
        // Skewed like real vocabulary: the first words are common, the last rare.
        let unit = Double(generator.index(1_000_000)) / 1_000_000
        return words[min(words.count - 1, Int(Double(words.count) * unit * unit * unit))]
    }
    static func text(_ generator: inout SeededGenerator, bytes: Int) -> String {
        var result = ""
        var size = 0
        while size < bytes {
            let next = word(&generator)
            let separator = generator.index(14) == 0 ? "\n" : generator.index(20) == 0 ? "\t" : " "
            result += next + separator
            size += next.utf8.count + 1
        }
        return result
    }
    /// The kinds of queries people type, drawn from the same vocabulary:
    /// one or two characters, whole words, pieces cut from inside a word,
    /// several terms, and terms that match nothing.
    static func query(_ generator: inout SeededGenerator) -> String {
        func piece() -> String {
            let scalars = Array(word(&generator).unicodeScalars)
            let length = min(scalars.count, 1 + generator.index(6))
            let start = generator.index(scalars.count - length + 1)
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars[start..<(start + length)])
            return String(view)
        }
        switch generator.index(10) {
        case 0: return String(piece().unicodeScalars.prefix(1))
        case 1: return String(piece().unicodeScalars.prefix(2))
        case 2, 3: return words[generator.index(words.count)]
        case 4, 5: return piece()
        case 6: return words[generator.index(words.count)] + " " + piece()
        case 7: return piece() + "  " + piece() + " " + piece()
        case 8: return words[generator.index(words.count)].uppercased()
        default: return piece() + String(generator.next(), radix: 36).prefix(2)
        }
    }

    struct Mix {
        var largeTexts = 0.01, mediumTexts = 0.04, links = 0.15, images = 0.10
        var largeBytes = 100_000
        var retained = 0.15, trashed = 0.05, offShelf = 0.0
    }
    /// The smallest valid PNG, written under a clipboard-copy name so the
    /// store treats it as a file it owns.
    static let pixel = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!

    /// Records oldest first, one second apart, ending at `end`.
    static func records(count: Int, seed: UInt64, inbox: URL, end: Date, mix: Mix = Mix()) throws -> [LibraryRecord] {
        var generator = SeededGenerator(seed: seed)
        var result = [LibraryRecord]()
        result.reserveCapacity(count)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        for index in 0..<count {
            let date = end.addingTimeInterval(Double(index - count))
            let roll = Double(generator.index(10_000)) / 10_000
            var record: LibraryRecord
            if roll < mix.images {
                record = LibraryRecord(id: generator.uuid(), kind: .image, createdAt: date, updatedAt: date)
                let file = inbox.appendingPathComponent("Clipboard \(generator.uuid()).png")
                try pixel.write(to: file)
                record.path = file.path
            } else if roll < mix.images + mix.links {
                record = LibraryRecord(id: generator.uuid(), kind: .link, createdAt: date, updatedAt: date)
                let url = URL(
                    string:
                        "https://\(["example.com", "docs.example.org", "video.example.net"][generator.index(3)])/\(String(generator.next(), radix: 36))/item-\(index)?topic=\(["orbital", "release", "istanbul"][generator.index(3)])"
                )!
                record.originalURL = url.absoluteString
                record.normalizedURL = LinkIdentity.normalized(url)
                if generator.index(2) == 0 {
                    record.metadataTitle = text(&generator, bytes: 40)
                    record.metadataState = "ready"
                }
            } else {
                record = LibraryRecord(id: generator.uuid(), kind: .text, createdAt: date, updatedAt: date)
                let size =
                    roll < mix.images + mix.links + mix.largeTexts
                    ? mix.largeBytes
                    : roll < mix.images + mix.links + mix.largeTexts + mix.mediumTexts
                        ? 2_000 + generator.index(6_000) : 12 + generator.index(380)
                // The index keeps every text distinct for clipboard identity.
                record.text = "#\(index) " + text(&generator, bytes: size)
            }
            record.lastCapturedAt = date
            record.captureRevision = generator.uuid()
            if generator.index(10) == 0 { record.title = text(&generator, bytes: 16).trimmingCharacters(in: .whitespacesAndNewlines) }
            if generator.index(12) == 0 { record.note = text(&generator, bytes: 60) }
            let state = Double(generator.index(10_000)) / 10_000
            if state < mix.trashed {
                record.deletedAt = date
                record.onShelf = false
                record.trashRevision = generator.uuid()
            } else if state < mix.trashed + mix.retained {
                record.retainedAt = date
                record.favorite = generator.index(2) == 0
            }
            if record.deletedAt == nil, Double(generator.index(10_000)) / 10_000 < mix.offShelf, record.retainedAt != nil {
                record.onShelf = false
            }
            result.append(record)
        }
        return result
    }
}
