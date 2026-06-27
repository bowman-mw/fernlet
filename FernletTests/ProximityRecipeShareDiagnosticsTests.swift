import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

struct ProximityRecipeShareDiagnosticsTests {
    @Test func appendingKeepsNewestEventsWhenCapped() {
        let events = (0..<45).map { index in
            ProximityRecipeShareDiagnosticEvent(
                id: UUID(),
                timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
                message: "event-\(index)"
            )
        }

        let capped = events.reduce(into: [ProximityRecipeShareDiagnosticEvent]()) { result, event in
            result = ProximityRecipeShareDiagnostics.appending(event, to: result, maxCount: 40)
        }

        #expect(capped.count == 40)
        #expect(capped.first?.message == "event-5")
        #expect(capped.last?.message == "event-44")
    }

    @Test func appendingPreservesEventOrder() {
        let first = ProximityRecipeShareDiagnosticEvent(
            timestamp: Date(timeIntervalSince1970: 10),
            message: "Recipe share discovery started."
        )
        let second = ProximityRecipeShareDiagnosticEvent(
            timestamp: Date(timeIntervalSince1970: 11),
            message: "Discovered Taylor."
        )

        let events = ProximityRecipeShareDiagnostics.appending(
            second,
            to: ProximityRecipeShareDiagnostics.appending(first, to: [])
        )

        #expect(events.map(\.message) == [
            "Recipe share discovery started.",
            "Discovered Taylor."
        ])
    }

    @Test func appendingWithZeroCapacityDropsEvents() {
        let event = ProximityRecipeShareDiagnosticEvent(message: "Ignored")

        let events = ProximityRecipeShareDiagnostics.appending(event, to: [], maxCount: 0)

        #expect(events.isEmpty)
    }
}
