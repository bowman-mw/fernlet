import Foundation
import Testing
import CloudKitSync
import DiaryStore
import FernletDomainModel
import FernletPersistence
import HealthKitGateway
@testable import Fernlet

/// "HealthKit information shouldn't be stored in iCloud" (owner, 2026-09-23) — the body-profile half,
/// healthkit-local's residual 1. A HealthKit import of age, sex, height and weight used to OVERWRITE
/// `settings.userProfile`, which rides the synced blob; now it is recorded device-locally and laid over
/// the profile the user typed. Pins: an import never reaches the synced settings (in memory or in the
/// repository); a typed value still does; the overlay feeds the targets, the profile screen and the
/// period-visibility default; it stays on the device that read it; the opt-out and the wipe clear it.
@MainActor
struct HealthImportedBodyProfileTests {

    /// What a HealthKit read might bring back — every field different from the typed defaults.
    private static let healthReading = HealthBodyProfile(age: 44, sex: .female, heightInches: 63, weightPounds: 142)

    // MARK: - Never synced

    /// The import changes what this device USES and nothing the store SAVES: the in-memory settings
    /// and the repository's persisted settings both keep the typed profile.
    @Test func anImportNeverReachesTheSyncedSettings() throws {
        let built = makeTestStoreWithRepositories()
        let store = built.store
        let typed = store.settings.userProfile

        store.recordHealthImportedBodyProfile(Self.healthReading)
        store.addBottle()   // user content, so there is something to save
        #expect(store.flushPendingSnapshotSave())

        #expect(store.settings.userProfile == typed)
        let persisted = built.repository.loadSnapshot(todayKey: store.todayKey).settings.userProfile
        #expect(persisted == typed, "the synced settings must carry only what the user typed")
        #expect(persisted.weightPounds != 142 && persisted.sex != .female)
    }

    /// What the user types on the profile screen is theirs: it lands in the synced settings — and a
    /// HealthKit value they merely saw on that screen (the height here) does not come along.
    @Test func aTypedEditStillSyncsAndCarriesNoHealthValueWithIt() throws {
        let built = makeTestStoreWithRepositories()
        let store = built.store
        let typedHeight = store.settings.userProfile.heightInches
        store.recordHealthImportedBodyProfile(Self.healthReading)

        var edited = store.effectiveUserProfile   // what the profile screen shows
        edited.weightPounds = 150
        store.applyEditedBodyProfile(edited)
        #expect(store.flushPendingSnapshotSave())

        let persisted = built.repository.loadSnapshot(todayKey: store.todayKey).settings.userProfile
        #expect(persisted.weightPounds == 150, "the typed weight syncs")
        #expect(persisted.heightInches == typedHeight, "Health's height, only shown on screen, does not")
        #expect(store.effectiveUserProfile.weightPounds == 150, "the edit wins over Health's older reading")
        #expect(store.effectiveUserProfile.heightInches == 63, "Health's height still applies on this device")
        #expect(store.diary.healthImportedBodyProfile?.weightPounds == nil)
    }

    // MARK: - Used on this device

    /// The overlay feeds everything computed from the body: the targets, the settings-based editor
    /// preview, and the profile screen.
    @Test func theOverlayFeedsTheTargetsAndTheProfileScreen() {
        let store = makeTestStore()
        let typedTargets = store.nutritionTargets

        store.recordHealthImportedBodyProfile(Self.healthReading)

        var expected = store.settings
        expected.userProfile = Self.healthReading.applying(to: store.settings.userProfile)
        #expect(store.nutritionTargets == NutritionTargetCalculator.targets(for: expected))
        #expect(store.nutritionTargets != typedTargets)
        #expect(store.effectiveUserProfile == expected.userProfile)
        #expect(store.effectiveSettings.userProfile == expected.userProfile)
    }

    /// The period surfaces' default follows the EFFECTIVE sex, as it did when the import overwrote
    /// the profile — without the typed (synced) sex changing.
    @Test func thePeriodVisibilityDefaultFollowsTheImportedSex() {
        let store = makeTestStore()
        store.settings.periodTrackingVisible = nil
        store.settings.userProfile.sex = .male
        #expect(store.isPeriodTrackingVisible == false)

        store.recordHealthImportedBodyProfile(HealthBodyProfile(sex: .female))

        #expect(store.isPeriodTrackingVisible)
        #expect(store.settings.userProfile.sex == .male)
    }

    /// The import survives a relaunch on THIS device (same cache) and does not exist on another
    /// device reading the same synced rows with its own cache.
    @Test func theImportStaysOnTheDeviceThatReadIt() throws {
        let cache = InMemoryDeviceHealthResidueStore()
        let first = makeTestStoreWithRepositories(deviceHealthResidueStore: cache)
        first.store.recordHealthImportedBodyProfile(Self.healthReading)
        first.store.addBottle()
        #expect(first.store.flushPendingSnapshotSave())

        let relaunched = makeStoreSharingStores(repository: first.repository, narratives: first.narratives, deviceHealthResidueStore: cache)
        #expect(relaunched.effectiveUserProfile.weightPounds == 142)

        let otherDevice = makeStoreSharingStores(repository: first.repository, narratives: first.narratives)
        #expect(otherDevice.effectiveUserProfile == otherDevice.settings.userProfile)
        #expect(otherDevice.effectiveUserProfile.weightPounds != 142)
    }

    // MARK: - Cleared

    /// "Delete everything" drops it from memory and from the device cache.
    @Test func deleteEverythingClearsTheImport() {
        let cache = InMemoryDeviceHealthResidueStore()
        let store = makeTestStore(deviceHealthResidueStore: cache)
        store.recordHealthImportedBodyProfile(Self.healthReading)

        _ = store.resetAll()

        #expect(store.diary.healthImportedBodyProfile == nil)
        #expect(cache.importedBodyProfile == nil)
        #expect(store.effectiveUserProfile == store.settings.userProfile)
    }

    /// The HealthKit opt-out empties the cache (the cleaner's `clearAll`); the master-off hook then
    /// drops the in-memory copy so the typed profile is back in effect at once.
    @Test func theHealthOptOutClearsTheImport() {
        let cache = InMemoryDeviceHealthResidueStore()
        let store = makeTestStore(deviceHealthResidueStore: cache)
        store.recordHealthImportedBodyProfile(Self.healthReading)

        #expect(cache.clearAll())
        store.reloadHealthImportedBodyProfile()

        #expect(store.diary.healthImportedBodyProfile == nil)
        #expect(store.effectiveUserProfile == store.settings.userProfile)
    }

    // MARK: - The device cache file

    /// The file-backed cache keeps the import across instances, a file written before the field
    /// existed still decodes, and `clearAll` removes it with the rest.
    @Test func theFileCacheKeepsTheImportAndClearsItWithTheRest() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fernlet.tests.bodyProfile.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = DeviceHealthBodyProfile(imported: Self.healthReading)

        #expect(FileDeviceHealthResidueStore(directory: directory).recordImportedBodyProfile(profile))
        let reopened = FileDeviceHealthResidueStore(directory: directory)
        #expect(reopened.importedBodyProfile == profile)
        #expect(reopened.clearAll())
        #expect(FileDeviceHealthResidueStore(directory: directory).importedBodyProfile == nil)

        let legacy = Data(#"{"legacySyncedRowsScrubbed":true,"days":{}}"#.utf8)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try legacy.write(to: directory.appendingPathComponent(FileDeviceHealthResidueStore.fileName))
        let legacyStore = FileDeviceHealthResidueStore(directory: directory)
        #expect(legacyStore.legacySyncedRowsScrubbed, "a pre-profile file decodes, marker intact")
        #expect(legacyStore.importedBodyProfile == nil)
    }

    /// The device record keeps only what Health supplied, bounded the way the old import bounded it.
    @Test func theDeviceRecordKeepsOnlySuppliedFieldsWithinBounds() {
        let partial = DeviceHealthBodyProfile(imported: HealthBodyProfile(weightPounds: 900))
        #expect(partial.age == nil && partial.sex == nil && partial.heightInches == nil)
        #expect(partial.weightPounds == 500, "the gateway's 70–500 lb clamp applies to the recorded value")
        #expect(DeviceHealthBodyProfile(imported: HealthBodyProfile()).isEmpty)
    }
}
