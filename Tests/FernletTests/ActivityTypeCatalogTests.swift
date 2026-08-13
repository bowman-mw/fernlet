import Foundation
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
