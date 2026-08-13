// HeartDropAppWiringTests.swift
// FernletTests
//
// The APP-LAYER half of the away-hearts dead-drop (bitchat adoptions Increment 3): the service's own
// behavior lives in HeartDropTests, this covers how FernletStore and the two UI surfaces drive it.
//
// Added by the review round of 2026-07-25, which found three silent promises:
//   - turning the toggle OFF left this device's sealed records on the CloudKit PUBLIC database with
//     nothing left able to name them (public records have no TTL, and recipients cannot delete a
//     sender's records),
//   - "delete everything" wiped the outbox — and with it the record names — BEFORE any remote delete
//     could run, and reported nothing,
//   - the UI kept promising delivery while `deliveryProblem` said delivery was not happening.
//
// The review OF that fix round (same day) found the "purge is owed" state was a process-local flag,
// which lost the purge across an app kill and never saw consent withdrawn on another device (the
// setting rides the synced snapshot, so it lands as state, not as a setter call) — and that a wipe
// whose remote purge failed reported the failure once and then reported the RETRY as a clean sweep.
// The state is now derived from (consent flag, outbox), and a wipe-time strand is latched.
//
// The store tests drive a real `FernletStore` with a mock transport injected into its live
// `heartDropService`, so they exercise the actual wiring rather than a re-implementation of it.
// Each test's stores share ONE per-test heart-drop scope (see `heartDropDirectory` /
// `heartDropKeychainService` below) rather than the app's process-wide sidecars — the wiring under
// test includes `deleteAllData`, whose wipe used to reach every concurrently-running suite's hearts.

import Foundation
import Testing
import CryptoKit
import ProximityKit
import FernletFoundation
import FernletDomainModel
@testable import Fernlet
import LocalPersistence

@MainActor
@Suite(.serialized)
struct HeartDropAppWiringTests {

    // MARK: - Harness

    nonisolated final class MockDropTransport: HeartDropTransporting, @unchecked Sendable {
        var records: [HeartDropRecord] = []
        var available = true
        /// Makes the remote purge fail the way a network drop does, which is the only way the
        /// "couldn't remove them" path is reachable.
        var failDeletes = false
        /// Guarantees a real suspension inside the delete, so a test can assert what does (and does
        /// not) get to run while a purge is parked on the network.
        var deleteYields = false
        var deleteAttempts = 0
        private var counter = 0

        func accountAvailable() async -> Bool { available }

        func upload(tag: String, payload: Data) async throws -> String {
            counter += 1
            let name = "rec-\(counter)"
            records.append(HeartDropRecord(tag: tag, payload: payload, recordName: name))
            return name
        }

        func fetch(tags: [String]) async throws -> [HeartDropRecord] {
            let wanted = Set(tags)
            return records.filter { wanted.contains($0.tag) }
        }

        func deleteOwnRecords(recordNames: [String]) async throws {
            deleteAttempts += 1
            if deleteYields { await Task.yield() }
            if failDeletes { throw CocoaError(.fileWriteUnknown) }
            let doomed = Set(recordNames)
            records.removeAll { doomed.contains($0.recordName) }
        }
    }

    /// THIS test's heart-drop scope — the sidecar root and the keychain service holding the key
    /// those sidecars are sealed with. Swift Testing builds a fresh suite value per test, so every
    /// test gets its own pair, and the two stores a relaunch test builds share it for free (which is
    /// exactly what "the same on-disk outbox, a new process" means).
    ///
    /// Both halves, not just the directory: `deleteAllData` runs `wipeForDeleteAll()`, which deletes
    /// the whole keychain service — so on the production service a wipe in any concurrently-running
    /// suite would destroy the key these sidecars are sealed under and leave them quarantined. See
    /// `uniqueHeartDropKeychainService()`.
    private let heartDropDirectory = uniqueProximityDirectory()
    private let heartDropKeychainService = uniqueHeartDropKeychainService()

    /// A store on this test's heart-drop scope. `proximityDirectory`/`keychainService` override it
    /// only for the isolation test, which needs a store standing in for a DIFFERENT suite.
    private func makeStore(
        _ name: String,
        proximityDirectory: URL? = nil,
        keychainService: String? = nil
    ) -> FernletStore {
        FernletStore(
            repository: LocalFernletRepository(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(name)-\(UUID().uuidString).json")
            ),
            sensitiveVisibilityDefaults: uniqueSensitiveVisibilityDefaults(),
            appGroupDirectory: uniqueAppGroupDirectory(),
            sharedRecipeImportQueueFileURL: uniqueSharedRecipeImportQueueURL(),
            photoDocumentsDirectory: uniquePhotoDirectory(),
            proximitySupportDirectory: proximityDirectory ?? heartDropDirectory,
            heartDropKeychainService: keychainService ?? heartDropKeychainService,
            aiQuotaDefaults: uniqueAIQuotaDefaults()
        )
    }

    /// Removes this test's scoped seal key + prekey blob. A struct suite has no teardown hook, so
    /// the tests that mint keychain material call it from the same `defer` that cleans up the
    /// friend identity they minted — otherwise every run leaves two more rows behind.
    private func cleanUpHeartDropKeychain() {
        KeychainItem.deleteAll(service: heartDropKeychainService)
    }

    private func makeFriendIdentity() throws -> (ProximityTrustedPeerRecord, String) {
        let serviceID = "com.fernlet.identity.test.\(UUID().uuidString)"
        let identity = IdentityService(keychainService: serviceID)
        try identity.ensureProvisioned()
        let record = ProximityTrustedPeerRecord(
            id: UUID(),
            displayName: "Rowan Fields",
            fingerprint: identity.localFingerprint,
            signingPublicKey: identity.localSigningPublicKey,
            keyAgreementPublicKey: identity.localKeyAgreementPublicKey,
            mode: .friend,
            firstAcceptedAt: Date(),
            lastSeenAt: Date()
        )
        return (record, serviceID)
    }

    /// Bounded spin for the fire-and-forget paths (`queueHeart`'s auto-sync, the purge `Task`).
    /// Spins until `condition` holds, or until BOTH the deadline has passed and `minimumPolls`
    /// observations have actually been made.
    ///
    /// Both halves of that give-up rule are load-earned. A fixed iteration count of `Task.yield()`
    /// does not measure time: on the FIRST store in a cold test process — where identity
    /// provisioning and the sidecar writes actually hit the keychain and disk — 20k yields burned
    /// through before the upload landed, so both purge tests failed on their first execution and
    /// passed on the rerun. But a wall-clock deadline alone is no better under the opposite
    /// pressure: this suite is `@MainActor`, and in a loaded full-suite run the whole process can
    /// be starved of the MainActor for tens of seconds at a stretch. `Date()` keeps advancing
    /// throughout, so a pure 10 s deadline expired having genuinely *looked* only a handful of
    /// times — `aPurgeOwedFromAPreviousLaunchIsRediscoveredAndRetried` burned 38.1 s and failed
    /// that way, against the ~0.02 s it takes unloaded. Requiring real observations makes the
    /// give-up decision proportional to scheduling actually received rather than to time elapsed,
    /// and the pair still terminates: `polls` only climbs, and each turn of the loop sleeps.
    ///
    /// The short sleep also stops this from starving the very MainActor work it is waiting for.
    private func waitUntil(
        _ condition: () -> Bool,
        timeout: TimeInterval = 30,
        minimumPolls: Int = 500
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var polls = 0
        while true {
            if condition() { return true }
            polls += 1
            if polls >= minimumPolls, Date() >= deadline { return false }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000) // 1 ms
        }
    }

    /// Enables away delivery, queues one heart and waits until it has actually REACHED the drop-off
    /// (uploaded and written back), which is the only state in which there is a remote record to
    /// delete. Returns the friend's keychain service so the caller can clean it up.
    private func queueOneDeliveredHeart(
        store: FernletStore,
        transport: MockDropTransport
    ) async throws -> (friend: ProximityTrustedPeerRecord, keychainService: String) {
        // Kept from when the store's service wrote to the app's real sidecar files and a previous
        // run's entries could be swept into this test's counts. Harmless now that the scope is
        // per-test, and it still pins that a queue-after-purge starts from a genuinely empty outbox.
        _ = await store.heartDropService.purgeDeadDrop()
        store.setHeartsAwayDelivery(true)
        let (friend, keychainService) = try makeFriendIdentity()
        #expect(store.heartDropService.queueHeart(to: friend) == .queued)
        let delivered = await waitUntil {
            !transport.records.isEmpty && store.heartDropService.pendingCount(for: friend) == 0
        }
        #expect(delivered, "precondition: the heart never reached the mock drop-off")
        return (friend, keychainService)
    }

    // MARK: - Consent withdrawal

    /// Turning the toggle off has to delete OUR OWN uploaded records. Nothing else can: the record
    /// names live only in the outbox, and once consent is gone the service is not allowed to look
    /// them up again — so a stranded record is stranded forever.
    @Test func turningAwayDeliveryOffDeletesOurRecordsFromTheDropOff() async throws {
        let store = makeStore("heartdrop-toggle-off")
        let transport = MockDropTransport()
        store.heartDropService.transport = transport
        let (_, keychainService) = try await queueOneDeliveredHeart(store: store, transport: transport)
        defer { KeychainItem.deleteAll(service: keychainService); cleanUpHeartDropKeychain() }

        store.setHeartsAwayDelivery(false)

        // One combined wait: the transport's records clear INSIDE the purge's await, but the
        // derived pending state only settles once the purge task resumes and prunes the outbox —
        // asserting it un-awaited raced that continuation under full-suite load.
        #expect(await waitUntil { transport.records.isEmpty && !store.heartsAwayPurgePending },
                "our sealed records were left on the public database after consent was withdrawn")
    }

    /// A purge that fails over the network is remembered rather than swallowed, and the foreground
    /// retry seam finishes the job. "Off" has to become true eventually, not just visually.
    @Test func aFailedPurgeIsRememberedAndRetriedOnTheNextForeground() async throws {
        let store = makeStore("heartdrop-purge-retry")
        let transport = MockDropTransport()
        store.heartDropService.transport = transport
        let (_, keychainService) = try await queueOneDeliveredHeart(store: store, transport: transport)
        defer { KeychainItem.deleteAll(service: keychainService); cleanUpHeartDropKeychain() }

        transport.deleteAttempts = 0
        transport.failDeletes = true
        store.setHeartsAwayDelivery(false)
        // Wait on the ATTEMPT, not on the pending state: the state is derived, so it is true from
        // the moment consent goes off — which would let this assert before the purge even ran.
        #expect(await waitUntil { transport.deleteAttempts > 0 }, "the purge never reached the drop-off")
        #expect(store.heartsAwayPurgePending,
                "a failed purge was swallowed — nothing would ever retry it")
        #expect(!transport.records.isEmpty, "precondition: the failed delete removed the record anyway")

        transport.failDeletes = false
        // Awaited, not spun on: the fire-and-forget seam needs the MainActor, which every other
        // @MainActor suite is competing for under full-suite load.
        #expect(await store.retryHeartsAwayPurgeNow(), "the retry seam declined a purge it owed")

        #expect(transport.records.isEmpty)
        #expect(!store.heartsAwayPurgePending)
    }

    /// FIX D: the purge owed across an app KILL. The old in-memory flag died with the process, so on
    /// the next launch nothing knew a purge was outstanding — the foreground retry never fired and
    /// this device's sealed records sat on the public database until they aged out, with the user
    /// reading "off" as "removed". The outbox sidecar survives the kill, which is what makes the
    /// state derivable; a second `FernletStore` over that same sidecar is what a relaunch looks like.
    ///
    /// Both stores come from `makeStore`, so they share this test's heart-drop scope — the shared
    /// sidecar IS the fixture here, and it has to be the same file AND the same seal key, or the
    /// "relaunch" would find an outbox it cannot open rather than one it can read.
    @Test func aPurgeOwedFromAPreviousLaunchIsRediscoveredAndRetried() async throws {
        let firstLaunch = makeStore("heartdrop-relaunch-1")
        let transport = MockDropTransport()
        firstLaunch.heartDropService.transport = transport
        let (_, keychainService) = try await queueOneDeliveredHeart(store: firstLaunch, transport: transport)
        defer { KeychainItem.deleteAll(service: keychainService); cleanUpHeartDropKeychain() }

        transport.deleteAttempts = 0
        transport.failDeletes = true
        firstLaunch.setHeartsAwayDelivery(false)
        #expect(await waitUntil { transport.deleteAttempts > 0 })
        #expect(!transport.records.isEmpty, "precondition: the record is still stranded")

        // The kill: a brand-new store with no in-memory anything and consent off by default, but the
        // same on-disk outbox — which still names the record we uploaded.
        let relaunched = makeStore("heartdrop-relaunch-2")
        let relaunchedTransport = MockDropTransport()
        relaunchedTransport.records = transport.records
        relaunched.heartDropService.transport = relaunchedTransport
        #expect(!relaunched.settings.heartsAwayDelivery, "precondition: a fresh store starts opted out")
        #expect(relaunched.heartsAwayPurgePending,
                "the relaunch forgot the purge it still owed — the records would sit there until they aged out")

        // What the foreground listener does at launch, awaited so load can't make it flaky.
        #expect(await relaunched.retryHeartsAwayPurgeNow())
        #expect(relaunchedTransport.records.isEmpty)
        #expect(!relaunched.heartsAwayPurgePending)
    }

    /// FIX E: `heartsAwayDelivery` lives in FernletSettings inside the SYNCED snapshot, so turning
    /// the feature off on another device arrives here as a plain state change — the local setter the
    /// purge used to hang off is never called. Simulated exactly that way: the setting is written
    /// directly, never through `setHeartsAwayDelivery`.
    @Test func consentWithdrawnOnAnotherDeviceStillPurgesThisDevicesRecords() async throws {
        let store = makeStore("heartdrop-other-device-off")
        let transport = MockDropTransport()
        store.heartDropService.transport = transport
        let (_, keychainService) = try await queueOneDeliveredHeart(store: store, transport: transport)
        defer { KeychainItem.deleteAll(service: keychainService); cleanUpHeartDropKeychain() }

        store.settings.heartsAwayDelivery = false // arrived by snapshot sync, not by this device
        #expect(store.heartsAwayPurgePending)

        #expect(await store.retryHeartsAwayPurgeNow())

        #expect(transport.records.isEmpty && !store.heartsAwayPurgePending,
                "consent withdrawn elsewhere left this device's records on the public database")
    }

    /// The retry fires from a listener chain that re-enters on every scene/tab/lock event, and each
    /// `purgeDeadDrop()` bumps the service's purge generation — so overlapping calls would supersede
    /// one another mid-flight and multiply the round trips instead of finishing the one running.
    @Test func repeatedRetriesDoNotStackConcurrentPurges() async throws {
        let store = makeStore("heartdrop-retry-no-stack")
        let transport = MockDropTransport()
        store.heartDropService.transport = transport
        let (_, keychainService) = try await queueOneDeliveredHeart(store: store, transport: transport)
        defer { KeychainItem.deleteAll(service: keychainService); cleanUpHeartDropKeychain() }

        transport.failDeletes = true
        transport.deleteYields = true
        transport.deleteAttempts = 0
        store.setHeartsAwayDelivery(false)
        for _ in 0..<5 { store.retryHeartsAwayPurgeIfNeeded() }
        for _ in 0..<500 { await Task.yield() }

        #expect(transport.deleteAttempts == 1,
                "the foreground retry stacked \(transport.deleteAttempts) purges over the same records")

        transport.failDeletes = false
        await store.retryHeartsAwayPurgeNow()
    }

    /// And it must never fire while consent is ON — that would delete records the user still expects
    /// to be delivered. The derived state short-circuits on the consent flag for exactly this.
    @Test func theRetryNeverFiresWhileTheFeatureIsOn() async throws {
        let store = makeStore("heartdrop-retry-consent-on")
        let transport = MockDropTransport()
        store.heartDropService.transport = transport
        let (_, keychainService) = try await queueOneDeliveredHeart(store: store, transport: transport)
        defer { KeychainItem.deleteAll(service: keychainService); cleanUpHeartDropKeychain() }

        transport.deleteAttempts = 0
        #expect(store.settings.heartsAwayDelivery, "precondition: the feature is on with a record out there")
        #expect(!store.heartsAwayPurgePending)

        store.retryHeartsAwayPurgeIfNeeded()
        for _ in 0..<100 { await Task.yield() }

        #expect(transport.deleteAttempts == 0, "a retry deleted a heart that was still on its way")
        #expect(!transport.records.isEmpty)

        store.setHeartsAwayDelivery(false)
        _ = await waitUntil { transport.records.isEmpty }
    }

    /// The retry is driven from a listener chain that fires on every scene/tab/lock change, so it
    /// must cost nothing when there is nothing outstanding — and it must never fire while the user
    /// has the feature turned back ON, which would delete records they still expect to be delivered.
    @Test func theRetrySeamIsInertWhenNothingIsOutstanding() async throws {
        let store = makeStore("heartdrop-retry-inert")
        defer { cleanUpHeartDropKeychain() }
        let transport = MockDropTransport()
        store.heartDropService.transport = transport
        // Clean slate first. The sidecar is this test's own now, so nothing can be left in it — but
        // the purge also exercises the empty case, which is the state this test is about.
        _ = await store.heartDropService.purgeDeadDrop()
        transport.deleteAttempts = 0

        store.retryHeartsAwayPurgeIfNeeded()
        store.setHeartsAwayDelivery(true)
        store.retryHeartsAwayPurgeIfNeeded()
        for _ in 0..<50 { await Task.yield() } // let any spawned task run

        #expect(transport.deleteAttempts == 0)
        #expect(!store.heartsAwayPurgePending)
        store.setHeartsAwayDelivery(false)
    }

    /// Re-enabling supersedes a pending purge: whatever survived is back under consent, and the
    /// service's own expiry cleanup deletes it. Leaving the notice up would say "couldn't remove
    /// them" about a feature the user has just turned back on.
    @Test func reEnablingClearsThePendingPurgeNotice() async throws {
        let store = makeStore("heartdrop-reenable")
        let transport = MockDropTransport()
        store.heartDropService.transport = transport
        let (_, keychainService) = try await queueOneDeliveredHeart(store: store, transport: transport)
        defer { KeychainItem.deleteAll(service: keychainService); cleanUpHeartDropKeychain() }

        transport.deleteAttempts = 0
        transport.failDeletes = true
        store.setHeartsAwayDelivery(false)
        #expect(await waitUntil { transport.deleteAttempts > 0 })
        #expect(store.heartsAwayPurgePending)

        store.setHeartsAwayDelivery(true)
        #expect(!store.heartsAwayPurgePending)
        transport.failDeletes = false
        store.setHeartsAwayDelivery(false)
        _ = await waitUntil { transport.records.isEmpty }
    }

    // MARK: - Delete everything

    /// "Delete everything" must reach the dead-drop BEFORE the local wipe. The wipe destroys the
    /// record names, so an ordering slip here is unrecoverable — the copies stay on the public
    /// database with nothing able to address them.
    @Test func deleteAllRemovesOurRecordsFromTheDropOff() async throws {
        let store = makeStore("heartdrop-delete-all")
        let transport = MockDropTransport()
        store.heartDropService.transport = transport
        let (_, keychainService) = try await queueOneDeliveredHeart(store: store, transport: transport)
        defer { KeychainItem.deleteAll(service: keychainService); cleanUpHeartDropKeychain() }

        let outcome = await store.deleteAllData(includingHealthKitSamples: false)

        #expect(transport.records.isEmpty, "the wipe left our sealed hearts on the public database")
        #expect(!outcome.incompleteStores.contains("hearts parked in iCloud"))
        #expect(!store.heartsAwayPurgePending)
    }

    /// A remote delete that fails during a wipe has to reach the user: the local wipe still runs
    /// (privacy wins), which means nothing can retry afterwards — so the dialog must not claim the
    /// copies are gone.
    @Test func deleteAllReportsHeartsItCouldNotRemove() async throws {
        let store = makeStore("heartdrop-delete-all-fail")
        let transport = MockDropTransport()
        store.heartDropService.transport = transport
        let (_, keychainService) = try await queueOneDeliveredHeart(store: store, transport: transport)
        defer { KeychainItem.deleteAll(service: keychainService); cleanUpHeartDropKeychain() }

        transport.failDeletes = true
        let outcome = await store.deleteAllData(includingHealthKitSamples: false)

        #expect(!outcome.isComplete)
        #expect(outcome.incompleteStores.contains("hearts parked in iCloud"),
                "a stranded public-database record was hidden behind a dialog promising a complete wipe")
    }

    /// FIX F: the failure alert invites the user to try again, and the wipe has by then destroyed the
    /// record names those copies are addressed by — so the retry finds an empty outbox and used to
    /// come back CLEAN over records this device knowingly left on a public database. The strand is
    /// latched for the life of the process instead, so every later wipe keeps saying so.
    @Test func aRetriedWipeStillReportsTheHeartsItStranded() async throws {
        let store = makeStore("heartdrop-delete-all-retry")
        let transport = MockDropTransport()
        store.heartDropService.transport = transport
        let (_, keychainService) = try await queueOneDeliveredHeart(store: store, transport: transport)
        defer { KeychainItem.deleteAll(service: keychainService); cleanUpHeartDropKeychain() }

        transport.failDeletes = true
        let first = await store.deleteAllData(includingHealthKitSamples: false)
        #expect(first.incompleteStores.contains("hearts parked in iCloud"))

        // The retry the alert offers. Even with the network back, nothing can name those records
        // any more — so "we deleted everything" would be false.
        transport.failDeletes = false
        let retried = await store.deleteAllData(includingHealthKitSamples: false)

        #expect(retried.incompleteStores.contains("hearts parked in iCloud"),
                "the retry reported a clean wipe while our sealed hearts were still on the public database")
        #expect(!retried.isComplete)
        #expect(!transport.records.isEmpty, "precondition: they really are still out there")
    }

    /// The latch is per-strand, not sticky-by-default: a wipe that DID reach the drop-off must not
    /// start claiming hearts were left behind just because a later one runs in the same process.
    @Test func aCleanWipeNeverClaimsStrandedHearts() async throws {
        let store = makeStore("heartdrop-delete-all-twice-clean")
        let transport = MockDropTransport()
        store.heartDropService.transport = transport
        let (_, keychainService) = try await queueOneDeliveredHeart(store: store, transport: transport)
        defer { KeychainItem.deleteAll(service: keychainService); cleanUpHeartDropKeychain() }

        let first = await store.deleteAllData(includingHealthKitSamples: false)
        let second = await store.deleteAllData(includingHealthKitSamples: false)

        #expect(!first.incompleteStores.contains("hearts parked in iCloud"))
        #expect(!second.incompleteStores.contains("hearts parked in iCloud"))
        #expect(transport.records.isEmpty)
    }

    // MARK: - Storage isolation

    /// The behavioral half of the per-store heart-drop scope. "Delete everything" is a real funnel
    /// with a process-wide blast radius: `wipeForDeleteAll()` removes the outbox / peer-bundle /
    /// dedup files AND, through `HeartPrekeyStore.wipeForDeleteAll()`, every row under the
    /// heart-drop keychain service — which is where the key those files are SEALED with lives. On
    /// the shipped scope all of that is one directory and one service, so under the test runner
    /// (XCTest and Swift Testing suites run in parallel inside ONE process) a wipe here landed in
    /// the middle of whichever suite happened to be running beside it. Third member of the family
    /// fixed for the own-photo corpora (329ceb4) and the friend photo wall (ff7dadb) — NOT the last:
    /// `ModerationLedger`, `FriendStateCache` and `ClosenessLedger` are still built with no
    /// `fileURL:` (so on `JSONSidecarFile`'s fixed `Application Support/Fernlet` path) and `resetAll`
    /// calls `clearAll()` on all three. Latent rather than live today — no suite reads them across
    /// another's wipe — but the same shape, and unsealed, so they need a root and no keychain half.
    ///
    /// The shape mirrors those: `mine` and `theirs` are two live stores on different scopes, and the
    /// wipe runs on `theirs`. `relaunched` — a THIRD store, on `mine`'s scope, built after the wipe —
    /// is what makes the assertions mean something. Without it the test would pass just as happily
    /// if the sidecars stopped persisting at all, and it is the only reader that proves BOTH halves
    /// of the scope survived: the file is still on disk, and the key it is sealed with still opens
    /// it. Reverting the directory half, the keychain half, or the ledger's `fileURL:` each fails it.
    @Test func aDeleteAllInAnotherStoreLeavesThisOnesHeartDropStateIntact() async throws {
        let mine = makeStore("heartdrop-isolation-mine")
        defer { cleanUpHeartDropKeychain() }
        let theirDirectory = uniqueProximityDirectory()
        let theirKeychainService = uniqueHeartDropKeychainService()
        let theirs = makeStore(
            "heartdrop-isolation-theirs",
            proximityDirectory: theirDirectory,
            keychainService: theirKeychainService
        )
        defer { KeychainItem.deleteAll(service: theirKeychainService) }
        let (friend, friendKeychainService) = try makeFriendIdentity()
        defer { KeychainItem.deleteAll(service: friendKeychainService) }

        // One sealed outbox entry and one received heart on EACH store. The transport is replaced
        // with an UNAVAILABLE mock, deliberately: the store's own builder always installs a real
        // `HeartDropCloudTransport`, and `queueHeart` schedules a sync immediately — so on a host
        // whose simulator happens to be signed in to iCloud the heart could upload, and
        // `pendingCount` (which counts un-uploaded entries) would drop to 0 for a reason that has
        // nothing to do with isolation. `accountAvailable() == false` makes "the heart stays
        // queued" true by construction instead of by environment.
        for store in [mine, theirs] {
            let offline = MockDropTransport()
            offline.available = false
            store.heartDropService.transport = offline
            store.setHeartsAwayDelivery(true)
            #expect(store.heartDropService.queueHeart(to: friend) == .queued)
            #expect(store.heartLedger.recordReceivedHeart(
                id: UUID(), senderDisplayName: "Rowan Fields", senderFingerprint: friend.fingerprint))
        }

        // The other suite's "delete everything".
        _ = await theirs.deleteAllData(includingHealthKitSamples: false)

        // Its own state really is gone — otherwise the assertions below would pass against a wipe
        // that had quietly stopped wiping.
        #expect(theirs.heartDropService.pendingCount(for: friend) == 0)
        #expect(theirs.heartLedger.receivedHearts.isEmpty)

        // And ours is untouched, read back through a fresh store on our scope.
        #expect(mine.heartDropService.pendingCount(for: friend) == 1,
                "another store's delete-all emptied this store's live outbox")
        let relaunched = makeStore("heartdrop-isolation-relaunch")
        #expect(relaunched.heartDropService.pendingCount(for: friend) == 1,
                "the queued heart did not survive on disk — the sidecar file was deleted by the other store's wipe, or the key sealing it was")
        #expect(relaunched.heartLedger.receivedHearts.count == 1,
                "the received-heart ledger did not survive the other store's wipe")
    }

    /// The rest of the proximity root, closed out after the heart state: moderation reports, the
    /// friend fuzzy-state cache, the closeness signal and the group-activity ledger all hung off
    /// `JSONSidecarFile`'s fixed `Application Support/Fernlet` path while `resetAll` calls
    /// `clearAll()` on every one of them — so one store's "Reset everything" deleted all four for
    /// every concurrently-live store.
    ///
    /// These were LATENT where the heart sidecars were live: same shape, but no suite read them
    /// across another's wipe, so nothing was failing yet. This test is what makes them stay fixed —
    /// it is the first reader, and without it the isolation is unenforced by anything but the
    /// grep-wall. All four are unsealed, so a root is the whole fix and there is no keychain half.
    ///
    /// Same three-store shape as the heart test above: `theirs` wipes, `mine` must not notice, and
    /// `relaunched` (built on `mine`'s root AFTER the wipe) is what proves the state was really on
    /// disk rather than merely still in memory.
    @Test func aResetInAnotherStoreLeavesThisOnesProximitySidecarsIntact() throws {
        let mine = makeStore("proximity-isolation-mine")
        let theirs = makeStore(
            "proximity-isolation-theirs",
            proximityDirectory: uniqueProximityDirectory(),
            keychainService: uniqueHeartDropKeychainService()
        )
        let hash = Data([0xAB, 0xCD])

        for store in [mine, theirs] {
            store.moderationLedger.recordLocalReport(
                reporterSigningPublicKey: Data([1]), reporterFingerprint: "me",
                subjectSigningPublicKey: Data([2]), itemID: UUID(), contentHash: hash, reason: "offensive")
            store.friendStateCache.record(
                fingerprint: "abcd1234", fuzzyState: .struggling, appearance: .standard)
            store.closenessLedger.recordSession(fingerprint: "abcd1234")
        }

        // The other suite's "Reset everything" — the funnel that clears all four.
        _ = theirs.resetAll()

        // Its own state really is gone, so the assertions below cannot pass against a reset that
        // quietly stopped resetting.
        #expect(!theirs.moderationLedger.isLocallyReported(contentHash: hash, reporterFingerprint: "me"))
        #expect(theirs.friendStateCache.state(for: "abcd1234") == nil)
        #expect(theirs.closenessLedger.closeness(fingerprint: "abcd1234") == 0)

        // Ours is untouched, and still on disk — read back through a fresh store on our root.
        let relaunched = makeStore("proximity-isolation-relaunch")
        #expect(relaunched.moderationLedger.isLocallyReported(contentHash: hash, reporterFingerprint: "me"),
                "another store's reset deleted this store's moderation ledger")
        #expect(relaunched.friendStateCache.state(for: "abcd1234") != nil,
                "another store's reset deleted this store's friend-state cache")
        #expect(relaunched.closenessLedger.closeness(fingerprint: "abcd1234") > 0,
                "another store's reset deleted this store's closeness ledger")
    }

    // MARK: - Nothing-silent copy

    /// Every delivery problem maps to a sentence on both surfaces. A nil return here is the bug the
    /// mapping exists to prevent: it puts the UI back to promising delivery it isn't making.
    @Test func everyDeliveryProblemHasCopyOnBothSurfaces() {
        let problems: [HeartDropService.DeliveryProblem] = [
            .noAccount,
            .uploadFailing(since: Date(timeIntervalSince1970: 1_780_000_000)),
            .undeliverable(count: 3),
            .storageUnavailable
        ]
        for problem in problems {
            #expect(AwayHeartsCopy.friendRowLine(for: problem)?.isEmpty == false, "no friend-row copy for \(problem)")
            #expect(AwayHeartsCopy.settingsLine(for: problem)?.isEmpty == false, "no settings copy for \(problem)")
        }
        #expect(AwayHeartsCopy.friendRowLine(for: nil) == nil)
        #expect(AwayHeartsCopy.settingsLine(for: nil) == nil)
    }

    /// One undelivered heart is not "1 hearts".
    @Test func undeliverableCopyAgreesWithItsCount() {
        #expect(AwayHeartsCopy.friendRowLine(for: .undeliverable(count: 1))?.contains("A heart") == true)
        #expect(AwayHeartsCopy.settingsLine(for: .undeliverable(count: 2))?.contains("2 hearts") == true)
    }

    /// The no-account line must not blame Fernlet's own iCloud Sync setting — the dead-drop works
    /// with sync off, so "turn on iCloud Sync" would be a wrong instruction.
    @Test func theNoAccountLineNamesTheSignInNotTheSyncToggle() {
        let settings = AwayHeartsCopy.settingsLine(for: .noAccount) ?? ""
        let row = AwayHeartsCopy.friendRowLine(for: .noAccount) ?? ""
        #expect(settings.lowercased().contains("signed in to icloud"))
        #expect(row.lowercased().contains("signed in to icloud"))
        #expect(!settings.contains("iCloud Sync"))
        #expect(!row.contains("iCloud Sync"))
    }

    /// Locked decision (Docs/Plan-Bitchat-Adoptions-2026-07-25.md): the away-hearts dead-drop is
    /// INDEPENDENT of the iCloud Sync storage preference, and the consent copy has to say so — a
    /// user reading "parked in iCloud" reasonably assumes it rides the sync toggle they already
    /// declined. Scanned from source because SwiftUI copy has no other seam.
    @Test func bothConsentSurfacesSayTheDropOffIsSeparateFromICloudSync() throws {
        let root = try Self.repoRoot()
        for path in ["Fernlet/FriendListView.swift", "Fernlet/SettingsSheet.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            #expect(source.contains("separate from iCloud Sync"),
                    "\(path) no longer tells the user the drop-off is independent of iCloud Sync")
        }
    }

    /// Turning the feature off now DISCARDS queued hearts (they are purged, not resumed), so the
    /// surface the user reads before flipping it has to say so.
    @Test func settingsSaysWhatTurningAwayDeliveryOffDoes() throws {
        let source = try String(
            contentsOf: Self.repoRoot().appendingPathComponent("Fernlet/SettingsSheet.swift"),
            encoding: .utf8
        )
        #expect(source.contains("Turning it off deletes the hearts still waiting there"))
    }

    private static func repoRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Fernlet/FernletStore.swift").path) {
                return url
            }
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
