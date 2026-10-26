import Foundation
import PrivateHealthStore

/// Advanced period tracking (World Review Batch 3, `b3-period-settings`, new from the owner's note on
/// `b3-log-period` draft 1): off by default, Log period shows the date, flow, first day of cycle and
/// the four common symptoms; on, it shows every symptom, spotting between periods, cervical mucus,
/// ovulation tests and basal temperature.
///
/// **Where it lives.** A device-only `UserDefaults` switch, never in the synced settings, the snapshot,
/// an export or the AI: it says nothing about a cycle by itself, but whether someone logs ovulation
/// tests is the kind of detail the sealed cycle store exists to keep off the iCloud blob, so it stays on
/// this iPhone with the other device-only preferences. "Delete everything" removes it
/// (``clearAll(in:)``, Docs/PrivacyWipeCoverage.md), and a decoy (duress) session neither reads nor
/// writes it: there it is always off, so a decoy shows nothing a real session set.
///
/// It only changes which fields Log period OFFERS. A record that already holds a symptom, an observation
/// or a temperature always shows it, whatever the switch says, so nothing logged is ever hidden from its
/// own edit sheet.
nonisolated enum CyclePreferences {
    /// The frozen `UserDefaults` key (a token; never localized, never renamed).
    static let advancedTrackingKey = "fernlet.cycle.advancedTracking"

    /// Whether Advanced period tracking is on. Always off in a decoy session.
    static func advancedTracking(duressSessionActive: Bool, in defaults: UserDefaults = .standard) -> Bool {
        guard !duressSessionActive else { return false }
        return defaults.bool(forKey: advancedTrackingKey)
    }

    /// Turns Advanced period tracking on or off. A decoy session writes nothing.
    static func setAdvancedTracking(_ on: Bool, duressSessionActive: Bool, in defaults: UserDefaults = .standard) {
        guard !duressSessionActive else { return }
        defaults.set(on, forKey: advancedTrackingKey)
    }

    /// Removes the switch (Delete everything): the next launch starts with it off.
    static func clearAll(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: advancedTrackingKey)
    }
}

/// Which of Log period's fields show (`b3-log-period` draft 2): the common set always, the rest with
/// Advanced period tracking — and any field the record being edited already holds, so an entry made
/// with the switch on (or synced from Apple Health) never loses a value from view when it is off.
/// Pure, so the rule is tested without SwiftUI (`LogPeriodFieldVisibilityTests`).
nonisolated enum LogPeriodFieldVisibility {
    /// The four symptoms offered by default, in the sheet's order: cramps, bloating, headache, fatigue.
    static let commonSymptoms: [PeriodSymptom] = [.cramps, .bloating, .headache, .fatigue]

    /// The symptoms to list: every one with Advanced on; otherwise the common four plus any other the
    /// draft already has, in the domain's order after them.
    static func symptoms(advanced: Bool, selected: Set<PeriodSymptom>) -> [PeriodSymptom] {
        guard !advanced else { return PeriodSymptom.allCases }
        let extra = PeriodSymptom.allCases.filter { !commonSymptoms.contains($0) && selected.contains($0) }
        return commonSymptoms + extra
    }

    /// The flow choices: None, Light, Medium and Heavy; "Unspecified" too with Advanced on, or when
    /// the draft already says it.
    static func flowLevels(advanced: Bool, selected: PeriodFlowLevel?) -> [PeriodFlowLevel] {
        guard !advanced, selected != .unspecified else { return PeriodFlowLevel.allCases }
        return PeriodFlowLevel.allCases.filter { $0 != .unspecified }
    }

    /// Whether "Intermenstrual bleeding" (spotting between periods) shows.
    static func showsSpotting(advanced: Bool, isOn: Bool) -> Bool { advanced || isOn }

    /// Whether the cervical-mucus and ovulation-test rows show.
    static func showsObservations(advanced: Bool, hasMucus: Bool, hasOvulationTest: Bool) -> Bool {
        advanced || hasMucus || hasOvulationTest
    }

    /// Whether the basal-temperature field shows.
    static func showsTemperature(advanced: Bool, temperatureText: String) -> Bool {
        advanced || !temperatureText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
