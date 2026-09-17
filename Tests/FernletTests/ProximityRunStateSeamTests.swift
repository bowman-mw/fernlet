// ProximityRunStateSeamTests.swift
// FernletTests
//
// Network migration P7 item 3, pass A (plan §13): the three `applyRunState` seams, and the one
// vocabulary they share.
//
// **What this suite claims.** That each manager now has an `apply(_:)`-shaped door taking the
// RESOLVED directive; that the door is idempotent (a second push of the same value does nothing and
// says nothing); that `mesh.runState.applied` names a CHANGE and is never emitted for a no-op; that
// a seam handed `foregroundOnly` treats it as `run` and records `mesh.runState.unresolved`; and —
// the cell the whole pass exists for — that a links `stop` over a COMMITTED peer tears nothing
// down. `stopJoin()` runs `stopSearching()`, which empties `slots`, drops `slotTrustPolicies`,
// cancels every slot coordinator and runs `clearGroupKeyState()`; running that over a committed
// slot is ending a live mesh, not standing one down.
//
// **And, since pass B, the give-up clock.** `ContentView.armDiscoveryTimeout()` — the five-minute
// "found nobody" one-shot that hung off the app's own `startFriendsDiscovery()` — is retired, and
// its successor is `armFriendRadios()`'s `.fresh` row arming the manager's existing door-3 clock.
// Two cells drive it end to end with an injected instant: a fresh peerless search gives up after
// `discoveryGiveUpInterval`, and a committed peer cancels it.
//
// **What it does not claim.** The app's own wiring: pass B makes `ProximityRunPolicyHost` the
// shipping driver of these three doors, and the host's side — the resolved directives, the teardown
// latch and the zero wall over `App/` — is `ProximityRunPolicyHostTests`' subject, not this file's.
// Every cell here still drives a manager directly. And no cell drives `run` from a STOPPED presence
// or recipe manager:
// `PresenceManager.start()` brings up a real `MCNearbyServiceAdvertiser` and
// `ProximityRecipeShareManager.start()` a real browser, which a unit test must never do. Both
// managers' `run` arm is therefore covered from the RUNNING side — the idempotent no-op, which is
// the half a wrong guard would break — and the `stop` arm, which is the direction shipping actually
// takes at consent-off, at a wipe and on the way to background, is driven end to end. Said out loud
// rather than skipped: the missing half is `start()` itself, and it is unchanged by this pass.
//
// Construction mirrors the cheapest existing paths: `makeTestStore()` + `FakeMeshTransportSession`
// for the mesh (as `MeshDivergentTunnelGateTests` builds its bare manager), a minimal
// `ProximityHost` double for presence and recipe (as `ProximityRecipeShareCapTests` does), and
// `MeshP3Acceptance.attachSlot(to:fingerprint:)` for the committed slot. Hosts are hoisted into
// their own `let` before the manager is built (rule ML5: `store` is `unowned`).
//
// **Two suites live in this file**, so a `-only-testing` line must name each of them by struct:
// `ProximityRunStateVocabularyTests` (the shared vocabulary and its resolver) and
// `ProximityRunStateSeamTests` (the three doors). A filter that names only one runs half of this
// file and reports green.
//
// Serialized, because the audit log's capture handler is process-global — but `.serialized` is NOT
// what makes the counts honest, and saying so was a review finding (P2-3). `.serialized` orders a
// suite's OWN cells; cells of these two suites can still run in parallel with each other. What
// makes every audit count in this file this cell's own is that **every cell body is `@MainActor`
// and synchronous**: a synchronous main-actor body cannot suspend, so `install()` → drive → assert
// → `uninstall()` can never interleave with another cell's capture handler. One `async` cell added
// to either suite would silently break every count in both. The second fact the counts rest on is
// that `mesh.runState.*` has no other emitter in the build: these three seams are its only source,
// and the one shipping caller pass B added (`ProximityRunPolicyHost`, reached from `FernletApp`'s
// scene) exists only inside a running app — no unit-test process mounts a scene, so nothing else in
// this process can add to the tally. The same holds for the two `mesh.session.*` tokens the
// give-up-clock cells count.

import Foundation
import Testing
import FernletDomainModel
import FernletFoundation
@testable import ProximityKit
@testable import Fernlet

// MARK: - Fixtures

/// The minimal `ProximityHost` the presence and recipe seams need: a trust vault and a name.
///
/// A double rather than `makeTestStore()` because neither seam reads anything else, and the two
/// cheapest suites over these managers (`ProximityRecipeShareCapTests`, `HeartShareTests`) already
/// build exactly this shape. Held by the cell in its own `let` so the manager's `unowned store`
/// never dangles (rule ML5).
private final class RunStateSeamHost: ProximityHost {

    /// The display name the managers advertise under. Never read by these cells.
    var proximityDisplayName: String { "Seam" }

    /// The vault's roster, which stays empty here.
    var trustedProximityPeers: [ProximityTrustedPeerRecord] { proximityTrustVault.trustedPeers }

    /// The vault itself, fresh per host.
    let proximityTrustVault = ProximityTrustVault()

    /// Whether a fingerprint is blocked — delegated to the vault.
    ///
    /// - Parameter fingerprint: The peer's fingerprint.
    /// - Returns: the vault's answer.
    func isBlockedFingerprint(_ fingerprint: String) -> Bool {
        proximityTrustVault.isBlockedFingerprint(fingerprint)
    }

    /// Blocks a peer by signing key — delegated to the vault.
    ///
    /// - Parameter signingPublicKey: The peer's Ed25519 key.
    func blockProximityPeer(signingPublicKey: Data) {
        proximityTrustVault.block(signingPublicKey: signingPublicKey)
    }
}

/// A heart ledger under a fresh temp directory that EXISTS (review finding P3-10).
///
/// The seam cells never write through the ledger — `PresenceManager`'s door only flips a run flag —
/// but a `fileURL` whose parent directory was never created is a trap for the next cell that does
/// write, and creating it is one call. `try?`, because a temp directory that cannot be made is not
/// any of these cells' claim: the manager is built either way and every seam assertion stands on
/// the run flag alone. Hoisted out of the two cells that were spelling the same three lines.
///
/// - Returns: a ledger rooted at its own directory, so no two cells can collide.
@MainActor
private func makeSeamHeartLedger() -> ProximityHeartLedger {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("run-state-seam-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return ProximityHeartLedger(fileURL: directory.appendingPathComponent("HeartLedger.json"))
}

/// The audit lines one cell saw, so "fires once per change, never on a no-op" is a count.
///
/// The same shape as `MeshFoundingAuditCapture`, and it may count rather than only assert existence
/// for the two reasons this file's header gives: every cell body is `@MainActor` and synchronous,
/// so no other cell's capture window overlaps this one's, and `mesh.runState.*` has exactly three
/// emitters and no shipping caller, so nothing else in the process can add to the tally.
private final class RunStateAuditCapture {

    /// The lock guarding ``storedLines`` — the handler is invoked off the installing actor.
    private let lock = NSLock()

    /// Every line seen since ``install()``.
    private var storedLines: [(event: String, context: [String: String])] = []

    /// The registry token, so the handler can be removed again.
    private var token: UUID?

    /// Starts capturing.
    func install() {
        token = FernletAuditLog.addCaptureHandler { [weak self] event, context in
            guard let self else { return }
            self.lock.lock()
            self.storedLines.append((event, context))
            self.lock.unlock()
        }
    }

    /// Stops capturing.
    func uninstall() {
        if let token {
            FernletAuditLog.removeCaptureHandler(token)
            self.token = nil
        }
    }

    /// How many lines carried `event`.
    ///
    /// - Parameter event: The audit token.
    /// - Returns: the count.
    func count(of event: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return storedLines.filter { $0.event == event }.count
    }

    /// The `reason` values of every ``ProximityRunStateSeam/held`` line seen.
    ///
    /// - Returns: the reasons, in order.
    func heldReasons() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return storedLines.filter { $0.event == ProximityRunStateSeam.held }
            .compactMap { $0.context["reason"] }
    }
}

// MARK: - The vocabulary

/// `ProximityRunState` is ProximityKit's, it has exactly three cases, and its `rawValue`s are
/// frozen English tokens rather than display copy.
@MainActor
@Suite(.serialized)
struct ProximityRunStateVocabularyTests {

    /// Three cases, and every `rawValue` pinned literally.
    ///
    /// The `rawValue`s are what the seams log as `state=…`, so they are a promise to whoever reads
    /// a trace later — pinned here so renaming one is a red rather than a silent break in someone
    /// else's saved log. A fourth case fails the count, which is the point: plan §13's vocabulary is
    /// three answers and a fourth is a design decision, not an addition.
    @Test func theRunStateVocabularyIsThreeFrozenTokens() {
        #expect(ProximityRunState.allCases.count == 3, "plan §13's vocabulary is exactly three answers")
        #expect(ProximityRunState.run.rawValue == "run", "the frozen token for the always-up answer")
        #expect(ProximityRunState.foregroundOnly.rawValue == "foregroundOnly",
                "the frozen token for the scene-dependent answer")
        #expect(ProximityRunState.stop.rawValue == "stop", "the frozen token for the stand-down answer")
        #expect(ProximityRunState.allCases.map(\.rawValue) == ["run", "foregroundOnly", "stop"],
                "and the declaration order is pinned too, so a reordered enum is a visible change")
        #expect(ProximityRunState(rawValue: "foregroundOnly") == .foregroundOnly,
                "the token round-trips, which is what makes it readable back out of a log")
    }

    /// The truth table of ``ProximityRunState/isUp(inForeground:)`` — six rows, written literally.
    ///
    /// Literal rather than derived, because a derivation from the same `switch` the function uses
    /// would be the function spelled twice. The load-bearing row is the last pair: `foregroundOnly`
    /// is the only answer that moves with the scene, which is what lets §13's rows be read as
    /// written and the RESOLUTION put the radio down in the background.
    @Test func theDirectiveResolvesAgainstTheOneForegroundFact() {
        #expect(ProximityRunState.run.isUp(inForeground: true), "run is up in the foreground")
        #expect(ProximityRunState.run.isUp(inForeground: false), "and in the background — §13's only such answer")
        #expect(!ProximityRunState.stop.isUp(inForeground: true), "stop is down in the foreground")
        #expect(!ProximityRunState.stop.isUp(inForeground: false), "and in the background")
        #expect(ProximityRunState.foregroundOnly.isUp(inForeground: true), "foregroundOnly is up while foreground")
        #expect(!ProximityRunState.foregroundOnly.isUp(inForeground: false), "and down once backgrounded")
    }

    /// A seam handed an UNRESOLVED directive treats it as `run` and says so.
    ///
    /// `foregroundOnly` is a policy/UI concept — an answer about two scene phases — and a manager
    /// knows about neither, so the seams resolve it rather than inventing a third behaviour. `run`
    /// is the fail-SAFE direction: standing a radio down on a directive nobody resolved could end a
    /// live mesh, and a radio left up costs battery. The audit line is what makes the claim
    /// testable instead of a comment.
    @Test func aSeamTreatsForegroundOnlyAsRunAndSaysSo() {
        let audit = RunStateAuditCapture()
        audit.install()
        defer { audit.uninstall() }

        #expect(ProximityRunStateSeam.isUp(.run, radio: ProximityRunStateSeam.presence), "run is up")
        #expect(!ProximityRunStateSeam.isUp(.stop, radio: ProximityRunStateSeam.presence), "stop is down")
        #expect(audit.count(of: ProximityRunStateSeam.unresolved) == 0,
                "a resolved directive is silent — only the unresolved one is named")
        #expect(ProximityRunStateSeam.isUp(.foregroundOnly, radio: ProximityRunStateSeam.presence),
                "an unresolved directive resolves UP, which is the fail-safe direction")
        #expect(audit.count(of: ProximityRunStateSeam.unresolved) == 1, "and is named exactly once")
    }

    /// The token family is one family, spelled once, and the radio names match the app's
    /// `ProximityRadio` `rawValue`s that ProximityKit may not import.
    ///
    /// The app-side half is asserted from the app's own enum, so the two spellings cannot drift
    /// apart silently: a rename on either side fails here.
    @Test func theSeamTokensAreFrozenAndMatchTheAppsRadioNames() {
        #expect(ProximityRunStateSeam.applied == "mesh.runState.applied", "the change token")
        #expect(ProximityRunStateSeam.held == "mesh.runState.held", "the refusal token")
        #expect(ProximityRunStateSeam.unresolved == "mesh.runState.unresolved", "the unresolved-directive token")
        #expect(ProximityRunStateSeam.committedPeer == "committedPeer", "the committed-peer bail's reason")
        #expect(ProximityRunStateSeam.noStandAloneDiscoveryStop == "noStandAloneDiscoveryStop",
                "the P8-only combination's reason")
        #expect(ProximityRunStateSeam.resumeRefused == "resumeRefused",
                "the refused-resume reason, so the ended-session row is never a silence again")
        #expect(ProximityRunStateSeam.resumeOffered == "resumeOffered", """
            P7 item 5 pass 2's fourth `held` reason: a fresh search over an UNANSWERED launch-restore \
            offer holds, because `startJoin()` would clear `offersForegroundResume` and \
            `restoredSessionContext` before the Friends card could be drawn
            """)
        #expect(ProximityRunStateSeam.meshLinks == ProximityRadio.meshLinks.rawValue,
                "the module's radio name is the app's, because the app type cannot cross the boundary")
        #expect(ProximityRunStateSeam.discoveryAdmission == ProximityRadio.discoveryAdmission.rawValue,
                "same for the admission door")
        #expect(ProximityRunStateSeam.presence == ProximityRadio.presence.rawValue, "same for presence")
        #expect(ProximityRunStateSeam.recipeShare == ProximityRadio.recipeShare.rawValue, "same for recipe")
        #expect(ProximityRunStateSeam.friendRadios == "meshLinks+discoveryAdmission",
                "and the pair token names both, because one door serves both")
    }
}

// MARK: - The seams

/// P7 item 3 pass A: each manager's `applyRunState` door, driven directly.
///
/// Serialized: every cell reads the process-global audit log, and the mesh cells drive one
/// manager's radio lifecycle.
@MainActor
@Suite(.serialized)
struct ProximityRunStateSeamTests {

    /// `run` on the discovery radio arms the radios once, and a second push does nothing.
    ///
    /// Idempotence is `isSearching`'s, exactly as `ContentView.startFriendsDiscovery()`'s bail is —
    /// a second `startJoin()` re-mints the radio's Bonjour name mid-run. The audit half is the
    /// claim the wiring will lean on: `applied` names a CHANGE, so the second push is silent.
    @Test func aRunArmsTheRadiosOnceAndTheSecondPushIsASilentNoOp() {
        let audit = RunStateAuditCapture()
        audit.install()
        defer { audit.uninstall() }
        // The host is held for the manager's whole life (rule ML5): `store` is `unowned`, so an
        // inline `makeTestStore()` would die at the end of the expression that built the manager.
        let host = makeTestStore()
        let manager = MeshNetworkManager(store: host, transport: FakeMeshTransportSession())
        defer { manager.stopJoin() }

        manager.applyRunState(links: .run, discovery: .run)
        #expect(manager.isSearching, "a discovery run arms the radios")
        #expect(manager.isProximityJoin, "through startJoin(), so a discovered peer is invited")
        #expect(audit.count(of: ProximityRunStateSeam.applied) == 1, "and the change is named once")

        manager.applyRunState(links: .run, discovery: .run)
        #expect(manager.isSearching, "the second push leaves the radios exactly as they were")
        #expect(audit.count(of: ProximityRunStateSeam.applied) == 1,
                "and emits nothing: `applied` is a CHANGE line, not a receipt for every call")
    }

    /// **The five-minute give-up clock has a home again** (P7 item 3, pass B — the obligation pass A
    /// recorded and the ledger carried).
    ///
    /// `ContentView.startFriendsDiscovery()` armed `armDiscoveryTimeout()` beside its radio call,
    /// and pass B retires both. The successor is `armFriendRadios()`'s `.fresh` row, which arms the
    /// manager's own door-3 clock — the same `MeshNetworkManager.discoveryGiveUpInterval`, the same
    /// on-fire effect (`endSessionAfterDiscoveryTimeout()`, which the app's one-shot also called),
    /// and no display copy anywhere: the ending is a frozen state the app renders, never a sentence
    /// ProximityKit owns.
    ///
    /// Driven with an INJECTED instant and no sleep, the way `MeshPairwiseFoundingTests` drives the
    /// slot-loss arm: the deadline is the decision and `evaluateSessionGiveUp(now:)` is the only
    /// thing that reads it, so a wake that never comes and a wake that comes late are the same cell.
    /// The interval is read off the shipping constant rather than spelled, so the clock and the cell
    /// cannot drift to different five minutes.
    @Test func aFreshPeerlessSearchGivesUpAfterTheGiveUpInterval() {
        let audit = RunStateAuditCapture()
        audit.install()
        defer { audit.uninstall() }
        // The host is held for the manager's whole life (rule ML5): `store` is `unowned`, so an
        // inline `makeTestStore()` would die at the end of the expression that built the manager.
        let host = makeTestStore()
        let manager = MeshNetworkManager(store: host, transport: FakeMeshTransportSession())
        defer { manager.stopJoin() }
        let armedAt = Date()
        let interval = MeshNetworkManager.discoveryGiveUpInterval

        manager.applyRunState(links: .run, discovery: .run)
        #expect(manager.isSearching, "the `.fresh` row armed the radios")
        #expect(!manager.hasCommittedPeer, "with nobody committed, which is what makes it `.fresh`")
        #expect(manager.isSessionGiveUpClockArmed, """
            and the give-up clock came with them — retiring the app's armDiscoveryTimeout() without \
            this arm would have left a fresh search with no door 3 at all
            """)

        manager.evaluateSessionGiveUp(now: armedAt.addingTimeInterval(interval - 60))
        #expect(manager.isSearching, "a minute short of the interval is not the interval")
        #expect(audit.count(of: "mesh.session.endedByDiscoveryTimeout") == 0, "nothing has given up")

        manager.evaluateSessionGiveUp(now: armedAt.addingTimeInterval(interval + 60))
        #expect(!manager.isSearching, "past the deadline the search stands down")
        #expect(audit.count(of: "mesh.session.endedByDiscoveryTimeout") == 1,
                "through endSessionAfterDiscoveryTimeout(), which is what the app's one-shot called")
        #expect(!manager.isSessionGiveUpClockArmed, "and the clock stands down with it")
    }

    /// The other half of the same clock: a committed peer cancels it rather than deferring it.
    ///
    /// A search with a peer in it is not giving up on anything, so the wake that arrives after the
    /// original deadline must find nothing to end. Two guards make that true and both are shipping:
    /// `evaluateSessionGiveUp(now:)` cancels outright on `hasCommittedPeer`, and
    /// `endSessionAfterDiscoveryTimeout()` refuses the same predicate at the far end.
    @Test func aCommittedPeerCancelsTheFreshSearchesGiveUpClock() {
        let audit = RunStateAuditCapture()
        audit.install()
        defer { audit.uninstall() }
        // The host is held for the manager's whole life (rule ML5): `store` is `unowned`, so an
        // inline `makeTestStore()` would die at the end of the expression that built the manager.
        let host = makeTestStore()
        let manager = MeshNetworkManager(store: host, transport: FakeMeshTransportSession())
        defer { manager.stopJoin() }
        let armedAt = Date()

        manager.applyRunState(links: .run, discovery: .run)
        #expect(manager.isSessionGiveUpClockArmed, "the fresh search is counting down")

        MeshP3Acceptance.attachSlot(to: manager, fingerprint: "00000000000000dd")
        #expect(manager.hasCommittedPeer, "a peer commits inside the window")

        manager.evaluateSessionGiveUp(
            now: armedAt.addingTimeInterval(MeshNetworkManager.discoveryGiveUpInterval + 60)
        )
        #expect(!manager.isSessionGiveUpClockArmed, "so the clock is cancelled, not fired")
        #expect(manager.isSearching, "the radios stay up over a committed peer")
        #expect(audit.count(of: "mesh.session.endedByDiscoveryTimeout") == 0, "and nothing gave up")
    }

    /// `stop` with no committed peer stands the radios down — and a second `stop` is silent.
    ///
    /// This is the whole of the retired `ContentView.stopFriendsDiscovery()` when its
    /// `hasCommittedPeer` guard passed, and it is the only row of the table in which `stopJoin()`
    /// runs at all.
    @Test func aStopWithNoCommittedPeerStandsTheRadiosDown() {
        let audit = RunStateAuditCapture()
        audit.install()
        defer { audit.uninstall() }
        // The host is held for the manager's whole life (rule ML5): `store` is `unowned`, so an
        // inline `makeTestStore()` would die at the end of the expression that built the manager.
        let host = makeTestStore()
        let manager = MeshNetworkManager(store: host, transport: FakeMeshTransportSession())

        manager.applyRunState(links: .run, discovery: .run)
        #expect(manager.isSearching, "armed, so there is something to stand down")
        #expect(!manager.hasCommittedPeer, "with nobody committed, which is what lets the stop through")

        manager.applyRunState(links: .stop, discovery: .stop)
        #expect(!manager.isSearching, "the radios are down")
        #expect(audit.count(of: ProximityRunStateSeam.applied) == 2, "one line for the arm, one for the stand-down")
        #expect(audit.count(of: ProximityRunStateSeam.held) == 0, "and nothing was refused")

        manager.applyRunState(links: .stop, discovery: .stop)
        #expect(!manager.isSearching, "a second stop over a quiet manager changes nothing")
        #expect(audit.count(of: ProximityRunStateSeam.applied) == 2, "and says nothing")
    }

    /// **The trap.** A links `stop` over a COMMITTED peer ends no mesh.
    ///
    /// `stopJoin()` runs `stopSearching()`, which empties `slots`, drops `slotTrustPolicies`,
    /// cancels every slot coordinator and runs `clearGroupKeyState()` — so running it here is
    /// ending a live session, not standing radios down. The app being backgrounded or leaving the
    /// tab is the OS suspending the links; the session survives as `.linksLost` → partition →
    /// restore. The guard is `hasCommittedPeer`, never `isSessionLive` and never `isInSession`.
    @Test func aStopOverACommittedPeerTearsNothingDown() {
        let audit = RunStateAuditCapture()
        audit.install()
        defer { audit.uninstall() }
        // The host is held for the manager's whole life (rule ML5): `store` is `unowned`, so an
        // inline `makeTestStore()` would die at the end of the expression that built the manager.
        let host = makeTestStore()
        let manager = MeshNetworkManager(store: host, transport: FakeMeshTransportSession())
        defer { manager.stopJoin() }

        manager.applyRunState(links: .run, discovery: .run)
        MeshP3Acceptance.attachSlot(to: manager, fingerprint: "00000000000000aa")
        #expect(manager.hasCommittedPeer, "a peer is committed right now")
        #expect(manager.isSessionLive, "so the session is live")
        let slotCount = manager.slots.count
        let slotFingerprints = manager.slots.compactMap(\.fingerprint)

        manager.applyRunState(links: .stop, discovery: .stop)

        #expect(manager.hasCommittedPeer, "the committed peer survives the stand-down request")
        #expect(manager.isSessionLive, "and so does the session — a stop is not a teardown")
        #expect(manager.slots.count == slotCount, "the slots are intact")
        #expect(manager.slots.compactMap(\.fingerprint) == slotFingerprints, "fingerprints and all")
        #expect(manager.isSearching, "and the radios were never stood down, because that IS the teardown")
        #expect(audit.count(of: ProximityRunStateSeam.applied) == 1, "only the arm moved anything")
        #expect(audit.heldReasons() == [ProximityRunStateSeam.committedPeer],
                "and the refusal names the predicate it bailed on")
    }

    /// The `.resume` row: a `run` over a mesh that outlived its links RESUMES, never restarts.
    ///
    /// The arm that had no cell at all before this fix (review finding P2-4). Construction is the
    /// cheapest one that produces the state the row names — a mesh held, no committed slot, radios
    /// down — by assigning the descriptor the way a dozen mesh suites already do
    /// (`MeshP3Acceptance.mesh(for:)`), rather than standing a two-node founding rig up for it.
    ///
    /// **`isProximityJoin` is the observable that separates the two arms.** `startJoin()` sets it
    /// `true` unconditionally, while `resumeSearchingForPartitionedMesh()` RESTORES it from
    /// `sessionEnteredByProximityJoin`, which is `false` for a session this cell never entered by
    /// proximity join. So "searching, over the same mesh, and still not in proximity-join mode" is
    /// exactly "the resume ran and the fresh start did not" — which is the whole claim of the row,
    /// because `startJoin()` here would have nilled a session ceiling that can never be re-armed.
    @Test func aRunOverAMeshThatOutlivedItsLinksResumesRatherThanRestarts() {
        let audit = RunStateAuditCapture()
        audit.install()
        defer { audit.uninstall() }
        // The host is held for the manager's whole life (rule ML5): `store` is `unowned`, so an
        // inline `makeTestStore()` would die at the end of the expression that built the manager.
        let host = makeTestStore()
        let manager = MeshNetworkManager(store: host, transport: FakeMeshTransportSession())
        defer { manager.stopJoin() }
        let mesh = MeshP3Acceptance.mesh(for: manager)
        manager.currentMesh = mesh

        #expect(manager.isInSession, "a mesh is held")
        #expect(!manager.hasCommittedPeer, "with nobody committed — the `.resume` row exactly")
        #expect(!manager.isSearching, "and the radios are down, as a tab exit leaves them")

        manager.applyRunState(links: .run, discovery: .run)

        #expect(manager.isSearching, "the radios come back")
        #expect(!manager.isProximityJoin, "through the resume: startJoin() would have set this true")
        #expect(manager.currentMesh?.meshID == mesh.meshID, "over the SAME mesh — nothing re-founded")
        #expect(audit.count(of: ProximityRunStateSeam.applied) == 1, "and the change is named once")
        #expect(audit.count(of: ProximityRunStateSeam.held) == 0, "with nothing refused")
    }

    /// The `.resume` row's refusal: an ENDED session's mesh is never re-entered, and now it says so.
    ///
    /// `resumeSearchingForPartitionedMesh()` bails on `sessionState.hasEnded` — the rejoin bar: a
    /// departed, terminated or expired session can never be resumed, and its mesh object outlives
    /// the ending until `leaveMesh()` runs. It bails by RETURNING, so before this fix this was the
    /// one "moved nothing" row of the door's table with no audit line at all, while every other one
    /// logs `held` (review finding P2-4).
    ///
    /// The ending is driven through the state machine's cheapest terminal edge — a launch restore
    /// that finds a terminated context, which moves `idle → terminated` carrying no effects at all,
    /// so nothing here tears a session down behind the cell's back.
    @Test func aRunOverAnEndedSessionsMeshIsRefusedAndNamed() {
        let audit = RunStateAuditCapture()
        audit.install()
        defer { audit.uninstall() }
        // The host is held for the manager's whole life (rule ML5): `store` is `unowned`, so an
        // inline `makeTestStore()` would die at the end of the expression that built the manager.
        let host = makeTestStore()
        let manager = MeshNetworkManager(store: host, transport: FakeMeshTransportSession())
        defer { manager.stopJoin() }
        let mesh = MeshP3Acceptance.mesh(for: manager)
        manager.currentMesh = mesh
        manager.applySessionEvent(.contextRestored(.terminated))

        #expect(manager.sessionState == .terminated, "the session ended under a mesh that is still held")
        #expect(manager.isInSession, "so the door still reads this as the `.resume` row")
        #expect(!manager.isSearching, "with the radios down")

        manager.applyRunState(links: .run, discovery: .run)

        #expect(!manager.isSearching, "the radios stay down: an ended session is never re-entered")
        #expect(manager.currentMesh?.meshID == mesh.meshID, "and the mesh object outlives the ending")
        #expect(audit.count(of: ProximityRunStateSeam.applied) == 0, "nothing moved, so nothing is claimed")
        #expect(audit.heldReasons() == [ProximityRunStateSeam.resumeRefused],
                "and the refusal has a name, which is the row that used to be silent")
    }

    /// The `.none` row: a `run` over a committed peer with the radios down does nothing, silently.
    ///
    /// The radios already have a peer, so re-entering discovery is never the safe move — and unlike
    /// the two `held` rows this one refuses nothing: no directive was denied, the entry decision
    /// simply has no call to make. A silence rather than a line is the claim, so the cell counts
    /// both tokens at zero.
    @Test func aRunOverACommittedPeerWithTheRadiosDownDoesNothingAtAll() {
        let audit = RunStateAuditCapture()
        audit.install()
        defer { audit.uninstall() }
        // The host is held for the manager's whole life (rule ML5): `store` is `unowned`, so an
        // inline `makeTestStore()` would die at the end of the expression that built the manager.
        let host = makeTestStore()
        let manager = MeshNetworkManager(store: host, transport: FakeMeshTransportSession())
        defer { manager.stopJoin() }
        MeshP3Acceptance.attachSlot(to: manager, fingerprint: "00000000000000bb")

        #expect(manager.hasCommittedPeer, "a peer is committed")
        #expect(!manager.isSearching, "and the radios are down — `FriendsDiscoveryEntry.none`")

        manager.applyRunState(links: .run, discovery: .run)

        #expect(!manager.isSearching, "nothing was armed")
        #expect(audit.count(of: ProximityRunStateSeam.applied) == 0, "nothing moved, so nothing is claimed")
        #expect(audit.count(of: ProximityRunStateSeam.held) == 0, "and nothing was refused, so nothing is named")
    }

    /// A refusal is named once per CHANGE, not once per call (review finding P2-5).
    ///
    /// `applied` has always been a change line; `held` was a per-call one, and from pass B the
    /// caller is `ProximityRunPolicyHost`, which deduplicates nothing and re-decides on every leg
    /// setter. A backgrounded session holding a committed peer would then have emitted one
    /// `held committedPeer` per lifecycle edge for as long as the session lasted. The door now
    /// remembers the last `(links, discovery)` pair and the last reason, which is the smallest
    /// memory that makes the second identical push silent while keeping a CHANGED refusal loud.
    @Test func aRepeatedRefusalIsNamedOnceAndAChangedOneIsNamedAgain() {
        let audit = RunStateAuditCapture()
        audit.install()
        defer { audit.uninstall() }
        // The host is held for the manager's whole life (rule ML5): `store` is `unowned`, so an
        // inline `makeTestStore()` would die at the end of the expression that built the manager.
        let host = makeTestStore()
        let manager = MeshNetworkManager(store: host, transport: FakeMeshTransportSession())
        defer { manager.stopJoin() }

        manager.applyRunState(links: .run, discovery: .run)
        MeshP3Acceptance.attachSlot(to: manager, fingerprint: "00000000000000cc")

        manager.applyRunState(links: .stop, discovery: .stop)
        #expect(audit.heldReasons() == [ProximityRunStateSeam.committedPeer], "the refusal is named once")

        manager.applyRunState(links: .stop, discovery: .stop)
        #expect(audit.heldReasons() == [ProximityRunStateSeam.committedPeer],
                "and an identical second push adds nothing: `held` is a CHANGE line too now")
        #expect(manager.isSearching, "with the committed session still up, which is what it refused for")

        manager.applyRunState(links: .run, discovery: .stop)
        #expect(audit.heldReasons() == [ProximityRunStateSeam.committedPeer,
                                        ProximityRunStateSeam.noStandAloneDiscoveryStop],
                "a DIFFERENT pair is a different refusal, and the dedupe never swallows one")
        #expect(audit.count(of: ProximityRunStateSeam.applied) == 1, "and only the first arm ever moved anything")
    }

    /// The **P8-only** combination — links `run`, discovery `stop` — moves nothing, and says why.
    ///
    /// A mesh continued in the background whose admission door should be shut needs a primitive that
    /// stops browsing and advertising while KEEPING the committed links. There is none:
    /// `stopSearching()` is the only stand-down there is, and it takes the slots and the group key
    /// with it. Inventing that primitive is P8's work; until then the safe answer is to move
    /// nothing, and the audit token is how the claim stays visible.
    @Test func theP8OnlyCombinationMovesNothingAndNamesItself() {
        let audit = RunStateAuditCapture()
        audit.install()
        defer { audit.uninstall() }
        // The host is held for the manager's whole life (rule ML5): `store` is `unowned`, so an
        // inline `makeTestStore()` would die at the end of the expression that built the manager.
        let host = makeTestStore()
        let manager = MeshNetworkManager(store: host, transport: FakeMeshTransportSession())
        defer { manager.stopJoin() }

        manager.applyRunState(links: .run, discovery: .run)
        #expect(manager.isSearching, "the radios are up")

        manager.applyRunState(links: .run, discovery: .stop)

        #expect(manager.isSearching, "and stay up: nothing can shut the admission door on its own")
        #expect(audit.count(of: ProximityRunStateSeam.applied) == 1, "nothing changed, so nothing is claimed")
        #expect(audit.heldReasons() == [ProximityRunStateSeam.noStandAloneDiscoveryStop],
                "the combination names itself rather than being silently rounded to a stop")
    }

    /// `foregroundOnly` at the mesh seam behaves as `run`, and both radios are named.
    ///
    /// The host resolves before it calls; a directive that arrives unresolved is a caller bug, and
    /// the seam's answer is the fail-safe one plus a line per radio.
    @Test func aForegroundOnlyAtTheMeshSeamBehavesAsRun() {
        let audit = RunStateAuditCapture()
        audit.install()
        defer { audit.uninstall() }
        // The host is held for the manager's whole life (rule ML5): `store` is `unowned`, so an
        // inline `makeTestStore()` would die at the end of the expression that built the manager.
        let host = makeTestStore()
        let manager = MeshNetworkManager(store: host, transport: FakeMeshTransportSession())
        defer { manager.stopJoin() }

        manager.applyRunState(links: .foregroundOnly, discovery: .foregroundOnly)

        #expect(manager.isSearching, "an unresolved directive resolves UP, never into a stand-down")
        #expect(audit.count(of: ProximityRunStateSeam.unresolved) == 2, "one line per radio")
        #expect(audit.count(of: ProximityRunStateSeam.applied) == 1, "and one line for the change it caused")
    }

    /// The presence seam: `stop` stands the radio down once, and a second `stop` is silent.
    ///
    /// Driven from the RUNNING side through `activateForTesting()`, which flips the run flag without
    /// bringing up Bonjour — `start()` would advertise for real. This is also the direction shipping
    /// takes when the nearby-presence consent goes off and when a wipe runs, both of which pass B
    /// re-aimed at the policy: `FernletStore.setAllowNearbyPresence(false)` now only writes the
    /// setting, and the wipe funnel raises `deletingAllDataHook` instead of stopping one radio.
    @Test func thePresenceSeamStandsTheRadioDownOnceAndIsIdempotent() {
        let audit = RunStateAuditCapture()
        audit.install()
        defer { audit.uninstall() }
        let host = RunStateSeamHost()
        let manager = PresenceManager(store: host, ledger: makeSeamHeartLedger())
        manager.activateForTesting()
        #expect(manager.isRunning, "the radio is up (without a real advertiser)")

        manager.applyRunState(.stop)
        #expect(!manager.isRunning, "the seam stands it down")
        #expect(audit.count(of: ProximityRunStateSeam.applied) == 1, "and names the change once")

        manager.applyRunState(.stop)
        #expect(!manager.isRunning, "a second stop changes nothing")
        #expect(audit.count(of: ProximityRunStateSeam.applied) == 1, "and says nothing")
    }

    /// The recipe seam: the same three claims, over the listener's own run flag.
    ///
    /// `markRunningForTesting()` is the established seam for exactly this — `start()` brings up a
    /// real browser and advertiser, which `ProximityRecipeShareCapTests` has never allowed either.
    @Test func theRecipeSeamStandsTheListenerDownOnceAndIsIdempotent() {
        let audit = RunStateAuditCapture()
        audit.install()
        defer { audit.uninstall() }
        let host = RunStateSeamHost()
        let manager = ProximityRecipeShareManager(store: host)
        manager.markRunningForTesting()
        #expect(manager.isRunningForTesting, "the listener is up (without a real browser)")

        manager.applyRunState(.stop)
        #expect(!manager.isRunningForTesting, "the seam stands it down")
        #expect(audit.count(of: ProximityRunStateSeam.applied) == 1, "and names the change once")

        manager.applyRunState(.stop)
        #expect(!manager.isRunningForTesting, "a second stop changes nothing")
        #expect(audit.count(of: ProximityRunStateSeam.applied) == 1, "and says nothing")
    }

    /// A `run` over an ALREADY-running listener touches no radio and claims no change.
    ///
    /// The half of the `run` arm a unit test can reach without starting Bonjour, and the half a
    /// wrong guard would actually break: without the `isRunning` check, every push would re-enter
    /// `start()` and re-mint the radio's ephemeral peer id mid-run. `foregroundOnly` is driven
    /// through the same arm, so the "a seam treats it as run" claim is made at a real seam rather
    /// than only at the resolver.
    @Test func aRunOverAnAlreadyRunningRadioTouchesNothing() {
        let audit = RunStateAuditCapture()
        audit.install()
        defer { audit.uninstall() }
        let presenceHost = RunStateSeamHost()
        let presence = PresenceManager(store: presenceHost, ledger: makeSeamHeartLedger())
        let recipeHost = RunStateSeamHost()
        let recipe = ProximityRecipeShareManager(store: recipeHost)
        presence.activateForTesting()
        recipe.markRunningForTesting()

        presence.applyRunState(.run)
        recipe.applyRunState(.foregroundOnly)

        #expect(presence.isRunning, "presence is still up")
        #expect(recipe.isRunningForTesting, "and so is the recipe listener")
        #expect(audit.count(of: ProximityRunStateSeam.applied) == 0,
                "neither claimed a change, because neither made one")
        #expect(audit.count(of: ProximityRunStateSeam.unresolved) == 1,
                "and the unresolved directive was named at the seam, not only at the resolver")
        presence.applyRunState(.stop)
        recipe.applyRunState(.stop)
    }
}
