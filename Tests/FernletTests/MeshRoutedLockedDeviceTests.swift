// MeshRoutedLockedDeviceTests.swift
// FernletTests
//
// Network migration P5 item 10 (plan §11 "locked device", §19.5, invariant 7): ciphertext-only
// custody under a lock, the one pushed gate that decides whether PLAINTEXT may exist, and the
// re-entry an unlock, a foreground or a cleared duress session owes.
//
// The finding this suite is written against: after the first post-boot unlock a locked device's
// routed store is **`loaded`** — the seal key is `AfterFirstUnlockThisDeviceOnly` and the files are
// `…UntilFirstUserAuthentication` — so custody, custody receipts and photo/text recipient receipts
// already work with the screen off. `MeshRoutedAccessGate` is therefore NOT a proxy for store
// readability: the store answers readability itself, in five states, and the gate answers a
// different question. Both halves are asserted here, and their orthogonality is itself a cell (T2
// drives the gate with the store sealable; T3/T4 drive the store's states with the gate untouched).
//
// Tier 1 throughout: `MeshRoutedDrainRig` on `FakePeerNetwork`, an injected clock, no radio and no
// wall-clock sleeps. `DeviceBindingID.$testOverride` drives the STORE's states (`.readError` ⇒
// deferred, `.unavailable` ⇒ seal-refused, `.identifier(install)` ⇒ loaded) and
// `applyRoutedAccessGate(_:now:)` drives the GATE — deliberately two independent knobs.
//
// The audit log is process-global and suites run in parallel (D-8.31), so every claim about a
// logged line is a **containment** claim, and every claim about a state is made against this rig's
// own store as well.

import CryptoKit
import Foundation
import Security
import Testing
@testable import FernletCrypto
import FernletDomainModel
import FernletFoundation
@testable import ProximityKit
@testable import Fernlet

/// The error a locked keychain surfaces to a content-key unwrap — T9's stand-in for "the identity
/// key could not be read", which must reach the caller verbatim rather than as a wrap failure.
private struct MeshRoutedLockedKeychainError: Error, Equatable {}

// MARK: - The locked device

/// Locked-device handling end to end: the gate's truth table, the five store states at the routed
/// doors, and the re-entry.
@MainActor
@Suite(.serialized)
struct MeshRoutedLockedDeviceTests {

    /// An unlocked, foregrounded device with no duress session — the only value that opens the gate.
    private static let openGate = MeshRoutedAccessGate(
        protectedDataAvailable: true, appIsForeground: true, duressActive: false
    )

    /// Data protection available while the app is BACKGROUNDED — the unlock edge that fires with no
    /// scene change, and the one the ciphertext jobs must still run on.
    private static let unlockedBackground = MeshRoutedAccessGate(
        protectedDataAvailable: true, appIsForeground: false, duressActive: false
    )

    /// A duress session, every other fact unchanged.
    private static let duressedGate = MeshRoutedAccessGate(
        protectedDataAvailable: true, appIsForeground: true, duressActive: true
    )

    /// Pushes one gate value under a chosen install binding — the app's seam, driven directly.
    ///
    /// `now` and `binding` are resolved in the body: a `@MainActor` static cannot be a
    /// default-argument value under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
    @discardableResult
    private func push(
        _ gate: MeshRoutedAccessGate,
        into manager: MeshNetworkManager,
        now: Date? = nil,
        binding: DeviceBindingID.TestOverride? = nil
    ) -> MeshRoutedReentryReport? {
        let now = now ?? MeshRoutedDrainRig.now
        let binding = binding ?? .identifier(MeshP3Acceptance.install)
        return DeviceBindingID.$testOverride.withValue(binding) {
            manager.applyRoutedAccessGate(gate, now: now)
        }
    }

    /// One node's raw routed load under a chosen override, so "which of the five states" is a
    /// separate claim from "what the doors did".
    private func load(
        _ rig: MeshRoutedDrainRig, _ node: Int, binding: DeviceBindingID.TestOverride
    ) -> MeshRoutedLoad {
        DeviceBindingID.$testOverride.withValue(binding) { rig.routedStore(rig.nodes[node]).load() }
    }

    /// Drives the routed ingest doors and the digest door at one node under `binding`: a manifest,
    /// every chunk, and one signed advertisement (which is also the claim + sweep entry).
    private func driveRoutedDoors(
        _ rig: MeshRoutedDrainRig,
        _ item: MeshRoutedDrainItem,
        at receiver: Int,
        binding: DeviceBindingID.TestOverride,
        now: Date
    ) throws {
        try rig.dispatch(
            MeshRoutedManifestPayload(manifest: item.manifest), type: .meshRoutedManifest,
            sender: 0, receiver: receiver, now: now, binding: binding
        )
        // R2: bounded by the item's own chunk count.
        for chunk in item.chunks {
            try rig.dispatch(
                MeshChunkPayload(chunk: chunk), type: .meshRoutedChunk,
                sender: 0, receiver: receiver, now: now, binding: binding
            )
        }
        let advertisement = try MeshRoutedInventoryPayload.signed(
            meshID: rig.meshID, index: MeshRoutedIndex(), sentAt: now, identity: rig.identities[0]
        )
        DeviceBindingID.$testOverride.withValue(binding) {
            rig.nodes[receiver].manager.receiveRoutedInventory(
                advertisement, from: rig.nodes[0].fingerprint, now: now
            )
        }
    }

    /// Every `state:` token the store's two suppression lines carried during a capture.
    private func suppressionStates(_ capture: MeshRoutedBackpressureAuditCapture) -> [String] {
        capture.values(of: "mesh.routedStore.readSuppressed", key: "state")
            + capture.values(of: "mesh.routedStore.sweepSuppressed", key: "state")
    }

    // MARK: - T1: the gate itself

    /// All eight fact combinations, all three capabilities: custody is never gated here, and the two
    /// plaintext capabilities are answered at the SAME strength.
    @Test func theGateTruthTableIsExhaustive() {
        var seen = 0
        // R2: three bounded two-valued loops — the whole product, by construction.
        for protectedData in [false, true] {
            for foreground in [false, true] {
                for duress in [false, true] {
                    let gate = MeshRoutedAccessGate(
                        protectedDataAvailable: protectedData, appIsForeground: foreground,
                        duressActive: duress
                    )
                    let open = protectedData && foreground && !duress
                    seen += 1
                    #expect(gate.permits(.sealCustody), "custody is ciphertext-only and never gated")
                    #expect(gate.permits(.decryptContent) == open, "decrypt must follow the gate")
                    #expect(gate.permits(.mutateCanonicalStore) == open,
                            "a plaintext write is not a weaker act than a plaintext read")
                    #expect(gate.isOpen == open, "isOpen must be the conjunction of the three facts")
                }
            }
        }
        #expect(seen == 8, "the truth table did not cover the whole product")
        #expect(MeshRoutedCapability.allCases.count == 3, "a capability was added without an answer")
        #expect(MeshRoutedAccessGate.closed.isOpen == false, "the initial value must fail closed")
    }

    // MARK: - T2/T5: custody under a closed gate

    /// **The locked-device feature, positively.** With the gate CLOSED and the store sealable — the
    /// real post-first-unlock locked device — a photo's manifest, every chunk, the custody receipt
    /// and this device's own recipient receipt all land. The gate changed nothing about custody.
    @Test func custodyProceedsWhileLockedButSealable() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "lock-custody")
        defer { rig.teardown() }
        let item = try MeshRoutedDrainItem.mint(
            rig, origin: 0, typeToken: MeshRoutedTypeToken.tempMessage
        )
        item.stage(into: rig, at: 0)
        rig.link(0, 1)
        let destination = rig.nodes[1]
        #expect(push(.closed, into: destination.manager) == nil,
                "the manager starts fail-closed, so pushing closed moves no leg")
        #expect(destination.manager.routedAccessGate.isOpen == false, "the gate must be closed here")
        #expect(destination.manager.mayDecryptRoutedContent == false, "nothing may be decrypted")

        rig.commit(0, 1)
        try await rig.settle(until: {
            rig.routedIndex(destination)?.record(for: item.key)?.recipientReceipts.isEmpty == false
        })

        let record = try #require(rig.routedIndex(destination)?.record(for: item.key))
        #expect(record.chunks.count == item.chunks.count, "the ciphertext did not land")
        #expect(record.custodiedAt != nil, "durable ciphertext custody is not gated by the lock")
        #expect(record.recipientReceipts.contains { $0.recipientFingerprint == destination.fingerprint },
                "a photo/text item is final on durable ciphertext, locked or not")
        #expect(record.deliveryTarget?.state(of: destination.fingerprint) == .delivered,
                "the rung must reach delivered under a closed gate")
    }

    /// **The two stages under ONE gate.** A heart stops at `custodied(by: self)` with its shortfall
    /// named, the heart ledger is untouched, and the photo beside it is still final on ciphertext.
    @Test func aClosedGateDecryptsNothingAndMutatesNoCanonicalStore() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "lock-stages")
        defer { rig.teardown() }
        let heart = try MeshRoutedDrainItem.mint(
            rig, origin: 0, typeToken: MeshRoutedTypeToken.heart
        )
        let photo = try MeshRoutedDrainItem.mint(rig, origin: 0)
        heart.stage(into: rig, at: 0)
        photo.stage(into: rig, at: 0)
        rig.link(0, 1)
        let destination = rig.nodes[1]
        let hearts = destination.store.heartLedger.receivedHearts.count
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }

        rig.commit(0, 1)
        try await rig.settle(until: {
            rig.routedIndex(destination)?.record(for: photo.key)?.recipientReceipts.isEmpty == false
                && rig.routedIndex(destination)?.record(for: heart.key)?.custodiedAt != nil
        })

        let held = try #require(rig.routedIndex(destination)?.record(for: heart.key))
        #expect(held.custodiedAt != nil, "the heart's ciphertext is custodied all the same")
        #expect(held.deliveredAt == nil, "a heart is not final without a foreground ledger commit")
        #expect(held.recipientReceipts.isEmpty, "no receipt may be minted for an unjudged heart")
        #expect(destination.store.heartLedger.receivedHearts.count == hearts,
                "a closed gate mutated a canonical store")
        #expect(capture.values(of: "mesh.routedDrain.deliveryPending", key: "shortfall")
                .contains(MeshRoutedAckShortfall.ledgerJudgementMissing.diagnosticDescription),
                "the heart's shortfall was not named")
        #expect(rig.routedIndex(destination)?.record(for: photo.key)?.deliveredAt != nil,
                "the photo stage must still be final on durable ciphertext")
    }

    // MARK: - T3/T4: the five states at the doors

    /// **Deferred is not empty.** Every routed door reached with a `deferred` store writes nothing,
    /// acknowledges nothing and leaves a pre-planted index byte-identical — and says so by name.
    @Test func everyRoutedDoorAnswersDeferredWithoutWritingOrAcknowledging() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "lock-deferred")
        defer { rig.teardown() }
        let planted = try MeshRoutedDrainItem.mint(rig, origin: 0)
        let offered = try MeshRoutedDrainItem.mint(rig, origin: 0)
        planted.stage(into: rig, at: 1)
        rig.link(0, 1)
        let scope = rig.nodes[1].store.meshRoutedStorage
        let before = MeshRoutedStoreFixtures.snapshot(scope)
        #expect(before.isEmpty == false, "the cell needs a planted index, or nothing is at risk")
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        let sentBefore = rig.tokens(at: 0, from: 1).count

        try driveRoutedDoors(rig, offered, at: 1, binding: .readError, now: MeshRoutedDrainRig.now)

        guard case .deferred = load(rig, 1, binding: .readError) else {
            Issue.record("the cell did not reach the deferred state at all")
            return
        }
        #expect(MeshRoutedStoreFixtures.snapshot(scope) == before, "a deferred store was written to")
        #expect(rig.routedIndex(rig.nodes[1])?.record(for: offered.key) == nil,
                "a deferred store admitted an item, so something was acknowledged for lost state")
        #expect(rig.routedIndex(rig.nodes[1])?.record(for: planted.key) != nil,
                "the planted item must survive — deferred is never read as empty")
        #expect(rig.nodes[1].manager.routedDeliveryHold == nil,
                "a deferred store is not a FULL one, and must raise no user-visible hold")
        #expect(rig.nodes[1].manager.lastDevelopmentHandoff == nil, "nothing was handed off here")
        #expect(rig.tokens(at: 0, from: 1).count == sentBefore,
                "a deferred store emitted a frame — nothing may be acknowledged on the wire either")
        #expect(rig.routedIndex(rig.nodes[1])?.record(for: planted.key)?
                .deliveryTarget?.state(of: rig.nodes[1].fingerprint) != .delivered,
                "a deferred pass moved a rung to delivered")
        #expect(suppressionStates(capture).contains { $0.hasPrefix("deferred:") },
                "the doors went silent instead of naming the state")
    }

    /// **The fifth wrinkle.** The same pass under a seal REFUSAL names `refused:` at the same doors —
    /// a different answer from `deferred`, and still not "the field is empty".
    @Test func aSealRefusedStoreIsNotADeferredOneAndNeitherIsAbsent() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "lock-refused")
        defer { rig.teardown() }
        let planted = try MeshRoutedDrainItem.mint(rig, origin: 0)
        let offered = try MeshRoutedDrainItem.mint(rig, origin: 0)
        planted.stage(into: rig, at: 1)
        rig.link(0, 1)
        let scope = rig.nodes[1].store.meshRoutedStorage
        let before = MeshRoutedStoreFixtures.snapshot(scope)
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }

        try driveRoutedDoors(rig, offered, at: 1, binding: .unavailable, now: MeshRoutedDrainRig.now)

        guard case .refused = load(rig, 1, binding: .unavailable) else {
            Issue.record("the cell did not reach the seal-refused state at all")
            return
        }
        guard case .deferred = load(rig, 1, binding: .readError) else {
            Issue.record("the two states are supposed to be reachable independently")
            return
        }
        #expect(MeshRoutedStoreFixtures.snapshot(scope) == before,
                "a refusal wrote to the store — the field may be full, and it is not empty")
        #expect(rig.routedIndex(rig.nodes[1])?.record(for: offered.key) == nil,
                "a refusing store admitted an item")
        #expect(suppressionStates(capture).contains { $0.hasPrefix("refused:") },
                "a refusal was not named as one")
    }

    // MARK: - T6/T13/T14: the edge

    /// One closed→open push runs the pass **once** and reports it; an identical second push moves no
    /// leg, returns nil and logs nothing.
    @Test func theReentryRunsEachActionOnceAndIsIdempotent() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "lock-reentry")
        defer { rig.teardown() }
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        let manager = rig.nodes[1].manager

        let first = try #require(push(Self.openGate, into: manager), "a rising edge owes a pass")

        #expect(first.legs.protectedDataRose, "the data-protection leg rose")
        #expect(first.legs.foregroundRose, "the foreground leg rose")
        #expect(first.legs.duressCleared == false, "no duress session was active")
        #expect(capture.count(of: "mesh.routedAccess.reentry") == 1, "the pass ran more than once")
        #expect(capture.count(of: "mesh.routedAccess.gateChanged") == 1, "the change logged twice")

        #expect(push(Self.openGate, into: manager) == nil, "an unchanged push must do nothing")
        #expect(capture.count(of: "mesh.routedAccess.reentry") == 1, "an unchanged push ran a pass")
        #expect(capture.count(of: "mesh.routedAccess.gateChanged") == 1, "an unchanged push logged")
        #expect(manager.routedAccessGate == Self.openGate, "the pushed value must be the stored one")
    }

    /// **The falling leg is observable.** The two protected-data notifications carry the fact
    /// literally, so a lock/unlock pair is exactly one falling and one rising edge — and one pass.
    /// This is the cell that fails if the app ever re-reads `isProtectedDataAvailable` inside the
    /// will-become-unavailable handler, where it still answers `true`.
    @Test func aWillUnavailableDidAvailablePairProducesExactlyOneRisingEdge() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "lock-pair")
        defer { rig.teardown() }
        let manager = rig.nodes[1].manager
        push(Self.openGate, into: manager)
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }

        let locked = MeshRoutedAccessGate(
            protectedDataAvailable: false, appIsForeground: true, duressActive: false
        )
        #expect(push(locked, into: manager) == nil, "a falling leg owes no pass")
        #expect(manager.routedAccessGate.protectedDataAvailable == false,
                "the falling leg never reached the stored value")
        #expect(manager.mayDecryptRoutedContent == false, "a locked device may decrypt nothing")

        let report = try #require(
            push(Self.openGate, into: manager), "the unlock edge owes the pass"
        )
        #expect(report.legs.protectedDataRose, "the unlock leg must be the one that rose")
        #expect(report.legs.foregroundRose == false, "the scene never moved in this pair")
        #expect(capture.count(of: "mesh.routedAccess.reentry") == 1,
                "a lock/unlock pair must produce exactly one pass")
    }

    /// **Duress is the third leg.** It closes the gate with no scene and no lock transition, owes no
    /// pass on its rising edge, and its CLEARING runs a pass whose only job is the heart stage.
    @Test func duressClosesTheGateWithNoSceneChangeAndItsClearingReEvaluatesTheHeartStage() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "lock-duress")
        defer { rig.teardown() }
        let heart = try MeshRoutedDrainItem.mint(rig, origin: 0, typeToken: MeshRoutedTypeToken.heart)
        heart.stage(into: rig, at: 1)
        let manager = rig.nodes[1].manager
        push(Self.openGate, into: manager)
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }

        #expect(push(Self.duressedGate, into: manager) == nil,
                "a duress session opens no store that was not already open")
        #expect(manager.mayDecryptRoutedContent == false, "duress must close the decrypt predicate")
        #expect(manager.mayMutateCanonicalStoreWithRoutedContent == false,
                "duress must close the canonical-mutation predicate")
        #expect(manager.mayCommitRoutedHeartLedgerJudgement == false,
                "and the heart stage with them")

        let report = try #require(
            push(Self.openGate, into: manager), "a cleared duress session owes the pass"
        )
        #expect(report.legs.duressCleared, "the clearing leg must be the one that moved")
        #expect(report.legs.isRising == false, "no ciphertext leg moves when duress clears")
        #expect(report.restoredSession == false, "a duress fall owes no session restore")
        #expect(report.committedCustodyCount == 0, "a duress fall owes no custody commit")
        #expect(report.sweptPeerCount == 0, "a duress fall owes no sweep")
        #expect(report.heartsPending == 1, "the pending heart must be counted")
        #expect(capture.count(of: "mesh.routedAccess.heartStageEvaluable") == 1,
                "the heart stage was not re-evaluated when duress cleared")
    }

    // MARK: - T11: the heart stage's own predicate

    /// The heart stage is evaluable only behind the whole gate: a rising data-protection leg with
    /// the app still backgrounded counts the hearts and DEFERS them; the foreground edge evaluates.
    /// Neither branch commits anything — P6 owns the unwrap and the ledger commit.
    @Test func theHeartStageIsOnlyEvaluableBehindTheOneGate() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "lock-heartstage")
        defer { rig.teardown() }
        let heart = try MeshRoutedDrainItem.mint(rig, origin: 0, typeToken: MeshRoutedTypeToken.heart)
        heart.stage(into: rig, at: 1)
        let manager = rig.nodes[1].manager
        #expect(manager.sessionState == .activeForeground, "the rig's nodes are in a live session")
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }

        let deferredPass = try #require(
            push(Self.unlockedBackground, into: manager), "an unlock owes the pass even backgrounded"
        )
        #expect(deferredPass.heartsPending == 1, "the pending heart must be counted")
        #expect(manager.mayCommitRoutedHeartLedgerJudgement == false,
                "a backgrounded app may not commit a ledger judgement")
        #expect(capture.count(of: "mesh.routedAccess.heartStageDeferred") == 1,
                "the deferred heart stage was not named")

        let openPass = try #require(push(Self.openGate, into: manager), "the foreground edge rose")
        #expect(openPass.heartsPending == 1, "the same heart is still pending")
        #expect(manager.mayCommitRoutedHeartLedgerJudgement, "the whole gate is open now")
        #expect(capture.count(of: "mesh.routedAccess.heartStageEvaluable") == 1,
                "the heart stage was not evaluated behind an open gate")
        let record = try #require(rig.routedIndex(rig.nodes[1])?.record(for: heart.key))
        #expect(record.deliveredAt == nil, "item 10 must commit no heart — that is P6's")
        #expect(record.recipientReceipts.isEmpty, "and mint no receipt for one")
    }

    // MARK: - T15/T8: the sweep budget

    /// **The re-entry never pre-empts the drain-exchange seam.** With the store `.loaded` throughout,
    /// a gate edge spends no peer's once-per-session capacity sweep, and the peer's own exchange
    /// still spends it afterwards.
    @Test func aReentryOnAnAlwaysLoadedStoreLeavesTheDrainSweepBudgetAvailable() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "lock-budget")
        defer { rig.teardown() }
        // A LOADED store, deliberately: an `.absent` one suppresses nothing and spends nothing, so a
        // cell run against it would prove neither half.
        try MeshRoutedDrainItem.mint(rig, origin: 0).stage(into: rig, at: 1)
        let manager = rig.nodes[1].manager
        let peer = rig.nodes[0].fingerprint

        let report = try #require(push(Self.openGate, into: manager), "the rising edge owes a pass")
        #expect(report.sweptPeerCount == 0, "the re-entry spent a budget nothing had suppressed")
        #expect(manager.routedSweptFingerprintsForTesting.isEmpty,
                "the drain-exchange seam's budget must still be unspent")
        #expect(manager.routedSweepsDeferredFingerprintsForTesting.isEmpty,
                "a loaded store suppresses no sweep at all")

        let advertisement = try MeshRoutedInventoryPayload.signed(
            meshID: rig.meshID, index: MeshRoutedIndex(), sentAt: MeshRoutedDrainRig.now,
            identity: rig.identities[0]
        )
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            manager.receiveRoutedInventory(advertisement, from: peer, now: MeshRoutedDrainRig.now)
        }
        #expect(manager.routedSweptFingerprintsForTesting.contains(peer),
                "the peer's own exchange must still perform its sweep")
    }

    /// A sweep a NON-loaded store took away is recorded, and the re-entry spends exactly that one.
    @Test func aSweepSuppressedByADeferredStoreIsSpentAtTheReentry() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "lock-sweep")
        defer { rig.teardown() }
        let planted = try MeshRoutedDrainItem.mint(rig, origin: 0)
        planted.stage(into: rig, at: 1)
        let manager = rig.nodes[1].manager
        let peer = rig.nodes[0].fingerprint
        let advertisement = try MeshRoutedInventoryPayload.signed(
            meshID: rig.meshID, index: MeshRoutedIndex(), sentAt: MeshRoutedDrainRig.now,
            identity: rig.identities[0]
        )

        DeviceBindingID.$testOverride.withValue(.readError) {
            manager.receiveRoutedInventory(advertisement, from: peer, now: MeshRoutedDrainRig.now)
        }
        #expect(manager.routedSweptFingerprintsForTesting.contains(peer) == false,
                "a deferred store must not spend the peer's budget")
        #expect(manager.routedSweepsDeferredFingerprintsForTesting.contains(peer),
                "the suppressed sweep was not recorded, so the re-entry can never repay it")

        let report = try #require(push(Self.openGate, into: manager), "the unlock owes the pass")
        #expect(report.sweptPeerCount == 1, "the re-entry did not spend the suppressed sweep")
        #expect(manager.routedSweptFingerprintsForTesting.contains(peer),
                "the peer's sweep must now be recorded as spent")
        #expect(manager.routedSweepsDeferredFingerprintsForTesting.contains(peer) == false,
                "a spent sweep must leave the deferred set")
    }

    // MARK: - T16: the session-restore guard

    /// **Job 1's `.idle` guard.** A gate edge during a LIVE session retries no restore — the launch
    /// restore re-arms the session ceiling and re-assigns the epoch heads before the state machine's
    /// `restoreOnlyFromIdle` refusal is reached, so a mid-session retry would re-grant the
    /// manipulation-resistant half of the ceiling and only then be told no.
    ///
    /// Non-vacuous by construction: a retryable outcome is planted first, so the retry would really
    /// fire if the guard were removed.
    @Test func aReentryDuringALiveSessionDoesNotReArmTheSessionCeiling() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "lock-restore")
        defer { rig.teardown() }
        let node = rig.nodes[1]
        let created = MeshRoutedDrainRig.createdAt
        let context = MeshSessionContext(
            meshID: UUID(),
            protocolVersion: 3,
            createdAt: created,
            hardDeadline: created.addingTimeInterval(MeshSessionCeiling.ceilingSeconds)
        )
        try MeshSessionStoreFixtures.save(
            context, into: MeshSessionStore(scope: node.store.meshSessionStorage),
            install: MeshP3Acceptance.install
        )
        let deferredOutcome = DeviceBindingID.$testOverride.withValue(.readError) {
            node.manager.restoreSessionContextAtLaunch(now: MeshRoutedDrainRig.now)
        }
        #expect(deferredOutcome.isRetryable, "the cell needs a retryable restore, or it proves nothing")
        #expect(node.manager.sessionState == .activeForeground, "and a live session to guard against")
        let heads = node.manager.knownEpochHeads

        let report = try #require(push(Self.openGate, into: node.manager), "the unlock owes a pass")

        #expect(report.restoredSession == false, "a mid-session edge retried the launch restore")
        #expect(node.manager.sessionCeiling == nil,
                "the launch restore re-armed the ceiling inside a live session")
        #expect(node.manager.knownEpochHeads == heads, "and re-assigned the epoch heads")
        #expect(node.manager.sessionState == .activeForeground, "the live session must be untouched")
    }

    // MARK: - T7/T17: the durable retries

    /// **The restart between a claim and its commit.** The commit queue is memory-only and dies with
    /// the process — fail-closed, no receipt — and the durable RUNG is what the re-entry recovers
    /// from.
    ///
    /// The one sanctioned exception to "a distinct identity per manager": a relaunch is one device,
    /// and `itemsWithUncommittedOwnCustody(at:for:)` keys on the local fingerprint, so a fresh
    /// identity would make this cell prove nothing. The rig keeps the store alive for the process.
    @Test func aRestartBetweenClaimAndCommitIsFailClosedAndRecoversAtReentry() async throws {
        let rig = try MeshRoutedDrainRig.build(3, label: "lock-restart")
        defer { rig.teardown() }
        let item = try MeshRoutedDrainItem.mint(rig, origin: 0)
        item.stage(into: rig, at: 1)
        let courier = rig.nodes[1]
        let store = rig.routedStore(courier)
        var index = try #require(rig.routedIndex(courier), "the courier must hold the bytes")
        var record = try #require(index.record(for: item.key))
        #expect(record.custodiedAt == nil, "a staged item is not yet custodied")
        record.delivery = MeshRoutedDeliveryRecord(
            contentID: try #require(record.deliveryTarget?.contentID),
            progress: [rig.nodes[2].fingerprint: MeshRoutedDeliveryProgress(
                .custodied(by: courier.fingerprint)
            )]
        )
        index = MeshRoutedIndex(items: [record])
        try MeshRoutedStoreFixtures.save(index, into: store, install: MeshP3Acceptance.install)

        let reborn = MeshNetworkManager(
            store: courier.store, transport: FakeMeshTransportSession(),
            identity: rig.identities[1]
        )
        #expect(reborn.deferredCustodyCommitCountForTesting == 0,
                "the memory-only queue must not survive a restart")
        #expect(rig.routedIndex(courier)?.record(for: item.key)?.custodiedAt == nil,
                "and nothing may be acknowledged for it before the recovery runs")

        let report = try #require(push(Self.openGate, into: reborn), "the unlock owes the pass")

        #expect(report.committedCustodyCount == 1, "the durable rung was not recovered")
        #expect(rig.routedIndex(courier)?.record(for: item.key)?.custodiedAt != nil,
                "custody was never committed, so no receipt can honestly be minted")
        // A second RISING edge, which needs a falling leg first: re-pushing the same value moves
        // nothing and would return nil for a reason that has nothing to do with the recovery.
        push(
            MeshRoutedAccessGate(
                protectedDataAvailable: false, appIsForeground: true, duressActive: false
            ),
            into: reborn
        )
        let again = try #require(push(Self.openGate, into: reborn), "the second unlock owes a pass")
        #expect(again.committedCustodyCount == 0, "a committed item must never be re-streamed")
    }

    /// **R4's stranded own receipt.** A delivery whose ack instant was stamped and whose receipt
    /// then failed to store is otherwise recoverable only by a peer's re-send; the re-entry files it,
    /// and sends nothing.
    @Test func aStampedDeliveryWhoseReceiptDidNotStoreIsFiledAtTheReentry() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "lock-stranded")
        defer { rig.teardown() }
        let item = try MeshRoutedDrainItem.mint(rig, origin: 0)
        item.stage(into: rig, at: 1)
        let destination = rig.nodes[1]
        let store = rig.routedStore(destination)
        var record = try #require(rig.routedIndex(destination)?.record(for: item.key))
        record.deliveredAt = MeshRoutedDrainRig.now
        try MeshRoutedStoreFixtures.save(
            MeshRoutedIndex(items: [record]), into: store, install: MeshP3Acceptance.install
        )
        let index = try #require(rig.routedIndex(destination))
        #expect(index.itemsAwaitingLocalAck(
            at: MeshRoutedDrainRig.now, for: destination.fingerprint
        ).count == 1, "the retry list must name the stranded item, or nothing can file it")
        let sentBefore = rig.tokens(at: 0, from: 1).count

        let report = try #require(
            push(Self.openGate, into: destination.manager), "the unlock owes the pass"
        )

        #expect(report.acksFiled == 1, "the stranded receipt was not filed")
        let filed = try #require(rig.routedIndex(destination)?.record(for: item.key))
        #expect(filed.recipientReceipts.contains { $0.recipientFingerprint == destination.fingerprint },
                "this device's own recipient receipt is still missing")
        #expect(filed.deliveryTarget?.state(of: destination.fingerprint) == .delivered,
                "the rung must read delivered once the receipt is filed")
        #expect(rig.tokens(at: 0, from: 1).count == sentBefore,
                "the re-entry sent a frame — the next exchange forwards, it does not broadcast")
    }

    // MARK: - T9/T10: the keychain, unweakened

    /// A keychain failure under a lock reaches the caller **verbatim**, never as
    /// `MeshRoutedKeyWrapError.openFailed` — which is the permanent "these bytes are wrong" answer
    /// and would turn a deferral into a discard.
    @Test func aKeychainFailureUnderLockIsADeferralNotARefusal() throws {
        let origin = try MeshPartitionFixtures.identity("lock-wrap-origin")
        let recipient = try MeshPartitionFixtures.identity("lock-wrap-recipient")
        let binding = MeshRoutedWrapBinding(
            meshID: MeshRoutedManifestFixtures.meshID,
            itemID: MeshRoutedManifestFixtures.itemID,
            originFingerprint: origin.localFingerprint
        )
        let wrapped = try MeshRoutedContentKeyWrapper.wrap(
            contentKey: MeshRoutedContentKeyWrapper.makeContentKey(),
            recipientFingerprint: recipient.localFingerprint,
            recipientKeyAgreementPublicKey: recipient.localKeyAgreementPublicKey,
            binding: binding
        )

        #expect(throws: MeshRoutedLockedKeychainError.self) {
            try MeshRoutedContentKeyWrapper.unwrap(
                wrapped,
                binding: binding,
                localFingerprint: recipient.localFingerprint,
                localKeyAgreementPublicKey: recipient.localKeyAgreementPublicKey,
                staticAgreement: { _ in throw MeshRoutedLockedKeychainError() }
            )
        }
    }

    /// The routed seal key stays `AfterFirstUnlockThisDeviceOnly` and never synchronizable.
    ///
    /// Strengthening it to `WhenUnlockedThisDeviceOnly` would make every background custody write
    /// unsealable — and an unsealable write is an unacknowledgeable one — which deletes the
    /// locked-device feature; weakening it to a syncable class is prohibited outright and would
    /// promise what the ciphertext cannot keep, since V3 authenticates a `ThisDeviceOnly` binding.
    @Test func theRoutedSealKeyStaysAfterFirstUnlockThisDeviceOnly() throws {
        let service = "com.fernlet.mesh-routed.test.lock.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: service) }
        guard case .available = MeshRoutedSealKey.forSeal(service: service) else {
            Issue.record("the routed seal key could not be minted on a per-test service")
            return
        }

        var result: AnyObject?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: MeshRoutedSealKey.keychainAccount,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
            kSecUseDataProtectionKeychain as String: true
        ]
        #expect(SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                "the minted row could not be read back")
        let attributes = result as? [String: Any]
        #expect(attributes?[kSecAttrAccessible as String] as? String
                == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
                "the routed seal key's accessibility class moved")
        #expect((attributes?[kSecAttrSynchronizable as String] as? NSNumber)?.boolValue != true,
                "the routed seal key must never synchronize")
    }
}

// MARK: - The source walls

/// The tripwires. Item 10 adds a predicate and a re-entry, not a decrypt: the enforcement that
/// matters is a wall that fails the moment P6 or item 13 adds a plaintext seam which does not name
/// the gate. Said plainly rather than dressed up — a tripwire plus a predicate, never a claim that
/// something is being blocked today.
@MainActor
extension MeshRoutedLockedDeviceTests {

    /// The ten files whose authority is the STORE's five states, never the access gate.
    private static let custodyDoorFiles = [
        "MeshRoutedStore.swift", "MeshRoutedCustody.swift", "MeshRoutedCustodyCommit.swift",
        "MeshRoutedIndex.swift", "MeshRoutedStoreKey.swift", "MeshRoutedContentHasher.swift",
        "MeshChunkAdmissionRule.swift", "MeshRoutedCustodyHandoff.swift",
        "MeshRoutedCapacity.swift", "MeshRoutedDeliveryHold.swift"
    ]

    /// Every `.swift` file under one repo-relative directory, comments stripped, sorted by name.
    ///
    /// Whole-line comments are removed so a wall states something about CODE rather than about the
    /// prose explaining why the code does not do a thing — this file's own subjects document
    /// themselves at length in exactly those terms.
    private static func codeSources(under relativePath: String) throws -> [(name: String, code: String)] {
        let root = RepoRoot.url(relativePath)
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        let files = (walker?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
        var sources: [(name: String, code: String)] = []
        // R2: bounded by the module's own file list.
        for file in files.sorted(by: { $0.path < $1.path }) {
            sources.append((
                file.lastPathComponent,
                MeshRoutedSourceScan.codeOnly(try String(contentsOf: file, encoding: .utf8))
            ))
        }
        return sources
    }

    /// How many times `needle` occurs in `haystack`.
    private static func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    /// **W1.** Each of the three predicates is defined exactly once in the whole package: one
    /// question, one answer, and no second definition to answer it more weakly.
    @Test func theAccessPredicatesEachHaveExactlyOneDefinition() throws {
        let sources = try Self.codeSources(under: "FernletKit/Sources")
        #expect(sources.count > 100, "the package source sweep found too few files")
        for predicate in ["var mayDecryptRoutedContent",
                          "var mayMutateCanonicalStoreWithRoutedContent",
                          "var mayCommitRoutedHeartLedgerJudgement"] {
            let defined = sources.reduce(0) { $0 + Self.occurrences(of: predicate, in: $1.code) }
            #expect(defined == 1, "a routed access predicate is defined other than exactly once")
        }
    }

    /// The three qualified spellings a real routed decrypt or heart judgement has to write, each
    /// with the one file it may legitimately appear in and the count pinned **there**. Everywhere
    /// else in `ProximityKit` the count is zero.
    ///
    /// Pinned counts rather than per-file containment alone, because containment cannot fire where
    /// such a seam would actually land: `MeshNetworkManager.swift` **defines** all three predicates,
    /// so a decrypt written there would name one by construction and pass a containment check
    /// automatically. A pin says the honest thing instead — *no such seam exists yet* — and fails
    /// the build on the first one, wherever it is written.
    ///
    /// The one non-zero pin is the stage precondition's own `guard case` in
    /// `MeshRoutedDeliveryCommit.stageShortfall`: the **reader** of the evidence, which judges
    /// nothing. A construction or a `evidence: .heartLedgerCommit(ack)` call site would be a second
    /// occurrence, and that is the event this pin exists to catch.
    private static let routedPlaintextSeams: [(needle: String, home: String, pinned: Int)] = [
        ("MeshRoutedContentKeyWrapper.unwrap(", "", 0),
        ("MeshRoutedHeartAck(", "", 0),
        (".heartLedgerCommit(", "MeshRoutedDeliveryCommit.swift", 1)
    ]

    /// The two files that name the heart evidence without judging anything: the enum's own
    /// declaration and the stage precondition that reads it.
    private static let heartEvidenceHomes: Set<String> =
        ["MeshRoutedAck.swift", "MeshRoutedDeliveryCommit.swift"]

    /// **W2.** No routed plaintext seam exists that does not name its predicate — and today none
    /// exists at all.
    ///
    /// Two halves. **The pin** (``routedPlaintextSeams``) counts every occurrence of the three
    /// qualified spellings across `FernletKit/Sources/ProximityKit` — the whole module, not just
    /// `Mesh/`, because `MeshRoutedContentKeyWrapper` and its `unwrap` are internal to all of it, so
    /// a decrypt under `HeartSharing/` or `Messaging/` would otherwise be invisible — and requires
    /// each to stand at its recorded number. **The containment half**
    /// (``expectPlaintextSeamsNameTheirPredicate(_:)``) is the rule P6 and item 13 inherit the day a
    /// pin legitimately rises. The scan keys on the qualified call because a bare `.unwrap(` also
    /// matches the app lock's own Secure Enclave wrap.
    @Test func everyRoutedPlaintextSeamNamesItsPredicate() throws {
        let sources = try Self.codeSources(under: "FernletKit/Sources/ProximityKit")
        #expect(sources.count >= 100, "the ProximityKit source sweep found too few files")
        // R2: three needles over the module's own bounded file list.
        for seam in Self.routedPlaintextSeams {
            var atHome = 0
            var elsewhere = 0
            for source in sources {
                let found = Self.occurrences(of: seam.needle, in: source.code)
                if source.name == seam.home { atHome += found } else { elsewhere += found }
            }
            #expect(elsewhere == 0, "a routed plaintext seam appeared outside its pinned home")
            #expect(atHome == seam.pinned, "a routed plaintext seam's pinned count moved")
        }
        Self.expectPlaintextSeamsNameTheirPredicate(sources)
    }

    /// W2's containment half: whoever moves a pin in ``routedPlaintextSeams`` must name the gating
    /// predicate in the same file — ``MeshNetworkManager/mayDecryptRoutedContent`` for a decrypt,
    /// ``MeshNetworkManager/mayCommitRoutedHeartLedgerJudgement`` for a heart judgement.
    ///
    /// Vacuous while every pin stands at its declaring home; the counts are what fires today. Note
    /// the deliberate pairing with W3(b), which exempts exactly the files this half matches — a new
    /// decrypting file MUST name the decrypt predicate here, so W3(b) may not forbid the token there.
    private static func expectPlaintextSeamsNameTheirPredicate(
        _ sources: [(name: String, code: String)]
    ) {
        // R2: bounded by the module's own file list.
        for source in sources where source.name != "MeshRoutedContentKeyWrapper.swift" {
            guard source.code.contains("MeshRoutedContentKeyWrapper.unwrap(") else { continue }
            #expect(source.code.contains("mayDecryptRoutedContent"),
                    "a routed decrypt appeared in a file that never names the decrypt predicate")
        }
        // R2: the same bound.
        for source in sources where !Self.heartEvidenceHomes.contains(source.name) {
            let mutates = source.code.contains("MeshRoutedHeartAck(")
                || source.code.contains(".heartLedgerCommit(")
            guard mutates else { continue }
            #expect(source.code.contains("mayCommitRoutedHeartLedgerJudgement"),
                    "a routed heart judgement appeared in a file that never names its predicate")
        }
    }

    /// **W3.** Custody's authority stays the store's five states.
    ///
    /// (a) no custody door names the gate, its predicates or the `sealCustody` case — a lock fact at
    /// a ciphertext door would delete the locked-device feature; (b) the vocabulary cannot spread:
    /// under the mesh directory the two tokens appear only in the manager and in the gate's own file
    /// (which is not a custody door, and necessarily contains `case .sealCustody` inside
    /// `permits(_:)`).
    ///
    /// **(b) exempts a file that performs a routed decrypt**, because W2's containment half
    /// *requires* such a file to name ``MeshNetworkManager/mayDecryptRoutedContent``. Without the
    /// exemption the two walls would be mutually unsatisfiable for the first real decrypt outside
    /// the manager — every new `Mesh/` file would fail one or the other, silently forcing every
    /// routed decrypt into `MeshNetworkManager.swift`. `routedAccessGate` itself stays confined: a
    /// decrypting file consults the manager's **predicate**, never the gate value.
    @Test func theCustodyDoorsNameNoAccessGate() throws {
        var scanned = 0
        for name in Self.custodyDoorFiles {
            let code = MeshRoutedSourceScan.codeOnly(
                try RepoRoot.source("FernletKit/Sources/ProximityKit/Mesh/\(name)")
            )
            scanned += 1
            for token in ["routedAccessGate", "mayDecryptRoutedContent",
                          "mayMutateCanonicalStoreWithRoutedContent", ".sealCustody"] {
                #expect(code.contains(token) == false, "a custody door consulted the access gate")
            }
        }
        #expect(scanned == Self.custodyDoorFiles.count, "the custody-door scan lost a file")

        let allowed: Set<String> = ["MeshRoutedAccessGate.swift", "MeshNetworkManager.swift"]
        for source in try Self.codeSources(under: "FernletKit/Sources/ProximityKit/Mesh")
        where !allowed.contains(source.name) {
            #expect(source.code.contains("routedAccessGate") == false,
                    "the gate's vocabulary spread beyond the manager and its own file")
            // The W2 exemption: a file W2's containment half already obliges to name the predicate
            // cannot also be forbidden from naming it.
            guard source.code.contains("MeshRoutedContentKeyWrapper.unwrap(") == false else { continue }
            #expect(source.code.contains("mayDecryptRoutedContent") == false,
                    "the decrypt predicate spread beyond the manager and the gate's own file")
        }
    }

    /// **W4.** No routed door collapses an outcome to a default.
    ///
    /// `.value ?? []` made a deferred store, a seal refusal and a genuinely receipt-less item
    /// produce one identical answer — invariant 7's failure mode expressed as a diagnostic.
    @Test func noRoutedDoorCollapsesAnOutcomeToADefault() throws {
        var found = 0
        for source in try Self.codeSources(under: "FernletKit/Sources/ProximityKit/Mesh") {
            found += Self.occurrences(of: ".value ??", in: source.code)
        }
        #expect(found == 0, "a routed door collapsed a five-state outcome into a default")
    }

    /// **W5.** The four keychain rows the whole lock story rests on still spell their class in
    /// source, so a "background decrypt would be convenient" patch cannot move one quietly. The
    /// answer to that request is **no**, never an accessibility change.
    @Test func theKeychainClassesTheLockStoryRestsOnAreNamedInSource() throws {
        let files = [
            "FernletKit/Sources/ProximityKit/Mesh/MeshRoutedStoreKey.swift",
            "FernletKit/Sources/ProximityKit/Mesh/MeshSessionKeyStore.swift",
            "FernletKit/Sources/FernletCrypto/DeviceBindingID.swift",
            "FernletKit/Sources/ProximityKit/Identity/IdentityService.swift"
        ]
        var scanned = 0
        for path in files {
            let code = MeshRoutedSourceScan.codeOnly(try RepoRoot.source(path))
            scanned += 1
            #expect(code.contains("kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly"),
                    "a row the locked-device story rests on no longer names its class")
        }
        #expect(scanned == files.count, "the keychain-class scan lost a file")
    }

    /// **W6.** The app pushes the gate from every site the three facts actually move at.
    ///
    /// Six call sites: the launch mount (`.onChange(of: scenePhase)` carries no `initial:`, and the
    /// loader becomes ready after the first activation), the two scene legs, the two protected-data
    /// notifications — which pass the fact **literally**, because `isProtectedDataAvailable` still
    /// answers `true` inside the will-become-unavailable handler — and duress, which moves at
    /// neither transition.
    @Test func theAppPushesTheGateFromEverySiteTheFactsMoveAt() throws {
        let code = MeshRoutedSourceScan.codeOnly(try RepoRoot.source("App/Fernlet/FernletApp.swift"))
        let calls = code.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.contains("pushRoutedAccessGate(") && !$0.contains("private func") }
        #expect(calls.count == 6, "the app pushes the routed access gate from the wrong number of sites")
        #expect(code.contains("protectedData: false"),
                "the will-become-unavailable handler must pass the fact literally")
        #expect(code.contains("protectedData: true"),
                "the did-become-available handler must pass the fact literally")
        #expect(code.contains("onChange(of: lockService.isDuressSessionActive)"),
                "duress moves at neither a scene nor a protected-data transition")
    }
}
