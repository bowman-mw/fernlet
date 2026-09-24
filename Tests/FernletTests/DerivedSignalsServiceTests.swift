import Foundation
import LocalPersistence
import FernletFoundation
import Testing
import FernletDomainModel
import StoreCore
@testable import Fernlet

@MainActor
struct DerivedSignalsServiceTests {

    @Test func rebuildProducesSignalsMatchingRebuilderDirectly() {
        let service = DerivedSignalsService()
        let todayKey = FernletDate.dayKey(for: Date())
        let allDays: [String: FernletDay] = [todayKey: FernletDay(date: todayKey)]

        service.rebuild(allDays: allDays, todayKey: todayKey, isSickToday: false)

        let expected = DerivedSignalsRebuilder.rebuild(allDays: allDays, todayKey: todayKey)
        #expect(service.derivedSignals.count == expected.count)
        #expect(service.derivedSignals.map(\.signalName) == expected.map(\.signalName))
    }

    @Test func rebuildWithEmptyDaysProducesEmptyOrDefaultSignals() {
        let service = DerivedSignalsService()
        let todayKey = FernletDate.dayKey(for: Date())
        service.rebuild(allDays: [:], todayKey: todayKey, isSickToday: false)
        // Empty input should not crash; signals will have "insufficient data" values.
        let expected = DerivedSignalsRebuilder.rebuild(allDays: [:], todayKey: todayKey)
        #expect(service.derivedSignals.count == expected.count)
    }

    /// Spec §6a: the unwell flag reaches the factory through the service's REQUIRED parameter and
    /// forces readiness to "needs rest".
    @Test func rebuildForwardsTodaysUnwellFlag() {
        let service = DerivedSignalsService()
        let todayKey = FernletDate.dayKey(for: Date())
        let allDays: [String: FernletDay] = [todayKey: FernletDay(date: todayKey)]

        service.rebuild(allDays: allDays, todayKey: todayKey, isSickToday: true)

        #expect(service.derivedSignals.first { $0.signalName == "intensityReadiness" }?.value == "needs rest")
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
            isSickTodayProvider: { false },
            todayKey: todayKey
        )
        service.scheduleDeferredRebuild(
            allDaysProvider: {
                providerCallCount += 1
                return allDays
            },
            isSickTodayProvider: { false },
            todayKey: todayKey
        )

        service.flushDeferredRebuild()

        #expect(providerCallCount == 1)
    }

    /// The deferred launch rebuild reads the unwell flag when it FIRES, not when it was scheduled —
    /// a user who marks today unwell in the first moments after launch must not get it overwritten.
    @Test func deferredRebuildReadsTheUnwellFlagAtFireTime() {
        let service = DerivedSignalsService()
        let todayKey = FernletDate.dayKey(for: Date())
        let allDays: [String: FernletDay] = [todayKey: FernletDay(date: todayKey)]
        let flag = UnwellFlag()

        service.scheduleDeferredRebuild(
            allDaysProvider: { allDays },
            isSickTodayProvider: { flag.isSick },
            todayKey: todayKey
        )
        flag.isSick = true
        service.flushDeferredRebuild()

        #expect(service.derivedSignals.first { $0.signalName == "intensityReadiness" }?.value == "needs rest")
    }
}

/// A mutable unwell flag the deferred-rebuild provider reads by reference, so the test can flip it
/// after scheduling (a captured `var` cannot be mutated after capture by a `@MainActor` closure).
@MainActor
private final class UnwellFlag {
    var isSick = false
}
