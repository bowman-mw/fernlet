// DeviceHealthBodyProfile.swift
// FernletPersistence
//
// The body-profile half of "HealthKit information is not stored in iCloud" (owner decision
// 2026-09-23): what THIS device imported from Apple Health for the user's age, sex, height and
// weight, kept beside the day residue in the device-local cache instead of in the synced settings.

import Foundation
import FernletDomainModel

/// The body-profile fields THIS device imported from Apple Health — age, biological sex, height and
/// weight — kept device-local (in the `DeviceHealthResidueStoring` cache), never in the synced
/// `FernletSettings.userProfile`.
///
/// Until 2026-09-23 a Health import OVERWROTE `settings.userProfile`, which rides the synced blob, so
/// every weight Apple Health reported reached iCloud. Now the import is recorded here and laid over
/// the profile the user typed wherever this device uses the profile (`DiaryStore.effectiveUserProfile`:
/// nutrition targets, the profile screen, the period-visibility default). What the user types still
/// lives in settings and syncs; another device lays its OWN Health import over the same typed profile.
///
/// A field is nil when Health supplied nothing for it. Values arrive already bounded — the app records
/// them through the gateway's clamp — and ``applied(to:)`` routes them through `UserNutritionProfile`'s
/// own clamps again, so a hand-edited cache file cannot push the profile out of range either.
public nonisolated struct DeviceHealthBodyProfile: Codable, Equatable {
    /// Age in whole years, from Health's date of birth.
    public var age: Int?
    /// Biological sex, from Health's characteristic.
    public var sex: BiologicalSex?
    /// Most recent height sample, in inches.
    public var heightInches: Double?
    /// Most recent body-mass sample, in pounds.
    public var weightPounds: Double?

    /// Creates a profile from whichever fields Health supplied.
    public init(age: Int? = nil, sex: BiologicalSex? = nil, heightInches: Double? = nil, weightPounds: Double? = nil) {
        self.age = age
        self.sex = sex
        self.heightInches = heightInches
        self.weightPounds = weightPounds
    }

    /// Whether Health supplied nothing — an empty import is stored as no profile at all.
    public var isEmpty: Bool {
        age == nil && sex == nil && heightInches == nil && weightPounds == nil
    }

    /// `profile` with every field Health supplied laid over it — the profile this device uses. The
    /// typed profile's other fields (activity level, parked tokens) are untouched.
    public func applied(to profile: UserNutritionProfile) -> UserNutritionProfile {
        var effective = profile
        if let age { effective.age = min(max(age, UserNutritionProfile.ageRange.lowerBound), UserNutritionProfile.ageRange.upperBound) }
        if let sex { effective.sex = sex }
        if let heightInches, heightInches.isFinite {
            effective.heightInches = min(max(heightInches, UserNutritionProfile.heightInchesRange.lowerBound), UserNutritionProfile.heightInchesRange.upperBound)
        }
        if let weightPounds, weightPounds.isFinite {
            effective.weightPounds = min(max(weightPounds, UserNutritionProfile.weightPoundsRange.lowerBound), UserNutritionProfile.weightPoundsRange.upperBound)
        }
        return effective
    }

    /// This import without the fields the user just changed by hand — an edit of the effective
    /// profile from `before` to `after`. A field the user set themselves is theirs from then on (it is
    /// written to the synced settings), so Health's older reading must stop covering it; the next
    /// import replaces the whole record anyway (and height/weight edits are written back to Health
    /// when sharing allows).
    public func removingFieldsEdited(from before: UserNutritionProfile, to after: UserNutritionProfile) -> DeviceHealthBodyProfile {
        var remaining = self
        if before.age != after.age { remaining.age = nil }
        if before.sex != after.sex { remaining.sex = nil }
        if before.heightInches != after.heightInches { remaining.heightInches = nil }
        if before.weightPounds != after.weightPounds { remaining.weightPounds = nil }
        return remaining
    }

    /// The profile to store in the SYNCED settings after the user edited the effective profile from
    /// `before` to `after`: each field they changed takes its edited value, every other field keeps
    /// what `typed` (the settings profile) already held. A HealthKit value the user merely saw on the
    /// profile screen therefore never lands in settings — only what they typed does.
    public static func typedProfile(
        _ typed: UserNutritionProfile,
        editedFrom before: UserNutritionProfile,
        to after: UserNutritionProfile
    ) -> UserNutritionProfile {
        var result = typed
        if before.age != after.age { result.age = after.age }
        if before.sex != after.sex { result.sex = after.sex }
        if before.heightInches != after.heightInches { result.heightInches = after.heightInches }
        if before.weightPounds != after.weightPounds { result.weightPounds = after.weightPounds }
        if before.activityLevel != after.activityLevel { result.activityLevel = after.activityLevel }
        return result
    }
}
