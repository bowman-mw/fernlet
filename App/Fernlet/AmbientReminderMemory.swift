import Foundation
import FernletFoundation

/// The gentle reminders' small device-local record: the dates breathing and grounding sessions were
/// finished, the reminders' schedule (`AmbientReminderSchedule`: what showed when, what was put
/// off with "Not now"), and when a quiet-place card last named a restaurant, gym or name-only place
/// (a date only, so those are suggested at most once a quarter; P3-B).
///
/// `UserDefaults` on this iPhone only, never synced and never in `FernletSettings`, on the
/// `CompanionEmotionPreferences` pattern. A finish keeps only its date and which tool it was — no
/// content, no feelings — and only the last `finishCap` per tool; an abandoned session is never
/// recorded. "Delete everything" removes all three keys (``clearAll(in:)``, in `resetAll`'s
/// `clearSettingsAndRunMarkersForWipe` leg; see `Docs/PrivacyWipeCoverage.md`).
///
/// The keys are FROZEN persisted tokens — never rename or localize them.
nonisolated enum AmbientReminderMemory {
    /// `[String: [Double]]`: per `AmbientCalmTool` raw value, finish dates as seconds since 1970.
    static let calmFinishesKey = "fernlet.ambientReminders.calmFinishes"
    /// `Data`: the JSON-encoded `AmbientReminderSchedule`.
    static let scheduleKey = "fernlet.ambientReminders.schedule"
    /// `Double`: when a quiet-place card last named a restaurant, gym or name-only place, in seconds since
    /// 1970. A date only: never which place.
    static let indoorPlaceShownKey = "fernlet.ambientReminders.indoorPlaceShown"
    /// How many finish dates are kept per tool (the newest).
    static let finishCap = 20

    /// Whether a quiet-place card may name a restaurant, gym or name-only place at `now`: none shown, or
    /// the last over ``AmbientQuietPlaceFinder/indoorRestDays`` ago.
    static func indoorPlaceRested(now: Date, in defaults: UserDefaults = .standard) -> Bool {
        guard let seconds = defaults.object(forKey: indoorPlaceShownKey) as? Double else { return true }
        let rest = Double(AmbientQuietPlaceFinder.indoorRestDays) * 86_400
        return now.timeIntervalSince(Date(timeIntervalSince1970: seconds)) >= rest
    }

    /// Records that a quiet-place card named a restaurant, gym or name-only place at `date`.
    static func recordIndoorPlaceShown(at date: Date, in defaults: UserDefaults = .standard) {
        defaults.set(date.timeIntervalSince1970, forKey: indoorPlaceShownKey)
    }

    /// The finish dates per calm tool, oldest first. Unknown tool tokens are ignored.
    static func calmFinishes(in defaults: UserDefaults = .standard) -> [AmbientCalmTool: [Date]] {
        guard let stored = defaults.dictionary(forKey: calmFinishesKey) else { return [:] }
        var finishes: [AmbientCalmTool: [Date]] = [:]
        for (token, value) in stored {
            guard let tool = AmbientCalmTool(rawValue: token), let seconds = value as? [Double] else { continue }
            finishes[tool] = seconds.map { Date(timeIntervalSince1970: $0) }
        }
        return finishes
    }

    /// Records that `tool` was finished at `date`, keeping the newest `finishCap` dates.
    static func recordCalmFinish(_ tool: AmbientCalmTool, at date: Date = Date(), in defaults: UserDefaults = .standard) {
        var stored = defaults.dictionary(forKey: calmFinishesKey) as? [String: [Double]] ?? [:]
        let dates = (stored[tool.rawValue] ?? []) + [date.timeIntervalSince1970]
        stored[tool.rawValue] = Array(dates.sorted().suffix(finishCap))
        assert((stored[tool.rawValue]?.count ?? 0) <= finishCap, "the finish record stays capped")
        defaults.set(stored, forKey: calmFinishesKey)
    }

    /// The stored schedule, or a fresh one (nothing stored, or a record this build cannot read).
    static func schedule(in defaults: UserDefaults = .standard) -> AmbientReminderSchedule {
        guard let data = defaults.data(forKey: scheduleKey) else { return AmbientReminderSchedule() }
        do {
            return try JSONDecoder().decode(AmbientReminderSchedule.self, from: data)
        } catch {
            FernletAuditLog.log("ambientReminders.scheduleUnreadable")
            return AmbientReminderSchedule()
        }
    }

    /// Stores `schedule`. An encode failure keeps the previous record and is audited.
    static func save(_ schedule: AmbientReminderSchedule, in defaults: UserDefaults = .standard) {
        do {
            defaults.set(try JSONEncoder().encode(schedule), forKey: scheduleKey)
        } catch {
            FernletAuditLog.log("ambientReminders.scheduleUnsaved")
        }
    }

    /// Removes all three records — the "Delete everything" funnel's call. A plain `UserDefaults` removal
    /// has no failure signal.
    static func clearAll(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: calmFinishesKey)
        defaults.removeObject(forKey: scheduleKey)
        defaults.removeObject(forKey: indoorPlaceShownKey)
    }
}
