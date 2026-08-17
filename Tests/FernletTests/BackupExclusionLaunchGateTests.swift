//
//  BackupExclusionLaunchGateTests.swift
//  FernletTests
//
//  Security-hardening Phase 6: the default-on backup-exclusion launch gate (fresh installs
//  default excluded, existing installs get a one-time honest prompt, nobody is silently
//  flipped) and the LocalFernletRepository day-blob exclusion that closes the last local
//  Fernlet-data file the Privacy & Data toggle's exclusion did not reach (the legacy
//  pre-migration JSON blob; live history is Fernlet.sqlite, excluded separately at store load).
//

import Foundation
import FernletFoundation
import FernletDomainModel
import FernletPersistence
import LocalPersistence
import Testing
@testable import Fernlet

/// Pins `BackupExclusionLaunchGate`'s fresh-vs-existing classification and its three outcomes:
/// the silent fresh-install excluded default, the record-only path for already-excluded existing
/// installs, and the exactly-once prompt for existing included installs. Isolated fixtures
/// throughout — a unique keychain service per test and a private `UserDefaults` suite for the
/// prior-use marker — so no test touches the simulator's real preference blob or first-run state.
@MainActor
@Suite(.serialized)
struct BackupExclusionLaunchGateTests {

    /// The pure decision table: `choiceMade` always wins, no prior use means fresh, and prior use
    /// splits on the currently-stored exclusion value. (`priorUse` is the OR the gate computes
    /// over the marker, the legacy onboarding evidence, and persisted-blob presence.)
    @Test func decisionTableCoversEveryCohort() {
        var chosen = StoragePreferences()
        chosen.backupExclusionChoiceMade = true
        #expect(BackupExclusionLaunchGate.decision(preferences: chosen, priorUse: true) == .alreadyChosen)
        #expect(BackupExclusionLaunchGate.decision(preferences: chosen, priorUse: false) == .alreadyChosen)

        let undecided = StoragePreferences()
        #expect(BackupExclusionLaunchGate.decision(preferences: undecided, priorUse: false) == .adoptExcludedDefault)
        #expect(BackupExclusionLaunchGate.decision(preferences: undecided, priorUse: true) == .promptExistingInstall)

        var alreadyExcluded = StoragePreferences()
        alreadyExcluded.localBackupExcludedFromiOSBackup = true
        #expect(BackupExclusionLaunchGate.decision(preferences: alreadyExcluded, priorUse: true) == .recordExistingExclusion)
    }

    /// Fresh install (no marker, no onboarding evidence): the excluded default is adopted
    /// silently — excluded and choiceMade both flip true, no prompt is requested, the immediate
    /// apply seam fires with `true`, and the prior-use marker latches for every later launch.
    @Test func freshInstallAdoptsExcludedDefaultWithoutPrompt() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        var applied: [Bool] = []

        let resolution = fixture.gate(priorUseEvidence: false).resolveAtLaunch(
            store: fixture.store,
            applyExclusionNow: { applied.append($0) }
        )

        #expect(resolution == .resolved(needsPrompt: false))
        #expect(fixture.store.preferences.localBackupExcludedFromiOSBackup == true)
        #expect(fixture.store.preferences.backupExclusionChoiceMade == true)
        #expect(applied == [true])
        #expect(fixture.marker.hasPriorUse)

        // A second launch is inert: the choice is recorded, so nothing changes and no prompt.
        let secondLaunch = fixture.gate(priorUseEvidence: false).resolveAtLaunch(store: fixture.store)
        #expect(secondLaunch == .resolved(needsPrompt: false))
    }

    /// Existing install (prior use), currently included, no recorded choice: the gate requests
    /// the one-time prompt WITHOUT touching the preferences, and the "keep in backups" answer
    /// records the choice so the prompt never returns — with the exclusion value unchanged.
    @Test func existingIncludedInstallIsPromptedOnceAndKeepPickSticks() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        var applied: [Bool] = []
        let gate = fixture.gate(priorUseEvidence: true)

        let resolution = gate.resolveAtLaunch(store: fixture.store, applyExclusionNow: { applied.append($0) })

        #expect(resolution == .resolved(needsPrompt: true))
        // Requesting the prompt must not itself change anything — the user has not answered yet.
        #expect(fixture.store.preferences.localBackupExcludedFromiOSBackup == false)
        #expect(fixture.store.preferences.backupExclusionChoiceMade == false)
        #expect(applied.isEmpty)

        gate.recordPromptChoice(excludeFromBackups: false, store: fixture.store, applyExclusionNow: { applied.append($0) })
        #expect(fixture.store.preferences.localBackupExcludedFromiOSBackup == false)
        #expect(fixture.store.preferences.backupExclusionChoiceMade == true)
        #expect(applied.isEmpty, "keeping the status quo must not re-flag any file")

        // Never shown again.
        #expect(gate.resolveAtLaunch(store: fixture.store) == .resolved(needsPrompt: false))
    }

    /// The prompt's "exclude" answer: excluded and choiceMade flip together, the immediate apply
    /// seam fires, and the prompt never returns.
    @Test func existingInstallPromptExcludePickExcludesAndSticks() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        var applied: [Bool] = []
        let gate = fixture.gate(priorUseEvidence: true)

        #expect(gate.resolveAtLaunch(store: fixture.store) == .resolved(needsPrompt: true))
        gate.recordPromptChoice(excludeFromBackups: true, store: fixture.store, applyExclusionNow: { applied.append($0) })

        #expect(fixture.store.preferences.localBackupExcludedFromiOSBackup == true)
        #expect(fixture.store.preferences.backupExclusionChoiceMade == true)
        #expect(applied == [true])
        #expect(gate.resolveAtLaunch(store: fixture.store) == .resolved(needsPrompt: false))
    }

    /// Existing install that had already opted into exclusion via the Privacy & Data toggle: the
    /// gate records that a choice exists (so later launches are inert) without prompting and
    /// without changing the stored value.
    @Test func existingExcludedInstallGetsChoiceRecordedWithoutPrompt() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        fixture.store.update { $0.localBackupExcludedFromiOSBackup = true }

        let resolution = fixture.gate(priorUseEvidence: true).resolveAtLaunch(store: fixture.store)

        #expect(resolution == .resolved(needsPrompt: false))
        #expect(fixture.store.preferences.localBackupExcludedFromiOSBackup == true)
        #expect(fixture.store.preferences.backupExclusionChoiceMade == true)
    }

    /// The marker is the load-bearing half of fresh-vs-existing across a wipe: "delete
    /// everything" resets the preferences (clearing `backupExclusionChoiceMade`) but the
    /// device-local marker survives, so the next launch re-runs the gate as an EXISTING install —
    /// the honest one-time prompt again, never a second silent excluded default.
    @Test func priorUseMarkerSurvivesPreferenceResetSoPostWipeLaunchPromptsInsteadOfSilentlyFlipping() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        // Launch 1: genuinely fresh — silent excluded default, marker latched.
        #expect(fixture.gate(priorUseEvidence: false).resolveAtLaunch(store: fixture.store) == .resolved(needsPrompt: false))
        #expect(fixture.marker.hasPriorUse)

        // "Delete everything" resets the preference blob to first-launch defaults.
        #expect(fixture.store.resetToDefaults(), "the preferences row survived the reset")
        #expect(fixture.store.preferences.backupExclusionChoiceMade == false)

        // Launch 2: the marker alone classifies this as prior use (no onboarding evidence
        // injected, and the blob was just deleted), so the gate asks instead of silently
        // adopting the excluded default again.
        #expect(fixture.gate(priorUseEvidence: false).resolveAtLaunch(store: fixture.store) == .resolved(needsPrompt: true))
    }

    /// Legacy evidence (onboarding completed before the marker existed) counts as prior use on
    /// its own, so the upgrade generation can never be misclassified as fresh.
    @Test func legacyOnboardingEvidenceAloneCountsAsPriorUse() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        #expect(fixture.marker.hasPriorUse == false)

        let resolution = fixture.gate(priorUseEvidence: true).resolveAtLaunch(store: fixture.store)

        #expect(resolution == .resolved(needsPrompt: true))
        #expect(fixture.marker.hasPriorUse, "the resolution itself must latch the marker")
    }

    /// The reinstall cohort (adversarial-review finding, 2026-08-11): the marker and the
    /// onboarding key die with the app container on uninstall, but the preferences blob lives in
    /// the keychain, which SURVIVES delete + reinstall. A surviving blob alone must classify the
    /// install as existing — otherwise the gate would adopt the silent excluded default over a
    /// user's recorded "keep included" preference and, because it also sets `choiceMade`, would
    /// suppress the honest prompt forever.
    @Test func survivingKeychainBlobAloneCountsAsPriorUseSoReinstallIsNeverSilentlyFlipped() throws {
        // A pre-Phase-6 blob written by the previous install: included, never asked, sync on.
        var surviving = StoragePreferences()
        surviving.iCloudSyncEnabled = true
        let fixture = try Fixture(preSeededBlob: surviving)
        defer { fixture.tearDown() }
        // Reinstall shape: no marker, no onboarding evidence — the container is gone.
        #expect(fixture.marker.hasPriorUse == false)

        let resolution = fixture.gate(priorUseEvidence: false).resolveAtLaunch(store: fixture.store)

        // Existing install: the honest prompt, never the silent fresh-install default.
        #expect(resolution == .resolved(needsPrompt: true))
        #expect(fixture.store.preferences.localBackupExcludedFromiOSBackup == false)
        #expect(fixture.store.preferences.backupExclusionChoiceMade == false)
        #expect(fixture.store.preferences.iCloudSyncEnabled == true, "the surviving blob must not be overwritten by the classification")
    }

    /// Same reinstall shape for a user whose surviving blob already records exclusion: their
    /// standing choice is recorded without a prompt, exactly like the in-place upgrade cohort.
    @Test func survivingExcludedBlobGetsChoiceRecordedWithoutPromptAfterReinstall() throws {
        var surviving = StoragePreferences()
        surviving.localBackupExcludedFromiOSBackup = true
        let fixture = try Fixture(preSeededBlob: surviving)
        defer { fixture.tearDown() }

        let resolution = fixture.gate(priorUseEvidence: false).resolveAtLaunch(store: fixture.store)

        #expect(resolution == .resolved(needsPrompt: false))
        #expect(fixture.store.preferences.localBackupExcludedFromiOSBackup == true)
        #expect(fixture.store.preferences.backupExclusionChoiceMade == true)
    }

    /// The launch-frozen-copy hazard (adversarial-review finding, 2026-08-11): a process
    /// launched before first device unlock loads fresh DEFAULTS into the store's in-memory copy
    /// (the keychain blob is `AfterFirstUnlockThisDeviceOnly`), while the gate runs later, post
    /// foreground, when the real blob is readable again. The gate must classify over the LIVE
    /// blob — an already-decided user is never re-prompted — and must re-sync the store so no
    /// later write persists the frozen defaults over the real preferences.
    @Test func gateClassifiesOverTheLiveBlobNotTheLaunchFrozenCopy() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        // The store loaded when the keychain was "empty" (stand-in for unreadable-at-prewarm):
        // its frozen copy is all defaults.
        #expect(fixture.store.preferences.backupExclusionChoiceMade == false)

        // The REAL blob (readable by gate time): decided, included, sync + a sealed backup on.
        var real = StoragePreferences()
        real.backupExclusionChoiceMade = true
        real.iCloudSyncEnabled = true
        real.sealedBackupPeriodEnabled = true
        fixture.writeBlobDirectly(real)

        let resolution = fixture.gate(priorUseEvidence: true).resolveAtLaunch(store: fixture.store)

        // Already chosen: no re-prompt for a decided user, no matter what the frozen copy said.
        #expect(resolution == .resolved(needsPrompt: false))
        // And the store's in-memory copy was re-synced to the live values, not left on defaults.
        #expect(fixture.store.preferences.backupExclusionChoiceMade == true)
        #expect(fixture.store.preferences.iCloudSyncEnabled == true)
        #expect(fixture.store.preferences.sealedBackupPeriodEnabled == true)
        // The persisted blob is untouched — nothing clobbered it back to defaults.
        let persisted = StoragePreferencesStore.currentPreferences(service: fixture.store.keychainService)
        #expect(persisted.iCloudSyncEnabled == true)
        #expect(persisted.sealedBackupPeriodEnabled == true)
    }

    /// The prompt-branch half of the frozen-copy hazard: when the live blob genuinely needs the
    /// prompt, the recorded answer must write through the re-synced live values — preserving
    /// every unrelated choice — never through the launch-frozen defaults.
    @Test func promptAnswerWritesThroughTheLiveBlobPreservingUnrelatedChoices() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        var real = StoragePreferences()
        real.iCloudSyncEnabled = true
        real.sealedBackupJournalEnabled = true
        fixture.writeBlobDirectly(real)
        let gate = fixture.gate(priorUseEvidence: true)

        #expect(gate.resolveAtLaunch(store: fixture.store) == .resolved(needsPrompt: true))
        gate.recordPromptChoice(excludeFromBackups: true, store: fixture.store)

        let persisted = StoragePreferencesStore.currentPreferences(service: fixture.store.keychainService)
        #expect(persisted.localBackupExcludedFromiOSBackup == true)
        #expect(persisted.backupExclusionChoiceMade == true)
        #expect(persisted.iCloudSyncEnabled == true, "the answer must not clobber unrelated preferences")
        #expect(persisted.sealedBackupJournalEnabled == true, "a cleared sealed-backup flag would strand the CKRecords delete-everything claims to remove")
    }

    /// The fail-closed path (adversarial-review finding, 2026-08-11): when the keychain read
    /// itself fails — `errSecInteractionNotAllowed` in a prewarmed pre-first-unlock process —
    /// the blob's existence is unknown, so the gate must do NOTHING: no classification, no
    /// prompt, no write, no marker latch. The caller retries on the next foreground activation.
    @Test func unreadableKeychainDefersResolutionWithoutLatchingOrWriting() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        var applied: [Bool] = []

        let resolution = fixture.gate(priorUseEvidence: true, blobState: .unreadable).resolveAtLaunch(
            store: fixture.store,
            applyExclusionNow: { applied.append($0) }
        )

        #expect(resolution == .deferredKeychainUnreadable)
        #expect(applied.isEmpty)
        #expect(fixture.marker.hasPriorUse == false, "a deferred launch decided nothing, so it must not latch")
        #expect(fixture.store.preferences.localBackupExcludedFromiOSBackup == false)
        #expect(fixture.store.preferences.backupExclusionChoiceMade == false)
        #expect(KeychainItem.load(for: .storagePreferences, service: fixture.store.keychainService) == nil, "nothing may be persisted on a deferred launch")

        // Once the keychain is readable again (default live read, empty service = absent), the
        // same fixture resolves normally — the retry the deferral promises.
        #expect(fixture.gate(priorUseEvidence: true).resolveAtLaunch(store: fixture.store) == .resolved(needsPrompt: true))
    }

    /// Per-test isolation: a unique keychain service for the preference store and a private
    /// UserDefaults suite for the marker, both torn down after the test. `preSeededBlob` writes a
    /// blob into the keychain BEFORE the store is constructed — the reinstall shape, where the
    /// previous install's blob survives while the app container (marker + onboarding key) did not.
    @MainActor
    private struct Fixture {
        let store: StoragePreferencesStore
        let marker: FernletPriorUseMarker
        private let service: String
        private let suiteName: String
        private let defaults: UserDefaults

        init(preSeededBlob: StoragePreferences? = nil) throws {
            service = testServiceID()
            suiteName = "BackupExclusionLaunchGateTests.\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: suiteName))
            if let preSeededBlob {
                let seeded = KeychainItem.store(try JSONEncoder().encode(preSeededBlob),
                                                for: .storagePreferences, service: service)
                #expect(seeded == errSecSuccess, "pre-seeding the preferences blob failed")
            }
            store = StoragePreferencesStore(keychainService: service)
            marker = FernletPriorUseMarker(defaults: defaults)
        }

        /// A gate over this fixture's marker with the legacy prior-use evidence pinned;
        /// `blobState` overrides the live keychain read (used to simulate the unreadable
        /// pre-first-unlock keychain, which a real simulator keychain cannot produce).
        func gate(priorUseEvidence: Bool, blobState: StoragePreferencesBlobState? = nil) -> BackupExclusionLaunchGate {
            BackupExclusionLaunchGate(
                marker: marker,
                legacyPriorUseEvidence: { priorUseEvidence },
                persistedBlobState: blobState.map { state in { _ in state } }
            )
        }

        /// Writes `preferences` straight into this fixture's keychain slot, bypassing the store —
        /// the "another launch already persisted the real blob" shape the frozen-copy tests need.
        func writeBlobDirectly(_ preferences: StoragePreferences) {
            guard let data = try? JSONEncoder().encode(preferences) else { return }
            #expect(KeychainItem.store(data, for: .storagePreferences, service: service) == errSecSuccess)
        }

        func tearDown() {
            KeychainItem.delete(for: .storagePreferences, service: service)
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}

/// The literal lives in a helper (mirroring `StoragePreferencesTests`) so the wipe-coverage
/// keychain-service discovery does not read a test fixture as a production service.
private func testServiceID() -> String {
    "com.fernlet.storage-preferences.tests.\(UUID().uuidString)"
}

/// Pins the Phase-6 fix for the toggle-copy overpromise: with the exclusion preference set, the
/// `LocalFernletRepository` JSON day blob — the legacy pre-migration history file, which can
/// still hold a user's pre-migration days in plaintext (live history is Core Data's
/// `Fernlet.sqlite`, excluded separately at store load) — really carries `isExcludedFromBackup`,
/// keeps carrying it across the atomic rewrite every save performs (which replaces the inode the
/// flag lives on), and can be re-included through the explicit preference-change seam.
@MainActor
struct LocalDayBlobBackupExclusionTests {

    /// With the preference set, the blob is flagged after a save, and STAYS flagged after a
    /// second save — the atomic rewrite would have silently dropped the flag without the
    /// re-application in `saveDatabase`.
    @Test func prefSetFlagsTheDayBlobAndReappliesAfterEveryRewrite() throws {
        let url = temporaryBlobURL("excluded")
        defer { try? FileManager.default.removeItem(at: url) }
        let repository = LocalFernletRepository(fileURL: url, backupExclusionPreference: { true })

        #expect(repository.saveSnapshot(minimalSnapshot()))
        #expect(try isExcludedFromBackup(url) == true)

        // Rewrite the blob (new inode): the flag must be re-applied, not silently lost.
        #expect(repository.saveSnapshot(minimalSnapshot()))
        #expect(try isExcludedFromBackup(url) == true)
    }

    /// With the preference unset (the pre-decision and keep-in-backups states), saves leave the
    /// blob included — exclusion is opt-in, never ambient.
    @Test func prefUnsetLeavesTheDayBlobIncluded() throws {
        let url = temporaryBlobURL("included")
        defer { try? FileManager.default.removeItem(at: url) }
        let repository = LocalFernletRepository(fileURL: url, backupExclusionPreference: { false })

        #expect(repository.saveSnapshot(minimalSnapshot()))

        #expect(try isExcludedFromBackup(url) != true)
    }

    /// Constructing a repository over an EXISTING un-flagged blob applies the set preference
    /// immediately — the launch-time pass, so a user who excluded on another screen (or whose
    /// last session predates the fix) is covered without waiting for the next save.
    @Test func initAppliesTheSetPreferenceToAnExistingBlob() throws {
        let url = temporaryBlobURL("existing")
        defer { try? FileManager.default.removeItem(at: url) }
        // Write the blob with the preference OFF, so the file exists un-flagged.
        #expect(LocalFernletRepository(fileURL: url, backupExclusionPreference: { false }).saveSnapshot(minimalSnapshot()))
        #expect(try isExcludedFromBackup(url) != true)

        _ = LocalFernletRepository(fileURL: url, backupExclusionPreference: { true })

        #expect(try isExcludedFromBackup(url) == true)
    }

    /// The explicit preference-change seam works in BOTH directions — re-including restores the
    /// user's device-backup recovery, exactly like `PrivatePersistenceController`'s equivalent.
    @Test func applyBackupExclusionTogglesBothDirections() throws {
        let url = temporaryBlobURL("toggle")
        defer { try? FileManager.default.removeItem(at: url) }
        let repository = LocalFernletRepository(fileURL: url, backupExclusionPreference: { false })
        #expect(repository.saveSnapshot(minimalSnapshot()))

        repository.applyBackupExclusion(excluded: true)
        #expect(try isExcludedFromBackup(url) == true)

        repository.applyBackupExclusion(excluded: false)
        #expect(try isExcludedFromBackup(url) != true)
    }

    /// A minimal, empty-day sanitized snapshot — the save path is what is under test, not the content.
    private func minimalSnapshot() -> SanitizedSnapshot {
        let todayKey = "2026-08-11"
        let snapshot = FernletSnapshot(
            todayKey: todayKey,
            day: FernletDay(date: todayKey),
            settings: FernletSettings(),
            recentMeals: [],
            previousJournals: [],
            memories: [],
            goals: [],
            workshop: WorkshopData()
        )
        return SanitizedSnapshot.sanitizing(snapshot, sealedJournalIDs: [])
    }

    /// Fresh-URL read of the file's `isExcludedFromBackup` resource value (a reused URL instance
    /// can serve a cached value).
    private func isExcludedFromBackup(_ url: URL) throws -> Bool? {
        try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
    }

    private func temporaryBlobURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalDayBlobBackupExclusionTests-\(name)-\(UUID().uuidString)")
            .appendingPathExtension("json")
    }
}
