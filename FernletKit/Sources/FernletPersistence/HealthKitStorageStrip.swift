// HealthKitStorageStrip.swift
// FernletPersistence
//
// The HealthKit half of the storage privacy strip, and the device-local residue it produces.
//
// Owner decision 2026-09-23 ("HealthKit information shouldn't be stored in iCloud"), App Review
// 5.1.3(ii): no value READ from HealthKit may reach the CloudKit-mirrored store. The strip below is
// applied by the one sanitize boundary (`SanitizedSnapshot` / `SanitizedDay`), so every synced write
// — today's snapshot, a past-day edit, the blob→row migration — passes through it. What it removes is
// not thrown away: `healthKitResidue` hands it to this device's `DeviceHealthResidueStoring` cache and
// `overlayingHealthKitResidue(_:)` puts it back on read, so this device keeps scoring with it while
// other devices derive their own from their own HealthKit store.

import Foundation
import FernletDomainModel

/// One day's HealthKit-derived values, kept on THIS device only — never in a synced row, the synced
/// blob, or a device backup.
///
/// The exact complement of the storage strip: whatever `FernletDay.strippingHealthKitValues()`
/// removes from a day, this carries, so `overlayingHealthKitResidue(_:)` can restore it on the
/// device that read it. Cycle and intimate groups are never carried (not even device-locally): they
/// were never persisted anywhere before this type existed, and they are re-read from HealthKit under
/// their own gates. Both caps are enforced at construction AND on decode, so a hand-edited or corrupt
/// cache file cannot smuggle either back in.
public nonisolated struct DeviceHealthResidue: Codable, Equatable {
    /// R3: the most Apple Health workouts one day's residue keeps. Far above any real day's imports
    /// (Apple Watch auto-detected walks included); the overflow would only lose its device-local
    /// mirror, never a HealthKit sample.
    public static let maxImportedWorkouts = 50

    /// The day's HealthKit context with `cycle` and `intimate` always nil, and
    /// `healthKitSleepLogHours` set only when the day's sleep hours were HealthKit's.
    public let context: HealthDailyContext?
    /// Workouts imported from Apple Health (`Workout.isHealthImported`) — read-only mirrors of
    /// samples another app or a manual Health entry owns. Fernlet-authored workouts are the user's
    /// own logs and stay in the synced row.
    public let importedWorkouts: [Workout]

    /// Normalizes on the way in: drops the cycle/intimate groups and caps the imported workouts.
    public init(context: HealthDailyContext?, importedWorkouts: [Workout]) {
        var cleaned = context
        cleaned?.cycle = nil
        cleaned?.intimate = nil
        self.context = cleaned
        self.importedWorkouts = Array(importedWorkouts.prefix(Self.maxImportedWorkouts))
    }

    /// The two persisted keys (the custom decoder needs them spelled out).
    private enum CodingKeys: String, CodingKey { case context, importedWorkouts }

    /// Decodes through the normalizing initializer; `importedWorkouts` is tolerant of absence.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            context: try container.decodeIfPresent(HealthDailyContext.self, forKey: .context),
            importedWorkouts: try container.decodeIfPresent([Workout].self, forKey: .importedWorkouts) ?? []
        )
    }

    /// Whether there is anything to keep — an empty residue is stored as no entry at all.
    public var isEmpty: Bool { context == nil && importedWorkouts.isEmpty }
}

/// The device-local cache of ``DeviceHealthResidue`` — non-synced, excluded from device backup,
/// bounded — that keeps this device's HealthKit readings once the storage strip has removed them
/// from every synced write.
///
/// The app's file-backed conformer lives in the app target, never in a module the walled
/// `CloudKitSync` imports; `DiaryStore` reaches it only through this protocol (overlay on read,
/// capture after a past-day write), and the app captures today's residue at the HealthKit ingestion
/// points. Keyed by `yyyy-MM-dd` day key. `@MainActor`, like the per-row store contracts.
@MainActor
public protocol DeviceHealthResidueStoring: AnyObject {
    /// The residue recorded for `dateKey`, or nil when there is none.
    func residue(for dateKey: String) -> DeviceHealthResidue?
    /// Every recorded residue, keyed by day — the days that exist on this device only because of
    /// what it read from HealthKit are among them.
    func allResidues() -> [String: DeviceHealthResidue]
    /// Records (or, for nil / an empty residue, removes) the residue for `dateKey`.
    ///
    /// - Returns: `false` when the change could not be persisted; the in-memory view may still
    ///   hold it. A success/failure signal, so not discardable (R7).
    func record(_ residue: DeviceHealthResidue?, for dateKey: String) -> Bool
    /// The body-profile fields this device imported from HealthKit, or nil when there are none
    /// (2026-09-23 — they used to overwrite the synced `settings.userProfile`).
    var importedBodyProfile: DeviceHealthBodyProfile? { get }
    /// Records (or, for nil / an empty profile, removes) this device's HealthKit body-profile import.
    ///
    /// - Returns: `false` when the change could not be persisted; the in-memory view may still hold
    ///   it. A success/failure signal, so not discardable (R7).
    func recordImportedBodyProfile(_ profile: DeviceHealthBodyProfile?) -> Bool
    /// Removes every recorded residue, the imported body profile, and the migration marker below —
    /// the wipe and the HealthKit opt-out. Returns `false` when something could not be removed.
    func clearAll() -> Bool
    /// Whether this device has run the one-time scrub of HealthKit values out of the rows written
    /// before the strip existed.
    var legacySyncedRowsScrubbed: Bool { get }
    /// Records that the one-time scrub completed. Returns `false` when that could not be persisted
    /// (the scrub is idempotent, so the cost is one more pass next launch).
    func markLegacySyncedRowsScrubbed() -> Bool
}

public extension FernletDay {
    /// The sleep hours on this day's log that HealthKit wrote, or nil when the hours were typed by
    /// the user (or there are none).
    ///
    /// HealthKit's hours are recognized by value: they equal the context's
    /// ``HealthDailyContext/healthKitSleepLogHours`` marker, or — for a context written before that
    /// marker existed — its `body.sleepHours`. The model cannot tell a typed value that happens to
    /// equal HealthKit's reading from HealthKit's own, so such hours count as HealthKit's: the
    /// conservative direction (they stay on this device through the residue, and off iCloud).
    var healthKitDerivedSleepHours: Double? {
        guard let hours = sleep?.hours, let context = healthContext else { return nil }
        guard context.healthKitSleepLogHours == hours || context.body?.sleepHours == hours else { return nil }
        return hours
    }

    /// Whether the day carries any value read from HealthKit: a context, HealthKit sleep hours, or
    /// a workout imported from Apple Health.
    var carriesHealthKitValues: Bool {
        healthContext != nil || healthKitDerivedSleepHours != nil || workouts.contains(where: \.isHealthImported)
    }

    /// A copy with every value READ from HealthKit removed and every value the user authored kept —
    /// the HealthKit half of the storage strip.
    ///
    /// Removes the whole `healthContext` (any field added to it later goes with it), HealthKit's
    /// sleep hours (see ``healthKitDerivedSleepHours``), and every imported workout. Keeps typed
    /// sleep hours, the user's sleep quality and note, and Fernlet-logged workouts (authored ones
    /// included — they are the user's logs even when Fernlet also wrote them to Health).
    func strippingHealthKitValues() -> FernletDay {
        var stripped = self
        stripped.sleep = sleepWithoutHealthKitHours
        stripped.healthContext = nil
        stripped.workouts = workouts.filter { !$0.isHealthImported }
        return stripped
    }

    /// The HealthKit-derived values ``strippingHealthKitValues()`` removes, for this device's
    /// residue cache; nil when there are none. The sleep marker is set only while the day's sleep
    /// hours ARE HealthKit's, so a user who typed over (or cleared) them is not overridden on read.
    var healthKitResidue: DeviceHealthResidue? {
        var context = healthContext
        context?.healthKitSleepLogHours = healthKitDerivedSleepHours
        let residue = DeviceHealthResidue(context: context, importedWorkouts: workouts.filter(\.isHealthImported))
        return residue.isEmpty ? nil : residue
    }

    /// This day with `residue` put back — the read-side inverse of the strip, applied only on the
    /// device that recorded the residue.
    ///
    /// The residue's context merges over any context the day already carries (a legacy row's); its
    /// sleep hours fill a log whose hours are empty (typed hours always win); its imported workouts
    /// are appended unless the day already holds the same id or Health sample. Idempotent: applying
    /// it twice changes nothing more.
    func overlayingHealthKitResidue(_ residue: DeviceHealthResidue?) -> FernletDay {
        guard let residue, !residue.isEmpty else { return self }
        var day = self
        if let context = residue.context {
            var merged = day.healthContext ?? context
            merged.merge(context)
            day.healthContext = merged
        }
        day.sleep = day.sleepRestoringHealthKitHours
        let knownIDs = Set(day.workouts.map(\.id))
        let knownSamples = Set(day.workouts.compactMap(\.healthKitUUID))
        day.workouts += residue.importedWorkouts.filter { workout in
            !knownIDs.contains(workout.id) && !(workout.healthKitUUID.map(knownSamples.contains) ?? false)
        }
        return day
    }

    /// The sleep log with HealthKit's hours removed. A log left with nothing but the untouched
    /// defaults (quality `.ok`, no parked token, empty note) is indistinguishable from the one
    /// HealthKit sync creates on its own, so it goes too — keeping it would plant a rating the user
    /// never gave on every other device. Any quality or note the user set keeps the log.
    private var sleepWithoutHealthKitHours: SleepLog? {
        guard var log = sleep, healthKitDerivedSleepHours != nil else { return sleep }
        log.hours = nil
        let isHealthKitShell = log.quality == .ok && log.unknownQualityToken == nil && log.note.isEmpty
        return isHealthKitShell ? nil : log
    }

    /// The sleep log with the context's HealthKit hours restored into an empty `hours` slot —
    /// creating the default log HealthKit sync would have created when there is none.
    private var sleepRestoringHealthKitHours: SleepLog? {
        guard let context = healthContext, let hours = context.healthKitSleepLogHours,
              sleep?.hours == nil else { return sleep }
        guard var log = sleep else {
            return SleepLog(hours: hours, quality: .ok, note: "", loggedAt: context.syncedAt)
        }
        log.hours = hours
        return log
    }
}
