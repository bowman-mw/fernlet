import Foundation
import HealthKit
import Testing
import FernletDomainModel
import HealthKitGateway
@testable import Fernlet

struct ActivityTypeCatalogTests {
    @Test func allActivityTypesRoundTripCodable() throws {
        for type in WorkoutActivityType.allCases {
            let data = try JSONEncoder().encode(type)
            let decoded = try JSONDecoder().decode(WorkoutActivityType.self, from: data)

            #expect(decoded == type)
        }
    }

    @Test func everyActivityTypeHasDisplayNameAndSymbol() {
        for type in WorkoutActivityType.allCases {
            #expect(!type.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(!type.systemImage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @Test func hkMappingRoundTrips() {
        let metadataAliases: Set<WorkoutActivityType> = [.indoorCycling, .swimmingOpenWater]

        for type in WorkoutActivityType.allCases where type != .other && !metadataAliases.contains(type) {
            let hkType = ActivityTypeCatalog.hkActivityType(for: type)
            let decoded = ActivityTypeCatalog.fernletType(for: hkType)

            #expect(decoded == type)
        }
    }

    /// The sports round 2 added (R5) write to Apple Health as their own types, and a Health workout of
    /// one of them imports as that sport rather than Other.
    @Test func theAddedSportsMapToTheirOwnHealthTypes() {
        let pairs: [(WorkoutActivityType, HKWorkoutActivityType)] = [
            (.boxing, .boxing), (.wrestling, .wrestling), (.volleyball, .volleyball),
            (.americanFootball, .americanFootball), (.baseball, .baseball), (.softball, .softball),
            (.hockey, .hockey), (.rugby, .rugby), (.lacrosse, .lacrosse), (.golf, .golf),
            (.downhillSkiing, .downhillSkiing), (.crossCountrySkiing, .crossCountrySkiing),
            (.snowboarding, .snowboarding), (.skating, .skatingSports), (.surfing, .surfingSports),
        ]
        for (type, hk) in pairs {
            let written = ActivityTypeCatalog.hkActivityType(for: type)
            let imported = ActivityTypeCatalog.fernletType(for: hk)
            #expect(written == hk, "\(type) writes as its own Health type")
            #expect(imported == type, "Health type \(hk.rawValue) imports as \(type)")
        }
    }

    @Test func searchMatchesByDisplayName() {
        #expect(ActivityTypeCatalog.search("yoga").contains(.yoga))
    }

    @Test func searchIsCaseInsensitive() {
        #expect(ActivityTypeCatalog.search("YOGA") == ActivityTypeCatalog.search("yoga"))
    }

    @Test func searchEmptyReturnsAll() {
        #expect(ActivityTypeCatalog.search("") == WorkoutActivityType.allCases)
    }

    @Test func everyActivityTypeMapsToFernletCategory() {
        for type in WorkoutActivityType.allCases {
            #expect(WorkoutType.allCases.contains(type.fernletCategory))
        }
    }
}
