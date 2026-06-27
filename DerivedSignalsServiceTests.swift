import Foundation
import Testing
@testable import Fernlet

@MainActor
struct DerivedSignalsServiceTests {

    @Test func rebuildProducesSignalsMatchingRebuilderDirectly() {
        let service = DerivedSignalsService()
        let todayKey = FernletDate.dayKey(for: Date())
        let allDays: [String: FernletDay] = [todayKey: FernletDay(date: todayKey)]

        service.rebuild(allDays: allDays, todayKey: todayKey)

        let expected = DerivedSignalsRebuilder.rebuild(allDays: allDays, todayKey: todayKey)
        #expect(service.derivedSignals.count == expected.count)
        #expect(service.derivedSignals.map(\.signalName) == expected.map(\.signalName))
    }

    @Test func rebuildWithEmptyDaysProducesEmptyOrDefaultSignals() {
        let service = DerivedSignalsService()
        let todayKey = FernletDate.dayKey(for: Date())
        service.rebuild(allDays: [:], todayKey: todayKey)
        // Empty input should not crash; signals will have "insufficient data" values.
        let expected = DerivedSignalsRebuilder.rebuild(allDays: [:], todayKey: todayKey)
        #expect(service.derivedSignals.count == expected.count)
    }

    @Test func scheduleDeferredRebuildRunsOnce() async {
        let service = DerivedSignalsService()
        let todayKey = FernletDate.dayKey(for: Date())
        let allDays: [String: FernletDay] = [todayKey: FernletDay(date: todayKey)]

        var providerCallCount = 0
        service.scheduleDeferredRebuild(
            allDaysProvider: {
                providerCallCount += 1
                return allDays
            },
            todayKey: todayKey
        )
        service.scheduleDeferredRebuild(
            allDaysProvider: {
                providerCallCount += 1
                return allDays
            },
            todayKey: todayKey
        )

        service.flushDeferredRebuild()

        #expect(providerCallCount == 1)
    }
}
