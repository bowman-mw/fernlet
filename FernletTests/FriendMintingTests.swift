// FriendMintingTests.swift
// Phase 2 — one-sided friend minting (Docs/Proximity-Mesh-Redesign-2026-07-10.md).
//
// Covers: the session roster (captured at commit via the internal seam, deduped by fingerprint,
// promoted into the pendingFriendReview batch at teardown, reset on the next session via the
// radio-free seam, consumed scoped), the review batch (merge by fingerprint, id-scoped consume,
// removal purges), the presentation-time eligibility filter (already-trusted / blocked /
// empty-KA stubs excluded; fresh AND revoked-only "Removed" peers included per the Phase-2
// friend lifecycle semantics), the keep-path mint through FernletStore (full-key vault record,
// sanitized display name, save-scheduling hook fires, revoked-only revive), and the vouch-list
// gate (broadcast off by default + inbound dropped while off; capped TTL + sanitized name when on).

@testable import ProximityKit
import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

// MARK: - Shared fixtures

private func makeRosterEntry(
    name: String = "Alice",
    signingPublicKey: Data = Data([1, 2, 3]),
    keyAgreementPublicKey: Data = Data([4, 5, 6])
) -> MeshSessionRosterEntry {
    MeshSessionRosterEntry(
        displayName: name,
        fingerprint: IdentityService.fingerprint(of: signingPublicKey),
        signingPublicKey: signingPublicKey,
        keyAgreementPublicKey: keyAgreementPublicKey
    )
}

@MainActor
private func makePeerIdentity(
    name: String = "Alice",
    signingPublicKey: Data = Data([1, 2, 3]),
    keyAgreementPublicKey: Data = Data([4, 5, 6])
) -> ProximityCoordinator.PeerIdentity {
    ProximityCoordinator.PeerIdentity(
        id: UUID(),
        displayName: name,
        signingPublicKey: signingPublicKey,
        keyAgreementPublicKey: keyAgreementPublicKey,
        fingerprint: IdentityService.fingerprint(of: signingPublicKey),
        rangingMode: .none,
        firstSeenAt: Date()
    )
}

// MARK: - Session roster

// Serialized + a per-test store, mirroring MeshNetworkManagerTests: the store property keeps
// the FernletStore alive past the manager's `unowned let store`.
@Suite(.serialized) @MainActor
struct SessionRosterTests {
    let store = makeTestStore()

    @Test func roster_capturesAndDedupesByFingerprint() {
        let manager = MeshNetworkManager(store: store)

        manager.recordSessionParticipant(
            displayName: "Alice", fingerprint: "aabbccdd11223344",
            signingPublicKey: Data([1]), keyAgreementPublicKey: Data([2]))
        manager.recordSessionParticipant(
            displayName: "Bob", fingerprint: "eeff001122334455",
            signingPublicKey: Data([3]), keyAgreementPublicKey: Data([4]))
        // Re-commit of the same peer must not duplicate the entry.
        manager.recordSessionParticipant(
            displayName: "Alice", fingerprint: "aabbccdd11223344",
            signingPublicKey: Data([1]), keyAgreementPublicKey: Data([2]))

        #expect(manager.sessionRoster.count == 2)
        #expect(manager.sessionRoster.map(\.fingerprint) == ["aabbccdd11223344", "eeff001122334455"])
    }

    @Test func roster_displayNameIsLastWriteWins() {
        let manager = MeshNetworkManager(store: store)

        manager.recordSessionParticipant(
            displayName: "Alice", fingerprint: "aabbccdd11223344",
            signingPublicKey: Data([1]), keyAgreementPublicKey: Data([2]))
        manager.recordSessionParticipant(
            displayName: "Alice Renamed", fingerprint: "aabbccdd11223344",
            signingPublicKey: Data([1]), keyAgreementPublicKey: Data([2]))

        #expect(manager.sessionRoster.count == 1)
        #expect(manager.sessionRoster[0].displayName == "Alice Renamed")
        // The keys captured at first commit stay authoritative.
        #expect(manager.sessionRoster[0].signingPublicKey == Data([1]))
        #expect(manager.sessionRoster[0].keyAgreementPublicKey == Data([2]))
    }

    /// Session-end review is model-state (spec bullet, settled by the Phase-2 capstone review):
    /// teardown PROMOTES the roster into the observable `pendingFriendReview` batch — the
    /// entries survive slot teardown, just no longer on the live roster. (This test previously
    /// pinned "roster survives leaveSession untouched"; the spec moved consumption from
    /// view-events to the promoted batch, so the pinned semantics changed with it.)
    @Test func roster_promotesToPendingReviewOnLeaveSession() {
        let manager = MeshNetworkManager(store: store)
        manager.recordSessionParticipant(
            displayName: "Alice", fingerprint: "aabbccdd11223344",
            signingPublicKey: Data([1]), keyAgreementPublicKey: Data([2]))

        manager.leaveSession()

        #expect(manager.sessionRoster.isEmpty,
                "Teardown moves the roster into the pending review batch")
        #expect(manager.pendingFriendReview?.entries.map(\.fingerprint) == ["aabbccdd11223344"],
                "leaveSession must promote the roster — the keep-as-friend prompt consumes the batch post-teardown")
    }

    /// Driven through the internal seam (called by startJoin/startNewMesh) so the unit test
    /// never starts real Bonjour radios.
    @Test func roster_resetsWhenNewSessionStarts() {
        let manager = MeshNetworkManager(store: store)
        manager.recordSessionParticipant(
            displayName: "Alice", fingerprint: "aabbccdd11223344",
            signingPublicKey: Data([1]), keyAgreementPublicKey: Data([2]))

        manager.resetSessionRosterForNewSession()

        #expect(manager.sessionRoster.isEmpty,
                "A new session (startJoin/startNewMesh) must drop any unconsumed live roster from the last one")
    }

    @Test func newSessionReset_neverTouchesPendingFriendReview() {
        let manager = MeshNetworkManager(store: store)
        manager.recordSessionParticipant(
            displayName: "Alice", fingerprint: "aabbccdd11223344",
            signingPublicKey: Data([1]), keyAgreementPublicKey: Data([2]))
        manager.leaveSession()   // promotes into the batch
        let batchID = manager.pendingFriendReview?.id

        manager.resetSessionRosterForNewSession()

        #expect(manager.pendingFriendReview?.id == batchID,
                "An unreviewed batch survives into the next search cycle")
    }

    @Test func roster_clearedByClearSessionRoster() {
        let manager = MeshNetworkManager(store: store)
        manager.recordSessionParticipant(
            displayName: "Alice", fingerprint: "aabbccdd11223344",
            signingPublicKey: Data([1]), keyAgreementPublicKey: Data([2]))

        manager.clearSessionRoster()

        #expect(manager.sessionRoster.isEmpty)
    }

    /// Scoped consume for the in-session camera review: only the presented fingerprints leave
    /// the live roster — a peer who committed mid-review stays and is offered at session end.
    @Test func roster_consumeRosterEntriesIsScoped() {
        let manager = MeshNetworkManager(store: store)
        manager.recordSessionParticipant(
            displayName: "Alice", fingerprint: "aabbccdd11223344",
            signingPublicKey: Data([1]), keyAgreementPublicKey: Data([2]))
        manager.recordSessionParticipant(
            displayName: "Bob", fingerprint: "eeff001122334455",
            signingPublicKey: Data([3]), keyAgreementPublicKey: Data([4]))

        manager.consumeRosterEntries(fingerprints: ["aabbccdd11223344"])

        #expect(manager.sessionRoster.map(\.fingerprint) == ["eeff001122334455"],
                "Mid-review committer must survive the scoped consume")
    }
}

// MARK: - Pending friend-review batch (session-end review is model-state)

@Suite(.serialized) @MainActor
struct FriendReviewBatchTests {
    let store = makeTestStore()

    @Test func promotion_mergesIntoUnconsumedBatchByFingerprint() {
        let manager = MeshNetworkManager(store: store)
        manager.recordSessionParticipant(
            displayName: "Alice", fingerprint: "aabbccdd11223344",
            signingPublicKey: Data([1]), keyAgreementPublicKey: Data([2]))
        manager.leaveSession()
        let firstBatchID = manager.pendingFriendReview?.id

        // Next session: Alice re-commits (new display name) and Bob commits; batch unconsumed.
        manager.resetSessionRosterForNewSession()
        manager.recordSessionParticipant(
            displayName: "Alice Renamed", fingerprint: "aabbccdd11223344",
            signingPublicKey: Data([1]), keyAgreementPublicKey: Data([2]))
        manager.recordSessionParticipant(
            displayName: "Bob", fingerprint: "eeff001122334455",
            signingPublicKey: Data([3]), keyAgreementPublicKey: Data([4]))
        manager.leaveSession()

        let batch = manager.pendingFriendReview
        #expect(batch?.id == firstBatchID, "Merges into the existing unconsumed batch, never a new one")
        #expect(batch?.entries.map(\.fingerprint) == ["aabbccdd11223344", "eeff001122334455"],
                "Candidates are never dropped by a merge")
        #expect(batch?.entries.first?.displayName == "Alice Renamed", "Merge is last-write-wins per fingerprint")
        #expect(manager.sessionRoster.isEmpty)
    }

    @Test func completeFriendReview_clearsOnlyTheMatchingBatch() {
        let manager = MeshNetworkManager(store: store)
        manager.recordSessionParticipant(
            displayName: "Alice", fingerprint: "aabbccdd11223344",
            signingPublicKey: Data([1]), keyAgreementPublicKey: Data([2]))
        manager.leaveSession()
        let batchID = manager.pendingFriendReview!.id

        manager.completeFriendReview(UUID())
        #expect(manager.pendingFriendReview != nil, "A stale/foreign id must not consume the batch")

        manager.completeFriendReview(batchID)
        #expect(manager.pendingFriendReview == nil)
    }

    @Test func promotion_isIdempotentAcrossRepeatedTeardownPaths() {
        let manager = MeshNetworkManager(store: store)
        manager.recordSessionParticipant(
            displayName: "Alice", fingerprint: "aabbccdd11223344",
            signingPublicKey: Data([1]), keyAgreementPublicKey: Data([2]))

        manager.leaveSession()
        let batchID = manager.pendingFriendReview?.id
        manager.leaveSession()   // second teardown: roster already empty — nothing changes

        #expect(manager.pendingFriendReview?.id == batchID)
        #expect(manager.pendingFriendReview?.entries.count == 1)
    }

    /// Finding 5: a peer removed by the session vote must never be offered by the keep prompt —
    /// purged from the live roster, refused on re-record, absent from the promoted batch.
    @Test func votedOutPeerIsAbsentFromThePromotedBatch() {
        let manager = MeshNetworkManager(store: store)
        manager.recordSessionParticipant(
            displayName: "Bob", fingerprint: "bob-fp-0011223344",
            signingPublicKey: Data([3]), keyAgreementPublicKey: Data([4]))
        manager.recordSessionParticipant(
            displayName: "Cara", fingerprint: "cara-fp-99887766",
            signingPublicKey: Data([5]), keyAgreementPublicKey: Data([6]))

        // Approved removal (proposed by another member, seconded locally) targets Bob.
        let proposal = MeshRemovalProposalPayload(
            id: UUID(),
            targetFingerprint: "bob-fp-0011223344",
            targetDisplayName: "Bob",
            proposerFingerprint: "alice-fp-55667788",
            proposerDisplayName: "Alice",
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(60)
        )
        manager.secondRemoval(proposal)

        #expect(manager.sessionRoster.map(\.fingerprint) == ["cara-fp-99887766"],
                "The voted-out peer is purged from the live roster")

        // Belt-and-braces: a late re-commit of the removed peer is refused.
        manager.recordSessionParticipant(
            displayName: "Bob", fingerprint: "bob-fp-0011223344",
            signingPublicKey: Data([3]), keyAgreementPublicKey: Data([4]))
        #expect(manager.sessionRoster.count == 1)

        manager.leaveSession()
        #expect(manager.pendingFriendReview?.entries.map(\.fingerprint) == ["cara-fp-99887766"],
                "The promoted batch never offers a voted-out peer")
    }

    /// Finding 6: the pairwise ask-to-remove shortcut (sole other peer ⇒ just leave) must not
    /// end in a keep prompt for the very peer the user asked to remove.
    @Test func pairwiseAskToRemoveYieldsNoKeepPromptForThatPeer() {
        let manager = MeshNetworkManager(store: store)
        manager.recordSessionParticipant(
            displayName: "Bob", fingerprint: "bob-fp-0011223344",
            signingPublicKey: Data([3]), keyAgreementPublicKey: Data([4]))
        let now = Date()
        manager.currentMesh = MeshDescriptor(
            meshID: UUID(),
            name: "Pairwise",
            mode: .open,
            members: [MeshMember(
                fingerprint: "bob-fp-0011223344",
                displayName: "Bob",
                signingPublicKey: Data([3]),
                keyAgreementPublicKey: Data([4]),
                joinedAt: now
            )],
            nameSetAt: now, nameSetBy: "bob-fp-0011223344",
            modeSetAt: now, modeSetBy: "bob-fp-0011223344",
            createdAt: now
        )

        manager.proposeRemoval(of: MeshSessionParticipant(
            fingerprint: "bob-fp-0011223344", displayName: "Bob", isLocal: false))

        #expect(manager.currentMesh == nil, "The shortcut ends the session")
        #expect(manager.sessionRoster.isEmpty)
        #expect(manager.pendingFriendReview == nil,
                "No batch promotes — the only roster entry was the peer being removed")
    }
}

// MARK: - Eligibility

@MainActor
struct FriendMintingEligibilityTests {

    @Test func freshPeerIsEligible() {
        let entry = makeRosterEntry()
        let eligible = FriendMintingReview.eligibleCandidates(roster: [entry], trustedPeers: [])
        #expect(eligible == [entry])
    }

    @Test func alreadyTrustedPeerIsExcluded() {
        let vault = ProximityTrustVault()
        vault.trust(makePeerIdentity(), mode: .friend)

        let eligible = FriendMintingReview.eligibleCandidates(
            roster: [makeRosterEntry()],
            trustedPeers: vault.trustedPeers
        )
        #expect(eligible.isEmpty, "An unrevoked, unblocked record means the peer is already a friend")
    }

    @Test func blockedPeerIsExcluded() {
        let vault = ProximityTrustVault()
        vault.trust(makePeerIdentity(), mode: .friend)
        vault.block(signingPublicKey: Data([1, 2, 3]))

        let eligible = FriendMintingReview.eligibleCandidates(
            roster: [makeRosterEntry()],
            trustedPeers: vault.trustedPeers
        )
        #expect(eligible.isEmpty)
    }

    /// Phase-2 friend lifecycle semantics (settled by the capstone review — this test previously
    /// pinned "revoked excludes"; the spec now defines *Remove* as a reversible unfriend): a
    /// revoked-only ("Removed") record does NOT exclude the peer — the fresh verified in-person
    /// session re-offers them.
    @Test func revokedOnlyPeerIsEligibleAgain() {
        let vault = ProximityTrustVault()
        vault.trust(makePeerIdentity(), mode: .friend)
        vault.revoke(signingPublicKey: Data([1, 2, 3]))

        let entry = makeRosterEntry()
        let eligible = FriendMintingReview.eligibleCandidates(
            roster: [entry],
            trustedPeers: vault.trustedPeers
        )
        #expect(eligible == [entry], "Removed = reversible unfriend — re-offer after a fresh verified session")
    }

    /// *Unblock* demotes a ban to "removed" (block sets both timestamps; unblock clears only
    /// blockedAt) — re-friendable in person via a fresh session-roster entry, not silently restored.
    @Test func unblockedPeerBecomesEligibleAgain() {
        let vault = ProximityTrustVault()
        vault.trust(makePeerIdentity(), mode: .friend)
        vault.block(signingPublicKey: Data([1, 2, 3]))
        vault.unblock(signingPublicKey: Data([1, 2, 3]))
        #expect(vault.trustedPeers[0].revokedAt != nil, "Precondition: unblock leaves the record revoked-only")

        let entry = makeRosterEntry()
        let eligible = FriendMintingReview.eligibleCandidates(
            roster: [entry],
            trustedPeers: vault.trustedPeers
        )
        #expect(eligible == [entry])
    }

    /// `ProximityTrustVault.block` mints an empty-KA stub record for never-trusted peers; a
    /// roster entry matching such a stub (here: by fingerprint) must not be offered.
    @Test func emptyKeyAgreementStubIsExcluded() {
        let vault = ProximityTrustVault()
        vault.block(signingPublicKey: Data([1, 2, 3]))
        #expect(vault.trustedPeers[0].keyAgreementPublicKey.isEmpty, "Precondition: block() mints a stub")

        let eligible = FriendMintingReview.eligibleCandidates(
            roster: [makeRosterEntry()],
            trustedPeers: vault.trustedPeers
        )
        #expect(eligible.isEmpty)
    }

    /// Legacy 8-char records (older builds) still exclude their 16-char roster counterparts.
    @Test func legacyShortFingerprintRecordStillExcludes() {
        let entry = makeRosterEntry()
        let legacyRecord = ProximityTrustedPeerRecord(
            displayName: "Alice",
            fingerprint: String(entry.fingerprint.prefix(8)),
            signingPublicKey: Data([9, 9, 9]),   // different key bytes — only the fingerprint matches
            keyAgreementPublicKey: Data([8, 8, 8]),
            mode: .friend
        )

        let eligible = FriendMintingReview.eligibleCandidates(roster: [entry], trustedPeers: [legacyRecord])
        #expect(eligible.isEmpty)
    }

    /// Defensive: a roster entry missing either key never reaches the sheet (a committed
    /// handshake always carries both).
    @Test func rosterEntryWithEmptyKeysIsExcluded() {
        let noKA = makeRosterEntry(keyAgreementPublicKey: Data())
        let noSigning = MeshSessionRosterEntry(
            displayName: "Ghost", fingerprint: "0011223344556677",
            signingPublicKey: Data(), keyAgreementPublicKey: Data([1]))

        let eligible = FriendMintingReview.eligibleCandidates(roster: [noKA, noSigning], trustedPeers: [])
        #expect(eligible.isEmpty)
    }

    @Test func sessionEndReviewDecision() {
        #expect(FriendMintingReview.sessionEndReview(hasPhotos: true, eligibleCandidateCount: 0) == .photoReview)
        #expect(FriendMintingReview.sessionEndReview(hasPhotos: true, eligibleCandidateCount: 2) == .photoReview)
        #expect(FriendMintingReview.sessionEndReview(hasPhotos: false, eligibleCandidateCount: 2) == .friendPromptOnly)
        #expect(FriendMintingReview.sessionEndReview(hasPhotos: false, eligibleCandidateCount: 0) == .none)
    }
}

// MARK: - Keep-path minting through the store

@Suite(.serialized) @MainActor
struct FriendMintingStoreTests {
    let store = makeTestStore()

    @Test func keepPathWritesFullKeyRecordAndSchedulesSave() {
        // FernletStore wires vault.onChange to snapshotSaveCoordinator.schedule(); replace it
        // with a spy to pin that the mint fires that hook (the pattern ProximityTrustVaultTests
        // uses to assert save scheduling).
        var onChangeFired = 0
        store.proximityTrustVault.onChange = { onChangeFired += 1 }

        // Zero-width space in the peer-supplied name must be sanitized out before persisting.
        let kept = makeRosterEntry(name: "Ali\u{200B}ce", signingPublicKey: Data([1, 2, 3]))
        let skipped = makeRosterEntry(name: "Bob", signingPublicKey: Data([7, 7, 7]))

        store.keepProximityFriends(from: [kept, skipped], keptFingerprints: [kept.fingerprint])

        #expect(store.proximityTrustVault.trustedPeers.count == 1, "Only the kept candidate is minted")
        let record = store.proximityTrustVault.trustedPeers[0]
        #expect(record.displayName == "Alice", "Peer-supplied display name is sanitized before persisting")
        #expect(record.signingPublicKey == Data([1, 2, 3]))
        #expect(record.keyAgreementPublicKey == Data([4, 5, 6]), "The record carries the full KA key — not a stub")
        #expect(record.fingerprint == IdentityService.fingerprint(of: Data([1, 2, 3])))
        #expect(record.mode == .friend)
        #expect(record.revokedAt == nil)
        #expect(record.blockedAt == nil)
        #expect(onChangeFired == 1, "The mint must fire the vault onChange hook that schedules a snapshot save")
    }

    @Test func skipAllMintsNothing() {
        var onChangeFired = 0
        store.proximityTrustVault.onChange = { onChangeFired += 1 }

        store.keepProximityFriends(from: [makeRosterEntry()], keptFingerprints: [])

        #expect(store.proximityTrustVault.trustedPeers.isEmpty)
        #expect(onChangeFired == 0, "Skipping is a pure no-op — no record, no save, no wire message")
    }

    @Test func keepIsIdempotentAcrossSessions() {
        let entry = makeRosterEntry()
        store.keepProximityFriends(from: [entry], keptFingerprints: [entry.fingerprint])
        store.keepProximityFriends(from: [entry], keptFingerprints: [entry.fingerprint])

        #expect(store.proximityTrustVault.trustedPeers.count == 1)
    }

    /// The re-friend path: keeping a revoked-only ("Removed") peer after a fresh session revives
    /// the record — revocation cleared, mode back to .friend, keys refreshed from the new handshake.
    @Test func keepRevivesARevokedOnlyRecord() {
        let entry = makeRosterEntry()
        store.keepProximityFriends(from: [entry], keptFingerprints: [entry.fingerprint])
        store.revokeTrustedProximityPeer(signingPublicKey: entry.signingPublicKey)

        // A later session: same signing identity, fresh handshake KA key.
        let freshEntry = makeRosterEntry(keyAgreementPublicKey: Data([9, 9, 9]))
        store.keepProximityFriends(from: [freshEntry], keptFingerprints: [freshEntry.fingerprint])

        #expect(store.proximityTrustVault.trustedPeers.count == 1, "Revive, not duplicate")
        let record = store.proximityTrustVault.trustedPeers[0]
        #expect(record.revokedAt == nil, "The keep clears the revocation — desired re-friend path")
        #expect(record.blockedAt == nil)
        #expect(record.mode == .friend)
        #expect(record.keyAgreementPublicKey == Data([9, 9, 9]), "Keys refresh from the new handshake")
    }

    @Test func keepDoesNotReviveAPeerBlockedMidPrompt() {
        // Eligibility runs at presentation time; a peer blocked (e.g. from FriendListView)
        // between the prompt appearing and Done must NOT be revived — trust() clears
        // blockedAt/revokedAt, so keepProximityFriends re-checks the vault at finalize time.
        let entry = makeRosterEntry()
        store.proximityTrustVault.block(signingPublicKey: entry.signingPublicKey)

        store.keepProximityFriends(from: [entry], keptFingerprints: [entry.fingerprint])

        let record = store.proximityTrustVault.trustedPeers.first {
            $0.signingPublicKey == entry.signingPublicKey
        }
        #expect(record?.blockedAt != nil, "The block must survive the keep attempt")
        #expect(record?.revokedAt != nil, "Block implies revoke; the keep must not clear it")
        // block() mints its stub with an empty KA key; trust() would have written the full key —
        // an empty key here proves the keep never reached trust().
        #expect(record?.keyAgreementPublicKey == Data(), "The stub must not be upgraded by the keep")
    }
}

// MARK: - Vouch-list broadcast gate

@Suite(.serialized) @MainActor
struct VouchListBroadcastGateTests {
    let store = makeTestStore()

    @Test func vouchBroadcastIsDisabledByDefault() {
        let manager = MeshNetworkManager(store: store)
        // Seed a friend so the payload WOULD be non-empty if the gate were open.
        store.trustProximityPeer(makePeerIdentity(), mode: .friend)

        // Phase 2 disables the vouch-list broadcast (Docs/Proximity-Mesh-Redesign-2026-07-10.md):
        // friend minting is what would have switched this friend-graph disclosure on.
        #expect(manager.isVouchListBroadcastEnabled == false)
        #expect(manager.vouchListPayloadForBroadcast() == nil,
                "Gate off ⇒ sendVouchList must be a no-op even with trusted peers in the vault")
    }

    /// The machinery stays tested: forcing the flag on yields a payload with exactly the
    /// unblocked, unrevoked fingerprints.
    @Test func vouchMachineryStillFiltersWhenForcedOn() throws {
        let manager = MeshNetworkManager(store: store)
        let activeKey = Data([1, 1, 1])
        let revokedKey = Data([2, 2, 2])
        let blockedKey = Data([3, 3, 3])
        store.trustProximityPeer(makePeerIdentity(name: "Active", signingPublicKey: activeKey), mode: .friend)
        store.trustProximityPeer(makePeerIdentity(name: "Revoked", signingPublicKey: revokedKey), mode: .friend)
        store.trustProximityPeer(makePeerIdentity(name: "Blocked", signingPublicKey: blockedKey), mode: .friend)
        store.revokeTrustedProximityPeer(signingPublicKey: revokedKey)
        store.blockProximityPeer(signingPublicKey: blockedKey)

        manager.isVouchListBroadcastEnabled = true
        let payload = try #require(manager.vouchListPayloadForBroadcast())

        #expect(payload.trustedFingerprints == [IdentityService.fingerprint(of: activeKey)])
        #expect(payload.voucherFingerprint == manager.localFingerprint)
        #expect(payload.expiresAt > Date().addingTimeInterval(3600), "2 h TTL")
    }

    /// Finding 1: the Phase-2 gate must hold on the RECEIVE side too — while disabled, inbound
    /// vouch lists are dropped wholesale (no cache write, no "Friend of …" label).
    @Test func inboundVouchListIsDroppedWhileGateIsOff() {
        let manager = MeshNetworkManager(store: store)
        let payload = MeshFriendVouchListPayload(
            voucherFingerprint: "voucher-fp-001122",
            voucherDisplayName: "Mallory",
            trustedFingerprints: ["vouched-fp-334455"],
            expiresAt: Date().addingTimeInterval(3600)
        )

        manager.receiveVouchList(payload, senderFingerprint: "voucher-fp-001122")

        #expect(manager.isVouchListBroadcastEnabled == false, "Precondition: gate defaults off")
        #expect(manager.cachedVouchList(from: "voucher-fp-001122") == nil)
        #expect(manager.vouchLabel(for: "vouched-fp-334455") == nil)
    }

    /// Forced on, the receive path hygienes what it caches: expiry capped at the protocol's 2 h
    /// TTL (the wire value is sender-controlled) and the peer-supplied display name sanitized.
    @Test func inboundVouchListIsCappedAndSanitizedWhenForcedOn() throws {
        let manager = MeshNetworkManager(store: store)
        manager.isVouchListBroadcastEnabled = true
        let payload = MeshFriendVouchListPayload(
            voucherFingerprint: "voucher-fp-001122",
            voucherDisplayName: "Ali\u{200B}ce",   // zero-width space must not survive
            trustedFingerprints: ["vouched-fp-334455"],
            expiresAt: Date().addingTimeInterval(10 * 3600)   // sender claims 10 h
        )

        manager.receiveVouchList(payload, senderFingerprint: "voucher-fp-001122")

        let cached = try #require(manager.cachedVouchList(from: "voucher-fp-001122"))
        #expect(cached.expiresAt <= Date().addingTimeInterval(2 * 3600 + 5), "Wire TTL capped at 2 h")
        #expect(cached.voucherDisplayName == "Alice")
        #expect(manager.vouchLabel(for: "vouched-fp-334455") == "Friend of Alice")
    }

    /// Sender binding is unchanged: a vouch list whose claimed voucher fingerprint doesn't match
    /// the authenticated envelope sender is dropped even with the gate on.
    @Test func inboundVouchListRequiresAuthenticatedSenderMatch() {
        let manager = MeshNetworkManager(store: store)
        manager.isVouchListBroadcastEnabled = true
        let payload = MeshFriendVouchListPayload(
            voucherFingerprint: "voucher-fp-001122",
            voucherDisplayName: "Mallory",
            trustedFingerprints: ["vouched-fp-334455"],
            expiresAt: Date().addingTimeInterval(3600)
        )

        manager.receiveVouchList(payload, senderFingerprint: "someone-else-778899")

        #expect(manager.cachedVouchList(from: "voucher-fp-001122") == nil)
    }
}
