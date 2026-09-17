// ProximityRunPolicyHost.swift
// Fernlet
//
// Network migration P7 items 2 and 3 (plan §13, §24.1): the ONE app-target site that assembles
// `ProximityRunInputs` from the live lifecycle facts, calls `ProximityRunPolicy.decide(_:)`, and
// writes the answer through five injected doors — the routed access gate
// (`MeshNetworkManager.applyRoutedAccessGate(_:now:)`), the three `applyRunState` radio seams, and
// the session teardown.
//
// `FernletApp.pushRoutedAccessGate(_:protectedData:foreground:)` used to assemble the gate at SIX
// call sites. The EDGES survive — a fact that moves at a scene transition, at a protected-data
// notification, at the duress `.onChange` and at the launch mount each still needs its own observer,
// and the duress one moves at neither of the other two transitions — but the assembly and the
// manager calls happen here, once. Item 3 added five more edges for the facts the RADIOS read and
// the gate does not: the app-lock state beside duress (`FernletApp`), and the tab, the two nearby
// consents, the chat-age record and the committed-peer fact (`ContentView`), plus the wipe flag the
// store raises through a hook.
// `applyRoutedAccessGate(_:now:)` itself does not move: it was built in P5 item 10 as the
// `apply(_:)`-shaped door P7 would become the single writer of, its five-job re-entry is bounded,
// idempotent and audited, and `ProximityRunPolicyHostTests` counts the call sites outside
// ProximityKit at exactly one.
//
// What this type is NOT:
//
//   * It is not a coordinator. P8's `MeshContinuationCoordinator` owns that word and the
//     continuation task it names; ``ProximityRunPolicyHost/continuationTask`` is `.inert` here and
//     item 3 of P8 is what makes it move.
//   * It starts no `Task`, arms no timer, registers for no notification and persists NOTHING. P7
//     adds no persisted surface (the phase decision), so `Docs/PrivacyWipeCoverage.md` owes this
//     file no row and delete-all owes it no writer. It holds five closures, ten values and one
//     latch.
//   * It is not a second opinion about any radio. Every directive it hands a seam is
//     ``ProximityRunDecision/isUp(_:)``'s answer collapsed to `run` / `stop`, so
//     `foregroundOnly` — a policy answer about two scene phases — never reaches a manager, and the
//     managers' own `applyRunState` doors stay the only place a radio actually moves.
//
// And one boundary it inherits whole, D-10.3: the gate says what may be DECRYPTED, never which
// radios run. Nothing here reads `isOpen` or `permits(_:)`, and the gate value is carried from the
// decision untouched — this file constructs no `MeshRoutedAccessGate` of its own.

import ProximityKit
import SwiftUI

/// The app's single writer of the routed access gate and of the four proximity radios (network
/// migration P7 items 2 and 3).
///
/// **Legs in, one decision out.** Each setter records one lifecycle fact and then re-decides: the
/// host holds the latest value of every ``ProximityRunInputs`` field, hands them to
/// ``ProximityRunPolicy/decide(_:)``, and writes the decision's gate, its four radio directives and
/// its teardown flag through the injected doors. `FernletApp` and `ContentView` own the edges; this
/// type owns the assembly.
///
/// **There is exactly ONE instance, and it is `FernletApp`'s `@State`.** That is where the legs
/// are: the scene phase is the scene's `@Environment`, both protected-data notifications are
/// observed on that scene, and the app lock (with the duress session folded in) lives on
/// `FernletLockService`, which is `FernletApp`'s `@State` and not the store's. The other two
/// feeders are handed the same object rather than making one of their own — `ContentView` takes it
/// as an `init` parameter (an `@Environment` injection would need `@Observable`, and nothing here
/// is observed), and `FernletStore` never holds it at all: the wipe funnel reaches it through
/// ``FernletStore/deletingAllDataHook``, a closure `ContentView.attachDeleteAllHooks()` wires, so
/// the store holds no reference to the host that holds closures capturing the store.
///
/// **It deliberately does not deduplicate** — with one exception, the teardown, which is an edge
/// rather than a value and says so on ``didTearDownSession``. A setter pushes whether or not the
/// value moved, because every seam already owns its own edge:
/// `MeshNetworkManager.applyRoutedAccessGate(_:now:)` ignores an unchanged gate and decides which
/// edge owes a re-entry pass (`MeshRoutedAccessEdge`), and all three `applyRunState` doors are
/// idempotent in what they do AND in what they log (`mesh.runState.applied` is a CHANGE line, and
/// the mesh door dedupes its refusals against the last directive pair). A second opinion about edges
/// in the app is exactly what the P5 review found the six push sites drifting into — four compared
/// `== .active` while the scene handler fell only on `.background` — so the edge stays where it is
/// tested.
///
/// **The doors are injected, and they are installed as a set.** ``connect(accessGate:meshRadios:presence:recipeShare:tearDownSession:)``
/// takes the five closures that reach the loaded store's managers; until it runs there is no store,
/// hence no manager, hence nothing to write to, and every leg set before it is simply recorded.
/// That latch is the old `if case .ready(let store) = loader.phase` guard the six gate sites each
/// carried, held in one place — and it is what lets a test inject recording closures instead of a
/// mesh. Connecting again REPLACES the set rather than stacking a second one, so a store rebuilt
/// under the app is re-mounted by its own `.onAppear` and the doors follow it instead of pointing
/// at a dead store (`FernletStore` is never rebuilt in shipping — `FernletStoreLoader.retry()`
/// re-enters only from `.failed`, when no store was ever built — so in practice the second call is
/// a re-fired `.onAppear` re-installing equivalent closures for the same store).
///
/// **`@MainActor`, and no `Task` anywhere.** Every fact it reads is main-actor state (the scene, the
/// lock service, the store's settings, the mesh manager) and the door it calls is a main-actor
/// method, so there is nothing to hop for. `MemoryLifecycleBoundaryTests` ML1/ML4 have no subject
/// here: this host stores no task handle and holds no `ProximityHost`.
@MainActor
final class ProximityRunPolicyHost {

    // MARK: - The doors

    /// The injected gate writer: `MeshNetworkManager.applyRoutedAccessGate(_:now:)` in production,
    /// a recording closure in tests. Nil until
    /// ``connect(accessGate:meshRadios:presence:recipeShare:tearDownSession:)`` runs, which is the
    /// whole of this type's "is there a store yet" question — the four doors below are installed in
    /// the same call, so this one being nil answers it for all five.
    private var writeAccessGate: (@MainActor (MeshRoutedAccessGate, Date) -> Void)?

    /// The injected mesh seam: `MeshNetworkManager.applyRunState(links:discovery:)`.
    ///
    /// ONE door for two radios, because `startJoin()` / `stopJoin()` already is one — see that
    /// method's table. Both directives arrive together so the manager decides once instead of
    /// acting on half a decision.
    private var applyMeshRunState: (@MainActor (ProximityRunState, ProximityRunState) -> Void)?

    /// The injected presence seam: `PresenceManager.applyRunState(_:)`.
    private var applyPresenceRunState: (@MainActor (ProximityRunState) -> Void)?

    /// The injected recipe-share seam: `ProximityRecipeShareManager.applyRunState(_:)`.
    private var applyRecipeShareRunState: (@MainActor (ProximityRunState) -> Void)?

    /// The injected teardown: what the app runs for plan §13's three dominating inputs (delete-all,
    /// below-age, duress) once the radios have been stood down.
    ///
    /// A door of its own rather than a fourth directive, because "stand down" and "end the session"
    /// are different acts and the seams above deliberately only do the first: the mesh door refuses
    /// a links `stop` over a committed peer precisely so a backgrounding cannot end a live mesh, and
    /// a teardown has to get past that refusal.
    private var tearDownSession: (@MainActor () -> Void)?

    /// Whether the teardown has already run for the condition that is still in force — the RISING
    /// edge latch.
    ///
    /// ``ProximityRunDecision/tearsDownSession`` is a level, not an edge: it stays true for as long
    /// as the wipe runs, the duress session lasts or the below-age verdict stands, and every leg
    /// setter re-decides. Without this latch a tab switch during a wipe would run the whole teardown
    /// again. Cleared the moment the decision stops demanding one, so a second duress session in the
    /// same launch tears down again.
    ///
    /// **Clearing it RE-ARMS the radios, and for a delete-all that is reachable and deliberate.**
    /// `FernletStore.deleteAllData(includingHealthKitSamples:)` lowers its leg from a `defer`, so a
    /// wipe that finishes with the user parked on the Friends tab, foreground and unlocked, pushes
    /// `run` again the instant the success sheet appears — a fresh `startJoin()` and a fresh
    /// give-up clock, with no further user act. That is an IMPROVEMENT rather than a leak: leg 11
    /// (`wipeIdentityForDeleteAll()`) runs before the `defer`, so the new search advertises a
    /// freshly minted identity, where before pass B the mesh advertised on the OLD identity
    /// straight through the wipe and after it.
    private var didTearDownSession = false

    // MARK: - The legs

    /// The scene phase, fed to ``ProximityRunInputs``' initialiser and never compared here —
    /// `FernletApp.routedGateForeground(for:)` is the one phase-to-foreground translation and that
    /// initialiser is the only way to reach it.
    ///
    /// Starts `.background`, the fail-closed value: nothing is written before the doors are
    /// installed, and `FernletApp.mountRoutedRunPolicy(_:)` seeds the live phase before the launch
    /// push.
    private var scenePhase: ScenePhase = .background

    /// iOS data protection, fed literally from the two `UIApplication` notifications — the
    /// notification IS the fact, because `isProtectedDataAvailable` still answers `true` inside the
    /// will-become-unavailable handler. Starts fail-closed.
    private var isProtectedDataAvailable = false

    /// The app lock with the duress session folded in
    /// (``ProximityAppLockState/resolve(_:isDuressSessionActive:)``).
    ///
    /// Fed at the duress `.onChange`, at the lock-state `.onChange` beside it, and at the launch
    /// mount — which is every moment either half can move: `duressActive` is the only clause of
    /// Fernlet's own app lock that reaches the GATE (D-10.3), a duress session is entered and
    /// cleared at an already-foreground lock screen, and the `.locked` / `.unlocked` distinction
    /// moves the two listeners. Both edges live on `FernletApp`, because `FernletLockService` is its
    /// `@State` and not the store's.
    private var appLockState: ProximityAppLockState = .locked

    /// The tab on screen, fed by `ContentView.handleTabChange(from:to:)`. The launch value is
    /// `ContentView.selectedTab`'s own initial value (`.home`), so the seed is honest
    /// until the user moves. The gate does not read it.
    ///
    /// One further feeder, DEBUG-only and never on a user's device: `MeshRejectionMatrixHarness`
    /// sets it to `.social` after arming the Lane C search, because a runbook lane drives no UI and
    /// the `.home` seed would otherwise have the policy stand that search down at the next leg
    /// change. It is a leg, not a radio — the harness tells the policy where the run is, and the
    /// policy still decides.
    private var selectedTab: FernletTab = .home

    /// The 13+ chat gate, read off `AgeAssuranceStore.record` at the launch mount and re-fed by
    /// `ContentView`'s `.onChange` on that record — the value, not the setter, so every writer of a
    /// verdict is covered. The gate does not read it.
    private var chatAgeGate: ProximityChatAgeGate = .undetermined

    /// Whether a delete-all / privacy wipe is running.
    ///
    /// Raised at the top of `FernletStore.deleteAllData(includingHealthKitSamples:)` and lowered
    /// when it returns, through ``FernletStore/deletingAllDataHook``. `false` at launch is the
    /// honest seed: the per-screen `DeleteEverythingFlow.isDeleting` describes one sheet, not the
    /// app, and no wipe is in flight before the store is loaded. The gate does not read it.
    private var isDeletingAllData = false

    /// `MeshNetworkManager.hasCommittedPeer` — the predicate the decision table names for radio
    /// guards, never `isSessionLive` (projections and ceremonies) and never `isInSession` (the
    /// layout swap). Seeded at the launch mount and re-fed by `ContentView`'s `.onChange` on the
    /// manager's own observable answer, which covers the commit door and both slot-loss doors at
    /// once. The gate does not read it.
    private var hasCommittedPeer = false

    /// `FernletStore.settings.allowNearbyPresence`, seeded at the launch mount and re-fed by
    /// `ContentView`'s `.onChange` on the VALUE — which covers the Settings toggle, the first-friend
    /// prompt, the wipe's `resetAll()` and a change synced in from another device alike, where
    /// watching `setAllowNearbyPresence(_:)` would cover only the first two. The gate does not read
    /// it.
    private var allowsNearbyPresence = false

    /// `FernletStore.settings.allowNearbyRecipeShares`, seeded at the launch mount and re-fed by
    /// `ContentView`'s `.onChange` on the value, for the same reason as the consent above. The gate
    /// does not read it.
    private var allowsNearbyRecipeShares = false

    /// The background continuation task — **inert until P8**, which is the only phase that can
    /// submit one. A `let` rather than a leg, so nothing in P7 can pretend a task exists: plan §13
    /// already decides the other three states, so P8 adds a setter here and no policy argument.
    private let continuationTask: ProximityContinuationTaskState = .inert

    // MARK: - Wiring

    /// Installs the five doors this host writes through, as one set.
    ///
    /// A second call REPLACES the set. The ready view's `.onAppear` re-fires on every reappearance
    /// and hands back closures over the same store, so replacing is a no-op there; what it buys is
    /// the case a one-shot latch would get wrong — a store rebuilt under the app would re-mount with
    /// doors still pointing at the dead one. Nothing is stacked: the previous closures are released
    /// with the assignment, so there is never a second writer of anything.
    ///
    /// The production closures are the ONLY `applyRoutedAccessGate(`, `applyRunState(` and
    /// `stopJoin()` call sites outside ProximityKit —
    /// `ProximityRunPolicyHostTests.theRoutedAccessGateHasExactlyOneWriterInTheAppTarget()` and
    /// `…theProximityRadiosAreDrivenOnlyFromTheHostsDoors()` count them.
    ///
    /// Connecting pushes NOTHING on its own: `FernletApp.mountRoutedRunPolicy(_:)` seeds every leg
    /// it can before calling this, so the launch is one push rather than one per leg, and
    /// ``pushNow()`` is the explicit act that makes it.
    ///
    /// - Parameters:
    ///   - accessGate: Production passes `store.meshNetworkManager.applyRoutedAccessGate(_:now:)`.
    ///   - meshRadios: Production passes
    ///     `store.meshNetworkManager.applyRunState(links:discovery:)`.
    ///   - presence: Production passes `store.presenceManager.applyRunState(_:)`.
    ///   - recipeShare: Production passes `store.recipeShareManager.applyRunState(_:)`.
    ///   - tearDownSession: Production runs the mesh, presence and recipe teardown the app used to
    ///     spell across `FernletStore`'s wipe funnel and the lock service's duress purge.
    func connect(
        accessGate: @escaping @MainActor (MeshRoutedAccessGate, Date) -> Void,
        meshRadios: @escaping @MainActor (ProximityRunState, ProximityRunState) -> Void,
        presence: @escaping @MainActor (ProximityRunState) -> Void,
        recipeShare: @escaping @MainActor (ProximityRunState) -> Void,
        tearDownSession: @escaping @MainActor () -> Void
    ) {
        writeAccessGate = accessGate
        applyMeshRunState = meshRadios
        applyPresenceRunState = presence
        applyRecipeShareRunState = recipeShare
        self.tearDownSession = tearDownSession
    }

    /// Every fact the policy reads, as this host currently knows them.
    ///
    /// Exposed rather than private so a test can hold the pushed gate against
    /// `ProximityRunPolicy.decide(inputs).accessGate` for the SAME inputs rather than re-spelling
    /// them, and so P7 item 3 can read the directives off one decision instead of building a second
    /// set of inputs beside this one.
    var inputs: ProximityRunInputs {
        ProximityRunInputs(
            scenePhase: scenePhase,
            selectedTab: selectedTab,
            lockState: appLockState,
            isProtectedDataAvailable: isProtectedDataAvailable,
            chatAgeGate: chatAgeGate,
            isDeletingAllData: isDeletingAllData,
            continuationTask: continuationTask,
            hasCommittedPeer: hasCommittedPeer,
            allowsNearbyPresence: allowsNearbyPresence,
            allowsNearbyRecipeShares: allowsNearbyRecipeShares
        )
    }

    /// Decides over ``inputs`` and writes the whole decision through the injected doors.
    ///
    /// **The order is the wiring decision.** The gate first, unchanged from P7 item 2 — it says what
    /// may be DECRYPTED and its five-job re-entry has to run against this instant's facts before any
    /// radio moves. Then the radios, each with its directive already resolved. Then the teardown,
    /// last, because it has to get past the mesh door's committed-peer refusal rather than race it.
    ///
    /// A no-op before ``connect(accessGate:meshRadios:presence:recipeShare:tearDownSession:)``:
    /// there is no manager to write to until the store is loaded, which is the guard each of the six
    /// former push sites carried for itself.
    func pushNow() {
        guard let writeAccessGate else { return }
        let decision = ProximityRunPolicy.decide(inputs)
        writeAccessGate(decision.accessGate, Date())
        pushRadios(decision)
        pushTeardown(decision)
    }

    /// Hands each seam its RESOLVED directive.
    ///
    /// ``ProximityRunState/foregroundOnly`` never leaves this function: a directive is an answer
    /// about two scene phases and a manager knows about neither, so the host applies
    /// ``ProximityRunDecision/isUp(_:)`` — which resolves against the one foreground fact — and
    /// sends `run` or `stop`. `ProximityRunStateSeam.unresolved` exists to catch a caller that does
    /// not, and `ProximityRunPolicyHostTests` pins that this one never trips it.
    ///
    /// - Parameter decision: The policy's answer for the facts the host currently holds.
    private func pushRadios(_ decision: ProximityRunDecision) {
        applyMeshRunState?(
            Self.resolved(decision, .meshLinks), Self.resolved(decision, .discoveryAdmission)
        )
        applyPresenceRunState?(Self.resolved(decision, .presence))
        applyRecipeShareRunState?(Self.resolved(decision, .recipeShare))
    }

    /// One radio's directive, resolved against the decision's own foreground fact.
    ///
    /// - Parameters:
    ///   - decision: The policy's answer.
    ///   - radio: The radio being asked about.
    /// - Returns: ``ProximityRunState/run`` when it is up right now, ``ProximityRunState/stop``
    ///   otherwise — never ``ProximityRunState/foregroundOnly``.
    private static func resolved(
        _ decision: ProximityRunDecision, _ radio: ProximityRadio
    ) -> ProximityRunState {
        decision.isUp(radio) ? .run : .stop
    }

    /// Runs the teardown on the RISING edge of ``ProximityRunDecision/tearsDownSession``, and not
    /// again until the condition clears.
    ///
    /// The flag is a level: a wipe holds it for the length of the funnel, a duress session until a
    /// real-passcode unlock, a below-age verdict for good. Every leg setter re-decides, so without
    /// the latch a tab switch or a scene bounce mid-wipe would re-run the whole teardown.
    ///
    /// - Parameter decision: The policy's answer for the facts the host currently holds.
    private func pushTeardown(_ decision: ProximityRunDecision) {
        guard decision.tearsDownSession else {
            didTearDownSession = false
            return
        }
        guard !didTearDownSession else { return }
        didTearDownSession = true
        tearDownSession?()
    }

    // MARK: - The legs the app feeds today

    /// Records the scene phase and re-decides — P5 item 10's two foreground legs, and the launch
    /// seed.
    ///
    /// The phase is stored raw and handed to ``ProximityRunInputs``' initialiser, which is the only
    /// door onto `FernletApp.routedGateForeground(for:)`. Nothing here compares it: `ScenePhase` is
    /// not frozen, and an inactive scene is a foreground scene.
    ///
    /// - Parameter phase: The phase the scene just entered.
    func setScenePhase(_ phase: ScenePhase) {
        scenePhase = phase
        pushNow()
    }

    /// Records iOS data protection and re-decides — the two notification legs, and the launch seed.
    ///
    /// - Parameter isAvailable: Whether protected data is available, passed literally from the
    ///   notification that says so.
    func setProtectedDataAvailable(_ isAvailable: Bool) {
        isProtectedDataAvailable = isAvailable
        pushNow()
    }

    /// Records the app lock (duress folded in) and re-decides — the duress `.onChange` leg, and the
    /// launch seed.
    ///
    /// - Parameter state: ``ProximityAppLockState/resolve(_:isDuressSessionActive:)``'s answer.
    func setAppLockState(_ state: ProximityAppLockState) {
        appLockState = state
        pushNow()
    }

    // MARK: - The legs P7 item 3 feeds

    /// Records the tab on screen and re-decides — `ContentView.handleTabChange(from:to:)`, which is
    /// where `startFriendsDiscovery()` / `stopFriendsDiscovery()` used to be called from.
    ///
    /// - Parameter tab: The tab on screen.
    func setSelectedTab(_ tab: FernletTab) {
        selectedTab = tab
        pushNow()
    }

    /// Records the 13+ chat gate and re-decides — the launch mount, and `ContentView`'s `.onChange`
    /// on `AgeAssuranceStore.record`.
    ///
    /// - Parameter gate: ``ProximityChatAgeGate/resolve(_:)``'s answer for this device's record.
    func setChatAgeGate(_ gate: ProximityChatAgeGate) {
        chatAgeGate = gate
        pushNow()
    }

    /// Records whether a delete-all is running and re-decides —
    /// `FernletStore.deleteAllData(includingHealthKitSamples:)`, through
    /// ``FernletStore/deletingAllDataHook``, raised before the first leg of the wipe and lowered
    /// from the funnel's `defer`.
    ///
    /// - Parameter isDeleting: Whether a privacy wipe is in flight.
    func setDeletingAllData(_ isDeleting: Bool) {
        isDeletingAllData = isDeleting
        pushNow()
    }

    /// Records the committed-peer fact and re-decides — the launch mount, and `ContentView`'s
    /// `.onChange` on `MeshNetworkManager.hasCommittedPeer`.
    ///
    /// - Parameter hasPeer: `MeshNetworkManager.hasCommittedPeer`, never `isSessionLive` and never
    ///   `isInSession` — three predicates, three jobs.
    func setHasCommittedPeer(_ hasPeer: Bool) {
        hasCommittedPeer = hasPeer
        pushNow()
    }

    /// Records the nearby-presence consent and re-decides — the launch mount, and `ContentView`'s
    /// `.onChange` on `store.settings.allowNearbyPresence`.
    ///
    /// - Parameter allows: `FernletStore.settings.allowNearbyPresence`.
    func setAllowsNearbyPresence(_ allows: Bool) {
        allowsNearbyPresence = allows
        pushNow()
    }

    /// Records the nearby-recipe-share consent and re-decides — the launch mount, and
    /// `ContentView`'s `.onChange` on `store.settings.allowNearbyRecipeShares`.
    ///
    /// - Parameter allows: `FernletStore.settings.allowNearbyRecipeShares`.
    func setAllowsNearbyRecipeShares(_ allows: Bool) {
        allowsNearbyRecipeShares = allows
        pushNow()
    }
}
