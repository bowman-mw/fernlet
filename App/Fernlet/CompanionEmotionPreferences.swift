import Foundation
import FernletScoring

/// The person's companion-feelings settings: the appetite and thirst cues switch, and the bedtime
/// window that makes the companion sleepy.
///
/// Device-local `UserDefaults`, never synced and never in `FernletSettings`, on the
/// `RecentActivityTypeMemory` pattern: the Settings rows bind the same keys through `@AppStorage`,
/// and `FernletStore` reads them here when it builds the companion's emotion inputs, so key and
/// reader cannot drift. "Delete everything" clears all three (``clearAll(in:)``, owner 2026-11-13:
/// "really means everything"), so after a wipe the companion is back on the standard sleep window
/// with appetite cues ON, like a fresh install — someone who had turned the cues off turns them off
/// again in Settings › Appearance › Companion feelings (see `Docs/PrivacyWipeCoverage.md`).
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

    /// Removes all three settings — the "Delete everything" funnel's call. A plain `UserDefaults`
    /// removal has no failure signal. The `@AppStorage` rows bound to these keys see the removal and
    /// fall back to their defaults.
    static func clearAll(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: appetiteCuesKey)
        defaults.removeObject(forKey: bedtimeMinuteKey)
        defaults.removeObject(forKey: wakeMinuteKey)
    }
}
