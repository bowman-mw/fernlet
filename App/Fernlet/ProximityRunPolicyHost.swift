// ProximityRunPolicyHost.swift
// Fernlet
//
// Network migration P7 item 2 (plan §13, §24.1; the P7 work list's "the policy becomes the single
// writer of the routed access gate"): the ONE app-target site that assembles `ProximityRunInputs`
// from the live lifecycle facts, calls `ProximityRunPolicy.decide(_:)`, and writes the resulting
// `MeshRoutedAccessGate` through `MeshNetworkManager.applyRoutedAccessGate(_:now:)`.
//
// `FernletApp.pushRoutedAccessGate(_:protectedData:foreground:)` used to assemble the gate at SIX
// call sites (`:337`, `:383`, `:416`, `:435`, `:447`, `:491`). The six EDGES survive — a fact that
// moves at a scene transition, at a protected-data notification, at the duress `.onChange` and at
// the launch mount each still needs its own observer, and the duress one moves at neither of the
// other two transitions — but the assembly and the manager call happen here, once.
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
//     file no row and delete-all owes it no writer. It holds a closure and ten values.
//   * It does not act on the radio directives. ``ProximityRunDecision/meshLinks``,
//     `discoveryAdmission`, `presence` and `recipeShare` are COMPUTED on every push and deliberately
//     dropped: P7 item 3 gives each manager its `apply(_:)` seam and makes this host their single
//     writer too. Only ``ProximityRunDecision/accessGate`` is written in this commit, which is why
//     the gate is exact from here and the directives become exact when their last legs are fed.
//
// And one boundary it inherits whole, D-10.3: the gate says what may be DECRYPTED, never which
// radios run. Nothing here reads `isOpen` or `permits(_:)`, and the gate value is carried from the
// decision untouched — this file constructs no `MeshRoutedAccessGate` of its own.

import ProximityKit
import SwiftUI

/// The app's single writer of the routed access gate (network migration P7 item 2).
///
/// **Legs in, one decision out.** Each setter records one lifecycle fact and then re-decides: the
/// host holds the latest value of every ``ProximityRunInputs`` field, hands them to
/// ``ProximityRunPolicy/decide(_:)``, and writes the decision's gate through the injected door.
/// `FernletApp` owns the edges; this type owns the assembly.
///
/// **It deliberately does not deduplicate.** A setter pushes whether or not the value moved, because
/// `MeshNetworkManager.applyRoutedAccessGate(_:now:)` already ignores an unchanged gate and already
/// decides which edge owes a re-entry pass (`MeshRoutedAccessEdge`). A second opinion about edges in
/// the app is exactly what the P5 review found the six push sites drifting into — four compared
/// `== .active` while the scene handler fell only on `.background` — so the edge stays where it is
/// tested.
///
/// **The door is injected and installed once.** ``connect(_:)`` takes the closure that reaches
/// `MeshNetworkManager`; until it runs there is no store, hence no manager, hence nothing to write
/// to, and every leg set before it is simply recorded. That latch is the old `if case .ready(let
/// store) = loader.phase` guard the six sites each carried, held in one place — and it is what lets
/// a test inject a recording closure instead of a mesh.
///
/// **`@MainActor`, and no `Task` anywhere.** Every fact it reads is main-actor state (the scene, the
/// lock service, the store's settings, the mesh manager) and the door it calls is a main-actor
/// method, so there is nothing to hop for. `MemoryLifecycleBoundaryTests` ML1/ML4 have no subject
/// here: this host stores no task handle and holds no `ProximityHost`.
@MainActor
final class ProximityRunPolicyHost {

    // MARK: - The door

    /// The injected writer: `MeshNetworkManager.applyRoutedAccessGate(_:now:)` in production, a
    /// recording closure in tests. Nil until ``connect(_:)`` runs, which is the whole of this type's
    /// "is there a store yet" question.
    private var writeAccessGate: (@MainActor (MeshRoutedAccessGate, Date) -> Void)?

    // MARK: - The legs

    /// The scene phase, fed to ``ProximityRunInputs``' initialiser and never compared here —
    /// `FernletApp.routedGateForeground(for:)` is the one phase-to-foreground translation and that
    /// initialiser is the only way to reach it.
    ///
    /// Starts `.background`, the fail-closed value: nothing is written before ``connect(_:)``, and
    /// `FernletApp.mountRoutedRunPolicy(_:)` seeds the live phase before the launch push.
    private var scenePhase: ScenePhase = .background

    /// iOS data protection, fed literally from the two `UIApplication` notifications — the
    /// notification IS the fact, because `isProtectedDataAvailable` still answers `true` inside the
    /// will-become-unavailable handler. Starts fail-closed.
    private var isProtectedDataAvailable = false

    /// The app lock with the duress session folded in
    /// (``ProximityAppLockState/resolve(_:isDuressSessionActive:)``).
    ///
    /// Fed at the duress `.onChange` and at the launch mount, which is every moment the leg the GATE
    /// reads can move: `duressActive` is the only clause of Fernlet's own app lock that reaches the
    /// mesh (D-10.3), a duress session is entered and cleared at an already-foreground lock screen,
    /// and `FernletLockService.refreshStateFromKeychain()` — the one lock call a scene activation
    /// makes — cannot touch it. The `.locked` / `.unlocked` distinction moves the two LISTENERS and
    /// nothing else, so its own observer is P7 item 3's, with the radios it decides.
    private var appLockState: ProximityAppLockState = .locked

    /// The tab on screen. **Fed by P7 item 3**, which is the commit that wires `ContentView`; the
    /// launch value is `ContentView.selectedTab`'s own initial value (`ContentView.swift:63`), so it
    /// is honest until the user moves and wrong only for the radio directives this item does not
    /// act on. The gate does not read it.
    private var selectedTab: FernletTab = .home

    /// The 13+ chat gate, read off `AgeAssuranceStore.record` at the launch mount. **Re-fed by P7
    /// item 3**, which owns the surface that can change a verdict mid-session. The gate does not
    /// read it.
    private var chatAgeGate: ProximityChatAgeGate = .undetermined

    /// Whether a delete-all / privacy wipe is running. **Fed by P7 item 3.** There is no app-wide
    /// fact to seed it from today: the flag is `DeleteEverythingFlow.isDeleting`, which is
    /// deliberately PER SCREEN (`DeleteEverythingFlow.swift:29`), so `false` at launch is the honest
    /// value and item 3 re-aims `FernletStore`'s three stop sites at this leg. The gate does not
    /// read it.
    private var isDeletingAllData = false

    /// `MeshNetworkManager.hasCommittedPeer` — the predicate the decision table names for radio
    /// guards, never `isSessionLive` and never `isInSession`. Seeded at the launch mount and
    /// **re-fed by P7 item 3**, which owns the commit and slot-loss edges. The gate does not read
    /// it.
    private var hasCommittedPeer = false

    /// `FernletStore.settings.allowNearbyPresence`, seeded at the launch mount. **Re-fed by P7 item
    /// 3**, which re-aims `FernletStore.setAllowNearbyPresence(_:)`'s stop at the policy. The gate
    /// does not read it.
    private var allowsNearbyPresence = false

    /// `FernletStore.settings.allowNearbyRecipeShares`, seeded at the launch mount. **Re-fed by P7
    /// item 3**, which re-aims `FernletStore.setAllowNearbyRecipeShares(_:)`'s stop at the policy.
    /// The gate does not read it.
    private var allowsNearbyRecipeShares = false

    /// The background continuation task — **inert until P8**, which is the only phase that can
    /// submit one. A `let` rather than a leg, so nothing in P7 can pretend a task exists: plan §13
    /// already decides the other three states, so P8 adds a setter here and no policy argument.
    private let continuationTask: ProximityContinuationTaskState = .inert

    // MARK: - Wiring

    /// Installs the door this host writes the routed access gate through, once.
    ///
    /// A second call is ignored, because the ready view's `.onAppear` re-fires on every reappearance
    /// and a re-installed door would be a second closure holding a second store reference. The
    /// production closure is the single `applyRoutedAccessGate(` call site outside ProximityKit —
    /// `ProximityRunPolicyHostTests.theRoutedAccessGateHasExactlyOneWriterInTheAppTarget()` counts
    /// it.
    ///
    /// Connecting pushes NOTHING on its own: `FernletApp.mountRoutedRunPolicy(_:)` seeds every leg
    /// it can before calling this, so the launch is one push rather than one per leg, and
    /// ``pushNow()`` is the explicit act that makes it.
    ///
    /// - Parameter write: The door. Production passes
    ///   `store.meshNetworkManager.applyRoutedAccessGate(_:now:)`; tests pass a recorder.
    func connect(_ write: @escaping @MainActor (MeshRoutedAccessGate, Date) -> Void) {
        guard writeAccessGate == nil else { return }
        writeAccessGate = write
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

    /// Decides over ``inputs`` and writes the decision's gate through the injected door.
    ///
    /// The whole of P7 item 2's wiring is these three lines. The decision's four radio directives
    /// are computed here and deliberately NOT acted on — that is P7 item 3, which gives each manager
    /// an `apply(_:)` seam and makes this the single writer of those too.
    ///
    /// A no-op before ``connect(_:)``: there is no manager to write to until the store is loaded,
    /// which is the guard each of the six former push sites carried for itself.
    func pushNow() {
        guard let writeAccessGate else { return }
        let decision = ProximityRunPolicy.decide(inputs)
        writeAccessGate(decision.accessGate, Date())
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

    /// Records the tab on screen and re-decides. **No caller in this commit** — `ContentView` is
    /// wired in P7 item 3; the gate does not read this leg, so the gate is exact without it.
    ///
    /// - Parameter tab: The tab on screen.
    func setSelectedTab(_ tab: FernletTab) {
        selectedTab = tab
        pushNow()
    }

    /// Records the 13+ chat gate and re-decides. Called once at the launch mount; re-fed in P7
    /// item 3.
    ///
    /// - Parameter gate: ``ProximityChatAgeGate/resolve(_:)``'s answer for this device's record.
    func setChatAgeGate(_ gate: ProximityChatAgeGate) {
        chatAgeGate = gate
        pushNow()
    }

    /// Records whether a delete-all is running and re-decides. **No caller in this commit** — the
    /// flag is per screen today (see ``isDeletingAllData``) and P7 item 3 re-aims `FernletStore`'s
    /// stop sites at it.
    ///
    /// - Parameter isDeleting: Whether a privacy wipe is in flight.
    func setDeletingAllData(_ isDeleting: Bool) {
        isDeletingAllData = isDeleting
        pushNow()
    }

    /// Records the committed-peer fact and re-decides. Seeded at the launch mount; re-fed in P7
    /// item 3.
    ///
    /// - Parameter hasPeer: `MeshNetworkManager.hasCommittedPeer`, never `isSessionLive` and never
    ///   `isInSession` — three predicates, three jobs.
    func setHasCommittedPeer(_ hasPeer: Bool) {
        hasCommittedPeer = hasPeer
        pushNow()
    }

    /// Records the nearby-presence consent and re-decides. Seeded at the launch mount; re-fed in P7
    /// item 3.
    ///
    /// - Parameter allows: `FernletStore.settings.allowNearbyPresence`.
    func setAllowsNearbyPresence(_ allows: Bool) {
        allowsNearbyPresence = allows
        pushNow()
    }

    /// Records the nearby-recipe-share consent and re-decides. Seeded at the launch mount; re-fed in
    /// P7 item 3.
    ///
    /// - Parameter allows: `FernletStore.settings.allowNearbyRecipeShares`.
    func setAllowsNearbyRecipeShares(_ allows: Bool) {
        allowsNearbyRecipeShares = allows
        pushNow()
    }
}
