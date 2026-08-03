import Combine
import Foundation
import Testing
import FernletDomainModel
import FernletPersistence
import StoreCore
@testable import Fernlet

@MainActor
struct SnapshotSaveCoordinatorTests {
    @Test func scheduleThenFlushPendingSavesExactlyOnce() {
        let repository = SnapshotSaveTestRepository()
        let snapshot = makeSnapshot(dateKey: "2026-05-26")
        var afterSaveCount = 0
        let coordinator = SnapshotSaveCoordinator(
            repository: repository,
            debounce: .seconds(10),
            buildSnapshot: { snapshot.forTestingSanitized },
            onAfterSave: { afterSaveCount += 1 }
        )

        coordinator.schedule()
        coordinator.flushPending()
        coordinator.flushPending()

        #expect(repository.savedSnapshots.count == 1)
        #expect(repository.savedSnapshots.first?.day.date == "2026-05-26")
        #expect(afterSaveCount == 1)
    }

    @Test func scheduleTwiceWithinDebounceSavesOnceWithLatestSnapshot() async {
        let repository = SnapshotSaveTestRepository()
        var snapshot = makeSnapshot(dateKey: "2026-05-26")
        var afterSaveCount = 0
        let coordinator = SnapshotSaveCoordinator(
            repository: repository,
            debounce: .milliseconds(20),
            buildSnapshot: { snapshot.forTestingSanitized },
            onAfterSave: { afterSaveCount += 1 }
        )

        coordinator.schedule()
        snapshot = makeSnapshot(dateKey: "2026-05-27")
        coordinator.schedule()
        await waitUntil { repository.savedSnapshots.count == 1 }

        #expect(repository.savedSnapshots.count == 1)
        #expect(repository.savedSnapshots.first?.day.date == "2026-05-27")
        #expect(afterSaveCount == 1)
    }

    @Test func subscribeRemoteRunsHandlerAfterDebounce() async {
        let repository = SnapshotSaveTestRepository()
        var handlerCalls = 0
        let coordinator = SnapshotSaveCoordinator(
            repository: repository,
            debounce: .milliseconds(20),
            buildSnapshot: { makeSnapshot(dateKey: "2026-05-26").forTestingSanitized },
            onAfterSave: {}
        )

        coordinator.subscribeRemote(remoteReloadDebounce: .milliseconds(20)) {
            handlerCalls += 1
        }
        repository.remoteChangeSubject.send()
        await waitUntil { handlerCalls == 1 }

        #expect(handlerCalls == 1)
    }

    private func makeSnapshot(dateKey: String) -> FernletSnapshot {
        FernletSnapshot(
            todayKey: dateKey,
            day: FernletDay(date: dateKey),
            settings: FernletSettings(),
            recentMeals: [],
            previousJournals: [],
            memories: [],
            goals: [],
            workshop: WorkshopData()
        )
    }

    private func waitUntil(
        // Generous headroom: these debounces are 20ms, but under full-suite CPU saturation the timer can
        // fire late. The loop returns as soon as the condition holds, so a longer ceiling never slows a
        // passing run — it only stops a saturated scheduler from tripping a false timeout.
        timeout: Duration = .seconds(10),
        // …but headroom denominated in wall clock is the wrong currency, which this 10 s ceiling
        // learned the hard way: it was not enough. This suite is `@MainActor`, and while a loaded
        // full-suite run starves it `ContinuousClock` keeps advancing, so the deadline can expire
        // having genuinely *looked* only a handful of times. Both of these tests failed exactly
        // that way at 40.3 s, inside the same starvation stall that other suites rode out. So give
        // up only once the deadline has passed AND this many observations have really been made —
        // tying the decision to scheduling received rather than to time elapsed. It still
        // terminates: `polls` only climbs, and every turn of the loop sleeps.
        minimumPolls: Int = 300,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var polls = 0
        while !condition() {
            polls += 1
            if polls >= minimumPolls, clock.now >= deadline { return }
            try? await clock.sleep(for: .milliseconds(10))
        }
    }
}

private final class SnapshotSaveTestRepository: RemoteChangePublishingRepository {
    let remoteChangeSubject = PassthroughSubject<Void, Never>()
    private(set) var savedSnapshots: [FernletSnapshot] = []

    var remoteChangePublisher: AnyPublisher<Void, Never> {
        remoteChangeSubject.eraseToAnyPublisher()
    }

    func loadSnapshot(todayKey: String) -> FernletSnapshot {
        FernletSnapshot(
            todayKey: todayKey,
            day: FernletDay(date: todayKey),
            settings: FernletSettings(),
            recentMeals: [],
            previousJournals: [],
            memories: [],
            goals: [],
            workshop: WorkshopData()
        )
    }

    @discardableResult func saveSnapshot(_ snapshot: SanitizedSnapshot) -> Bool {
        savedSnapshots.append(snapshot.snapshot)
        return true
    }

    @discardableResult func updateDay(_ day: SanitizedDay, for dateKey: String, todayKey: String) -> Bool {
        true
    }

    func storageDescription() -> String {
        "test"
    }

    func loadAllDays() -> [String: FernletDay] {
        [:]
    }

    func loadTierTwoMemories() -> [TierTwoMemoryRecord] {
        []
    }

    func loadDay(for dateKey: String, todayKey: String) -> FernletDay {
        FernletDay(date: dateKey)
    }
}
