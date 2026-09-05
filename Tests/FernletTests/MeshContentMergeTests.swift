// MeshContentMergeTests.swift
// FernletTests
//
// P4 item 7 (plan §10.3, and §21.3's "re-run at ingestion" decision): **content merge — ordering,
// dedup, and the gates re-run at ingestion.**
//
// §10.3's four rules, each a claim here:
//
//   1. **Photos** union by manifest ID, hash-validated on reassembly, then the existing review flow.
//   2. **Texts** union by message ID; the visible transcript is re-derived in total order
//      `(claimedSentAt clamped to ±10 min of first-seen, senderFingerprint, messageID)`.
//   3. **Hearts** union by gift ID; the final receipt is still only the foreground decrypt +
//      ledger commit, and the ledger's own dedup/cooldown arbitrates a duplicate that crossed
//      the split.
//   4. **N-way merges need no special case** — union is commutative, associative and idempotent, so
//      a 4/2/2 partition tree converges as links form in any order.
//
// Plus §21.3's decision, asserted rather than implied: **a branch's approval is not a free pass.**
// The age gate and the local block/ban re-run at the *receiving* member, as a **view filter over an
// unmutated union** — the record still unions everywhere; only what renders differs. That is the
// same shape as termination-derived-at-read (item 6), and for the same reason: a merge that mutated
// the record would break all three union laws at once.
//
// **Everything here is pure.** No radio, no manager, no wall clock — every instant comes from
// `MeshContentFixtures.base` and every "first seen" from an injected receiver clock. The one type
// that touches disk (``ProximityHeartLedger``) gets a per-instance temp root, per the shared-disk-root
// flake family.
//
// **`keyEpoch` (plan §21.5, and what P5 item 13 did with it).** These tests sit at the model seam
// *below* where `MeshNetworkManager`'s three `keyEpoch` gates used to stand.
// `contentFromTheOtherBranchKeepsItsEpoch` is now the record of which of them was retired with
// which path: two are GONE with the group-key photo transport they gated, and the third kept its
// compare over the control arms it still guards. None was ever loosened in place — the assertions
// here are unchanged, because this seam never had an epoch judgement of its own to relax.

import Foundation
import Testing
import FernletDomainModel
@testable import ProximityKit

// MARK: - MeshContentFixtures

/// Deterministic ids, instants and content values — nothing random, nothing wall-clock.
enum MeshContentFixtures {

    /// The pinned instant every scenario measures from.
    static let base = Date(timeIntervalSince1970: 1_800_000_000)

    /// A deterministic UUID whose `uuidString` sorts by `n`, so id-tiebreak assertions are stable.
    static func id(_ n: Int) -> UUID {
        let high = UInt8((n >> 8) & 0xFF)
        let low = UInt8(n & 0xFF)
        return UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, high, low))
    }

    /// `base` offset by `seconds`.
    static func at(_ seconds: TimeInterval) -> Date { base.addingTimeInterval(seconds) }

    /// A merged photo with a digest that matches `bytes`.
    static func photo(
        _ n: Int,
        sender: String = "alice",
        epoch: Int = 3,
        addedAt seconds: TimeInterval = 0,
        bytes: Data? = nil
    ) -> MeshMergedPhoto {
        let payload = bytes ?? Data("photo-\(n)".utf8)
        return MeshMergedPhoto(
            manifestID: id(n),
            senderFingerprint: sender,
            keyEpoch: epoch,
            addedAt: at(seconds),
            contentDigest: MeshPhotoReassembly.digest(of: payload)
        )
    }

    /// A merged message. `claimed` and `firstSeen` are seconds from ``base``.
    static func message(
        _ n: Int,
        sender: String = "alice",
        text: String? = nil,
        claimed: TimeInterval,
        firstSeen: TimeInterval
    ) -> MeshMergedMessage {
        MeshMergedMessage(
            messageID: id(n),
            senderFingerprint: sender,
            text: text ?? "m\(n)",
            claimedSentAt: at(claimed),
            firstSeenAt: at(firstSeen)
        )
    }

    /// A merged heart.
    static func heart(
        _ n: Int,
        sender: String = "alice",
        name: String = "Alice",
        firstSeen: TimeInterval = 0
    ) -> MeshMergedHeart {
        MeshMergedHeart(
            giftID: id(n),
            senderFingerprint: sender,
            senderDisplayName: name,
            firstSeenAt: at(firstSeen)
        )
    }

    /// A bounded, deterministic family of arrival orders over `count` items: every rotation and its
    /// reversal, capped at six rotations so the family can never grow without bound.
    static func arrivalOrders(count: Int) -> [[Int]] {
        var orders: [[Int]] = []
        for shift in 0..<min(count, 6) {
            let rotated = (0..<count).map { ($0 + shift) % count }
            orders.append(rotated)
            orders.append(Array(rotated.reversed()))
        }
        return orders
    }
}

// MARK: - Union laws

/// The three laws every union in §10.3 must satisfy, at the caps as well as below them.
@Suite("Mesh content union laws")
@MainActor
struct MeshContentUnionLawTests {

    private typealias F = MeshContentFixtures

    @Test("Photo union is commutative, associative and idempotent")
    func photoUnionObeysTheLaws() {
        let a = MeshContentSet([F.photo(1, addedAt: 10), F.photo(2, addedAt: 20)])
        let b = MeshContentSet([F.photo(2, addedAt: 20), F.photo(3, addedAt: 30)])
        let c = MeshContentSet([F.photo(4, addedAt: 40)])

        #expect(a.merging(b) == b.merging(a))
        #expect(a.merging(b).merging(c) == a.merging(b.merging(c)))
        #expect(a.merging(a) == a)
        #expect(a.merging(b).contentIDs == Set([F.id(1), F.id(2), F.id(3)]))
    }

    @Test("Message union is commutative, associative and idempotent")
    func messageUnionObeysTheLaws() {
        let a = MeshContentSet([F.message(1, claimed: 10, firstSeen: 10)])
        let b = MeshContentSet([F.message(2, claimed: 20, firstSeen: 20)])
        let c = MeshContentSet([F.message(3, claimed: 30, firstSeen: 30)])

        #expect(a.merging(b) == b.merging(a))
        #expect(a.merging(b).merging(c) == a.merging(b.merging(c)))
        #expect(b.merging(b) == b)
    }

    @Test("Heart union is commutative, associative and idempotent")
    func heartUnionObeysTheLaws() {
        let a = MeshContentSet([F.heart(1, firstSeen: 1)])
        let b = MeshContentSet([F.heart(2, firstSeen: 2), F.heart(1, firstSeen: 1)])
        let c = MeshContentSet([F.heart(3, firstSeen: 3)])

        #expect(a.merging(b) == b.merging(a))
        #expect(a.merging(b).merging(c) == a.merging(b.merging(c)))
        #expect(c.merging(c) == c)
    }

    @Test("The laws still hold at the heart set's cap")
    func heartUnionObeysTheLawsAtCapacity() {
        let cap = MeshMergedHeart.setCapacity
        let a = MeshContentSet((0..<cap).map { F.heart($0, firstSeen: TimeInterval($0)) })
        let b = MeshContentSet((cap / 2..<cap + cap / 2).map { F.heart($0, firstSeen: TimeInterval($0)) })
        let c = MeshContentSet((cap..<cap + 8).map { F.heart($0, firstSeen: TimeInterval($0)) })

        #expect(a.count == cap)
        #expect(a.merging(b).count == cap)
        #expect(a.merging(b) == b.merging(a))
        #expect(a.merging(b).merging(c) == a.merging(b.merging(c)))
        #expect(a.merging(a) == a)
    }

    @Test("The laws still hold at the photo set's cap")
    func photoUnionObeysTheLawsAtCapacity() {
        let cap = MeshMergedPhoto.setCapacity
        let a = MeshContentSet((0..<cap).map { F.photo($0, addedAt: TimeInterval($0)) })
        let b = MeshContentSet((cap / 2..<cap + 100).map { F.photo($0, addedAt: TimeInterval($0)) })
        let c = MeshContentSet((cap + 50..<cap + 150).map { F.photo($0, addedAt: TimeInterval($0)) })

        #expect(a.merging(b).count == cap)
        #expect(a.merging(b) == b.merging(a))
        #expect(a.merging(b).merging(c) == a.merging(b.merging(c)))
        #expect(a.merging(b).merging(b) == a.merging(b))
    }

    @Test("The cap keeps the newest items, matching every live surface's own bound")
    func theCapKeepsTheNewest() {
        let cap = MeshMergedHeart.setCapacity
        let set = MeshContentSet((0..<(cap + 5)).map { F.heart($0, firstSeen: TimeInterval($0)) })
        #expect(set.count == cap)
        #expect(set.contains(F.id(cap + 4)))
        #expect(!set.contains(F.id(0)))
        #expect(set.isAtCapacity)
    }

    @Test("The merged caps are the live surfaces' caps, not a second set of numbers")
    func mergedCapsTrackTheLiveOnes() {
        #expect(MeshMergedMessage.setCapacity == SessionMessageStore.maxMessages)
        #expect(MeshMergedHeart.setCapacity == ProximityHeartLedger.maxStoredHearts)
        #expect(MeshMergedPhoto.setCapacity == FriendPhotoLimits.maxManifestEntries)
    }
}

// MARK: - Photos

/// §10.3 rule 1: union by manifest ID, hash-validated on reassembly, then the existing review flow.
@Suite("Mesh content merge — photos")
@MainActor
struct MeshContentPhotoMergeTests {

    private typealias F = MeshContentFixtures

    @Test("Two branches union by manifest ID, the shared one appearing once")
    func branchesUnionByManifestID() {
        let branchA = MeshContentSet([F.photo(1, addedAt: 10), F.photo(2, addedAt: 20), F.photo(9, addedAt: 90)])
        let branchB = MeshContentSet([F.photo(3, addedAt: 30), F.photo(4, addedAt: 40), F.photo(9, addedAt: 90)])

        let merged = branchA.merging(branchB)
        #expect(merged.count == 5)
        #expect(merged.contentIDs == Set([1, 2, 3, 4, 9].map(F.id)))
        #expect(merged.all.filter { $0.manifestID == F.id(9) }.count == 1)
    }

    @Test("Reassembled bytes that do not match the digest are rejected AT reassembly")
    func aDigestMismatchIsRejectedAtReassembly() {
        let bytes = Data("the real photo".utf8)
        let photo = F.photo(1, bytes: bytes)
        let empty = MeshContentSet<MeshMergedPhoto>.empty

        let tampered = MeshPhotoReassembly.admitting(photo, reassembled: Data("not it".utf8), into: empty)
        #expect(tampered.verdict == .rejectedDigestMismatch)
        #expect(tampered.set.isEmpty)   // not silently kept

        let truncated = MeshPhotoReassembly.admitting(photo, reassembled: Data(), into: empty)
        #expect(truncated.verdict == .rejectedEmpty)
        #expect(truncated.set.isEmpty)

        let good = MeshPhotoReassembly.admitting(photo, reassembled: bytes, into: empty)
        #expect(good.verdict == .accepted)
        #expect(good.set.contains(F.id(1)))
    }

    @Test("A rejected manifest never re-enters the union by a second merge")
    func aRejectedManifestStaysOut() {
        let photo = F.photo(1, bytes: Data("real".utf8))
        let held = MeshContentSet([F.photo(2, addedAt: 20)])
        let attempt = MeshPhotoReassembly.admitting(photo, reassembled: Data("fake".utf8), into: held)
        #expect(attempt.set == held)
        #expect(attempt.set.merging(held) == held)
    }

    @Test("Merged photos enter the same review state a live one does")
    func mergedPhotosEnterTheSameReviewState() {
        // A photo this member already held live, and one that arrived only through the merge.
        let live = F.photo(1, sender: "alice", addedAt: 10)
        let merged = F.photo(2, sender: "bob", addedAt: 20)
        let ledger = MeshContentLedger(photos: MeshContentSet([live]))
            .merging(MeshContentLedger(photos: MeshContentSet([merged])))

        // The gates cannot tell them apart: both show, and blocking either author hides exactly it.
        let open = MeshContentGates.open
        #expect(ledger.visiblePhotos(gates: open).map(\.manifestID) == [F.id(1), F.id(2)])

        let blockingBob = MeshContentGates(chatAllowed: true, blockedFingerprints: ["bob"])
        #expect(ledger.visiblePhotos(gates: blockingBob).map(\.manifestID) == [F.id(1)])

        let blockingAlice = MeshContentGates(chatAllowed: true, blockedFingerprints: ["alice"])
        #expect(ledger.visiblePhotos(gates: blockingAlice).map(\.manifestID) == [F.id(2)])

        // And the record is untouched either way — the gate is a view, not a mutation.
        #expect(ledger.photos.count == 2)
    }

    @Test("Content from the other branch keeps its own keyEpoch through the union (plan §21.5)")
    func contentFromTheOtherBranchKeepsItsEpoch() {
        // The union adds NO epoch judgement of its own, and since P5 item 13 the live path adds
        // none either for CONTENT. What became of the three gates this comment used to list:
        //   * `handlePhotoManifest`'s `.filter { $0.keyEpoch >= localJoinedEpoch }` — RETIRED with
        //     the pull protocol itself; the routed drain is push-only and names no epoch.
        //   * `handleFriendPhotoEnvelope`'s `key.epoch == photo.keyEpoch` — RETIRED with the
        //     group-key photo decrypt; a routed item carries a per-recipient content-key wrap, so
        //     branch and epoch no longer decide decryptability.
        //   * `handleEncryptedMetadata`'s `wrapper.keyEpoch == currentGroupKey?.epoch` — KEPT, and
        //     deliberately: its two CONTENT arms retired, but the door survives with two control
        //     arms that have no routed successor, and deleting the compare over those would be
        //     loosening a gate in place (D-13.5b).
        // A photo minted at epoch 7 in the other branch, merged into a member sitting at epoch 3,
        // survives the union byte-identical — and now reaches that member's wall as well.
        let ours = MeshContentSet([F.photo(1, epoch: 3, addedAt: 10)])
        let theirs = MeshContentSet([F.photo(2, epoch: 7, addedAt: 20)])
        let merged = ours.merging(theirs)

        #expect(merged.count == 2)
        #expect(merged.all.map(\.keyEpoch) == [3, 7])
        #expect(merged.all.contains(F.photo(2, epoch: 7, addedAt: 20)))
    }
}

// MARK: - Texts

/// §10.3 rule 2: union by message ID, transcript re-derived in `(clamped claim, sender, id)` order.
@Suite("Mesh content merge — texts")
@MainActor
struct MeshContentTranscriptTests {

    private typealias F = MeshContentFixtures

    @Test("A claimed stamp is clamped to ±10 minutes of first-seen")
    func aClaimedStampIsClampedToTenMinutes() {
        let window = MeshMergedMessage.claimWindow
        #expect(window == 600)

        let future = F.message(1, claimed: 3 * 3600, firstSeen: 0)
        #expect(future.orderingInstant == F.at(window))

        let past = F.message(2, claimed: -3 * 3600, firstSeen: 0)
        #expect(past.orderingInstant == F.at(-window))

        let honest = F.message(3, claimed: 120, firstSeen: 0)
        #expect(honest.orderingInstant == F.at(120))   // inside the window: untouched
    }

    @Test("A forged stamp cannot jump the queue by more than ten minutes")
    func aForgedStampCannotJumpTheQueue() {
        // `forged` claims three hours in the past; `honest` genuinely arrived 20 minutes before it.
        let forged = F.message(2, sender: "mallory", claimed: -3 * 3600, firstSeen: 0)
        let honest = F.message(1, sender: "alice", claimed: -20 * 60, firstSeen: -20 * 60)
        let transcript = MeshContentLedger(messages: MeshContentSet([forged, honest]))
            .visibleTranscript(gates: .open)

        // The clamp floors the forgery at first-seen − 10 min, which is still AFTER the honest one.
        #expect(forged.orderingInstant == F.at(-600))
        #expect(transcript.map(\.messageID) == [F.id(1), F.id(2)])
    }

    @Test("Ties break by senderFingerprint, then by messageID")
    func tiesBreakBySenderThenID() {
        let sameInstant: TimeInterval = 100
        let zoe = F.message(1, sender: "zoe", claimed: sameInstant, firstSeen: sameInstant)
        let amy2 = F.message(2, sender: "amy", claimed: sameInstant, firstSeen: sameInstant)
        let amy3 = F.message(3, sender: "amy", claimed: sameInstant, firstSeen: sameInstant)

        let transcript = MeshContentLedger(messages: MeshContentSet([zoe, amy3, amy2]))
            .visibleTranscript(gates: .open)
        #expect(transcript.map(\.senderFingerprint) == ["amy", "amy", "zoe"])
        #expect(transcript.map(\.messageID) == [F.id(2), F.id(3), F.id(1)])
    }

    @Test("Duplicate message ids collapse to one")
    func duplicateIDsCollapse() {
        let one = F.message(1, claimed: 10, firstSeen: 10)
        let same = F.message(1, claimed: 10, firstSeen: 10)
        let merged = MeshContentSet([one]).merging(MeshContentSet([same]))
        #expect(merged.count == 1)
    }

    @Test("Every member derives the identical transcript regardless of arrival order")
    func everyMemberDerivesTheIdenticalTranscript() {
        // Six messages, three senders, claims deliberately out of index order.
        let claims: [TimeInterval] = [30, 10, 50, 20, 40, 0]
        let senders = ["amy", "bob", "cara", "amy", "bob", "cara"]
        let orders = MeshContentFixtures.arrivalOrders(count: claims.count)
        #expect(orders.count >= 6)

        var transcripts: [[UUID]] = []
        for order in orders {
            // Each "member" walks its own arrival order on its OWN clock: first-seen advances one
            // second per arrival, so no two members assign the same first-seen values.
            var ledger = MeshContentLedger.empty
            for (step, index) in order.enumerated() {
                let message = F.message(
                    index,
                    sender: senders[index],
                    claimed: claims[index],
                    firstSeen: TimeInterval(step)
                )
                ledger = ledger.merging(MeshContentLedger(messages: MeshContentSet([message])))
            }
            transcripts.append(ledger.visibleTranscript(gates: .open).map(\.messageID))
        }

        // Sorted by claim: 5 (0s), 1 (10s), 3 (20s), 0 (30s), 4 (40s), 2 (50s).
        let expected = [5, 1, 3, 0, 4, 2].map(F.id)
        for transcript in transcripts { #expect(transcript == expected) }
    }

    @Test("First-seen is the RECEIVER's clock, never a stamp in the message")
    func firstSeenIsTheReceiversClock() {
        // The same message reaching two members at different local instants.
        let atAlice = F.message(1, claimed: 60, firstSeen: 55)
        let atBob = F.message(1, claimed: 60, firstSeen: 400)

        #expect(atAlice.firstSeenAt != atBob.firstSeenAt)
        #expect(atAlice.claimedSentAt == atBob.claimedSentAt)
        // Honest claim (inside both windows) ⇒ both members order it at the claim itself.
        #expect(atAlice.orderingInstant == atBob.orderingInstant)
        #expect(atAlice.orderingInstant == F.at(60))
    }
}

// MARK: - Hearts

/// §10.3 rule 3: union by gift ID; the final receipt is the ledger's, not the merge's.
@Suite("Mesh content merge — hearts")
@MainActor
struct MeshContentHeartMergeTests {

    private typealias F = MeshContentFixtures

    /// A ledger on its own temp root (shared-disk-root flake family) with an injected clock.
    private func isolatedLedger(_ clock: @escaping () -> Date) -> ProximityHeartLedger {
        ProximityHeartLedger(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("mesh-content-merge-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent("HeartLedger.json"),
            now: clock
        )
    }

    @Test("A merged heart is pending until the ledger commits a receipt")
    func aMergedHeartIsPendingUntilTheLedgerCommits() {
        let ledger = isolatedLedger { F.at(0) }
        let merged = MeshContentLedger(hearts: MeshContentSet([F.heart(1, firstSeen: 1)]))

        #expect(merged.heartReceipt(F.id(1), committed: []) == .pending)

        let outcome = MeshHeartCommit.commit(merged.visibleHearts(gates: .open), into: ledger)
        #expect(outcome.receivedGiftIDs == [F.id(1)])
        #expect(merged.heartReceipt(F.id(1), committed: outcome.committed) == .received)
        #expect(ledger.receivedHearts.map(\.id) == [F.id(1)])
    }

    @Test("A duplicate that crossed the split is judged ONCE, not twice")
    func aDuplicateAcrossTheSplitIsJudgedOnce() {
        let ledger = isolatedLedger { F.at(0) }
        // The same gift id held by both branches.
        let branchA = MeshContentLedger(hearts: MeshContentSet([F.heart(1, firstSeen: 1)]))
        let branchB = MeshContentLedger(hearts: MeshContentSet([F.heart(1, firstSeen: 2)]))
        let merged = branchA.merging(branchB)

        #expect(merged.hearts.count == 1)
        let outcome = MeshHeartCommit.commit(merged.visibleHearts(gates: .open), into: ledger)
        #expect(outcome.judgements == 1)          // the union collapsed it BEFORE the ledger saw it
        #expect(outcome.receivedGiftIDs == [F.id(1)])
        #expect(ledger.receivedHearts.count == 1)
    }

    @Test("The ledger's existing dedup and cooldown arbitrate, not a second copy of them")
    func theLedgersOwnDedupAndCooldownArbitrate() {
        var instant = F.at(0)
        let ledger = isolatedLedger { instant }

        // Two DISTINCT hearts from one sender inside the 5-minute window: the ledger's cooldown
        // refuses the second. Nothing in the merge layer re-implements this rule.
        let batch = [F.heart(1, sender: "alice", firstSeen: 1), F.heart(2, sender: "alice", firstSeen: 2)]
        let first = MeshHeartCommit.commit(batch, into: ledger)
        #expect(first.judgements == 2)
        #expect(first.receivedGiftIDs == [F.id(1)])
        #expect(first.refusedGiftIDs == [F.id(2)])

        // Past the cooldown, a later heart from the same sender lands.
        instant = F.at(6 * 60)
        let later = MeshHeartCommit.commit([F.heart(3, sender: "alice", firstSeen: 360)], into: ledger)
        #expect(later.receivedGiftIDs == [F.id(3)])

        // And re-offering an already-committed id is refused by the ledger's id dedup.
        let replay = MeshHeartCommit.commit([F.heart(1, sender: "alice", firstSeen: 1)], into: ledger)
        #expect(replay.receivedGiftIDs.isEmpty)
        #expect(replay.refusedGiftIDs == [F.id(1)])
    }

    @Test("Hearts union by gift ID across branches")
    func heartsUnionByGiftID() {
        let a = MeshContentSet([F.heart(1, firstSeen: 1), F.heart(2, firstSeen: 2)])
        let b = MeshContentSet([F.heart(2, firstSeen: 2), F.heart(3, firstSeen: 3)])
        #expect(a.merging(b).contentIDs == Set([1, 2, 3].map(F.id)))
    }
}

// MARK: - Gates re-run at ingestion (§21.3)

/// §21.3's decision, asserted: content does NOT get a free pass because another branch approved it.
@Suite("Mesh content merge — gates re-run at ingestion")
@MainActor
struct MeshContentGateTests {

    private typealias F = MeshContentFixtures

    /// A ledger both members hold after the merge: one message, one photo, one heart from `mallory`,
    /// plus an innocuous message from `alice`.
    private func mergedLedger() -> MeshContentLedger {
        let branchA = MeshContentLedger(
            messages: MeshContentSet([F.message(1, sender: "alice", claimed: 10, firstSeen: 10)])
        )
        let branchB = MeshContentLedger(
            photos: MeshContentSet([F.photo(2, sender: "mallory", addedAt: 20)]),
            messages: MeshContentSet([F.message(3, sender: "mallory", claimed: 30, firstSeen: 30)]),
            hearts: MeshContentSet([F.heart(4, sender: "mallory", firstSeen: 40)])
        )
        return branchA.merging(branchB)
    }

    @Test("A member whose age gate refuses chat shows no transcript, though the other branch did")
    func theAgeGateIsReRunAtTheReceivingMember() {
        let ledger = mergedLedger()

        let adult = MeshContentGates(chatAllowed: true, blockedFingerprints: [])
        #expect(ledger.visibleTranscript(gates: adult).count == 2)

        let underAge = MeshContentGates(chatAllowed: false, blockedFingerprints: [])
        #expect(ledger.visibleTranscript(gates: underAge).isEmpty)

        // The gate is chat-only, exactly like the live one: photos and hearts are unaffected.
        #expect(ledger.visiblePhotos(gates: underAge).count == 1)
        #expect(ledger.visibleHearts(gates: underAge).count == 1)

        // …and the RECORD unioned regardless. The gate is a view filter, not a record mutation.
        #expect(ledger.messages.count == 2)
    }

    @Test("A local block filters at that member only; the record still unions everywhere")
    func moderationFiltersAtOneMemberOnly() {
        let ledger = mergedLedger()

        let blocking = MeshContentGates(chatAllowed: true, blockedFingerprints: ["mallory"])
        #expect(ledger.visibleTranscript(gates: blocking).map(\.messageID) == [F.id(1)])
        #expect(ledger.visiblePhotos(gates: blocking).isEmpty)
        #expect(ledger.visibleHearts(gates: blocking).isEmpty)

        // The member that did NOT block sees everything from the same union.
        let permissive = MeshContentGates.open
        #expect(ledger.visibleTranscript(gates: permissive).count == 2)
        #expect(ledger.visiblePhotos(gates: permissive).count == 1)
        #expect(ledger.visibleHearts(gates: permissive).count == 1)

        // Identical ledgers at both members — only the derived view differs.
        #expect(ledger == mergedLedger())
        #expect(ledger.messages.count == 2)
        #expect(ledger.photos.count == 1)
        #expect(ledger.hearts.count == 1)
    }

    @Test("Gates fold from the live predicate over exactly the senders the merge produced")
    func gatesFoldFromTheLivePredicate() {
        let ledger = mergedLedger()
        #expect(ledger.senders == Set(["alice", "mallory"]))

        let gates = MeshContentGates.folding(
            chatAllowed: true,
            senders: ledger.senders,
            isRefused: { $0 == "mallory" }
        )
        #expect(gates == MeshContentGates(chatAllowed: true, blockedFingerprints: ["mallory"]))
        #expect(!gates.admits("mallory"))
        #expect(gates.admits("alice"))
    }

    @Test("Re-opening a gate reveals the merged record without a second merge")
    func reOpeningAGateNeedsNoSecondMerge() {
        let ledger = mergedLedger()
        #expect(ledger.visibleTranscript(gates: MeshContentGates(chatAllowed: false, blockedFingerprints: [])).isEmpty)
        #expect(ledger.visibleTranscript(gates: .open).count == 2)
    }
}

// MARK: - N-way convergence

/// §10.3 rule 4: merges are pairwise and union is associative/commutative/idempotent, so any
/// partition tree converges as links form — no special case for N.
@Suite("Mesh content merge — N-way convergence")
@MainActor
struct MeshContentNWayConvergenceTests {

    private typealias F = MeshContentFixtures

    /// Branch content for a 4/2/2 split: four members' worth on the first branch, two on each of
    /// the others, with one photo the first two branches both hold (so dedup is exercised too).
    private func branch(_ tag: String, ids: [Int]) -> MeshContentLedger {
        MeshContentLedger(
            photos: MeshContentSet(ids.map { F.photo($0, sender: tag, addedAt: TimeInterval($0)) }),
            messages: MeshContentSet(ids.map {
                F.message($0, sender: tag, claimed: TimeInterval($0), firstSeen: TimeInterval($0))
            }),
            hearts: MeshContentSet(ids.map { F.heart($0, sender: tag, firstSeen: TimeInterval($0)) })
        )
    }

    @Test("A 4/2/2 content merge converges to the identical state in any link order")
    func aFourTwoTwoMergeConverges() {
        let big = branch("big", ids: [10, 11, 12, 13])
        let left = branch("left", ids: [20, 21])
        let right = branch("right", ids: [30, 31])

        // Every order the links could form in — pairwise merges only, no special case for N.
        let orders: [MeshContentLedger] = [
            big.merging(left).merging(right),
            big.merging(right).merging(left),
            left.merging(right).merging(big),
            right.merging(left).merging(big),
            big.merging(left.merging(right)),
            left.merging(big.merging(right))
        ]

        for ledger in orders { #expect(ledger == orders[0]) }
        #expect(orders[0].photos.count == 8)
        #expect(orders[0].messages.count == 8)
        #expect(orders[0].hearts.count == 8)
    }

    @Test("Every member's transcript, photo set and heart set are identical after convergence")
    func everyMemberSeesTheSameContent() {
        let big = branch("big", ids: [10, 11, 12, 13])
        let left = branch("left", ids: [20, 21])
        let right = branch("right", ids: [30, 31])

        // Three members, three different link orders, then the same derivation at each.
        let atBig = big.merging(left).merging(right)
        let atLeft = left.merging(big).merging(right)
        let atRight = right.merging(left.merging(big))

        #expect(atBig.visibleTranscript(gates: .open) == atLeft.visibleTranscript(gates: .open))
        #expect(atLeft.visibleTranscript(gates: .open) == atRight.visibleTranscript(gates: .open))
        #expect(atBig.visiblePhotos(gates: .open) == atRight.visiblePhotos(gates: .open))
        #expect(atBig.visibleHearts(gates: .open) == atLeft.visibleHearts(gates: .open))
    }

    @Test("A nested re-split mid-merge still converges")
    func aNestedReSplitStillConverges() {
        let a = branch("a", ids: [1, 2])
        let b = branch("b", ids: [3])
        let c = branch("c", ids: [4])
        let d = branch("d", ids: [5, 6])

        // {a,b} merged, then re-split into {a} and {b,c}, then everything heals.
        let ab = a.merging(b)
        let bc = ab.merging(c)
        let healed = bc.merging(d).merging(a)
        let alternative = d.merging(c).merging(b).merging(a)

        #expect(healed == alternative)
        #expect(healed.messages.count == 6)
    }

    @Test("A shared item across three branches still appears once")
    func aSharedItemAppearsOnce() {
        let shared = F.photo(99, sender: "shared", addedAt: 99)
        let ledgers = ["a", "b", "c"].enumerated().map { index, tag in
            MeshContentLedger(photos: MeshContentSet([shared, F.photo(index + 1, sender: tag)]))
        }
        let merged = ledgers.reduce(MeshContentLedger.empty) { $0.merging($1) }
        #expect(merged.photos.all.filter { $0.manifestID == F.id(99) }.count == 1)
    }
}
