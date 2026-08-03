import Combine
import CoreData
import CryptoKit
import Foundation
import Testing
import FernletDomainModel
import FernletLock
import FernletPersistence
import HealthKitGateway
import LocalPersistence
import PrivateHealthStore
import PrivateStoreCore
@testable import Fernlet

/// The hide gate for period (#4) + intimacy (#5). The rule these enforce: hiding is a HARD gate —
/// Fernlet reads nothing, derives nothing, holds nothing — and hiding NEVER deletes.
@MainActor
struct SensitiveSurfaceGateTests {

    private func makeStore(_ name: String) -> FernletStore {
        FernletStore(repository: LocalFernletRepository(fileURL: temporaryDatabaseURL(name)))
    }

    private func temporaryDatabaseURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString).json")
    }

    /// Puts the device-local age record above the 16+ intimacy gate.
    ///
    /// The profile age stepper no longer gates anything (it feeds nutrition targets only) — the gate
    /// reads `AgeAssuranceStore`, seeded here from Apple's declared age range. Provenance is required:
    /// a bracket without one deliberately stays `.undetermined` rather than unlocking.
    ///
    /// Every intimacy test sets this EXPLICITLY in both directions, so a record left in the shared
    /// defaults by an earlier test can never decide a later one.
    private func seedAgeMeetingIntimacyGate(_ store: FernletStore) {
        store.ageAssurance.applyDetermination(
            lowerBound: AgeGate.intimacy.minimumAge,
            upperBound: nil,
            provenance: .selfDeclared
        )
    }

    /// Puts the device-local age record below the 16+ intimacy gate (a 13–16 bracket).
    private func seedAgeBelowIntimacyGate(_ store: FernletStore) {
        store.ageAssurance.applyDetermination(
            lowerBound: AgeGate.chat.minimumAge,
            upperBound: AgeGate.intimacy.minimumAge,
            provenance: .guardianDeclared
        )
    }

    // MARK: - Visibility derivation

    @Test func periodVisibilityDerivesFromSexWhenUnset() {
        let store = makeStore("gate-derive-sex")
        store.settings.periodTrackingVisible = nil

        store.settings.userProfile.sex = .female
        #expect(store.isPeriodTrackingVisible)

        store.settings.userProfile.sex = .male
        #expect(!store.isPeriodTrackingVisible)
    }

    /// An explicit choice must outrank `sex` in BOTH directions. This matters because the HealthKit
    /// body-profile auto-import rewrites `sex` on launch — without the override winning, Health could
    /// silently overturn the user's Settings choice on the next cold start.
    @Test func explicitPeriodChoiceOutranksSex() {
        let store = makeStore("gate-explicit-outranks-sex")

        store.settings.userProfile.sex = .male
        store.settings.periodTrackingVisible = true
        #expect(store.isPeriodTrackingVisible)

        store.settings.userProfile.sex = .female
        store.settings.periodTrackingVisible = false
        #expect(!store.isPeriodTrackingVisible)
    }

    /// Turning the toggle on/off must always write an explicit value — including when the chosen value
    /// matches what `sex` would have derived — or a later `sex` change would silently overturn it.
    @Test func togglingAlwaysRecordsAnExplicitChoice() {
        let store = makeStore("gate-records-explicit")
        store.settings.userProfile.sex = .female
        store.settings.periodTrackingVisible = nil

        store.setPeriodTrackingVisible(true)

        #expect(store.settings.periodTrackingVisible == true)
        store.settings.userProfile.sex = .male
        #expect(store.isPeriodTrackingVisible)
    }

    // MARK: - Age vs preference (intimacy)

    /// Age is a floor, not a preference: someone 16+ who hides the feature and someone below the gate
    /// are both invisible, but only the former can turn it back on.
    @Test func intimacyVisibilityRequiresBothAgeAndPreference() {
        let store = makeStore("gate-intimacy-age")

        seedAgeBelowIntimacyGate(store)
        store.settings.intimacyTrackingVisible = true
        #expect(!store.isIntimacyTrackingVisible)

        seedAgeMeetingIntimacyGate(store)
        #expect(store.isIntimacyTrackingVisible)

        store.settings.intimacyTrackingVisible = false
        #expect(!store.isIntimacyTrackingVisible)
    }

    @Test func intimacyDefaultsToVisibleForAdults() {
        let store = makeStore("gate-intimacy-default")
        seedAgeMeetingIntimacyGate(store)

        // Default ON preserves today's behavior, and means the flag only ever deviates from its
        // default in the benign direction (OFF) when it rides the synced blob.
        #expect(store.settings.intimacyTrackingVisible)
        #expect(store.isIntimacyTrackingVisible)
    }

    // MARK: - Ambient HealthKit reads (G4)

    @Test func hiddenSurfacesAreSubtractedFromHealthCapabilities() {
        let store = makeStore("gate-capabilities")
        seedAgeMeetingIntimacyGate(store)
        store.settings.userProfile.sex = .female
        store.settings.periodTrackingVisible = true
        store.settings.intimacyTrackingVisible = true

        let all = Set(HealthCapability.allCases)
        // Baseline: nothing hidden, and the store must be unlocked or the lock gate confounds this.
        #expect(store.allowedHealthCapabilities(from: all).contains(.cycleTracking) == (store.lockState == .unlocked(scope: .privateHub)))

        store.settings.periodTrackingVisible = false
        #expect(!store.allowedHealthCapabilities(from: all).contains(.cycleTracking))

        store.settings.intimacyTrackingVisible = false
        #expect(!store.allowedHealthCapabilities(from: all).contains(.intimateLogging))
    }

    // MARK: - Derived leaks

    /// `HealthDailyContext.merge` coalesces with `other.x ?? x`, so simply not FETCHING a dimension
    /// freezes its last value forever. Hiding must explicitly nil it, or a day that recorded cycle
    /// data before the user hid the feature keeps serving it.
    @Test func scrubbingClearsHiddenHealthContextDimensions() {
        let store = makeStore("gate-scrub-context")
        seedAgeMeetingIntimacyGate(store)
        store.day.healthContext = HealthDailyContext(
            cycle: HealthCycleContext(),
            intimate: HealthIntimateContext(eventCount: 2)
        )

        store.settings.periodTrackingVisible = false
        store.settings.intimacyTrackingVisible = false
        store.scrubHiddenHealthContext()

        #expect(store.day.healthContext?.cycle == nil)
        #expect(store.day.healthContext?.intimate == nil)
    }

    @Test func scrubbingLeavesVisibleDimensionsAlone() {
        let store = makeStore("gate-scrub-keeps-visible")
        seedAgeMeetingIntimacyGate(store)
        store.settings.userProfile.sex = .female
        store.settings.periodTrackingVisible = true
        store.settings.intimacyTrackingVisible = true
        store.day.healthContext = HealthDailyContext(
            cycle: HealthCycleContext(),
            intimate: HealthIntimateContext(eventCount: 3)
        )

        store.scrubHiddenHealthContext()

        #expect(store.day.healthContext?.intimate?.eventCount == 3)
    }

    // MARK: - Quick log is display-only

    /// Hiding must not rewrite the user's saved quick-log layout. The filter is for rendering only —
    /// if hiding stripped the shortcut from the STORED array, un-hiding could not restore it and the
    /// user's choice would be silently destroyed.
    @Test func hidingFiltersQuickLogForDisplayWithoutMutatingStoredItems() {
        let store = makeStore("gate-quicklog-display-only")
        seedAgeMeetingIntimacyGate(store)
        let chosen: [FernletShortcut] = [.meal, .water, .intimacyTracking, .periodTracking]
        store.setQuickLogItems(chosen)

        store.settings.intimacyTrackingVisible = false
        store.settings.periodTrackingVisible = false

        let rendered = FernletShortcut.visibleQuickLog(
            store.settings.quickLogItems,
            visibility: store.sensitiveSurfaceVisibility
        )
        #expect(!rendered.contains(.intimacyTracking))
        #expect(!rendered.contains(.periodTracking))

        // The saved choice survives untouched...
        #expect(store.settings.quickLogItems.contains(.intimacyTracking))
        #expect(store.settings.quickLogItems.contains(.periodTracking))

        // ...and comes back on un-hide.
        store.settings.intimacyTrackingVisible = true
        store.settings.periodTrackingVisible = true
        let restored = FernletShortcut.visibleQuickLog(
            store.settings.quickLogItems,
            visibility: store.sensitiveSurfaceVisibility
        )
        #expect(restored.contains(.intimacyTracking))
        #expect(restored.contains(.periodTracking))
    }

    // MARK: - Regressions found by adversarial review

    /// The gate is DERIVED, so the Settings toggle is only one of its inputs — editing Gender/Age in the
    /// profile editor, or a HealthKit body-profile auto-import, flips it just as surely. Keying the
    /// scrub to `setPeriodTrackingVisible` alone left those paths hiding the UI while the data stayed
    /// live, so the scrub must be driven off the VALUE. This asserts the value moves; ContentView's
    /// `.onChange(of: store.sensitiveSurfaceVisibility)` is what acts on it.
    @Test func editingProfileSexFlipsTheDerivedGate() {
        let store = makeStore("gate-derived-flip-sex")
        store.settings.periodTrackingVisible = nil
        store.settings.userProfile.sex = .female
        #expect(store.sensitiveSurfaceVisibility.period)

        // No call to setPeriodTrackingVisible — this is the profile-editor / HealthKit-import path.
        store.settings.userProfile.sex = .male

        #expect(!store.sensitiveSurfaceVisibility.period)
    }

    @Test func agingBelowTheFloorFlipsTheDerivedIntimacyGate() {
        let store = makeStore("gate-derived-flip-age")
        seedAgeMeetingIntimacyGate(store)
        store.settings.intimacyTrackingVisible = true
        #expect(store.sensitiveSurfaceVisibility.intimacy)

        seedAgeBelowIntimacyGate(store)

        #expect(!store.sensitiveSurfaceVisibility.intimacy)
    }

    /// The scrub must be reachable from the derived flip, not only the setter — this is the exact hole
    /// that made the first fix incomplete.
    @Test func scrubbingAfterADerivedFlipClearsHealthContext() {
        let store = makeStore("gate-derived-flip-scrub")
        store.settings.periodTrackingVisible = nil
        store.settings.userProfile.sex = .female
        store.day.healthContext = HealthDailyContext(cycle: HealthCycleContext())

        store.settings.userProfile.sex = .male
        // Stands in for ContentView's .onChange(of: store.sensitiveSurfaceVisibility).
        store.scrubHiddenHealthContext()

        #expect(store.day.healthContext?.cycle == nil)
    }

    /// `allows(_:)` used a `default: true`, which failed OPEN for `.logPeriod` — a live period-LOGGING
    /// tile stayed on Home while the feature was hidden, and tapping it opened a sheet whose save was
    /// guaranteed to throw. Every gated shortcut must be enumerated.
    @Test func logPeriodShortcutIsGatedWithPeriodSurfaces() {
        let hidden = SensitiveSurfaceVisibility(intimacy: true, period: false)

        #expect(!hidden.allows(FernletShortcut.logPeriod))
        #expect(!hidden.allows(FernletShortcut.periodTracking))
        #expect(hidden.allows(FernletShortcut.intimacyTracking))
        // Ungated shortcuts are unaffected.
        #expect(hidden.allows(FernletShortcut.meal))
        #expect(hidden.allows(FernletShortcut.worryBox))
    }

    @Test func hiddenPeriodFiltersLogPeriodOutOfQuickLog() {
        let store = makeStore("gate-logperiod-quicklog")
        store.settings.periodTrackingVisible = false

        let rendered = FernletShortcut.visibleQuickLog(
            [.meal, .water, .logPeriod, .move, .sleep, .journal],
            visibility: store.sensitiveSurfaceVisibility
        )
        #expect(!rendered.contains(.logPeriod))
    }

    /// Settings > Health listed a Cycle row while hidden whose "Update data" action re-read HealthKit
    /// and wrote straight back into `healthContext.cycle` — undoing the scrub rather than merely
    /// ignoring the gate.
    @Test func hiddenSurfacesAreNotOfferedAsHealthRows() {
        let store = makeStore("gate-visible-capabilities")
        seedAgeMeetingIntimacyGate(store)
        store.settings.userProfile.sex = .female
        store.settings.periodTrackingVisible = true
        store.settings.intimacyTrackingVisible = true

        #expect(store.visibleHealthCapabilities.contains(.cycleTracking))
        #expect(store.visibleHealthCapabilities.contains(.intimateLogging))

        store.settings.periodTrackingVisible = false
        store.settings.intimacyTrackingVisible = false

        #expect(!store.visibleHealthCapabilities.contains(.cycleTracking))
        #expect(!store.visibleHealthCapabilities.contains(.intimateLogging))
        // Ungated rows survive.
        #expect(store.visibleHealthCapabilities.contains(.activityContext))
    }

    /// The merged Cycle page's four-combination truth table: the page exists while EITHER half is
    /// visible and vanishes only when both gates hide. Ungated sections are unaffected throughout.
    @Test func hubSectionsFollowVisibility() {
        // Both visible.
        #expect(PrivateHubSection.visibleSections(visibility: .all) == PrivateHubSection.allCases)

        // Period only.
        let periodOnly = PrivateHubSection.visibleSections(
            visibility: SensitiveSurfaceVisibility(intimacy: false, period: true)
        )
        #expect(periodOnly.contains(.cycle))

        // Intimacy only.
        let intimacyOnly = PrivateHubSection.visibleSections(
            visibility: SensitiveSurfaceVisibility(intimacy: true, period: false)
        )
        #expect(intimacyOnly.contains(.cycle))

        // Both hidden — the ONLY combination that removes the page.
        let neither = PrivateHubSection.visibleSections(
            visibility: SensitiveSurfaceVisibility(intimacy: false, period: false)
        )
        #expect(!neither.contains(.cycle))
        // Ungated sections are unaffected.
        #expect(neither.contains(.journal))
        #expect(neither.contains(.worryBox))
    }

    // MARK: - Mixed-version multi-device key-drop (end-to-end)

    /// End-to-end: this device resolves period+intimacy HIDDEN, then a PRE-GATE peer re-encodes the synced
    /// settings and drops the visibility keys. A fresh store on the SAME device (same device-local sidecar)
    /// loading that key-dropped blob stays HIDDEN. Against the pre-guard code the reload re-pinned period to
    /// visible (migration marker absent) and defaulted intimacy back to visible — both gates failed OPEN,
    /// and the HealthKit reads behind them (keyed off this derived value) resumed.
    @Test func mixedVersionKeyDropDoesNotReopenHiddenSurfaces() throws {
        let suiteName = "gate-keydrop-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // 1. This device explicitly hides BOTH surfaces — the setters write the device-local marker.
        let store1 = FernletStore(
            repository: LocalFernletRepository(fileURL: temporaryDatabaseURL("gate-keydrop-src")),
            sensitiveVisibilityDefaults: defaults
        )
        seedAgeMeetingIntimacyGate(store1)
        store1.setPeriodTrackingVisible(false)
        store1.setIntimacyTrackingVisible(false)
        #expect(!store1.isPeriodTrackingVisible)
        #expect(!store1.isIntimacyTrackingVisible)

        // 2. A pre-gate peer re-encodes the synced blob, dropping all three visibility keys.
        let syncedURL = temporaryDatabaseURL("gate-keydrop-synced")
        try writeKeyDroppedDatabase(to: syncedURL)

        // 3. A fresh store on the SAME device (same sidecar) loads the key-dropped blob.
        let store2 = FernletStore(
            repository: LocalFernletRepository(fileURL: syncedURL),
            sensitiveVisibilityDefaults: defaults
        )
        seedAgeMeetingIntimacyGate(store2)

        #expect(!store2.isPeriodTrackingVisible)
        #expect(!store2.isIntimacyTrackingVisible)
    }

    /// Writes a `LocalFernletRepository` database file whose settings LACK the three visibility keys —
    /// exactly what a build that predates the gate produces when it re-encodes the synced settings.
    private func writeKeyDroppedDatabase(to url: URL) throws {
        var settings = FernletSettings()
        settings.userProfile.age = 30
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var settingsObject = try #require(
            JSONSerialization.jsonObject(with: try encoder.encode(settings)) as? [String: Any])
        settingsObject.removeValue(forKey: "didMigratePeriodVisibility")
        settingsObject.removeValue(forKey: "periodTrackingVisible")
        settingsObject.removeValue(forKey: "intimacyTrackingVisible")
        let database: [String: Any] = ["settings": settingsObject]
        try JSONSerialization.data(withJSONObject: database).write(to: url)
    }

    // MARK: - Fresh-install first load vs the real account blob (final-review finding)

    /// A pre-gate database from a REAL user: months of use (onboarding completed), no visibility keys,
    /// no migration marker — what the account blob of an existing cycle-tracking user looks like when a
    /// fresh device's first sync pull finally lands.
    private func writePreGateUserDatabase(to url: URL) throws {
        var settings = FernletSettings()
        settings.hasCompletedOnboarding = true
        settings.userProfile.age = 30
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var settingsObject = try #require(
            JSONSerialization.jsonObject(with: try encoder.encode(settings)) as? [String: Any])
        settingsObject.removeValue(forKey: "didMigratePeriodVisibility")
        settingsObject.removeValue(forKey: "periodTrackingVisible")
        settingsObject.removeValue(forKey: "intimacyTrackingVisible")
        let database: [String: Any] = ["settings": settingsObject]
        try JSONSerialization.data(withJSONObject: database).write(to: url)
    }

    /// The restore-regression half of the finding: on a fresh install with iCloud, the FIRST snapshot
    /// the store loads is the repository's synthesized missing-record DEFAULT — pristine values that
    /// are NOT a determination. The old code still minted `resolved = true` from them into the sidecar,
    /// so when the real pre-gate account blob arrived via sync, the reconcile took the resolved branch
    /// and re-asserted `(nil, visible)` instead of running the pin — an existing cycle-tracking user
    /// restoring a new phone silently lost period tracking to `sex`'s `.male` default. The empty first
    /// load must stay genuinely unresolved so the blob's `apply` runs the one-time migration pin.
    /// Delivered through the REAL remote-change path (coordinator subscription → reload → apply).
    @Test func freshInstallPullingAPreGateBlobRunsThePinNotAPristineReassert() async throws {
        let suiteName = "gate-freshpull-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Fresh install: no record yet — the repository serves the synthesized default database.
        let remote = RemoteSwappableRepository(
            current: LocalFernletRepository(fileURL: temporaryDatabaseURL("gate-freshpull-empty")))
        let store = FernletStore(repository: remote, sensitiveVisibilityDefaults: defaults)
        #expect(store.settings.periodTrackingVisible == nil)
        // Flush the init-scheduled save NOW so the reload below (which flushes pending saves before
        // loading, as the real path does) can't clobber the just-arrived blob with pristine state.
        store.flushPendingSnapshotSave()

        // The real account blob arrives from sync: a pre-gate cycle-tracking user's settings.
        let blobURL = temporaryDatabaseURL("gate-freshpull-blob")
        try writePreGateUserDatabase(to: blobURL)
        remote.current = LocalFernletRepository(fileURL: blobURL)
        remote.simulateRemoteChange()

        // The remote-reload path debounces (750ms); wait for apply() to land. Gives up only once
        // the deadline has passed AND 200 observations have actually been made: this suite is
        // `@MainActor`, and while a loaded full-suite run starves it `ContinuousClock` keeps
        // advancing — a deadline-only loop expired here having genuinely looked only a handful of
        // times, failing all three assertions below with the debounce simply not yet applied.
        // Counting observations ties the give-up decision to scheduling received, not time elapsed.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        var polls = 0
        while store.settings.periodTrackingVisible != true {
            polls += 1
            if polls >= 200, clock.now >= deadline { break }
            try? await clock.sleep(for: .milliseconds(25))
        }
        #expect(store.settings.periodTrackingVisible == true,
                "the one-time pin must fire for a pre-gate blob on a genuinely fresh device")
        #expect(store.settings.didMigratePeriodVisibility)
        #expect(store.isPeriodTrackingVisible)
    }

    /// The laundering half: the fresh device's own FIRST save (before any real blob has arrived) must
    /// not stamp `didMigratePeriodVisibility = true` onto pristine values — a blob claiming an
    /// up-to-date determination it never made. A properly-resolved-HIDDEN device syncing such a blob in
    /// would trust the marker, re-open its hidden surfaces, and overwrite its own sidecar with
    /// `(nil, visible)` — permanently erasing the fail-closed defense.
    @Test func freshDeviceFirstSaveDoesNotClaimAVisibilityDetermination() throws {
        let suiteName = "gate-freshsave-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let url = temporaryDatabaseURL("gate-freshsave")
        let store = FernletStore(
            repository: LocalFernletRepository(fileURL: url),
            sensitiveVisibilityDefaults: defaults
        )
        // Any benign first-session mutation (init also schedules one for the designer-id mint).
        store.setCompanionName("Fern")
        store.flushPendingSnapshotSave()

        let database = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let settingsObject = try #require(database["settings"] as? [String: Any])
        #expect(settingsObject["didMigratePeriodVisibility"] as? Bool == false,
                "an undetermined fresh device must not write an up-to-date migration marker")

        // End-to-end: a resolved-HIDDEN device syncing this blob in keeps re-asserting hidden rather
        // than trusting it as an up-to-date determination.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            FernletSettings.self,
            from: JSONSerialization.data(withJSONObject: settingsObject))
        let hiddenElsewhere = SensitiveVisibilityResolution(
            resolved: true, periodTrackingVisible: false, intimacyTrackingVisible: false)
        let reconciled = decoded.reconcilingSensitiveVisibility(deviceLocal: hiddenElsewhere)
        #expect(reconciled.settings.periodTrackingVisible == false)
        #expect(!reconciled.settings.intimacyTrackingVisible)
    }

    // MARK: - Intimacy sealed-note decrypt seam (#5, mirrors PeriodTracker's gate)

    private func makeIntimacyStore(context: NSManagedObjectContext) -> IntimacyLogStore {
        IntimacyLogStore(repository: IntimacyLogRepository(context: context))
    }

    /// The load-bearing guarantee for #5: the gate lives at the decrypt/seal SEAM, not in a `View`. With
    /// a REAL sealed row and a valid content key present, hiding makes the store inert — `logs()`
    /// decrypts nothing (returns `[]`) and `insert()` refuses. Against the old unguarded
    /// `IntimacyLogRepository`-only path these BOTH fail: `logs()` returned the decrypted row and
    /// `insert()` sealed a new one regardless of visibility (the only guard was a `View`-body `if`).
    @Test func hiddenIntimacyStoreReadsNothingAndRefusesWrites() throws {
        let context = PrivatePersistenceController(inMemory: true).container.viewContext
        let store = makeIntimacyStore(context: context)
        let key = SymmetricKey(size: .bits256)
        store.isVisible = { true }

        // A real sealed row and a valid key — visibility is the only thing between caller and plaintext.
        try store.insert(IntimacyLog(eventDate: Date(), note: "sealed while visible"), contentKey: key)
        #expect(try store.logs(contentKey: key).count == 1)

        store.isVisible = { false }

        #expect(try store.logs(contentKey: key).isEmpty)
        #expect(throws: IntimacyTrackingHiddenError.self) {
            try store.insert(IntimacyLog(eventDate: Date(), note: "must not seal while hidden"), contentKey: key)
        }
    }

    /// Hidden must never mean deleted: the sealed row survives hiding and comes back on un-hide.
    @Test func hidingIntimacyKeepsDataAndUnhidingRestoresIt() throws {
        let context = PrivatePersistenceController(inMemory: true).container.viewContext
        let store = makeIntimacyStore(context: context)
        let key = SymmetricKey(size: .bits256)
        store.isVisible = { true }
        try store.insert(IntimacyLog(eventDate: Date(), note: "survives hiding"), contentKey: key)

        store.isVisible = { false }
        #expect(try store.logs(contentKey: key).isEmpty)

        store.isVisible = { true }
        #expect(try store.logs(contentKey: key).first?.note == "survives hiding")
    }

    /// Fail-closed DEFAULT (#2, intimacy half): a store nobody wired reads/writes nothing, so a
    /// regression of the default back to `{ true }` is caught here. The row is seeded through a
    /// briefly-visible store sharing the same context, proving the data really is present and only the
    /// default gate hides it.
    @Test func unwiredIntimacyStoreDefaultsToFailClosed() throws {
        let context = PrivatePersistenceController(inMemory: true).container.viewContext
        let key = SymmetricKey(size: .bits256)

        let seeder = makeIntimacyStore(context: context)
        seeder.isVisible = { true }
        try seeder.insert(IntimacyLog(eventDate: Date(), note: "present but gated"), contentKey: key)

        // A fresh store with NO wiring — its default gate must be closed.
        let unwired = makeIntimacyStore(context: context)
        #expect(try unwired.logs(contentKey: key).isEmpty)
        #expect(throws: IntimacyTrackingHiddenError.self) {
            try unwired.insert(IntimacyLog(eventDate: Date(), note: "blocked by default"), contentKey: key)
        }
    }

    /// Pins the funnel WIRING, not just the funnel: the store-level gate tests above stay green even if
    /// a call site regresses back to constructing a raw `IntimacyLogRepository` (the pre-#5 shape) and
    /// reads/writes around the gate. So grep the APP TARGET's sources — every intimacy touch must go
    /// through the gated `IntimacyLogStore` (whose default init builds the repository INSIDE the
    /// `PrivateHealthStore` module, the one sanctioned construction site). Mirrors the
    /// `S3BoundaryTests` grep-wall approach.
    @Test func appTargetNeverConstructsARawIntimacyLogRepository() throws {
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FernletTests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Fernlet")
        let enumerator = try #require(
            FileManager.default.enumerator(at: appRoot, includingPropertiesForKeys: nil),
            "app-target source root not found — moved?")
        var scanned = 0
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            scanned += 1
            if source.contains("IntimacyLogRepository(") {
                offenders.append(url.lastPathComponent)
            }
        }
        // Guard against a vacuous pass if the root moves or the enumerator breaks.
        #expect(scanned > 50, "app-target scan collapsed to \(scanned) files — discovery is broken")
        #expect(offenders.isEmpty,
                "raw IntimacyLogRepository constructed outside the gated IntimacyLogStore funnel: \(offenders)")
    }
}

/// A repository wrapper that delivers a "remote change" through the REAL sync path — the coordinator
/// subscription (`SnapshotSaveCoordinator.subscribeRemote`) → debounced reload → `FernletStore.apply` —
/// exactly as a CloudKit push does. `current` is swappable so a store can boot against one database
/// (the synthesized fresh-install default) and then "receive" another (the account blob).
private final class RemoteSwappableRepository: RemoteChangePublishingRepository {
    var current: FernletRepository
    private let remoteChangeSubject = PassthroughSubject<Void, Never>()

    init(current: FernletRepository) {
        self.current = current
    }

    var remoteChangePublisher: AnyPublisher<Void, Never> {
        remoteChangeSubject.eraseToAnyPublisher()
    }

    func simulateRemoteChange() {
        remoteChangeSubject.send(())
    }

    func loadSnapshot(todayKey: String) -> FernletSnapshot {
        current.loadSnapshot(todayKey: todayKey)
    }

    @discardableResult func saveSnapshot(_ snapshot: SanitizedSnapshot) -> Bool {
        current.saveSnapshot(snapshot)
    }

    @discardableResult func updateDay(_ day: SanitizedDay, for dateKey: String, todayKey: String) -> Bool {
        current.updateDay(day, for: dateKey, todayKey: todayKey)
    }

    func storageDescription() -> String {
        current.storageDescription()
    }

    func loadAllDays() -> [String: FernletDay] {
        current.loadAllDays()
    }

    func loadTierTwoMemories() -> [TierTwoMemoryRecord] {
        current.loadTierTwoMemories()
    }

    func loadDay(for dateKey: String, todayKey: String) -> FernletDay {
        current.loadDay(for: dateKey, todayKey: todayKey)
    }
}

/// Settings decode: a fresh install derives from `sex`, but an EXISTING user must never silently lose
/// period tracking just because `sex` defaults to `.male`.
struct SensitiveSurfaceGateDecodeTests {

    private func decode(_ json: String) throws -> FernletSettings {
        try JSONDecoder().decode(FernletSettings.self, from: Data(json.utf8))
    }

    /// A blob from a build that predates the gate: no `periodTrackingVisible` AND no migration marker.
    /// Such a user may have been tracking cycles for months while `sex` sat at its `.male` default, so
    /// they must be pinned visible rather than silently losing the feature. The pin now runs in
    /// `reconcilingSensitiveVisibility` gated on a FRESH device-local marker — pure decode only preserves
    /// the RAW marker (absent ⇒ false) as the reconciliation discriminator, so a mixed-version key-drop
    /// can't make the pin re-fire on a device that already resolved.
    @Test func legacySettingsPinPeriodTrackingVisibleOnAFreshDevice() throws {
        let decoded = try decode(#"{"hasCompletedOnboarding": true}"#)
        #expect(decoded.periodTrackingVisible == nil)
        #expect(decoded.didMigratePeriodVisibility == false)

        let reconciled = decoded.reconcilingSensitiveVisibility(deviceLocal: SensitiveVisibilityResolution())
        #expect(reconciled.settings.periodTrackingVisible == true)
        #expect(reconciled.settings.didMigratePeriodVisibility)
        #expect(reconciled.resolution.resolved)
        #expect(reconciled.settingsChanged)
    }

    /// Regression: the marker was originally `hasCompletedOnboarding`, which is NOT a proxy for
    /// "existing user" — it turns true for new users the moment they finish onboarding. That pinned
    /// every new user to visible on their second launch and meant the `sex` derivation never ran.
    /// A post-gate blob must leave visibility unset so it keeps deriving.
    @Test func completedOnboardingAloneDoesNotPinVisibility() throws {
        let settings = try decode(#"{"hasCompletedOnboarding": true, "didMigratePeriodVisibility": true}"#)

        #expect(settings.periodTrackingVisible == nil)
    }

    @Test func freshInstallLeavesPeriodVisibilityUnsetSoItDerivesFromSex() throws {
        // A fresh install writes the marker on its first save, so subsequent decodes must not migrate.
        let settings = try decode(#"{"didMigratePeriodVisibility": true}"#)

        #expect(settings.periodTrackingVisible == nil)
    }

    /// The migration must run at most once: a legacy user who migrates, then deliberately hides, must
    /// stay hidden rather than being re-pinned to visible on the next launch.
    @Test func migrationDoesNotOverrideALaterExplicitChoice() throws {
        let settings = try decode(#"{"didMigratePeriodVisibility": true, "periodTrackingVisible": false}"#)

        #expect(settings.periodTrackingVisible == false)
    }

    @Test func migrationDoesNotRefireOnceTheDeviceHasResolved() throws {
        // A fresh device migrates a legacy blob → pins visible and records the resolution device-locally.
        let first = try decode(#"{"hasCompletedOnboarding": true}"#)
            .reconcilingSensitiveVisibility(deviceLocal: SensitiveVisibilityResolution())
        #expect(first.settings.periodTrackingVisible == true)
        #expect(first.resolution.resolved)

        // What an up-to-date device now syncs (didMigrate encoded true), reloaded on the SAME resolved
        // device: the migration does not re-run, and nothing changes.
        let reencoded = try JSONDecoder().decode(FernletSettings.self, from: JSONEncoder().encode(first.settings))
        #expect(reencoded.didMigratePeriodVisibility)
        let second = reencoded.reconcilingSensitiveVisibility(deviceLocal: first.resolution)
        #expect(second.settings.periodTrackingVisible == true)
        #expect(!second.settingsChanged)
    }

    @Test func explicitStoredChoiceSurvivesDecode() throws {
        let hidden = try decode(#"{"hasCompletedOnboarding": true, "periodTrackingVisible": false}"#)
        #expect(hidden.periodTrackingVisible == false)

        let shown = try decode(#"{"hasCompletedOnboarding": false, "periodTrackingVisible": true}"#)
        #expect(shown.periodTrackingVisible == true)
    }

    @Test func intimacyVisibilityDefaultsToTrueWhenAbsent() throws {
        let settings = try decode(#"{}"#)

        #expect(settings.intimacyTrackingVisible)
    }

    @Test func settingsRoundTripPreservesVisibility() throws {
        var settings = FernletSettings()
        settings.periodTrackingVisible = false
        settings.intimacyTrackingVisible = false

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(FernletSettings.self, from: data)

        #expect(decoded.periodTrackingVisible == false)
        #expect(!decoded.intimacyTrackingVisible)
    }

    // MARK: - Mixed-version key-drop (the privacy-critical fail-closed guard)

    /// The headline finding: a user hides period on an up-to-date device (`periodTrackingVisible=false`
    /// syncs); a SECOND device on a PRE-GATE build decodes the synced settings and re-encodes WITHOUT the
    /// visibility keys. When the up-to-date device re-decodes that blob, `didMigratePeriodVisibility` is
    /// absent — under the OLD code the pin re-fired (nil ⇒ visible-true), silently re-opening the hidden
    /// surface and resuming the HealthKit cycle reads behind it. With the device-local marker recording
    /// HIDDEN, reconcile re-asserts hidden instead of re-pinning.
    @Test func resolvedHiddenPeriodSurvivesAPreGateKeyDrop() throws {
        let hiddenOnThisDevice = SensitiveVisibilityResolution(
            resolved: true, periodTrackingVisible: false, intimacyTrackingVisible: true)
        // The pre-gate re-encode: the synced blob has NONE of the three visibility keys.
        let dropped = try decode("{}")
        #expect(dropped.periodTrackingVisible == nil)         // OLD code pinned this to visible-true...
        #expect(dropped.didMigratePeriodVisibility == false)  // ...because the migration marker is absent.

        let reconciled = dropped.reconcilingSensitiveVisibility(deviceLocal: hiddenOnThisDevice)
        #expect(reconciled.settings.periodTrackingVisible == false)   // re-asserted hidden, NOT re-pinned
        #expect(reconciled.settings.didMigratePeriodVisibility)
        #expect(reconciled.resolution.periodTrackingVisible == false)
    }

    /// Intimacy analogue: a pre-gate build also drops `intimacyTrackingVisible`, which decodes back to its
    /// default of `true` (visible). A device that resolved intimacy HIDDEN re-asserts hidden rather than
    /// letting the default re-open it.
    @Test func resolvedHiddenIntimacySurvivesAPreGateKeyDrop() throws {
        let hiddenOnThisDevice = SensitiveVisibilityResolution(
            resolved: true, periodTrackingVisible: nil, intimacyTrackingVisible: false)
        let dropped = try decode("{}")
        #expect(dropped.intimacyTrackingVisible)  // OLD code: intimacy defaults straight back to visible.

        let reconciled = dropped.reconcilingSensitiveVisibility(deviceLocal: hiddenOnThisDevice)
        #expect(!reconciled.settings.intimacyTrackingVisible)   // re-asserted hidden
        #expect(!reconciled.resolution.intimacyTrackingVisible)
    }

    /// The normal both-new-build path must stay intact: a genuine cross-device UN-HIDE from an UP-TO-DATE
    /// peer (blob carries `didMigratePeriodVisibility: true`) still propagates to a device that had resolved
    /// hidden. The guard is a mixed-version discriminator, not a blanket hidden-latch.
    @Test func upToDatePeerUnhidePropagatesToAResolvedDevice() throws {
        let hiddenOnThisDevice = SensitiveVisibilityResolution(
            resolved: true, periodTrackingVisible: false, intimacyTrackingVisible: false)
        let unhidden = try decode(
            #"{"didMigratePeriodVisibility": true, "periodTrackingVisible": true, "intimacyTrackingVisible": true}"#)

        let reconciled = unhidden.reconcilingSensitiveVisibility(deviceLocal: hiddenOnThisDevice)
        #expect(reconciled.settings.periodTrackingVisible == true)
        #expect(reconciled.settings.intimacyTrackingVisible)
        #expect(reconciled.resolution.periodTrackingVisible == true)  // device-local record follows the agreed value
    }

    // MARK: - Pristine state is not a determination (final-review finding)

    /// The synthesized missing-record default — what a fresh install loads FIRST, before any sync pull —
    /// must never mint `resolved = true`: pristine values are the ABSENCE of a determination, and
    /// storing them would make the later real blob hit the resolved branch (a pre-gate account blob
    /// then gets a pristine re-assert instead of the migration pin; see the store-level
    /// `freshInstallPullingAPreGateBlobRunsThePinNotAPristineReassert`).
    @Test func pristineDefaultsNeverMintAResolution() {
        let synthesized = FernletSettings()
        let result = synthesized.reconcilingSensitiveVisibility(deviceLocal: SensitiveVisibilityResolution())

        #expect(!result.resolution.resolved)
        #expect(!result.settingsChanged)
        #expect(result.settings.periodTrackingVisible == nil)
        #expect(!result.settings.didMigratePeriodVisibility)
    }

    /// The laundering guard at the unit level: a resolved device whose values ARE the pristine defaults
    /// re-asserts them into a key-dropped blob WITHOUT stamping the migration marker — a reconstruction
    /// adds no information and must not masquerade as an up-to-date write, or a hidden peer would trust
    /// the marker into re-opening. A real deviation still stamps and saves (covered by
    /// `resolvedHiddenPeriodSurvivesAPreGateKeyDrop` above).
    @Test func pristineReassertDoesNotStampTheMigrationMarker() throws {
        let pristineResolved = SensitiveVisibilityResolution(
            resolved: true, periodTrackingVisible: nil, intimacyTrackingVisible: true)
        let dropped = try decode("{}")

        let reconciled = dropped.reconcilingSensitiveVisibility(deviceLocal: pristineResolved)
        #expect(!reconciled.settings.didMigratePeriodVisibility)
        #expect(!reconciled.settingsChanged)
        #expect(reconciled.settings.periodTrackingVisible == nil)
        #expect(reconciled.settings.intimacyTrackingVisible)
    }
}
