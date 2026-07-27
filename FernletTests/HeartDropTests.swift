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
        lifetime: TimeInterval = 30 * 24 * 3600,
        signedPrekey: HeartPrekeyStore.SignedPrekey? = nil
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
            keys: keys,
            signedPrekey: signedPrekey
        )
    }

    private func makeSignedPrekey(created: Date) -> HeartPrekeyStore.SignedPrekey {
        HeartPrekeyStore.SignedPrekey(
            id: UUID(),
            publicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
            created: created,
            expires: created.addingTimeInterval(7 * 24 * 3600)
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
            #expect(accepted == .queued)
        }
        #expect(outbox.enqueue(HeartDropOutbox.Entry(
            id: UUID(), friendSigningKey: friend, tag: "overflow", wire: Data([1]), createdAt: currentTime)) == .backlogFull)
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
            id: UUID(), friendSigningKey: friend, tag: "ninth", wire: Data([1]), createdAt: currentTime)) == .queued)
        // ...and the delivered entries are still retained for cleanup.
        #expect(outbox.uploadedRecordNames()?.count == HeartDropOutbox.maxPendingPerFriend)
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

        let captured = outbox.snapshot() ?? []
        outbox.markUploaded(id: racing, recordName: "rec-2") // uploaded mid-purge
        let newcomer = UUID()
        outbox.enqueue(HeartDropOutbox.Entry(
            id: newcomer, friendSigningKey: friend, tag: "new", wire: Data([1]), createdAt: currentTime))

        #expect(outbox.removeUnchanged(captured) == 2) // the uploaded one and the still-waiting one
        #expect(outbox.uploadedRecordNames() == ["rec-2"])
        #expect(Set((outbox.snapshot() ?? []).map(\.id)) == [racing, newcomer])
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
            #expect(reloaded.acceptIfWithinDailyBudget(senderFingerprint: "abc", dayEpoch: today) == .accepted)
        }
        #expect(reloaded.acceptIfWithinDailyBudget(senderFingerprint: "abc", dayEpoch: today) == .budgetExhausted)
        #expect(reloaded.acceptIfWithinDailyBudget(senderFingerprint: "abc", dayEpoch: today + 1) == .accepted)
        // A different sender has its own budget.
        #expect(reloaded.acceptIfWithinDailyBudget(senderFingerprint: "xyz", dayEpoch: today) == .accepted)
    }

    /// Counters prune BY DAY. The old size-tripped `removeAll()` could be provoked deliberately to
    /// hand every sender a fresh budget; ageing out is the only thing that may reset one.
    @Test func dedupBudgetResetsOnlyByAgeing() {
        let clock = TestClock()
        let dedup = HeartDropDedupStore(fileURL: tempFile("dedup.json"), now: { clock.date })
        let day = IdentityService.heartDropDayEpoch(at: clock.date)

        for _ in 0..<HeartDropDedupStore.maxAcceptedPerSenderPerDay {
            #expect(dedup.acceptIfWithinDailyBudget(senderFingerprint: "abc", dayEpoch: day) == .accepted)
        }
        #expect(dedup.acceptIfWithinDailyBudget(senderFingerprint: "abc", dayEpoch: day) == .budgetExhausted)

        // Traffic from many other senders does not clear the map.
        for index in 0..<200 {
            #expect(dedup.acceptIfWithinDailyBudget(senderFingerprint: "sender-\(index)", dayEpoch: day) == .accepted)
        }
        #expect(dedup.acceptIfWithinDailyBudget(senderFingerprint: "abc", dayEpoch: day) == .budgetExhausted)

        // Past retention the day bucket is pruned and the same key is spendable again.
        clock.advance(HeartDropDedupStore.retention + 86_400)
        #expect(dedup.acceptIfWithinDailyBudget(senderFingerprint: "abc", dayEpoch: day) == .accepted)
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

    // MARK: - Sidecar durability (Track A, Plan-Prekeys-ProtectedLoad-CoachMesh-2026-07-26)

    /// A shared switchable I/O gate for simulating "protected data unavailable" per store.
    nonisolated final class IOGate: @unchecked Sendable {
        var failReads = false
        var failWrites = false
        func readData(_ url: URL) throws -> Data {
            if failReads { throw CocoaError(.fileReadNoPermission) }
            return try Data(contentsOf: url)
        }
        func writeData(_ data: Data, _ url: URL) throws {
            if failWrites { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: [.atomic])
        }
    }

    /// The live data-loss bug: an outbox whose file could not be READ used to look empty, and
    /// the next persist overwrote the real entries. Now the read failure refuses the queue, the
    /// file survives untouched, and recovery reads it back.
    @Test func unreadableOutboxRefusesHeartsAndNeverOverwritesTheFile() async throws {
        let (sender, senderID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: senderID) }
        let (recipient, recipientID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: recipientID) }
        let prekeySvc = "com.fernlet.heartdrop.test.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: prekeySvc) }

        let clock = TestClock()
        let outboxURL = tempFile("outbox.json")
        let io = IOGate()
        // Seed one real entry through a healthy outbox instance.
        let seeder = HeartDropOutbox(fileURL: outboxURL, now: { clock.date })
        #expect(seeder.enqueue(HeartDropOutbox.Entry(
            id: UUID(), friendSigningKey: Data([7]), tag: "t", wire: Data([1]),
            createdAt: clock.date)) == .queued)

        io.failReads = true
        let transport = MockDropTransport()
        let recipientRecord = makeFriendRecord(of: recipient, name: "Bobby Fern")
        let service = makeService(
            identity: sender, prekeyService: prekeySvc,
            ledger: ProximityHeartLedger(fileURL: tempFile("ledger.json"), now: { clock.date }),
            friends: { [recipientRecord] }, transport: transport, clock: clock,
            outbox: HeartDropOutbox(
                fileURL: outboxURL, now: { clock.date },
                readData: io.readData, writeData: io.writeData))

        #expect(service.queueHeart(to: recipientRecord) == .storageUnavailable)
        #expect(service.deliveryProblem == .storageUnavailable, "a refused queue surfaces immediately")
        #expect(service.uploadedDeadDropRecordCount() == nil, "an unloaded outbox reports UNKNOWN, not zero")
        #expect(service.hasStrandedDeadDropRecords(), "unknown fails closed: a purge may still be owed")
        await service.syncOnce()
        let onDisk = try JSONDecoder().decode([HeartDropOutbox.Entry].self, from: Data(contentsOf: outboxURL))
        #expect(onDisk.count == 1, "nothing may overwrite the file that could not be read")

        io.failReads = false
        #expect(service.queueHeart(to: recipientRecord) == .queued, "recovery on the next access")
        await service.syncOnce()
        #expect(transport.records.count == 2, "both the seeded and the new heart upload after recovery")
        #expect(service.deliveryProblem == nil)
    }

    /// The flush live bug (Increment 3): the device locks across the upload await, the
    /// `.completeFileProtection` write of the record name fails — the name must survive in
    /// memory as the truth, surface as a delivery problem, and commit durably once writes
    /// recover. Losing it strands a public-DB record nothing can ever delete.
    @Test func markUploadedWriteFailureSurfacesAndCommitsOnRecovery() async throws {
        let (sender, senderID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: senderID) }
        let (recipient, recipientID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: recipientID) }
        let prekeySvc = "com.fernlet.heartdrop.test.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: prekeySvc) }

        let clock = TestClock()
        let outboxURL = tempFile("outbox.json")
        let io = IOGate()
        let transport = MockDropTransport()
        let recipientRecord = makeFriendRecord(of: recipient, name: "Bobby Fern")
        let service = makeService(
            identity: sender, prekeyService: prekeySvc,
            ledger: ProximityHeartLedger(fileURL: tempFile("ledger.json"), now: { clock.date }),
            friends: { [recipientRecord] }, transport: transport, clock: clock,
            outbox: HeartDropOutbox(
                fileURL: outboxURL, now: { clock.date },
                readData: io.readData, writeData: io.writeData))

        #expect(service.queueHeart(to: recipientRecord) == .queued)
        io.failWrites = true // the device "locks" before the upload's record name can persist
        await service.syncOnce()

        #expect(transport.records.count == 1, "the upload itself succeeded")
        #expect(service.deliveryProblem == .storageUnavailable,
                "the un-persisted record name is a surfaced problem, not a silent continue")
        #expect(service.uploadedDeadDropRecordCount() == 1,
                "the name survives in memory as the truth")

        io.failWrites = false
        await service.syncOnce() // the sync pass re-persists the dirty value
        #expect(service.deliveryProblem == nil)
        // A relaunch (fresh instance on the same file) still knows the record name — durability.
        let relaunched = HeartDropOutbox(fileURL: outboxURL, now: { clock.date })
        #expect(relaunched.uploadedRecordNames() == transport.records.map(\.recordName))
    }

    /// Corrupt-outbox salvage (locked decision O4): keep the rows that parse — above all a
    /// `recordName`, the one thing that can never be reconstructed — and discard the remainder.
    @Test func corruptOutboxSalvageKeepsTheRecordName() throws {
        let clock = TestClock()
        let url = tempFile("outbox.json")
        let seeder = HeartDropOutbox(fileURL: url, now: { clock.date })
        let id = UUID()
        #expect(seeder.enqueue(HeartDropOutbox.Entry(
            id: id, friendSigningKey: Data([7]), tag: "t", wire: Data([1]),
            createdAt: clock.date)) == .queued)
        #expect(seeder.markUploaded(id: id, recordName: "rec-precious"))

        // Corrupt the array by splicing in a row that is not an Entry.
        var rows = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [Any]
        rows.append(["bogus": true])
        try JSONSerialization.data(withJSONObject: rows).write(to: url)

        let recovered = HeartDropOutbox(fileURL: url, now: { clock.date })
        #expect(recovered.uploadedRecordNames() == ["rec-precious"])
        #expect(recovered.dataLossOccurred, "the discarded row is not silent")
    }

    /// The dedup store fails CLOSED while unavailable: nothing is accepted, so no double
    /// delivery ever (the record stays on the server and is re-fetched once storage recovers).
    @Test func unavailableDedupRefusesAcceptsAndPreservesItsFile() throws {
        let clock = TestClock()
        let url = tempFile("dedup.json")
        let io = IOGate()
        let seeder = HeartDropDedupStore(fileURL: url, now: { clock.date })
        let seen = UUID()
        #expect(seeder.recordIfNew(envelopeID: seen))

        io.failReads = true
        let broken = HeartDropDedupStore(
            fileURL: url, now: { clock.date }, readData: io.readData, writeData: io.writeData)
        #expect(!broken.recordIfNew(envelopeID: UUID()))
        #expect(broken.acceptIfWithinDailyBudget(senderFingerprint: "f", dayEpoch: 1) == .storageUnavailable)

        io.failReads = false
        #expect(broken.retryLoad())
        #expect(!broken.recordIfNew(envelopeID: seen), "the preserved file still remembers the seen id")
        #expect(broken.recordIfNew(envelopeID: UUID()))
    }

    /// The peer-bundle cache fails toward AVAILABILITY: while its sidecar is unavailable,
    /// `consumePrekey` returns nil and the heart seals to the static key — delivery is preserved,
    /// only forward secrecy degrades (the documented fallback).
    @Test func unavailablePeerCacheFallsBackToTheStaticSeal() async throws {
        let (sender, senderID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: senderID) }
        let (recipient, recipientID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: recipientID) }
        let prekeySvc = "com.fernlet.heartdrop.test.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: prekeySvc) }

        let clock = TestClock()
        let io = IOGate()
        let cacheURL = tempFile("bundles.json")
        // Seed a cached bundle, then break reads: the cache is unavailable at consume time.
        let seededCache = HeartDropPeerBundleCache(fileURL: cacheURL, now: { clock.date })
        seededCache.store(bundle: makeBundle(created: clock.date), forFriendSigningKey: recipient.localSigningPublicKey)

        io.failReads = true
        let transport = MockDropTransport()
        let recipientRecord = makeFriendRecord(of: recipient, name: "Bobby Fern")
        let service = makeService(
            identity: sender, prekeyService: prekeySvc,
            ledger: ProximityHeartLedger(fileURL: tempFile("ledger.json"), now: { clock.date }),
            friends: { [recipientRecord] }, transport: transport, clock: clock,
            peerBundles: HeartDropPeerBundleCache(
                fileURL: cacheURL, now: { clock.date },
                readData: io.readData, writeData: io.writeData),
            outbox: HeartDropOutbox(fileURL: tempFile("outbox.json"), now: { clock.date }))

        #expect(service.queueHeart(to: recipientRecord) == .queued, "availability over FS")
        await service.syncOnce()
        #expect(transport.records.count == 1)
        // The wire's 16-byte prekey id slot is all-zeros = sealed to the static key.
        let wire = try #require(transport.records.first?.payload)
        #expect(wire.subdata(in: 1..<17) == Data(count: 16))
    }

    /// The ledger adoption (O5): an unreadable ledger refuses sends fail-closed instead of
    /// re-opening the 5-minute gate, and its file survives for recovery.
    @Test func unreadableLedgerFailsClosedAndRecovers() throws {
        let clock = TestClock()
        let url = tempFile("ledger.json")
        let io = IOGate()
        let seeder = ProximityHeartLedger(fileURL: url, now: { clock.date })
        seeder.recordHeartSent(to: "friend-1")
        #expect(!seeder.canSendHeart(to: "friend-1"))

        io.failReads = true
        let broken = ProximityHeartLedger(
            fileURL: url, now: { clock.date }, readData: io.readData, writeData: io.writeData)
        #expect(!broken.isLoaded)
        #expect(!broken.canSendHeart(to: "friend-1"), "an unloaded gate refuses rather than allows")
        #expect(!broken.recordReceivedHeart(id: UUID(), senderDisplayName: "F", senderFingerprint: "x"))

        io.failReads = false
        #expect(broken.retryLoad())
        #expect(!broken.canSendHeart(to: "friend-1"), "the preserved file still arms the gate")
        clock.advance(5 * 60 + 1) // past the 5-minute rate window
        #expect(broken.canSendHeart(to: "friend-1"))
    }

    /// Consent-off still short-circuits before any storage check: an opted-out device reports
    /// `.disabled`, never a storage problem it has no business surfacing.
    @Test func consentOffShortCircuitsBeforeStorageChecks() throws {
        let (sender, senderID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: senderID) }
        let (recipient, recipientID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: recipientID) }
        let prekeySvc = "com.fernlet.heartdrop.test.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: prekeySvc) }

        let clock = TestClock()
        let io = IOGate()
        io.failReads = true
        let outboxURL = tempFile("outbox.json")
        try FileManager.default.createDirectory(
            at: outboxURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode([HeartDropOutbox.Entry]()).write(to: outboxURL)
        let recipientRecord = makeFriendRecord(of: recipient, name: "Bobby Fern")
        let service = makeService(
            identity: sender, prekeyService: prekeySvc,
            ledger: ProximityHeartLedger(fileURL: tempFile("ledger.json"), now: { clock.date }),
            friends: { [recipientRecord] }, transport: MockDropTransport(),
            enabled: { false }, clock: clock,
            outbox: HeartDropOutbox(
                fileURL: outboxURL, now: { clock.date },
                readData: io.readData, writeData: io.writeData))

        #expect(service.queueHeart(to: recipientRecord) == .disabled)
    }

    /// End-to-end with the at-rest seal (Increment 4): the sidecar files are ciphertext on disk,
    /// hearts still round-trip, and the delete-all wipe removes the seal key with the prekeys.
    @Test func sealedSidecarsRoundTripAndWipeRemovesTheKey() async throws {
        let (sender, senderID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: senderID) }
        let (recipient, recipientID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: recipientID) }
        let prekeySvc = "com.fernlet.heartdrop.test.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: prekeySvc) }

        let clock = TestClock()
        let seal = HeartDropSidecarSeal.make(keychainService: prekeySvc)
        let outboxURL = tempFile("outbox.json")
        let transport = MockDropTransport()
        let recipientRecord = makeFriendRecord(of: recipient, name: "Bobby Fern")
        let service = makeService(
            identity: sender, prekeyService: prekeySvc,
            ledger: ProximityHeartLedger(fileURL: tempFile("ledger.json"), now: { clock.date }),
            friends: { [recipientRecord] }, transport: transport, clock: clock,
            peerBundles: HeartDropPeerBundleCache(fileURL: tempFile("bundles.json"), seal: seal, now: { clock.date }),
            outbox: HeartDropOutbox(fileURL: outboxURL, seal: seal, now: { clock.date }))

        #expect(service.queueHeart(to: recipientRecord) == .queued)
        let raw = try Data(contentsOf: outboxURL)
        #expect(raw.starts(with: Data("FSC1".utf8)), "the outbox is ciphertext at rest")
        await service.syncOnce()
        #expect(transport.records.count == 1)

        // Delete-all: the prekey wipe (same keychain service) takes the seal key with it.
        service.wipeForDeleteAll()
        #expect(KeychainItem.load(account: "sidecarSealKey", service: prekeySvc) == nil)
        #expect(!FileManager.default.fileExists(atPath: outboxURL.path))
    }

    // MARK: - Signed prekey (Track B, Plan-Prekeys-ProtectedLoad-CoachMesh-2026-07-26)

    /// THE migration risk of Track B: `StoredState.signedPrekeys` must decode as absent from a
    /// pre-change keychain blob. A decode failure would classify the blob as corrupt → empty →
    /// mint fresh, stranding the private halves of prekeys already gossiped — every in-flight
    /// drop would then silently fail to open.
    @Test func preChangePrekeyBlobDecodesAndKeepsGossipedHalves() throws {
        let svc = "com.fernlet.heartdrop.test.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: svc) }
        let clock = TestClock()

        // The captured pre-change shape: {"bundles":[{"bundle":{…},"privateKeys":[…]}]} — no
        // signedPrekeys key anywhere (asserted below so the fixture can't silently drift).
        struct LegacyStoredBundle: Codable {
            var bundle: HeartPrekeyStore.Bundle
            var privateKeys: [Data]
        }
        struct LegacyStoredState: Codable {
            var bundles: [LegacyStoredBundle]
        }
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let gossipedID = UUID()
        let legacy = LegacyStoredState(bundles: [LegacyStoredBundle(
            bundle: HeartPrekeyStore.Bundle(
                bundleID: UUID(),
                created: clock.date,
                expires: clock.date.addingTimeInterval(30 * 24 * 3600),
                keys: [HeartPrekeyStore.PrekeyEntry(
                    id: gossipedID, publicKey: privateKey.publicKey.rawRepresentation)]),
            privateKeys: [privateKey.rawRepresentation])])
        let blob = try JSONEncoder().encode(legacy)
        let json = try #require(String(data: blob, encoding: .utf8))
        #expect(!json.contains("signedPrekey"), "fixture must really be the pre-change shape")
        KeychainItem.store(
            blob, account: "prekeyPrivateHalves", service: svc,
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, synchronizable: false)

        let store = HeartPrekeyStore(keychainService: svc, now: { clock.date })
        #expect(store.privateKey(forPrekeyID: gossipedID) != nil,
                "pre-change private halves stay resolvable")
        let bundle = try #require(store.currentBundle())
        #expect(bundle.keys.map(\.id).contains(gossipedID),
                "the stored bundle survives — it is not minted over")
        #expect(bundle.signedPrekey != nil, "and gains a fresh signed prekey")
        #expect(store.privateKey(forPrekeyID: gossipedID) != nil)
    }

    /// Same shape as `senderDailyCapMatchesTheReceiverBudget`: the constants may move, the
    /// invariants may not.
    @Test func spkRetentionInvariantsHold() {
        // A drop sealed at the very end of the SPK seal window can sit the full outbox lifetime
        // (plus tolerated clock skew) before its last legitimate open. Retention must cover
        // that whole gap — violating this silently loses hearts (the recipient just fails
        // `open` and returns).
        #expect(HeartPrekeyStore.spkRetention >=
                HeartDropPeerBundleCache.maxSealSignedPrekeyAge
                + HeartDropOutbox.entryLifetime
                + HeartDropService.createdAtSkewTolerance)
        // O2: nothing Track B introduces is ever the longest-lived key on the device.
        #expect(HeartPrekeyStore.spkRetention <
                HeartPrekeyStore.bundleLifetime + HeartPrekeyStore.expiryGrace)
    }

    @Test func signedPrekeyRotatesWeeklyAndRetainsRotatedOutHalves() throws {
        let svc = "com.fernlet.heartdrop.test.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: svc) }
        let clock = TestClock()
        let store = HeartPrekeyStore(keychainService: svc, now: { clock.date })

        let spk0 = try #require(store.currentBundle()?.signedPrekey)
        clock.advance(3 * 24 * 3600)
        #expect(store.currentBundle()?.signedPrekey?.id == spk0.id, "stable inside the rotation window")

        clock.advance(5 * 24 * 3600) // day 8 — past the rotation deadline
        let spk1 = try #require(store.currentBundle()?.signedPrekey)
        #expect(spk1.id != spk0.id)
        #expect(store.privateKey(forPrekeyID: spk0.id) != nil,
                "rotated-out halves stay resolvable for in-flight drops")

        clock.advance(30 * 24 * 3600) // day 38 — both are past their 29-day retention
        _ = store.currentBundle() // the prune tick
        #expect(store.privateKey(forPrekeyID: spk0.id) == nil)
        #expect(store.privateKey(forPrekeyID: spk1.id) == nil)
    }

    /// The two cache slots are independent: consuming one-time keys falls through to the SPK,
    /// the SPK is reusable, an SPK-only refresh never wipes the one-time slot's consumption,
    /// and older gossip rolls back neither slot.
    @Test func signedPrekeySlotIsIndependentOfTheOneTimeSlot() throws {
        let clock = TestClock()
        let cache = HeartDropPeerBundleCache(fileURL: tempFile("bundles.json"), now: { clock.date })
        let friend = Data([9])
        let t0 = clock.date

        let spk1 = makeSignedPrekey(created: t0)
        cache.store(bundle: makeBundle(keyCount: 1, created: t0, signedPrekey: spk1),
                    forFriendSigningKey: friend)

        let first = try #require(cache.consumePrekey(forFriendSigningKey: friend))
        #expect(first.isOneTime, "one-time keys carry the seal while any are left")
        let second = try #require(cache.consumePrekey(forFriendSigningKey: friend))
        #expect(!second.isOneTime)
        #expect(second.id == spk1.id, "exhausted one-time slot falls through to the SPK")
        #expect(cache.consumePrekey(forFriendSigningKey: friend)?.id == spk1.id, "the SPK is reusable")

        // An SPK-only refresh (no one-time keys) rotates the SPK slot without touching the
        // one-time slot — the consumed mark stays consumed.
        clock.advance(3600)
        let spk2 = makeSignedPrekey(created: clock.date)
        cache.store(bundle: makeBundle(keyCount: 0, created: clock.date, signedPrekey: spk2),
                    forFriendSigningKey: friend)
        let third = try #require(cache.consumePrekey(forFriendSigningKey: friend))
        #expect(third.id == spk2.id)
        #expect(!third.isOneTime, "the one-time slot's consumption survived the SPK-only refresh")

        // Older gossip (an intro built before the rotation, arriving late) rolls back neither.
        cache.store(bundle: makeBundle(keyCount: 4, created: t0.addingTimeInterval(-3600), signedPrekey: spk1),
                    forFriendSigningKey: friend)
        let fourth = try #require(cache.consumePrekey(forFriendSigningKey: friend))
        #expect(fourth.id == spk2.id, "older gossip must not roll back either slot")
    }

    /// The SPK has its own seal window (14 d), longer than the one-time bundle's 7 d — but past
    /// it the cache falls back to the static key, exactly like a stale one-time bundle.
    @Test func staleSignedPrekeyIsNotSealedTo() {
        let clock = TestClock()
        let cache = HeartDropPeerBundleCache(fileURL: tempFile("bundles.json"), now: { clock.date })
        let friend = Data([9])
        let spk = makeSignedPrekey(created: clock.date)
        cache.store(bundle: makeBundle(keyCount: 1, created: clock.date, signedPrekey: spk),
                    forFriendSigningKey: friend)

        clock.advance(10 * 24 * 3600) // day 10: one-time slot stale (> 7 d), SPK fresh (≤ 14 d)
        #expect(cache.consumePrekey(forFriendSigningKey: friend)?.id == spk.id)

        clock.advance(5 * 24 * 3600) // day 15: SPK past its 14-day seal window too
        #expect(cache.consumePrekey(forFriendSigningKey: friend) == nil)
    }

    /// The end-to-end coverage win, at the retention edge: a friend last seen 13 days ago gets
    /// an SPK-sealed drop (not static), and the drop still opens after sitting almost the full
    /// outbox lifetime — the scenario the retention invariant exists to protect. Past retention
    /// the private half is gone (clean failure).
    @Test func aHeartSealedToTheSignedPrekeyOpensAtTheRetentionEdge() async throws {
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
        let recipientLedger = ProximityHeartLedger(fileURL: tempFile("r-ledger.json"), now: { clock.date })
        let recipientPrekeys = HeartPrekeyStore(keychainService: recipientPrekeySvc, now: { clock.date })
        let recipientService = HeartDropService(
            ledger: recipientLedger,
            isEnabled: { true },
            activeFriends: { [senderRecord] },
            localDayKey: { FernletDate.dayKey(for: $0) },
            displayName: { "Bobby" },
            identity: recipient,
            prekeys: recipientPrekeys,
            peerBundles: HeartDropPeerBundleCache(fileURL: tempFile("rb.json"), now: { clock.date }),
            outbox: HeartDropOutbox(fileURL: tempFile("ro.json"), now: { clock.date }),
            dedup: HeartDropDedupStore(fileURL: tempFile("rd.json"), now: { clock.date }),
            now: { clock.date }
        )
        recipientService.transport = transport

        // Day 0: they meet; the sender caches the recipient's gossiped bundle (16 one-time
        // keys + the SPK).
        let bundle = try #require(recipientService.currentLocalBundle())
        let spkID = try #require(bundle.signedPrekey?.id)
        senderService.storePeerBundle(bundle, friendSigningKey: recipient.localSigningPublicKey)

        // Day 13: the one-time slot is stale (7-day seal window) — without the SPK this heart
        // would fall all the way back to the static key. The SPK (14-day window) carries it.
        clock.advance(13 * 24 * 3600)
        #expect(senderService.queueHeart(to: recipientRecord) == .queued)
        await senderService.syncOnce()
        #expect(transport.records.count == 1)
        let wire = try #require(transport.records.first?.payload)
        let expectedID = withUnsafeBytes(of: spkID.uuid) { Data($0) }
        #expect(wire.subdata(in: 1..<17) == expectedID, "the wire names the SPK, not static (zeros)")

        // Day 26.8: the drop sat almost its whole 14-day lifetime. SPK age is ~27 days — inside
        // the 29-day retention, so it opens.
        clock.advance(13 * 24 * 3600 + 20 * 3600)
        await recipientService.syncOnce()
        #expect(recipientLedger.receivedHearts.count == 1)
        #expect(recipientLedger.receivedHearts.first?.senderFingerprint == sender.localFingerprint)

        // Day 30: past retention the private half is pruned — the clean-failure side of the
        // invariant (anything sealed this late is already outside every legitimate window).
        clock.advance(4 * 24 * 3600)
        _ = recipientPrekeys.currentBundle() // the prune tick
        #expect(recipientPrekeys.privateKey(forPrekeyID: spkID) == nil)
    }

    // MARK: - Review-round fixes (2026-07-26 adversarial review)

    /// The published `receivedHearts` mirror must follow the sidecar when it recovers through
    /// one of its OWN paths (the unlock notification, an on-access read) — with away-hearts
    /// off (the default) no sync pass ever runs, and a stale-empty mirror makes on-disk hearts
    /// invisible for the whole session.
    @Test func ledgerMirrorFollowsSidecarInternalRecovery() async throws {
        let clock = TestClock()
        let url = tempFile("ledger.json")
        let io = IOGate()
        let seeder = ProximityHeartLedger(fileURL: url, now: { clock.date })
        #expect(seeder.recordReceivedHeart(id: UUID(), senderDisplayName: "Fern", senderFingerprint: "abc"))

        io.failReads = true
        let broken = ProximityHeartLedger(
            fileURL: url, now: { clock.date }, readData: io.readData, writeData: io.writeData)
        #expect(broken.receivedHearts.isEmpty)

        io.failReads = false
        clock.advance(6) // past the on-access retry floor
        // A view-body read (`canSendHeart`) is enough to recover the sidecar; the mirror must
        // follow without anyone calling the ledger's own retryLoad().
        _ = broken.canSendHeart(to: "someone")
        let mirrored = await waitUntil { broken.receivedHearts.count == 1 }
        #expect(mirrored, "the published mirror stayed stale-empty after sidecar-internal recovery")
    }

    /// A crafted over-cap bundle must not ride the SPK-only branch into the sidecar: only a
    /// stripped carrier (no one-time keys) is stored alongside the SPK.
    @Test func oversizedBundleCannotRideTheSPKOnlyBranch() throws {
        let clock = TestClock()
        let cache = HeartDropPeerBundleCache(fileURL: tempFile("bundles.json"), now: { clock.date })
        let friend = Data([9])
        let spk = makeSignedPrekey(created: clock.date)
        let oversized = makeBundle(
            keyCount: HeartDropPeerBundleCache.maxBundleKeys + 1,
            created: clock.date, signedPrekey: spk)

        cache.store(bundle: oversized, forFriendSigningKey: friend)
        let consumed = try #require(cache.consumePrekey(forFriendSigningKey: friend))
        #expect(!consumed.isOneTime, "none of the over-cap one-time keys may be stored")
        #expect(consumed.id == spk.id, "the (bounded) SPK itself still stores")
    }

    /// Eviction must not destroy a row whose one-time bundle expired while its SPK is still
    /// inside the 14-day seal window — that silently degraded exactly the away-friends the SPK
    /// exists for.
    @Test func evictionKeepsARowWhoseSPKIsStillSealable() throws {
        let clock = TestClock()
        let cache = HeartDropPeerBundleCache(fileURL: tempFile("bundles.json"), now: { clock.date })
        let friend = Data([9])
        let spk = makeSignedPrekey(created: clock.date)
        // A short-lived one-time bundle + a fresh SPK.
        cache.store(bundle: makeBundle(keyCount: 1, created: clock.date, lifetime: 3600, signedPrekey: spk),
                    forFriendSigningKey: friend)

        clock.advance(2 * 3600) // the bundle is expired; the SPK is 2 h old
        // Any store() runs the eviction pass — this one is for a different peer.
        cache.store(bundle: makeBundle(keyCount: 1, created: clock.date), forFriendSigningKey: Data([8]))

        #expect(cache.consumePrekey(forFriendSigningKey: friend)?.id == spk.id,
                "eviction destroyed a still-sealable signed prekey with its expired carrier")
    }

    /// Acknowledging a storage banner must not zero the undelivered-hearts count the user was
    /// never shown — it has to surface once storage recovers.
    @Test func acknowledgingStorageProblemPreservesTheUndeliveredCount() async throws {
        let (sender, senderID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: senderID) }
        let (recipient, recipientID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: recipientID) }
        let prekeySvc = "com.fernlet.heartdrop.test.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: prekeySvc) }

        let clock = TestClock()
        let io = IOGate()
        let transport = MockDropTransport()
        let recipientRecord = makeFriendRecord(of: recipient, name: "Bobby Fern")
        let service = makeService(
            identity: sender, prekeyService: prekeySvc,
            ledger: ProximityHeartLedger(fileURL: tempFile("ledger.json"), now: { clock.date }),
            friends: { [recipientRecord] }, transport: transport, clock: clock,
            outbox: HeartDropOutbox(
                fileURL: tempFile("outbox.json"), now: { clock.date },
                readData: io.readData, writeData: io.writeData))

        // One heart expires un-uploaded → undeliverable(1).
        transport.failUploads = true
        #expect(service.queueHeart(to: recipientRecord) == .queued)
        clock.advance(HeartDropOutbox.entryLifetime + 60)
        transport.failUploads = false
        await service.syncOnce()
        #expect(service.deliveryProblem == .undeliverable(count: 1))

        // Storage breaks mid-sync (an upload's recordAttempt write fails) → storage outranks.
        transport.failUploads = true
        #expect(service.queueHeart(to: recipientRecord) == .queued)
        io.failWrites = true
        await service.syncOnce()
        #expect(service.deliveryProblem == .storageUnavailable)

        // The user dismisses the STORAGE banner. The undelivered count they never saw survives.
        service.acknowledgeDeliveryProblem()
        io.failWrites = false
        transport.failUploads = false
        await service.syncOnce()
        #expect(service.deliveryProblem == .undeliverable(count: 1),
                "dismissing the storage banner destroyed the undelivered-hearts count")
    }

    /// A dedup mark whose downstream budget write failed must be undone, or the envelope id is
    /// burned while the heart was never surfaced.
    @Test func dedupUnrecordReopensAnEnvelopeAfterAStorageFailure() throws {
        let clock = TestClock()
        let io = IOGate()
        let dedup = HeartDropDedupStore(
            fileURL: tempFile("dedup.json"), now: { clock.date },
            readData: io.readData, writeData: io.writeData)
        let id = UUID()
        #expect(dedup.recordIfNew(envelopeID: id))

        io.failWrites = true // storage breaks between the two marks
        #expect(dedup.acceptIfWithinDailyBudget(senderFingerprint: "f", dayEpoch: 1) == .storageUnavailable)
        dedup.unrecord(envelopeID: id) // what openIncoming now does on that outcome

        io.failWrites = false
        #expect(dedup.retryLoad(), "the commit-on-failure removal re-persists")
        #expect(dedup.recordIfNew(envelopeID: id), "the envelope id is fresh again — the heart re-delivers")
    }

    /// Consent withdrawal outranks a failing write: a dirty-but-loaded outbox still purges its
    /// records off the public database (memory is the truth), rather than leaving them there
    /// until the write recovers.
    @Test func purgeProceedsFromADirtyOutbox() async throws {
        let (sender, senderID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: senderID) }
        let (recipient, recipientID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: recipientID) }
        let prekeySvc = "com.fernlet.heartdrop.test.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: prekeySvc) }

        let clock = TestClock()
        let io = IOGate()
        let transport = MockDropTransport()
        let recipientRecord = makeFriendRecord(of: recipient, name: "Bobby Fern")
        let gate = ConsentGate()
        let service = makeService(
            identity: sender, prekeyService: prekeySvc,
            ledger: ProximityHeartLedger(fileURL: tempFile("ledger.json"), now: { clock.date }),
            friends: { [recipientRecord] }, transport: transport,
            enabled: { gate.enabled }, clock: clock,
            outbox: HeartDropOutbox(
                fileURL: tempFile("outbox.json"), now: { clock.date },
                readData: io.readData, writeData: io.writeData))

        #expect(service.queueHeart(to: recipientRecord) == .queued)
        await service.syncOnce()
        #expect(transport.records.count == 1)

        // Break writes and dirty the outbox (a failed-upload attempt write).
        transport.failUploads = true
        clock.advance(5 * 60 + 1) // past the ledger's per-friend send gate
        #expect(service.queueHeart(to: recipientRecord) == .queued) // still ready at enqueue time
        io.failWrites = true
        await service.syncOnce() // recordAttempt's write fails → dirty
        #expect(service.deliveryProblem == .storageUnavailable)

        gate.enabled = false
        #expect(await service.purgeDeadDrop(), "a dirty outbox must still purge — memory is the truth")
        #expect(transport.records.isEmpty, "the uploaded record left the public database")
        #expect(!service.hasStrandedDeadDropRecords())
    }
}
