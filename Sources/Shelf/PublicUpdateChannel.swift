import Foundation

/// This local release has no signed update channel. A feed cannot be enabled by
/// Info.plist values or saved preferences; configuring a future release requires
/// an explicit source change and an independent Shelf signing key.
struct PublicUpdateChannel: Equatable {
    static let repository = "baypeanut/shelf"
    let feedURL: URL

    init?(info: [String: Any]) { return nil }

    static func automaticChecksEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: AutomaticUpdateSchedule.preferenceKey) as? Bool ?? false
    }
}
