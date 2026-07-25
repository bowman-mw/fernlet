// HeartDropTests.swift
// FernletTests
//
// Offline hearts dead-drop (bitchat adoptions Increment 3): day-tag derivation, the prekey/static
// outer sealer, prekey stores + one-time consumption, outbox caps/expiry, durable dedup + daily
// budget, and the full sender→transport→recipient service loop against a mock transport.
// Identity/prekey stores use UUID-scoped keychain services + defer cleanup (IdentityServiceTests
// convention); sidecars use per-test temp files.

import Foundation
import Testing
import CryptoKit
import ProximityKit
import FernletFoundation
import FernletDomainModel
@testable import Fernlet

@MainActor
@Suite(.serialized)
struct HeartDropTests {

    // MARK: - Harness

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

    nonisolated final class MockDropTransport: HeartDropTransporting, @unchecked Sendable {
        var records: [HeartDropRecord] = []
        var available = true
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
        enabled: @escaping () -> Bool = { true }
    ) -> HeartDropService {
        let service = HeartDropService(
            ledger: ledger,
            isEnabled: enabled,
            activeFriends: friends,
            localDayKey: { FernletDate.dayKey(for: $0) },
            displayName: { "Tester" },
            identity: identity,
            prekeys: HeartPrekeyStore(keychainService: prekeyService),
            peerBundles: HeartDropPeerBundleCache(fileURL: tempFile("bundles.json")),
            outbox: HeartDropOutbox(fileURL: tempFile("outbox.json")),
            dedup: HeartDropDedupStore(fileURL: tempFile("dedup.json"))
        )
        service.transport = transport
        return service
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

    @Test func peerBundleConsumptionIsOneTimePerSender() throws {
        let cache = HeartDropPeerBundleCache(fileURL: tempFile("bundles.json"))
        let prekeyServiceID = "com.fernlet.heartdrop.test.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: prekeyServiceID) }
        let bundle = try #require(HeartPrekeyStore(keychainService: prekeyServiceID).currentBundle())
        let friendKey = Data([1, 2, 3])

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
        // ...but a genuinely new bundle does.
        let second = try #require(HeartPrekeyStore(
            keychainService: "com.fernlet.heartdrop.test.\(UUID().uuidString)").currentBundle())
        cache.store(bundle: second, forFriendSigningKey: friendKey)
        #expect(cache.consumePrekey(forFriendSigningKey: friendKey) != nil)
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
        outbox.remove(ids: outbox.expiredEntries().map(\.id))
        #expect(outbox.expiredEntries().isEmpty)
    }

    @Test func dedupIsDurableAndBudgetsPerSenderDay() {
        let url = tempFile("dedup.json")
        let dedup = HeartDropDedupStore(fileURL: url)
        let envelopeID = UUID()
        #expect(dedup.recordIfNew(envelopeID: envelopeID))
        #expect(!dedup.recordIfNew(envelopeID: envelopeID))
        // Durability: a fresh instance over the same file still knows it.
        let reloaded = HeartDropDedupStore(fileURL: url)
        #expect(!reloaded.recordIfNew(envelopeID: envelopeID))

        for _ in 0..<HeartDropDedupStore.maxAcceptedPerSenderPerDay {
            #expect(reloaded.acceptIfWithinDailyBudget(senderFingerprint: "abc", dayKey: "2026-07-25"))
        }
        #expect(!reloaded.acceptIfWithinDailyBudget(senderFingerprint: "abc", dayKey: "2026-07-25"))
        #expect(reloaded.acceptIfWithinDailyBudget(senderFingerprint: "abc", dayKey: "2026-07-26"))
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
}
