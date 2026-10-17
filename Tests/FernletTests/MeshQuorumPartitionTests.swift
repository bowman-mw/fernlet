// MeshQuorumPartitionTests.swift
// FernletTests
//
// P4 item 5 (plan §10.4): moderation under partition — the roster quorum.
//
// §10.4, verbatim, is what this file encodes:
//
//   Removal requires ⌊|roster|/2⌋ + 1 distinct signed votes (the proposal counts as the proposer's
//   vote; the target cannot vote), where roster is the *current merged derived roster* at
//   evaluation time. Votes are signed records referencing a proposal ID; a proposal expires 5
//   minutes after issuance. A completed removal becomes a permanent `SignedRemovalRecord` and
//   union-merges like any record; an incomplete proposal simply expires and leaves no trace in the
//   roster. Consequences: roster 4 → quorum 3 → a 2/2 split can moderate nobody; a 3/1 split can
//   remove the isolated member. Roster 2 → quorum 2 with the target abstaining → removal is
//   structurally impossible. After a departure shrinks roster 4 → 3, quorum drops to 2 and a
//   connected pair regains moderation power.
//
// Four claims are walled here, each one something a later item cannot cheaply re-derive:
//
// 1. **Quorum is the RECEIVER's arithmetic, on the MERGED roster.** A partition does not shrink the
//    derived roster (item 1), so a branch of two out of four is short of quorum however connected
//    it feels. The table below runs rosters 2–8 × partition shapes and checks both questions in
//    every cell: can this branch remove somebody inside it, and somebody outside it.
// 2. **No wall clock in the bytes decides anything.** Expiry is measured from the RECEIVER's own
//    first-seen instant on an injected clock. The signed `issuedAt` is only ever a *bound* (§10.3's
//    ±10 minutes), so a forged far-future stamp cannot extend a window and a forged far-past one
//    cannot kill a live proposal.
// 3. **An incomplete proposal leaves no trace.** Not a tombstone, not a sealed row, not a record —
//    the ledger's four record counts are identical before the proposal and after it expires, and
//    `MeshSessionContext` stays at schema 2 because nothing here is ever persisted.
// 4. **Two independent completions converge on ONE removal.** Three members of a branch each reach
//    quorum and each mint a record; the union deduplicates by member keeping the earliest, so the
//    merge needs no special case and no second ledger commit happens at the manager seam.
//
// Claims 1 to 3 were walled by **value tests**: `MeshRemovalQuorum` takes its clock and its roster as
// parameters and verifies no signatures, so §10.4's whole arithmetic runs with no fabric, no store and
// no transport; the signature half is `MeshMembershipRecordVerifier`'s, asserted separately with
// really-signed proposals and votes. Since the re-pin to ProximityKit 0.1.1 (2026-10-17) those four
// suites (`MeshRemovalQuorumArithmeticTests`, `MeshRemovalQuorumExpiryTests`,
// `MeshQuorumPartitionTableTests`, `MeshQuorumSignatureTests`) are ProximityKit's package suites of the
// same names and cells, which its own CI runs. What stays is the manager seam, claim 4 and the
// incomplete proposal at the seam, and the fixtures it, the convergence property suite's oracle and
// the termination suites build on.

import Foundation
import Testing
import FernletConnections
import FernletDomainModel
@testable import ProximityKit
@testable import Fernlet

// MARK: - MeshQuorumRoster

/// A roster of `n` real, provisioned members and the ledger it derives from.
///
/// The identities are kept because §10.4's departure case needs one of them to sign its own
/// departure — a fixture that only kept fingerprints could not shrink a roster honestly.
@MainActor
struct MeshQuorumRoster {

    /// The members, in creation order (NOT roster order — the roster sorts by fingerprint).
    let identities: [IdentityService]

    /// The mesh everything is keyed on.
    let meshID: UUID

    /// The records the roster is derived from.
    var ledger: MeshMembershipLedger

    /// The derived roster, re-derived on every read exactly as the shipping code does.
    var roster: MeshDerivedRoster { ledger.derivedRoster }

    /// The member fingerprints, in the roster's own deterministic order.
    var fingerprints: [String] { roster.memberFingerprints }
}

// MARK: - MeshQuorumFixtures

/// Everything the quorum scenarios build, in one place.
@MainActor
enum MeshQuorumFixtures {

    /// The pinned instant every scenario measures from. Nothing here reads a wall clock.
    ///
    /// `nonisolated` because it is a default argument below, and a `@MainActor` value cannot be one.
    nonisolated static let base = Date(timeIntervalSince1970: 1_700_000_000)

    /// A 64-byte blob standing in for a signature. ``MeshRemovalQuorum`` verifies nothing — that is
    /// ``MeshMembershipRecordVerifier``'s job and has its own suite — so a well-formed placeholder
    /// is the honest input here, and using a real one would only make the arithmetic slower.
    nonisolated static let placeholderSignature = Data(repeating: 0xAB, count: 64)

    /// A roster of `size` real, provisioned members.
    ///
    /// - Parameters:
    ///   - size: How many members. Plan §9 caps a roster at 8.
    ///   - label: Keychain-row prefix, so no two fixtures share a row.
    static func roster(size: Int, label: String) throws -> MeshQuorumRoster {
        let meshID = UUID()
        let identities = try (0..<size).map { try MeshPartitionFixtures.identity("\(label)\($0)") }
        guard let founder = identities.first else { throw MeshQuorumTestFailure.rosterTooSmall }
        #expect(Set(identities.map(\.localFingerprint)).count == size,
                "\(size) DISTINCT provisioned identities, or every claim below is vacuous")
        let ledger = try MeshPartitionFixtures.ledger(
            founder: founder, others: Array(identities.dropFirst()), meshID: meshID
        )
        let built = MeshQuorumRoster(identities: identities, meshID: meshID, ledger: ledger)
        #expect(built.roster.memberCount == size, "roster \(size) is this cell's hard precondition")
        return built
    }

    /// An unsigned-but-well-formed proposal, for the arithmetic oracle
    /// ``verdict(voters:target:roster:meshID:)``.
    static func proposal(
        meshID: UUID,
        proposalID: UUID = UUID(),
        target: String,
        proposer: String,
        issuedAt: Date = base
    ) -> SignedRemovalProposal {
        SignedRemovalProposal(
            meshID: meshID, proposalID: proposalID, targetFingerprint: target,
            proposerFingerprint: proposer, issuedAt: issuedAt, signature: placeholderSignature
        )
    }

    /// A well-formed vote agreeing with `proposal`.
    static func vote(
        on proposal: SignedRemovalProposal, voter: String, castAt: Date = base
    ) -> SignedRemovalVote {
        SignedRemovalVote(
            meshID: proposal.meshID, proposalID: proposal.proposalID,
            targetFingerprint: proposal.targetFingerprint, voterFingerprint: voter,
            castAt: castAt, signature: placeholderSignature
        )
    }

    /// Opens a proposal by `voters.first` and casts the rest, then answers §10.4 for that branch.
    ///
    /// - Parameters:
    ///   - voters: The branch members that may vote, proposer first. Never contains the target.
    ///   - target: The member proposed for removal, in the branch or outside it.
    ///   - roster: The **merged** derived roster the arithmetic is judged on.
    ///   - meshID: The mesh.
    /// - Returns: The verdict, or `.unknown` when the branch could not even open a proposal.
    static func verdict(
        voters: [String], target: String, roster: MeshDerivedRoster, meshID: UUID
    ) -> MeshRemovalQuorumVerdict {
        guard let proposer = voters.first else { return .unknown }
        var quorum = MeshRemovalQuorum()
        let opened = Self.proposal(meshID: meshID, target: target, proposer: proposer)
        guard quorum.open(opened, meshID: meshID, roster: roster, now: base) == nil else {
            return .unknown
        }
        for voter in voters.dropFirst() {
            let rejection = quorum.cast(
                Self.vote(on: opened, voter: voter), meshID: meshID, roster: roster, now: base
            )
            #expect(rejection == nil, "a branch member's vote must count: \(voter)")
        }
        return quorum.verdict(for: opened.proposalID, roster: roster, at: base)
    }
}

// MARK: - MeshQuorumTestFailure

/// A precondition a quorum fixture could not meet. Thrown rather than force-unwrapped so a broken
/// fixture fails as a named error instead of trapping (Power of 10 rule 5).
enum MeshQuorumTestFailure: Error {
    /// Fewer identities than the scenario needs.
    case rosterTooSmall
    /// A record the fixture had to sign could not be signed.
    case couldNotSign
}

// MARK: - MeshQuorumManagerSeamTests

/// §10.4 at the **manager seam**: real signed frames, four managers on one `FakePeerNetwork`, and
/// the two claims that only exist once more than one device is tallying.
///
/// The shape is P4 item 4's `MeshDepartureRig`, reused rather than copied — it already keys one
/// `ProximityCoordinator` per link, which is what makes a node with two peers attribute each frame
/// to the peer that actually sent it.
///
/// The clock here is the real one, deliberately: this suite is about who tallies what, and the
/// five-minute window and the ±10-minute issuance bound are settled by the value suites above on an
/// injected clock. Nothing sleeps, and the window is five minutes wide against a test that takes
/// milliseconds.
@MainActor
@Suite(.serialized)
struct MeshQuorumManagerSeamTests {

    /// The branch {A, B, C} of a roster of four, with D absent — §10.4's "a 3/1 split can remove
    /// the isolated member (votes are valid for absent targets)".
    ///
    /// `@MainActor` because a nested type does not inherit the enclosing suite's isolation, and
    /// every node it reaches through is main-actor state.
    @MainActor
    private struct Branch {
        let fabric: FakePeerNetwork
        let meshID: UUID
        let nodes: [MeshDepartureNode]
        var absentFingerprint: String { nodes[3].fingerprint }
        var connected: [MeshDepartureNode] { Array(nodes.prefix(3)) }
    }

    /// Builds the roster of four, links the three-member branch, and asserts the preconditions that
    /// would make every later claim vacuous.
    private func branch(_ label: String) throws -> Branch {
        let fabric = FakePeerNetwork()
        let meshID = UUID()
        let labels = (0..<4).map { "\(label)\($0)" }
        let ids = try labels.map { try MeshPartitionFixtures.identity($0) }
        #expect(Set(ids.map(\.localFingerprint)).count == 4, "four distinct provisioned identities")
        let ledger = try MeshPartitionFixtures.ledger(
            founder: ids[0], others: Array(ids.dropFirst()), meshID: meshID
        )
        var nodes: [MeshDepartureNode] = []
        for (name, identity) in zip(labels, ids) {
            let node = MeshDepartureRig.node(name, identity: identity, on: fabric)
            MeshDepartureRig.start(
                node, ledger: ledger, founderKey: ids[0].localSigningPublicKey, meshID: meshID
            )
            #expect(MeshMergeFixtures.roster(node.manager).count == 4, "roster 4 is the precondition")
            #expect(MeshDepartureRig.quorum(node) == 3, "roster 4 ⇒ quorum 3, everywhere")
            nodes.append(node)
        }
        guard nodes.count == 4 else { throw MeshQuorumTestFailure.rosterTooSmall }
        MeshDepartureRig.link(nodes[0], nodes[1], on: fabric)
        MeshDepartureRig.link(nodes[1], nodes[2], on: fabric)
        MeshDepartureRig.link(nodes[0], nodes[2], on: fabric)
        return Branch(fabric: fabric, meshID: meshID, nodes: nodes)
    }

    /// The whole §10.4 loop on the wire: A proposes, B and C vote, quorum completes at **every**
    /// member of the branch, and each mints the permanent `member-removal.v1`.
    ///
    /// D is never reachable and never told — plan §8.3 keeps the record from its subject, who
    /// learns of it as a key that no longer opens anything, and as a refused introduction.
    @Test func aBranchOfThreeRemovesTheIsolatedMemberAndEveryMemberMintsTheRecord() async throws {
        let scenario = try branch("q-seam-")
        let connected = scenario.connected
        let target = scenario.absentFingerprint

        guard let proposal = connected[0].manager.proposeSignedRemoval(of: target) else {
            throw MeshQuorumTestFailure.couldNotSign
        }
        try await MeshDepartureRig.settle(connected, on: scenario.fabric) {
            connected.allSatisfy { $0.manager.removalQuorum.proposal(proposal.proposalID) != nil }
        }
        for node in connected.dropFirst() {
            #expect(node.manager.removalQuorum.proposal(proposal.proposalID) != nil,
                    "\(node.label) must hold the proposal before it can vote on it")
            #expect(node.manager.voteOnSignedRemoval(proposal.proposalID) != nil,
                    "\(node.label)'s vote must be signable")
        }
        try await MeshDepartureRig.settle(connected, on: scenario.fabric) {
            connected.allSatisfy { MeshMergeFixtures.roster($0.manager).count == 3 }
        }
        for node in connected {
            let ledger = node.manager.membershipVerifier?.ledger
            #expect(ledger?.removals.count == 1, "\(node.label): exactly one removal record")
            #expect(ledger?.removals.all.first?.memberFingerprint == target,
                    "\(node.label): and it names the absent member")
            #expect(MeshMergeFixtures.roster(node.manager).count == 3, "\(node.label): roster 4 → 3")
            #expect(node.manager.removalQuorum.proposal(proposal.proposalID) == nil,
                    "\(node.label): a completed proposal is closed, so a late vote cannot re-run it")
        }
    }

    /// The three records the branch minted are three DIFFERENT records for one member — and the
    /// union converges on one. Commutative, idempotent, and no second ledger commit.
    ///
    /// This is the "two receivers reach quorum independently across a split" case §10.4 implies and
    /// never spells out: nothing coordinates the talliers, so the convergence has to be a property
    /// of the record set (dedup by member, earliest wins) rather than of anybody's restraint.
    @Test func independentCompletionsConvergeOnOneRemoval() async throws {
        let scenario = try branch("q-converge-")
        let connected = scenario.connected
        let target = scenario.absentFingerprint
        guard let proposal = connected[0].manager.proposeSignedRemoval(of: target) else {
            throw MeshQuorumTestFailure.couldNotSign
        }
        try await MeshDepartureRig.settle(connected, on: scenario.fabric) {
            connected.allSatisfy { $0.manager.removalQuorum.proposal(proposal.proposalID) != nil }
        }
        for node in connected.dropFirst() { _ = node.manager.voteOnSignedRemoval(proposal.proposalID) }
        try await MeshDepartureRig.settle(connected, on: scenario.fabric) {
            connected.allSatisfy { MeshMergeFixtures.roster($0.manager).count == 3 }
        }
        MeshDepartureRig.consumeRotations(connected)

        guard let ledgerA = connected[0].manager.membershipVerifier?.ledger,
              let ledgerC = connected[2].manager.membershipVerifier?.ledger else {
            throw MeshQuorumTestFailure.rosterTooSmall
        }
        // Commutative at the manager seam: A ∪ C and C ∪ A agree, and both agree with what each
        // already held — the earliest record wins by the set's own total order either way.
        let rosterBefore = MeshMergeFixtures.roster(connected[0].manager)
        connected[0].manager.mergeMembershipLedger(ledgerC)
        connected[2].manager.mergeMembershipLedger(ledgerA)
        #expect(MeshMergeFixtures.roster(connected[0].manager) == rosterBefore)
        #expect(MeshMergeFixtures.roster(connected[2].manager) == rosterBefore)
        #expect(connected[0].manager.membershipVerifier?.ledger.removals.all
                == connected[2].manager.membershipVerifier?.ledger.removals.all,
                "one effective removal, byte-identical on both devices")
        #expect(connected[0].manager.membershipVerifier?.ledger.removals.count == 1)
        // Idempotent, and no duplicate commit: `mergeMembershipLedger` only seals and rotates when
        // the roster MOVED, so "nothing was queued" is the countable form of "nothing committed".
        #expect(connected[0].manager.consumePendingRotationForTesting() == nil,
                "a merge that moved no roster queues no rotation, so it committed nothing")
        connected[0].manager.mergeMembershipLedger(ledgerC)
        #expect(MeshMergeFixtures.roster(connected[0].manager) == rosterBefore, "twice is a no-op")
        #expect(connected[0].manager.membershipVerifier?.ledger.removals.count == 1)
        #expect(connected[0].manager.consumePendingRotationForTesting() == nil)
    }

    /// The removed member is ejected at its **next connection attempt**, not by cutting a live
    /// tunnel: every survivor's introduction roster answers `barred` for it, by name.
    @Test func theRemovedMemberIsRefusedAtItsNextIntroduction() async throws {
        let scenario = try branch("q-barred-")
        let connected = scenario.connected
        let absent = scenario.nodes[3]
        guard let proposal = connected[0].manager.proposeSignedRemoval(of: absent.fingerprint) else {
            throw MeshQuorumTestFailure.couldNotSign
        }
        try await MeshDepartureRig.settle(connected, on: scenario.fabric) {
            connected.allSatisfy { $0.manager.removalQuorum.proposal(proposal.proposalID) != nil }
        }
        for node in connected.dropFirst() { _ = node.manager.voteOnSignedRemoval(proposal.proposalID) }
        try await MeshDepartureRig.settle(connected, on: scenario.fabric) {
            connected.allSatisfy { MeshMergeFixtures.roster($0.manager).count == 3 }
        }
        let key = absent.manager.identityForTesting.localSigningPublicKey
        for node in connected {
            let roster = node.manager.membershipVerifier?.roster.introductionRoster()
            #expect(roster?.verdict(for: key) == .barred, "\(node.label) refuses the removed member")
        }
        // And the branch's own three are still members, on every one of them.
        for node in connected {
            #expect(MeshMergeFixtures.roster(node.manager) == connected.map(\.fingerprint).sorted())
        }
    }

    /// A proposal that never reaches quorum leaves the ledger **exactly** as it was — all four
    /// record counts, on every member of the branch.
    @Test func anIncompleteProposalWritesNothingAtTheManagerSeam() async throws {
        let scenario = try branch("q-noquorum-")
        let connected = scenario.connected
        let before = connected.map { MeshPartitionFixtures.recordCounts($0.manager.membershipVerifier?.ledger) }
        guard let proposal = connected[0].manager
            .proposeSignedRemoval(of: scenario.absentFingerprint) else {
            throw MeshQuorumTestFailure.couldNotSign
        }
        // One vote only: two of the three needed on a roster of four.
        try await MeshDepartureRig.settle(connected, on: scenario.fabric) {
            connected.allSatisfy { $0.manager.removalQuorum.proposal(proposal.proposalID) != nil }
        }
        _ = connected[1].manager.voteOnSignedRemoval(proposal.proposalID)
        // Ends on the observable the assertions below are about, rather than running every settle
        // round out (P6 1c): the rounds it used to burn unconditionally were `Task.yield()`s, and
        // under a full-suite load each one can cost real seconds against a five-minute window.
        try await MeshDepartureRig.settle(connected, on: scenario.fabric) {
            connected.allSatisfy {
                $0.manager.removalQuorum.proposal(proposal.proposalID)?.voterFingerprints.count == 2
            }
        }
        for (index, node) in connected.enumerated() {
            #expect(MeshPartitionFixtures.recordCounts(node.manager.membershipVerifier?.ledger)
                    == before[index], "\(node.label): an incomplete proposal writes no record")
            #expect(MeshMergeFixtures.roster(node.manager).count == 4, "\(node.label): roster intact")
            // Judged at the instant THIS node opened its window, never at `Date()` (P6 1c). The
            // claim is the tally — two of the three a roster of four needs — and the window's
            // expiry is settled on an injected clock by this file's own value cells. Read at
            // `Date()`, the claim silently depended on how long the harness took to get here, and
            // answered `.expired` under load with the votes counted and the ledger untouched.
            let open = try #require(node.manager.removalQuorum.proposal(proposal.proposalID),
                                    "\(node.label): the proposal must still be open to be judged")
            let verdict = node.manager.removalQuorum.verdict(
                for: proposal.proposalID,
                roster: node.manager.membershipVerifier?.roster ?? .empty,
                at: open.firstSeenAt
            )
            #expect(verdict == .pending(required: 3, counted: 2), "\(node.label): two of three")
        }
    }
}
