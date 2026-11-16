import Foundation

enum HistoryRetention {
    static func key(_ kind: LibraryKind) -> String {
        switch kind { case .image: "historyRetentionDays"; case .text: "textHistoryRetentionDays"; case .link: "linkHistoryRetentionDays" }
    }
    static func days(_ kind: LibraryKind, defaults: UserDefaults) -> Int {
        let specific = defaults.integer(forKey: key(kind))
        if ImageHistory.dayChoices.contains(specific) { return specific }
        let legacy = defaults.integer(forKey: "historyRetentionDays")
        return ImageHistory.dayChoices.contains(legacy) ? legacy : 30
    }
    static let trashKey = "trashRetentionDays"
    /// 0 is the stored choice for never emptying Trash automatically.
    static let trashDayChoices = [7, 30, 90, 0]
    /// How long a trashed item stays recoverable, or nil to keep it until
    /// Trash is emptied by hand. A missing or unknown preference means 30 days.
    static func trashDays(defaults: UserDefaults) -> Int? {
        guard let stored = defaults.object(forKey: trashKey) as? Int, trashDayChoices.contains(stored) else { return 30 }
        return stored == 0 ? nil : stored
    }
}
