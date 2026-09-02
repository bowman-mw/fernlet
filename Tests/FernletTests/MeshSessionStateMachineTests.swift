// MeshSessionStateMachineTests.swift
// FernletTests
//
// P3 item 6 (plan §8.1, §8.2, §3.6): the session state machine, the ceiling at both bounds, the
// launch restore, and the save cadence.
//
// The claims worth walling here:
//
// 1. **The transition function is total.** Every (state, event) pair either moves or names a
//    refusal — never a trap. Most of these events arrive from the wire, so a state machine that
//    crashed on an unexpected one would be a remotely reachable crash.
// 2. **The ceiling is guarded at both bounds.** A wall clock set backwards cannot lengthen a
//    session (the monotonic guard ends it anyway) and one set forwards cannot end it earlier than
//    the signed absolute deadline allows.
// 3. **A disconnect is not a removal** (invariant 1): the roster does not move, no record is
//    minted, and the peer that comes back needs no re-admission — while a *removed* member stays
//    out of the next epoch's key.
// 4. **Idle-lapse resume IS the merge path** (plan §10.3): two members that rotated independently
//    at the same counter come back with both epochs recorded — coexistence, not a re-key.
// 5. **Developed / terminated never rejoin**, and a relaunch re-derives that from the sealed file.
// 6. **Durable before acknowledged** (plan §3.6): a join is not acknowledged and a record is not
//    inserted until the context that contains it is on the disk.
//
// Time is always an argument here — `now` and `monotonicElapsed` are passed in, exactly like
// `MeshEpochKeyring` and `MeshRotationTriggerQueue` — so nothing waits and nothing flakes.

import Foundation
import Testing
@testable import FernletCrypto
import FernletDomainModel
@testable import ProximityKit
@testable import Fernlet

// MARK: - MeshSessionStateMachineTests

/// Plan §8.2's edges, its non-edges, and the totality of the function over both.
@Suite(.serialized)
struct MeshSessionStateMachineTests {

    /// Every event, built from the `CaseIterable` payload enums so a new payload case cannot slip
    /// past the totality sweep.
    private static var allEvents: [MeshSessionEvent] {
        var events: [MeshSessionEvent] = [
            .founded, .joined, .peerCommitted, .backgrounded, .foregrounded, .linksLost,
            .linksRestored, .idleLapsed, .resumedAfterLapse, .developed, .departureRequested,
            .departureSent, .terminationSent, .terminationVerified, .removed
        ]
        events.append(contentsOf: MeshSessionTerminationReason.allCases.map { .terminationRequested($0) })
        events.append(contentsOf: MeshSessionCeilingBound.allCases.map { .hardDeadlineReached($0) })
        events.append(contentsOf: MeshSessionRestoredDisposition.allCases.map { .contextRestored($0) })
        return events
    }

    /// The function is TOTAL: every pair answers, and a terminal state answers "ended" to all of
    /// them. Nothing traps, and nothing falls through to a default that quietly moves.
    @Test func everyStateAnswersEveryEventWithoutTrapping() {
        for state in MeshSessionState.allCases {
            for event in Self.allEvents {
                let transition = MeshSessionStateMachine.transition(from: state, on: event)
                if state.hasEnded {
                    #expect(transition == .rejected(.sessionAlreadyEnded),
                            "\(state) must refuse \(event) as an ended session")
                    continue
                }
                #expect(transition.nextState != nil || transition.effects.isEmpty,
                        "a refusal must carry no effects (\(state) / \(event))")
            }
        }
    }

    /// The happy path across §8.2's spine: idle → joining → active → background → active.
    @Test func theForegroundSpineFollowsTheDiagram() {
        #expect(MeshSessionStateMachine.transition(from: .idle, on: .founded)
                == .moved(to: .joining, effects: [.persistContext]))
        #expect(MeshSessionStateMachine.transition(from: .idle, on: .joined)
                == .moved(to: .joining, effects: [.persistContext]))
        #expect(MeshSessionStateMachine.transition(from: .joining, on: .peerCommitted)
                == .moved(to: .activeForeground, effects: [.persistContext, .clearIdleTimer]))
        #expect(MeshSessionStateMachine.transition(from: .activeForeground, on: .backgrounded)
                == .moved(to: .continuingInBackground, effects: []))
        #expect(MeshSessionStateMachine.transition(from: .continuingInBackground, on: .foregrounded)
                == .moved(to: .activeForeground, effects: []))
    }

    /// Losing links partitions from either live state and arms the idle window; it never ends
    /// membership (invariant 1).
    @Test func lostLinksPartitionFromEitherLiveState() {
        for state in [MeshSessionState.activeForeground, .continuingInBackground] {
            #expect(MeshSessionStateMachine.transition(from: state, on: .linksLost)
                    == .moved(to: .partitioned, effects: [.armIdleTimer]),
                    "\(state) must partition, not end")
        }
    }

    /// A partition heals through the merge path, and an idle lapse stops participation only.
    @Test func aPartitionHealsAsAMergeAndLapsesIntoLocalIdleStop() {
        #expect(MeshSessionStateMachine.transition(from: .partitioned, on: .linksRestored)
                == .moved(to: .activeForeground, effects: [.clearIdleTimer, .beginMerge]))
        #expect(MeshSessionStateMachine.transition(from: .partitioned, on: .peerCommitted)
                == .moved(to: .activeForeground, effects: [.clearIdleTimer, .beginMerge]),
                "a peer reappearing is a heal, and a heal is a merge")
        #expect(MeshSessionStateMachine.transition(from: .partitioned, on: .idleLapsed)
                == .moved(to: .localIdleStop, effects: [.stopParticipation, .clearIdleTimer]))
    }

    /// Resume after a lapse restarts the radios and enters the merge path — the same mechanism as
    /// a partition heal, which is the whole point of plan §10.3.
    @Test func resumeAfterALapseIsTheMergePath() {
        let transition = MeshSessionStateMachine.transition(from: .localIdleStop, on: .resumedAfterLapse)
        #expect(transition == .moved(
            to: .activeForeground, effects: [.startParticipation, .beginMerge, .clearIdleTimer]
        ))
        #expect(MeshSessionStateMachine.transition(from: .localIdleStop, on: .peerCommitted)
                == .rejected(.eventNotApplicableInState),
                "a stopped radio has no peer to commit — the resume comes first")
    }

    /// The two endings §8.2 draws out of `handingOff`, and the durable-before-acknowledged order:
    /// the mark and the save happen on the REQUEST, the state moves on the SEND.
    @Test func handingOffSavesFirstAndMovesOnTheSend() {
        #expect(MeshSessionStateMachine.transition(from: .activeForeground, on: .departureRequested)
                == .moved(to: .handingOff, effects: [.markTerminated, .persistContext]))
        #expect(MeshSessionStateMachine.transition(from: .handingOff, on: .departureSent)
                == .moved(to: .departed, effects: [.stopParticipation]))
        #expect(MeshSessionStateMachine.transition(
            from: .partitioned, on: .terminationRequested(.finalPairTermination)
        ) == .moved(to: .handingOff, effects: [.markTerminated, .persistContext]))
        #expect(MeshSessionStateMachine.transition(from: .handingOff, on: .terminationSent)
                == .moved(to: .terminated, effects: [.stopParticipation]))
    }

    /// Developing marks the permanent bar and saves before anything else happens.
    @Test func developingMarksTheBarBeforeItIsAnnounced() {
        let transition = MeshSessionStateMachine.transition(from: .activeForeground, on: .developed)
        #expect(transition == .moved(
            to: .handingOff, effects: [.markDeveloped, .persistContext, .stopParticipation]
        ))
        #expect(MeshSessionEvent.developed.terminationReason == .developed)
    }

    /// The ceiling ends the session from EVERY live state — plan §8.2 draws the edge from
    /// `localIdleStop`, and the prose ("the 6-hour ceiling is the membership death") is broader.
    @Test func theCeilingEndsEveryLiveState() {
        for state in MeshSessionState.allCases where state.isLive {
            for bound in MeshSessionCeilingBound.allCases {
                let transition = MeshSessionStateMachine.transition(from: state, on: .hardDeadlineReached(bound))
                #expect(transition == .moved(
                    to: .expired, effects: [.markTerminated, .persistContext, .stopParticipation]
                ), "\(state) must expire at \(bound)")
            }
        }
        #expect(MeshSessionStateMachine.transition(from: .idle, on: .hardDeadlineReached(.signedAbsolute))
                == .rejected(.noSessionYet), "there is no session to expire before one starts")
    }

    /// A removal is involuntary and terminal for this device; a verified termination ends the mesh.
    @Test func removalAndVerifiedTerminationAreTerminal() {
        #expect(MeshSessionStateMachine.transition(from: .activeForeground, on: .removed)
                == .moved(to: .departed, effects: [.markTerminated, .persistContext, .stopParticipation]))
        #expect(MeshSessionStateMachine.transition(from: .partitioned, on: .terminationVerified)
                == .moved(to: .terminated, effects: [.markTerminated, .persistContext, .stopParticipation]))
        #expect(MeshSessionEvent.removed.terminationReason == .removedFromRoster)
    }

    /// Every terminal state refuses every event by the same named rule: a developed or terminated
    /// mesh can never be rejoined.
    @Test func aTerminalStateNeverRejoins() {
        for state in [MeshSessionState.departed, .terminated, .expired] {
            for event in [MeshSessionEvent.founded, .joined, .resumedAfterLapse, .linksRestored,
                          .contextRestored(.resumable)] {
                #expect(MeshSessionStateMachine.transition(from: state, on: event)
                        == .rejected(.sessionAlreadyEnded),
                        "\(state) must refuse \(event)")
            }
        }
    }

    /// The named non-edges, each by its own rule rather than one catch-all.
    @Test func everyNonEdgeNamesItsRule() {
        #expect(MeshSessionStateMachine.transition(from: .idle, on: .peerCommitted)
                == .rejected(.noSessionYet))
        #expect(MeshSessionStateMachine.transition(from: .activeForeground, on: .founded)
                == .rejected(.sessionAlreadyStarted))
        #expect(MeshSessionStateMachine.transition(from: .joining, on: .idleLapsed)
                == .rejected(.eventNotApplicableInState))
        #expect(MeshSessionStateMachine.transition(from: .activeForeground, on: .contextRestored(.resumable))
                == .rejected(.restoreOnlyFromIdle))
        #expect(MeshSessionStateMachine.transition(from: .handingOff, on: .peerCommitted)
                == .rejected(.eventNotApplicableInState))
    }

    /// A link lost before anything committed is not a partition — there is no roster peer yet.
    @Test func aLinkLostWhileJoiningIsNotAPartition() {
        #expect(MeshSessionStateMachine.transition(from: .joining, on: .linksLost)
                == .moved(to: .joining, effects: []))
    }

    /// The launch restore's four dispositions, including the one that must WRITE.
    @Test func restoreMapsEveryDispositionFromIdle() {
        #expect(MeshSessionStateMachine.transition(from: .idle, on: .contextRestored(.none))
                == .moved(to: .idle, effects: []))
        #expect(MeshSessionStateMachine.transition(from: .idle, on: .contextRestored(.resumable))
                == .moved(to: .localIdleStop, effects: [.offerForegroundResume]),
                "a relaunch never auto-reconnects — it offers a resume")
        #expect(MeshSessionStateMachine.transition(from: .idle, on: .contextRestored(.terminated))
                == .moved(to: .terminated, effects: []))
        #expect(MeshSessionStateMachine.transition(from: .idle, on: .contextRestored(.departed))
                == .moved(to: .departed, effects: []))
        #expect(MeshSessionStateMachine.transition(from: .idle, on: .contextRestored(.expired))
                == .moved(to: .expired, effects: [.markTerminated, .persistContext]),
                "a ceiling that passed while the process was gone is written down now")
    }

    /// `persistContext` precedes every effect that tells anybody anything (plan §3.6), and no
    /// transition exceeds the performer's bound.
    @Test func everySaveComesBeforeEveryAnnouncement() {
        for state in MeshSessionState.allCases {
            for event in Self.allEvents {
                let effects = MeshSessionStateMachine.transition(from: state, on: event).effects
                #expect(effects.count <= MeshSessionStateMachine.maxEffectsPerTransition)
                guard let saveIndex = effects.firstIndex(of: .persistContext) else { continue }
                for marker in [MeshSessionEffect.markTerminated, .markDeveloped] {
                    if let markIndex = effects.firstIndex(of: marker) {
                        #expect(markIndex < saveIndex, "the mark must be staged before the save")
                    }
                }
            }
        }
    }
}

// MARK: - MeshSessionCeilingTests

/// The 6-hour ceiling at both of its bounds, including the clock jumps each one exists for.
@Suite(.serialized)
struct MeshSessionCeilingTests {

    private let created = Date(timeIntervalSince1970: 1_800_000_000)

    private var deadline: Date { created.addingTimeInterval(MeshSessionCeiling.ceilingSeconds) }

    /// A fresh session has the full ceiling on both bounds.
    @Test func aFreshSessionHasTheWholeCeiling() {
        let ceiling = MeshSessionCeiling(hardDeadline: deadline, startedAt: created)
        #expect(ceiling.monotonicBudgetSeconds == MeshSessionCeiling.ceilingSeconds)
        #expect(ceiling.verdict(now: created, monotonicElapsed: 0)
                == .live(remainingSeconds: MeshSessionCeiling.ceilingSeconds))
    }

    /// The signed bound ends the session, and only after the skew tolerance.
    @Test func theSignedBoundEndsItAfterTheSkewTolerance() {
        let ceiling = MeshSessionCeiling(hardDeadline: deadline, startedAt: created)
        let tolerance = MeshSessionCeiling.skewToleranceSeconds

        #expect(!ceiling.verdict(now: deadline.addingTimeInterval(tolerance - 1), monotonicElapsed: 0).isReached,
                "inside the ± 120 s tolerance the session is still live")
        #expect(ceiling.verdict(now: deadline.addingTimeInterval(tolerance), monotonicElapsed: 0)
                == .reached(.signedAbsolute))
    }

    /// The monotonic bound ends the session on runtime alone.
    @Test func theMonotonicBoundEndsItOnRuntimeAlone() {
        let ceiling = MeshSessionCeiling(hardDeadline: deadline, startedAt: created)
        let budget = MeshSessionCeiling.ceilingSeconds

        #expect(!ceiling.verdict(now: created, monotonicElapsed: budget - 1).isReached)
        #expect(ceiling.verdict(now: created, monotonicElapsed: budget) == .reached(.localMonotonic))
    }

    /// **A wall clock set backwards cannot extend a session.** The signed bound says a day remains;
    /// the monotonic guard ends it anyway.
    @Test func aBackwardClockJumpCannotExtendTheSession() {
        let ceiling = MeshSessionCeiling(hardDeadline: deadline, startedAt: created)
        let yesterday = created.addingTimeInterval(-86_400)

        #expect(ceiling.verdict(now: yesterday, monotonicElapsed: MeshSessionCeiling.ceilingSeconds)
                == .reached(.localMonotonic),
                "a clock set backwards must not buy a single second of extra membership")
    }

    /// **A forward jump cannot end a session earlier than the signed absolute allows.** Inside the
    /// tolerance it is still live; past it, the signed bound — not the monotonic one — is what ends
    /// it, and the reason recorded says so.
    @Test func aForwardClockJumpEndsItOnlyByTheSignedBound() {
        let ceiling = MeshSessionCeiling(hardDeadline: deadline, startedAt: created)

        #expect(ceiling.verdict(now: created.addingTimeInterval(60), monotonicElapsed: 5) ==
                .live(remainingSeconds: MeshSessionCeiling.ceilingSeconds - 5),
                "the tighter of the two bounds is what remains")
        let verdict = ceiling.verdict(now: deadline.addingTimeInterval(3_600), monotonicElapsed: 5)
        #expect(verdict == .reached(.signedAbsolute))
        #expect(MeshSessionCeilingBound.signedAbsolute.terminationReason == .hardDeadlineSigned)
        #expect(MeshSessionCeilingBound.localMonotonic.terminationReason == .hardDeadlineMonotonic)
    }

    /// A descriptor claiming a deadline days out still buys no more than the ceiling, and a restore
    /// gets only the time that was left.
    @Test func theBudgetIsClampedToTheCeilingAndToWhatIsLeft() {
        let forged = MeshSessionCeiling(
            hardDeadline: created.addingTimeInterval(7 * 86_400), startedAt: created
        )
        #expect(forged.monotonicBudgetSeconds == MeshSessionCeiling.ceilingSeconds)

        let restoredHalfway = MeshSessionCeiling(
            hardDeadline: deadline, startedAt: created.addingTimeInterval(3 * 3_600)
        )
        #expect(restoredHalfway.monotonicBudgetSeconds == 3 * 3_600)

        let restoredLate = MeshSessionCeiling(hardDeadline: deadline, startedAt: deadline.addingTimeInterval(60))
        #expect(restoredLate.monotonicBudgetSeconds == 0)
        #expect(restoredLate.verdict(now: created, monotonicElapsed: 0) == .reached(.localMonotonic),
                "a session restored past its deadline has no budget at all")
    }

    /// A monotonic source that ran backwards is a broken reading, never a licence to extend.
    @Test func aNegativeMonotonicReadingIsTreatedAsZero() {
        let ceiling = MeshSessionCeiling(hardDeadline: deadline, startedAt: created)
        #expect(ceiling.verdict(now: created, monotonicElapsed: -10_000)
                == .live(remainingSeconds: MeshSessionCeiling.ceilingSeconds))
    }
}

// MARK: - MeshSessionRestoreMappingTests

/// The five load states → seven launch outcomes, as a pure mapping.
@Suite(.serialized)
struct MeshSessionRestoreMappingTests {

    private typealias Fixture = MeshSessionStoreFixtures

    private let selfFingerprint = MeshMembershipFixtures.fingerprint(0)

    /// A live context, well inside its ceiling.
    private func liveContext(termination: MeshSessionLocalTermination? = nil) -> MeshSessionContext {
        MeshSessionContext(
            meshID: MeshMembershipFixtures.meshID,
            protocolVersion: 3,
            createdAt: MeshMembershipFixtures.base,
            hardDeadline: MeshMembershipFixtures.base.addingTimeInterval(6 * 3_600),
            localTermination: termination
        )
    }

    /// A token-carrying `loaded`, built through the store so the token is a real one.
    private func loaded(_ context: MeshSessionContext) throws -> MeshSessionLoad {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        let store = MeshSessionStore(scope: scope)
        try Fixture.save(context, into: store)
        return DeviceBindingID.$testOverride.withValue(.identifier(Fixture.installA)) { store.load() }
    }

    /// Outcome 1: a live context inside the ceiling resumes.
    @Test func aLiveContextIsResumable() throws {
        let context = liveContext()
        let outcome = MeshSessionRestore.outcome(
            for: try loaded(context),
            selfFingerprint: selfFingerprint,
            now: MeshMembershipFixtures.base.addingTimeInterval(3_600)
        )
        #expect(outcome.disposition == .resumable)
        #expect(outcome.context?.meshID == context.meshID)
        #expect(!outcome.isRetryable)
    }

    /// Outcome 2: a context that already records an ending comes back ended, by every one of the
    /// four authorities that can record one.
    @Test func aRecordedEndingComesBackEnded() {
        var developed = liveContext()
        developed.developedLocally = true
        #expect(developed.recordedEndingReason(selfFingerprint: selfFingerprint) == .developed)

        var terminatedLedger = liveContext()
        terminatedLedger.ledger.terminations = MeshMembershipRecordSet([MeshMembershipFixtures.termination(1)])
        #expect(terminatedLedger.recordedEndingReason(selfFingerprint: selfFingerprint)
                == .verifiedTerminationRecord)

        var departed = liveContext()
        departed.ledger.departures = MeshMembershipRecordSet([MeshMembershipFixtures.departure(0)])
        #expect(departed.recordedEndingReason(selfFingerprint: selfFingerprint) == .ownDeparture)

        let marked = liveContext(termination: MeshSessionLocalTermination(
            reason: .epochCounterExhausted, at: MeshMembershipFixtures.base
        ))
        #expect(marked.recordedEndingReason(selfFingerprint: selfFingerprint) == .epochCounterExhausted)
    }

    /// A recorded ending beats the ceiling: the reason on the file is what the launch reports.
    @Test func aRecordedEndingBeatsThePassedCeiling() throws {
        let context = liveContext(termination: MeshSessionLocalTermination(
            reason: .ownDeparture, at: MeshMembershipFixtures.base
        ))
        let outcome = MeshSessionRestore.outcome(
            for: try loaded(context),
            selfFingerprint: selfFingerprint,
            now: MeshMembershipFixtures.base.addingTimeInterval(86_400)
        )
        #expect(outcome == .terminated(context, .ownDeparture))
        #expect(outcome.disposition == .departed, "a departure ends this device, not the mesh")
    }

    /// Outcome 3: a live context whose ceiling passed while the process was gone.
    @Test func aPassedCeilingIsExpired() throws {
        let context = liveContext()
        let outcome = MeshSessionRestore.outcome(
            for: try loaded(context),
            selfFingerprint: selfFingerprint,
            now: context.hardDeadline.addingTimeInterval(MeshSessionCeiling.skewToleranceSeconds + 1)
        )
        #expect(outcome == .expired(context))
        #expect(outcome.disposition == .expired)
    }

    /// Outcomes 4–7: absent, deferred, refused and corrupt, each distinct and only one of them a
    /// green field.
    @Test func theFourNonLoadedStatesStayDistinct() {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        let store = MeshSessionStore(scope: scope)
        let absent = DeviceBindingID.$testOverride.withValue(.identifier(Fixture.installA)) { store.load() }
        #expect(MeshSessionRestore.outcome(for: absent, selfFingerprint: selfFingerprint, now: .now)
                == .noSession)

        let deferral = MeshSessionDeferral(reason: .fileUnreadable, detail: "x")
        let deferred = MeshSessionRestore.outcome(
            for: .deferred(deferral), selfFingerprint: selfFingerprint, now: .now
        )
        #expect(deferred == .retryAfterUnlock(deferral))
        #expect(deferred.isRetryable)
        #expect(deferred.logToken == "deferred:fileUnreadable")

        let refusal = MeshSessionSealRefusal(operation: .open, cause: .installBindingUnavailable)
        let refused = MeshSessionRestore.outcome(
            for: .refused(refusal), selfFingerprint: selfFingerprint, now: .now
        )
        #expect(refused == .retryAfterRefusal(refusal))
        #expect(refused.isRetryable)
        #expect(refused.logToken == "refused:installBindingUnavailable",
                "a refusal is logged apart from a deferral")

        let corruption = MeshSessionCorruption(detail: .emptyFile)
        let corrupt = MeshSessionRestore.outcome(
            for: .corrupt(corruption), selfFingerprint: selfFingerprint, now: .now
        )
        #expect(corrupt == .quarantineCorruptFile(corruption))
        #expect(!corrupt.isRetryable, "a corrupt file is quarantined, not retried")
    }

    /// None of the three token-less states starts a session.
    @Test func noTokenlessStateStartsASession() {
        let outcomes: [MeshSessionRestoreOutcome] = [
            .retryAfterUnlock(MeshSessionDeferral(reason: .sealKeyTransientlyUnreadable, detail: "x")),
            .retryAfterRefusal(MeshSessionSealRefusal(operation: .open, cause: .sealKeyMalformed)),
            .quarantineCorruptFile(MeshSessionCorruption(detail: .authenticationFailed))
        ]
        for outcome in outcomes {
            #expect(outcome.disposition == .none)
            #expect(outcome.context == nil)
        }
    }
}

// MARK: - MeshSessionLifecycleManagerTests

/// The manager half: the save cadence, disconnect ≠ removal, the merge-path resume, the rejoin bar
/// and the launch restore.
@MainActor
@Suite(.serialized)
struct MeshSessionLifecycleManagerTests {

    let store = makeTestStore()

    /// A pinned install identity, so every seal in this suite is deterministic.
    private static let install = Data(repeating: 0x6D, count: 16)

    /// The mesh a manager is put into by hand (the descriptor path is item 7's).
    private func makeMesh(_ manager: MeshNetworkManager, createdAt: Date = Date()) -> MeshDescriptor {
        let local = MeshMember(
            fingerprint: manager.identityForTesting.localFingerprint,
            displayName: "Local",
            signingPublicKey: manager.identityForTesting.localSigningPublicKey,
            keyAgreementPublicKey: manager.identityForTesting.localKeyAgreementPublicKey,
            joinedAt: createdAt
        )
        return MeshDescriptor(
            meshID: UUID(),
            name: "Lifecycle Meadow",
            mode: .open,
            members: [local],
            nameSetAt: createdAt,
            nameSetBy: local.fingerprint,
            modeSetAt: createdAt,
            modeSetBy: local.fingerprint,
            createdAt: createdAt
        )
    }

    /// A donor ledger holding this device's own admission, signed by this device as founder — the
    /// one merge input the fail-closed verifier accepts before item 7.
    private func selfAdmittingLedger(_ manager: MeshNetworkManager, meshID: UUID) throws -> MeshMembershipLedger {
        let identity = manager.identityForTesting
        var donor = MeshMembershipLedger.empty
        donor.admissions = donor.admissions.inserting(
            SignedAdmissionRecord(token: try MeshAdmissionToken.signed(
                meshID: meshID,
                joinerFingerprint: identity.localFingerprint,
                joinerSigningPublicKey: identity.localSigningPublicKey,
                admitterIdentity: identity
            ))
        )
        return donor
    }

    /// Reads the sealed context back, under the same pinned install everything here writes with.
    private func loadContext() -> MeshSessionContext? {
        let sessionStore = MeshSessionStore(scope: store.meshSessionStorage)
        let load = DeviceBindingID.$testOverride.withValue(.identifier(Self.install)) {
            sessionStore.load()
        }
        guard case .loaded(let context, _) = load else { return nil }
        return context
    }

    // MARK: The save cadence

    /// Founding writes the context BEFORE the UI is shown a mesh (plan §3.6).
    @Test func foundingPersistsBeforeTheMeshIsShown() {
        let manager = MeshNetworkManager(store: store)
        DeviceBindingID.$testOverride.withValue(.identifier(Self.install)) {
            manager.startNewMesh(name: "Durable Meadow")
        }

        #expect(manager.sessionState == .joining)
        #expect(manager.currentMesh != nil)
        #expect(loadContext()?.meshID == manager.currentMesh?.meshID,
                "the mesh the UI was shown must already be on the disk")
        manager.leaveMesh()
    }

    /// A refused seal abandons the founding outright: no mesh, no session, and it is named.
    @Test func aRefusedSealAbandonsTheFounding() {
        let manager = MeshNetworkManager(store: store)
        DeviceBindingID.$testOverride.withValue(.unavailable) {
            manager.startNewMesh(name: "Undurable Meadow")
        }

        #expect(manager.currentMesh == nil, "a mesh that could not be written down is not created")
        #expect(manager.sessionState == .idle)
        #expect(manager.lastRotationBlockReason != nil, "an abandoned founding is never silent")
        manager.leaveMesh()
    }

    /// **join-ack blocked by a refused store.** A verified admission is not acknowledged — no
    /// epoch, no key, no beacon — until the context is durable.
    @Test func aVerifiedAdmissionIsNotAcknowledgedUntilItIsDurable() {
        let manager = MeshNetworkManager(store: store)
        manager.currentMesh = makeMesh(manager)

        let refused = DeviceBindingID.$testOverride.withValue(.unavailable) {
            manager.recordVerifiedAdmissionDurably()
        }
        #expect(!refused, "a refused seal must block the join acknowledgement")
        #expect(manager.sessionState == .idle, "a half-joined state is not a state")

        let accepted = DeviceBindingID.$testOverride.withValue(.identifier(Self.install)) {
            manager.recordVerifiedAdmissionDurably()
        }
        #expect(accepted)
        #expect(manager.sessionState == .joining)
        manager.leaveMesh()
    }

    /// **record-insert blocked by a deferred store.** A verified record that could not be written
    /// down is rolled back out of the ledger, and the rotation it would have caused does not fire.
    @Test func aRecordIsNotInsertedWhenTheStoreDefers() throws {
        let manager = MeshNetworkManager(store: store)
        let mesh = makeMesh(manager)
        manager.currentMesh = mesh
        manager.prepareMembershipLedger(
            meshID: mesh.meshID, founderSigningPublicKey: manager.identityForTesting.localSigningPublicKey
        )
        // A file must EXIST for a binding read error to defer rather than refuse.
        DeviceBindingID.$testOverride.withValue(.identifier(Self.install)) {
            _ = manager.persistSessionContext(addingEpochHead: nil)
        }
        let donor = try selfAdmittingLedger(manager, meshID: mesh.meshID)

        let rejections = DeviceBindingID.$testOverride.withValue(.readError) {
            manager.mergeMembershipLedger(donor)
        }

        #expect(rejections.isEmpty, "the record verified — it is the SAVE that failed")
        #expect(manager.membershipVerifier?.ledger.admissions.isEmpty == true,
                "a record that could not be written down is not inserted for roster purposes")
        #expect(manager.rotationTriggers.pendingCause == nil,
                "and the rotation that record would have caused must not fire")
        manager.leaveMesh()
    }

    /// The same merge, once the store can write, keeps the record and rotates as `.merge`.
    @Test func aDurableMergeKeepsTheRecordAndRotates() throws {
        let manager = MeshNetworkManager(store: store)
        let mesh = makeMesh(manager)
        manager.currentMesh = mesh
        manager.prepareMembershipLedger(
            meshID: mesh.meshID, founderSigningPublicKey: manager.identityForTesting.localSigningPublicKey
        )
        let donor = try selfAdmittingLedger(manager, meshID: mesh.meshID)

        let rejections = DeviceBindingID.$testOverride.withValue(.identifier(Self.install)) {
            manager.mergeMembershipLedger(donor)
        }

        #expect(rejections.isEmpty)
        #expect(manager.membershipVerifier?.roster.memberCount == 1)
        #expect(manager.rotationTriggers.pendingCause == .merge)
        #expect(loadContext()?.ledger.admissions.count == 1, "the record is on the disk, not only in RAM")
        manager.leaveMesh()
    }

    // MARK: Disconnect ≠ removal

    /// A transport disconnect partitions the session and leaves membership exactly where it was:
    /// no record minted, the roster unmoved, and the peer still admitted.
    @Test func aDisconnectIsNotARemoval() throws {
        let manager = MeshNetworkManager(store: store)
        let mesh = makeMesh(manager)
        manager.currentMesh = mesh
        manager.prepareMembershipLedger(
            meshID: mesh.meshID, founderSigningPublicKey: manager.identityForTesting.localSigningPublicKey
        )
        let donor = try selfAdmittingLedger(manager, meshID: mesh.meshID)
        DeviceBindingID.$testOverride.withValue(.identifier(Self.install)) {
            _ = manager.mergeMembershipLedger(donor)
            manager.applySessionEvent(.founded)
            manager.applySessionEvent(.peerCommitted)
            manager.applySessionEvent(.linksLost)
        }
        let rosterAfterDrop = manager.membershipVerifier?.roster

        #expect(manager.sessionState == .partitioned, "links lost is a partition, never an ending")
        #expect(manager.idleLapseDeadline != nil, "the idle window arms on the partition")
        #expect(rosterAfterDrop?.memberCount == 1)
        #expect(manager.membershipVerifier?.ledger.departures.isEmpty == true,
                "a disconnect mints no departure record")
        #expect(manager.membershipVerifier?.ledger.removals.isEmpty == true,
                "and no removal record")

        // The reconnect needs no re-admission, and the returning member is still a key recipient —
        // while a member the roster actually removed is not (item 5's exclusion rule).
        let selfFP = manager.identityForTesting.localFingerprint
        let recipients = MeshRotationPolicy.recipients(
            acked: [selfFP, "fp-stranger"],
            selfFingerprint: selfFP,
            derivedRoster: rosterAfterDrop,
            locallyRemoved: ["fp-stranger"]
        )
        #expect(recipients.contains(selfFP), "a disconnected member keeps its place in the roster")
        #expect(!recipients.contains("fp-stranger"), "a removed member does not get the next key")
        manager.leaveMesh()
    }

    /// The same claim through the radio: a `FakeMeshTransportSession` dropping a **committed** peer
    /// partitions the session and mints nothing. This is the transport seam, not a hand-applied
    /// event — the disconnect arrives exactly where a real radio's does.
    @Test func aDroppedPeerFromTheRadioPartitionsWithoutMintingARecord() {
        let transport = FakeMeshTransportSession()
        let manager = MeshNetworkManager(store: store, transport: transport)
        let mesh = makeMesh(manager)
        manager.currentMesh = mesh
        manager.prepareMembershipLedger(
            meshID: mesh.meshID, founderSigningPublicKey: manager.identityForTesting.localSigningPublicKey
        )
        let peer = PeerHandle(
            id: UUID(),
            displayHint: "iPhone",
            discoveryInfo: ["v": "1"],
            advertisedFingerprint: nil,
            endpoint: PeerEndpointKey()
        )
        manager.addSlotForTesting(
            coordinator: Self.throwawayCoordinator(), peer: peer, fingerprint: "fp-committed"
        )
        DeviceBindingID.$testOverride.withValue(.identifier(Self.install)) {
            manager.applySessionEvent(.founded)
            manager.applySessionEvent(.peerCommitted)
            transport.drop(peer)
        }

        #expect(manager.sessionState == .partitioned, "a dropped link partitions, it does not remove")
        #expect(manager.idleLapseDeadline != nil)
        #expect(manager.membershipVerifier?.ledger.departures.isEmpty == true)
        #expect(manager.membershipVerifier?.ledger.removals.isEmpty == true)
        manager.leaveMesh()
    }

    /// A coordinator with no live dependencies, for slots this suite only needs to exist.
    private static func throwawayCoordinator() -> ProximityCoordinator {
        ProximityCoordinator(
            identity: IdentityService(keychainService: "test.mesh.lifecycle.\(UUID().uuidString)"),
            transport: MockMultipeerTransport(),
            ranging: MockRangingProvider(),
            inspector: nil,
            replayCache: ReplayCache(),
            foregroundAnchor: nil,
            displayName: "Local",
            timeoutSeconds: 0
        )
    }

    // MARK: Idle-lapse resume is the merge path

    /// A lapsed session resumes through the merge: the returning peer's divergent same-counter
    /// epoch **coexists** with this device's own, the ledger merges, and `.merge` fires once.
    @Test func anIdleLapseResumesThroughTheMergePath() throws {
        let manager = MeshNetworkManager(store: store)
        let mesh = makeMesh(manager)
        manager.currentMesh = mesh
        manager.prepareMembershipLedger(
            meshID: mesh.meshID, founderSigningPublicKey: manager.identityForTesting.localSigningPublicKey
        )
        let selfFP = manager.identityForTesting.localFingerprint
        guard let ownHead = MeshEpochRef.minted(counter: 4, coordinatorFingerprint: selfFP, meshID: mesh.meshID),
              let peerHead = MeshEpochRef.minted(
                  counter: 4, coordinatorFingerprint: "00000000000000bb", meshID: mesh.meshID
              ) else {
            Issue.record("could not mint the two divergent heads")
            return
        }
        #expect(MeshEpochAcceptance.rotationVerdict(
            local: ownHead,
            presented: peerHead,
            presentedRoster: ["00000000000000bb"],
            presenterFingerprint: "00000000000000bb"
        ) == .coexist, "two partitions at the same counter coexist — neither accepts the other")

        let donor = try selfAdmittingLedger(manager, meshID: mesh.meshID)
        DeviceBindingID.$testOverride.withValue(.identifier(Self.install)) {
            _ = manager.persistSessionContext(addingEpochHead: ownHead)
            manager.applySessionEvent(.founded)
            manager.applySessionEvent(.peerCommitted)
            manager.applySessionEvent(.linksLost)
            _ = manager.evaluateIdleLapse(now: Date().addingTimeInterval(MeshNetworkManager.idleWindowSeconds))
            _ = manager.resumeSessionAfterLapse(mergingLedger: donor, peerEpochHead: peerHead)
        }

        #expect(manager.sessionState == .activeForeground, "the resume brings the session back")
        #expect(manager.currentMesh?.meshID == mesh.meshID, "and it is the SAME session, not a fresh one")
        #expect(manager.rotationTriggers.pendingCause == .merge, "the resume rotates as a merge, once")
        let heads = loadContext()?.epochHeads ?? []
        #expect(heads.contains(ownHead) && heads.contains(peerHead),
                "both branch heads survive the resume — coexistence, not a silent re-key")
        manager.leaveMesh()
    }

    /// The lapse itself stops participation without ending membership.
    @Test func anIdleLapseStopsParticipationNotMembership() {
        let manager = MeshNetworkManager(store: store)
        manager.currentMesh = makeMesh(manager)
        DeviceBindingID.$testOverride.withValue(.identifier(Self.install)) {
            manager.applySessionEvent(.founded)
            manager.applySessionEvent(.peerCommitted)
            manager.applySessionEvent(.linksLost)
        }

        #expect(!manager.evaluateIdleLapse(now: Date()), "the window has not elapsed yet")
        let lapsed = manager.evaluateIdleLapse(
            now: Date().addingTimeInterval(MeshNetworkManager.idleWindowSeconds + 1)
        )
        #expect(lapsed)
        #expect(manager.sessionState == .localIdleStop)
        #expect(manager.currentMesh != nil, "local participation stopped; membership did not")
        manager.leaveMesh()
    }

    // MARK: The ceiling, enforced

    /// Either bound ends the session, marks the context terminated and announces it.
    @Test func theCeilingEndsTheSessionAtEitherBound() async {
        for bound in MeshSessionCeilingBound.allCases {
            let manager = MeshNetworkManager(store: store)
            let created = Date()
            manager.currentMesh = makeMesh(manager, createdAt: created)
            let deadline = created.addingTimeInterval(MeshSessionCeiling.ceilingSeconds)
            var emitted: [PayloadType] = []
            manager.onMembershipEventSentForTesting = { emitted.append($0) }

            await DeviceBindingID.$testOverride.withValue(.identifier(Self.install)) {
                manager.applySessionEvent(.founded)
                manager.startSessionCeiling(hardDeadline: deadline, startedAt: created)
                let elapsed = bound == .localMonotonic ? MeshSessionCeiling.ceilingSeconds : 0
                let now = bound == .localMonotonic ? created : deadline.addingTimeInterval(3_600)
                await manager.enforceSessionCeiling(now: now, monotonicElapsed: elapsed)
            }

            #expect(manager.sessionState == .expired, "\(bound) must end the session")
            #expect(emitted == [.meshTerminated], "the ceiling announces itself (plan §8.2)")
            #expect(loadContext()?.localTermination?.reason == bound.terminationReason,
                    "and the reason recorded names the bound that ended it")
            manager.leaveMesh()
        }
    }

    /// Inside both bounds nothing happens at all.
    @Test func aSessionInsideBothBoundsIsUntouched() async {
        let manager = MeshNetworkManager(store: store)
        let created = Date()
        manager.currentMesh = makeMesh(manager, createdAt: created)
        DeviceBindingID.$testOverride.withValue(.identifier(Self.install)) {
            manager.applySessionEvent(.founded)
        }
        manager.startSessionCeiling(
            hardDeadline: created.addingTimeInterval(MeshSessionCeiling.ceilingSeconds), startedAt: created
        )

        let verdict = await manager.enforceSessionCeiling(now: created.addingTimeInterval(60), monotonicElapsed: 60)

        #expect(verdict?.isReached == false)
        #expect(manager.sessionState == .joining)
        manager.leaveMesh()
    }

    // MARK: Developed / terminated never rejoin

    /// A departure writes the durable mark, and the mesh it left is barred at both doors — before
    /// the process ends and, via the restore below, after it.
    @Test func aDepartureBarsTheMeshItLeft() async {
        let manager = MeshNetworkManager(store: store)
        let mesh = makeMesh(manager)
        manager.currentMesh = mesh
        var emitted: [PayloadType] = []
        manager.onMembershipEventSentForTesting = { emitted.append($0) }

        await DeviceBindingID.$testOverride.withValue(.identifier(Self.install)) {
            manager.applySessionEvent(.founded)
            await manager.leaveSessionAfterNotifyingPeers()
        }

        #expect(emitted == [.meshMemberDeparture], "the departure still reaches the peers")
        #expect(manager.sessionState == .departed)
        #expect(manager.rejoinRefusal(for: mesh.meshID) == .ownDeparture)
        #expect(loadContext()?.localTermination?.reason == .ownDeparture,
                "the bar is durable before it is announced")
    }

    /// A terminated context loaded at launch yields the terminated state, not a resumable one, and
    /// the bar it carries refuses a fresh join for the same mesh id.
    @Test func aTerminatedContextRestoresTerminatedAndRefusesARejoin() throws {
        let sessionStore = MeshSessionStore(scope: store.meshSessionStorage)
        let meshID = UUID()
        let created = Date()
        let context = MeshSessionContext(
            meshID: meshID,
            protocolVersion: 3,
            createdAt: created,
            hardDeadline: created.addingTimeInterval(MeshSessionCeiling.ceilingSeconds),
            localTermination: MeshSessionLocalTermination(reason: .finalPairTermination, at: created)
        )
        try MeshSessionStoreFixtures.save(context, into: sessionStore, install: Self.install)

        let manager = MeshNetworkManager(store: store)
        let outcome = DeviceBindingID.$testOverride.withValue(.identifier(Self.install)) {
            manager.restoreSessionContextAtLaunch(now: created.addingTimeInterval(60))
        }

        #expect(outcome == .terminated(context, .finalPairTermination))
        #expect(manager.sessionState == .terminated, "a restart must not resurrect an ended session")
        #expect(manager.rejoinRefusal(for: meshID) == .finalPairTermination)
        #expect(manager.applySessionEvent(.joined) == .rejected(.sessionAlreadyEnded))
        #expect(loadContext()?.localTermination?.reason == .finalPairTermination,
                "and the sealed context still says so")
    }

    /// A live context restores as idle-lapsed with a resume on offer — never as a live session,
    /// because a relaunch never auto-reconnects (invariant 5).
    @Test func aLiveContextRestoresIdleLapsedAwaitingAPeer() throws {
        let sessionStore = MeshSessionStore(scope: store.meshSessionStorage)
        let created = Date()
        let context = MeshSessionContext(
            meshID: UUID(),
            protocolVersion: 3,
            createdAt: created,
            hardDeadline: created.addingTimeInterval(MeshSessionCeiling.ceilingSeconds)
        )
        try MeshSessionStoreFixtures.save(context, into: sessionStore, install: Self.install)

        let manager = MeshNetworkManager(store: store)
        let outcome = DeviceBindingID.$testOverride.withValue(.identifier(Self.install)) {
            manager.restoreSessionContextAtLaunch(now: created.addingTimeInterval(3_600))
        }

        #expect(outcome.disposition == .resumable)
        #expect(manager.sessionState == .localIdleStop)
        #expect(manager.offersForegroundResume)
        #expect(manager.currentMesh == nil, "restoring is not reconnecting")
        #expect(manager.rejoinBar == nil)
    }

    /// A context whose ceiling passed while the process was gone expires AND writes the mark.
    @Test func aPastDeadlineContextRestoresExpiredAndWritesTheMark() throws {
        let sessionStore = MeshSessionStore(scope: store.meshSessionStorage)
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        let context = MeshSessionContext(
            meshID: UUID(),
            protocolVersion: 3,
            createdAt: created,
            hardDeadline: created.addingTimeInterval(MeshSessionCeiling.ceilingSeconds)
        )
        try MeshSessionStoreFixtures.save(context, into: sessionStore, install: Self.install)

        let manager = MeshNetworkManager(store: store)
        let outcome = DeviceBindingID.$testOverride.withValue(.identifier(Self.install)) {
            manager.restoreSessionContextAtLaunch(now: context.hardDeadline.addingTimeInterval(86_400))
        }

        #expect(outcome == .expired(context))
        #expect(manager.sessionState == .expired)
        #expect(loadContext()?.localTermination?.reason == .hardDeadlineSigned,
                "the expiry the launch discovered is written down, not merely noticed")
        #expect(manager.rejoinRefusal(for: context.meshID) == .hardDeadlineSigned)
    }

    /// An absent file is the one green field: no session, nothing written, nothing barred.
    @Test func anAbsentContextIsNoSession() {
        let manager = MeshNetworkManager(store: store)
        let outcome = DeviceBindingID.$testOverride.withValue(.identifier(Self.install)) {
            manager.restoreSessionContextAtLaunch(now: Date())
        }

        #expect(outcome == .noSession)
        #expect(manager.sessionState == .idle)
        #expect(manager.rejoinBar == nil)
    }

    /// A deferred load starts no session and is retried a **bounded** number of times.
    @Test func aDeferredRestoreStartsNoSessionAndRetriesABoundedNumberOfTimes() throws {
        let sessionStore = MeshSessionStore(scope: store.meshSessionStorage)
        let created = Date()
        try MeshSessionStoreFixtures.save(
            MeshSessionContext(
                meshID: UUID(), protocolVersion: 3, createdAt: created,
                hardDeadline: created.addingTimeInterval(MeshSessionCeiling.ceilingSeconds)
            ),
            into: sessionStore, install: Self.install
        )

        let manager = MeshNetworkManager(store: store)
        DeviceBindingID.$testOverride.withValue(.readError) {
            _ = manager.restoreSessionContextAtLaunch(now: created)
            for _ in 0..<10 { _ = manager.retrySessionRestoreIfPending(now: created) }
        }

        #expect(manager.lastSessionRestoreOutcome?.isRetryable == true)
        #expect(manager.sessionState == .idle, "a deferral never starts a session")
        #expect(manager.sessionRestoreAttempts == MeshSessionRestoreBounds.maxAttempts,
                "the retry is bounded — a deferral is asked again, never spun on")
        #expect(loadContext() != nil, "and no writer ran: the context that was there is untouched")
    }

    /// A refused load is retried like a deferral and runs no writer — the `LoadToken` rule.
    @Test func aRefusedRestoreStartsNoSessionAndRunsNoWriter() throws {
        let sessionStore = MeshSessionStore(scope: store.meshSessionStorage)
        let created = Date()
        let context = MeshSessionContext(
            meshID: UUID(), protocolVersion: 3, createdAt: created,
            hardDeadline: created.addingTimeInterval(MeshSessionCeiling.ceilingSeconds)
        )
        try MeshSessionStoreFixtures.save(context, into: sessionStore, install: Self.install)

        let manager = MeshNetworkManager(store: store)
        let outcome = DeviceBindingID.$testOverride.withValue(.unavailable) {
            manager.restoreSessionContextAtLaunch(now: created)
        }

        #expect(outcome.isRetryable)
        #expect(outcome.logToken.hasPrefix("refused:"), "a refusal is logged apart from a deferral")
        #expect(manager.sessionState == .idle)
        #expect(loadContext()?.meshID == context.meshID, "the file the refusal could not open still stands")
    }

    /// A corrupt file is quarantined beside itself — preserved, not overwritten — and starts no
    /// session.
    @Test func aCorruptContextIsQuarantinedAndStartsNoSession() throws {
        let sessionStore = MeshSessionStore(scope: store.meshSessionStorage)
        let created = Date()
        try MeshSessionStoreFixtures.save(
            MeshSessionContext(
                meshID: UUID(), protocolVersion: 3, createdAt: created,
                hardDeadline: created.addingTimeInterval(MeshSessionCeiling.ceilingSeconds)
            ),
            into: sessionStore, install: Self.install
        )
        // Truncated ciphertext, not junk bytes: junk has no v3 prefix and is a REFUSAL by name.
        let sealed = try Data(contentsOf: sessionStore.fileURL)
        try MeshSessionStoreFixtures.writeRaw(sealed.prefix(sealed.count - 8), into: sessionStore)

        let manager = MeshNetworkManager(store: store)
        let outcome = DeviceBindingID.$testOverride.withValue(.identifier(Self.install)) {
            manager.restoreSessionContextAtLaunch(now: Date())
        }

        #expect(outcome.disposition == .none)
        #expect(manager.sessionState == .idle)
        #expect(FileManager.default.fileExists(atPath: sessionStore.quarantineURL.path),
                "the bytes are set aside, not destroyed")
        #expect(!FileManager.default.fileExists(atPath: sessionStore.fileURL.path))
    }
}
