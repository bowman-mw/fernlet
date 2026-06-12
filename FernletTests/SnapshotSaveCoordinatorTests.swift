import Combine
import Foundation
import Testing
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
            buildSnapshot: { snapshot },
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
            buildSnapshot: { snapshot },
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
            buildSnapshot: { makeSnapshot(dateKey: "2026-05-26") },
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
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
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

    @discardableResult func saveSnapshot(_ snapshot: FernletSnapshot) -> Bool {
        savedSnapshots.append(snapshot)
        return true
    }

    @discardableResult func updateDay(_ day: FernletDay, for dateKey: String, todayKey: String) -> Bool {
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
