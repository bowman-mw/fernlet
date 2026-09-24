import Foundation
import FernletScoring

/// The person's companion-feelings settings: the appetite and thirst cues switch, and the bedtime
/// window that makes the companion sleepy.
///
/// Device-local `UserDefaults`, never synced and never in `FernletSettings`, on the
/// `RecentActivityTypeMemory` pattern: the Settings rows bind the same keys through `@AppStorage`,
/// and `FernletStore` reads them here when it builds the companion's emotion inputs, so key and
/// reader cannot drift. How a companion behaves on this phone is a preference, not a record — the
/// "Delete everything" funnel keeps all three keys by design (see `Docs/PrivacyWipeCoverage.md`):
/// clearing the cue switch would silently switch appetite cues back ON for someone who turned them
/// off, which is the one outcome this switch exists to prevent.
///
/// The keys are FROZEN persisted tokens — never rename or localize them.
enum CompanionEmotionPreferences {
    /// `Bool`, default `true`: whether the companion may look hungry or thirsty.
    static let appetiteCuesKey = "fernlet.companionFeelings.appetiteCues"
    /// `Int`, minutes after local midnight: when the companion gets sleepy.
    static let bedtimeMinuteKey = "fernlet.companionFeelings.bedtimeMinute"
    /// `Int`, minutes after local midnight: when the companion wakes.
    static let wakeMinuteKey = "fernlet.companionFeelings.wakeMinute"

    /// The appetite and thirst cues switch; on until the person turns it off.
    static func appetiteCuesEnabled(in defaults: UserDefaults = .standard) -> Bool {
        guard let stored = defaults.object(forKey: appetiteCuesKey) as? Bool else { return true }
        return stored
    }

    /// The person's sleep window, or the standard 22:30–07:00 one until they set their own.
    static func sleepWindow(in defaults: UserDefaults = .standard) -> CompanionSleepWindow {
        let standard = CompanionSleepWindow.standard
        let bedtime = defaults.object(forKey: bedtimeMinuteKey) as? Int ?? standard.bedtimeMinute
        let wake = defaults.object(forKey: wakeMinuteKey) as? Int ?? standard.wakeMinute
        return CompanionSleepWindow(bedtimeMinute: bedtime, wakeMinute: wake)
    }
}
