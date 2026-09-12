// MeshRoutedDrainConvergenceTests.swift
// FernletTests
//
// Network migration P5 items 6 and 14 (plan §11, §3 item 14): the routed half of §16.2's
// convergence property — every outstanding delivery reaches `delivered` or a NAMED closed state
// under a bounded schedule, no content lost, no receipt double-counted.
//
// An **extension on `MeshConvergenceRun`**, not a parallel rig: the split, the events, the ordered
// heal, the full-mesh reform and the bounded settles are item 4's, and only the routed seam is new.
//
// **D-14.1, taken here: no new `MeshScheduleEvent` case.** Items 6, 8, 10 and 12 each deferred that
// matrix-wide decision to item 14, and item 14 takes it in the negative. `events(branch:…)` builds
// `kinds` and shuffles it, so one more element is one more swap draw plus one more performer draw,
// which re-phases `interleave` and `healSteps` for **every** shape and seed — voiding P4's §10.10
// evidence and every named regression fixture inside it (2c's `0x308d0d414707d80` on `2/2`, 2d's
// two `4/2/2` seeds, `departureFirstSeed`). The routed vocabulary is instead
// `MeshRoutedScheduleOverlay`, a **salted side-plan** over the same seeds and the same five shapes
// (`MeshConvergenceSchedule.swift`), in the idiom `resplit(for:)` already uses. Nothing is lost:
// the rectangle runs the whole fixed seed family across the whole partition tree, and only the
// interleaving differs — which is what items 6/8/10/12/13 already drive explicitly.
//
// Seeds come from `MeshConvergenceSeeds.family` (root `0x00F32B1C00090002`) and nothing is drawn at
// run time: a randomized seed is a flake generator, not a property test.

import CryptoKit
import Foundation
import Testing
@testable import FernletCrypto
import FernletDomainModel
@testable import ProximityKit
@testable import Fernlet

// MARK: - MeshRoutedCellFailure

/// A precondition one routed cell could not meet.
///
/// Thrown rather than force-unwrapped so a broken fixture fails as a named error instead of
/// trapping (Power of 10 rule 5) — and so "could not be built" can never read as "ran and passed".
enum MeshRoutedCellFailure: Error {

    /// The overlay's origin is not a living member of the built run.
    ///
    /// Unreachable by construction — the overlay draws its origin from `schedule.survivors`, and a
    /// survivor is exactly a member the run leaves `isParticipating`. It is a thrown error rather
    /// than a force-unwrap because that construction is a *generator* invariant, and a generator
    /// change that broke it must fail as a named error rather than trap the whole test process.
    case originNotLiving

    /// The TEXT row's own send door refused, or minted something other than exactly one item
    /// (P6 item 9, stage 0).
    ///
    /// Carries the outcome rather than a `Bool`, because the whole point of minting through
    /// `sendTempMessage(_:)` is that a run whose addressing never converged answers
    /// `.refused(.destinationNotAddressable)` **by name** — item 1's residual turned into a failure
    /// instead of a silence. A cell that could not mint must say which refusal it got.
    case textNotStaged(MeshTextSendOutcome)

    /// The HEART row's own send door staged nothing, or more than one item (P6 item 9).
    ///
    /// Carries no outcome, unlike its text sibling: `sendSessionHeart(to:)` answers `Void` and
    /// reports through `sessionHeartState`, so the honest thing a cell can say is "no heart reached
    /// the store" — the state itself is item 6's exhaustive space and is asserted there.
    case heartNotStaged

    /// The overlay named a heart recipient that is not a living member of the built run.
    ///
    /// Unreachable by construction — field 13 draws over `survivors ∖ {heartOrigin}` — and a thrown
    /// error rather than a force-unwrap for ``originNotLiving``'s reason: a generator change that
    /// broke it must fail as a named error rather than trap the whole test process.
    case heartRecipientMissing
}

// MARK: - The routed seam on the convergence run

@MainActor
extension MeshConvergenceRun {

    /// How many extra commit-and-settle rounds the routed assertions may wait for.
    ///
    /// The drain is exchange-driven — an answer truncated at its per-answer bound leaves the
    /// remainder for the NEXT exchange with that peer, and exchanges happen only as a link opens —
    /// so a bounded number of further rounds is the honest shape of "it converges", not a retry loop
    /// hiding a hang. Bounded (R2), with an early exit the moment the origin owes nobody.
    static var routedDrainRounds: Int { MeshScheduleBounds.maxCommitRounds + 2 }

    /// **One call into the drain's seam**: the member mints a routed item for the full roster minus
    /// itself and stages it into its own routed store, exactly as an origin does.
    ///
    /// - Returns: the item's signed pair, which every routed assertion is written against.
    func routedCustodyEvent(
        at member: MeshConvergenceMember, chunks: Int, now: Date,
        typeToken: String = MeshRoutedTypeToken.photo
    ) throws -> MeshRoutedItemKey {
        let identity = member.node.manager.identityForTesting
        guard let roster = member.node.manager.membershipVerifier?.roster else {
            throw MeshMergeTestFailure.rosterTooSmall
        }
        let payload = MeshRoutedCustodyFixtures.blob(
            byteCount: MeshRoutedCustodyFixtures.blobByteCount(
                for: typeToken,
                requested: MeshChunkFormat.maxChunkPayloadBytes * (chunks - 1) + 1_000
            )
        )
        // The target's SHAPE follows the type's registered column (P6 item 6): the heart row is
        // `.singleRecipient`, and a full-roster target for it is refused by the mint's own shape
        // guard on any roster of three or more. Read from the registry rather than branched on the
        // token, so a fourth type needs no edit here.
        let contentID = UUID()
        let target: MeshDeliveryTarget
        if MeshRoutedTypeRegistry.increment1.entry(for: typeToken)?.destinations == .singleRecipient {
            // The recipient must be a SURVIVOR, not merely a roster row: on a partition shape the
            // lowest-sorting roster member may be one the schedule removed, and a single-recipient
            // item addressed to it has exactly one destination that is `departed` — so the item
            // closes with nobody outstanding and nobody holding custody, and a stage claim about it
            // asserts nothing. A full-roster item hid this by always having a living destination
            // too (item 9's design check, R3, met here first).
            let living = Set(livingMembers.map(\.fingerprint))
            let recipient = try #require(
                roster.memberFingerprints.first {
                    $0 != identity.localFingerprint && living.contains($0)
                },
                "a single-recipient mint needs one other LIVING member"
            )
            guard case .updated(let subset) = MeshDeliveryTarget.addressing(
                contentID: contentID, recipient: recipient, roster: roster,
                selfFingerprint: identity.localFingerprint
            ) else { throw MeshMergeTestFailure.rosterTooSmall }
            target = subset
        } else {
            target = MeshDeliveryTarget(
                contentID: contentID, roster: roster, selfFingerprint: identity.localFingerprint
            )
        }
        let manifest = try MeshRoutedManifest.signed(
            meshID: meshID,
            target: target,
            typeToken: typeToken,
            contentHash: MeshRoutedContentDigest.contentHash(of: payload),
            size: UInt64(payload.count),
            createdAt: anchor.addingTimeInterval(60),
            hardDeadline: anchor.addingTimeInterval(MeshSessionCeiling.ceilingSeconds),
            contentKey: Data(repeating: 0x51, count: 32),
            recipientKeys: Dictionary(uniqueKeysWithValues: members.map {
                ($0.fingerprint, $0.node.manager.identityForTesting.localKeyAgreementPublicKey)
            }),
            identity: identity
        )
        let store = MeshRoutedStore(scope: member.node.store.meshRoutedStorage)
        try DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            #expect(store.admittingManifest(manifest, now: now).value != nil)
            // R2: bounded by the item's own chunk count.
            for chunk in try MeshChunker.chunks(of: payload, for: manifest, identity: identity) {
                #expect(store.stagingChunk(chunk, now: now).value != nil)
            }
        }
        return MeshRoutedItemKey(manifest)
    }

    /// **P5 item 13's seam into the battery**: one member mints a REAL sealed photo item — framed
    /// body, item seal, signed manifest, chunks — and stages it into its own routed store.
    ///
    /// Deliberately not ``routedCustodyEvent(at:chunks:now:typeToken:)``: that stages an opaque
    /// fixture blob, which every rung above the plaintext seam is happy with and no delivery
    /// projection can open. A convergence claim about the WALL needs bytes a receiver can really
    /// decrypt.
    ///
    /// - Parameters:
    ///   - member: The origin.
    ///   - now: The injected instant the two store doors are charged at.
    /// - Returns: the item's signed pair.
    func routedSealedPhotoEvent(
        at member: MeshConvergenceMember, now: Date
    ) throws -> MeshRoutedItemKey {
        let identity = member.node.manager.identityForTesting
        guard let roster = member.node.manager.membershipVerifier?.roster else {
            throw MeshMergeTestFailure.rosterTooSmall
        }
        let item = try MeshRoutedPhotoFixtures.item(
            meshID: meshID,
            roster: roster,
            signer: identity,
            recipientKeys: Dictionary(uniqueKeysWithValues: members.map {
                ($0.fingerprint, $0.node.manager.identityForTesting.localKeyAgreementPublicKey)
            }),
            createdAt: anchor.addingTimeInterval(60),
            hardDeadline: anchor.addingTimeInterval(MeshSessionCeiling.ceilingSeconds)
        )
        let store = MeshRoutedStore(scope: member.node.store.meshRoutedStorage)
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            #expect(store.admittingManifest(item.manifest, now: now).value != nil)
            // R2: bounded by the item's own chunk count.
            for chunk in item.chunks {
                #expect(store.stagingChunk(chunk, now: now).value != nil)
            }
        }
        return MeshRoutedItemKey(item.manifest)
    }

    /// Opens every living member's access gate, which is what a device that is unlocked and
    /// foregrounded looks like — and the precondition for any plaintext claim at all.
    func openEveryRoutedGate(now: Date) {
        // R2: bounded by the roster cap.
        for member in livingMembers {
            DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
                member.node.manager.applyRoutedAccessGate(
                    MeshRoutedAccessGate(
                        protectedDataAvailable: true, appIsForeground: true, duressActive: false
                    ),
                    now: now
                )
            }
        }
    }

    /// **P5 item 11's seam into the battery**: one receiver's registry stops knowing `token`.
    ///
    /// The forwarding gates are unreachable in one shipping build — nothing carrying an unregistered
    /// token can be admitted anywhere — so a narrowed registry at ONE member is the only way a cell
    /// can drive "unknown types are refused, not forwarded" inside a converging run.
    func routedUnknownTypeEvent(at member: MeshConvergenceMember, dropping token: String) {
        member.node.manager.routedTypeRegistryForTesting =
            MeshRoutedTypeRegistryFixtures.narrowed(dropping: token)
    }

    /// **P5 item 8's seam into the battery**: one member develops, on an injected clock, with no
    /// randomness of its own.
    ///
    /// Deliberately **not** a new `MeshScheduleEvent` case (D-14.1, this file's header): the
    /// schedule already carries `departure`; this is the routed half of what one costs.
    ///
    /// - Returns: what the development's custody transfer actually did.
    @discardableResult
    func routedDevelopmentEvent(
        at member: MeshConvergenceMember, now: Date
    ) async -> MeshCustodyHandoffResult {
        let clock = MeshTerminationFixtures.SteppedClock(
            [now, now.addingTimeInterval(3), now.addingTimeInterval(3)]
        )
        await DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            await member.node.manager.leaveSessionAfterNotifyingPeers(clock: { clock.next() })
        }
        return member.node.manager.lastDevelopmentHandoff ?? .none
    }

    /// Drains `key` inside the ORIGIN's own branch only — the shape a development actually needs.
    ///
    /// The branch partner ends up holding the ciphertext and the origin holding its signed custody
    /// receipt, while every destination on the far side of the split is still `pending`. Draining
    /// the **whole** mesh first is what makes a development vacuous: with nothing outstanding the
    /// transfer has no candidates at all, and every hand-off assertion then holds with the entire
    /// mechanism removed.
    ///
    /// Bounded (R2), with an early exit the moment the origin holds a custody receipt.
    func runBranchDrainRounds(origin: MeshConvergenceMember, key: MeshRoutedItemKey) async throws {
        let branch = livingMembers.filter { $0.branch == origin.branch }
        // R2: a hard constant ceiling.
        for _ in 0..<Self.routedDrainRounds {
            if routedIndex(of: origin)?.record(for: key)?.receipts.isEmpty == false { return }
            DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
                // R2: bounded by the branch size, squared.
                for (position, near) in branch.enumerated() {
                    for far in branch.dropFirst(position + 1) {
                        near.node.manager.applySessionEvent(
                            .peerCommitted, committedPeer: far.fingerprint
                        )
                        far.node.manager.applySessionEvent(
                            .peerCommitted, committedPeer: near.fingerprint
                        )
                    }
                }
            }
            try await MeshDepartureRig.settle(branch.map(\.node), on: fabric)
        }
    }

    /// One living member's routed index, or nil for every non-`.loaded` state.
    func routedIndex(of member: MeshConvergenceMember) -> MeshRoutedIndex? {
        guard case .loaded(let index, _) = routedLoadState(of: member) else { return nil }
        return index
    }

    /// One member's **five-state** routed load — the reading ``routedIndex(of:)`` collapses to nil.
    ///
    /// `.deferred` and `.refused` are not "empty" and are never treated as such (plan §3.7 and
    /// §19.5's fifth wrinkle): the first is a device before its first post-boot unlock, the second is
    /// a seal this device refused to write. Discriminating them is I-6's whole subject.
    func routedLoadState(
        of member: MeshConvergenceMember, binding: DeviceBindingID.TestOverride? = nil
    ) -> MeshRoutedLoad {
        DeviceBindingID.$testOverride.withValue(binding ?? .identifier(MeshP3Acceptance.install)) {
            MeshRoutedStore(scope: member.node.store.meshRoutedStorage).load()
        }
    }

    /// Whether one member's **own** access gate is really shut — the manager state a locked window
    /// is, read at the device rather than forced by the reader.
    ///
    /// D-14.5's `routedLoadState(of:binding: .readError)` reading is **gone** (D-14.9): it applied
    /// the read error itself, so it asked "does this store defer when I force a binding error?" —
    /// a property of the override, not of the window. `MeshRoutedStore.load()` consults
    /// `DeviceBindingID` only after the index file is read, so under `.readError` it answers
    /// `.deferred` for any member whose index exists whether or not the drain ran deferred, and the
    /// regression it was written to catch (item 10's `binding`-as-parameter discipline regressing to
    /// a wrapper) left it answering true.
    func routedWindowIsShut(_ member: MeshConvergenceMember) -> Bool {
        let gate = member.node.manager.routedAccessGate
        return !gate.permits(.decryptContent) && !gate.permits(.mutateCanonicalStore)
    }

    /// The two facts that make a lock window's "nothing moved" claim mean something.
    ///
    /// 1. The member's own gate is **shut** — a manager state read at the device, not a binding the
    ///    reader applied to itself.
    /// 2. The item is still **outstanding at the origin**, so the pumps that ran inside the window
    ///    had something to move.
    ///
    /// Together with the caller's whole-mesh snapshot equality that is falsifiable by exactly the
    /// regression the old reading could not catch: item 10's `binding`-as-parameter discipline
    /// regressing to a wrapper leaves every store `.loaded` for the commit pumps the routed work
    /// happens in, the drain then delivers the outstanding item, and the snapshots move.
    ///
    /// The `readSuppressed state=deferred:*` audit line is deliberately **not** the witness
    /// (D-14.9). It is written only at the three logging read doors, and the drain's advertise and
    /// answer doors are once-per-peer-per-session, so 9 of the 40 cells legitimately emit none
    /// inside their window — measured, not assumed (`item14/logs/batt5.log`). It is a process-global
    /// signal besides, with no scope, node or item to filter on.
    ///
    /// - Parameters:
    ///   - member: The locked device.
    ///   - origin: The member that minted the item.
    ///   - key: The item the window is meant to be holding still.
    func expectRoutedWindowIsShut(
        at member: MeshConvergenceMember, origin: MeshConvergenceMember, key: MeshRoutedItemKey
    ) {
        #expect(routedWindowIsShut(member),
                "the window's own gate is open, so the deferral it claims is not the state tested")
        #expect(routedOutstanding(at: origin, key: key).isEmpty == false,
                "the window had nothing outstanding, so a loaded drain would have moved nothing")
    }

    /// Every living member's routed store, as bytes on disk — the whole-mesh form of the "nothing
    /// moved" claim, so a window is not judged by the locked device's own directory alone.
    func routedDiskSnapshots() -> [Int: [String: Data]] {
        var snapshots: [Int: [String: Data]] = [:]
        // R2: bounded by the roster cap.
        for member in livingMembers {
            snapshots[member.index] = MeshRoutedStoreFixtures.snapshot(
                member.node.store.meshRoutedStorage
            )
        }
        return snapshots
    }

    /// Whether one member really has no record for `key` any more — the **per-device** corroboration
    /// a process-global drop line is never allowed to stand in for.
    ///
    /// `FernletAuditLog.addCaptureHandler` is a process-wide registry with no scope, node or item
    /// key to filter on, and every converging drain emits `itemDropped reason=delivered`. So the
    /// capture's answer is only ever admitted **together with** this reading, at the device the
    /// claim is about (D-14.10).
    ///
    /// `.reclaimed` is the ordinary shape — item 9's reclaim leaves an empty index behind — and an
    /// `.absent` store is the same fact one step further along. Every other state answers false
    /// deliberately: a `.deferred`, `.refused` or `.corrupt` store cannot say what it holds, and
    /// "cannot say" is never evidence of a drop.
    func routedRecordIsGone(at member: MeshConvergenceMember, key: MeshRoutedItemKey) -> Bool {
        if case .absent = routedLoadState(of: member) { return true }
        return routedDeliveryState(at: member, key: key) == .reclaimed
    }

    /// Whether **every** living member has lost the record — the corroboration for "nobody holds it".
    func routedReclaimedEverywhere(_ key: MeshRoutedItemKey) -> Bool {
        livingMembers.allSatisfy { routedRecordIsGone(at: $0, key: key) }
    }

    /// Whether some surviving copy of the record says `fingerprint` finished — the per-destination
    /// corroboration for a device that holds nothing and is owed nothing.
    func routedDeliveredSomewhere(_ fingerprint: String, key: MeshRoutedItemKey) -> Bool {
        // R2: bounded by the roster cap.
        for member in livingMembers {
            guard let target = routedIndex(of: member)?.record(for: key)?.deliveryTarget else {
                continue
            }
            if target.state(of: fingerprint) == .delivered { return true }
        }
        return false
    }

    /// **One call into item 9's seam**: fills one member's routed store to the byte cap, so the next
    /// admission at that member must refuse.
    ///
    /// One planted descriptor claiming the whole budget — no sealing at all — carrying the schedule's
    /// own expiry, so the hog is live at the run's `now` and the refusal it exists to cause really
    /// happens rather than being swept away first.
    func routedCapacityEvent(at member: MeshConvergenceMember, now: Date) throws {
        let deadline = anchor.addingTimeInterval(MeshSessionCeiling.ceilingSeconds)
        let hog = MeshRoutedStoreFixtures.record(
            chunks: [MeshRoutedStoreFixtures.descriptor(
                index: 0, count: 1, bytes: Int(MeshRoutedStoreFormat.maxContentBytes)
            )],
            expiresAt: MeshRoutedManifest.expiry(afterHardDeadline: deadline)
        )
        try MeshRoutedStoreFixtures.plant(
            MeshRoutedIndex(items: [hog]),
            into: MeshRoutedStore(scope: member.node.store.meshRoutedStorage),
            install: MeshP3Acceptance.install
        )
    }

    /// One member's state for `key` — the deletion-proof reading of "the origin owes nobody".
    ///
    /// P5 item 9's reclaim means a fully delivered item can DISAPPEAR from the origin's own index,
    /// and `outstandingDestinations` answers `[]` for a missing record. A progress claim written
    /// against that predicate alone is therefore satisfied by a deletion, which is exactly what a
    /// property battery must not accept.
    func routedDeliveryState(
        at member: MeshConvergenceMember, key: MeshRoutedItemKey
    ) -> MeshRoutedDeliveryProgressState {
        guard let index = routedIndex(of: member) else { return .outstanding([]) }
        guard index.record(for: key) != nil else { return .reclaimed }
        guard let roster = member.node.manager.membershipVerifier?.roster else {
            return .outstanding([])
        }
        let owed = index.outstandingDestinations(for: key, in: roster)
        return owed.isEmpty ? .closed : .outstanding(owed)
    }

    /// Commits every living pair again and settles, up to ``routedDrainRounds`` times, stopping the
    /// moment the origin's copy is closed **or has been reclaimed**.
    ///
    /// `binding` is a **parameter** (P5 item 10): an inner `withValue` shadows an outer one, so a
    /// caller that wrapped this in `.withValue(.readError)` to drive a locked window would otherwise
    /// find every store `.loaded` for exactly the commit pumps the routed work happens in — the
    /// window would be vacuous and the cell would pass for the wrong reason. It defaults to `nil`
    /// rather than to the install itself because a `@MainActor` static cannot be a default-argument
    /// value — the rig's own `dispatch(_:type:sender:receiver:now:binding:)` resolves it the same way.
    func runRoutedDrainRounds(
        origin: MeshConvergenceMember,
        key: MeshRoutedItemKey,
        binding: DeviceBindingID.TestOverride? = nil
    ) async throws {
        let binding = binding ?? .identifier(MeshP3Acceptance.install)
        // R2: a hard constant ceiling.
        for _ in 0..<Self.routedDrainRounds {
            if routedDeliveryState(at: origin, key: key).isSettled { return }
            let living = livingMembers
            DeviceBindingID.$testOverride.withValue(binding) {
                // R2: bounded by the roster cap, squared.
                for (position, near) in living.enumerated() {
                    for far in living.dropFirst(position + 1) {
                        near.node.manager.applySessionEvent(
                            .peerCommitted, committedPeer: far.fingerprint
                        )
                        far.node.manager.applySessionEvent(
                            .peerCommitted, committedPeer: near.fingerprint
                        )
                    }
                }
            }
            try await MeshDepartureRig.settle(livingNodes, on: fabric, binding: binding)
        }
    }

    /// **P5 item 10's seam into the battery**: a locked window, sampled, then the unlock edge.
    ///
    /// 1. the member's gate is pushed **closed** and the drain runs with every store unreadable
    ///    (`.readError` ⇒ `deferred`, the state a device is in before its first post-boot unlock);
    /// 2. `sample` runs while the window is still shut — the only place the "nothing moved" half can
    ///    honestly be read, and the rig's own "sample right after a synchronous pump" discipline;
    /// 3. the device unlocks: the open gate is pushed under the pinned install binding, which is the
    ///    re-entry's own edge.
    ///
    /// The binding is a **parameter** of the rounds rather than a wrapper around them: an inner
    /// `withValue` shadows an outer one, so wrapping would leave every store `.loaded` for exactly
    /// the commit pumps the routed work happens in, and the window would be vacuous.
    ///
    /// - Parameters:
    ///   - member: The device that locks.
    ///   - key: The item whose progress the window is judged against.
    ///   - now: The injected instant.
    ///   - sample: Read inside the window, before the unlock.
    /// - Returns: what the unlock's re-entry did.
    @discardableResult
    func routedLockWindowEvent(
        at member: MeshConvergenceMember,
        closingAfter key: MeshRoutedItemKey,
        now: Date,
        sampling sample: () -> Void = {}
    ) async throws -> MeshRoutedReentryReport? {
        member.node.manager.applyRoutedAccessGate(.closed, now: now)
        try await runRoutedDrainRounds(origin: member, key: key, binding: .readError)
        sample()
        return DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            member.node.manager.applyRoutedAccessGate(
                MeshRoutedAccessGate(
                    protectedDataAvailable: true, appIsForeground: true, duressActive: false
                ),
                now: now
            )
        }
    }

    /// **P5 item 12's seam into the battery**: one already-delivered routed frame, re-presented.
    ///
    /// Deliberately **not** a new `MeshScheduleEvent` case (D-14.1, this file's header). The frame is
    /// the SENDER's own stored manifest for `key`, re-dispatched through the real envelope
    /// verification and the drain's own door on an injected clock — i.e. a replay of a frame the
    /// receiver has already admitted, which is what an attacker on this link can mount.
    ///
    /// - Returns: whether a frame actually **reached the ingest door**, so a cell can refuse to pass
    ///   vacuously. The committed slot is part of that contract, not an afterthought: a manifest and
    ///   a coordinator are not enough, because `dispatchRoutedPayload` returns at its very first
    ///   guard (`slot?.fingerprint`, `droppedUncommittedSlot`) when the receiver holds no committed
    ///   slot for that coordinator — and a `true` returned over that return is exactly the vacuous
    ///   pass the flag exists to prevent. So the slot is resolved with the manifest, before any
    ///   signing work, and a missing one answers false.
    @discardableResult
    func routedReplayEvent(
        at receiver: MeshConvergenceMember,
        from sender: MeshConvergenceMember,
        frame key: MeshRoutedItemKey,
        captured: MeshRoutedManifest? = nil,
        now: Date
    ) throws -> Bool {
        guard let manifest = captured ?? routedIndex(of: sender)?.record(for: key)?.manifest,
              let coordinator = receiver.node.coordinators[sender.node.handle.endpoint],
              let slot = receiver.node.manager.slots.first(where: { $0.coordinator === coordinator }),
              slot.fingerprint != nil
        else { return false }
        let identity = sender.node.manager.identityForTesting
        let envelope = try FernletIdentityEnvelope.signed(
            identityService: identity, senderDisplayName: "replay",
            recipientFingerprint: receiver.fingerprint,
            payloadType: .meshRoutedManifest, payloadEncryption: .none,
            payloadSummary: PayloadSummary(title: "routed"),
            payload: try JSONEncoder().encode(MeshRoutedManifestPayload(manifest: manifest)),
            createdAt: now
        )
        let plaintext = try envelope.verify(
            identityService: receiver.node.manager.identityForTesting,
            replayCache: receiver.node.replayCache
        )
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            receiver.node.manager.dispatchRoutedPayload(
                .meshRoutedManifest, plaintext: plaintext, decoder: JSONDecoder(),
                slot: slot, now: now
            )
        }
        return true
    }

    /// **I-11's own half, asserted around the event rather than after it.** A replayed frame moves
    /// no byte of the victim's store, no rung and no receipt count.
    ///
    /// The three readings are taken immediately before and immediately after the dispatch, because
    /// nothing later can tell "the replay changed nothing" from "the drain put it back".
    ///
    /// - Returns: whether the frame reached the door, so a caller can refuse to pass vacuously.
    @discardableResult
    func routedReplayChangesNothing(
        at victim: MeshConvergenceMember,
        from sender: MeshConvergenceMember,
        frame key: MeshRoutedItemKey,
        captured: MeshRoutedManifest? = nil,
        now: Date
    ) throws -> Bool {
        let before = MeshRoutedStoreFixtures.snapshot(victim.node.store.meshRoutedStorage)
        let rungs = routedRungSnapshot(key: key)
        let dispatched = try routedReplayEvent(
            at: victim, from: sender, frame: key, captured: captured, now: now
        )
        #expect(dispatched, "the replay never reached the door, so the claim below is vacuous")
        #expect(MeshRoutedStoreFixtures.snapshot(victim.node.store.meshRoutedStorage) == before,
                "a replayed manifest moved a byte of the receiver's sealed store")
        #expect(routedRungSnapshot(key: key) == rungs,
                "a replayed manifest moved a rung or a receipt count")
        return dispatched
    }

    /// The destinations the origin still owes, derived from its own index.
    func routedOutstanding(at origin: MeshConvergenceMember, key: MeshRoutedItemKey) -> [String] {
        guard let index = routedIndex(of: origin),
              let roster = origin.node.manager.membershipVerifier?.roster else { return [] }
        return index.outstandingDestinations(for: key, in: roster)
    }

    /// One living member by fingerprint, or nil.
    func routedMember(fingerprint: String) -> MeshConvergenceMember? {
        members.first { $0.fingerprint == fingerprint }
    }
}

// MARK: - The key-advertisement seams (P6 item 9, STAGE 0)

/// The addressing half of item 9's feature pipeline, landed ahead of the overlay it will serve.
///
/// **Inside this file on purpose.** A new convergence suite would not match
/// `CIGateSelectorBoundaryTests.isMeshBattery`'s `MeshP<n>*AcceptanceTests` shape and would be
/// ungated the day it was written; these are seams on the rig every routed cell already uses, so
/// they ride `MeshRoutedDrainConvergenceTests`' own CI line.
///
/// Nothing here touches `MeshRoutedScheduleOverlay`, adds a `MeshScheduleEvent` case, or draws from
/// any generator, so **neither `MeshP5DeterminismAcceptanceTests` digest can move**.
@MainActor
extension MeshConvergenceRun {

    /// Mints every living member's OWN key advertisement through the **production** door.
    ///
    /// `MeshConvergenceRun` arms its ledgers with `seedMembershipLedgerForTesting`, which bypasses
    /// BOTH doors the shipping self-mint hangs off (`seedFounderAdmission` / `armJoinerLedger`) and
    /// therefore mints nothing at all — P6 item 1's named residual, and still true of the seeding
    /// itself.
    ///
    /// **It is not, however, what makes the set non-empty**, and the item 9 design's expectation
    /// that it was has been measured and corrected: `sendKeyAdvertisements(to:)` runs
    /// `repairOwnKeyAdvertisementIfMissing()` above its batch read, so the heal's own
    /// `.peerCommitted` traffic self-mints every missing row. See
    /// ``MeshRoutedDrainConvergenceTests/withoutTheArmingDoorItemOnesSelfMintRepairStillAddressesTheMesh()``.
    /// This seam earns its place as a **determinism** one: it mints on the injected clock before the
    /// heal, it asserts the arm rather than discovering a half-armed mesh later, and it leaves the
    /// repair's three-attempt session budget unspent for the state the repair actually exists for.
    ///
    /// `#expect(armed)` per member, so an arm-time seal refusal fails loudly rather than leaving a
    /// half-armed mesh that converges to a subset.
    ///
    /// - Parameter now: The injected instant the advertisement is signed at.
    func armKeyAdvertisements(now: Date) {
        // R2: bounded by the roster cap.
        for member in livingMembers {
            let armed = DeviceBindingID.$testOverride.withValue(
                .identifier(MeshP3Acceptance.install)
            ) {
                member.node.manager.armOwnKeyAdvertisementForTesting(now: now)
            }
            #expect(armed, "a living member could not mint or seal its own key advertisement")
        }
    }

    /// Opens the 13+ chat gate at every living member, except one that is deliberately left shut.
    ///
    /// `chatAllowedProvider` is **nil** on a freshly built manager and `isChatAllowed` reads
    /// `provider?() == true`, i.e. fail-closed — so without this call `sendTempMessage(_:)` answers
    /// `.ageGated` at every member and the whole text half is green over nothing.
    ///
    /// - Parameter gated: The member index to leave gated, or nil to open every member.
    func allowChatEverywhere(except gated: Int?) {
        // R2: bounded by the roster cap.
        for member in livingMembers {
            let allowed = member.index != gated
            member.node.manager.chatAllowedProvider = { allowed }
        }
    }

    /// Whether every living member holds a verified advertisement for every OTHER living member.
    ///
    /// **Equality, never `⊇`.** A superset would be satisfied by rows for members that have since
    /// left, and a subset claim is what "green over nothing" looks like the moment the set is empty.
    /// One survivor converges nothing, so a roster of fewer than two is `false` rather than
    /// vacuously true.
    func routedAdvertisementsConverged() -> Bool {
        let living = Set(livingMembers.map(\.fingerprint))
        guard living.count >= 2 else { return false }
        // R2: bounded by the roster cap, squared.
        return livingMembers.allSatisfy { member in
            let set = member.node.manager.keyAdvertisements
            guard set.memberFingerprints == living else { return false }
            return living.allSatisfy { set.keyAgreementPublicKey(for: $0) != nil }
        }
    }

    /// Bounded commit-and-settle rounds until the advertised-key set has converged.
    ///
    /// The same loop shape as ``runRoutedDrainRounds(origin:key:binding:)`` and for the same reason:
    /// item 1 hung `sendKeyAdvertisements(to:)` off the three ask doors plus `readvertiseMergeProof`,
    /// `attemptLedgerAdoption` and `grantAdmission`, all reached from
    /// `applySessionEvent(.peerCommitted)` — and the send is once per (peer, local-set version), with
    /// the version bumping on every fold, so a bounded number of full-mesh commit rounds converges
    /// it. `linkBranches` deliberately raises no `.peerCommitted`, which is why nothing converges
    /// before the heal.
    ///
    /// A bound that turns out too small leaves the caller's own `#expect` to fail loudly, rather
    /// than this quietly returning a half-converged set.
    func runKeyAdvertisementRounds() async throws {
        let binding = DeviceBindingID.TestOverride.identifier(MeshP3Acceptance.install)
        // R2: a hard constant ceiling.
        for _ in 0..<Self.routedDrainRounds {
            if routedAdvertisementsConverged() { return }
            let living = livingMembers
            DeviceBindingID.$testOverride.withValue(binding) {
                // R2: bounded by the roster cap, squared.
                for (position, near) in living.enumerated() {
                    for far in living.dropFirst(position + 1) {
                        near.node.manager.applySessionEvent(
                            .peerCommitted, committedPeer: far.fingerprint
                        )
                        far.node.manager.applySessionEvent(
                            .peerCommitted, committedPeer: near.fingerprint
                        )
                    }
                }
            }
            try await MeshDepartureRig.settle(livingNodes, on: fabric, binding: binding)
        }
    }

    /// The frozen text one feature round mints. Distinct per round, so an ordering claim over two
    /// rounds is assertable.
    static func featureText(_ round: Int) -> String { "feature-\(round)" }

    /// What the TEXT row's **own public door** answers for one member — the outcome, unjudged.
    ///
    /// Separate from ``routedTextEvent(at:round:)`` because the negative needs the refusal itself:
    /// a run whose addressing never converged answers `.refused(.destinationNotAddressable)` here,
    /// and that named answer is what makes the arming door load-bearing instead of decorative.
    func sendTextOutcome(at member: MeshConvergenceMember, round: Int) -> MeshTextSendOutcome {
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            member.node.manager.sendTempMessage(Self.featureText(round))
        }
    }

    /// **One call into the TEXT row's own seam** (P6 item 4): the member sends a session message
    /// through the real public API, and the cell refuses to continue on anything but a staged mint.
    ///
    /// The id is read back by diffing the origin's own index rather than returned by a new seam:
    /// `sendTempMessage(_:)` mints its own `UUID`, and a seam that handed it out would be a second
    /// per-type source — exactly what D-13.31 walls.
    ///
    /// - Parameters:
    ///   - member: The origin.
    ///   - round: Which feature round's text to mint.
    /// - Returns: the minted item's key.
    /// - Throws: ``MeshRoutedCellFailure/textNotStaged(_:)`` on any answer but one staged item.
    func routedTextEvent(at member: MeshConvergenceMember, round: Int) throws -> MeshRoutedItemKey {
        let before = Set(routedIndex(of: member)?.items.map(\.key) ?? [])
        let outcome = sendTextOutcome(at: member, round: round)
        guard outcome == .staged else { throw MeshRoutedCellFailure.textNotStaged(outcome) }
        let minted = Set(routedIndex(of: member)?.items.map(\.key) ?? []).subtracting(before)
        guard minted.count == 1, let key = minted.first else {
            throw MeshRoutedCellFailure.textNotStaged(outcome)
        }
        return key
    }
}

// MARK: - MeshRoutedHeartJudgementLog

/// Every routed heart judgement one run's members minted, in order — the per-gift witness item 9's
/// exactly-once invariant is written against (P6 item 9).
///
/// **A run-scoped collector over item 6's own `onHeartJudgedForTesting` seam, not a new field on the
/// manager.** The design proposed a `routedHeartJudgementsForTesting` list on `MeshNetworkManager`;
/// item 6 had already shipped the seam that makes one unnecessary, and a stored list would have been
/// a second persisted-ish surface to bound, clear and wipe for no gain. Nothing here is shipping
/// code, so the memory-lifecycle and wipe walls have nothing to look for.
///
/// The ledger cannot be this witness and neither can the audit capture: `recordReceivedHeart` dedups
/// by gift id, so a ledger asked twice looks exactly like a ledger asked once, and the capture is
/// process-global with no node or item scope (D-14.10 / D-6a.10).
@MainActor
final class MeshRoutedHeartJudgementLog {

    /// The most judgements one run may record before this stops growing.
    ///
    /// A real bound at the append site rather than a claim in a doc comment: a cell's heart is one
    /// gift over at most eight members, so anything approaching this is a defect the count itself
    /// should make visible rather than an allocation to absorb.
    static let maxJudgements = 64

    /// Every ack minted at any member, with the fingerprint of the device that minted it.
    private(set) var judgements: [(member: String, ack: MeshRoutedHeartAck)] = []

    /// How many judgements were dropped at the cap — asserted zero rather than assumed.
    private(set) var dropped = 0

    /// Records one judgement, or counts a drop.
    func record(_ ack: MeshRoutedHeartAck, at member: String) {
        guard judgements.count < Self.maxJudgements else {
            dropped += 1
            return
        }
        judgements.append((member: member, ack: ack))
    }

    /// Every judgement minted **anywhere** for one gift.
    func acks(for giftID: UUID) -> [MeshRoutedHeartAck] {
        judgements.filter { $0.ack.giftID == giftID }.map(\.ack)
    }
}

// MARK: - The feature seams (P6 item 9)

/// The heart half of item 9's feature pipeline, the drain round its two rows share, and the reads
/// rectangle G's invariants are written against.
///
/// **Through the real `sendSessionHeart(to:)`, never a fixture mint.** The design named a
/// `MeshRoutedHeartFixtures` item built on `MeshDeliveryTarget.addressing(…)` because at design time
/// neither existed (its own check said so, O7); item 6 shipped the whole sender instead, and its
/// five gates are six lines of rig state — the same six `MeshFoundingRig`'s heart seams set. Going
/// through the shipping door is strictly stronger: it runs `originateRoutedItem` →
/// `routedDestinationKeys`, the resolver the arming converges, so a heart on a mesh whose
/// advertisements never converged refuses BY NAME here exactly as a text does, and the exactly-once
/// claim is then about the real ceremony rather than about a fixture's chunks.
@MainActor
extension MeshConvergenceRun {

    /// Arms both ends of one heart: the opt-in, an isolated ledger each, and the mutual trust-vault
    /// rows a mesh heart's eligibility gate reads.
    ///
    /// **The vault rows are SEEDED, and that is the thing to be honest about** — the same honesty
    /// item 6's ceremony suite carries in its own header. A vault row appears when
    /// `pendingFriendReview` completes, which fires at session END, so inside the session that
    /// produced a heart it cannot exist. This stands in for a second session and proves nothing
    /// about the first; item 10's two-session Lane C script is the only honest proof of the feature.
    ///
    /// The ledgers are per node and temp-file backed (the shared-disk-root flake family), and their
    /// clock is the run's own injected anchor, never the wall clock.
    ///
    /// - Parameters:
    ///   - origin: The member that will send.
    ///   - recipient: Its single destination.
    func armHeartCeremony(at origin: MeshConvergenceMember, to recipient: MeshConvergenceMember) {
        // R2: a fixed two-element list.
        for member in [origin, recipient] {
            member.node.store.setAllowNearbyHearts(true)
            member.node.manager.heartLedger = isolatedHeartLedger()
        }
        origin.node.store.proximityTrustVault.trust(heartPeerIdentity(of: recipient), mode: .friend)
        recipient.node.store.proximityTrustVault.trust(heartPeerIdentity(of: origin), mode: .friend)
    }

    /// A temp-file-backed heart ledger on the run's injected clock.
    func isolatedHeartLedger() -> ProximityHeartLedger {
        let anchor = self.anchor
        return ProximityHeartLedger(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("routed-feature-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent("HeartLedger.json"),
            now: { anchor }
        )
    }

    /// The handshake-shaped identity the trust vault keys its rows on, built from the two fields
    /// the run's own pump hands the manager.
    private func heartPeerIdentity(of member: MeshConvergenceMember) -> ProximityCoordinator.PeerIdentity {
        let identity = member.node.manager.identityForTesting
        return ProximityCoordinator.PeerIdentity(
            id: member.node.handle.id,
            displayName: member.node.label,
            signingPublicKey: identity.localSigningPublicKey,
            keyAgreementPublicKey: identity.localKeyAgreementPublicKey,
            fingerprint: identity.localFingerprint,
            rangingMode: .rssi,
            firstSeenAt: anchor,
            capabilities: ProximityCapability.allCases.map(\.rawValue)
        )
    }

    /// Installs `log` as every member's heart-judgement witness.
    ///
    /// `members`, not `livingMembers`: a device that judged and then departed still judged, and a
    /// witness over survivors alone could not see the judgement it made.
    func installHeartJudgementWitness(_ log: MeshRoutedHeartJudgementLog) {
        // R2: bounded by the roster cap.
        for member in members {
            let fingerprint = member.fingerprint
            member.node.manager.onHeartJudgedForTesting = { [weak log] ack in
                log?.record(ack, at: fingerprint)
            }
        }
    }

    /// **One call into the HEART row's own seam** (P6 item 6): the member sends a session heart to
    /// one recipient through the real public API, and the cell refuses to continue on anything but
    /// a staged mint.
    ///
    /// The id is read back out of the origin's own routed index rather than returned by a new seam,
    /// for `routedTextEvent(at:round:)`'s reason: the door mints its own `UUID` and a seam that
    /// handed it out would be a second per-type source, which is what D-13.31 walls.
    ///
    /// - Parameters:
    ///   - member: The origin.
    ///   - recipient: The single destination.
    /// - Returns: the minted item's key, whose `itemID` **is** the gift id for this type.
    /// - Throws: ``MeshRoutedCellFailure/heartNotStaged`` when no heart reached the store.
    func routedHeartEvent(
        at member: MeshConvergenceMember, to recipient: MeshConvergenceMember
    ) throws -> MeshRoutedItemKey {
        let before = Set(routedHeartKeys(at: member))
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            member.node.manager.sendSessionHeart(to: heartFriendRecord(of: recipient))
        }
        let minted = Set(routedHeartKeys(at: member)).subtracting(before)
        guard minted.count == 1, let key = minted.first else {
            throw MeshRoutedCellFailure.heartNotStaged
        }
        return key
    }

    /// Every heart this member originated itself, by key.
    private func routedHeartKeys(at member: MeshConvergenceMember) -> [MeshRoutedItemKey] {
        let mine = member.fingerprint
        return routedIndex(of: member)?.items.filter {
            $0.key.originFingerprint == mine
                && $0.manifest?.typeToken == MeshRoutedTypeToken.heart
        }.map(\.key) ?? []
    }

    /// The trusted-peer record the heart affordance would hand the sender for `member`.
    private func heartFriendRecord(of member: MeshConvergenceMember) -> ProximityTrustedPeerRecord {
        let identity = member.node.manager.identityForTesting
        return ProximityTrustedPeerRecord(
            displayName: member.node.label,
            fingerprint: identity.localFingerprint,
            signingPublicKey: identity.localSigningPublicKey,
            keyAgreementPublicKey: identity.localKeyAgreementPublicKey,
            mode: .friend,
            firstAcceptedAt: anchor,
            lastSeenAt: anchor
        )
    }

    /// Puts one member's session state where field 15 drew it.
    ///
    /// **`applySessionEvent(.backgrounded)`, never the routed access gate** (the design check's R4).
    /// `MeshRoutedAccessGate.permits(.decryptContent)` reads `appIsForeground`, so pushing a closed
    /// gate would shut that member's TEXT projection too and redden the complement loop §2c depends
    /// on. The only leg that isolates the heart is `sessionState`, whose case is
    /// `.continuingInBackground`; `.peerCommitted` is then a self-edge, so the drain still pumps.
    ///
    /// Honesty, recorded in `MeshP6HonestyAcceptanceTests` as well as here: **nothing in shipping
    /// raises `.backgrounded` or `.foregrounded`** — the predicate's own source calls the leg inert
    /// until P8 — so the asleep quarter proves the gate's arithmetic, not a reachable product state.
    ///
    /// - Parameters:
    ///   - member: The recipient.
    ///   - foregrounded: Whether it stays `.activeForeground`.
    func setHeartRecipientForegrounded(_ member: MeshConvergenceMember, _ foregrounded: Bool) {
        guard !foregrounded else { return }
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            member.node.manager.applySessionEvent(.backgrounded)
        }
    }

    /// Raises the recipient back to the foreground — the re-entry half of the asleep quarter.
    func foregroundHeartRecipient(_ member: MeshConvergenceMember) {
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            member.node.manager.applySessionEvent(.foregrounded)
        }
    }

    /// The heart-ledger rows one member holds for a gift — the ledger's own dedup, read at the
    /// device that holds it.
    func heartLedgerRows(at member: MeshConvergenceMember, giftID: UUID) -> [ReceivedHeartRecord] {
        member.node.manager.heartLedger?.receivedHearts.filter { $0.id == giftID } ?? []
    }

    /// One bounded full-mesh round for the feature window: every pair commits, then the fabric
    /// settles, exactly as ``runKeyAdvertisementRounds()`` does.
    ///
    /// Separate from ``runRoutedDrainRounds(origin:key:binding:)`` because the window carries TWO
    /// keys with two different origins, so there is no single "is the origin settled?" exit.
    func runFeatureDrainRound() async throws {
        let binding = DeviceBindingID.TestOverride.identifier(MeshP3Acceptance.install)
        let living = livingMembers
        DeviceBindingID.$testOverride.withValue(binding) {
            // R2: bounded by the roster cap, squared.
            for (position, near) in living.enumerated() {
                for far in living.dropFirst(position + 1) {
                    near.node.manager.applySessionEvent(.peerCommitted, committedPeer: far.fingerprint)
                    far.node.manager.applySessionEvent(.peerCommitted, committedPeer: near.fingerprint)
                }
            }
        }
        try await MeshDepartureRig.settle(livingNodes, on: fabric, binding: binding)
    }

    /// Asserts the advertised-key set really converged before anything is minted against it.
    func expectAdvertisementsConverged() {
        #expect(livingMembers.count >= 2, "one survivor converges nothing")
        #expect(routedAdvertisementsConverged(), """
            the advertised-key set never converged, so every feature mint below it would be \
            unaddressable and every claim about them green over nothing
            """)
    }
}

// MARK: - The rung ladder and the byte reader

@MainActor
extension MeshConvergenceRun {

    /// Every living member's per-destination rung for `key`, plus its two receipt counts.
    ///
    /// The unit I-8 compares across the final drain and I-11 compares across a replay. Ranks rather
    /// than states, because ``MeshDeliveryState/later(_:_:)`` is a lexicographic **tiebreak at equal
    /// rank**, not a ≥ test: it answers `lhs` when both are `.custodied` and the left fingerprint
    /// sorts first, so a legal custody transfer from custodian A to B with A < B would report a
    /// regression that did not happen. ``MeshDeliveryState/rank`` is the comparator the ladder has.
    func routedRungSnapshot(key: MeshRoutedItemKey) -> MeshRoutedRungSnapshot {
        var rungs: [String: [String: Int]] = [:]
        var receipts: [String: Int] = [:]
        // R2: bounded by the roster cap.
        for member in livingMembers {
            guard let record = routedIndex(of: member)?.record(for: key) else { continue }
            receipts[member.fingerprint] = record.receipts.count + record.recipientReceipts.count
            guard let target = record.deliveryTarget else { continue }
            var mine: [String: Int] = [:]
            // R2: bounded by the roster cap.
            for destination in target.destinations {
                mine[destination] = target.state(of: destination)?.rank ?? 0
            }
            rungs[member.fingerprint] = mine
        }
        return MeshRoutedRungSnapshot(
            rungs: rungs, receiptCounts: receipts, inventoryStamps: routedInventoryStamps()
        )
    }

    /// Every living member's last recorded `inventorySentAt`, per peer — **I-13's unit** (P6 item 7).
    ///
    /// Folded into ``MeshRoutedRungSnapshot`` rather than handed to `routedInvariants` as a second
    /// `before:` parameter: that signature is called by 40+ cells, and a claim is not worth a
    /// parameter at every one of them when the value it needs is already sampled at exactly the
    /// right two moments.
    ///
    /// Read-only, through `peerRoutedInventories` (`@ObservationIgnored private(set)` at internal
    /// access). A peer with no stamp yet is **absent** rather than present-and-nil, so a member that
    /// exchanged no digest contributes nothing and the claim has nothing to compare — which is why
    /// the non-vacuity guard lives with the sample (see
    /// ``MeshRoutedDrainConvergenceTests/theRungSnapshotReallySamplesAnInventoryStamp()``) and not
    /// inside the shared claim, where it would redden every cell that legitimately exchanges none.
    func routedInventoryStamps() -> [String: [String: Date]] {
        var stamps: [String: [String: Date]] = [:]
        // R2: bounded by the roster cap.
        for member in livingMembers {
            var mine: [String: Date] = [:]
            // R2: bounded by the roster cap.
            for (peer, state) in member.node.manager.peerRoutedInventories {
                guard let sentAt = state.inventorySentAt else { continue }
                mine[peer] = sentAt
            }
            if !mine.isEmpty { stamps[member.fingerprint] = mine }
        }
        return stamps
    }

    /// The routed ladder projected onto **member indices** rather than fingerprints — the value two
    /// runs of one cell are compared by.
    ///
    /// Fingerprints come out of freshly provisioned signing keys and item ids are minted per run, so
    /// a digest carrying either would differ between two runs of the same schedule for reasons that
    /// are not the schedule's. Projecting through the run's own indices is what makes a replay
    /// comparison mean anything, exactly as `MeshConvergenceDigest` does for the membership half.
    func routedDigest(key: MeshRoutedItemKey) -> [String] {
        let snapshot = routedRungSnapshot(key: key)
        var lines: [String] = []
        // R2: bounded by the roster cap, squared.
        for (member, rungs) in snapshot.rungs {
            guard let holder = routedMember(fingerprint: member)?.index else { continue }
            for (destination, rank) in rungs {
                guard let target = routedMember(fingerprint: destination)?.index else { continue }
                lines.append("\(holder)>\(target)=\(rank)")
            }
        }
        // R2: bounded by the roster cap.
        for (member, count) in snapshot.receiptCounts {
            guard let holder = routedMember(fingerprint: member)?.index else { continue }
            lines.append("\(holder)#\(count)")
        }
        return lines.sorted()
    }

    /// The item's plaintext ciphertext blob, reassembled from ONE member's own sealed chunk files
    /// and measured against the manifest's `contentHash` — or nil when this device cannot produce it.
    ///
    /// Every step is the shipping one: the store's own seal key (``MeshRoutedStore/openKey()``), its
    /// own per-slot descriptor comparison (``MeshRoutedStore/readChunkFile(expecting:contentKey:)`` —
    /// the `aad` carries no file name, so that comparison is what binds a file to a slot), and
    /// ``MeshChunkAssembly/completion(against:)``, which re-derives the whole-item hash. A chunk
    /// written into the wrong slot, a truncated assembly or a rung minted before the bytes landed all
    /// answer nil here.
    func routedAssembledBlob(at member: MeshConvergenceMember, key: MeshRoutedItemKey) -> Data? {
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            let store = MeshRoutedStore(scope: member.node.store.meshRoutedStorage)
            guard case .loaded(let index, _) = store.load(),
                  let record = index.record(for: key), let manifest = record.manifest,
                  case .available(let contentKey) = store.openKey(),
                  var assembly = MeshChunkAssembly.forManifest(manifest) else { return nil }
            // R2: bounded by the item's own chunk count, itself bounded by `maxChunksPerItem`.
            for stored in record.chunks {
                guard case .chunk(let chunk) = store.readChunkFile(
                    expecting: stored, contentKey: contentKey
                ) else { return nil }
                guard case .admitted = assembly.admit(chunk) else { return nil }
            }
            guard case .complete(let blob) = assembly.completion(against: manifest) else { return nil }
            return blob
        }
    }
}

// MARK: - MeshConvergenceRun: the twelve routed invariants

@MainActor
extension MeshConvergenceRun {

    /// The routed half of §16.2's invariants, over the same survivors — **thirteen named claims
    /// behind one entry point**, so a departure-free cell cannot assert five of them vacuously.
    ///
    /// The thirteenth is P6 item 7's: `inventorySentAt` never moves backwards, at any member, for
    /// any peer. It reads the same rule the door applies (`MeshRoutedInventoryStampRule`), and its
    /// non-vacuity is asserted once beside the sample rather than here — see
    /// ``routedInventoryStamps()``.
    ///
    /// There is deliberately no relaxed variant (item 7 deleted P4's `checkExceptTheHealsRotationCause`
    /// and item 14 does not reintroduce the shape): a cell that cannot pass is deferred by name with a
    /// written note, or it is fixed.
    ///
    /// - Parameters:
    ///   - origin: The member that minted the item.
    ///   - key: The item.
    ///   - capture: The run's audit capture. Every "the record is gone" arm is read **through** it: a
    ///     missing record is otherwise indistinguishable from one that was never written, so an
    ///     un-corroborated `.reclaimed` would satisfy "nothing lost" for any deletion at all.
    ///   - overlay: What this cell PLANTED — the only thing allowed to excuse an outstanding leg.
    ///   - before: The rung ladder sampled after the heal, which I-8 compares the final one against.
    ///   - judged: The **audience** — the destination fingerprints the roster-wide claims may be
    ///     written against, or nil for "every living member but the origin", which is what a
    ///     `.fullRosterAtCreation` item means. See ``routedJudgedAudience(_:key:)``.
    func routedInvariants(
        _ origin: MeshConvergenceMember,
        _ key: MeshRoutedItemKey,
        audited capture: MeshRoutedBackpressureAuditCapture,
        overlay: MeshRoutedScheduleOverlay,
        before: MeshRoutedRungSnapshot,
        judged: Set<String>? = nil
    ) {
        let audited = capture.values(of: "mesh.routedStore.itemDropped", key: "reason")
            .contains("delivered")
        let audience = judged ?? Set(
            livingMembers.filter { $0.index != origin.index }.map(\.fingerprint)
        )
        routedProgressByName(origin, key, overlay: overlay, audited: audited)
        routedNothingLost(origin, key, audited: audited, judged: audience)
        routedBytesRecoverable(origin, key, audited: audited)
        routedNoDoubleCountedReceipt(origin, key)
        routedLoadStatesAreDistinct(origin, key, overlay: overlay, audited: audited)
        routedHandoffBound(origin: origin, key: key, developing: false)
        routedRungMonotone(
            origin, key, before: before, audited: audited,
            blocked: routedEveryDestinationIsPlanted(
                origin, overlay: overlay, judged: audience, token: routedTypeToken(origin, key)
            )
        )
        routedCapacityHoldVisible(overlay: overlay)
        routedReplayWindowStaysInsideItsBounds(overlay: overlay)
        routedMergeClosureNamed()
        routedInventoryStampMonotone(before: before)
    }

    /// The audience a **one-destination** item's roster-wide claims must be narrowed to (P6 item 9,
    /// the design check's R3).
    ///
    /// Item 6 flipped the heart row to `.singleRecipient`, and three of the claims above are
    /// `.fullRosterAtCreation`-shaped. The trap `routedDeliveryState` sets is that it answers
    /// **`.reclaimed` for "the index loads and holds no record for this key"** — which is precisely
    /// a device that was never a destination. So I-2's third disjunct is satisfied at every
    /// non-recipient for exactly the wrong reason, and I-8's `blocked` leg, computed over
    /// `livingMembers`, asks whether every LIVING member was planted rather than every destination.
    ///
    /// Read off the record's own signed delivery target rather than from a parameter the caller
    /// composes, intersected with the living: a destination that departed is judged by I-1's
    /// `.departed` arm, not by a claim about what it still holds. Answers nil — meaning "judge
    /// everybody", the pre-P6 reading — when the origin no longer holds a record, because item 9's
    /// reclaim legitimately takes it away and a narrowed audience derived from nothing would be
    /// narrower than the truth.
    ///
    /// - Parameters:
    ///   - origin: The member that minted the item.
    ///   - key: The item.
    /// - Returns: the living destinations, or nil.
    func routedJudgedAudience(
        _ origin: MeshConvergenceMember, key: MeshRoutedItemKey
    ) -> Set<String>? {
        let witness = routedIndex(of: origin)?.record(for: key)?.deliveryTarget
            ?? livingMembers.compactMap { routedIndex(of: $0)?.record(for: key)?.deliveryTarget }.first
        guard let target = witness else { return nil }
        let living = Set(livingMembers.map(\.fingerprint))
        return Set(target.destinations).intersection(living)
    }

    /// **I-13 — a peer's recorded `inventorySentAt` never moves backwards** (P6 item 7).
    ///
    /// One pair at a time, over the pairs present in BOTH samples. A pair that vanished is not a
    /// regression and needs no excuse: `clearRoutedDrainState()` empties the whole per-peer map at
    /// a session end, which is a legal thing for a departing member to have done between the two
    /// samples, and the map carries no per-item fact that could be lost with it.
    ///
    /// Equality is admitted, exactly as the door admits it: a peer's own digest re-arriving
    /// byte-identical re-records the same stamp, and the claim is monotonicity, not progress — and
    /// "exactly as the door admits it" is now literal rather than a promise (P6 item 7 fix review,
    /// P2-1). The claim CALLS `MeshRoutedInventoryStampRule`, the same pure decision
    /// `routedInventoryStampIsStale(_:from:)` applies, so a tolerance or a flipped arm added to the
    /// rule reddens here instead of leaving the battery asserting a second, hand-spelled `>=` that
    /// the shipping door no longer means.
    private func routedInventoryStampMonotone(before: MeshRoutedRungSnapshot) {
        let after = routedInventoryStamps()
        // R2: bounded by the roster cap, squared.
        for (member, stamps) in before.inventoryStamps {
            for (peer, stamp) in stamps {
                guard let later = after[member]?[peer] else { continue }
                let verdict = MeshRoutedInventoryStampRule.verdict(inbound: later, recorded: stamp)
                #expect(verdict == .admit,
                        "a peer's recorded inventory stamp moved backwards down the drain")
            }
        }
    }

    /// **I-1 — progress by name, per destination.** Every destination ends `delivered`, or departed
    /// with a signed record behind it, or outstanding at a member **this cell itself planted**.
    ///
    /// Read through `MeshDeliveryTarget.dispositions(in:)` and never through the emptiness of
    /// `outstanding(in:)`, which a deletion satisfies. The excuse is corroborated at THAT
    /// destination's own manager — `lastRoutedDrainRefusal` and `routedDeliveryHold` are single,
    /// item-agnostic, last-write-wins values, and the capacity note is written on the device that
    /// refused the frame rather than on the origin, so one refusal anywhere would otherwise license
    /// every outstanding leg in the cell.
    private func routedProgressByName(
        _ origin: MeshConvergenceMember, _ key: MeshRoutedItemKey,
        overlay: MeshRoutedScheduleOverlay, audited: Bool
    ) {
        guard let roster = origin.node.manager.membershipVerifier?.roster else {
            Issue.record("the origin has no derived roster, so no destination can be judged")
            return
        }
        guard let record = routedIndex(of: origin)?.record(for: key),
              let target = record.deliveryTarget else {
            #expect(audited && routedRecordIsGone(at: origin, key: key),
                    "the origin's own record vanished with no audited reclaim behind it")
            return
        }
        let token = record.manifest?.typeToken ?? MeshRoutedTypeToken.photo
        let planted = routedPlantedFingerprints(overlay)
        var excused: Set<String> = []
        // R2: bounded by the roster cap.
        for (destination, disposition) in target.dispositions(in: roster) {
            switch disposition {
            case .delivered:
                continue
            case .departed:
                #expect(routedDepartureIsSigned(destination, at: origin),
                        "a destination read as departed with no signed record behind it")
            case .pending, .custodied:
                if routedOutstandingIsExcused(destination, overlay: overlay, token: token) {
                    excused.insert(destination)
                } else {
                    Issue.record("a reachable destination never reached delivered: \(destination)")
                }
            }
        }
        #expect(excused.isSubset(of: planted),
                "an outstanding leg was excused at a destination this cell never planted")
    }

    /// The fingerprints this cell's overlay planted a refusal at — the only excusable destinations.
    ///
    /// An **upper bound**, never a claim: `excused.isSubset(of: planted)` is the only reader, so a
    /// fingerprint that is never actually excused is inert. That is why P6 item 9's deferred heart
    /// recipient joins the set unconditionally rather than behind the token test that guards the
    /// excuse itself.
    private func routedPlantedFingerprints(_ overlay: MeshRoutedScheduleOverlay) -> Set<String> {
        var planted: Set<String> = []
        if let index = overlay.capacityMember, let member = participant(global: index) {
            planted.insert(member.fingerprint)
        }
        if let index = overlay.unknownTypeMember, let member = participant(global: index) {
            planted.insert(member.fingerprint)
        }
        if let index = overlay.heartDeferredRecipient, let member = participant(global: index) {
            planted.insert(member.fingerprint)
        }
        return planted
    }

    /// Whether this cell planted, at **every** one of its own live destinations, something that
    /// stops a rung moving at all.
    ///
    /// The one shape in which no rung can legally move — a roster-3 cell whose single surviving
    /// destination is the byte-hog, say. I-8's non-vacuity and the replay's own resolution both have
    /// to know it, or a correctly-refusing cell reds for the refusal it was built to drive.
    ///
    /// Over the item's own AUDIENCE since P6 item 9 (R3): a one-destination heart whose single
    /// recipient is the byte-hog is blocked, and a full-roster photo with one hog among seven is not
    /// — a question `livingMembers` alone cannot tell apart.
    ///
    /// **The deferred-heart arm is P6 item 9's, and it is TYPE-SCOPED for rectangle A's sake.** A
    /// backgrounded recipient admits the ciphertext and holds it, but `ackableNow` skips an
    /// unjudgeable heart *before* the allowance is planned — so it files no receipt of any kind, and
    /// the origin's rung for it stays at `.pending` by design (measured: two of rectangle G's twelve
    /// cells, `logs/item9/conv-02.log`). That is the same consequence the two refusals above have,
    /// by a different mechanism, and it is stated rather than folded into their wording. Without the
    /// `token ==` leg a rectangle-A photo cell whose overlay happened to draw a sleeping recipient
    /// would read as blocked and lose I-8's non-vacuity for nothing.
    ///
    /// - Parameters:
    ///   - origin: The member that minted the item.
    ///   - overlay: What this cell planted.
    ///   - judged: The item's own audience.
    ///   - token: The item's signed type token.
    private func routedEveryDestinationIsPlanted(
        _ origin: MeshConvergenceMember, overlay: MeshRoutedScheduleOverlay,
        judged: Set<String>, token: String
    ) -> Bool {
        let destinations = livingMembers.filter {
            $0.index != origin.index && judged.contains($0.fingerprint)
        }
        guard !destinations.isEmpty else { return true }
        return destinations.allSatisfy {
            $0.index == overlay.capacityMember || $0.index == overlay.unknownTypeMember
                || (token == MeshRoutedTypeToken.heart
                    && $0.index == overlay.heartDeferredRecipient)
        }
    }

    /// Whether an outstanding leg is one this cell planted, corroborated at that destination's own
    /// manager: item 9's `storeFull` hold, item 11's registry answering nil for the token, or P6
    /// item 9's deliberately-asleep heart recipient.
    ///
    /// **The heart arm is TYPE-SCOPED, which is what makes it safe for rectangle A.** The photo and
    /// blob items rectangle A judges carry `MeshRoutedTypeToken.photo` (`routedCustodyEvent`'s own
    /// default, and `record.manifest?.typeToken ?? .photo` at the reader), so `token ==` can never
    /// fire there; and it is corroborated at the recipient's own manager by the predicate that
    /// actually deferred it, never by the overlay alone.
    private func routedOutstandingIsExcused(
        _ destination: String, overlay: MeshRoutedScheduleOverlay, token: String
    ) -> Bool {
        guard let member = routedMember(fingerprint: destination) else { return false }
        if overlay.capacityMember == member.index,
           member.node.manager.routedDeliveryHold?.cause == .storeFull { return true }
        if overlay.unknownTypeMember == member.index,
           member.node.manager.routedTypeRegistryForTesting?.entry(for: token) == nil { return true }
        if overlay.heartDeferredRecipient == member.index,
           token == MeshRoutedTypeToken.heart,
           !member.node.manager.mayCommitRoutedHeartLedgerJudgement { return true }
        return false
    }

    /// Whether a departed destination has a signed membership record behind it, read off a manager
    /// that is still alive — invariant 1's "membership changes only via signed records".
    private func routedDepartureIsSigned(_ fingerprint: String, at reader: MeshConvergenceMember) -> Bool {
        guard let ledger = reader.node.manager.membershipVerifier?.ledger else { return false }
        return ledger.departures.memberFingerprints.contains(fingerprint)
            || ledger.removals.memberFingerprints.contains(fingerprint)
    }

    /// **I-2 (no content lost) and I-3 (the rung is real).**
    ///
    /// Every living non-origin member holds the item, is still owed it, or lost it to an **audited**
    /// `reason=delivered` drop. Members whose store reads `.deferred` or `.refused` are excluded **by
    /// state**, never by a nil index: neither is "empty" (plan §3.7, §19.5's fifth wrinkle). And §6.5's
    /// missing half — every custodian the origin's own record names must carry that record itself.
    ///
    /// **Over the item's own AUDIENCE, not the whole roster** (P6 item 9, R3): for a
    /// `.singleRecipient` heart a non-recipient survivor holds nothing and is owed nothing, and its
    /// only escape is the third disjunct — which `routedDeliveryState` grants for free to any device
    /// with no record at all. Judging it there would be the D-14.10 shape this file forbids
    /// everywhere else. `judged` is the whole living roster minus the origin for a full-roster item,
    /// so every pre-P6 cell is byte-identical.
    private func routedNothingLost(
        _ origin: MeshConvergenceMember, _ key: MeshRoutedItemKey, audited: Bool,
        judged: Set<String>
    ) {
        let owed = Set(routedOutstanding(at: origin, key: key))
        let claimed = routedClaimedCustodians(origin, key)
        // R2: bounded by the roster cap.
        for member in livingMembers where member.index != origin.index {
            switch routedLoadState(of: member) {
            case .deferred, .refused: continue
            case .loaded, .absent, .corrupt: break
            }
            let record = routedIndex(of: member)?.record(for: key)
            let holdsSomething = (record?.chunks.isEmpty == false)
            // The third disjunct is P5 item 9's: a PURE COURIER — a custodian that is not a
            // destination — loses its copy at the first exchange after every destination delivered,
            // so it holds nothing and is owed nothing, and both earlier disjuncts are false for a
            // device that did exactly the right thing. It is accepted ONLY together with the audited
            // drop that is the only thing allowed to have produced it.
            let reclaimed = audited && routedDeliveryState(at: member, key: key) == .reclaimed
            if judged.contains(member.fingerprint) {
                #expect(holdsSomething || owed.contains(member.fingerprint) || reclaimed,
                        "a destination neither holds the item nor is still owed it")
            }
            // **Not narrowed by the audience**: a rung can name a pure courier that is nobody's
            // destination, and "a custodian rung was written for a device holding nothing" is a
            // claim about the rung rather than about the audience.
            if claimed.contains(member.fingerprint) {
                #expect(record != nil,
                        "a custodian rung was written for a device whose own index holds nothing")
            }
        }
    }

    /// The custodians the origin's own record claims are holding the item — I-3's subject.
    private func routedClaimedCustodians(
        _ origin: MeshConvergenceMember, _ key: MeshRoutedItemKey
    ) -> Set<String> {
        guard let target = routedIndex(of: origin)?.record(for: key)?.deliveryTarget else { return [] }
        let living = Set(livingMembers.map(\.fingerprint))
        return Set(target.destinations.compactMap { target.state(of: $0)?.custodianFingerprint })
            .intersection(living)
    }

    /// **I-4 — the bytes are recoverable wherever a rung or a receipt claims them.**
    ///
    /// Two populations, not one: every `delivered` destination, **and** every custodian named by a
    /// `MeshCustodyReceipt` on the origin's record (map clause c3 — "no custody receipt exists whose
    /// chunks are not on disk"). Three arms at each, because the ciphertext may legitimately be gone:
    /// assembled-and-matching, projected into the canonical store, or audited-dropped.
    ///
    /// Non-vacuity is **per cell**: at least one member must take the first arm. Where the two
    /// populations are empty — every destination excused by a planted refusal — the origin's own copy
    /// stands in, which is honest rather than trivial: the origin's chunk files must still open, seal
    /// key and per-slot descriptor comparison included.
    ///
    /// The projection arm is **per canonical store since P6 item 9** (R3): it read `meshPhotos`
    /// alone, so a heart legitimately projected into the heart ledger — or a text into the session
    /// transcript — whose ciphertext was then reclaimed fell through to the audited-drop arm and
    /// was judged by a deletion rather than by the projection that justified it.
    private func routedBytesRecoverable(
        _ origin: MeshConvergenceMember, _ key: MeshRoutedItemKey, audited: Bool
    ) {
        let population = routedByteReaders(origin, key)
        guard !population.isEmpty else {
            #expect(audited && routedReclaimedEverywhere(key),
                    "nobody holds the item and no device dropped it, so the bytes simply vanished")
            return
        }
        let token = routedTypeToken(origin, key)
        var assembled = 0
        // R2: bounded by the roster cap.
        for member in population {
            if routedAssembledBlob(at: member, key: key) != nil { assembled += 1; continue }
            if routedProjectedIntoItsStore(at: member, key: key, token: token) { continue }
            switch routedLoadState(of: member) {
            case .deferred, .refused: continue
            case .loaded, .absent, .corrupt: break
            }
            #expect(audited && routedRecordIsGone(at: member, key: key),
                    "a rung or a receipt claims bytes this device can neither produce nor account for")
        }
        #expect(assembled > 0,
                "no member in this cell could reassemble the item from its own sealed chunk files")
    }

    /// The signed type token of `key`, read off whichever living member still holds a manifest for
    /// it, defaulting to the photo token exactly as `routedProgressByName` does.
    private func routedTypeToken(
        _ origin: MeshConvergenceMember, _ key: MeshRoutedItemKey
    ) -> String {
        if let token = routedIndex(of: origin)?.record(for: key)?.manifest?.typeToken { return token }
        let held = livingMembers.compactMap { routedIndex(of: $0)?.record(for: key)?.manifest }
        return held.first?.typeToken ?? MeshRoutedTypeToken.photo
    }

    /// Whether `member` projected this item into **its own type's** canonical store.
    ///
    /// One arm per registered routed type, because "the plaintext is safely somewhere else" is a
    /// different fact for each: a photo is in `meshPhotos`, a heart is a judged gift in the heart
    /// ledger, a text is a row in the session transcript. The control token is reserved and
    /// unregistered, so it has no projection and falls through to the audited-drop arm.
    private func routedProjectedIntoItsStore(
        at member: MeshConvergenceMember, key: MeshRoutedItemKey, token: String
    ) -> Bool {
        switch token {
        case MeshRoutedTypeToken.heart:
            return member.node.manager.heartLedger?.receivedHearts
                .contains { $0.id == key.itemID } == true
        case MeshRoutedTypeToken.tempMessage:
            return member.node.manager.sessionMessages.messages
                .contains { $0.messageID == key.itemID }
        default:
            return member.node.manager.meshPhotos.contains { $0.id == key.itemID }
        }
    }

    /// I-4's two populations — the delivered destinations and the receipted custodians — read off
    /// the first living member that still holds a record for the item.
    ///
    /// **Not the origin's record alone.** Item 9's reclaim drops a fully delivered item at the
    /// origin (a pure custodian for that predicate), so on exactly the cells that converged best the
    /// origin has nothing left to read the two populations out of. Where no record names anybody, the
    /// fallback is every living member that still holds one, which is what keeps the claim about
    /// bytes rather than about bookkeeping.
    private func routedByteReaders(
        _ origin: MeshConvergenceMember, _ key: MeshRoutedItemKey
    ) -> [MeshConvergenceMember] {
        let holders = livingMembers.filter { routedIndex(of: $0)?.record(for: key) != nil }
        let witness = routedIndex(of: origin)?.record(for: key)
            ?? holders.compactMap { routedIndex(of: $0)?.record(for: key) }.first
        guard let record = witness else { return [] }
        var wanted = Set(record.receipts.map(\.custodianFingerprint))
        if let target = record.deliveryTarget {
            // R2: bounded by the roster cap.
            for destination in target.destinations where target.state(of: destination) == .delivered {
                wanted.insert(destination)
            }
        }
        let named = livingMembers.filter { wanted.contains($0.fingerprint) }
        return named.isEmpty ? holders : named
    }

    /// **I-5 — no receipt double-counted.** Per record, per kind, at every living member.
    private func routedNoDoubleCountedReceipt(
        _ origin: MeshConvergenceMember, _ key: MeshRoutedItemKey
    ) {
        // R2: bounded by the roster cap.
        for member in livingMembers {
            guard let record = routedIndex(of: member)?.record(for: key) else { continue }
            let custodians = record.receipts.map(\.custodianFingerprint)
            #expect(Set(custodians).count == custodians.count, "a custody receipt was double-counted")
            let recipients = record.recipientReceipts.map(\.recipientFingerprint)
            #expect(Set(recipients).count == recipients.count, "a recipient receipt was double-counted")
        }
    }

    /// **I-6 — all five load states are distinct, and three of them are not "empty".**
    ///
    /// `.corrupt` is a failure at any living member; `.refused` is one in a cell that planted no seal
    /// refusal; `.deferred` outside a lock window is one too. `.absent` at a living destination the
    /// origin no longer owes is a loss. And at least one member must read `.loaded`, so the
    /// discrimination is exercised rather than assumed.
    private func routedLoadStatesAreDistinct(
        _ origin: MeshConvergenceMember, _ key: MeshRoutedItemKey,
        overlay: MeshRoutedScheduleOverlay, audited: Bool
    ) {
        let owed = Set(routedOutstanding(at: origin, key: key))
        var loaded = 0
        // R2: bounded by the roster cap.
        for member in livingMembers {
            switch routedLoadState(of: member) {
            case .loaded:
                loaded += 1
            case .absent:
                #expect(owed.contains(member.fingerprint) || member.index == origin.index
                        || (audited && routedDeliveredSomewhere(member.fingerprint, key: key)),
                        "a living destination holds nothing, is owed nothing, and lost nothing")
            case .deferred:
                #expect(overlay.lockMember != nil,
                        "a store deferred in a cell that closed no gate — deferred is not empty")
            case .refused:
                Issue.record("a store refused its seal in a cell that planted no refusal")
            case .corrupt:
                Issue.record("a living member's routed store is corrupt")
            }
        }
        #expect(loaded > 0, "no living member's routed store could be read at all")
    }

    /// **I-7 (the hand-off bound) and I-9 (the hop bound), run on EVERY cell.**
    ///
    /// A courier rung is `custodied(by: c)` for a destination `d` where `c != d`: self-custody at a
    /// destination is the ordinary drain, a third party holding it is increment 2's live relay, which
    /// increment 1 does not ship. So on a non-developing cell **no** such rung may exist, and on a
    /// developing one every courier must be named by the leaver's own plan **and** be a device the
    /// origin served the manifest to directly (§4.2a).
    ///
    /// - Parameter developing: Whether this cell ran a development. `false` asserts the zero case as
    ///   a **bound** (`0 ≤ held`), so a non-developing cell asserts it non-vacuously.
    func routedHandoffBound(
        origin: MeshConvergenceMember, key: MeshRoutedItemKey, developing: Bool
    ) {
        let handoff = origin.node.manager.lastDevelopmentHandoff ?? .none
        let named = Set(origin.node.manager.lastDevelopmentPlan?.handoffTargets ?? [])
        let held = routedIndex(of: origin)?.items.count ?? 0
        if developing {
            #expect(handoff.transferredItemCount == 1,
                    "the development transferred nothing, so every claim below would be vacuous")
        }
        #expect(handoff.transferredItemCount <= held,
                "a hand-off counted more items than the leaver actually holds")
        let couriers = routedCourierFingerprints(key)
        // R2: bounded by the roster cap.
        for courier in couriers {
            #expect(named.contains(courier),
                    "a courier the leaver's own departure record never named")
            #expect(routedMember(fingerprint: courier)?.node.manager
                    .originServedItemsForTesting.contains(key) == true,
                    "a courier the origin never served the manifest to — that is a second hop")
        }
        if developing {
            #expect(couriers.isEmpty == false,
                    "no survivor carries a courier rung at all, so the subset claims proved nothing")
        } else {
            #expect(couriers.isEmpty,
                    "a third-party courier rung exists with the origin still alive (increment 2)")
        }
    }

    /// Every third-party custodian named anywhere for `key`: `custodied(by: c)` at a destination
    /// `d != c`. Self-custody at a destination is the ordinary drain and is not a hop.
    private func routedCourierFingerprints(_ key: MeshRoutedItemKey) -> Set<String> {
        var couriers: Set<String> = []
        // R2: bounded by the roster cap.
        for member in members {
            guard let target = routedIndex(of: member)?.record(for: key)?.deliveryTarget else {
                continue
            }
            // R2: bounded by the roster cap.
            for destination in target.destinations {
                guard let custodian = target.state(of: destination)?.custodianFingerprint,
                      custodian != destination else { continue }
                couriers.insert(custodian)
            }
        }
        return couriers
    }

    /// **I-8 — no rung regression, on the ladder itself.**
    ///
    /// Every (member, destination) pair present in both samples must not fall, `delivered` is
    /// terminal, and a pair that vanished needs I-2's audited drop behind it. Non-vacuity: at least
    /// one sampled pair must already be off `.pending`, or the check is comparing bottoms.
    private func routedRungMonotone(
        _ origin: MeshConvergenceMember, _ key: MeshRoutedItemKey,
        before: MeshRoutedRungSnapshot, audited: Bool, blocked: Bool
    ) {
        let after = routedRungSnapshot(key: key)
        var offPending = 0
        // R2: bounded by the roster cap, squared.
        for (member, rungs) in before.rungs {
            for (destination, rank) in rungs {
                if rank > 0 { offPending += 1 }
                guard let later = after.rungs[member]?[destination] else {
                    #expect(audited && routedLadderHolderDropped(member, key: key),
                            "a rung pair vanished with no audited drop at the device that held it")
                    continue
                }
                #expect(later >= rank, "a delivery rung went backwards down the ladder")
                if rank == MeshDeliveryState.delivered.rank {
                    #expect(later == MeshDeliveryState.delivered.rank,
                            "a delivered rung stopped being delivered — the terminal rule")
                }
            }
        }
        // The one legal way to have nothing off `.pending` is the strongest outcome there is: every
        // destination delivered and item 9's reclaim then took the origin's own record away, so no
        // ladder survives to compare. That arm is admitted only with the audited drop AND the
        // origin's own record really being gone — a global drop line from another cell in the same
        // process is not evidence about this origin (D-14.10).
        #expect(offPending > 0 || blocked
                || (audited && routedRecordIsGone(at: origin, key: key)),
                "every sampled rung was still pending, so the ladder was not actually compared")
    }

    /// Whether the device a vanished ladder belonged to really dropped the record — the per-device
    /// half of the vanished-pair excuse.
    private func routedLadderHolderDropped(_ fingerprint: String, key: MeshRoutedItemKey) -> Bool {
        guard let member = routedMember(fingerprint: fingerprint) else { return false }
        return routedRecordIsGone(at: member, key: key)
    }

    /// **I-10 — a capacity hold is visible, and nothing is dropped.**
    ///
    /// The refusal note's `peerFingerprint` is deliberately not asserted to be the origin: a
    /// custodian may legitimately have been the offering peer.
    private func routedCapacityHoldVisible(overlay: MeshRoutedScheduleOverlay) {
        guard let index = overlay.capacityMember, let member = participant(global: index) else {
            return
        }
        #expect(member.node.manager.routedDeliveryHold?.cause == .storeFull,
                "a refusal that names no state at all is the silent stall this battery exists to catch")
    }

    /// **I-11's second half — the replay window holds both of its axes.** A door that admits before
    /// its `verdict()`, or a window that forgets a sender, breaks one of these two counts.
    private func routedReplayWindowStaysInsideItsBounds(overlay: MeshRoutedScheduleOverlay) {
        guard overlay.replays else { return }
        // R2: bounded by the roster cap.
        for member in livingMembers {
            guard let window = member.node.manager.routedReplayWindowForTesting else { continue }
            #expect(window.trackedSenderCount <= window.maxSenders,
                    "the routed replay window tracks more senders than its own cap")
            // R2: bounded by the roster cap.
            for peer in members {
                #expect(window.recordedCount(for: peer.fingerprint) <= window.framesPerSender,
                        "the routed replay window remembers more frames than its per-sender cap")
            }
        }
    }

    /// **I-12 — the merge window's closure reason, the falsifiable half only.**
    ///
    /// At least one living member must have closed `.converged`. A `.nothingOutstanding` closure is
    /// honest only where the roster really shrank — that case says the peers it waited on stopped
    /// being reachable members, which cannot be true of a mesh that lost nobody. A window still open
    /// after the heal is **recorded**, never failed: D-7.15 leaves three residual shapes in which a
    /// window is not guaranteed to close, and this battery asserts progress under its own bounded
    /// schedule, never "every window closes".
    private func routedMergeClosureNamed() {
        var converged = 0
        // R2: bounded by the roster cap.
        for member in livingMembers {
            switch member.node.manager.lastMergeClosureForTesting {
            case .converged:
                converged += 1
            case .nothingOutstanding:
                #expect(livingMembers.count < schedule.shape.rosterSize,
                        "a window closed on unreachable peers in a mesh that lost nobody")
            case nil:
                // D-7.15's residuals are not failed — but a window that stayed open is still held
                // to its own proof cap, so "recorded" is an assertion rather than a `continue`.
                guard let window = member.node.manager.mergeWindowForTesting else { continue }
                #expect(window.proofCount <= MeshMergeWindow.maxProofs,
                        "an open merge window advertised more digests than its own cap allows")
            }
        }
        #expect(converged > 0,
                "no living member's merge window closed on a matching digest (D-7.20)")
    }
}

// MARK: - MeshRoutedDeliveryProgressState

/// How far one member's copy of a routed item has got — the deletion-proof reading of the progress
/// claim (P5 item 9).
///
/// `.closed` is a record that is present with nothing outstanding; `.reclaimed` is no record at all,
/// which the reclaim can produce for the origin's own copy and for a pure courier's. `.outstanding`
/// also covers "this device cannot say" (a store that is not `.loaded`), so an unreadable store keeps
/// the rounds loop going and fails the final assertion rather than passing it vacuously.
nonisolated enum MeshRoutedDeliveryProgressState: Equatable, Sendable {
    /// Still owed to these destinations, or unreadable.
    case outstanding([String])
    /// The record is held and nothing is outstanding.
    case closed
    /// The record is gone — reclaimed, expired or dropped.
    case reclaimed

    /// Whether the drain has nothing further to do for this copy.
    var isSettled: Bool {
        switch self {
        case .outstanding: return false
        case .closed, .reclaimed: return true
        }
    }
}

// MARK: - MeshRoutedRungSnapshot

/// Every living member's delivery ladder for one item, as **ranks** — the unit I-8 compares across
/// the final drain and I-11 compares across a replay.
///
/// Ranks and not states because `MeshDeliveryState.later(_:_:)` is a lexicographic tiebreak at equal
/// rank rather than a ≥ test; `rank` is the monotone comparator the ladder actually has.
nonisolated struct MeshRoutedRungSnapshot: Equatable, Sendable {

    /// member fingerprint → destination fingerprint → ``MeshDeliveryState/rank``.
    let rungs: [String: [String: Int]]

    /// member fingerprint → custody receipts + recipient receipts held for the item.
    let receiptCounts: [String: Int]

    /// member fingerprint → peer fingerprint → that peer's last recorded `inventorySentAt` — the
    /// unit **I-13** compares across the final drain (P6 item 7's monotonicity guard).
    ///
    /// Item-independent, unlike the two above: a device records one stamp per peer, not one per
    /// item. It rides this value anyway because this is what `routedInvariants` already takes as
    /// `before:`, sampled at exactly the two moments the claim needs.
    let inventoryStamps: [String: [String: Date]]
}

// MARK: - MeshRoutedConvergenceCell

/// One cell of the routed rectangle: a partition shape and a **fixed** seed.
///
/// `preferQuorum` is deliberately not a routed dimension. P4's 80 = 5 shapes × 2 preferences × 8
/// seeds because the preference changes the *membership* outcome; it changes no routed rung, so the
/// routed rectangle is 5 × 8 = 40 and the reason is a test rather than a comment
/// (``MeshRoutedDrainConvergenceTests/theRoutedRectangleFixesTheQuorumPreferenceAndSaysWhy()``).
nonisolated struct MeshRoutedConvergenceCell: Equatable, Sendable, CustomStringConvertible {

    /// The partition shape this cell splits into.
    let shape: MeshPartitionShape

    /// The fixed seed from ``MeshConvergenceSeeds/family``.
    let seed: UInt64

    /// The base schedule, generated with the quorum preference fixed at `false`.
    var schedule: MeshConvergenceSchedule {
        MeshScheduleGenerator.schedule(seed: seed, shape: shape, preferQuorum: false)
    }

    /// The routed side-plan, salted away from the schedule's own draws.
    var overlay: MeshRoutedScheduleOverlay { MeshScheduleGenerator.routedOverlay(for: schedule) }

    /// A replayable label: shape and seed are what a failure is re-run from.
    var description: String { "\(shape.rawValue)/\(String(seed, radix: 16))" }
}

// MARK: - MeshRoutedConvergenceMatrix

/// The routed rectangle: five shapes × the eight fixed seeds, and the sub-rectangles derived from it
/// by arithmetic over the built overlays — never by a second draw.
nonisolated enum MeshRoutedConvergenceMatrix {

    /// The routed cells that do **not** run. **Empty, and it stays empty.** A deferral needs its own
    /// written defect note and a named guard-pin; the empty list plus ``all``'s filter is the
    /// mechanism that rule rides on, and `MeshP5HonestyAcceptanceTests` asserts the emptiness
    /// positively rather than counting to zero.
    static let deferred: [MeshRoutedConvergenceCell] = []

    /// **Rectangle A** — 40 cells, the whole partition tree at the whole fixed seed family.
    static let all: [MeshRoutedConvergenceCell] = {
        var cells: [MeshRoutedConvergenceCell] = []
        // R2: bounded by the shape list × the fixed seed family.
        for shape in MeshPartitionShape.matrix {
            for seed in MeshConvergenceSeeds.family {
                let cell = MeshRoutedConvergenceCell(shape: shape, seed: seed)
                if !deferred.contains(cell) { cells.append(cell) }
            }
        }
        return cells
    }()

    /// **Rectangle B** — the lock window: the whole seed family on `2/2`, plus the root seed on the
    /// other four shapes, so a locked device is driven across the tree without paying for 40 runs.
    static let lockWindow: [MeshRoutedConvergenceCell] = {
        var cells = all.filter { $0.shape == .twoTwo }
        // R2: bounded by the shape list.
        for shape in MeshPartitionShape.matrix where shape != .twoTwo {
            cells.append(MeshRoutedConvergenceCell(shape: shape, seed: MeshConvergenceSeeds.root))
        }
        return cells
    }()

    /// **Rectangle C** — the cells whose overlay resolved `develops == true`. Selected by arithmetic
    /// over rectangle A's overlays (no second draw) but executed on their own pipeline, because a
    /// development after a full heal and drain has no outstanding leg to hand.
    static let developing: [MeshRoutedConvergenceCell] = all.filter { $0.overlay.develops }

    /// **Rectangle D** — one sealed photo per shape at the root seed, minted wherever the overlay's
    /// own origin draw put it, so the far-branch case is reached deterministically.
    static let sealedTree: [MeshRoutedConvergenceCell] = MeshPartitionShape.matrix.map {
        MeshRoutedConvergenceCell(shape: $0, seed: MeshConvergenceSeeds.root)
    }

    /// **Rectangle F** — the two corners that need a mint of their own: the root seed and its first
    /// successor, on `2/2`.
    static let corners: [MeshRoutedConvergenceCell] = MeshConvergenceSeeds.family.prefix(2).map {
        MeshRoutedConvergenceCell(shape: .twoTwo, seed: $0)
    }

    /// **Rectangle G** — the FEATURE tree (P6 item 9): the whole seed family on `2/2`, plus the root
    /// seed on the other four shapes, so both of P6's rows are driven across the partition tree
    /// without paying for 40 runs of the costliest pipeline in the file.
    ///
    /// Rectangle B's shape and rectangle B's reason (`lockWindow`'s own note): a cell here mints a
    /// text through the real sender, a heart through the real sender, converges an advertised-key
    /// set first and then drains two keys with two different origins. Twelve cells, derived by
    /// arithmetic over the same rectangle rather than drawn beside it.
    static let featureTree: [MeshRoutedConvergenceCell] = {
        var cells = all.filter { $0.shape == .twoTwo }
        // R2: bounded by the shape list.
        for shape in MeshPartitionShape.matrix where shape != .twoTwo {
            cells.append(MeshRoutedConvergenceCell(shape: shape, seed: MeshConvergenceSeeds.root))
        }
        return cells
    }()
}

// MARK: - MeshRoutedCellRun

/// One executed routed cell: the run, its origin, its item, and what it actually did.
///
/// The executed-token trace is **returned** rather than stored on `MeshConvergenceRun`, so
/// `MeshConvergencePropertyTests.swift` is untouched by item 14 and "the generator files are
/// untouched in this diff" stays a fact a `git diff --stat` can settle.
@MainActor
struct MeshRoutedCellRun {

    /// The live run, for the caller to assert on and tear down.
    let run: MeshConvergenceRun

    /// The member that minted the item.
    let origin: MeshConvergenceMember

    /// The item every routed assertion is written against.
    let key: MeshRoutedItemKey

    /// The origin's own signed manifest, captured at the mint — item 9's reclaim can take the
    /// origin's record away before a later reader wants the bytes it was signed over.
    let manifest: MeshRoutedManifest?

    /// The routed tokens this pipeline really executed, in order.
    let executedTokens: [String]

    /// The rung ladder sampled after the heal — I-8's first sample.
    let before: MeshRoutedRungSnapshot
}

// MARK: - MeshRoutedPipeline

/// The two pipelines every routed cell runs, and nothing else.
///
/// **Pipeline 1** (`fullHeal`) mints, plants what the overlay planted, heals, samples the ladder,
/// drives the lock window, drains, replays, and hands the caller the run to assert on.
/// **Pipeline 2** (`development`) mints, drains **inside the origin's own branch**, asserts the two
/// preconditions that make a hand-off non-vacuous, and only then departs — because after a full heal
/// and drain the leaver has no outstanding leg, `handedOffItemCount` is 0, and I-3, I-7 and I-9 all
/// hold with the custody-transfer mechanism deleted.
@MainActor
enum MeshRoutedPipeline {

    /// The injected instant every mint, plant and window is charged at.
    static var mintInstant: Date { MeshRoutedFixtureClock.createdAt.addingTimeInterval(600) }

    /// Pipeline 1 — every non-developing cell.
    static func fullHeal(
        _ cell: MeshRoutedConvergenceCell, label: String, resplit: MeshResplitPlan? = nil,
        typeToken: String = MeshRoutedTypeToken.photo
    ) async throws -> MeshRoutedCellRun {
        let overlay = cell.overlay
        let run = try MeshConvergenceRun.build(
            cell.schedule, label: label, anchor: MeshRoutedFixtureClock.createdAt
        )
        guard let origin = run.participant(global: overlay.origin) else {
            throw MeshRoutedCellFailure.originNotLiving
        }
        try await run.runSplitEvents()
        var plan = try plantAndMint(run, origin: origin, overlay: overlay, typeToken: typeToken)
        #expect(run.routedOutstanding(at: origin, key: plan.key).isEmpty == false,
                "the cell must start with work actually outstanding")
        // The window runs BEFORE the heal, and the order is load-bearing (D-14.9). Opened after the
        // heal it is vacuous twice over: `runHeal` already converges the item on 11 of the 40 cells,
        // and `runRoutedDrainRounds` then returns at its `isSettled` guard, so the window pumps
        // nothing, no store is read, and "no byte moved" holds with the whole mechanism deleted
        // (measured — `item14/logs/batt6.log`). Opened here every destination is still owed the item
        // by construction (asserted immediately above), so a drain that ran loaded would move bytes
        // and the whole-mesh snapshot would say so.
        try await runLockWindow(
            run, origin: origin, overlay: overlay, key: plan.key, tokens: &plan.tokens
        )
        try await run.runHeal(interruptedBy: resplit)
        // The ladder is sampled after the FIRST drain pass, not straight off the heal. The mint
        // stages only into the origin's own store, so a sample taken before any drain is all
        // `.pending` — the bottom of the ladder — and I-8 would then compare bottoms on every cell.
        // The second pass early-exits on `isSettled` and costs nothing where the first one finished.
        try await run.runRoutedDrainRounds(origin: origin, key: plan.key)
        let before = run.routedRungSnapshot(key: plan.key)
        try await run.runRoutedDrainRounds(origin: origin, key: plan.key)
        plan.tokens += try replay(
            run, origin: origin, overlay: overlay, key: plan.key, captured: plan.manifest
        )
        return MeshRoutedCellRun(
            run: run, origin: origin, key: plan.key, manifest: plan.manifest,
            executedTokens: plan.tokens, before: before
        )
    }

    /// The gate, the mint and the two plants — pipeline 1's first half.
    private static func plantAndMint(
        _ run: MeshConvergenceRun, origin: MeshConvergenceMember,
        overlay: MeshRoutedScheduleOverlay, typeToken: String
    ) throws -> (key: MeshRoutedItemKey, tokens: [String], manifest: MeshRoutedManifest?) {
        var tokens: [String] = []
        let now = mintInstant
        let key: MeshRoutedItemKey
        if overlay.sealed {
            // REQUIRED before a sealed mint: without an open gate no canonical-store projection ever
            // happens, and every plaintext claim quietly degrades to the audited-drop arm.
            run.openEveryRoutedGate(now: now)
            key = try run.routedSealedPhotoEvent(at: origin, now: now)
            tokens.append(MeshRoutedEventToken.sealedItem.rawValue)
        } else {
            key = try run.routedCustodyEvent(
                at: origin, chunks: overlay.chunks, now: now, typeToken: typeToken
            )
            tokens.append(MeshRoutedEventToken.custody.rawValue)
        }
        if overlay.farBranchMint { tokens.append(MeshRoutedEventToken.farBranchMint.rawValue) }
        if let index = overlay.capacityMember, let member = run.participant(global: index) {
            try run.routedCapacityEvent(at: member, now: now)
            tokens.append(MeshRoutedEventToken.capacity.rawValue)
        }
        if let index = overlay.unknownTypeMember, let member = run.participant(global: index) {
            run.routedUnknownTypeEvent(at: member, dropping: typeToken)
            tokens.append(MeshRoutedEventToken.unknownType.rawValue)
        }
        tokens.append(MeshRoutedEventToken.receiptDrain.rawValue)
        // The origin's own signed manifest, captured at the mint. Item 9's reclaim drops a fully
        // delivered item at the origin, so a replay that looked the frame up afterwards would find
        // nothing and answer false for a fixture reason — which is exactly the vacuous skip the
        // dispatch flag exists to prevent.
        return (key, tokens, run.routedIndex(of: origin)?.record(for: key)?.manifest)
    }

    /// The lock window, with the in-window claims sampled while the gate is still shut.
    ///
    /// The "nothing moved" half is taken across **every** living member's directory, not the locked
    /// device's alone: the window suppresses reads at every store, so a drain that ran loaded would
    /// show up wherever it wrote. The non-vacuity half is
    /// ``MeshConvergenceRun/expectRoutedWindowIsShut(at:audited:paired:)`` — the window here runs
    /// after the heal, so the mesh is whole and a peer always exists to read an index (D-14.9).
    private static func runLockWindow(
        _ run: MeshConvergenceRun, origin: MeshConvergenceMember,
        overlay: MeshRoutedScheduleOverlay, key: MeshRoutedItemKey, tokens: inout [String]
    ) async throws {
        guard let index = overlay.lockMember, let member = run.participant(global: index) else {
            return
        }
        let snapshots = run.routedDiskSnapshots()
        try await run.routedLockWindowEvent(at: member, closingAfter: key, now: mintInstant) {
            #expect(run.routedDiskSnapshots() == snapshots,
                    "an index was overwritten while every store was deferred")
            run.expectRoutedWindowIsShut(at: member, origin: origin, key: key)
        }
        tokens.append(MeshRoutedEventToken.lockWindow.rawValue)
    }

    /// The replay: the sender is the item's origin and the victim is derived by the shipped
    /// predicate, so `routedReplayEvent` cannot answer false for a fixture reason.
    private static func replay(
        _ run: MeshConvergenceRun, origin: MeshConvergenceMember,
        overlay: MeshRoutedScheduleOverlay, key: MeshRoutedItemKey,
        captured: MeshRoutedManifest?
    ) throws -> [String] {
        guard overlay.replays else { return [] }
        // The victim must ALREADY HOLD the item, or the dispatch is a first admission dressed up as
        // a replay: it would legitimately move bytes and rungs, and I-11 would red for the one
        // reason that is not a defect.
        guard let victim = run.livingMembers.first(where: {
            $0.index != origin.index
                && run.routedIndex(of: $0)?.record(for: key)?.manifest != nil
        }) else {
            Issue.record("the cell planned a replay and no survivor ever admitted the manifest")
            return []
        }
        let dispatched = try run.routedReplayChangesNothing(
            at: victim, from: origin, frame: key, captured: captured,
            now: mintInstant.addingTimeInterval(60)
        )
        return dispatched ? [MeshRoutedEventToken.replay.rawValue] : []
    }

    /// Pipeline 2 — the developing cells, copied from the shipped item-8 cell.
    ///
    /// The teardown discipline is item 1a's and D-8.42's: the pending rotation is consumed on **every**
    /// node before any session ends, because a development arms a debounce that fires seconds later
    /// and, once started, runs on to `broadcastCoordinatorBeacon` and its send tasks.
    static func development(
        _ cell: MeshRoutedConvergenceCell, label: String
    ) async throws -> MeshRoutedCellRun {
        let overlay = cell.overlay
        let run = try MeshConvergenceRun.build(
            cell.schedule, label: label, anchor: MeshRoutedFixtureClock.createdAt
        )
        guard let origin = run.participant(global: overlay.origin) else {
            throw MeshRoutedCellFailure.originNotLiving
        }
        try await run.runSplitEvents()
        var tokens = [
            overlay.sealed
                ? MeshRoutedEventToken.sealedItem.rawValue
                : MeshRoutedEventToken.custody.rawValue
        ]
        if overlay.farBranchMint { tokens.append(MeshRoutedEventToken.farBranchMint.rawValue) }
        let now = mintInstant
        let key: MeshRoutedItemKey
        if overlay.sealed {
            run.openEveryRoutedGate(now: now)
            key = try run.routedSealedPhotoEvent(at: origin, now: now)
        } else {
            key = try run.routedCustodyEvent(at: origin, chunks: overlay.chunks, now: now)
        }
        try await run.runBranchDrainRounds(origin: origin, key: key)
        #expect(run.routedIndex(of: origin)?.record(for: key)?.receipts.isEmpty == false,
                "the branch partner must have taken the bytes and receipted for them")
        #expect(run.routedOutstanding(at: origin, key: key).isEmpty == false,
                "and the far branch must still be owed the item, or there is nothing to hand over")
        await run.routedDevelopmentEvent(at: origin, now: now.addingTimeInterval(300))
        tokens.append(MeshRoutedEventToken.development.rawValue)
        try await MeshDepartureRig.settle(run.livingNodes, on: run.fabric)
        // A second pump, so anything the first one's rotation spawned runs INSIDE this cell.
        try await MeshDepartureRig.settle(run.livingNodes, on: run.fabric)
        return MeshRoutedCellRun(
            run: run, origin: origin, key: key,
            manifest: run.routedIndex(of: origin)?.record(for: key)?.manifest,
            executedTokens: tokens, before: run.routedRungSnapshot(key: key)
        )
    }

    /// Ends every session a run left open, in the order D-8.42 requires.
    static func teardown(_ run: MeshConvergenceRun) {
        // R2: bounded by the roster cap, twice.
        for node in run.livingNodes { _ = node.manager.consumePendingRotationForTesting() }
        for node in run.livingNodes { node.manager.leaveMesh() }
    }
}

// MARK: - MeshRoutedFeatureCellRun

/// One executed FEATURE cell (P6 item 9): the run, the two rows it minted, and what it really did.
///
/// Two keys rather than one, because rectangle G's whole point is that P6's two rows converge
/// **together** on one partition tree — a text to the full roster and a heart to exactly one
/// member, interleaved by the overlay's own draws.
@MainActor
struct MeshRoutedFeatureCellRun {

    /// The live run, for the caller to assert on and tear down.
    let run: MeshConvergenceRun

    /// The cell's resolved plan.
    let overlay: MeshRoutedScheduleOverlay

    /// The member that minted the text.
    let textOrigin: MeshConvergenceMember

    /// The text item, minted through the real `sendTempMessage(_:)`.
    let textKey: MeshRoutedItemKey

    /// The member that minted the heart.
    let heartOrigin: MeshConvergenceMember

    /// The heart's single recipient.
    let heartRecipient: MeshConvergenceMember

    /// The heart item, or nil where the overlay planned none (unreachable in this rectangle).
    let heartKey: MeshRoutedItemKey?

    /// The routed tokens this pipeline really executed, in order.
    let executedTokens: [String]

    /// The text's rung ladder, sampled after its first drain pass.
    let beforeText: MeshRoutedRungSnapshot

    /// The heart's rung ladder, sampled after its first drain pass.
    let beforeHeart: MeshRoutedRungSnapshot

    /// Every heart judgement any member minted during the run.
    let judgementLog: MeshRoutedHeartJudgementLog
}

// MARK: - MeshRoutedFeaturePipeline

/// **Pipeline 3 — the FEATURE pipeline** (P6 item 9): the two rows P6 added, on a run whose
/// addressing has really converged.
///
/// **Why not pipeline 1.** The feature mints must come AFTER the heal, because nothing converges the
/// advertisement set before it (`linkBranches` raises no `.peerCommitted` on purpose) and the
/// resolver then refuses every mint by name. Pipeline 1's own mint must come BEFORE the heal for the
/// opposite reason — its lock window is vacuous otherwise (D-14.9). The two orders are incompatible,
/// which is what makes this a third pipeline rather than four more lines in an existing one.
@MainActor
enum MeshRoutedFeaturePipeline {

    /// Runs one feature cell end to end and hands the caller the run to assert on.
    ///
    /// - Parameters:
    ///   - cell: The rectangle-G cell.
    ///   - label: The diagnostic prefix.
    /// - Returns: the executed cell.
    static func featureRouting(
        _ cell: MeshRoutedConvergenceCell, label: String
    ) async throws -> MeshRoutedFeatureCellRun {
        let overlay = cell.overlay
        let run = try MeshConvergenceRun.build(
            cell.schedule, label: label, anchor: MeshRoutedFixtureClock.createdAt
        )
        let cast = try await converged(run, overlay: overlay)
        let log = MeshRoutedHeartJudgementLog()
        run.installHeartJudgementWitness(log)
        run.armHeartCeremony(at: cast.heartOrigin, to: cast.recipient)
        run.setHeartRecipientForegrounded(cast.recipient, overlay.heartRecipientForegrounded)
        let window = try await runFeatureWindow(run, overlay: overlay, cast: cast)
        return MeshRoutedFeatureCellRun(
            run: run, overlay: overlay,
            textOrigin: cast.textOrigin, textKey: window.textKey,
            heartOrigin: cast.heartOrigin, heartRecipient: cast.recipient,
            heartKey: window.heartKey, executedTokens: window.tokens,
            beforeText: window.beforeText, beforeHeart: window.beforeHeart, judgementLog: log
        )
    }

    /// The three members one cell's overlay names.
    struct FeatureCast {
        /// The text's origin.
        let textOrigin: MeshConvergenceMember
        /// The heart's origin.
        let heartOrigin: MeshConvergenceMember
        /// The heart's single recipient.
        let recipient: MeshConvergenceMember
    }

    /// Splits, opens every gate, arms and converges the advertised-key set, and resolves the cast.
    ///
    /// The arming is its own step and the convergence is asserted before anything is minted: a run
    /// whose set never converged would refuse every mint below by name, which is a loud failure —
    /// but the loud failure belongs here, where it names the addressing rather than the row.
    private static func converged(
        _ run: MeshConvergenceRun, overlay: MeshRoutedScheduleOverlay
    ) async throws -> FeatureCast {
        let now = MeshRoutedPipeline.mintInstant
        try await run.runSplitEvents()
        run.openEveryRoutedGate(now: now)
        run.armKeyAdvertisements(now: now)
        run.allowChatEverywhere(except: overlay.ageGatedMember)
        try await run.runHeal()
        try await run.runKeyAdvertisementRounds()
        run.expectAdvertisementsConverged()
        guard let textOrigin = run.participant(global: overlay.textOrigin),
              let heartOrigin = run.participant(global: overlay.heartOrigin)
        else { throw MeshRoutedCellFailure.originNotLiving }
        guard let recipient = run.participant(global: overlay.heartRecipient),
              overlay.plansHeart
        else { throw MeshRoutedCellFailure.heartRecipientMissing }
        return FeatureCast(textOrigin: textOrigin, heartOrigin: heartOrigin, recipient: recipient)
    }

    /// Samples one row's rung ladder the moment it has something off `.pending`, bounded.
    ///
    /// **Neither end of the obvious window works, and both were measured** (`logs/item9/`). I-8
    /// compares two ladders and its non-vacuity needs the FIRST to be off the bottom, so a sample
    /// taken straight off the feature window is all `.pending` for a row minted in the window's last
    /// round — two of rectangle G's twelve cells. Sampling after the full drain instead is worse:
    /// item 9's reclaim drops a fully delivered item at the origin, so on exactly the cells that
    /// converged best there is no ladder left to sample at all. So the sample is taken the moment
    /// the ladder moves, with a hard ceiling, and a row whose ladder never moves falls through to
    /// the caller's own claim rather than being waited for forever.
    private static func sampleWhenMoving(
        _ run: MeshConvergenceRun, key: MeshRoutedItemKey
    ) async throws -> MeshRoutedRungSnapshot {
        // R2: a hard constant ceiling.
        for _ in 0..<MeshConvergenceRun.routedDrainRounds {
            let snapshot = run.routedRungSnapshot(key: key)
            let moving = snapshot.rungs.values.contains { $0.values.contains { $0 > 0 } }
            if moving { return snapshot }
            try await run.runFeatureDrainRound()
        }
        return run.routedRungSnapshot(key: key)
    }

    /// What one feature window produced.
    private struct FeatureWindow {
        let textKey: MeshRoutedItemKey
        let heartKey: MeshRoutedItemKey?
        let tokens: [String]
        let beforeText: MeshRoutedRungSnapshot
        let beforeHeart: MeshRoutedRungSnapshot
    }

    /// The bounded feature window, then a bounded drain to convergence for each row.
    ///
    /// A conditional **execution** keyed on a resolved field, exactly as `capacityMember` and
    /// `develops` already are — never a conditional draw. The ladders are sampled after the window
    /// rather than straight off a mint: a sample taken off the mint is all `.pending`, the bottom of
    /// the ladder, and I-8 would then compare bottoms on every cell in the rectangle.
    private static func runFeatureWindow(
        _ run: MeshConvergenceRun, overlay: MeshRoutedScheduleOverlay, cast: FeatureCast
    ) async throws -> FeatureWindow {
        var tokens = [
            MeshRoutedEventToken.keyAdvertisement.rawValue,
            MeshRoutedEventToken.textOrigination.rawValue
        ]
        if overlay.ageGatedMember != nil {
            tokens.append(MeshRoutedEventToken.ageGatedReceiver.rawValue)
        }
        var textKey: MeshRoutedItemKey?
        var heartKey: MeshRoutedItemKey?
        // R2: a hard constant ceiling.
        for round in 0..<MeshScheduleBounds.maxFeatureRounds {
            if round == overlay.textRound {
                textKey = try run.routedTextEvent(at: cast.textOrigin, round: round)
            }
            if round == overlay.heartRound {
                heartKey = try run.routedHeartEvent(at: cast.heartOrigin, to: cast.recipient)
                tokens.append(MeshRoutedEventToken.heartOrigination.rawValue)
                if overlay.heartDeferredRecipient != nil {
                    tokens.append(MeshRoutedEventToken.heartDeferred.rawValue)
                }
            }
            try await run.runFeatureDrainRound()
        }
        guard let textKey, let heartKey else { throw MeshRoutedCellFailure.heartNotStaged }
        let beforeText = try await sampleWhenMoving(run, key: textKey)
        let beforeHeart = try await sampleWhenMoving(run, key: heartKey)
        try await run.runRoutedDrainRounds(origin: cast.textOrigin, key: textKey)
        try await run.runRoutedDrainRounds(origin: cast.heartOrigin, key: heartKey)
        return FeatureWindow(
            textKey: textKey, heartKey: heartKey, tokens: tokens,
            beforeText: beforeText, beforeHeart: beforeHeart
        )
    }
}

// MARK: - The property

/// **The routed progress property.** One seeded, bounded schedule per cell: split, events, mint,
/// ordered heal, bounded drain rounds — then the twelve routed invariants.
///
/// The progress half is what the safety pair cannot express: an item that never moves satisfies
/// "still named by `outstandingDestinations`" forever, so without it the whole pacing family would
/// be invisible to the battery. The rectangle carries a multi-chunk item for exactly that reason,
/// pinned by ``theRoutedRectangleCarriesAMultiChunkCellAndASingleChunkCell()``.
@MainActor
@Suite(.serialized)
struct MeshRoutedDrainConvergenceTests {

    /// **Rectangle A — progress, across the whole partition tree.** Five shapes × the eight fixed
    /// seeds, each carrying whatever its salted overlay resolved: a multi- or single-chunk mint, a
    /// sealed photo or an opaque blob, a capped destination, a locked device, a replay, an
    /// unregistered type at one receiver.
    @Test(arguments: MeshRoutedConvergenceMatrix.all)
    func everyOutstandingDeliveryClosesUnderASeededSchedule(
        cell: MeshRoutedConvergenceCell
    ) async throws {
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        let outcome = try await MeshRoutedPipeline.fullHeal(cell, label: "routed-drain")
        defer { MeshRoutedPipeline.teardown(outcome.run) }

        outcome.run.routedInvariants(
            outcome.origin, outcome.key, audited: capture,
            overlay: cell.overlay, before: outcome.before
        )
        #expect(Set(outcome.executedTokens) == cell.overlay.fullHealTokens,
                "the cell executed something its own overlay never planned")
    }

    /// **Rectangle B — a locked window loses nothing, and the unlock converges it.**
    ///
    /// Inside the window every store answers `deferred`, which is the state a device is in before its
    /// first post-boot unlock: no index is overwritten, no receipt and no `delivered` rung appears
    /// anywhere, and nothing is dropped. The window is driven at the **origin** here, which is the
    /// complement of rectangle A's overlay-drawn non-origin lock member.
    @Test(arguments: MeshRoutedConvergenceMatrix.lockWindow)
    func aLockedWindowLosesNothingAndConvergesAfterTheUnlock(
        cell: MeshRoutedConvergenceCell
    ) async throws {
        let run = try MeshConvergenceRun.build(
            cell.schedule, label: "routed-lock", anchor: MeshRoutedFixtureClock.createdAt
        )
        defer { MeshRoutedPipeline.teardown(run) }
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        try await run.runSplitEvents()

        let origin = try #require(run.livingMembers.first, "the cell needs a surviving origin")
        let now = MeshRoutedPipeline.mintInstant
        let key = try run.routedCustodyEvent(at: origin, chunks: cell.overlay.chunks, now: now)
        #expect(run.routedOutstanding(at: origin, key: key).isEmpty == false,
                "the cell must start with work actually outstanding")
        let before = run.routedDiskSnapshots()

        try await run.routedLockWindowEvent(at: origin, closingAfter: key, now: now) {
            #expect(run.routedDiskSnapshots() == before,
                    "an index was overwritten while every store was deferred")
            run.expectRoutedWindowIsShut(at: origin, origin: origin, key: key)
            // R2: bounded by the roster cap.
            for member in run.livingMembers where member.index != origin.index {
                #expect(run.routedIndex(of: member)?.record(for: key) == nil,
                        "content moved to a peer whose store could not say what it holds")
            }
            #expect(run.routedIndex(of: origin)?.record(for: key)?.recipientReceipts.isEmpty == true,
                    "a receipt was emitted for state a restart would have lost")
        }
        try await run.runHeal()
        try await run.runRoutedDrainRounds(origin: origin, key: key)
        let rungs = run.routedRungSnapshot(key: key)
        try await run.runRoutedDrainRounds(origin: origin, key: key)

        run.routedInvariants(
            origin, key, audited: capture,
            overlay: MeshRoutedOverlayFixtures.lockOnly(cell.seed, origin: origin.index),
            before: rungs
        )
    }

    /// **Rectangle C — a development hands custody only to the custodians it named.**
    ///
    /// The origin drains **inside its own branch**, develops there, and the hop invariant holds
    /// across every survivor: exactly one item transfers, every courier is one the leaver named and
    /// served directly, and nothing else couriers anything. The development happens while the far
    /// branch is still owed the item, deliberately — a development after a full heal-and-drain has no
    /// outstanding leg to hand, so the transfer would have nothing to do and every assertion would
    /// hold with the mechanism deleted. Both preconditions are asserted **per cell**, inside the
    /// pipeline, so the suite cannot become vacuous.
    @Test(arguments: MeshRoutedConvergenceMatrix.developing)
    func aDevelopmentHandsCustodyOnlyToTheCustodiansItNamed(
        cell: MeshRoutedConvergenceCell
    ) async throws {
        let outcome = try await MeshRoutedPipeline.development(cell, label: "routed-handoff")
        defer { MeshRoutedPipeline.teardown(outcome.run) }

        outcome.run.routedHandoffBound(
            origin: outcome.origin, key: outcome.key, developing: true
        )
        #expect(Set(outcome.executedTokens) == cell.overlay.developmentTokens,
                "the development cell executed something its own overlay never planned")
        // Ends the sessions and then lets whatever the teardown could not cancel actually run, while
        // these stores are still alive — see `MeshRoutedDrainRig.quiesce()`.
        MeshRoutedPipeline.teardown(outcome.run)
        // R2: a hard constant ceiling.
        for _ in 0..<16 { await Task.yield() }
    }

    /// **Rectangle D — a sealed photo converges across the partition tree.** One REAL sealed photo
    /// per shape at the fixed root seed, minted wherever the overlay's own origin draw put it, so
    /// far-branch mints are reached deterministically rather than hoped for.
    ///
    /// The property the ciphertext cells cannot state: they end at custody and receipts, while this
    /// one ends at the canonical store the whole feature exists to fill.
    @Test(arguments: MeshRoutedConvergenceMatrix.sealedTree)
    func aSealedPhotoConvergesAcrossThePartitionTree(
        cell: MeshRoutedConvergenceCell
    ) async throws {
        let run = try MeshConvergenceRun.build(
            cell.schedule, label: "routed-tree", anchor: MeshRoutedFixtureClock.createdAt
        )
        defer { MeshRoutedPipeline.teardown(run) }
        try await run.runSplitEvents()

        let origin = try #require(
            run.participant(global: cell.overlay.origin), "the cell needs a surviving origin"
        )
        let now = MeshRoutedPipeline.mintInstant
        run.openEveryRoutedGate(now: now)
        let key = try run.routedSealedPhotoEvent(at: origin, now: now)
        #expect(run.routedOutstanding(at: origin, key: key).isEmpty == false,
                "the cell must start with work actually outstanding")

        try await run.runHeal()
        try await run.runRoutedDrainRounds(origin: origin, key: key)

        let destinations = run.livingMembers.filter { $0.index != origin.index }
        #expect(destinations.isEmpty == false, "the cell needs at least one destination")
        // R2: bounded by the roster cap.
        for member in destinations {
            #expect(member.node.manager.meshPhotos.filter { $0.id == key.itemID }.count == 1,
                    "every destination's wall holds exactly one entry for the delivered item")
        }
    }

    /// **P-1 — P5 item 13's own root cell, kept.** One REAL sealed photo minted at the NEAR branch's
    /// first survivor, which rectangle D's overlay-driven origin does not always be.
    @Test func aSealedPhotoConvergesOnTheRootSeed() async throws {
        let schedule = MeshScheduleGenerator.schedule(
            seed: MeshConvergenceSeeds.root, shape: .twoTwo, preferQuorum: false
        )
        let run = try MeshConvergenceRun.build(
            schedule, label: "routed-photo", anchor: MeshRoutedFixtureClock.createdAt
        )
        defer { MeshRoutedPipeline.teardown(run) }
        try await run.runSplitEvents()

        let origin = try #require(run.livingMembers.first, "the cell needs a surviving origin")
        let now = MeshRoutedPipeline.mintInstant
        run.openEveryRoutedGate(now: now)
        let key = try run.routedSealedPhotoEvent(at: origin, now: now)
        #expect(run.routedOutstanding(at: origin, key: key).isEmpty == false,
                "the cell must start with work actually outstanding")

        try await run.runHeal()
        try await run.runRoutedDrainRounds(origin: origin, key: key)

        let destinations = run.livingMembers.filter { $0.index != origin.index }
        #expect(destinations.isEmpty == false, "the cell needs at least one destination")
        // R2: bounded by the roster cap.
        for member in destinations {
            #expect(member.node.manager.meshPhotos.filter { $0.id == key.itemID }.count == 1,
                    "every destination's wall holds exactly one entry for the delivered item")
        }
    }

    /// **Rectangle G — both of P6's rows converge together, across the partition tree** (item 9).
    ///
    /// One seeded cell: split, open every gate, arm every member's own key advertisement, shut one
    /// drawn member's chat gate, heal, converge the advertised-key set, then a bounded two-round
    /// feature window in which the overlay's draws decide who sends a text, who sends a heart to
    /// whom, in which round, and whether the recipient is awake when it lands.
    ///
    /// The two rows are judged with **different audiences**, which is the whole reason item 9 has a
    /// rectangle of its own: a text is `.fullRosterAtCreation` and a heart is `.singleRecipient`, and
    /// `routedDeliveryState` answers `.reclaimed` for "this device holds no record" — so a
    /// roster-wide claim about the heart would pass at every non-recipient for exactly the wrong
    /// reason (the design check's R3, and item 6's handoff §8 names the same trap).
    @Test(arguments: MeshRoutedConvergenceMatrix.featureTree)
    func bothFeatureRowsConvergeUnderASeededSchedule(
        cell: MeshRoutedConvergenceCell
    ) async throws {
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        let outcome = try await MeshRoutedFeaturePipeline.featureRouting(cell, label: "routed-feature")
        defer { MeshRoutedPipeline.teardown(outcome.run) }
        let overlay = cell.overlay
        let run = outcome.run

        run.routedInvariants(
            outcome.textOrigin, outcome.textKey, audited: capture,
            overlay: MeshRoutedOverlayFixtures.textOnly(
                cell.seed, origin: outcome.textOrigin.index, gated: overlay.ageGatedMember
            ),
            before: outcome.beforeText
        )
        let heartKey = try #require(outcome.heartKey, "every cell in this rectangle plans a heart")
        let audience = run.routedJudgedAudience(outcome.heartOrigin, key: heartKey)
            ?? [outcome.heartRecipient.fingerprint]
        #expect(audience == [outcome.heartRecipient.fingerprint], """
            the heart's own signed destination set must be exactly the member the overlay drew, or             the narrowed audience below is narrower than the mint
            """)
        run.routedInvariants(
            outcome.heartOrigin, heartKey, audited: capture,
            overlay: MeshRoutedOverlayFixtures.heartOnly(
                cell.seed, origin: outcome.heartOrigin.index,
                recipient: outcome.heartRecipient.index,
                deferredRecipient: overlay.heartDeferredRecipient
            ),
            before: outcome.beforeHeart, judged: audience
        )
        #expect(Set(outcome.executedTokens) == overlay.featureTokens, """
            this cell executed a feature token its overlay never planned, or planned one it never             executed
            """)
        #expect(outcome.judgementLog.dropped == 0,
                "the judgement witness hit its own cap, so the count below is not the whole count")
        // I-8's non-vacuity, named per ROW rather than left to the shared claim: the two ladders are
        // sampled independently and "the ladder was not actually compared" cannot say which of them
        // was still sitting at the bottom.
        let textOff = outcome.beforeText.rungs.values.flatMap(\.values).filter { $0 > 0 }.count
        let heartOff = outcome.beforeHeart.rungs.values.flatMap(\.values).filter { $0 > 0 }.count
        let heartMayBeStill = overlay.heartDeferredRecipient != nil
        if textOff == 0 || (heartOff == 0 && !heartMayBeStill) {
            Issue.record("""
                a feature ladder was sampled entirely at .pending — text \(textOff) off-pending over \
                \(outcome.beforeText.rungs.count) members, heart \(heartOff) over \
                \(outcome.beforeHeart.rungs.count) members, deferred recipient \
                \(overlay.heartDeferredRecipient != nil)
                """)
        }
    }

    /// **I-13's non-vacuity, asserted once — beside the sample, not inside the claim** (P6 item 7).
    ///
    /// `routedInventoryStampMonotone(before:)` compares the pairs present in both samples and is
    /// silent when there are none, which is correct: rectangle B's replay cell and the development
    /// pipeline legitimately exchange no inventory digest, and an `isEmpty == false` inside the
    /// shared claim would redden them. So the "it really is comparing something" half lives here,
    /// on one cell that does drive a full heal and two drain passes.
    @Test func theRungSnapshotReallySamplesAnInventoryStamp() async throws {
        let cell = MeshRoutedConvergenceCell(shape: .twoTwo, seed: MeshConvergenceSeeds.root)
        let outcome = try await MeshRoutedPipeline.fullHeal(cell, label: "routed-stamp")
        defer { MeshRoutedPipeline.teardown(outcome.run) }

        let sampled = outcome.before.inventoryStamps.values.reduce(0) { $0 + $1.count }
        #expect(sampled > 0, """
            no member had recorded any peer's inventory stamp when the ladder was sampled, so I-13 \
            compares nothing on every cell in the rectangle
            """)
    }

    /// **P6 item 9, STAGE 0: tier B addressing really converges in THIS rig.**
    ///
    /// The convergence run seeds its ledgers straight into the verifier, which is a different
    /// arming from the photo rigs that proved the resolver — so "does the advertised-key set
    /// converge here?" was the design's riskiest unanswered question, and it is answerable with no
    /// overlay change at all. The text mint at the end is the point: `sendTempMessage(_:)` runs the
    /// real `routedDestinationKeys` resolver, so a set that had not converged would refuse here
    /// rather than pass silently.
    @Test func everyLivingMemberEndsHoldingEveryOtherMembersAdvertisedKey() async throws {
        let schedule = MeshScheduleGenerator.schedule(
            seed: MeshConvergenceSeeds.root, shape: .twoTwo, preferQuorum: false
        )
        let run = try MeshConvergenceRun.build(
            schedule, label: "routed-adv", anchor: MeshRoutedFixtureClock.createdAt
        )
        defer { MeshRoutedPipeline.teardown(run) }
        try await run.runSplitEvents()
        run.allowChatEverywhere(except: nil)
        run.armKeyAdvertisements(now: MeshRoutedPipeline.mintInstant)

        try await run.runHeal()
        try await run.runKeyAdvertisementRounds()

        #expect(run.livingMembers.count >= 2, "one survivor converges nothing")
        #expect(run.routedAdvertisementsConverged(), """
            the advertised-key set never converged, so every feature mint item 9 will hang off it \
            would be unaddressable
            """)
        let origin = try #require(run.livingMembers.first, "the cell needs a surviving origin")
        let key = try run.routedTextEvent(at: origin, round: 0)
        #expect(run.routedOutstanding(at: origin, key: key).isEmpty == false,
                "a converged set must resolve real destinations for the text row")
    }

    /// **The arming-skipped case, measured — and it does NOT fail.** (item 9 design §2d, corrected.)
    ///
    /// The design expected a run that never calls ``MeshConvergenceRun/armKeyAdvertisements(now:)``
    /// to hold an EMPTY advertisement set, with the text mint answering
    /// `.refused(.destinationNotAddressable)`. **Measured at this HEAD, it converges anyway**, and
    /// the reason is item 1's own fix rather than an accident of the rig:
    /// `sendKeyAdvertisements(to:)` calls `repairOwnKeyAdvertisementIfMissing()` **above** its batch
    /// read, gated only on "there is somebody to tell" (item 1's second fix review, finding 1), and
    /// the heal raises `.peerCommitted` at every pair — so each member self-mints its own missing
    /// row on the first ask, bounded at
    /// `MeshKeyAdvertisementSendBounds.selfMintAttemptsPerSession`. The design was read before that
    /// gate was reshaped; this cell records the truth instead of asserting the stale expectation.
    ///
    /// The first assertion is the half that IS still true, and it is the half item 1's residual was
    /// really about: the rig's `seedMembershipLedgerForTesting` bypasses both production mint doors,
    /// so nothing is advertised until a **shipping** door runs. `armKeyAdvertisements(now:)`
    /// therefore stays as a determinism seam — it mints on the injected clock, before the heal, with
    /// `#expect(armed)` per member so an arm-time seal refusal is loud, and it does not spend the
    /// repair's three-attempt session budget. It is not what makes the set non-empty.
    ///
    /// The negative that really is load-bearing for this stage is the chat gate — see
    /// ``theChatGateIsFailClosedSoTheTextHalfIsNeverGreenOverNothing()``.
    @Test func withoutTheArmingDoorItemOnesSelfMintRepairStillAddressesTheMesh() async throws {
        let schedule = MeshScheduleGenerator.schedule(
            seed: MeshConvergenceSeeds.root, shape: .twoTwo, preferQuorum: false
        )
        let run = try MeshConvergenceRun.build(
            schedule, label: "routed-adv-repair", anchor: MeshRoutedFixtureClock.createdAt
        )
        defer { MeshRoutedPipeline.teardown(run) }
        try await run.runSplitEvents()
        run.allowChatEverywhere(except: nil)

        let seededEmpty = run.livingMembers.allSatisfy { $0.node.manager.keyAdvertisements.isEmpty }
        #expect(seededEmpty, """
            the rig's ledger seeding must mint nothing, or neither this cell nor the arming door \
            above it is measuring a production mint at all
            """)

        try await run.runHeal()                                   // deliberately no arming
        try await run.runKeyAdvertisementRounds()

        #expect(run.routedAdvertisementsConverged(), """
            item 1's bounded self-mint repair no longer fills the set on the first ask — if that is \
            deliberate, the arming door becomes load-bearing and §2d's negative comes back
            """)
        let origin = try #require(run.livingMembers.first, "the cell needs a surviving origin")
        #expect(run.sendTextOutcome(at: origin, round: 0) == .staged,
                "a converged set addresses the text row whether or not the arming door ran")
    }

    /// **The chat gate is fail-closed, which is what keeps the text half from being green over
    /// nothing** (item 9 design B1).
    ///
    /// `chatAllowedProvider` is **nil** on a freshly built manager and `isChatAllowed` reads
    /// `provider?() == true`, so a run that never calls
    /// ``MeshConvergenceRun/allowChatEverywhere(except:)`` gets `.ageGated` from every member — an
    /// answer that never touches the resolver, never mints an item, and would leave item 9's whole
    /// text rectangle asserting over nothing. The control is the same member one line later, with
    /// only the gate changed.
    @Test func theChatGateIsFailClosedSoTheTextHalfIsNeverGreenOverNothing() async throws {
        let schedule = MeshScheduleGenerator.schedule(
            seed: MeshConvergenceSeeds.root, shape: .twoTwo, preferQuorum: false
        )
        let run = try MeshConvergenceRun.build(
            schedule, label: "routed-adv-gate", anchor: MeshRoutedFixtureClock.createdAt
        )
        defer { MeshRoutedPipeline.teardown(run) }
        try await run.runSplitEvents()
        run.armKeyAdvertisements(now: MeshRoutedPipeline.mintInstant)
        try await run.runHeal()
        try await run.runKeyAdvertisementRounds()

        #expect(run.routedAdvertisementsConverged(), "the addressing half must not be the reason")
        let origin = try #require(run.livingMembers.first, "the cell needs a surviving origin")
        #expect(run.sendTextOutcome(at: origin, round: 0) == .ageGated,
                "a nil chat provider must fail CLOSED, or the gate is decoration")

        run.allowChatEverywhere(except: nil)
        #expect(run.sendTextOutcome(at: origin, round: 1) == .staged,
                "and opening the gate is the only thing that changed")
    }

    /// **P5 item 9 in the battery.** One survivor is at its byte cap when the drain reaches it, and a
    /// capacity refusal is a **named closed state** rather than a silent stall: the item stays
    /// outstanding at the origin, the origin's own record is intact, and the capped member says why.
    ///
    /// The hog carries the schedule's own expiry, so item 9's expiry sweep cannot free it before the
    /// refusal happens — the fixture trap that would turn this cell green for the wrong reason.
    @Test func aMemberAtCapacityLosesNoContent() async throws {
        let schedule = MeshScheduleGenerator.schedule(
            seed: MeshConvergenceSeeds.root, shape: .twoTwo, preferQuorum: false
        )
        let run = try MeshConvergenceRun.build(
            schedule, label: "routed-capacity", anchor: MeshRoutedFixtureClock.createdAt
        )
        defer { MeshRoutedPipeline.teardown(run) }
        try await run.runSplitEvents()

        let origin = try #require(run.livingMembers.first, "the cell needs a surviving origin")
        let capped = try #require(
            run.livingMembers.dropFirst().first, "the cell needs a second survivor to fill"
        )
        let now = MeshRoutedPipeline.mintInstant
        try run.routedCapacityEvent(at: capped, now: now)
        let key = try run.routedCustodyEvent(at: origin, chunks: 1, now: now)
        #expect(run.routedOutstanding(at: origin, key: key).contains(capped.fingerprint),
                "the cell must start with the capped member actually owed the item")

        try await run.runHeal()
        try await run.runRoutedDrainRounds(origin: origin, key: key)

        #expect(run.routedOutstanding(at: origin, key: key).contains(capped.fingerprint),
                "a capacity refusal must leave the delivery outstanding, never quietly closed")
        #expect(run.routedIndex(of: origin)?.record(for: key) != nil,
                "the origin's own copy is intact — backpressure is not data loss")
        #expect(capped.node.manager.routedDeliveryHold?.cause == .storeFull,
                "a refusal that names no state at all is the silent stall this battery exists to catch")
    }

    /// **P5 item 12 in the battery.** A replayed frame changes no rung and no receipt count: the
    /// routed progress invariants still hold after one already-admitted manifest is re-presented on
    /// a live link, and the receiver's index is byte-identical across the replay.
    @Test func aReplayedFrameChangesNoRungAndNoReceiptCount() async throws {
        let schedule = MeshScheduleGenerator.schedule(
            seed: MeshConvergenceSeeds.root, shape: .twoTwo, preferQuorum: false
        )
        let run = try MeshConvergenceRun.build(
            schedule, label: "routed-replay", anchor: MeshRoutedFixtureClock.createdAt
        )
        defer { MeshRoutedPipeline.teardown(run) }
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        try await run.runSplitEvents()

        let origin = try #require(run.livingMembers.first, "the cell needs a surviving origin")
        let now = MeshRoutedPipeline.mintInstant
        let key = try run.routedCustodyEvent(at: origin, chunks: 1, now: now)
        let captured = run.routedIndex(of: origin)?.record(for: key)?.manifest
        try await run.runHeal()
        try await run.runRoutedDrainRounds(origin: origin, key: key)
        let before = run.routedRungSnapshot(key: key)
        try await run.runRoutedDrainRounds(origin: origin, key: key)

        let victim = try #require(
            run.livingMembers.first {
                $0.index != origin.index
                    && run.routedIndex(of: $0)?.record(for: key)?.manifest != nil
            },
            "the cell needs a survivor that already admitted the manifest"
        )
        try run.routedReplayChangesNothing(
            at: victim, from: origin, frame: key, captured: captured, now: now.addingTimeInterval(60)
        )
        run.routedInvariants(
            origin, key, audited: capture,
            overlay: MeshRoutedOverlayFixtures.replayOnly(MeshConvergenceSeeds.root, origin: origin.index),
            before: before
        )
    }

    /// The seed family is fixed and derived from the one root — never drawn at run time.
    @Test func theSeedFamilyIsTheFixedOne() {
        #expect(MeshConvergenceSeeds.root == 0x00F3_2B1C_0009_0002)
        #expect(MeshConvergenceSeeds.family.count == MeshConvergenceSeeds.derivedCount)
        #expect(MeshConvergenceSeeds.family.first == MeshConvergenceSeeds.root)
        var random = MeshScheduleRandom(seed: MeshConvergenceSeeds.root)
        var rederived: [UInt64] = [MeshConvergenceSeeds.root]
        // R2: bounded by the fixed family size.
        for _ in 1..<MeshConvergenceSeeds.derivedCount { rederived.append(random.next()) }
        #expect(rederived == MeshConvergenceSeeds.family,
                "the family is SplitMix64 from the root — replayable from one constant")
    }

    /// **The rectangle still carries an item a single frame cannot finish** — and one it can.
    ///
    /// This supersedes by name the two cell-list assertions the eight-cell
    /// `MeshRoutedDrainCells` list carried (`all.count == derivedCount`, exactly one multi-chunk
    /// cell): the eight-cell list is gone, and the 40-cell rectangle is what they now pin.
    @Test func theRoutedRectangleCarriesAMultiChunkCellAndASingleChunkCell() {
        let overlays = MeshRoutedConvergenceMatrix.all.map(\.overlay)
        #expect(overlays.contains { !$0.sealed && $0.chunks == 3 },
                "no cell mints an opaque item that a single frame cannot finish")
        #expect(overlays.contains { $0.chunks == 1 },
                "and no cell mints a single-chunk item either")
        let sealedCells = overlays.contains { $0.sealed }
        #expect(sealedCells, "no cell mints a REAL sealed photo")
        #expect(overlays.contains { !$0.sealed }, "and no cell mints an opaque blob")
    }

    /// **The rectangle is 5 × 8, and the quorum preference is deliberately not a routed dimension.**
    ///
    /// P4's 80 = 5 × 2 × 8 because the preference changes the *membership* outcome; it changes no
    /// routed rung. Fixed at `false`, so the rectangle is 40 — and a silently shrunk rectangle goes
    /// red here rather than quiet.
    @Test func theRoutedRectangleFixesTheQuorumPreferenceAndSaysWhy() {
        #expect(MeshRoutedConvergenceMatrix.all.count == 40,
                "5 shapes × 8 fixed seeds is the routed rectangle")
        #expect(Set(MeshRoutedConvergenceMatrix.all.map(\.shape)) == Set(MeshPartitionShape.matrix),
                "every shape §16.2 names carries routed cells")
        #expect(Set(MeshRoutedConvergenceMatrix.all.map(\.seed)) == Set(MeshConvergenceSeeds.family),
                "and the whole fixed seed family runs")
        #expect(MeshRoutedConvergenceMatrix.all.allSatisfy { $0.schedule.shape == $0.shape })
        #expect(MeshRoutedConvergenceMatrix.lockWindow.count == 12,
                "8 seeds on 2/2 plus the root seed on the other four shapes")
        let developing = MeshRoutedConvergenceMatrix.developing.count
        #expect(developing >= 8 && developing <= 40,
                "the development rectangle must be neither empty nor the whole rectangle")
        #expect(MeshRoutedConvergenceMatrix.featureTree.count == 12,
                "rectangle G is rectangle B's shape, for rectangle B's reason")
        #expect(
            Set(MeshRoutedConvergenceMatrix.featureTree.map(\.shape))
                == Set(MeshPartitionShape.matrix),
            "and it reaches every shape, so neither P6 row is proved on one topology"
        )
    }

    /// **The `.departed` disposition is reachable at all** — the one variety of I-1's arm that had
    /// no pin of its own.
    ///
    /// A destination can only read `.departed` where the departure (or the completed removal) landed
    /// in a branch the ORIGIN could not see when it minted: the mint runs after `runSplitEvents`, so
    /// a leaver in the origin's own branch is already out of the roster the manifest freezes and the
    /// immutable destination set never names it. That is a conjunction of two independently salted
    /// draws — the schedule's departure and the overlay's origin — and nothing but this arithmetic
    /// says it ever happens. Every other variety in the rectangle is pinned the same way
    /// (`theRoutedRectangleCarriesAMultiChunkCellAndASingleChunkCell`, `sealedTree`,
    /// `farBranchMint`, `developing.count >= 8`).
    @Test func theRoutedRectangleReachesADepartedDestination() {
        var reaching = 0
        // R2: bounded by the rectangle's own 40 cells.
        for cell in MeshRoutedConvergenceMatrix.all {
            let schedule = cell.schedule
            guard let branch = schedule.branches.firstIndex(where: {
                $0.contains(cell.overlay.origin)
            }) else { continue }
            if let departing = schedule.departingMember,
               schedule.branches[branch].contains(departing) == false {
                reaching += 1
                continue
            }
            if let removal = schedule.removal, removal.completes, removal.proposingBranch != branch {
                reaching += 1
            }
        }
        #expect(reaching > 0,
                "no cell of the rectangle can produce a destination the derived roster has dropped")
    }

    /// **The coverage wall, on the generated side.** The union of what the 40 overlays PLAN is the
    /// whole routed vocabulary — arithmetic over resolved values, not a second execution.
    ///
    /// Per-cell equality (`Set(executed) == overlay.fullHealTokens`) is asserted inside rectangle A
    /// and rectangle C, which is strictly stronger than a union: a union is satisfied if *some* cell
    /// emitted a token, while equality catches a cell that executed something it never planned.
    @Test func theRoutedRectangleEmitsEveryRoutedToken() {
        var planned: Set<String> = []
        // R2: bounded by the rectangle's own 40 cells.
        for cell in MeshRoutedConvergenceMatrix.all { planned.formUnion(cell.overlay.fullHealTokens) }
        // R2: bounded by rectangle C, itself a subset of the 40.
        for cell in MeshRoutedConvergenceMatrix.developing {
            planned.formUnion(cell.overlay.developmentTokens)
        }
        // R2: bounded by rectangle G's own 12 cells.
        for cell in MeshRoutedConvergenceMatrix.featureTree {
            planned.formUnion(cell.overlay.featureTokens)
        }
        #expect(planned == Set(MeshRoutedEventToken.vocabulary),
                "the rectangle plans a token it never runs, or runs one it never planned")
        #expect(MeshRoutedEventToken.vocabulary.count == MeshRoutedEventToken.allCases.count,
                "the vocabulary is the whole enum")
        // Per-cell, the union really is a union: each pipeline's bucket is inside `plannedTokens`,
        // which is what makes the three loops above a RESTRICTION of that value rather than a
        // different accounting of it.
        // R2: bounded by the rectangle's own 40 cells.
        for cell in MeshRoutedConvergenceMatrix.all {
            let overlay = cell.overlay
            let whole = overlay.plannedTokens
            let covered = overlay.fullHealTokens.isSubset(of: whole)
                && overlay.featureTokens.isSubset(of: whole)
                && (!overlay.develops || overlay.developmentTokens.isSubset(of: whole))
            #expect(covered, "a pipeline's token bucket escaped the per-cell union")
        }
    }

    /// **Rectangle G plans what it claims** — pure arithmetic over the twelve built overlays, with
    /// every threshold MEASURED from a probe run first and then pinned (D-14.2's lesson: seed-only
    /// salting once collapsed the 40-cell rectangle to 8 distinct plans with no multi-chunk cell at
    /// all, and it was found by a probe rather than by reasoning).
    @Test func theFeatureRectanglePlansWhatItClaims() {
        let tree = MeshRoutedConvergenceMatrix.featureTree
        #expect(tree.count == 12, "8 seeds on 2/2 plus the root seed on the other four shapes")
        #expect(Set(tree.map(\.shape)) == Set(MeshPartitionShape.matrix),
                "every shape §16.2 names carries a feature cell")
        #expect(tree.allSatisfy { MeshRoutedConvergenceMatrix.all.contains($0) },
                "the feature cells are selected from the rectangle, never drawn beside it")
        let overlays = tree.map(\.overlay)
        let resolved = tree.allSatisfy { cell in
            let survivors = Set(cell.schedule.survivors)
            return survivors.contains(cell.overlay.textOrigin)
                && survivors.contains(cell.overlay.heartOrigin)
                && survivors.contains(cell.overlay.heartRecipient)
        }
        #expect(resolved, "a feature field resolved to a member this cell does not leave alive")
        let planned = overlays.allSatisfy(\.plansHeart)
        #expect(planned, "survivors are never fewer than two here, so every cell plans a heart")
        #expect(overlays.contains { $0.ageGatedMember != nil },
                "no cell shuts a chat gate, so the age-gate half would never run")
        #expect(overlays.contains { !$0.heartRecipientForegrounded },
                "no cell defers a heart, so D-10.12's third leg would never run")
        #expect(Set(overlays.map(\.textRound)) == Set(0..<MeshScheduleBounds.maxFeatureRounds),
                "both feature rounds must carry a text, or the window is one round wide")
        #expect(Set(overlays.map(\.heartRound)) == Set(0..<MeshScheduleBounds.maxFeatureRounds),
                "and both must carry a heart")
        #expect(overlays.contains { $0.textRound == $0.heartRound },
                "both-in-one-round is unreached, so the window never interleaves at all")
        #expect(overlays.contains { $0.textRound != $0.heartRound },
                "and a round apart with it")
        // **Measured, then pinned.** Rectangle G's twelve reach `heart == text` and
        // `heart < text` and NOT `text < heart` (`logs/item9/subset-01.log` — the first pin was a
        // guess and it was wrong). Both draws are fields 10 and 14 over the whole 40-cell rectangle,
        // so the ordering that G's twelve miss is asserted where it is reachable rather than wished
        // for here: twelve independent ¼-chance cells miss it about 3% of the time.
        let whole = MeshRoutedConvergenceMatrix.all.map(\.overlay)
        #expect(whole.contains { $0.textRound < $0.heartRound },
                "text-then-heart is unreached across all 40, so the interleaving is not a draw")
        #expect(whole.contains { $0.heartRound < $0.textRound }, "and heart-then-text with it")
    }

    /// **The whole 40-cell rectangle's feature fields are total functions** — the claim rectangle G
    /// itself cannot make, because it runs only twelve of them.
    ///
    /// Every overlay in the file is built for every cell (the coverage wall reads all 40), so a
    /// field that resolved to a non-survivor on cell 37 would be a latent trap for whatever later
    /// rectangle reaches it. Survivors are ≥ 2 on all 40 — `preferQuorum` is fixed false for routed
    /// cells, so `removal.completes` is always false and `planDeparture` refuses below three — which
    /// is what makes `plansHeart` universally true and `heartRecipient != heartOrigin` total.
    @Test func everyOverlaysFeatureFieldsResolveOnEveryCell() {
        // R2: bounded by the rectangle's own 40 cells.
        for cell in MeshRoutedConvergenceMatrix.all {
            let overlay = cell.overlay
            let survivors = Set(cell.schedule.survivors)
            #expect(survivors.count >= 2, "a routed cell with one survivor converges nothing")
            let inside = survivors.contains(overlay.textOrigin)
                && survivors.contains(overlay.heartOrigin)
                && survivors.contains(overlay.heartRecipient)
            #expect(inside, "a feature field resolved outside this cell's own survivors")
            #expect(overlay.heartRecipient != overlay.heartOrigin,
                    "a heart addressed to its own origin plans nothing")
            #expect(overlay.ageGatedMember != overlay.textOrigin,
                    "a gated ORIGIN mints nothing, which would make the text half green over nothing")
            let bounded = overlay.textRound < MeshScheduleBounds.maxFeatureRounds
                && overlay.heartRound < MeshScheduleBounds.maxFeatureRounds
            #expect(bounded, "a feature round outside the window it is an index into")
        }
    }
}

// MARK: - MeshRoutedOverlayFixtures

/// Overlays for the three named cells that drive one seam deliberately rather than by draw.
///
/// They exist so ``MeshConvergenceRun/routedInvariants(_:_:audited:overlay:before:)`` stays the
/// **only** entry point: a relaxed variant is exactly what item 7 deleted from P4, and item 14 does
/// not reintroduce the shape. Each fixture describes what its cell really did, so the invariants
/// judge that cell on its own plan.
nonisolated enum MeshRoutedOverlayFixtures {

    /// The lock-window cell's plan: the window runs at the ORIGIN, so no non-origin subject exists.
    static func lockOnly(_ seed: UInt64, origin: Int) -> MeshRoutedScheduleOverlay {
        base(seed, origin: origin, lockMember: origin)
    }

    /// The replay cell's plan.
    static func replayOnly(_ seed: UInt64, origin: Int) -> MeshRoutedScheduleOverlay {
        base(seed, origin: origin, replays: true)
    }

    /// The TEXT half of one feature cell, as the invariants must judge it: a full-roster item with
    /// one drawn gated receiver and no heart (P6 item 9).
    ///
    /// The gate is carried because §2c's own claim is that the gated member holds the ciphertext and
    /// projects nothing — it is not an excuse for an outstanding leg, and no invariant reads it as
    /// one; `routedPlantedFingerprints` deliberately still names only the capacity and unknown-type
    /// subjects.
    static func textOnly(_ seed: UInt64, origin: Int, gated: Int?) -> MeshRoutedScheduleOverlay {
        base(seed, origin: origin, textOrigin: origin, ageGatedMember: gated)
    }

    /// The HEART half of one feature cell: a one-destination item whose recipient may have been
    /// deliberately left asleep (P6 item 9).
    ///
    /// - Parameters:
    ///   - seed: The cell's seed, so a failure names its own replay.
    ///   - origin: The heart's origin.
    ///   - recipient: Its single destination.
    ///   - deferredRecipient: The recipient when this cell withheld its foreground, else nil — the
    ///     ONE thing allowed to excuse an outstanding heart leg.
    static func heartOnly(
        _ seed: UInt64, origin: Int, recipient: Int, deferredRecipient: Int?
    ) -> MeshRoutedScheduleOverlay {
        base(
            seed, origin: origin, textOrigin: origin, heartOrigin: origin,
            heartRecipient: recipient, heartRecipientForegrounded: deferredRecipient == nil
        )
    }

    /// The inert plan every fixture above varies one or two fields of.
    ///
    /// The feature fields default to "plans nothing": `textOrigin == origin`, no gate, and
    /// `heartRecipient == heartOrigin`, i.e. `plansHeart == false` — so rectangles A, B and C, whose
    /// pipelines never run a feature round, behave EXACTLY as they did before P6 item 9 appended
    /// the fields.
    private static func base(
        _ seed: UInt64, origin: Int, lockMember: Int? = nil, replays: Bool = false,
        textOrigin: Int? = nil, ageGatedMember: Int? = nil,
        heartOrigin: Int? = nil, heartRecipient: Int? = nil,
        heartRecipientForegrounded: Bool = true
    ) -> MeshRoutedScheduleOverlay {
        MeshRoutedScheduleOverlay(
            seed: seed, origin: origin, chunks: 1, sealed: false, capacityMember: nil,
            lockMember: lockMember, replays: replays, develops: false, unknownTypeMember: nil,
            farBranchMint: false,
            textOrigin: textOrigin ?? origin, textRound: 0, ageGatedMember: ageGatedMember,
            heartOrigin: heartOrigin ?? origin, heartRecipient: heartRecipient ?? origin,
            heartRound: 0, heartRecipientForegrounded: heartRecipientForegrounded
        )
    }
}
