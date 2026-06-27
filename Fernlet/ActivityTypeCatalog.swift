import Foundation
import HealthKit
import FernletDomainModel

enum ActivityTypeCatalog {
    static let allTypes: [WorkoutActivityType] = WorkoutActivityType.allCases

    static func search(_ query: String) -> [WorkoutActivityType] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return allTypes }

        return allTypes.filter { type in
            type.displayName.lowercased().contains(trimmed)
                || type.rawValue.lowercased().contains(trimmed)
        }
    }

    static func hkActivityType(for type: WorkoutActivityType) -> HKWorkoutActivityType {
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

    static func fernletType(for hk: HKWorkoutActivityType) -> WorkoutActivityType {
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
