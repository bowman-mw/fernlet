// MeshRoutedHeartAck.swift
// FernletSocial/HeartSharing
//
// Network migration P5 item 4 (plan §11's heart stage): a routed heart's ledger judgement as PROOF —
// the heart ledger's commit outcome and its own durability proof for one gift, never a re-implementation
// of the ledger's rules, beside the heart ledger, its proof and the heart row's ledger judge, with both
// proof-taking initializers: it is the judge's proof gate, and the engine mints the stage's evidence
// from the judge's answer alone (plan step A0.5.3), so no evidence initializer exists in either
// module.

import Foundation

// MARK: - MeshRoutedHeartAck

/// A routed heart's ledger judgement, as PROOF — derived from `MeshHeartCommitOutcome` plus the
/// ledger's own ``MeshHeartLedgerProof``, never a re-implementation of its dedup, cooldown or
/// retention rules.
///
/// The heart row's ledger judge (``MeshSessionHearts``' private adapter since plan step A0.5.10)
/// answers ProximityKit's `MeshRoutedJudgement.committed` only when this value can be built for the gift
/// it was handed, and the engine mints the stage's evidence, its internal `.ledgerCommit`, from that
/// answer alone — so no evidence exists for a gift the ledger does not stand behind (plan step
/// A0.5.3).
///
/// Two facts to carry rather than re-derive. **Pruning is not a regression**: a delivered gift may
/// fall out of the ledger's 32-item / 48-hour window later, and only the FIRST mint consults the
/// ledger — `MeshRoutedItemRecord.deliveredAt`, not the ledger, is the durable gate that stops the
/// second ask. And `MeshHeartCommit.commit(_:into:)` bounds its loop at `MeshMergedHeart.setCapacity`,
/// so "not in the outcome" is **not** "refused": ``judgementsForGift`` is the field that tells the
/// two apart, and a gift beyond that bound yields no evidence and stays enumerable rather than being
/// acknowledged on a guess.
nonisolated struct MeshRoutedHeartAck: Equatable, Sendable {
    /// The gift id, which for ``ProximityNamespace/RoutedTypes/heart`` IS the manifest's `itemID`.
    let giftID: UUID
    /// How many times the ledger judged THIS gift in the outcome that produced this evidence —
    /// always 1 when the value exists.
    ///
    /// `MeshHeartCommitOutcome.judgements` is a **batch** counter (`received.count + refused.count`)
    /// and is deliberately not the field carried here: the reused idempotence assertion (P4 item 7)
    /// is "each distinct gift id offered is judged exactly once", and this is that statement for one
    /// gift.
    let judgementsForGift: Int

    /// The pure form, for tier 1 and for callers holding both values already.
    ///
    /// Answers nil — so no evidence, and therefore no receipt — unless BOTH legs hold:
    ///
    ///  1. this gift was judged exactly once **in this outcome**. Never `outcome.judgements == 1`:
    ///     `MeshHeartCommit.commit(_:into:)` is a BATCH door and every shipped call site hands it a
    ///     whole merged set, so a pass carrying two hearts has `judgements == 2` and a per-pass leg
    ///     would fail closed for BOTH — silently, until expiry.
    ///  2. `proof.giftID == giftID` — the ledger's own answer to "the write landed and the gift is
    ///     in the stored set". A caller cannot construct a ``MeshHeartLedgerProof``.
    ///
    /// - Parameters:
    ///   - outcome: What the ledger made of the batch this gift was offered in.
    ///   - giftID: The gift, which is the routed item's id.
    ///   - proof: The ledger's own durability answer.
    init?(outcome: MeshHeartCommitOutcome, giftID: UUID, proof: MeshHeartLedgerProof) {
        let judged = outcome.receivedGiftIDs.filter { $0 == giftID }.count
            + outcome.refusedGiftIDs.filter { $0 == giftID }.count
        guard judged == 1 else { return nil }
        guard proof.giftID == giftID else { return nil }
        self.giftID = giftID
        judgementsForGift = judged
    }

    /// The one-call form: asks the ledger for its proof SYNCHRONOUSLY, right after the commit and
    /// never after an `await`, so the conjunction cannot be got wrong at a call site. Reads only.
    ///
    /// - Important: the caller must be in `MeshSessionState.activeForeground` — never
    ///   `.continuingInBackground`. That predicate lives on the mesh manager and cannot be reached
    ///   from a pure value; the engine asks it before it hands the heart row's ledger judge an item,
    ///   whose one construction of this value is the call site. It is the **only** leg on the heart
    ///   path a caller can satisfy by assertion — the other two are proof-gated.
    ///
    /// - Parameters:
    ///   - outcome: What the ledger made of the batch this gift was offered in.
    ///   - giftID: The gift, which is the routed item's id.
    ///   - ledger: The heart ledger that judged it.
    @MainActor
    init?(outcome: MeshHeartCommitOutcome, giftID: UUID, ledger: ProximityHeartLedger) {
        guard let proof = ledger.commitProof(for: giftID) else { return nil }
        self.init(outcome: outcome, giftID: giftID, proof: proof)
    }
}
