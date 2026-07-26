// HeartDropTests.swift
// FernletTests
//
// Offline hearts dead-drop (bitchat adoptions Increment 3): day-tag derivation, the prekey/static
// outer sealer, prekey stores + one-time consumption, outbox caps/expiry, durable dedup + daily
// budget, and the full sender→transport→recipient service loop against a mock transport.
// Identity/prekey stores use UUID-scoped keychain services + defer cleanup (IdentityServiceTests
// convention); sidecars use per-test temp files.
//
// The review round of 2026-07-25 added coverage for: the backlog cap counting only UNDELIVERED
// hearts, the receiver-side flood budget, pickup window ↔ outbox lifetime alignment, delivery
// health, the mid-sync consent/cancellation guards, prekey return on a refused send, wire size
// caps, peer-cache cap/monotonicity/freshness, the drop path not arming the live receive window,
// coalesced wakeups, and the dead-drop purge.
//
// The follow-up round added: the purge's post-await re-validation (hearts queued under RENEWED
// consent must survive it), the pickup window's UTC-midnight boundary, and the sender-side per-day
// cap that mirrors the receiver's acceptance budget.

import Foundation
import Testing
import CryptoKit
import Security
import ProximityKit
import FernletFoundation
import FernletDomainModel
@testable import Fernlet

@MainActor
@Suite(.serialized)
struct HeartDropTests {

    // MARK: - Harness

    /// Shared mutable clock so the service, ledger, outbox, dedup store and bundle cache all move
    /// together (the send gate, the backlog cap and the pickup window are all time-keyed).
    /// Anchored on the REAL now, not a fixed epoch: `FernletIdentityEnvelope.verify` checks
    /// `expiresAt` against the wall clock, so a fixed fixture date would rot into expiry failures.
    nonisolated final class TestClock: @unchecked Sendable {
        var date: Date
        init(_ date: Date = Date()) { self.date = date }
        func advance(_ interval: TimeInterval) { date = date.addingTimeInterval(interval) }
    }

    /// Lets a mock transport flip consent off mid-sync, which is how the "a pass already in flight
    /// must not write after a wipe" guards are exercised deterministically.
    nonisolated final class ConsentGate: @unchecked Sendable {
        var enabled = true
        init(enabled: Bool = true) { self.enabled = enabled }
    }

    private func makeIdentity() throws -> (IdentityService, String) {
        let serviceID = "com.fernlet.identity.test.\(UUID().uuidString)"
        let service = IdentityService(keychainService: serviceID)
        try service.ensureProvisioned()
        return (service, serviceID)
    }

    private func tempFile(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("heartdrop-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name)
    }

    private func makeFriendRecord(of identity: IdentityService, name: String) -> ProximityTrustedPeerRecord {
        ProximityTrustedPeerRecord(
            id: UUID(),
            displayName: name,
            fingerprint: identity.localFingerprint,
            signingPublicKey: identity.localSigningPublicKey,
            keyAgreementPublicKey: identity.localKeyAgreementPublicKey,
            mode: .friend,
            firstAcceptedAt: Date(),
            lastSeenAt: Date()
        )
    }

    /// A gossip bundle with controlled `created`/`expires` — the monotonicity and freshness rules
    /// must not depend on how fast two `HeartPrekeyStore` mints happen to run.
    private func makeBundle(
        keyCount: Int = 1,
        created: Date,
        lifetime: TimeInterval = 30 * 24 * 3600
    ) -> HeartPrekeyStore.Bundle {
        let keys = (0..<keyCount).map { _ in
            HeartPrekeyStore.PrekeyEntry(
                id: UUID(),
                publicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
            )
        }
        return HeartPrekeyStore.Bundle(
            bundleID: UUID(),
            created: created,
            expires: created.addingTimeInterval(lifetime),
            keys: keys
        )
    }

    nonisolated final class MockDropTransport: HeartDropTransporting, @unchecked Sendable {
        var records: [HeartDropRecord] = []
        var available = true
        var failUploads = false
        /// Set to flip consent off from inside `accountAvailable()` (mid-sync guard coverage).
        var disableOnAccountCheck: ConsentGate?
        /// Suspends `fetch` (which runs AFTER flush) so a test can queue a heart at the one moment
        /// the old code dropped the wakeup: mid-pass, past that pass's flush.
        var fetchStarted = false
        var fetchYields = 0
        /// Suspends `deleteOwnRecords` so a test can act in the exact window a purge is waiting on
        /// the server — the window in which consent can be renewed and a heart queued.
        var deleteStarted = false
        var deleteYields = 0
        var failDeletes = false
        private var counter = 0
        func accountAvailable() async -> Bool {
            disableOnAccountCheck?.enabled = false
            return available
        }
        func upload(tag: String, payload: Data) async throws -> String {
            if failUploads { throw CocoaError(.fileWriteUnknown) }
            counter += 1
            let name = "rec-\(counter)"
            records.append(HeartDropRecord(tag: tag, payload: payload, recordName: name))
            return name
        }
        func fetch(tags: [String]) async throws -> [HeartDropRecord] {
            fetchStarted = true
            for _ in 0..<fetchYields { await Task.yield() }
            let wanted = Set(tags)
            return records.filter { wanted.contains($0.tag) }
        }
        func deleteOwnRecords(recordNames: [String]) async throws {
            deleteStarted = true
            for _ in 0..<deleteYields { await Task.yield() }
            if failDeletes { throw CocoaError(.fileWriteUnknown) }
            let doomed = Set(recordNames)
            records.removeAll { doomed.contains($0.recordName) }
        }
    }

    private func makeService(
        identity: IdentityService,
        prekeyService: String,
        ledger: ProximityHeartLedger,
        friends: @escaping () -> [ProximityTrustedPeerRecord],
        transport: MockDropTransport,
        enabled: @escaping () -> Bool = { true },
        clock: TestClock? = nil,
        peerBundles: HeartDropPeerBundleCache? = nil,
        outbox: HeartDropOutbox? = nil
    ) -> HeartDropService {
        let now: () -> Date
        if let clock {
            now = { clock.date }
        } else {
            now = { Date() }
        }
        let service = HeartDropService(
            ledger: ledger,
            isEnabled: enabled,
            activeFriends: friends,
            localDayKey: { FernletDate.dayKey(for: $0) },
            displayName: { "Tester" },
            identity: identity,
            prekeys: HeartPrekeyStore(keychainService: prekeyService, now: now),
            peerBundles: peerBundles ?? HeartDropPeerBundleCache(fileURL: tempFile("bundles.json"), now: now),
            outbox: outbox ?? HeartDropOutbox(fileURL: tempFile("outbox.json"), now: now),
            dedup: HeartDropDedupStore(fileURL: tempFile("dedup.json"), now: now),
            now: now
        )
        service.transport = transport
        return service
    }

    /// Bounded spin for the fire-and-forget sync path (`syncNow`/`queueHeart`'s auto-kick).
    private func waitUntil(_ condition: () -> Bool, iterations: Int = 20_000) async -> Bool {
        for _ in 0..<iterations {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    // MARK: - Day tags

    @Test func dayTagsAreDirectionalDailyAndSymmetric() throws {
        let (alice, aliceID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: aliceID) }
        let (bob, bobID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: bobID) }

        let alicePair = try alice.heartDropPairSecret(with: bob.localKeyAgreementPublicKey)
        let bobPair = try bob.heartDropPairSecret(with: alice.localKeyAgreementPublicKey)
        let day = IdentityService.heartDropDayEpoch(at: Date())

        // Symmetric pair secret: both sides derive the same tag for the same (day, sender).
        let aliceOutgoing = IdentityService.heartDropTag(
            pairSecret: alicePair, dayEpoch: day, senderKeyAgreementPublicKey: alice.localKeyAgreementPublicKey)
        let bobExpectedIncoming = IdentityService.heartDropTag(
            pairSecret: bobPair, dayEpoch: day, senderKeyAgreementPublicKey: alice.localKeyAgreementPublicKey)
        #expect(aliceOutgoing == bobExpectedIncoming)

        // Direction asymmetry: Bob's outgoing tag differs from Alice's outgoing tag.
        let bobOutgoing = IdentityService.heartDropTag(
            pairSecret: bobPair, dayEpoch: day, senderKeyAgreementPublicKey: bob.localKeyAgreementPublicKey)
        #expect(aliceOutgoing != bobOutgoing)

        // Daily rotation.
        let tomorrow = IdentityService.heartDropTag(
            pairSecret: alicePair, dayEpoch: day + 1, senderKeyAgreementPublicKey: alice.localKeyAgreementPublicKey)
        #expect(aliceOutgoing != tomorrow)
        #expect(aliceOutgoing.count == 32) // 16 bytes hex
    }

    // MARK: - Sealer

    @Test func sealerRoundTripsViaPrekeyAndStaticFallback() throws {
        let (recipient, recipientID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: recipientID) }
        let prekeyServiceID = "com.fernlet.heartdrop.test.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: prekeyServiceID) }
        let prekeys = HeartPrekeyStore(keychainService: prekeyServiceID)

        let inner = Data(#"{"hello":"drop"}"#.utf8)
        let bundle = try #require(prekeys.currentBundle())
        let prekey = try #require(bundle.keys.first)

        // Prekey path.
        let prekeySealed = try HeartDropSealer.seal(
            innerEnvelopeJSON: inner,
            toPrekey: (prekey.id, prekey.publicKey),
            orStaticKey: recipient.localKeyAgreementPublicKey
        )
        let prekeyOpened = try HeartDropSealer.open(
            prekeySealed,
            prekeyPrivateKey: { prekeys.privateKey(forPrekeyID: $0) },
            staticAgreement: { try recipient.heartDropStaticAgreement(withEphemeralPublicKey: $0) },
            staticPublicKey: recipient.localKeyAgreementPublicKey
        )
        #expect(prekeyOpened == inner)

        // Static-fallback path.
        let staticSealed = try HeartDropSealer.seal(
            innerEnvelopeJSON: inner,
            toPrekey: nil,
            orStaticKey: recipient.localKeyAgreementPublicKey
        )
        let staticOpened = try HeartDropSealer.open(
            staticSealed,
            prekeyPrivateKey: { _ in nil },
            staticAgreement: { try recipient.heartDropStaticAgreement(withEphemeralPublicKey: $0) },
            staticPublicKey: recipient.localKeyAgreementPublicKey
        )
        #expect(staticOpened == inner)

        // Both drops land in the same padded size class regardless of path.
        #expect(prekeySealed.count == staticSealed.count)

        // Wrong recipient can't open.
        let (stranger, strangerID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: strangerID) }
        #expect(throws: (any Error).self) {
            try HeartDropSealer.open(
                staticSealed,
                prekeyPrivateKey: { _ in nil },
                staticAgreement: { try stranger.heartDropStaticAgreement(withEphemeralPublicKey: $0) },
                staticPublicKey: stranger.localKeyAgreementPublicKey
            )
        }
        // Garbage rejects cleanly.
        #expect(throws: (any Error).self) {
            try HeartDropSealer.open(
                Data([9, 9, 9]),
                prekeyPrivateKey: { _ in nil },
                staticAgreement: { try recipient.heartDropStaticAgreement(withEphemeralPublicKey: $0) },
                staticPublicKey: recipient.localKeyAgreementPublicKey
            )
        }
    }

    /// A heart is ~256 B; anything near the cap is somebody else writing to the public database.
    @Test func sealerRefusesOversizedWireBothWays() throws {
        let (recipient, recipientID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: recipientID) }

        // Incompressible body well past the cap: sealing refuses to build it at all.
        var big = Data(count: 0)
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<(HeartDropSealer.maxWireByteCount * 2) {
            big.append(UInt8.random(in: 0...255, using: &generator))
        }
        #expect(throws: HeartDropSealer.SealError.oversized) {
            try HeartDropSealer.seal(
                innerEnvelopeJSON: big,
                toPrekey: nil,
                orStaticKey: recipient.localKeyAgreementPublicKey
            )
        }

        // Receipt side rejects on size BEFORE any key agreement or inflation.
        var hostile = Data([1])
        hostile.append(Data(count: HeartDropSealer.maxWireByteCount + 64))
        #expect(throws: HeartDropSealer.SealError.oversized) {
            try HeartDropSealer.open(
                hostile,
                prekeyPrivateKey: { _ in nil },
                staticAgreement: { try recipient.heartDropStaticAgreement(withEphemeralPublicKey: $0) },
                staticPublicKey: recipient.localKeyAgreementPublicKey
            )
        }
    }

    // MARK: - Prekey stores

    @Test func prekeyStoreMintsResolvesAndWipes() throws {
        let serviceID = "com.fernlet.heartdrop.test.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: serviceID) }
        let store = HeartPrekeyStore(keychainService: serviceID)

        let bundle = try #require(store.currentBundle())
        #expect(bundle.keys.count == 16)
        let entry = try #require(bundle.keys.first)
        let privateKey = try #require(store.privateKey(forPrekeyID: entry.id))
        #expect(privateKey.publicKey.rawRepresentation == entry.publicKey)

        // Stable while fresh: a second call returns the same bundle.
        #expect(store.currentBundle()?.bundleID == bundle.bundleID)

        store.wipeForDeleteAll()
        let fresh = HeartPrekeyStore(keychainService: serviceID)
        #expect(fresh.privateKey(forPrekeyID: entry.id) == nil)
    }

    /// An undecodable keychain blob is unrecoverable either way (its private halves can't be
    /// parsed), so the store mints fresh rather than wedging — distinct from an unreadable
    /// keychain, which fails closed instead.
    @Test func prekeyStoreRecoversFromACorruptBlob() throws {
        let serviceID = "com.fernlet.heartdrop.test.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: serviceID) }
        // Account name mirrors HeartPrekeyStore.keychainAccount (internal to ProximityKit).
        KeychainItem.store(
            Data("not json".utf8),
            account: "prekeyPrivateHalves",
            service: serviceID,
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            synchronizable: false
        )
        let store = HeartPrekeyStore(keychainService: serviceID)
        let bundle = try #require(store.currentBundle())
        let entry = try #require(bundle.keys.first)
        #expect(store.privateKey(forPrekeyID: entry.id) != nil)
    }

    @Test func peerBundleConsumptionIsOneTimePerSender() throws {
        let clock = TestClock()
        let cache = HeartDropPeerBundleCache(fileURL: tempFile("bundles.json"), now: { clock.date })
        let friendKey = Data([1, 2, 3])
        let bundle = makeBundle(keyCount: 16, created: clock.date)

        cache.store(bundle: bundle, forFriendSigningKey: friendKey)
        var seen = Set<UUID>()
        for _ in 0..<16 {
            let consumed = try #require(cache.consumePrekey(forFriendSigningKey: friendKey))
            #expect(!seen.contains(consumed.id))
            seen.insert(consumed.id)
        }
        #expect(cache.consumePrekey(forFriendSigningKey: friendKey) == nil)

        // Re-receiving the SAME bundle must not reset one-time marking...
        cache.store(bundle: bundle, forFriendSigningKey: friendKey)
        #expect(cache.consumePrekey(forFriendSigningKey: friendKey) == nil)
        // ...but a genuinely NEWER bundle does.
        let second = makeBundle(keyCount: 16, created: clock.date.addingTimeInterval(60))
        cache.store(bundle: second, forFriendSigningKey: friendKey)
        #expect(cache.consumePrekey(forFriendSigningKey: friendKey) != nil)
    }

    /// Gossip arrives from two coordinators, so an older intro can land after a newer one. It must
    /// never overwrite the newer bundle or re-enable prekeys we already sealed to.
    @Test func olderBundleNeverReplacesNewerAndKeepsConsumption() throws {
        let clock = TestClock()
        let cache = HeartDropPeerBundleCache(fileURL: tempFile("bundles.json"), now: { clock.date })
        let friendKey = Data([9])

        let newer = makeBundle(keyCount: 2, created: clock.date)
        cache.store(bundle: newer, forFriendSigningKey: friendKey)
        let consumed = try #require(cache.consumePrekey(forFriendSigningKey: friendKey))

        let older = makeBundle(keyCount: 2, created: clock.date.addingTimeInterval(-3600))
        cache.store(bundle: older, forFriendSigningKey: friendKey)

        // Still the newer bundle, and still one key down (the other key, not the consumed one).
        let next = try #require(cache.consumePrekey(forFriendSigningKey: friendKey))
        #expect(next.id != consumed.id)
        #expect(newer.keys.map(\.id).contains(next.id))
        #expect(cache.consumePrekey(forFriendSigningKey: friendKey) == nil)
    }

    /// Sealing to a month-old bundle is barely forward-secret; refusing falls back to the static
    /// key (nil = "seal statically"), never to a failed send.
    @Test func staleBundleIsNotSealedTo() {
        let clock = TestClock()
        let cache = HeartDropPeerBundleCache(fileURL: tempFile("bundles.json"), now: { clock.date })
        let friendKey = Data([4])
        cache.store(bundle: makeBundle(keyCount: 4, created: clock.date), forFriendSigningKey: friendKey)

        clock.advance(HeartDropPeerBundleCache.maxSealBundleAge - 3600)
        #expect(cache.consumePrekey(forFriendSigningKey: friendKey) != nil)
        clock.advance(2 * 3600)
        #expect(cache.consumePrekey(forFriendSigningKey: friendKey) == nil)
    }

    /// Bundles are ingested from any verified intro, so the map needs a cap; eviction is LRU, and
    /// a peer touched recently survives a flood of newcomers.
    @Test func peerCacheCapsAndEvictsLeastRecentlyUsed() {
        let clock = TestClock()
        let cache = HeartDropPeerBundleCache(fileURL: tempFile("bundles.json"), now: { clock.date })
        let keptKey = Data([0, 0, 1])
        let evictedKey = Data([0, 0, 2])

        cache.store(bundle: makeBundle(created: clock.date), forFriendSigningKey: evictedKey)
        clock.advance(60)
        cache.store(bundle: makeBundle(created: clock.date), forFriendSigningKey: keptKey)

        // One peer past the cap: exactly the least-recently-touched row goes.
        for index in 0..<(HeartDropPeerBundleCache.maxPeers - 1) {
            clock.advance(1)
            cache.store(
                bundle: makeBundle(created: clock.date),
                forFriendSigningKey: Data([1, UInt8(index % 256), UInt8(index / 256)])
            )
        }

        #expect(cache.consumePrekey(forFriendSigningKey: evictedKey) == nil)
        #expect(cache.consumePrekey(forFriendSigningKey: keptKey) != nil)
    }

    /// A refused send must hand the one-time key back: burning 16 of them on refusals would drop
    /// the friend into permanent static-key fallback.
    @Test func returnedPrekeyGoesBackIntoThePool() throws {
        let clock = TestClock()
        let cache = HeartDropPeerBundleCache(fileURL: tempFile("bundles.json"), now: { clock.date })
        let friendKey = Data([5])
        cache.store(bundle: makeBundle(keyCount: 1, created: clock.date), forFriendSigningKey: friendKey)

        let consumed = try #require(cache.consumePrekey(forFriendSigningKey: friendKey))
        #expect(cache.consumePrekey(forFriendSigningKey: friendKey) == nil)
        cache.returnPrekey(id: consumed.id, forFriendSigningKey: friendKey)
        #expect(cache.consumePrekey(forFriendSigningKey: friendKey)?.id == consumed.id)
    }

    // MARK: - Outbox + dedup

    @Test func outboxCapsPerFriendAndExpires() {
        var currentTime = Date(timeIntervalSince1970: 1_700_000_000)
        let outbox = HeartDropOutbox(fileURL: tempFile("outbox.json"), now: { currentTime })
        let friend = Data([7])

        for index in 0..<HeartDropOutbox.maxPendingPerFriend {
            let accepted = outbox.enqueue(HeartDropOutbox.Entry(
                id: UUID(), friendSigningKey: friend, tag: "t\(index)", wire: Data([1]), createdAt: currentTime))
            #expect(accepted)
        }
        #expect(!outbox.enqueue(HeartDropOutbox.Entry(
            id: UUID(), friendSigningKey: friend, tag: "overflow", wire: Data([1]), createdAt: currentTime)))
        #expect(outbox.pendingCount(friendSigningKey: friend) == HeartDropOutbox.maxPendingPerFriend)

        currentTime = currentTime.addingTimeInterval(HeartDropOutbox.entryLifetime + 60)
        #expect(outbox.expiredEntries().count == HeartDropOutbox.maxPendingPerFriend)
        #expect(outbox.pendingCount(friendSigningKey: friend) == 0) // expired entries don't count
        #expect(outbox.expiredUndeliveredCount() == HeartDropOutbox.maxPendingPerFriend)
        outbox.remove(ids: outbox.expiredEntries().map(\.id))
        #expect(outbox.expiredEntries().isEmpty)
    }

    /// The cap bounds the UNDELIVERED backlog. Uploaded entries stay in the outbox (cleanup needs
    /// their record names) but they have already been delivered, so they must neither block new
    /// hearts nor read as "waiting" in the friend row.
    @Test func backlogCapCountsOnlyUndeliveredHearts() {
        let currentTime = Date(timeIntervalSince1970: 1_700_000_000)
        let outbox = HeartDropOutbox(fileURL: tempFile("outbox.json"), now: { currentTime })
        let friend = Data([7])

        var ids: [UUID] = []
        for index in 0..<HeartDropOutbox.maxPendingPerFriend {
            let id = UUID()
            ids.append(id)
            outbox.enqueue(HeartDropOutbox.Entry(
                id: id, friendSigningKey: friend, tag: "t\(index)", wire: Data([1]), createdAt: currentTime))
        }
        #expect(!outbox.hasCapacity(forFriendSigningKey: friend))

        for (index, id) in ids.enumerated() {
            outbox.markUploaded(id: id, recordName: "rec-\(index)")
        }
        #expect(outbox.pendingCount(friendSigningKey: friend) == 0)
        #expect(outbox.hasCapacity(forFriendSigningKey: friend))
        #expect(outbox.enqueue(HeartDropOutbox.Entry(
            id: UUID(), friendSigningKey: friend, tag: "ninth", wire: Data([1]), createdAt: currentTime)))
        // ...and the delivered entries are still retained for cleanup.
        #expect(outbox.uploadedRecordNames().count == HeartDropOutbox.maxPendingPerFriend)
    }

    /// The daily cap counts UPLOADED entries too — they are precisely the ones already spending the
    /// recipient's acceptance budget — and it rolls over on the UTC day, which is the bucket the
    /// receiver derives from the signed `createdAt`.
    @Test func dailyCapCountsDeliveredHeartsAndRollsOverOnTheUTCDay() {
        var currentTime = Date(timeIntervalSince1970: 1_700_000_000)
        let outbox = HeartDropOutbox(fileURL: tempFile("outbox.json"), now: { currentTime })
        let friend = Data([7])

        for index in 0..<HeartDropOutbox.maxPerFriendPerDay {
            #expect(outbox.hasDailyCapacity(forFriendSigningKey: friend, at: currentTime))
            let id = UUID()
            outbox.enqueue(HeartDropOutbox.Entry(
                id: id, friendSigningKey: friend, tag: "t\(index)", wire: Data([1]), createdAt: currentTime))
            outbox.markUploaded(id: id, recordName: "rec-\(index)") // delivered straight away
        }
        #expect(!outbox.hasDailyCapacity(forFriendSigningKey: friend, at: currentTime))
        #expect(outbox.hasCapacity(forFriendSigningKey: friend)) // backlog empty: only the day cap binds
        #expect(outbox.hasDailyCapacity(forFriendSigningKey: Data([8]), at: currentTime)) // per friend

        currentTime = currentTime.addingTimeInterval(86_400)
        #expect(outbox.hasDailyCapacity(forFriendSigningKey: friend, at: currentTime))
    }

    /// The purge captures the outbox, suspends on the network, then removes what it captured. An
    /// entry UPLOADED during that suspension must be KEPT: its record name was minted after the
    /// capture, so it was never handed to the remote delete — dropping it would leave a record on
    /// the public database that only this device could ever have named. A heart queued during the
    /// suspension must survive untouched.
    @Test func removeUnchangedSkipsEntriesThatMovedDuringTheCapture() {
        let currentTime = Date(timeIntervalSince1970: 1_700_000_000)
        let outbox = HeartDropOutbox(fileURL: tempFile("outbox.json"), now: { currentTime })
        let friend = Data([7])
        let uploaded = UUID()
        let racing = UUID()
        let waiting = UUID()
        for (index, id) in [uploaded, racing, waiting].enumerated() {
            outbox.enqueue(HeartDropOutbox.Entry(
                id: id, friendSigningKey: friend, tag: "t\(index)", wire: Data([1]), createdAt: currentTime))
        }
        outbox.markUploaded(id: uploaded, recordName: "rec-1")

        let captured = outbox.snapshot()
        outbox.markUploaded(id: racing, recordName: "rec-2") // uploaded mid-purge
        let newcomer = UUID()
        outbox.enqueue(HeartDropOutbox.Entry(
            id: newcomer, friendSigningKey: friend, tag: "new", wire: Data([1]), createdAt: currentTime))

        #expect(outbox.removeUnchanged(captured) == 2) // the uploaded one and the still-waiting one
        #expect(outbox.uploadedRecordNames() == ["rec-2"])
        #expect(Set(outbox.snapshot().map(\.id)) == [racing, newcomer])
    }

    @Test func dedupIsDurableAndBudgetsPerSenderDay() {
        let url = tempFile("dedup.json")
        let clock = TestClock()
        let dedup = HeartDropDedupStore(fileURL: url, now: { clock.date })
        let envelopeID = UUID()
        #expect(dedup.recordIfNew(envelopeID: envelopeID))
        #expect(!dedup.recordIfNew(envelopeID: envelopeID))
        // Durability: a fresh instance over the same file still knows it.
        let reloaded = HeartDropDedupStore(fileURL: url, now: { clock.date })
        #expect(!reloaded.recordIfNew(envelopeID: envelopeID))

        let today = IdentityService.heartDropDayEpoch(at: clock.date)
        for _ in 0..<HeartDropDedupStore.maxAcceptedPerSenderPerDay {
            #expect(reloaded.acceptIfWithinDailyBudget(senderFingerprint: "abc", dayEpoch: today))
        }
        #expect(!reloaded.acceptIfWithinDailyBudget(senderFingerprint: "abc", dayEpoch: today))
        #expect(reloaded.acceptIfWithinDailyBudget(senderFingerprint: "abc", dayEpoch: today + 1))
        // A different sender has its own budget.
        #expect(reloaded.acceptIfWithinDailyBudget(senderFingerprint: "xyz", dayEpoch: today))
    }

    /// Counters prune BY DAY. The old size-tripped `removeAll()` could be provoked deliberately to
    /// hand every sender a fresh budget; ageing out is the only thing that may reset one.
    @Test func dedupBudgetResetsOnlyByAgeing() {
        let clock = TestClock()
        let dedup = HeartDropDedupStore(fileURL: tempFile("dedup.json"), now: { clock.date })
        let day = IdentityService.heartDropDayEpoch(at: clock.date)

        for _ in 0..<HeartDropDedupStore.maxAcceptedPerSenderPerDay {
            #expect(dedup.acceptIfWithinDailyBudget(senderFingerprint: "abc", dayEpoch: day))
        }
        #expect(!dedup.acceptIfWithinDailyBudget(senderFingerprint: "abc", dayEpoch: day))

        // Traffic from many other senders does not clear the map.
        for index in 0..<200 {
            #expect(dedup.acceptIfWithinDailyBudget(senderFingerprint: "sender-\(index)", dayEpoch: day))
        }
        #expect(!dedup.acceptIfWithinDailyBudget(senderFingerprint: "abc", dayEpoch: day))

        // Past retention the day bucket is pruned and the same key is spendable again.
        clock.advance(HeartDropDedupStore.retention + 86_400)
        #expect(dedup.acceptIfWithinDailyBudget(senderFingerprint: "abc", dayEpoch: day))
    }

    // MARK: - Service end-to-end

    @Test func heartTravelsSenderToRecipientOnceWithPrekeyFS() async throws {
        let (sender, senderID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: senderID) }
        let (recipient, recipientID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: recipientID) }
        let senderPrekeySvc = "com.fernlet.heartdrop.test.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: senderPrekeySvc) }
        let recipientPrekeySvc = "com.fernlet.heartdrop.test.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: recipientPrekeySvc) }

        let transport = MockDropTransport()
        let senderLedger = ProximityHeartLedger(fileURL: tempFile("sender-ledger.json"))
        let recipientLedger = ProximityHeartLedger(fileURL: tempFile("recipient-ledger.json"))

        let recipientRecord = makeFriendRecord(of: recipient, name: "Bobby Fern")
        let senderRecord = makeFriendRecord(of: sender, name: "Alice Fern")

        let senderService = makeService(
            identity: sender, prekeyService: senderPrekeySvc, ledger: senderLedger,
            friends: { [recipientRecord] }, transport: transport)
        let recipientPrekeys = HeartPrekeyStore(keychainService: recipientPrekeySvc)
        let recipientService = HeartDropService(
            ledger: recipientLedger,
            isEnabled: { true },
            activeFriends: { [senderRecord] },
            localDayKey: { FernletDate.dayKey(for: $0) },
            displayName: { "Bobby" },
            identity: recipient,
            prekeys: recipientPrekeys,
            peerBundles: HeartDropPeerBundleCache(fileURL: tempFile("r-bundles.json")),
            outbox: HeartDropOutbox(fileURL: tempFile("r-outbox.json")),
            dedup: HeartDropDedupStore(fileURL: tempFile("r-dedup.json"))
        )
        recipientService.transport = transport

        // Simulate gossip: sender holds the recipient's current prekey bundle.
        let bundle = try #require(recipientService.currentLocalBundle())
        senderService.storePeerBundle(bundle, friendSigningKey: recipient.localSigningPublicKey)

        // Queue + flush on the sender.
        #expect(senderService.queueHeart(to: recipientRecord) == .queued)
        #expect(senderService.queueHeart(to: recipientRecord) == .rateLimited) // consume-on-queue
        await senderService.syncOnce()
        #expect(transport.records.count == 1)
        #expect(senderService.pendingCount(for: recipientRecord) == 0) // delivered, not "waiting"

        // Recipient fetches and the heart lands in its ledger exactly once.
        await recipientService.syncOnce()
        #expect(recipientLedger.receivedHearts.count == 1)
        #expect(recipientLedger.receivedHearts.first?.senderFingerprint == sender.localFingerprint)

        // A second sync re-fetches the same record but the durable dedup drops it.
        await recipientService.syncOnce()
        #expect(recipientLedger.receivedHearts.count == 1)
    }

    @Test func heartFallsBackToStaticSealWithoutABundle() async throws {
        let (sender, senderID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: senderID) }
        let (recipient, recipientID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: recipientID) }
        let senderPrekeySvc = "com.fernlet.heartdrop.test.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: senderPrekeySvc) }
        let recipientPrekeySvc = "com.fernlet.heartdrop.test.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: recipientPrekeySvc) }

        let transport = MockDropTransport()
        let recipientRecord = makeFriendRecord(of: recipient, name: "Bobby Fern")
        let senderRecord = makeFriendRecord(of: sender, name: "Alice Fern")
        let senderService = makeService(
            identity: sender, prekeyService: senderPrekeySvc,
            ledger: ProximityHeartLedger(fileURL: tempFile("s-ledger.json")),
            friends: { [recipientRecord] }, transport: transport)
        let recipientLedger = ProximityHeartLedger(fileURL: tempFile("r-ledger.json"))
        let recipientService = HeartDropService(
            ledger: recipientLedger,
            isEnabled: { true },
            activeFriends: { [senderRecord] },
            localDayKey: { FernletDate.dayKey(for: $0) },
            displayName: { "Bobby" },
            identity: recipient,
            prekeys: HeartPrekeyStore(keychainService: recipientPrekeySvc),
            peerBundles: HeartDropPeerBundleCache(fileURL: tempFile("rb.json")),
            outbox: HeartDropOutbox(fileURL: tempFile("ro.json")),
            dedup: HeartDropDedupStore(fileURL: tempFile("rd.json"))
        )
        recipientService.transport = transport

        #expect(senderService.queueHeart(to: recipientRecord) == .queued) // no bundle → static seal
        await senderService.syncOnce()
        await recipientService.syncOnce()
        #expect(recipientLedger.receivedHearts.count == 1)
    }

    @Test func consentGateBlocksQueueAndSync() async throws {
        let (sender, senderID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: senderID) }
        let (recipient, recipientID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: recipientID) }
        let prekeySvc = "com.fernlet.heartdrop.test.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: prekeySvc) }

        let transport = MockDropTransport()
        let recipientRecord = makeFriendRecord(of: recipient, name: "Bobby Fern")
        let service = makeService(
            identity: sender, prekeyService: prekeySvc,
            ledger: ProximityHeartLedger(fileURL: tempFile("ledger.json")),
            friends: { [recipientRecord] }, transport: transport,
            enabled: { false })

        #expect(service.queueHeart(to: recipientRecord) == .disabled)
        #expect(service.currentLocalBundle() == nil) // no gossip while opted out
        await service.syncOnce()
        #expect(transport.records.isEmpty)
    }

    /// The pickup window is DERIVED from the outbox lifetime, so a friend who does not open the
    /// app for over a week still gets the heart the sender is still holding.
    @Test func pickupWindowCoversTheWholeOutboxLifetime() async throws {
        #expect(HeartDropService.pickupWindowDays == UInt64(HeartDropOutbox.entryLifetime / 86_400))

        let (sender, senderID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: senderID) }
        let (recipient, recipientID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: recipientID) }
        let senderPrekeySvc = "com.fernlet.heartdrop.test.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: senderPrekeySvc) }
        let recipientPrekeySvc = "com.fernlet.heartdrop.test.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: recipientPrekeySvc) }

        let clock = TestClock()
        let transport = MockDropTransport()
        let recipientRecord = makeFriendRecord(of: recipient, name: "Bobby Fern")
        let senderRecord = makeFriendRecord(of: sender, name: "Alice Fern")

        let senderService = makeService(
            identity: sender, prekeyService: senderPrekeySvc,
            ledger: ProximityHeartLedger(fileURL: tempFile("s-ledger.json"), now: { clock.date }),
            friends: { [recipientRecord] }, transport: transport, clock: clock)
        #expect(senderService.queueHeart(to: recipientRecord) == .queued)
        await senderService.syncOnce()
        #expect(transport.records.count == 1)

        // Ten days later — well past the old 7-day tag window, still inside the outbox lifetime.
        clock.advance(10 * 86_400)
        let recipientLedger = ProximityHeartLedger(fileURL: tempFile("r-ledger.json"), now: { clock.date })
        let recipientService = HeartDropService(
            ledger: recipientLedger,
            isEnabled: { true },
            activeFriends: { [senderRecord] },
            localDayKey: { FernletDate.dayKey(for: $0) },
            displayName: { "Bobby" },
            identity: recipient,
            prekeys: HeartPrekeyStore(keychainService: recipientPrekeySvc, now: { clock.date }),
            peerBundles: HeartDropPeerBundleCache(fileURL: tempFile("rb.json"), now: { clock.date }),
            outbox: HeartDropOutbox(fileURL: tempFile("ro.json"), now: { clock.date }),
            dedup: HeartDropDedupStore(fileURL: tempFile("rd.json"), now: { clock.date }),
            now: { clock.date }
        )
        recipientService.transport = transport

        await recipientService.syncOnce()
        #expect(recipientLedger.receivedHearts.count == 1)
    }

    /// The boundary the derivation used to get wrong by one day. Entries expire in CONTINUOUS time
    /// (`createdAt + entryLifetime`) while tags rotate on UTC midnights, so a drop created a minute
    /// before a midnight is still live — still on the server, still counted as deliverable by the
    /// sender — after the 14th midnight, at which point its creation day sits at offset 14. With the
    /// old `0...13` window that record was unfindable for the last stretch of its paid-for life.
    @Test func pickupWindowFindsADropCreatedJustBeforeAUTCMidnight() async throws {
        let (sender, senderID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: senderID) }
        let (recipient, recipientID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: recipientID) }
        let senderPrekeySvc = "com.fernlet.heartdrop.test.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: senderPrekeySvc) }
        let recipientPrekeySvc = "com.fernlet.heartdrop.test.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: recipientPrekeySvc) }

        // 60 s before a UTC midnight, anchored on the real clock: the envelope's `expiresAt` is
        // checked against the wall clock, so a fixed fixture date would rot into expiry failures.
        let today = (Date().timeIntervalSince1970 / 86_400).rounded(.down) * 86_400
        let clock = TestClock(Date(timeIntervalSince1970: today + 86_400 - 60))
        let transport = MockDropTransport()
        let recipientRecord = makeFriendRecord(of: recipient, name: "Bobby Fern")
        let senderRecord = makeFriendRecord(of: sender, name: "Alice Fern")

        let senderService = makeService(
            identity: sender, prekeyService: senderPrekeySvc,
            ledger: ProximityHeartLedger(fileURL: tempFile("s-ledger.json"), now: { clock.date }),
            friends: { [recipientRecord] }, transport: transport, clock: clock)
        #expect(senderService.queueHeart(to: recipientRecord) == .queued)
        await senderService.syncOnce()
        #expect(transport.records.count == 1)

        // The very last minutes of the entry's life: NOT expired, but 14 UTC midnights have passed.
        clock.advance(HeartDropOutbox.entryLifetime - 120)
        await senderService.syncOnce()
        #expect(transport.records.count == 1) // the sender has not given up on it yet

        let recipientLedger = ProximityHeartLedger(fileURL: tempFile("r-ledger.json"), now: { clock.date })
        let recipientService = HeartDropService(
            ledger: recipientLedger,
            isEnabled: { true },
            activeFriends: { [senderRecord] },
            localDayKey: { FernletDate.dayKey(for: $0) },
            displayName: { "Bobby" },
            identity: recipient,
            prekeys: HeartPrekeyStore(keychainService: recipientPrekeySvc, now: { clock.date }),
            peerBundles: HeartDropPeerBundleCache(fileURL: tempFile("rb.json"), now: { clock.date }),
            outbox: HeartDropOutbox(fileURL: tempFile("ro.json"), now: { clock.date }),
            dedup: HeartDropDedupStore(fileURL: tempFile("rd.json"), now: { clock.date }),
            now: { clock.date }
        )
        recipientService.transport = transport

        await recipientService.syncOnce()
        #expect(recipientLedger.receivedHearts.count == 1)
    }

    /// The sender must stop at the same per-day budget the receiver enforces. Uploaded entries free
    /// backlog capacity immediately, so without this the 5-minute gate alone allowed ~288 hearts a
    /// day to one friend — of which the recipient accepts 3 and silently discards the rest, AFTER
    /// they were sealed, uploaded, stored on the public database and reported back as delivered.
    @Test func senderStopsAtTheReceiversDailyBudget() async throws {
        let (sender, senderID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: senderID) }
        let (recipient, recipientID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: recipientID) }
        let prekeySvc = "com.fernlet.heartdrop.test.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: prekeySvc) }

        // Mid-day anchor so the whole batch lands in one UTC day.
        let today = (Date().timeIntervalSince1970 / 86_400).rounded(.down) * 86_400
        let clock = TestClock(Date(timeIntervalSince1970: today + 3_600))
        let transport = MockDropTransport()
        let cache = HeartDropPeerBundleCache(fileURL: tempFile("bundles.json"), now: { clock.date })
        let ledger = ProximityHeartLedger(fileURL: tempFile("ledger.json"), now: { clock.date })
        let recipientRecord = makeFriendRecord(of: recipient, name: "Bobby Fern")
        let service = makeService(
            identity: sender, prekeyService: prekeySvc, ledger: ledger,
            friends: { [recipientRecord] }, transport: transport, clock: clock, peerBundles: cache)

        let keyCount = HeartDropOutbox.maxPerFriendPerDay + 4
        cache.store(
            bundle: makeBundle(keyCount: keyCount, created: clock.date),
            forFriendSigningKey: recipient.localSigningPublicKey
        )

        // Each heart is uploaded before the next, so the backlog cap never binds — the day budget is
        // the only thing left holding the line.
        for _ in 0..<HeartDropOutbox.maxPerFriendPerDay {
            #expect(service.queueHeart(to: recipientRecord) == .queued)
            await service.syncOnce()
            clock.advance(6 * 60) // past the 5-minute send gate
        }
        #expect(service.pendingCount(for: recipientRecord) == 0) // all delivered: backlog is empty
        #expect(transport.records.count == HeartDropOutbox.maxPerFriendPerDay)

        #expect(service.queueHeart(to: recipientRecord) == .dailyLimitReached)
        #expect(transport.records.count == HeartDropOutbox.maxPerFriendPerDay) // nothing uploaded
        // Refusing costs nothing irreversible, exactly like the backlog refusal.
        #expect(ledger.canSendHeart(to: recipientRecord.fingerprint))
        var remaining = 0
        while cache.consumePrekey(forFriendSigningKey: recipient.localSigningPublicKey) != nil {
            remaining += 1
        }
        #expect(remaining == keyCount - HeartDropOutbox.maxPerFriendPerDay)

        // The budget is a UTC DAY, matching the bucket the receiver derives from the signed
        // `createdAt` — so it comes back with the next day, not with the 5-minute gate.
        clock.advance(86_400)
        #expect(service.queueHeart(to: recipientRecord) == .queued)
    }

    /// The sender-side cap is DERIVED from the receiver's, so the two cannot drift into a state
    /// where a heart is uploaded and paid for only to be discarded on arrival.
    @Test func senderDailyCapMatchesTheReceiverBudget() {
        #expect(HeartDropOutbox.maxPerFriendPerDay == HeartDropDedupStore.maxAcceptedPerSenderPerDay)
    }

    /// The backlog cap must be checked BEFORE the one-time prekey is consumed and before the
    /// 5-minute cooldown is spent — a refused heart costs neither.
    @Test func refusedHeartBurnsNoPrekeyAndNoCooldown() async throws {
        let (sender, senderID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: senderID) }
        let (recipient, recipientID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: recipientID) }
        let prekeySvc = "com.fernlet.heartdrop.test.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: prekeySvc) }

        let clock = TestClock()
        let transport = MockDropTransport()
        transport.available = false // nothing uploads, so the backlog genuinely fills
        let cache = HeartDropPeerBundleCache(fileURL: tempFile("bundles.json"), now: { clock.date })
        let ledger = ProximityHeartLedger(fileURL: tempFile("ledger.json"), now: { clock.date })
        let recipientRecord = makeFriendRecord(of: recipient, name: "Bobby Fern")
        let service = makeService(
            identity: sender, prekeyService: prekeySvc, ledger: ledger,
            friends: { [recipientRecord] }, transport: transport, clock: clock, peerBundles: cache)

        let keyCount = HeartDropOutbox.maxPendingPerFriend + 4
        cache.store(
            bundle: makeBundle(keyCount: keyCount, created: clock.date),
            forFriendSigningKey: recipient.localSigningPublicKey
        )

        // The per-day cap (3) sits below the backlog cap (8), so filling the backlog now spans UTC
        // days — nothing else in the test changes: the refusal at the top must still cost nothing.
        var queued = 0
        while queued < HeartDropOutbox.maxPendingPerFriend {
            #expect(service.queueHeart(to: recipientRecord) == .queued)
            queued += 1
            if queued % HeartDropOutbox.maxPerFriendPerDay == 0 {
                clock.advance(86_400) // next UTC day: the daily budget resets
            } else {
                clock.advance(6 * 60) // past the 5-minute send gate
            }
        }
        #expect(service.pendingCount(for: recipientRecord) == HeartDropOutbox.maxPendingPerFriend)
        #expect(service.queueHeart(to: recipientRecord) == .backlogFull)

        // Exactly the delivered hearts consumed a prekey; the refusal consumed none.
        var remaining = 0
        while cache.consumePrekey(forFriendSigningKey: recipient.localSigningPublicKey) != nil {
            remaining += 1
        }
        #expect(remaining == keyCount - HeartDropOutbox.maxPendingPerFriend)
        // And the cooldown was not spent either — the refusal is retryable immediately.
        #expect(ledger.canSendHeart(to: recipientRecord.fingerprint))
    }

    /// Nothing-silent: a user with no iCloud account, or whose uploads keep failing, must be able
    /// to learn that the "will be delivered" promise is not being kept.
    @Test func deliveryProblemsAreObservable() async throws {
        let (sender, senderID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: senderID) }
        let (recipient, recipientID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: recipientID) }
        let prekeySvc = "com.fernlet.heartdrop.test.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: prekeySvc) }

        let clock = TestClock()
        let transport = MockDropTransport()
        let recipientRecord = makeFriendRecord(of: recipient, name: "Bobby Fern")
        let service = makeService(
            identity: sender, prekeyService: prekeySvc,
            ledger: ProximityHeartLedger(fileURL: tempFile("ledger.json"), now: { clock.date }),
            friends: { [recipientRecord] }, transport: transport, clock: clock)

        // No account at all.
        transport.available = false
        await service.syncOnce()
        #expect(service.deliveryProblem == .noAccount)

        // Account back, uploads failing.
        transport.available = true
        transport.failUploads = true
        let queuedAt = clock.date
        #expect(service.queueHeart(to: recipientRecord) == .queued)
        for _ in 0..<HeartDropService.failingAttemptThreshold {
            await service.syncOnce()
        }
        #expect(service.deliveryProblem == .uploadFailing(since: queuedAt))

        // Never delivered before the outbox lifetime ran out.
        clock.advance(HeartDropOutbox.entryLifetime + 60)
        await service.syncOnce()
        #expect(service.deliveryProblem == .undeliverable(count: 1))
        #expect(service.pendingCount(for: recipientRecord) == 0)

        service.acknowledgeDeliveryProblem()
        #expect(service.deliveryProblem == nil)

        // Healthy again once uploads succeed.
        transport.failUploads = false
        clock.advance(6 * 60)
        #expect(service.queueHeart(to: recipientRecord) == .queued)
        await service.syncOnce()
        #expect(service.deliveryProblem == nil)
        #expect(transport.records.count == 1)
    }

    /// A pass already in flight when consent is withdrawn (or delete-all runs) must stop at its
    /// next await instead of uploading and writing into just-cleared stores.
    @Test func syncStopsAtTheNextAwaitWhenConsentDropsMidPass() async throws {
        let (sender, senderID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: senderID) }
        let (recipient, recipientID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: recipientID) }
        let prekeySvc = "com.fernlet.heartdrop.test.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: prekeySvc) }

        let gate = ConsentGate()
        let transport = MockDropTransport()
        let recipientRecord = makeFriendRecord(of: recipient, name: "Bobby Fern")
        let service = makeService(
            identity: sender, prekeyService: prekeySvc,
            ledger: ProximityHeartLedger(fileURL: tempFile("ledger.json")),
            friends: { [recipientRecord] }, transport: transport,
            enabled: { gate.enabled })

        // No account yet, so the heart is still sitting un-uploaded when the next pass starts.
        transport.available = false
        #expect(service.queueHeart(to: recipientRecord) == .queued)
        _ = await waitUntil { !service.isSyncing }
        #expect(transport.records.isEmpty)

        // The next pass flips consent off inside `accountAvailable()`: it must return before its
        // flush rather than uploading a heart the user has just opted out of.
        transport.available = true
        transport.disableOnAccountCheck = gate
        await service.syncOnce()
        #expect(transport.records.isEmpty)
        #expect(service.pendingCount(for: recipientRecord) == 1)

        gate.enabled = true
        transport.disableOnAccountCheck = nil
        service.wipeForDeleteAll()
        #expect(!service.isSyncing)
        #expect(service.pendingCount(for: recipientRecord) == 0)
    }

    /// A heart queued while a sync is already running used to wait for the next foreground event;
    /// the wakeup is now coalesced into a re-run of the same pass.
    @Test func heartQueuedDuringAnInFlightSyncStillUploads() async throws {
        let (sender, senderID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: senderID) }
        let (first, firstID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: firstID) }
        let (second, secondID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: secondID) }
        let prekeySvc = "com.fernlet.heartdrop.test.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: prekeySvc) }

        let transport = MockDropTransport()
        let firstFriend = makeFriendRecord(of: first, name: "One Fern")
        let secondFriend = makeFriendRecord(of: second, name: "Two Fern")
        let service = makeService(
            identity: sender, prekeyService: prekeySvc,
            ledger: ProximityHeartLedger(fileURL: tempFile("ledger.json")),
            friends: { [firstFriend, secondFriend] }, transport: transport)

        // Hold the pass inside `fetch`, i.e. AFTER its flush — the exact window in which the old
        // `guard !isSyncing else { return }` threw the wakeup away.
        transport.fetchYields = 50
        #expect(service.queueHeart(to: firstFriend) == .queued)
        #expect(service.isSyncing)
        let reachedFetch = await waitUntil { transport.fetchStarted }
        #expect(reachedFetch)

        #expect(service.queueHeart(to: secondFriend) == .queued)
        #expect(service.isSyncing) // still the same pass — this queue must coalesce into it

        // Wait on the OUTBOX, not the mock's record list: the record is appended inside `upload`,
        // a beat before the outbox is marked, so waiting on the latter is the settled state.
        let bothDelivered = await waitUntil { service.pendingCount(for: secondFriend) == 0 }
        #expect(bothDelivered)
        #expect(transport.records.count == 2)
    }

    /// Turning the toggle off (or wiping) must not strand our own records on the public database —
    /// nobody else can delete them.
    @Test func purgeDeletesOwnRecordsAndClearsTheOutbox() async throws {
        let (sender, senderID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: senderID) }
        let (recipient, recipientID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: recipientID) }
        let prekeySvc = "com.fernlet.heartdrop.test.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: prekeySvc) }

        let clock = TestClock()
        let transport = MockDropTransport()
        let recipientRecord = makeFriendRecord(of: recipient, name: "Bobby Fern")
        let gate = ConsentGate()
        let service = makeService(
            identity: sender, prekeyService: prekeySvc,
            ledger: ProximityHeartLedger(fileURL: tempFile("ledger.json"), now: { clock.date }),
            friends: { [recipientRecord] }, transport: transport,
            enabled: { gate.enabled }, clock: clock)

        #expect(service.queueHeart(to: recipientRecord) == .queued)
        await service.syncOnce()
        #expect(transport.records.count == 1)

        gate.enabled = false // consent withdrawn: the purge must bypass the gate
        #expect(service.hasStrandedDeadDropRecords())
        let purged = await service.purgeDeadDrop()
        #expect(purged)
        #expect(transport.records.isEmpty)
        #expect(service.pendingCount(for: recipientRecord) == 0)
        #expect(!service.hasStrandedDeadDropRecords())
    }

    /// The remote delete is a suspension point long enough for the user to turn away-hearts back ON
    /// and send. The purge's tail used to `removeAll()`: it destroyed that heart, and had it already
    /// uploaded, its record name with it — stranding a record only this device can ever name.
    @Test func purgeKeepsHeartsQueuedWhileItsRemoteDeleteIsInFlight() async throws {
        let (sender, senderID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: senderID) }
        let (recipient, recipientID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: recipientID) }
        let prekeySvc = "com.fernlet.heartdrop.test.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: prekeySvc) }

        let clock = TestClock()
        let transport = MockDropTransport()
        let recipientRecord = makeFriendRecord(of: recipient, name: "Bobby Fern")
        let gate = ConsentGate()
        let service = makeService(
            identity: sender, prekeyService: prekeySvc,
            ledger: ProximityHeartLedger(fileURL: tempFile("ledger.json"), now: { clock.date }),
            friends: { [recipientRecord] }, transport: transport,
            enabled: { gate.enabled }, clock: clock)

        #expect(service.queueHeart(to: recipientRecord) == .queued)
        await service.syncOnce()
        #expect(transport.records.count == 1)

        // Consent off → the purge parks inside the server delete.
        gate.enabled = false
        transport.deleteYields = 50
        transport.available = false // keep the re-enabled send un-uploaded so it stays assertable
        let purge = Task { await service.purgeDeadDrop() }
        let reachedDelete = await waitUntil { transport.deleteStarted }
        #expect(reachedDelete)

        // ...and mid-delete the user changes their mind and sends again.
        gate.enabled = true
        clock.advance(6 * 60) // past the 5-minute send gate
        #expect(service.queueHeart(to: recipientRecord) == .queued)

        let purged = await purge.value
        #expect(purged)
        #expect(transport.records.isEmpty) // the captured record really was deleted
        #expect(service.pendingCount(for: recipientRecord) == 1) // the renewed-consent heart survived
        #expect(!service.hasStrandedDeadDropRecords())
    }

    /// A failed remote delete keeps the record names: they are the only handle anything has on our
    /// own public-database records, and the app layer re-derives "a purge is still owed" from them
    /// (a process-local flag dies with the process, and never runs at all when consent is withdrawn
    /// on another device and arrives by settings sync).
    @Test func failedPurgeKeepsTheRecordNamesForARetry() async throws {
        let (sender, senderID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: senderID) }
        let (recipient, recipientID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: recipientID) }
        let prekeySvc = "com.fernlet.heartdrop.test.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: prekeySvc) }

        let clock = TestClock()
        let transport = MockDropTransport()
        let recipientRecord = makeFriendRecord(of: recipient, name: "Bobby Fern")
        let gate = ConsentGate()
        let service = makeService(
            identity: sender, prekeyService: prekeySvc,
            ledger: ProximityHeartLedger(fileURL: tempFile("ledger.json"), now: { clock.date }),
            friends: { [recipientRecord] }, transport: transport,
            enabled: { gate.enabled }, clock: clock)

        #expect(service.queueHeart(to: recipientRecord) == .queued)
        await service.syncOnce()
        #expect(service.uploadedDeadDropRecordCount() == 1)

        gate.enabled = false
        transport.failDeletes = true
        let failedPurge = await service.purgeDeadDrop()
        #expect(!failedPurge)
        #expect(service.hasStrandedDeadDropRecords()) // still owed, still addressable
        #expect(transport.records.count == 1)

        transport.failDeletes = false
        let retriedPurge = await service.purgeDeadDrop()
        #expect(retriedPurge)
        #expect(!service.hasStrandedDeadDropRecords())
        #expect(transport.records.isEmpty)
    }

    // MARK: - Ledger interaction

    /// Picking up a days-old drop must not arm the LIVE 5-minute receive window, or it would
    /// swallow the next in-person heart from that friend.
    @Test func dropHeartDoesNotArmTheLiveReceiveWindow() {
        let ledger = ProximityHeartLedger(fileURL: tempFile("ledger.json"))
        #expect(ledger.recordReceivedDropHeart(
            id: UUID(), senderDisplayName: "Fern", senderFingerprint: "abc"))
        #expect(ledger.recordReceivedHeart(
            id: UUID(), senderDisplayName: "Fern", senderFingerprint: "abc"))
        // The live path still mirrors its own window.
        #expect(!ledger.recordReceivedHeart(
            id: UUID(), senderDisplayName: "Fern", senderFingerprint: "abc"))
        #expect(ledger.receivedHearts.count == 2)
    }
}
