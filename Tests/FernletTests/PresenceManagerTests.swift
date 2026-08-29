// PresenceManagerTests.swift
// FernletTests
//
// Phase 4a (Docs/Proximity-Mesh-Redesign-2026-07-10.md): the standing presence radio's PURE state
// machine, driven entirely through the no-radio test seams (`activateForTesting`,
// `handleDiscoveredPeerForTesting`, `markPeerLostForTesting`, `sweepExpiredPeersForTesting`, an
// injected `nowProvider`). No test here starts Bonjour — the unit-test invariant for proximity.
//
// Pins: roster eligibility filtering (blocked / revoked / empty-KA / empty-signing stubs excluded),
// the 24-tag advertise cap preferring most-recently-seen friends (matching stays uncapped),
// nearby-set debounce across the epoch advertiser-restart flap, both self-exclusion layers, epoch
// rotation dropping a stale advertisement, the `allowNearbyPresence` default-false + tolerant decode,
// and the one-time first-kept-friend enable prompt (fires on 0→1, never twice).

@testable import ProximityKit
import Foundation
import Testing
import CryptoKit
import MultipeerConnectivity
import FernletFoundation
import FernletDomainModel
@testable import Fernlet

// MARK: - Test host + fixtures

@MainActor
private final class MockPresenceHost: ProximityHost {
    var proximityDisplayName: String { "Tester" }
    var trustedProximityPeers: [ProximityTrustedPeerRecord] { proximityTrustVault.trustedPeers }
    let proximityTrustVault = ProximityTrustVault()
    func isBlockedFingerprint(_ fingerprint: String) -> Bool {
        proximityTrustVault.isBlockedFingerprint(fingerprint)
    }
    func blockProximityPeer(signingPublicKey: Data) {
        proximityTrustVault.block(signingPublicKey: signingPublicKey)
    }
}

@MainActor
@Suite(.serialized)
struct PresenceManagerTests {

    private let baseDate = Date(timeIntervalSince1970: 1_780_000_000)

    /// A provisioned identity on a throwaway keychain service (never the production identity).
    private func makeIdentity() throws -> (IdentityService, String) {
        let serviceID = "com.fernlet.identity.test.\(UUID().uuidString)"
        let svc = IdentityService(keychainService: serviceID)
        try svc.ensureProvisioned()
        return (svc, serviceID)
    }

    /// A friend trust record carrying a REAL X25519 KA public key (so tags derive) and a distinct
    /// 16-char fingerprint. `signing` defaults to random non-empty bytes so eligibility passes.
    private func makeFriend(
        fingerprint: String,
        keyAgreementPublicKey: Data,
        lastSeenAt: Date,
        signingPublicKey: Data = Data((0..<8).map { _ in UInt8.random(in: 0...255) }),
        blockedAt: Date? = nil,
        revokedAt: Date? = nil
    ) -> ProximityTrustedPeerRecord {
        ProximityTrustedPeerRecord(
            displayName: "Friend",
            fingerprint: fingerprint,
            signingPublicKey: signingPublicKey,
            keyAgreementPublicKey: keyAgreementPublicKey,
            mode: .friend,
            firstAcceptedAt: baseDate,
            lastSeenAt: lastSeenAt,
            revokedAt: revokedAt,
            blockedAt: blockedAt
        )
    }

    private func kaPublic() -> Data {
        Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
    }

    /// A throwaway heart ledger on a temp URL — these presence tests don't exercise hearts, but
    /// PresenceManager now requires one (Phase 4b).
    private func makeLedger() -> ProximityHeartLedger {
        ProximityHeartLedger(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("presence-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("HeartLedger.json"))
    }

    private func peer(displayName: String = "peer-\(UUID().uuidString.prefix(8))", tokens: [String]) -> PeerHandle {
        PeerHandle(
            id: UUID(),
            displayHint: displayName,
            discoveryInfo: ["v": "1", "t": tokens.joined(separator: ",")],
            advertisedFingerprint: nil
        )
    }

    // MARK: - Roster eligibility

    @Test func eligibleFriendsExcludesBlockedRevokedAndStubs() {
        let good = makeFriend(fingerprint: "aaaa0000aaaa0000", keyAgreementPublicKey: kaPublic(), lastSeenAt: baseDate)
        let blocked = makeFriend(fingerprint: "bbbb0000bbbb0000", keyAgreementPublicKey: kaPublic(), lastSeenAt: baseDate, blockedAt: baseDate)
        let revoked = makeFriend(fingerprint: "cccc0000cccc0000", keyAgreementPublicKey: kaPublic(), lastSeenAt: baseDate, revokedAt: baseDate)
        let emptyKA = makeFriend(fingerprint: "dddd0000dddd0000", keyAgreementPublicKey: Data(), lastSeenAt: baseDate)
        let emptySigning = makeFriend(fingerprint: "eeee0000eeee0000", keyAgreementPublicKey: kaPublic(), lastSeenAt: baseDate, signingPublicKey: Data())

        let eligible = PresenceManager.eligibleFriends(in: [good, blocked, revoked, emptyKA, emptySigning])

        #expect(eligible.map(\.fingerprint) == ["aaaa0000aaaa0000"],
                "Only a non-blocked, non-revoked friend with full key material is eligible")
    }

    @Test func eligibleFriendsSortsMostRecentlySeenFirst() {
        let older = makeFriend(fingerprint: "1111000011110000", keyAgreementPublicKey: kaPublic(), lastSeenAt: baseDate)
        let newer = makeFriend(fingerprint: "2222000022220000", keyAgreementPublicKey: kaPublic(), lastSeenAt: baseDate.addingTimeInterval(100))
        let eligible = PresenceManager.eligibleFriends(in: [older, newer])
        #expect(eligible.map(\.fingerprint) == ["2222000022220000", "1111000011110000"])
    }

    // MARK: - Advertise cap (24, most-recently-seen preferred; matching uncapped)

    @Test func advertisedTagsCapAt24PreferringRecentButCandidatesAreUncapped() throws {
        let (identity, serviceID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: serviceID) }
        let host = MockPresenceHost()
        let epoch = IdentityService.presenceEpoch(at: baseDate)

        // 30 friends, lastSeenAt increasing with index — index 29 is the most recent.
        var friends: [ProximityTrustedPeerRecord] = []
        for i in 0..<30 {
            friends.append(makeFriend(
                fingerprint: String(format: "%016x", i),
                keyAgreementPublicKey: kaPublic(),
                lastSeenAt: baseDate.addingTimeInterval(TimeInterval(i))))
        }
        host.proximityTrustVault.apply(peers: friends, audit: [])

        let manager = PresenceManager(store: host, ledger: makeLedger(), identity: identity)
        manager.nowProvider = { self.baseDate }
        manager.activateForTesting()

        // Exactly 24 advertised tags.
        #expect(manager.ownTagTokens.count == PresenceManager.maxAdvertisedTags)

        // The 24 newest friends are advertised; the 6 oldest are not.
        let sorted = friends.sorted { $0.lastSeenAt > $1.lastSeenAt }
        for friend in sorted.prefix(24) {
            let token = try identity.presenceTag(for: friend.keyAgreementPublicKey, epoch: epoch).base64EncodedString()
            #expect(manager.ownTagTokens.contains(token), "A most-recently-seen friend must be advertised")
        }
        for friend in sorted.suffix(6) {
            let token = try identity.presenceTag(for: friend.keyAgreementPublicKey, epoch: epoch).base64EncodedString()
            #expect(!manager.ownTagTokens.contains(token), "An older friend beyond the cap is NOT advertised")
            // ...but matching is uncapped: every eligible friend's current-epoch tag is a candidate.
            #expect(manager.candidateTokens[token] == friend.fingerprint,
                    "Matching candidates are uncapped — even beyond-cap friends can be recognized nearby")
        }

        // Wire-budget sanity: 24 tags × 12 base64 chars + separators stays well under ~400 B.
        let txt = manager.discoveryInfoForTesting()["t"] ?? ""
        #expect(txt.utf8.count < 400, "Advertised TXT must stay inside the Bonjour budget")
    }

    // MARK: - Discovery → nearby set

    @Test func matchingFriendAdvertisementPopulatesNearbySet() throws {
        let (identity, serviceID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: serviceID) }
        let host = MockPresenceHost()
        let epoch = IdentityService.presenceEpoch(at: baseDate)

        let friendKA = kaPublic()
        let friend = makeFriend(fingerprint: "f00df00df00df00d", keyAgreementPublicKey: friendKA, lastSeenAt: baseDate)
        host.proximityTrustVault.apply(peers: [friend], audit: [])

        let manager = PresenceManager(store: host, ledger: makeLedger(), identity: identity)
        manager.nowProvider = { self.baseDate }
        manager.activateForTesting()

        // A GENUINE friend advertises the SAME pairwise tag we derive for them (mutual property),
        // PLUS a tag for one of THEIR other friends (a pair we can't derive) — that extra token is
        // what distinguishes a real friend from our own single-friend ghost (self-exclusion
        // layer 3). See `singleFriendGhostIsExcludedWhenAdvertisingOnlyOwnTags`.
        let token = try identity.presenceTag(for: friendKA, epoch: epoch).base64EncodedString()
        let theirOtherFriendTag = Data((0..<8).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        manager.handleDiscoveredPeerForTesting(peer(tokens: [token, theirOtherFriendTag]))

        #expect(manager.nearbyFriendFingerprints == ["f00df00df00df00d"])
    }

    @Test func advertisementMatchingViaAdjacentEpochStillCounts() throws {
        // A friend whose advertiser hasn't rotated yet is still one epoch behind — ±1 must match.
        let (identity, serviceID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: serviceID) }
        let host = MockPresenceHost()
        let epoch = IdentityService.presenceEpoch(at: baseDate)

        let friendKA = kaPublic()
        let friend = makeFriend(fingerprint: "abcdabcdabcdabcd", keyAgreementPublicKey: friendKA, lastSeenAt: baseDate)
        host.proximityTrustVault.apply(peers: [friend], audit: [])

        let manager = PresenceManager(store: host, ledger: makeLedger(), identity: identity)
        manager.nowProvider = { self.baseDate }
        manager.activateForTesting()

        let staleToken = try identity.presenceTag(for: friendKA, epoch: epoch - 1).base64EncodedString()
        manager.handleDiscoveredPeerForTesting(peer(tokens: [staleToken]))
        #expect(manager.nearbyFriendFingerprints == ["abcdabcdabcdabcd"])
    }

    @Test func nonFriendAdvertisementIsIgnored() throws {
        let (identity, serviceID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: serviceID) }
        let host = MockPresenceHost()

        let friend = makeFriend(fingerprint: "f00df00df00df00d", keyAgreementPublicKey: kaPublic(), lastSeenAt: baseDate)
        host.proximityTrustVault.apply(peers: [friend], audit: [])

        let manager = PresenceManager(store: host, ledger: makeLedger(), identity: identity)
        manager.nowProvider = { self.baseDate }
        manager.activateForTesting()

        // A random tag no friend could have produced.
        manager.handleDiscoveredPeerForTesting(peer(tokens: [Data((0..<8).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()]))
        #expect(manager.nearbyFriendFingerprints.isEmpty)
    }

    // MARK: - Self-exclusion

    @Test func selfExclusionLayer1IgnoresOwnEphemeralPeerName() throws {
        let (identity, serviceID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: serviceID) }
        let host = MockPresenceHost()
        let epoch = IdentityService.presenceEpoch(at: baseDate)

        let friendKA = kaPublic()
        let friend = makeFriend(fingerprint: "f00df00df00df00d", keyAgreementPublicKey: friendKA, lastSeenAt: baseDate)
        host.proximityTrustVault.apply(peers: [friend], audit: [])

        let manager = PresenceManager(store: host, ledger: makeLedger(), identity: identity)
        manager.nowProvider = { self.baseDate }
        manager.activateForTesting()
        manager.registerOwnEphemeralPeerNameForTesting("ghost")

        // Even with a perfectly valid friend token, our own previous-start ghost is ignored.
        let token = try identity.presenceTag(for: friendKA, epoch: epoch).base64EncodedString()
        manager.handleDiscoveredPeerForTesting(peer(displayName: "ghost", tokens: [token]))
        #expect(manager.nearbyFriendFingerprints.isEmpty)
    }

    @Test func selfExclusionLayer2DropsAdvertisementMatchingMultipleFriends() throws {
        // A genuine friend's ad matches EXACTLY one of our friends (pair tags are unique). An ad
        // matching 2+ is our own reflected tag set — drop it.
        let (identity, serviceID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: serviceID) }
        let host = MockPresenceHost()
        let epoch = IdentityService.presenceEpoch(at: baseDate)

        let ka1 = kaPublic(), ka2 = kaPublic()
        let f1 = makeFriend(fingerprint: "1111111111111111", keyAgreementPublicKey: ka1, lastSeenAt: baseDate)
        let f2 = makeFriend(fingerprint: "2222222222222222", keyAgreementPublicKey: ka2, lastSeenAt: baseDate)
        host.proximityTrustVault.apply(peers: [f1, f2], audit: [])

        let manager = PresenceManager(store: host, ledger: makeLedger(), identity: identity)
        manager.nowProvider = { self.baseDate }
        manager.activateForTesting()

        let t1 = try identity.presenceTag(for: ka1, epoch: epoch).base64EncodedString()
        let t2 = try identity.presenceTag(for: ka2, epoch: epoch).base64EncodedString()
        manager.handleDiscoveredPeerForTesting(peer(tokens: [t1, t2]))
        #expect(manager.nearbyFriendFingerprints.isEmpty,
                "An ad matching 2+ friends is our own reflection / a splice — never a real peer")
    }

    @Test func singleFriendGhostIsExcludedWhenAdvertisingOnlyOwnTags() throws {
        // Group 4/finding-4: with exactly ONE friend, our previous-start ghost lingers in the
        // Bonjour cache under a RANDOM name this process never generated (so self-exclusion layer 1
        // misses it) and advertises our own single tag — which, by the mutual property, is exactly
        // the tag our one friend would advertise. Self-exclusion layer 3: an advertisement whose
        // FULL token set is a subset of our own current-epoch tags is treated as self. (Bounded
        // residual: a mutual friend whose ONLY friend is us, same epoch, is likewise excluded.)
        let (identity, serviceID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: serviceID) }
        let host = MockPresenceHost()
        let epoch = IdentityService.presenceEpoch(at: baseDate)

        let friendKA = kaPublic()
        let friend = makeFriend(fingerprint: "f00df00df00df00d", keyAgreementPublicKey: friendKA, lastSeenAt: baseDate)
        host.proximityTrustVault.apply(peers: [friend], audit: [])

        let manager = PresenceManager(store: host, ledger: makeLedger(), identity: identity)
        manager.nowProvider = { self.baseDate }
        manager.activateForTesting()

        // The ghost advertises ONLY our own current-epoch tag (a DIFFERENT random name — layer 1
        // can't catch a prior process's ghost). Excluded as self by layer 3.
        let ownTag = try identity.presenceTag(for: friendKA, epoch: epoch).base64EncodedString()
        manager.handleDiscoveredPeerForTesting(peer(displayName: "priorprocessghost", tokens: [ownTag]))
        #expect(manager.nearbyFriendFingerprints.isEmpty,
                "A prior-process ghost advertising only our own single tag is excluded as self")

        // A real friend who advertises that tag PLUS a tag for another of their friends (which we
        // cannot derive) is still recognized — the extra token proves it is a distinct device.
        let theirOtherFriendTag = Data((0..<8).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        manager.handleDiscoveredPeerForTesting(peer(displayName: "realfriend", tokens: [ownTag, theirOtherFriendTag]))
        #expect(manager.nearbyFriendFingerprints == ["f00df00df00df00d"],
                "A friend with any other friend advertises a tag outside our own set — distinguishable")
    }

    // MARK: - Debounce

    @Test func lostPeerStaysNearbyThroughGraceThenDropsAfterExpiry() throws {
        let (identity, serviceID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: serviceID) }
        let host = MockPresenceHost()
        let epoch = IdentityService.presenceEpoch(at: baseDate)

        let friendKA = kaPublic()
        let friend = makeFriend(fingerprint: "f00df00df00df00d", keyAgreementPublicKey: friendKA, lastSeenAt: baseDate)
        host.proximityTrustVault.apply(peers: [friend], audit: [])

        var clock = baseDate
        let manager = PresenceManager(store: host, ledger: makeLedger(), identity: identity)
        manager.nowProvider = { clock }
        manager.activateForTesting()

        // Distinguishable friend advertisement (shared tag + a tag for their other friend) so
        // self-exclusion layer 3 doesn't treat it as our own single-friend ghost (Group 3).
        let token = try identity.presenceTag(for: friendKA, epoch: epoch).base64EncodedString()
        let theirOtherFriendTag = Data((0..<8).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let discovered = peer(tokens: [token, theirOtherFriendTag])
        manager.handleDiscoveredPeerForTesting(discovered)
        #expect(manager.nearbyFriendFingerprints == ["f00df00df00df00d"])

        // Lost — but still nearby through the grace window (spans the epoch restart flap).
        manager.markPeerLostForTesting(discovered)
        #expect(manager.nearbyFriendFingerprints == ["f00df00df00df00d"], "Debounced: still nearby immediately after loss")

        clock = baseDate.addingTimeInterval(PresenceManager.lostGraceInterval - 5)
        manager.sweepExpiredPeersForTesting()
        #expect(manager.nearbyFriendFingerprints == ["f00df00df00df00d"], "Inside the grace window: still nearby")

        clock = baseDate.addingTimeInterval(PresenceManager.lostGraceInterval + 1)
        manager.sweepExpiredPeersForTesting()
        #expect(manager.nearbyFriendFingerprints.isEmpty, "Past the grace window: dropped")
    }

    @Test func rediscoveryWithinGraceCancelsTheDrop() throws {
        let (identity, serviceID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: serviceID) }
        let host = MockPresenceHost()
        let epoch = IdentityService.presenceEpoch(at: baseDate)

        let friendKA = kaPublic()
        let friend = makeFriend(fingerprint: "f00df00df00df00d", keyAgreementPublicKey: friendKA, lastSeenAt: baseDate)
        host.proximityTrustVault.apply(peers: [friend], audit: [])

        var clock = baseDate
        let manager = PresenceManager(store: host, ledger: makeLedger(), identity: identity)
        manager.nowProvider = { clock }
        manager.activateForTesting()

        let token = try identity.presenceTag(for: friendKA, epoch: epoch).base64EncodedString()
        let theirOtherFriendTag = Data((0..<8).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let discovered = peer(tokens: [token, theirOtherFriendTag])
        manager.handleDiscoveredPeerForTesting(discovered)
        manager.markPeerLostForTesting(discovered)

        // Re-found before the grace elapses clears the lost mark.
        clock = baseDate.addingTimeInterval(10)
        manager.handleDiscoveredPeerForTesting(discovered)

        clock = baseDate.addingTimeInterval(PresenceManager.lostGraceInterval + 100)
        manager.sweepExpiredPeersForTesting()
        #expect(manager.nearbyFriendFingerprints == ["f00df00df00df00d"],
                "Re-discovery cancels the pending drop — the peer never left")
    }

    // MARK: - Epoch rotation

    @Test func epochRotationDropsAStaleAdvertisement() throws {
        // A peer whose (static) ad is now 2 epochs behind falls out of the ±1 candidate window.
        let (identity, serviceID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: serviceID) }
        let host = MockPresenceHost()
        let epoch = IdentityService.presenceEpoch(at: baseDate)

        let friendKA = kaPublic()
        let friend = makeFriend(fingerprint: "f00df00df00df00d", keyAgreementPublicKey: friendKA, lastSeenAt: baseDate)
        host.proximityTrustVault.apply(peers: [friend], audit: [])

        var clock = baseDate
        let manager = PresenceManager(store: host, ledger: makeLedger(), identity: identity)
        manager.nowProvider = { clock }
        manager.activateForTesting()

        let token = try identity.presenceTag(for: friendKA, epoch: epoch).base64EncodedString()
        let theirOtherFriendTag = Data((0..<8).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        manager.handleDiscoveredPeerForTesting(peer(tokens: [token, theirOtherFriendTag]))
        #expect(manager.nearbyFriendFingerprints == ["f00df00df00df00d"])

        // Advance two full epochs and rotate — the cached ad (epoch N) is now outside N+2 ± 1.
        clock = baseDate.addingTimeInterval(IdentityService.presenceEpochSeconds * 2 + 1)
        manager.rotateEpochIfNeeded()
        #expect(manager.nearbyFriendFingerprints.isEmpty,
                "A friend whose advertisement is 2+ epochs stale drops on rotation")
    }

    @Test func discoveryInfoCarriesNoIdentifiers() throws {
        let (identity, serviceID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: serviceID) }
        let host = MockPresenceHost()
        let friend = makeFriend(fingerprint: "f00df00df00df00d", keyAgreementPublicKey: kaPublic(), lastSeenAt: baseDate)
        host.proximityTrustVault.apply(peers: [friend], audit: [])

        let manager = PresenceManager(store: host, ledger: makeLedger(), identity: identity)
        manager.nowProvider = { self.baseDate }
        manager.activateForTesting()

        let info = manager.discoveryInfoForTesting()
        #expect(Set(info.keys) == ["v", "t"], "Only version + tags — no display name, no session id")
        #expect(info["v"] == "1")
    }

    // MARK: - Setting default + tolerant decode

    @Test func allowNearbyPresenceDefaultsFalse() {
        #expect(FernletSettings().allowNearbyPresence == false)
        #expect(FernletSettings().hasPromptedForPresence == false)
    }

    @Test func presenceSettingsDecodeTolerantlyWhenAbsent() throws {
        // Simulate an older synced blob that predates the presence keys: every OTHER key is
        // present, the two presence keys are missing — decode must default them to false, not throw.
        var object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(FernletSettings())) as? [String: Any])
        object.removeValue(forKey: "allowNearbyPresence")
        object.removeValue(forKey: "hasPromptedForPresence")
        let data = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(FernletSettings.self, from: data)
        #expect(decoded.allowNearbyPresence == false)
        #expect(decoded.hasPromptedForPresence == false)
    }

    // MARK: - First-kept-friend enable prompt (0 → 1, once, never again)

    @Test func firstKeptFriendRequestsPresencePromptExactlyOnce() {
        let store = makeTestStore()
        #expect(store.settings.hasPromptedForPresence == false)
        #expect(store.presenceEnablePromptRequested == false)

        let first = MeshSessionRosterEntry(
            displayName: "Alice",
            fingerprint: IdentityService.fingerprint(of: Data([1, 2, 3])),
            signingPublicKey: Data([1, 2, 3]),
            keyAgreementPublicKey: Data([4, 5, 6]))
        store.keepProximityFriends(from: [first], keptFingerprints: [first.fingerprint])

        #expect(store.presenceEnablePromptRequested == true, "Keeping the FIRST friend requests the prompt")
        #expect(store.settings.hasPromptedForPresence == true, "The never-re-prompt marker is set immediately")

        // Dismiss the prompt (as the alert binding does) and keep a SECOND friend.
        store.presenceEnablePromptRequested = false
        let second = MeshSessionRosterEntry(
            displayName: "Bob",
            fingerprint: IdentityService.fingerprint(of: Data([7, 8, 9])),
            signingPublicKey: Data([7, 8, 9]),
            keyAgreementPublicKey: Data([10, 11, 12]))
        store.keepProximityFriends(from: [second], keptFingerprints: [second.fingerprint])

        #expect(store.presenceEnablePromptRequested == false, "The prompt never fires a second time")
    }

    @Test func presencePromptDoesNotFireWhenPresenceAlreadyOn() {
        let store = makeTestStore()
        store.settings.allowNearbyPresence = true

        let entry = MeshSessionRosterEntry(
            displayName: "Alice",
            fingerprint: IdentityService.fingerprint(of: Data([1, 2, 3])),
            signingPublicKey: Data([1, 2, 3]),
            keyAgreementPublicKey: Data([4, 5, 6]))
        store.keepProximityFriends(from: [entry], keptFingerprints: [entry.fingerprint])

        #expect(store.presenceEnablePromptRequested == false,
                "No enable prompt when the user already turned presence on")
    }
}
