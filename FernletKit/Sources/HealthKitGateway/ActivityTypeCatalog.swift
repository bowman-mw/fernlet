import Foundation
import HealthKit
import FernletDomainModel

/// Namespace for the two-way mapping between Fernlet's `WorkoutActivityType` and HealthKit's
/// `HKWorkoutActivityType`, plus a simple text search over the catalog.
///
/// The activity-picker UI uses ``search(_:)`` to filter the catalog; ``HealthKitService/saveWorkout(_:)``
/// (via `makeConfiguration`) uses ``hkActivityType(for:)`` when writing a workout to Apple Health, and
/// ``WorkoutHealthKitSync`` uses ``fernletType(for:)`` when importing a Health sample back into a local
/// row. The mapping is deliberately lossy in spots (e.g. both `.cycling` and `.indoorCycling` write as
/// HealthKit `.cycling`; the indoor variant is recovered on import from the `HKMetadataKeyIndoorWorkout`
/// metadata, not from the activity type), and any HealthKit activity Fernlet doesn't model falls back to
/// `.other`.
public enum ActivityTypeCatalog {
    /// Every Fernlet activity type, in `WorkoutActivityType.allCases` order — the unfiltered catalog.
    static let allTypes: [WorkoutActivityType] = WorkoutActivityType.allCases

    /// Case-insensitive substring search over display names and raw values.
    ///
    /// - Parameter query: Free text from the activity picker; a blank/whitespace query returns the
    ///   whole catalog.
    /// - Returns: The matching activity types, preserving catalog order.
    public static func search(_ query: String) -> [WorkoutActivityType] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return allTypes }

        return allTypes.filter { type in
            type.displayName.lowercased().contains(trimmed)
                || type.rawValue.lowercased().contains(trimmed)
        }
    }

    /// Maps a Fernlet activity type to the HealthKit activity type used when writing the workout.
    ///
    /// Total over `WorkoutActivityType`; variants HealthKit does not distinguish collapse (indoor
    /// cycling → `.cycling`, pool/open-water swimming → `.swimming`) and rely on workout-configuration
    /// location metadata to preserve the distinction.
    public static func hkActivityType(for type: WorkoutActivityType) -> HKWorkoutActivityType {
        switch type {
        case .running: .running
        case .walking: .walking
        case .hiking: .hiking
        case .cycling, .indoorCycling: .cycling
        case .yoga: .yoga
        case .pilates: .pilates
        case .barre: .barre
        case .dance: .cardioDance
        case .socialDance: .socialDance
        case .swimmingPool, .swimmingOpenWater: .swimming
        case .rowing: .rowing
        case .elliptical: .elliptical
        case .stairClimbing: .stairClimbing
        case .stairs: .stairs
        case .hiit: .highIntensityIntervalTraining
        case .kickboxing: .kickboxing
        case .martialArts: .martialArts
        case .climbing: .climbing
        case .jumpRope: .jumpRope
        case .tennis: .tennis
        case .basketball: .basketball
        case .soccer: .soccer
        case .pickleball: .pickleball
        case .badminton: .badminton
        case .tableTennis: .tableTennis
        case .racquetball: .racquetball
        case .squash: .squash
        case .coreTraining: .coreTraining
        case .flexibility: .flexibility
        case .mindAndBody: .mindAndBody
        case .taiChi: .taiChi
        case .functionalStrengthTraining: .functionalStrengthTraining
        case .traditionalStrengthTraining: .traditionalStrengthTraining
        case .crossTraining: .crossTraining
        case .mixedCardio: .mixedCardio
        case .preparationAndRecovery: .preparationAndRecovery
        case .cooldown: .cooldown
        case .other: .other
        }
    }

    /// Maps a HealthKit activity type to the Fernlet activity type used when importing a Health sample.
    ///
    /// The inverse of ``hkActivityType(for:)`` where one exists; ambiguous HealthKit types resolve to
    /// their outdoor/pool base case (`.cycling`, `.swimmingPool`) and every unmodeled HealthKit
    /// activity — including future cases — falls back to `.other`.
    public static func fernletType(for hk: HKWorkoutActivityType) -> WorkoutActivityType {
        switch hk {
        case .running: .running
        case .walking: .walking
        case .hiking: .hiking
        case .cycling: .cycling
        case .yoga: .yoga
        case .pilates: .pilates
        case .barre: .barre
        case .cardioDance: .dance
        case .socialDance: .socialDance
        case .swimming: .swimmingPool
        case .rowing: .rowing
        case .elliptical: .elliptical
        case .stairClimbing: .stairClimbing
        case .stairs: .stairs
        case .highIntensityIntervalTraining: .hiit
        case .kickboxing: .kickboxing
        case .martialArts: .martialArts
        case .climbing: .climbing
        case .jumpRope: .jumpRope
        case .tennis: .tennis
        case .basketball: .basketball
        case .soccer: .soccer
        case .pickleball: .pickleball
        case .badminton: .badminton
        case .tableTennis: .tableTennis
        case .racquetball: .racquetball
        case .squash: .squash
        case .coreTraining: .coreTraining
        case .flexibility: .flexibility
        case .mindAndBody: .mindAndBody
        case .taiChi: .taiChi
        case .functionalStrengthTraining: .functionalStrengthTraining
        case .traditionalStrengthTraining: .traditionalStrengthTraining
        case .crossTraining: .crossTraining
        case .mixedCardio: .mixedCardio
        case .preparationAndRecovery: .preparationAndRecovery
        case .cooldown: .cooldown
        case .other: .other
        default: .other
        }
    }
}
