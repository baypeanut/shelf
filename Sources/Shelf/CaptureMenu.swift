import AppKit

/// The capture rows of the menu bar menu and the wording they share with the
/// Actions catalog and the status item.
@MainActor
enum CaptureMenu {
    static func pauseTitle(_ duration: TimeInterval?) -> String {
        switch duration {
        case 300?: L("For 5 minutes")
        case 3600?: L("For 1 hour")
        default: L("Until I resume")
        }
    }

    /// Nil while capture runs. A timed pause says how long is left.
    static func status(_ capture: CaptureControl, now: Date = Date()) -> String? {
        switch capture.pauseState {
        case .running: return nil
        case .paused(until: nil): return L("Clipboard capture paused until you resume")
        case .paused(until: let until?):
            let formatter = DateComponentsFormatter()
            formatter.unitsStyle = .short
            formatter.maximumUnitCount = 1
            let seconds = max(1, until.timeIntervalSince(now))
            // Round up so the last minute never reads as "0 min".
            formatter.allowedUnits = seconds >= 60 ? [.hour, .minute] : [.second]
            let remaining = formatter.string(from: seconds >= 60 ? (seconds / 60).rounded(.up) * 60 : seconds.rounded(.up)) ?? ""
            return String(format: L("Clipboard capture paused · %@ left"), remaining)
        }
    }

    static func items(_ capture: CaptureControl) -> [NSMenuItem] {
        if let status = status(capture) {
            let state = NSMenuItem(title: status, action: nil, keyEquivalent: "")
            state.isEnabled = false
            return [state, ClosureMenuItem(L("Resume capture")) { capture.resume() }]
        }
        let choices = NSMenu()
        for duration in CaptureControl.timedPauses.map(Optional.some) + [nil] {
            choices.addItem(ClosureMenuItem(pauseTitle(duration)) { capture.pause(for: duration) })
        }
        let pause = NSMenuItem(title: L("Pause clipboard capture"), action: nil, keyEquivalent: "")
        pause.submenu = choices
        let skip = ClosureMenuItem(L("Skip next copy")) { capture.setSkipsNextCopy(!capture.skipsNextCopy) }
        skip.state = capture.skipsNextCopy ? .on : .off
        return [pause, skip]
    }
}
