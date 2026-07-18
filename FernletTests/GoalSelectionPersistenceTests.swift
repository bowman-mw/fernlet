import Foundation
import Testing
import FernletDomainModel
import FernletPersistence
import CloudKitSync
@testable import Fernlet

/// Finding #1: selecting a goal preset must persist. The Settings/onboarding cards route the pick
/// through `FernletStore.setSelectedGoal`, which sets the keypath then schedules the debounced snapshot
/// save (mirroring `setHidePredictions`). The old `$store.settings.selectedGoal` binding mutated memory
/// but never scheduled a save, so the choice silently reverted on the next launch.
@MainActor
struct GoalSelectionPersistenceTests {

    @Test func selectingAGoalSchedulesASaveAndSurvivesReload() {
        let (store, repository, _) = makeTestStoreWithRepositories()
        #expect(store.settings.selectedGoal != .strength)   // wellness is the seeded default

        store.setSelectedGoal(.strength)
        #expect(store.settings.selectedGoal == .strength)    // in-memory value updated

        // flushPendingSnapshotSave() is a no-op unless a save was scheduled — so without the fix
        // (a bare keypath binding, no schedule) the reload below would show the default, not .strength.
        store.flushPendingSnapshotSave()

        let reloaded = repository.loadSnapshot(todayKey: store.todayKey).settings.selectedGoal
        #expect(reloaded == .strength)
    }
}
