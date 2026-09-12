// MeshRoutedHeartTests.swift
// FernletTests
//
// Network migration P6 item 6 (plan §12): hearts on the routed store — the body's framing, the
// registry flip and its subset target, and the ACK CEREMONY end to end on a real two-node founding.
//
// **What tier 1 proves, and what it does not.** A mesh heart needs mutual trust-vault rows, and a
// row appears when `pendingFriendReview` completes — which fires at session END. So inside the
// session that produced a heart those rows CANNOT exist, and every ceremony cell here seeds them
// directly. That seeding stands in for a second session, so these cells prove the ceremony's
// mechanics and nothing about the product's first session: **item 10's two-session Lane C script is
// the only honest proof of the feature.** The explicit negative
// (`aHeartFromANonFriendIsRefusedFinalAndCustodyIsKept`, vault empty) is what keeps the seeding
// from being the whole argument.
//
// Three more fixture facts, each easy to get wrong here specifically:
//
// - **The rig is `MeshFoundingRig`**, because the ceremony needs a mesh the REAL commit path
//   founded: `MeshRoutedDrainRig` hand-seeds a ledger and fakes its commits, and the key
//   advertisements a single-recipient mint resolves its wrap against are minted by the production
//   founding doors. A heart cell on a seeded rig is green over nothing (item 1's own warning).
// - **`judgementsForGift`, never the batch counter.** The ceremony hands `MeshHeartCommit.commit` a
//   ONE-element batch, so `MeshHeartCommitOutcome.judgements` and
//   `MeshRoutedHeartAck.judgementsForGift` coincide at every shipping call site. The exactly-once
//   claim is therefore witnessed by counting `onHeartJudgedForTesting` firings per gift, and
//   `aTwoHeartBatchSeparatesTheBatchCounterFromThePerGiftCount` is the fixture-only cell proving the
//   two fields really are different questions.
// - **The ack the wall pins must be the SHIPPING one.** W2's pin scans
//   `FernletKit/Sources/ProximityKit` only, so a `MeshRoutedHeartAck` a test constructs is invisible
//   to it — which is why the ceremony cells assert a stored `MeshRecipientReceipt` produced by the
//   real `commitLocalDelivery`, never an ack value a cell built.

@testable import ProximityKit
import Foundation
import SwiftUI
import Testing
@testable import FernletCrypto
import FernletDomainModel
import FernletFoundation
@testable import Fernlet

// MARK: - The body

/// ``MeshRoutedHeartBody``'s framing, its four hostile shapes, its two field refusals and its cap.
@Suite(.serialized)
struct MeshRoutedHeartBodyTests {

    private static let giftID = UUID(uuidString: "6E3B1D2C-0000-4000-8000-00000000BEEF")!

    private static func header(
        id: UUID = giftID, dayKey: String = "2026-09-11", name: String = "Robin"
    ) -> MeshRoutedHeartHeader {
        MeshRoutedHeartHeader(id: id, sentAtDayKey: dayKey, senderName: name)
    }

    /// Round trip, and the framing really is the family's: an 8-byte big-endian length prefix, the
    /// header's JSON, and **nothing after it**.
    @Test func theBodyIsItsFramedHeaderAndNothingElse() throws {
        let encoded = try MeshRoutedHeartBody(header: Self.header()).encoded()
        let prefixWidth = MeshRoutedItemBodyFormat.headerLengthPrefixByteCount
        var declared = 0
        // R2: bounded by the fixed prefix width.
        for byte in encoded.prefix(prefixWidth) { declared = (declared << 8) | Int(byte) }
        #expect(declared == encoded.count - prefixWidth,
                "the payload half is empty, so the declared header runs to the end")
        let decoded = try MeshRoutedHeartBody(decoding: encoded)
        #expect(decoded.header == Self.header())
    }

    /// **Four hostile shapes, one frozen token.** The fourth is this family's own: a photo's
    /// remainder is the image and a message's is the text, so both read to the end — a heart's
    /// remainder is nothing, and bytes an authenticated blob carries but nobody reads are a
    /// malleability seam inside it.
    @Test func fourHostileHeartBodyShapesLandOnMalformed() throws {
        let good = try MeshRoutedHeartBody(header: Self.header()).encoded()
        let shapes: [(name: String, bytes: Data)] = [
            ("too short for the prefix", good.prefix(4)),
            ("a prefix past the remaining bytes", Data([0, 0, 0, 0, 0, 0, 0xFF, 0xFF]) + good.dropFirst(8)),
            ("an in-bounds slice that is not the header's JSON",
             good.prefix(8) + Data(repeating: 0x7B, count: good.count - 8)),
            ("a non-empty remainder", good + Data([0x00]))
        ]
        // R2: bounded by the shape list.
        for shape in shapes {
            #expect(throws: MeshRoutedItemSealError.malformed) {
                _ = try MeshRoutedHeartBody(decoding: shape.bytes)
            }
        }
        #expect(shapes.count == 4, "four shapes, and the fourth is the trailing byte")
        // The negative control: the same bytes with nothing appended DO decode, so the trailing-byte
        // refusal is about the tail and not about the body.
        #expect(throws: Never.self) { _ = try MeshRoutedHeartBody(decoding: good) }
    }

    /// A trailing byte alone is refused — stated as its own claim because it is the one shape a copy
    /// of the photo body's decoder gets wrong by omission.
    @Test func aTrailingByteAfterTheHeaderIsRefused() throws {
        let good = try MeshRoutedHeartBody(header: Self.header()).encoded()
        #expect(throws: MeshRoutedItemSealError.malformed) {
            _ = try MeshRoutedHeartBody(decoding: good + Data([0x20]))
        }
    }

    /// The day key is a SHAPE on the wire, exactly where the retired handler checked it.
    @Test func anInvalidDayKeyIsRefused() throws {
        let bad = try MeshRoutedHeartBody(header: Self.header(dayKey: "not-a-day")).encoded()
        #expect(throws: MeshRoutedItemSealError.malformed) {
            _ = try MeshRoutedHeartBody(decoding: bad)
        }
        let good = try MeshRoutedHeartBody(header: Self.header(dayKey: "2026-09-11")).encoded()
        #expect(throws: Never.self) { _ = try MeshRoutedHeartBody(decoding: good) }
    }

    /// The 128-byte name bound is enforced on the WIRE, not only at the mint — the cap's arithmetic
    /// is over that bound, so accepting a wider name would admit a header the formula says cannot
    /// exist. With an at-the-bound negative control.
    @Test func anOversizedSenderNameIsRefusedAtTheBound() throws {
        let atBound = String(repeating: "a", count: MeshRoutedHeartBody.maxSenderNameUTF8ByteCount)
        let overBound = atBound + "a"
        #expect(throws: Never.self) {
            _ = try MeshRoutedHeartBody(
                decoding: try MeshRoutedHeartBody(header: Self.header(name: atBound)).encoded()
            )
        }
        #expect(throws: MeshRoutedItemSealError.malformed) {
            _ = try MeshRoutedHeartBody(
                decoding: try MeshRoutedHeartBody(header: Self.header(name: overBound)).encoded()
            )
        }
        #expect(MeshRoutedHeartBody.bounded(senderName: overBound).utf8.count
                <= MeshRoutedHeartBody.maxSenderNameUTF8ByteCount,
                "and the mint bounds its own name so it cannot breach its own row")
    }

    /// **The cap as a formula, and the allowance MEASURED rather than asserted.** A zero payload
    /// term, this family's framed header, and the seal's overhead — every term read from the type
    /// that owns it.
    @Test func theHeartRowsCapIsTheFramedHeaderPlusTheSealOverhead() throws {
        #expect(MeshRoutedHeartBody.maxSealedBlobByteCount
                == MeshRoutedHeartBody.maxFramedHeaderByteCount
                    + MeshRoutedItemSealFormat.overheadByteCount)
        #expect(MeshRoutedHeartBody.maxFramedHeaderByteCount
                == MeshRoutedItemBodyFormat.headerLengthPrefixByteCount
                    + MeshRoutedHeartBody.maxHeaderJSONByteCount)
        let entry = try #require(
            MeshRoutedTypeRegistry.increment1.entry(for: MeshRoutedTypeToken.heart)
        )
        #expect(entry.maxItemByteCount == UInt64(MeshRoutedHeartBody.maxSealedBlobByteCount),
                "the row is DEFINED as the formula, never as a copy of its value")
        #expect(entry.maxItemByteCount < MeshRoutedManifestFormat.maxContentByteCount,
                "and it really narrows — the row sat at the shared 256 MiB wire bound before item 6")
    }

    /// The header allowance covers a maximal header at a 2× floor, measured.
    @Test func theHeartHeaderAllowanceCoversAMaximalHeader() throws {
        let widest = MeshRoutedHeartHeader(
            id: UUID(),
            sentAtDayKey: "2026-12-31",
            senderName: String(repeating: "é", count: MeshRoutedHeartBody.maxSenderNameUTF8ByteCount / 2)
        )
        let json = try MeshRoutedItemBodyFormat.headerEncoder().encode(widest)
        #expect(json.count * 2 <= MeshRoutedHeartBody.maxHeaderJSONByteCount,
                "a maximal heart header must fit its allowance with a 2x floor")
    }
}

// MARK: - The registry flip and the subset target

/// The `.singleRecipient` column at a real mint: the flip, the capture door's two refusals, and the
/// shape fence in BOTH directions.
@MainActor
@Suite(.serialized)
struct MeshRoutedHeartTargetTests {

    /// The flip itself, plus the per-token map that replaced "every row is full-roster".
    @Test func theHeartRowIsSingleRecipient() throws {
        let registry = MeshRoutedTypeRegistry.increment1
        let semantics: [String: MeshRoutedDestinationSemantics] = [
            MeshRoutedTypeToken.photo: .fullRosterAtCreation,
            MeshRoutedTypeToken.tempMessage: .fullRosterAtCreation,
            MeshRoutedTypeToken.heart: .singleRecipient
        ]
        // R2: bounded by the registry's own tokens.
        for token in registry.tokens {
            let entry = try #require(registry.entry(for: token), "\(token)")
            #expect(entry.destinations == semantics[token], "\(token)")
        }
    }

    /// The capture door names only its recipient, and the roster is still the only authority.
    @Test func aSubsetTargetNamesOnlyItsRecipient() throws {
        let rig = try MeshDeliveryFixtures.rig(memberCount: 3)
        let me = rig.fingerprints[0]
        let recipient = rig.fingerprints[2]
        guard case .updated(let target) = MeshDeliveryTarget.addressing(
            contentID: UUID(), recipient: recipient, roster: rig.roster, selfFingerprint: me
        ) else {
            Issue.record("a roster member must be addressable")
            return
        }
        #expect(target.destinations == [recipient])
        #expect(target.destinationCount == 1)
        #expect(!target.names(rig.fingerprints[1]),
                "and NOT the third member, which a full-roster capture would have included")
    }

    @Test func aRecipientOutsideTheRosterAtCreationIsRefusedByName() throws {
        let rig = try MeshDeliveryFixtures.rig(memberCount: 3)
        #expect(MeshDeliveryTarget.addressing(
            contentID: UUID(), recipient: "fp-stranger", roster: rig.roster,
            selfFingerprint: rig.fingerprints[0]
        ) == .refused(.recipientNotInRoster))
    }

    /// Self is checked FIRST on purpose: a roster always contains this device, so the other order
    /// would report the wrong fact.
    @Test func aRecipientThatIsThisDeviceIsRefusedByName() throws {
        let rig = try MeshDeliveryFixtures.rig(memberCount: 3)
        let me = rig.fingerprints[0]
        #expect(rig.roster.contains(fingerprint: me), "the precondition that makes the order matter")
        #expect(MeshDeliveryTarget.addressing(
            contentID: UUID(), recipient: me, roster: rig.roster, selfFingerprint: me
        ) == .refused(.recipientIsSelf))
    }

    /// A one-destination progress map restores: `restoring` refuses an EMPTY set, a duplicate and an
    /// over-cap one, and deliberately has no smaller-than-roster refusal.
    @Test func aOneDestinationDeliveryMapRestores() throws {
        let rig = try MeshDeliveryFixtures.rig(memberCount: 3)
        let recipient = rig.fingerprints[2]
        guard case .restored(let target) = MeshDeliveryTarget.restoring(
            contentID: UUID(), destinations: [recipient], progress: [recipient: .delivered]
        ) else {
            Issue.record("a single-destination map must restore")
            return
        }
        #expect(target.destinations == [recipient])
        #expect(target.state(of: recipient) == .delivered)
    }

    @Test func theDeliveryRefusalVocabularyIsFrozen() {
        #expect(MeshDeliveryRefusal.allCases.map(\.rawValue) == [
            "notADestination", "alreadyDelivered", "wouldRegress",
            "differentContent", "destinationSetMismatch",
            "recipientIsSelf", "recipientNotInRoster"
        ], "audit vocabulary; two cases joined it at P6 item 6")
    }
}

// MARK: - The ceremony

/// The ack ceremony on a real two-node founding: a heart delivered founder → joiner through the
/// production path and judged **exactly once**, plus every refusal leg and its retryable/FINAL
/// classification.
@MainActor
@Suite(.serialized)
struct MeshRoutedHeartCeremonyTests {

    private let day = Date(timeIntervalSince1970: 1_780_000_000)

    /// A founded pair with hearts on at both ends, a ledger at each, and the vault rows a mesh heart
    /// needs — **seeded, which is the thing to be honest about**: production reaches this state only
    /// across two sessions (`pendingFriendReview` completes at session END), so this rig proves the
    /// ceremony's mechanics and item 10's Lane C script proves the feature.
    ///
    /// - Parameters:
    ///   - label: The diagnostic prefix.
    ///   - trustBothWays: Whether to seed the vault rows at all — false is the explicit negative.
    /// - Returns: the rig and the recipient's ledger.
    private func founded(
        _ label: String, trustBothWays: Bool = true, openRecipientGate: Bool = true
    ) async throws -> (rig: MeshFoundingRig, recipientLedger: ProximityHeartLedger) {
        let rig = try MeshFoundingRig.build(2, label: label)
        rig.link(0, 1)
        rig.commit(0, 1)
        rig.commit(1, 0)
        try await rig.settle()
        rig.ensureForeground(at: 0, facing: 1)
        rig.ensureForeground(at: 1, facing: 0)
        let recipientLedger = rig.isolatedHeartLedger(now: day)
        rig.nodes[0].manager.heartLedger = rig.isolatedHeartLedger(now: day)
        rig.nodes[1].manager.heartLedger = recipientLedger
        rig.nodes[0].store.setAllowNearbyHearts(true)
        rig.nodes[1].store.setAllowNearbyHearts(true)
        if trustBothWays {
            rig.trustPeer(at: 1, asSeenFrom: 0)
            rig.trustPeer(at: 0, asSeenFrom: 1)
        }
        if openRecipientGate { rig.openGate(at: 1) }
        #expect(rig.nodes[1].manager.sessionState == .activeForeground,
                "the heart stage's third leg is a live FOREGROUND session — without it every cell here defers")
        return (rig, recipientLedger)
    }

    /// **The item's headline, measured at the RECIPIENT.** A heart minted through the real
    /// `sendSessionHeart` reaches the far node over the production push/drain, is judged at the live
    /// delivery door in the same pass, and the receipt is STORED — never an ack a cell built.
    @Test func aHeartIsDeliveredAndJudgedExactlyOnceAtTheLiveDoor() async throws {
        let (rig, ledger) = try await founded("heart-live")
        defer { rig.teardown() }
        var judged: [UUID] = []
        rig.nodes[1].manager.onHeartJudgedForTesting = { judged.append($0.giftID) }
        var closeness: [String] = []
        rig.nodes[1].manager.onHeartReceived = { closeness.append($0) }

        let giftID = try #require(rig.sendHeartReturningItemID(from: 0, to: 1, name: "Robin"))
        try await rig.settle()

        #expect(judged == [giftID], "the gift is judged exactly once, by its own per-gift witness")
        #expect(ledger.receivedHearts.map(\.id) == [giftID], "and the ledger holds it")
        let record = try #require(rig.routedIndex(1)?.record(for: rig.key(origin: 0, itemID: giftID)))
        #expect(record.deliveredAt != nil, "the delivery really was stamped")
        #expect(record.recipientReceipts.contains { $0.recipientFingerprint == rig.nodes[1].fingerprint },
                "and this device's own receipt is STORED, which is what the ack is for")
        #expect(closeness == [rig.nodes[0].fingerprint],
                "closeness is fed once, with the ORIGIN rather than the courier")
    }

    /// **The closeness hook must fire on FIRST ACCEPTANCE, not on every ack mint.**
    ///
    /// `commitProof` answers non-nil for an ALREADY-STORED gift, so a ceremony that reaches an
    /// already-held gift id still mints a valid ack and still stores a receipt — and the hook behind
    /// `onHeartReceived` is `closenessLedger.recordHeartReceived`, which is not idempotent. The gate
    /// is therefore `outcome.receivedGiftIDs.contains`, never the ack's existence.
    ///
    /// The rig constructs exactly that state: the heart is delivered with the recipient's gate
    /// CLOSED (so nothing is judged), its gift id is pre-recorded in the recipient's ledger, and
    /// only then does the gate open. `recordReceivedHeart` answers false on the id, so
    /// `receivedGiftIDs` is empty while `commitProof` is non-nil.
    @Test func anAlreadyHeldGiftMintsItsReceiptWithoutFeedingClosenessAgain() async throws {
        let (rig, ledger) = try await founded("heart-already-held", openRecipientGate: false)
        defer { rig.teardown() }
        let giftID = try #require(rig.sendHeartReturningItemID(from: 0, to: 1, name: "Robin"))
        try await rig.settle()
        let key = rig.key(origin: 0, itemID: giftID)
        try #require(rig.routedIndex(1)?.record(for: key)?.isComplete == true,
                     "the precondition: the recipient holds the whole heart behind a closed gate")
        #expect(ledger.receivedHearts.isEmpty, "and has judged nothing")
        // The same gift id is already in the ledger's stored set — a re-delivery after a receipt
        // that could not be stamped, or a duplicate that crossed a split.
        #expect(ledger.recordReceivedHeart(
            id: giftID, senderDisplayName: "Robin", senderFingerprint: rig.nodes[0].fingerprint
        ), "the precondition: the gift is stored BEFORE the ceremony runs")
        var closeness: [String] = []
        var judged: [UUID] = []
        rig.nodes[1].manager.onHeartReceived = { closeness.append($0) }
        rig.nodes[1].manager.onHeartJudgedForTesting = { judged.append($0.giftID) }

        rig.openGate(at: 1)

        #expect(judged == [giftID], "the ack still mints — the ledger stands behind the gift")
        let record = try #require(rig.routedIndex(1)?.record(for: key))
        #expect(record.deliveredAt != nil, "and the receipt is still stamped")
        #expect(closeness.isEmpty,
                "but closeness is NOT fed again: an already-stored gift is not a new acceptance")
        #expect(ledger.receivedHearts.filter { $0.id == giftID }.count == 1,
                "and the ledger holds exactly one row for the gift")
    }

    /// A STAMPED record is never re-asked of the ledger: with `deliveredAt` written, the durable ack
    /// IS the satisfied precondition, so a later pass re-mints the receipt from the stored instant
    /// and asks nothing.
    ///
    /// **Honest about what this observes.** Deleting `routedAckEvidence`'s `deliveredAt == nil`
    /// guard does NOT red this cell, and the reason is that the guard is belt-and-braces over two
    /// earlier stops: `itemsAwaitingLocalAck` is keyed on the stored recipient receipt, so a filed
    /// item leaves job 4's list entirely, and the live door's `routedRungsOutstanding` answers
    /// false once custody and the receipt are both written. So the claim is real and its
    /// enforcement is triple, but only the outer two are reachable from a tier-1 rig — the guard is
    /// what keeps the door honest if either of those ever narrows, and its absence is a review
    /// event rather than a test failure. Recorded rather than dressed up as a red-once.
    @Test func aStampedHeartIsNeverReAskedOfTheLedger() async throws {
        let (rig, ledger) = try await founded("heart-stamped")
        defer { rig.teardown() }
        let giftID = try #require(rig.sendHeartReturningItemID(from: 0, to: 1, name: "Robin"))
        try await rig.settle()
        try #require(ledger.receivedHearts.map(\.id) == [giftID], "the precondition: it was judged")
        var judged: [UUID] = []
        var closeness: [String] = []
        rig.nodes[1].manager.onHeartJudgedForTesting = { judged.append($0.giftID) }
        rig.nodes[1].manager.onHeartReceived = { closeness.append($0) }

        rig.pushGateEdge(at: 1)
        try await rig.settle()

        #expect(judged.isEmpty, "a stamped heart's ceremony does not run again")
        #expect(closeness.isEmpty, "so closeness cannot be fed twice by a later pass either")
        #expect(ledger.receivedHearts.count == 1)
    }

    /// A heart to an admitted member with **no live slot** is staged and custodied, and delivered
    /// once the link forms — the sentence the whole item exists for.
    @Test func aHeartToAnAdmittedMemberWithNoLiveSlotIsStagedAndCustodied() async throws {
        let (rig, ledger) = try await founded("heart-unlinked")
        defer { rig.teardown() }
        rig.dropLink(0, 1)
        #expect(!rig.nodes[0].manager.hasLiveHeartSlot(forFingerprint: rig.nodes[1].fingerprint),
                "the precondition: no live slot faces the recipient")
        #expect(rig.nodes[0].manager.canSendSessionHeart(toFingerprint: rig.nodes[1].fingerprint),
                "but the member is still addressable — that is the unlock")

        let giftID = try #require(rig.sendHeartReturningItemID(from: 0, to: 1, name: "Robin"))
        try await rig.settle()
        #expect(ledger.receivedHearts.isEmpty, "nothing is delivered while the link is down")
        let staged = try #require(rig.routedIndex(0)?.record(for: rig.key(origin: 0, itemID: giftID)))
        #expect(staged.isComplete, "the origin holds the sealed heart, durably")

        // The drain is EXCHANGE-driven: the re-commit opens a merge exchange, and the inventory,
        // the digest and the bulk answer each ride a later round. One settle is not the shape of
        // "it converges" here — a bounded number of commit-and-settle rounds is, with an early exit
        // the moment the ledger holds the gift.
        rig.relink(0, 1)
        // R2: bounded by the rig's own round count.
        for _ in 0..<MeshDepartureRig.settleRounds {
            try await rig.settle()
            if ledger.receivedHearts.map(\.id).contains(giftID) { break }
            rig.commit(1, 0)
        }

        #expect(ledger.receivedHearts.map(\.id) == [giftID],
                "and the drain carries it once a link exists again")
    }

    /// A recipient in the background defers — retryably, with nothing marked — and the next
    /// foreground edge judges. There is no `.activeBackground`: `applySessionEvent(.backgrounded)`
    /// moves the machine to `.continuingInBackground`, which is what closes the predicate.
    @Test func aBackgroundedRecipientDefersAndTheNextForegroundEdgeJudges() async throws {
        let (rig, ledger) = try await founded("heart-background")
        defer { rig.teardown() }
        rig.nodes[1].manager.applySessionEvent(MeshSessionEvent.backgrounded)
        #expect(rig.nodes[1].manager.sessionState == .continuingInBackground,
                "the precondition: the session is continuing in the background")
        #expect(!rig.nodes[1].manager.mayCommitRoutedHeartLedgerJudgement,
                "so the heart stage's predicate is closed")

        let giftID = try #require(rig.sendHeartReturningItemID(from: 0, to: 1, name: "Robin"))
        try await rig.settle()
        #expect(ledger.receivedHearts.isEmpty, "a backgrounded recipient judges nothing")
        let held = try #require(rig.routedIndex(1)?.record(for: rig.key(origin: 0, itemID: giftID)))
        #expect(held.isComplete, "but it HOLDS the ciphertext")
        #expect(held.deliveredAt == nil, "and has stamped no delivery")
        #expect(!rig.nodes[1].manager.routedHeartRefusedKeys.contains(rig.key(origin: 0, itemID: giftID)),
                "and nothing is marked — a closed predicate is retryable by construction")

        rig.nodes[1].manager.applySessionEvent(MeshSessionEvent.foregrounded)
        rig.pushGateEdge(at: 1)

        #expect(ledger.receivedHearts.map(\.id) == [giftID], "the foreground pass judges it")
    }

    /// **Hearts-off is an enumeration FILTER, not a mark**, so flipping it on re-enumerates the
    /// population for free with nothing to un-mark.
    @Test func aHeartsOffFlipOnRejudgesWithoutAMark() async throws {
        let (rig, ledger) = try await founded("heart-off-on")
        defer { rig.teardown() }
        rig.nodes[1].store.setAllowNearbyHearts(false)

        let giftID = try #require(rig.sendHeartReturningItemID(from: 0, to: 1, name: "Robin"))
        try await rig.settle()
        let key = rig.key(origin: 0, itemID: giftID)
        #expect(ledger.receivedHearts.isEmpty, "hearts-off judges nothing")
        #expect(!rig.nodes[1].manager.routedHeartRefusedKeys.contains(key),
                "and marks nothing, or the flip could not heal")

        rig.nodes[1].store.setAllowNearbyHearts(true)
        rig.pushGateEdge(at: 1)

        #expect(ledger.receivedHearts.map(\.id) == [giftID], "the flip on heals for free")
    }

    /// The ledger's five-minute per-sender cooldown is RETRYABLE: nothing is stored, so
    /// `commitProof` answers nil, the stage reports `ledgerJudgementMissing`, custody is kept and
    /// the item stays enumerable — then the same gift lands once the window ages out.
    @Test func aCooldownRefusalLeavesTheHeartEnumerableAndHealsAfterTheWindow() async throws {
        let rig = try MeshFoundingRig.build(2, label: "heart-cooldown-recv")
        defer { rig.teardown() }
        rig.link(0, 1)
        rig.commit(0, 1)
        rig.commit(1, 0)
        try await rig.settle()
        rig.ensureForeground(at: 0, facing: 1)
        rig.ensureForeground(at: 1, facing: 0)
        var clock = day
        let ledger = rig.isolatedHeartLedger(now: { clock })
        rig.nodes[1].manager.heartLedger = ledger
        rig.nodes[0].manager.heartLedger = rig.isolatedHeartLedger(now: day)
        rig.nodes[0].store.setAllowNearbyHearts(true)
        rig.nodes[1].store.setAllowNearbyHearts(true)
        rig.trustPeer(at: 0, asSeenFrom: 1)
        rig.openGate(at: 1)
        // A heart from the same sender landed seconds ago — the receive window's own precondition.
        #expect(ledger.recordReceivedHeart(
            id: UUID(), senderDisplayName: "Robin", senderFingerprint: rig.nodes[0].fingerprint
        ), "the precondition: the sender is inside the receive window")

        let giftID = try #require(rig.sendHeartReturningItemID(from: 0, to: 1, name: "Robin"))
        try await rig.settle()
        let key = rig.key(origin: 0, itemID: giftID)
        #expect(!ledger.receivedHearts.map(\.id).contains(giftID), "the cooldown refuses the gift")
        let held = try #require(rig.routedIndex(1)?.record(for: key))
        #expect(held.deliveredAt == nil, "nothing is stamped")
        #expect(!rig.nodes[1].manager.routedHeartRefusedKeys.contains(key),
                "and it is NOT marked — a cooldown is a not-yet, not a no")

        clock = day.addingTimeInterval(600)
        rig.pushGateEdge(at: 1)

        #expect(ledger.receivedHearts.map(\.id).contains(giftID),
                "and the same gift is accepted once the window ages out")
    }

    /// **The explicit negative, with the vault EMPTY.** Not-a-friend is FINAL and marked — the row a
    /// mesh heart needs appears only when `pendingFriendReview` completes at session end, so
    /// parking it buys nothing and costs an allowance slot.
    @Test func aHeartFromANonFriendIsRefusedFinalAndCustodyIsKept() async throws {
        let (rig, ledger) = try await founded("heart-nonfriend", trustBothWays: false)
        defer { rig.teardown() }
        let giftID = try #require(rig.sendHeartReturningItemID(from: 0, to: 1, name: "Robin"))
        try await rig.settle()
        let key = rig.key(origin: 0, itemID: giftID)

        #expect(ledger.receivedHearts.isEmpty, "an unknown sender's heart is never recorded")
        #expect(rig.nodes[1].manager.routedHeartRefusedKeys.contains(key),
                "and it is marked FINAL, so sixteen of them cannot hold the ack allowance")
        let held = try #require(rig.routedIndex(1)?.record(for: key))
        #expect(held.isComplete, "custody is kept until expiry — the bytes are not dropped")
        #expect(held.deliveredAt == nil)
    }

    /// **R3's leg.** A locally BLOCKED member is still on the derived roster (blocking is not
    /// removal), so its hearts reach the ceremony — and they must be MARKED, or sixteen of them hold
    /// job 4's whole allowance until expiry: R-19's starvation, reachable by the one adversary the
    /// block list exists for.
    @Test func aHeartFromABlockedOriginIsRefusedFinalAndMarked() async throws {
        let (rig, ledger) = try await founded("heart-blocked")
        defer { rig.teardown() }
        rig.blockPeer(at: 0, asSeenFrom: 1)
        #expect(rig.roster(1).contains(rig.nodes[0].fingerprint),
                "the precondition: blocking does NOT remove a member from the roster")

        let giftID = try #require(rig.sendHeartReturningItemID(from: 0, to: 1, name: "Robin"))
        try await rig.settle()
        let key = rig.key(origin: 0, itemID: giftID)

        #expect(ledger.receivedHearts.isEmpty, "a blocked origin's heart is never recorded")
        #expect(rig.nodes[1].manager.routedHeartRefusedKeys.contains(key),
                "and the leg is MARKED — the defect this cell exists for was a bare return")
    }

    /// **A judged heart must not log `noDispatchArm` on the SUCCESS path.** `finishLocalRungs` calls
    /// the projection for every item whose recipient receipt it just minted, and the dispatch's
    /// early return spells "this build has no arm for this type" — a false diagnostic about a type
    /// the pass has just finished. The filter on `requiresForegroundDecryptBeforeFinal` is what
    /// closes it; without the filter this cell reds.
    @Test func aJudgedHeartLogsNoMissingDispatchArm() async throws {
        let (rig, ledger) = try await founded("heart-no-arm-log")
        defer { rig.teardown() }
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }

        let giftID = try #require(rig.sendHeartReturningItemID(from: 0, to: 1, name: "Robin"))
        try await rig.settle()

        #expect(ledger.receivedHearts.map(\.id) == [giftID], "the precondition: it really was judged")
        #expect(capture.count(of: "mesh.routedProjection.noDispatchArm") == 0, """
            a heart that was just judged must not be reported as a type this build cannot \
            dispatch — the projection is not its door
            """)
        // And the same filter is what keeps a heart out of job 5's ROTATION: without it the
        // projection defers the item, charging one permanent entry per received heart into a 1024
        // bound it can never leave, because the token is never enumerated so no pass can mark it
        // final (item 5 review, P2-2 — dormant until this commit, live from it).
        #expect(!rig.nodes[1].manager
                .routedRetryRotationForTesting(.localProjection)
                .contains(rig.key(origin: 0, itemID: giftID)), """
            a heart must not occupy a slot in the projection's rotation, whose list its own token \
            is filtered out of
            """)
    }

    /// `.heartLedger` is deliberately absent from the projection list, and a complete, locally
    /// destined heart therefore never appears on job 5's enumeration at all.
    @Test func theHeartTokenIsNotProjectable() async throws {
        let (rig, _) = try await founded("heart-not-projectable")
        defer { rig.teardown() }
        let giftID = try #require(rig.sendHeartReturningItemID(from: 0, to: 1, name: "Robin"))
        try await rig.settle()
        let projectable = rig.nodes[1].manager.projectableRoutedTypeTokensForTesting
        #expect(!projectable.contains(MeshRoutedTypeToken.heart),
                "a heart's plaintext pass is its ack ceremony, not a projection")
        // The set is exactly the two tokens that HAVE an arm, and `.sessionTranscript` is further
        // conditional on `isChatAllowed` — off in this fixture's store, which is why the claim is
        // written as a subset plus the heart's absence rather than as a count. A later tidy-up that
        // added `.heartLedger` would break the first assertion and this one together.
        #expect(projectable.isSubset(of: [MeshRoutedTypeToken.photo, MeshRoutedTypeToken.tempMessage]),
                "only the two stores with a dispatch arm may be projectable")
        #expect(projectable.contains(MeshRoutedTypeToken.photo), "and the photo arm really is one")
        let awaiting = rig.routedIndex(1)?.itemsAwaitingLocalProjection(
            at: Date(), for: rig.nodes[1].fingerprint, types: projectable
        ) ?? []
        #expect(!awaiting.map(\.key).contains(rig.key(origin: 0, itemID: giftID)),
                "and the heart never occupies a slot on job 5's 16-item allowance")
    }

    /// The batch counter and the per-gift count are different questions, and the ceremony's
    /// one-element batch makes them coincide — so this is the fixture-only cell that separates them.
    @Test func aTwoHeartBatchSeparatesTheBatchCounterFromThePerGiftCount() throws {
        let ledger = ProximityHeartLedger(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("heart-batch-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent("HeartLedger.json"),
            now: { self.day }
        )
        let first = UUID()
        let second = UUID()
        let outcome = MeshHeartCommit.commit([
            MeshMergedHeart(giftID: first, senderFingerprint: "fp-a",
                            senderDisplayName: "A", firstSeenAt: day),
            MeshMergedHeart(giftID: second, senderFingerprint: "fp-b",
                            senderDisplayName: "B", firstSeenAt: day)
        ], into: ledger)

        #expect(outcome.judgements == 2, "the batch counter counts the BATCH")
        let ack = try #require(MeshRoutedHeartAck(outcome: outcome, giftID: first, ledger: ledger))
        #expect(ack.judgementsForGift == 1,
                "while the per-gift field answers the question the invariant is about")
        #expect(ack.judgementsForGift != outcome.judgements,
                "an invariant written against the batch counter would be green for an accident of the ceremony's one-element call")
    }

    /// The app's copy fork is exhaustive over the frozen token, and the package composes no sentence.
    @Test func everyHeartFailureCauseHasLocalizedCopy() throws {
        // R2: bounded by the enum's cases.
        for cause in MeshNetworkManager.SessionHeartFailure.allCases {
            let message: LocalizedStringKey = SessionHeartStatusCopy.message(
                cause, recipientName: "Robin Jones"
            )
            #expect(message != SessionHeartStatusCopy.sent(recipientName: "Robin Jones"),
                    "a failure sentence, never the success one")
        }
        #expect(SessionHeartStatusCopy.message(.cooldown, recipientName: "Robin")
                != SessionHeartStatusCopy.message(.ledgerUnavailable, recipientName: "Robin"),
                "an unloaded ledger is a different fact from a live cooldown — the §2.1 bug fix")
        #expect(SessionHeartStatusCopy.line(.idle) == nil)
        #expect(SessionHeartStatusCopy.line(.sent(recipientName: "Robin")) != nil)
        let manager = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("FernletKit/Sources/ProximityKit/Mesh/MeshNetworkManager.swift")
        )
        #expect(!manager.contains("some warmth"),
                "the heart sentences are composed in the app, never in the package")
        #expect(!manager.contains("no heart was sent"))
        #expect(manager.contains("sessionHeartState = .failed(cause, recipientName:"),
                "the package publishes its frozen token instead")
    }
}

// MARK: - MeshFoundingRig: the heart seams

/// What a heart scenario needs on top of item 2's founding rig: the two per-node pieces the app
/// wires (a heart ledger and the hearts opt-in), the trust-vault rows a mesh heart's eligibility
/// gate reads, the send itself under the pinned install binding, and a rising gate edge.
///
/// An extension rather than fields on the rig, because founding cells must keep starting from a
/// state with no heart state at all.
@MainActor
extension MeshFoundingRig {

    /// A temp-file-backed ledger, one per node, so a cell's assertions are isolated from the shared
    /// on-disk `HeartLedger.json` and from the presence path's ledger.
    func isolatedHeartLedger(now: Date) -> ProximityHeartLedger {
        isolatedHeartLedger(now: { now })
    }

    /// The injected-clock form, for the cell that has to age a five-minute window out.
    func isolatedHeartLedger(now: @escaping () -> Date) -> ProximityHeartLedger {
        ProximityHeartLedger(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("routed-heart-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent("HeartLedger.json"),
            now: now
        )
    }

    /// The handshake-shaped identity one node presents to another — the value the trust vault keys
    /// its rows on, built from the same two fields the rig's own pump hands the manager.
    private func peerIdentityForHearts(of index: Int) -> ProximityCoordinator.PeerIdentity {
        let identity = identities[index]
        return ProximityCoordinator.PeerIdentity(
            id: nodes[index].handle.id,
            displayName: nodes[index].label,
            signingPublicKey: identity.localSigningPublicKey,
            keyAgreementPublicKey: identity.localKeyAgreementPublicKey,
            fingerprint: identity.localFingerprint,
            rangingMode: .rssi,
            firstSeenAt: Date(),
            capabilities: ProximityCapability.allCases.map(\.rawValue)
        )
    }

    /// Seeds the vault row that makes `index` an ACTIVE, unblocked friend as `viewer` sees them.
    ///
    /// **This is the seeding the suite header is honest about**: production reaches this state only
    /// across two sessions, because the row appears when `pendingFriendReview` completes at session
    /// END. It stands in for that second session and proves nothing about the first.
    func trustPeer(at index: Int, asSeenFrom viewer: Int) {
        nodes[viewer].store.proximityTrustVault.trust(peerIdentityForHearts(of: index), mode: .friend)
    }

    /// Blocks `index` as `viewer` sees them — a LOCAL judgement that does not remove them from the
    /// derived roster, which is what makes the blocked leg a live case rather than a hypothetical.
    func blockPeer(at index: Int, asSeenFrom viewer: Int) {
        nodes[viewer].store.proximityTrustVault
            .block(signingPublicKey: identities[index].localSigningPublicKey)
    }

    /// Sends one heart through the real public API, under the pinned install binding (the founding's
    /// own seal and the routed store's writes both need it).
    func sendHeart(from node: Int, to friend: ProximityTrustedPeerRecord) {
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            nodes[node].manager.sendSessionHeart(to: friend)
        }
    }

    /// Sends one heart from `node` to the member at `recipient` and answers the gift id it minted,
    /// read back out of the sender's own routed index rather than out of a seam — so a cell that
    /// gets a nil here is looking at a mint that did not happen.
    func sendHeartReturningItemID(from node: Int, to recipient: Int, name: String) -> UUID? {
        let friend = ProximityTrustedPeerRecord(
            displayName: name,
            fingerprint: nodes[recipient].fingerprint,
            signingPublicKey: identities[recipient].localSigningPublicKey,
            keyAgreementPublicKey: identities[recipient].localKeyAgreementPublicKey,
            mode: .friend,
            firstAcceptedAt: Date(),
            lastSeenAt: Date()
        )
        sendHeart(from: node, to: friend)
        let mine = nodes[node].fingerprint
        return routedIndex(node)?.items.first {
            $0.key.originFingerprint == mine
                && $0.manifest?.typeToken == MeshRoutedTypeToken.heart
        }?.key.itemID
    }

    /// The routed index key one node's heart is held under.
    func key(origin: Int, itemID: UUID) -> MeshRoutedItemKey {
        MeshRoutedItemKey(originFingerprint: nodes[origin].fingerprint, itemID: itemID)
    }

    /// Drops `near`'s slot facing `far` through the production removal funnel, leaving the member on
    /// the derived roster — "admitted, not linked", which is the state the whole item exists for.
    func dropLink(_ near: Int, _ far: Int) {
        nodes[near].manager.evictSlotForTesting(peerID: nodes[far].handle.id)
    }

    /// Re-seats and re-commits the dropped direction through the REAL commit path, which is what
    /// opens the merge exchange the drain rides.
    func relink(_ near: Int, _ far: Int) {
        reseat(near, toward: far)
        commit(near, far)
    }

    /// Raises one node's session state to `.activeForeground` by driving a further commit, which is
    /// what a second dwell tick does in production.
    ///
    /// **It is needed because of a named item 2 residual, and it is worth stating.** Both halves of
    /// a proximity-join pair found, and the loser YIELDS to the winner's mesh — and the adoption
    /// re-arms the session, leaving the yielder holding a mesh with `sessionState == .joining` until
    /// some later `.peerCommitted` arrives. The founder election runs over random per-run
    /// fingerprints, so WHICH node that is flips from run to run: without this, half of every
    /// ceremony cell's runs would defer the heart for a reason the cell was not about. The heart
    /// stage's third leg (`sessionState == .activeForeground`) is the only routed predicate that
    /// reads the session at all, which is why item 6 is where this surfaced.
    func ensureForeground(at node: Int, facing peer: Int) {
        guard nodes[node].manager.sessionState != .activeForeground else { return }
        commit(node, peer)
    }

    /// A falling then rising access-gate edge at one node — the re-entry pass's own trigger.
    func pushGateEdge(at node: Int) {
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            _ = nodes[node].manager.applyRoutedAccessGate(
                MeshRoutedAccessGate(
                    protectedDataAvailable: false, appIsForeground: true, duressActive: false
                ),
                now: Date()
            )
            _ = nodes[node].manager.applyRoutedAccessGate(MeshRoutedDrainRig.openGate, now: Date())
        }
    }
}


