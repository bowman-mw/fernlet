import Foundation
import DiaryStore
import FernletDomainModel
import FernletFoundation
import FernletPersistence
import HealthKitGateway

/// The body-profile half of "HealthKit information is not stored in iCloud" (owner decision
/// 2026-09-23 — healthkit-local's residual 1): a HealthKit import of the user's age, sex, height and
/// weight no longer overwrites `settings.userProfile`, which rides the synced blob.
///
/// Imports are recorded device-locally (`DiaryStore.recordHealthImportedBodyProfile`, in the same
/// backup-excluded cache as the day residue) and laid over the profile the user typed wherever this
/// device uses it — `effectiveUserProfile`: the nutrition targets, the profile screen, and the
/// period-visibility default. What the user types still goes into settings and syncs, so an edit on
/// the profile screen is split: the fields the user changed become theirs (typed, synced, and no
/// longer covered by Health's older reading); every other field stays as it was in settings.
///
/// Cleared with the rest of the cache by the HealthKit opt-out (`CoreDataHealthKitCacheCleaner`,
/// plus ``reloadHealthImportedBodyProfile()`` so this session stops using it at once) and by
/// "delete everything" (`resetAll` → `resetDiary` + the cache's `clearAll`). Profiles an older build
/// already synced are left as they are — nothing can tell a typed value from an imported one there.
extension FernletStore {
    /// The body profile in effect on this device: typed (synced) with this device's HealthKit import
    /// laid over it. Read this — never `settings.userProfile` — for anything computed from the body.
    var effectiveUserProfile: UserNutritionProfile { diary.effectiveUserProfile }

    /// `settings` with ``effectiveUserProfile`` in place — for computations that take whole settings
    /// (the target editor's "automatic" preview). Never write it back.
    var effectiveSettings: FernletSettings { diary.effectiveSettings }

    /// Records a HealthKit body-profile import on THIS device only — the replacement for the old
    /// `settings.userProfile = health.applying(to: …)`, which synced it. A cache that refused the
    /// write is audited; the import still applies for this session.
    func recordHealthImportedBodyProfile(_ health: HealthBodyProfile) {
        recordDeviceBodyProfile(DeviceHealthBodyProfile(imported: health))
    }

    /// Applies an edit the user made on the profile screen, which shows (and hands back) the
    /// EFFECTIVE profile. Only the fields they changed are written to the synced settings — a
    /// HealthKit value they merely looked at never lands there — and those fields stop being covered
    /// by Health's older reading.
    func applyEditedBodyProfile(_ edited: UserNutritionProfile) {
        let before = diary.effectiveUserProfile
        if let imported = diary.healthImportedBodyProfile {
            recordDeviceBodyProfile(imported.removingFieldsEdited(from: before, to: edited))
        }
        settings.userProfile = DeviceHealthBodyProfile.typedProfile(settings.userProfile, editedFrom: before, to: edited)
    }

    /// Drops the in-memory import after the HealthKit opt-out emptied the cache, so the typed profile
    /// is back in effect at once (wired to the master switch turning off, beside the workout observer).
    func reloadHealthImportedBodyProfile() {
        diary.reloadHealthImportedBodyProfile()
    }

    /// Hands a device-local profile to the diary, auditing a refused cache write (R7: named, not
    /// dropped — the cost is the import lasting only until relaunch).
    private func recordDeviceBodyProfile(_ profile: DeviceHealthBodyProfile?) {
        guard diary.recordHealthImportedBodyProfile(profile) else {
            PersistenceFailureAudit.record("healthResidue.bodyProfile.recordFailed")
            return
        }
    }
}

/// The bridge from the gateway's import type to the device-local record — here in the app target,
/// the one place that sees both `HealthKitGateway` and `FernletPersistence`.
extension DeviceHealthBodyProfile {
    /// The device-local record of one HealthKit import: only the fields Health supplied, each bounded
    /// exactly as the old in-settings import bounded it (`HealthBodyProfile.applying(to:)`'s clamps).
    init(imported health: HealthBodyProfile) {
        let bounded = health.applying(to: UserNutritionProfile())
        self.init(
            age: health.age == nil ? nil : bounded.age,
            sex: health.sex,
            heightInches: health.heightInches == nil ? nil : bounded.heightInches,
            weightPounds: health.weightPounds == nil ? nil : bounded.weightPounds
        )
    }
}
