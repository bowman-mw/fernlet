// ProximityRunPolicy.swift
// Fernlet
//
// Network migration P7 item 1 (plan §13, option A): the single translator from the app's lifecycle
// facts to a run state per proximity radio.
//
// A PURE VALUE. It starts nothing, stops nothing, observes nothing and holds no reference to a
// manager — items 2 to 4 of P7 wire it. Everything that makes the decision hard is COMBINATORIAL
// (ten inputs, four radios, a continuation-task state that does not exist until P8), and
// combinatorics belong in a table rather than in a control flow, so the artefact is
// `ProximityRunPolicyTests`' enumeration of the whole input product with a named expectation on
// every row. The wiring then has nothing left to decide.
//
// It lives in the APP target because the app is the only place all ten facts exist: ProximityKit
// deliberately observes no lifecycle, imports no UIKit and cannot import FernletLock. Options B
// (ProximityKit self-observes) and C (the continuation coordinator intercepts) are rejected in
// plan §13.
//
// Two rules ride in from P5 item 10 and are not negotiable here:
//
//   * The foreground fact is ALWAYS `FernletApp.routedGateForeground(for:)`'s answer. There is no
//     other way to build a `ProximityRunInputs`, this file holds no raw scene-phase comparison and
//     no switch over `ScenePhase`, and `ProximityRunPolicyTests` scans this file for both. The
//     enum is not frozen: an `@unknown default` under warnings-as-errors would have to pick a side
//     for a phase that does not exist yet.
//   * An INACTIVE scene is a FOREGROUND scene (P5's post-close correction). Control Center or the
//     notification shade pulled over the app, the app switcher, a call banner, a system prompt, the
//     app's own Face ID sheet and iPad Split View are all states where the device is unlocked, the
//     user is present and the process is live.
//
// And one boundary, D-10.3: the policy decides RADIOS, never plaintext. The `MeshRoutedAccessGate`
// the decision carries is assembled from exactly the three facts
// `FernletApp.pushRoutedAccessGate(_:protectedData:foreground:)` assembles it from today and is
// carried through untouched — nothing in this file reads `isOpen` or `permits(_:)`, and Fernlet's
// app lock gates nothing in the mesh beyond the duress clause the gate already owns.

import FernletDomainModel
import FernletLock
import ProximityKit
import SwiftUI

// MARK: - Vocabulary

/// One of the four radios the policy answers for.
///
/// **Four names, not the two seams that exist today.** `MeshNetworkManager.startJoin()` /
/// `stopJoin()` is one door for two of them — `stopJoin()` runs `stopSearching()`, which stands the
/// transport down AND empties the committed slots — so `meshLinks` and `discoveryAdmission` are a
/// single radio in shipping code. Plan §13 needs them apart (a CPT-continued mesh keeps its links
/// while its admission door stays a foreground affair, invariant 5), so the vocabulary splits them
/// here and P7 item 3 owes each manager the `apply(_:)` seam that can honour the split.
nonisolated enum ProximityRadio: String, CaseIterable, Hashable, Sendable {

    /// The committed peer-to-peer links of a founded mesh, and the routed traffic that rides them.
    case meshLinks

    /// Advertising, browsing and admitting a NEW peer — the Friends tab's search.
    case discoveryAdmission

    /// `FernletStore.presenceManager`: the nearby-friends presence layer, which hearts ride.
    case presence

    /// `FernletStore.recipeShareManager`: the nearby recipe-share listener.
    case recipeShare
}

/// What one radio is directed to do, in plan §13's vocabulary.
///
/// A directive is not yet an answer about right now: ``ProximityRunState/foregroundOnly`` resolves
/// against the one foreground fact through ``isUp(inForeground:)``, which is what lets §13's rows be
/// read literally — "discovery/admission is `foregroundOnly`" is true in both scene phases, and it
/// is the RESOLUTION that puts the radio down in the background.
nonisolated enum ProximityRunState: String, CaseIterable, Hashable, Sendable {

    /// Up in both scene phases. Only a granted continuation task ever earns this (plan §13).
    case run

    /// Up while the app is foreground, down once it is backgrounded.
    case foregroundOnly

    /// Down, unconditionally.
    case stop

    /// The directive resolved against the one foreground fact.
    ///
    /// - Parameter isForeground: ``FernletApp/routedGateForeground(for:)``'s answer for this scene.
    /// - Returns: whether the radio is up right now.
    func isUp(inForeground isForeground: Bool) -> Bool {
        switch self {
        case .run: return true
        case .foregroundOnly: return isForeground
        case .stop: return false
        }
    }
}

/// The app-lock fact the policy takes, flattened into four enumerable cases.
///
/// `FernletLockState` itself carries associated values (a cooldown deadline, an unlock scope) and so
/// is not `CaseIterable`; neither value changes a radio, so the policy takes this instead and
/// ``ProximityAppLockState/resolve(_:isDuressSessionActive:)`` is the one documented mapping.
///
/// **Duress is a case rather than a second axis**, and it is checked first, because a duress unlock
/// arrives as an ordinary `.unlocked` transition (`ContentView.swift:300`) — the two facts co-occur,
/// and §13 has duress stopping every radio and tearing the session down regardless of the lock
/// state underneath it. It is also the only clause of Fernlet's own app lock that reaches the mesh
/// at all (D-10.3).
nonisolated enum ProximityAppLockState: String, CaseIterable, Hashable, Sendable {

    /// No credential has ever been configured. Treated exactly as `unlocked` by every radio rule,
    /// matching `ContentView.shouldRunPresence` (`ContentView.swift:1783`).
    case notConfigured

    /// Unlocked for some surface.
    case unlocked

    /// Locked. Stops presence and recipe today; the mesh radios are untouched by it (D-10.3).
    case locked

    /// A duress session is in force. Dominates every other input except delete-all and below-age.
    case duress

    /// Flattens the app's two lock facts into one case.
    ///
    /// - Parameters:
    ///   - state: `FernletLockService.state`.
    ///   - isDuressSessionActive: `FernletLockService.isDuressSessionActive`, which survives
    ///     `lock(reason:)` and is cleared only by a real-passcode unlock.
    /// - Returns: `duress` whenever a duress session is in force, otherwise the lock state.
    static func resolve(_ state: FernletLockState, isDuressSessionActive: Bool) -> Self {
        guard !isDuressSessionActive else { return .duress }
        switch state {
        case .notConfigured: return .notConfigured
        case .locked: return .locked
        case .unlocked: return .unlocked
        }
    }
}

/// What this device believes about the 13+ chat gate, the one age gate that covers the mesh.
///
/// Three states rather than a `Bool`, because `AgeGateVerdict` has three and they must lead to
/// different behaviour: `below` is a final, unappealable system determination, while `undetermined`
/// means nobody has ruled. `AgeAssuranceRecord.allows(.chat)` collapses the two (chat refuses
/// self-attestation, so an undetermined user is not allowed to chat), and collapsing them here would
/// take the Friends radios away from every user whose Apple Account carries no age range.
nonisolated enum ProximityChatAgeGate: String, CaseIterable, Hashable, Sendable {

    /// The system placed the user at or above 13, with usable provenance.
    case meets

    /// Nobody has ruled. Chat itself still refuses (`MeshTextSendOutcome.ageGated`); the radios run.
    case undetermined

    /// The system placed the user below 13, or a guardian's communication limits close the gate.
    /// Final, and §13's "below-age" input: every radio stops and the session tears down.
    case below

    /// Reads the chat gate off this device's age record.
    ///
    /// Guardian communication limits are checked FIRST and answer ``below``, mirroring
    /// `AgeAssuranceRecord.allows(_:)` — the guardian has already answered the question the age
    /// check was asking, and no bracket or confirmation may get past it.
    ///
    /// - Parameter record: `AgeAssuranceStore.record`.
    /// - Returns: the flattened verdict for `AgeGate.chat`.
    static func resolve(_ record: AgeAssuranceRecord) -> Self {
        guard !(AgeGate.chat.isInterpersonalCommunication && record.hasCommunicationLimits) else {
            return .below
        }
        switch record.verdict(for: .chat) {
        case .meets: return .meets
        case .undetermined: return .undetermined
        case .below: return .below
        }
    }
}

/// The background continuation task's state — **inert until P8**.
///
/// P7's wiring only ever passes ``inert``. The other three are P8's, and the matrix already decides
/// them so that P8 adds a coordinator rather than a policy argument. P8's coordinator submits a task
/// only once the first peer commits on a user start or join, so a non-inert value already implies a
/// user-started mesh — but the policy still reads `hasCommittedPeer` for itself rather than infer it,
/// because `hasCommittedPeer` is the predicate the decision table names for radio guards and
/// inferring one predicate from another is what P6 item 2's pass-B P1 cost.
nonisolated enum ProximityContinuationTaskState: String, CaseIterable, Hashable, Sendable {

    /// No continuation task exists. The only value P7 ever passes.
    case inert

    /// The system granted background continuation. The ONLY value that earns mesh `run` (§13).
    case granted

    /// The system refused background continuation. §13: the mesh falls back to `foregroundOnly`
    /// and the UI explains that background continuation is unavailable.
    case refused

    /// A granted task ran out. Same radio answer as ``refused``.
    case expired
}

// MARK: - Inputs

/// Everything the policy reads, and nothing else.
///
/// **There is exactly one initializer and it takes a `ScenePhase`**, so no caller can hand the
/// policy a foreground fact that did not come from ``FernletApp/routedGateForeground(for:)``. That
/// is structural rather than a convention: before the P5 review four of the six gate-push sites
/// compared against the active phase while the scene handler fell only on the backgrounded one, so
/// the stored answer for one physical state depended on which event pushed last.
///
/// Ten fields. Seven are plan §13's; the other three are named in P7's own work list as policy
/// INPUTS rather than competing owners, and each is a condition shipping code gates a radio on
/// today — see ``hasCommittedPeer``, ``allowsNearbyPresence`` and ``allowsNearbyRecipeShares``.
nonisolated struct ProximityRunInputs: Equatable, Hashable, Sendable {

    /// ``FernletApp/routedGateForeground(for:)``'s answer for the scene phase this was built from.
    /// An inactive scene is foreground.
    let isForeground: Bool

    /// `ContentView.selectedTab`. The Friends tab arms the search
    /// (`ContentView.swift:329`); presence and recipe each have their own tab set.
    let selectedTab: FernletTab

    /// The app lock, with duress folded in.
    let lockState: ProximityAppLockState

    /// iOS data protection. Carried into the gate and **nothing else** — it decides plaintext, never
    /// a radio (D-10.3), which is itself a row of the matrix.
    let isProtectedDataAvailable: Bool

    /// The 13+ chat gate.
    let chatAgeGate: ProximityChatAgeGate

    /// Whether a delete-all / privacy wipe is running. §13's first dominating input.
    let isDeletingAllData: Bool

    /// The background continuation task. Inert until P8.
    let continuationTask: ProximityContinuationTaskState

    /// `MeshNetworkManager.hasCommittedPeer` — the predicate the decision table names for radio
    /// guards, never `isSessionLive` (projections and ceremonies) and never `isInSession` (the
    /// layout swap).
    ///
    /// Required, not decorative: `ContentView.stopFriendsDiscovery()` guards on it
    /// (`ContentView.swift:1862`), so a tab exit or a scene change stands the radios down only when
    /// no peer is committed. A policy blind to it would tear a live mesh down on a tab switch.
    let hasCommittedPeer: Bool

    /// `FernletStore.settings.allowNearbyPresence`. Gates the presence radio today
    /// (`ContentView.swift:1779`), and `FernletStore.setAllowNearbyPresence(_:)` stops the radio
    /// outright when it is turned off (`FernletStore.swift:1868`) — one of the three store-side stop
    /// sites P7 item 3 re-aims at the policy, which is only possible if the policy can see it.
    let allowsNearbyPresence: Bool

    /// `FernletStore.settings.allowNearbyRecipeShares`. Gates the recipe listener today
    /// (`ContentView.swift:1720`); `FernletStore.setAllowNearbyRecipeShares(_:)` is the second
    /// store-side stop site (`FernletStore.swift:1701`).
    let allowsNearbyRecipeShares: Bool

    /// Builds the inputs, deriving the foreground fact in the one place it may be derived.
    ///
    /// - Parameters:
    ///   - scenePhase: The scene phase, passed straight to
    ///     ``FernletApp/routedGateForeground(for:)`` and never compared here.
    ///   - selectedTab: The tab on screen.
    ///   - lockState: The app lock with duress folded in.
    ///   - isProtectedDataAvailable: iOS data protection, for the gate leg.
    ///   - chatAgeGate: The 13+ chat gate.
    ///   - isDeletingAllData: Whether a delete-all is running.
    ///   - continuationTask: The background continuation task. Inert until P8.
    ///   - hasCommittedPeer: Whether a peer is committed right now.
    ///   - allowsNearbyPresence: The presence consent.
    ///   - allowsNearbyRecipeShares: The recipe-share consent.
    init(
        scenePhase: ScenePhase,
        selectedTab: FernletTab,
        lockState: ProximityAppLockState,
        isProtectedDataAvailable: Bool,
        chatAgeGate: ProximityChatAgeGate,
        isDeletingAllData: Bool,
        continuationTask: ProximityContinuationTaskState,
        hasCommittedPeer: Bool,
        allowsNearbyPresence: Bool,
        allowsNearbyRecipeShares: Bool
    ) {
        self.isForeground = FernletApp.routedGateForeground(for: scenePhase)
        self.selectedTab = selectedTab
        self.lockState = lockState
        self.isProtectedDataAvailable = isProtectedDataAvailable
        self.chatAgeGate = chatAgeGate
        self.isDeletingAllData = isDeletingAllData
        self.continuationTask = continuationTask
        self.hasCommittedPeer = hasCommittedPeer
        self.allowsNearbyPresence = allowsNearbyPresence
        self.allowsNearbyRecipeShares = allowsNearbyRecipeShares
    }

    /// Whether one of plan §13's three dominating inputs is in force: a delete-all, a final
    /// below-age verdict, or a duress session. Each stops every radio and tears the session down.
    var demandsTeardown: Bool {
        isDeletingAllData || chatAgeGate == .below || lockState == .duress
    }
}

// MARK: - Decision

/// What the policy decided: one directive per radio, the teardown flag, and the routed access gate
/// the app is already assembling.
///
/// The gate is CARRIED, never interpreted — nothing here reads `MeshRoutedAccessGate.isOpen` or
/// `permits(_:)`, because "may we decrypt" has exactly one owner and it is not this type (D-10.3).
/// ``isForeground`` duplicates the gate's own `appIsForeground` leg on purpose, so that resolving a
/// directive never has to reach into the gate; `ProximityRunPolicyTests` pins the two equal on every
/// row of the product.
///
/// Not `Hashable`: `MeshRoutedAccessGate` is `Equatable` and `Sendable` but not `Hashable`, and
/// synthesising a hash for it here would be a second opinion about a ProximityKit value.
nonisolated struct ProximityRunDecision: Equatable, Sendable {

    /// The committed links of a founded mesh.
    let meshLinks: ProximityRunState

    /// The admission door. Never ``ProximityRunState/run`` — invariant 5.
    let discoveryAdmission: ProximityRunState

    /// The presence radio.
    let presence: ProximityRunState

    /// The recipe-share listener.
    let recipeShare: ProximityRunState

    /// Whether the session must be torn down, not merely stood down. True for exactly plan §13's
    /// three dominating inputs.
    let tearsDownSession: Bool

    /// ``FernletApp/routedGateForeground(for:)``'s answer, the one fact a directive resolves
    /// against.
    let isForeground: Bool

    /// The gate value, assembled from the same three facts
    /// `FernletApp.pushRoutedAccessGate(_:protectedData:foreground:)` assembles it from, for the
    /// single writer P7 item 2 makes of this policy.
    let accessGate: MeshRoutedAccessGate

    /// The directive for one radio.
    ///
    /// - Parameter radio: The radio being asked about.
    /// - Returns: its directive.
    func directive(for radio: ProximityRadio) -> ProximityRunState {
        switch radio {
        case .meshLinks: return meshLinks
        case .discoveryAdmission: return discoveryAdmission
        case .presence: return presence
        case .recipeShare: return recipeShare
        }
    }

    /// Whether one radio is up right now — the directive resolved against ``isForeground``.
    ///
    /// This is the call the wiring makes, so that items 2 to 4 have nothing to decide.
    ///
    /// - Parameter radio: The radio being asked about.
    /// - Returns: `true` when it should be running.
    func isUp(_ radio: ProximityRadio) -> Bool {
        directive(for: radio).isUp(inForeground: isForeground)
    }
}

// MARK: - The policy

/// Plan §13's run policy: a pure function from ``ProximityRunInputs`` to ``ProximityRunDecision``.
///
/// The rules, in the order they are applied:
///
/// 1. **Delete-all, below-age and duress dominate.** Every radio stops and the session tears down
///    (§13). These are the conditions `FernletStore` reaches around the view for today —
///    `FernletStore.swift:1701`, `:1868` and `:5327` — and P7 item 3 re-aims those at this answer.
/// 2. **Mesh links.** `stop` with no committed peer and off the Friends tab (nothing is user-started
///    to keep up — `ContentView.swift:331`, the tab-exit `stopJoin()`); `run` only for a committed
///    peer under a granted continuation task; `foregroundOnly` otherwise, which is where a refused
///    or expired task lands and where every P7 row lands.
/// 3. **Discovery/admission** is never `run` (invariant 5): `foregroundOnly` on the Friends tab or
///    while a peer is committed (`ContentView.swift:329` and the `hasCommittedPeer` guard at
///    `:1862`), `stop` otherwise.
/// 4. **Presence** and **recipe** are never `run` either — §13 has both stopping on background —
///    and each keeps its own shipping condition: its consent, an unlocked-or-unconfigured app lock,
///    and its own tab set.
///
/// The one deliberate widening against today's code reaches EVERY radio, not just presence, and is
/// named in full on ``presenceDirective(_:)``: shipping asks for the ACTIVE phase at all four of its
/// gates, this policy has one foreground fact and an inactive scene is foreground, so an inactive
/// scene keeps `foregroundOnly` radios up where `ContentView` stands them down.
nonisolated enum ProximityRunPolicy {

    /// Decides every radio for one set of facts.
    ///
    /// - Parameter inputs: The app's lifecycle facts.
    /// - Returns: the directives, the teardown flag and the routed access gate.
    static func decide(_ inputs: ProximityRunInputs) -> ProximityRunDecision {
        let gate = MeshRoutedAccessGate(
            protectedDataAvailable: inputs.isProtectedDataAvailable,
            appIsForeground: inputs.isForeground,
            duressActive: inputs.lockState == .duress
        )
        guard !inputs.demandsTeardown else {
            return ProximityRunDecision(
                meshLinks: .stop, discoveryAdmission: .stop, presence: .stop, recipeShare: .stop,
                tearsDownSession: true, isForeground: inputs.isForeground, accessGate: gate
            )
        }
        return ProximityRunDecision(
            meshLinks: meshLinksDirective(inputs),
            discoveryAdmission: discoveryAdmissionDirective(inputs),
            presence: presenceDirective(inputs),
            recipeShare: recipeShareDirective(inputs),
            tearsDownSession: false,
            isForeground: inputs.isForeground,
            accessGate: gate
        )
    }

    /// The mesh links' directive, once the dominating inputs are ruled out.
    ///
    /// `run` requires BOTH a granted continuation task and a committed peer: `hasCommittedPeer` is
    /// the predicate the decision table names for radio guards, and claiming background continuation
    /// for a mesh with nobody in it would be a battery bug wearing P8's name.
    ///
    /// - Parameter inputs: The app's lifecycle facts.
    /// - Returns: the directive for ``ProximityRadio/meshLinks``.
    private static func meshLinksDirective(_ inputs: ProximityRunInputs) -> ProximityRunState {
        guard inputs.hasCommittedPeer || isFriendsTab(inputs.selectedTab) else { return .stop }
        guard inputs.hasCommittedPeer, inputs.continuationTask == .granted else {
            return .foregroundOnly
        }
        return .run
    }

    /// Whether this is the tab that arms the friend search (`ContentView.handleTabChange`,
    /// `App/Fernlet/ContentView.swift:329`).
    ///
    /// An exhaustive `switch` rather than an equality test, matching the two listener rules below: a
    /// sixth tab is a build error here until someone decides which side of the search it sits on.
    ///
    /// - Parameter tab: The tab on screen.
    /// - Returns: `true` for Friends.
    private static func isFriendsTab(_ tab: FernletTab) -> Bool {
        switch tab {
        case .social: return true
        case .home, .food, .move, .personal: return false
        }
    }

    /// The admission door's directive. Never `run` — plan §13's invariant 5 keeps admitting a new
    /// peer a foreground act, whatever the mesh itself is doing.
    ///
    /// - Parameter inputs: The app's lifecycle facts.
    /// - Returns: the directive for ``ProximityRadio/discoveryAdmission``.
    private static func discoveryAdmissionDirective(
        _ inputs: ProximityRunInputs
    ) -> ProximityRunState {
        guard inputs.hasCommittedPeer || isFriendsTab(inputs.selectedTab) else { return .stop }
        return .foregroundOnly
    }

    /// The presence radio's directive: consent, an app lock that is not locked, and one of the four
    /// tabs that are not Private (`ContentView.shouldRunPresence`, `ContentView.swift:1778`).
    ///
    /// **The one deliberate widening, and it covers all four radios.** Shipping code asks for the
    /// ACTIVE phase at every one of its gates, so a Control Centre pull or a call banner stands the
    /// whole set down today: `ContentView.shouldRunPresence` (`ContentView.swift:1780`) and
    /// `shouldListenForRecipeShares` (`:1721`) each guard `scenePhase == .active`, and
    /// `handleScenePhaseChange` (`:348`) runs `stopFriendsDiscovery()` on ANY non-active phase —
    /// which stands the mesh links and the admission door down too whenever no peer is committed
    /// (`:1858`, where the stop bails on a committed peer). The policy has one foreground fact and
    /// an inactive scene is foreground, so `foregroundOnly` keeps presence, the recipe listener, a
    /// peerless Friends search and its admission door up across that bounce. The alternative is a
    /// second scene fact, which means a raw phase comparison in this file for a state that is
    /// momentary, still unlocked, still user-present and which P5 already ruled a foreground state
    /// for the far more sensitive plaintext question. `ProximityRunPolicyTests` pins the widening's
    /// exact extent: every deviating row is an inactive one, and it counts them.
    ///
    /// - Parameter inputs: The app's lifecycle facts.
    /// - Returns: the directive for ``ProximityRadio/presence``.
    private static func presenceDirective(_ inputs: ProximityRunInputs) -> ProximityRunState {
        guard inputs.allowsNearbyPresence, inputs.lockState != .locked else { return .stop }
        switch inputs.selectedTab {
        case .home, .food, .move, .social: return .foregroundOnly
        case .personal: return .stop
        }
    }

    /// The recipe listener's directive: consent, an app lock that is not locked, and one of the
    /// three non-social, non-Private tabs (`ContentView.shouldListenForRecipeShares`,
    /// `ContentView.swift:1719`).
    ///
    /// Exhaustive over `FernletTab` rather than a set membership test, so a sixth tab is a build
    /// error here until someone decides which side of the listener it sits on. Carries the same
    /// inactive-scene widening as ``presenceDirective(_:)``.
    ///
    /// - Parameter inputs: The app's lifecycle facts.
    /// - Returns: the directive for ``ProximityRadio/recipeShare``.
    private static func recipeShareDirective(_ inputs: ProximityRunInputs) -> ProximityRunState {
        guard inputs.allowsNearbyRecipeShares, inputs.lockState != .locked else { return .stop }
        switch inputs.selectedTab {
        case .home, .food, .move: return .foregroundOnly
        case .social, .personal: return .stop
        }
    }
}
