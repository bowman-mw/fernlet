// ProximityRunPolicy.swift
// Fernlet
//
// Network migration P7 item 1 (plan §13 option A; the P7 launcher's item 1): the app-layer run
// policy as a VALUE — one pure function from everything the app knows about its own lifecycle
// (scene, tab, app lock and duress, iOS data protection, the age ruling, a delete-all in flight,
// P8's continuation task, and what the mesh manager currently holds) to what each proximity radio
// must do right now, plus the routed access gate the app already assembles.
//
// **A value, not a coordinator.** Everything that makes this decision hard — eleven inputs, four
// radios, a continuation state that does not exist yet — is combinatorial, and combinatorics belong
// in a table a test can enumerate, not in a control flow only a scene can reach. §13 rejects a
// self-observing ProximityKit (option B: it imports no UIKit and cannot import `FernletLock`) and a
// coordinator that intercepts (option C: two owners for one radio). This file is option A's
// decision half. Item 2 made it the single writer of
// `MeshNetworkManager.applyRoutedAccessGate(_:now:)`: `FernletStore.applyProximityRunPolicy(…)` is
// the ONE funnel that assembles an `Input` — the store's own facts plus the four the scene hands
// it — and writes the verdict's gate; the six edges in `FernletApp` call it and decide nothing.
// The radio half of the verdict is computed and kept (`FernletStore.proximityRunVerdict`) but
// applied by nothing yet: items 3 and 4 give each manager one `apply(_:)` seam and own the poller.
//
// **It decides radios, never plaintext.** `routedAccessGate` is the same three facts
// `FernletApp.pushRoutedAccessGate(_:protectedData:foreground:)` assembles today and nothing else:
// iOS data protection gates plaintext, Fernlet's app lock gates nothing in the mesh, and a duress
// session closes the gate (D-10.3). The gate reads no tab, no age ruling, no wipe and no
// continuation state, and this policy grows no second opinion about what may be decrypted — that
// is the bug class §13 rejects option C for, and P8 needs the gate's `appIsForeground` leg and the
// heart predicate's `sessionState` leg to stay independent so they can disagree on purpose.
//
// **Four run states, not §13's three.** `run` / `foregroundOnly` / `stop` cannot say what a
// committed session does in the background WITHOUT a continuation task today: it is kept, nothing
// runs, and iOS suspends the process — never torn down. `hold` names that (and the same session
// while the user is on another tab). It exists because `MeshNetworkManager.stopJoin()` →
// `stopSearching()` tears down the committed slots too: there is no seam that stops browsing while
// keeping links, so "not wanted, but do not destroy" needs its own word rather than a
// `foregroundOnly` smuggled into a background row.
//
// **`.inactive` is foreground.** The policy's one foreground fact is
// `FernletApp.routedGateForeground(for:)` — `phase != .background` — for the same reason every gate
// push site routes through it: `ScenePhase` is not frozen, and an inactive scene (Control Center, a
// call banner, the app's own Face ID sheet, iPad Split View) has the device unlocked and the process
// live. Today `ContentView` stops presence, recipe and discovery on `.inactive` through
// `scenePhase == .active` guards; item 3's retirement pass changes that by design. Device lock still
// traverses `.inactive → .background`, so every stop that matters still happens.
//
// **The age input is a ruling, never an absence.** `belowMinimumAge` is the system's FINAL `.below`
// verdict against the mesh's minimum age (`AgeGate.chat`, 13) or a guardian's communication limits.
// An account the system never ruled on keeps its radios and is refused chat only, exactly as today;
// no radio reads any age fact before item 3 wires this input.
//
// **The continuation input is inert until P8, and stays fed, never driven.** Nothing in shipping
// raises `.backgrounded` / `.foregrounded`, and this policy must not either: that asserts a
// `BGContinuedProcessingTask` is running, which is P8's claim. The app can only feed
// `.notRequested` today, and the matrix pins that under it no radio ever claims the background.
//
// **Three session predicates, three jobs.** `isSessionLive` is for projections and ceremonies and
// this policy never reads it; `hasCommittedPeer` guards radios and the resume arm; `isInSession` is
// the layout swap's. The policy folds the second and third into ``ProximitySessionPresence`` and
// reads nothing else, so a link blip (which moves `isSessionLive`'s inputs, not the slots) cannot
// move a radio verdict — P6 item 2's pass-B P1 is what confusing them costs.

import Foundation
import SwiftUI
import FernletDomainModel
import FernletLock
import ProximityKit

// MARK: - ProximityRunState

/// What one radio must do **right now**, decided by ``ProximityRunPolicy`` from the whole input.
///
/// A verdict, not a mode: the policy re-decides on every input change, so a value never has to
/// anticipate the next scene transition. Four values rather than §13's three — see the file header
/// for why ``hold`` exists. No `String` rawValue, deliberately: nothing logs or shows these, and a
/// rawValue is a frozen-token obligation under the localization wall taken on for no reader.
nonisolated enum ProximityRunState: Equatable, Sendable, CaseIterable {

    /// Runs now, **and keeps running if the scene leaves the foreground.** Only a mesh continued by
    /// P8's task ever gets this; nothing else may claim the background.
    case run

    /// Runs now **because the scene is foreground.** Emitted only in foreground rows; the next scene
    /// exit re-evaluates it.
    case foregroundOnly

    /// Keeps what it has, starts nothing, tears nothing down. Today's committed session in the
    /// background without a continuation task (iOS suspends the process), and a committed session
    /// while the user is on another tab.
    case hold

    /// Must not run now; whatever runs is torn down. Every hard stop (a delete-all in flight, a
    /// duress session, a below-minimum-age ruling), a search with nothing to keep, and every
    /// background presence and recipe row.
    case stop

    /// Whether the radio is up under this verdict — ``run`` or ``foregroundOnly``. An exhaustive
    /// `switch` rather than a comparison, so a fifth value would fail to compile here.
    var isRunning: Bool {
        switch self {
        case .run, .foregroundOnly: return true
        case .hold, .stop: return false
        }
    }
}

// MARK: - ProximityContinuationState

/// P8's `BGContinuedProcessingTask`, as the policy sees it — **fed in, never driven.**
///
/// The policy takes this as an input so §13's matrix can be stated and tested before the task
/// exists; it registers, submits, drives and completes nothing. Until P8 the app feeds
/// ``notRequested`` and nothing else, and ``ProximityRunPolicy`` treats the three non-running states
/// identically for every radio — the difference between them is copy P8 owes the user, not a radio
/// decision.
nonisolated enum ProximityContinuationState: Equatable, Sendable, CaseIterable {

    /// No task was submitted. The only value the app can feed before P8.
    case notRequested

    /// The task is running: the process is live in the background, and the mesh may continue.
    case running

    /// The system refused the task. The mesh has no claim on the background.
    case refused

    /// The task ran and the system ended it. The mesh has no claim on the background.
    case expired
}

// MARK: - ProximitySessionPresence

/// What the mesh manager holds right now, folded from the two predicates a radio guard may read.
///
/// Three cases rather than two Bools so the unrepresentable row (`hasCommittedPeer` without
/// `isInSession` — the same slots satisfy both) does not exist in the input product. Deliberately
/// **not** `isSessionLive`: that predicate answers "has the session ended" for projections and
/// ceremonies, and reading it for a radio is how P6 item 2's pass-B P1 happened.
nonisolated enum ProximitySessionPresence: Equatable, Sendable, CaseIterable {

    /// No mesh is held and no slot has committed — `!isInSession`. There is nothing to keep.
    case absent

    /// A mesh is held but no slot is committed — `isInSession && !hasCommittedPeer`: a mesh that
    /// outlived its links, or a restored ledger nobody has linked into yet. The mesh is kept; the
    /// radios have nobody.
    case meshHeld

    /// A slot holds a committed fingerprint right now — `hasCommittedPeer`. The radios have somebody,
    /// and standing them down would drop the link.
    case peerCommitted

    /// Folds the manager's two predicates into one presence, totally.
    ///
    /// - Parameters:
    ///   - isInSession: `MeshNetworkManager.isInSession` — a mesh is held, or some slot committed.
    ///   - hasCommittedPeer: `MeshNetworkManager.hasCommittedPeer` — a slot holds a committed
    ///     fingerprint now.
    /// - Returns: The presence. The unrepresentable row (`hasCommittedPeer` without `isInSession`) is
    ///   **answered** ``peerCommitted`` rather than trapped, exactly as `FriendsDiscoveryEntry` answers
    ///   it: a committed peer means the radios have somebody, whatever the other predicate says.
    static func folding(isInSession: Bool, hasCommittedPeer: Bool) -> ProximitySessionPresence {
        if hasCommittedPeer { return .peerCommitted }
        return isInSession ? .meshHeld : .absent
    }
}

// MARK: - ProximityRunPolicy

/// The app-layer run policy: the single translator from the app's lifecycle facts to a per-radio
/// ``ProximityRunState`` and the routed access gate (network migration P7, plan §13 option A).
///
/// A namespace for one pure function, ``verdict(for:)``, and its two value types. No stored state,
/// no clock, no store, no manager, no `UIApplication`; the caller samples the facts and the policy
/// decides. Items 2–4 of P7 make it the only writer of every radio seam and of
/// `MeshNetworkManager.applyRoutedAccessGate(_:now:)`.
nonisolated enum ProximityRunPolicy {

    // MARK: Input

    /// Everything the policy reads — the whole input product `ProximityRunPolicyTests` enumerates.
    ///
    /// Every field is a fact the app already holds; none is derived here. Where a field is a
    /// projection of a richer value (`appLockEngaged`, `belowMinimumAge`, `session`), its doc says
    /// exactly which projection, so item 3's wiring has nothing to decide.
    nonisolated struct Input: Equatable, Hashable, Sendable {

        /// The SwiftUI scene phase as the app sees it. The policy reads it through
        /// `FernletApp.routedGateForeground(for:)` and never compares a phase itself: `ScenePhase`
        /// is not frozen, and `.inactive` is a foreground scene.
        let scenePhase: ScenePhase

        /// The selected top-level tab.
        let selectedTab: FernletTab

        /// Fernlet's own app lock is `.locked` — the projection of `FernletLockState` that
        /// `ContentView.shouldRunPresence` and `shouldListenForRecipeShares` read today
        /// (`.notConfigured` and `.unlocked` are both `false`). Reaches presence and recipe only:
        /// Fernlet's app lock gates nothing in the mesh (D-10.3).
        let appLockEngaged: Bool

        /// `FernletLockService.isDuressSessionActive`. A hard stop for every radio, and the gate's
        /// `duressActive` leg.
        let duressSessionActive: Bool

        /// iOS data protection, as the app samples it at a scene site or is told it by the two
        /// notifications. Reaches the gate only.
        let protectedDataAvailable: Bool

        /// The system's **final** `.below` ruling against the mesh's minimum age (`AgeGate.chat`,
        /// 13), or a guardian's communication limits. Never "undetermined": an account that was
        /// never asked keeps its radios and is refused chat only. A hard stop.
        let belowMinimumAge: Bool

        /// `FernletStore.deleteAllData` is between `meshNetworkManager.beginPrivacyWipe()` and
        /// `endPrivacyWipe()`. A hard stop.
        let deleteAllInProgress: Bool

        /// P8's continuation task, fed in. `.notRequested` until P8 exists.
        let continuation: ProximityContinuationState

        /// What the mesh manager holds, folded from `isInSession` and `hasCommittedPeer`.
        let session: ProximitySessionPresence

        /// `settings.allowNearbyPresence`.
        let allowNearbyPresence: Bool

        /// `settings.allowNearbyRecipeShares`.
        let allowNearbyRecipeShares: Bool

        /// Builds an input from the eleven facts.
        ///
        /// - Parameters:
        ///   - scenePhase: The scene phase.
        ///   - selectedTab: The selected tab.
        ///   - appLockEngaged: Whether the app lock is `.locked`.
        ///   - duressSessionActive: Whether a duress session is active.
        ///   - protectedDataAvailable: Whether iOS data protection permits protected reads now.
        ///   - belowMinimumAge: Whether the system ruled this account below the mesh's minimum age.
        ///   - deleteAllInProgress: Whether a delete-all is between its wipe brackets.
        ///   - continuation: P8's task state.
        ///   - session: What the manager holds.
        ///   - allowNearbyPresence: The presence opt-in.
        ///   - allowNearbyRecipeShares: The recipe-share opt-in.
        init(
            scenePhase: ScenePhase,
            selectedTab: FernletTab,
            appLockEngaged: Bool,
            duressSessionActive: Bool,
            protectedDataAvailable: Bool,
            belowMinimumAge: Bool,
            deleteAllInProgress: Bool,
            continuation: ProximityContinuationState,
            session: ProximitySessionPresence,
            allowNearbyPresence: Bool,
            allowNearbyRecipeShares: Bool
        ) {
            self.scenePhase = scenePhase
            self.selectedTab = selectedTab
            self.appLockEngaged = appLockEngaged
            self.duressSessionActive = duressSessionActive
            self.protectedDataAvailable = protectedDataAvailable
            self.belowMinimumAge = belowMinimumAge
            self.deleteAllInProgress = deleteAllInProgress
            self.continuation = continuation
            self.session = session
            self.allowNearbyPresence = allowNearbyPresence
            self.allowNearbyRecipeShares = allowNearbyRecipeShares
        }
    }

    // MARK: Verdict

    /// The policy's answer: one ``ProximityRunState`` per radio, and the routed access gate.
    ///
    /// The four radios are the four things the app starts and stops today, named by what they are
    /// rather than by the type that runs them, so item 3's seams have one word each to answer to.
    nonisolated struct Verdict: Equatable, Sendable {

        /// The session's links to committed members and the routed drain — the thing a
        /// continuation task would continue. Its `stop` is a teardown (`leaveSession`), never a
        /// tab bounce.
        let mesh: ProximityRunState

        /// Browse, advertise and admission — `startJoin()`, `resumeSearchingForPartitionedMesh()`,
        /// `stopJoin()`. Foreground-only by invariant 5: it is never ``ProximityRunState/run``, and
        /// in the background with a live continuation task it is ``ProximityRunState/stop``, which
        /// is P8's seam to build (stop browsing, refuse admission, keep the links).
        let discovery: ProximityRunState

        /// `PresenceManager` — the nearby-friends presence radio.
        let presence: ProximityRunState

        /// `RecipeShareManager` — the nearby recipe-share listener.
        let recipeShare: ProximityRunState

        /// The three plaintext facts, exactly as the app assembles them today. The gate reads no
        /// tab, age, wipe or continuation fact — the policy decides radios, never plaintext.
        let routedAccessGate: MeshRoutedAccessGate

        /// Builds a verdict.
        ///
        /// - Parameters:
        ///   - mesh: The session radio's state.
        ///   - discovery: The discovery radio's state.
        ///   - presence: The presence radio's state.
        ///   - recipeShare: The recipe-share radio's state.
        ///   - routedAccessGate: The routed access gate to push.
        init(
            mesh: ProximityRunState,
            discovery: ProximityRunState,
            presence: ProximityRunState,
            recipeShare: ProximityRunState,
            routedAccessGate: MeshRoutedAccessGate
        ) {
            self.mesh = mesh
            self.discovery = discovery
            self.presence = presence
            self.recipeShare = recipeShare
            self.routedAccessGate = routedAccessGate
        }

        /// Whether any radio is up under this verdict. A convenience for tests and diagnostics; item
        /// 4's poller keys on the mesh's own liveness, never on this.
        var anyRadioRuns: Bool {
            mesh.isRunning || discovery.isRunning || presence.isRunning || recipeShare.isRunning
        }
    }

    // MARK: The projections

    /// ``Input/appLockEngaged`` from the lock service's state: `.locked` only, exactly as
    /// `ContentView.shouldRunPresence` and `shouldListenForRecipeShares` read it today.
    ///
    /// - Parameter state: `FernletLockService.state`.
    /// - Returns: `true` for `.locked` (with or without a cooldown), `false` for `.notConfigured`
    ///   and every `.unlocked` scope.
    static func appLockEngaged(_ state: FernletLockState) -> Bool {
        switch state {
        case .locked: return true
        case .notConfigured, .unlocked: return false
        }
    }

    /// ``Input/belowMinimumAge`` from the age record: a **ruling**, never an absence.
    ///
    /// `true` only for the system's final `.below` verdict against the mesh's minimum age
    /// (`AgeGate.chat`, 13) or a guardian's communication limits — the two things that close the
    /// chat gate for good. An `.undetermined` verdict (never asked, declined, or a bracket at the
    /// line with no provenance) answers `false`: that account keeps its radios and is refused chat
    /// only, exactly as it is today, because no radio was ever age-gated before this input existed.
    ///
    /// - Parameter record: `AgeAssuranceStore.record`.
    /// - Returns: Whether the radios must stop for age.
    static func belowMinimumAge(_ record: AgeAssuranceRecord) -> Bool {
        if record.hasCommunicationLimits { return true }
        switch record.verdict(for: .chat) {
        case .below: return true
        case .meets, .undetermined: return false
        }
    }

    // MARK: The decision

    /// The decision — pure, total, and re-run on every input change.
    ///
    /// - Parameter input: Everything the policy reads.
    /// - Returns: What each radio must do now, and the gate to push. The per-radio rules are the
    ///   private helpers below; `ProximityRunPolicyTests` pins them over the whole input product.
    static func verdict(for input: Input) -> Verdict {
        let foreground = isForeground(input)
        let hardStop = isHardStop(input)
        return Verdict(
            mesh: meshState(input, foreground: foreground, hardStop: hardStop),
            discovery: discoveryState(input, foreground: foreground, hardStop: hardStop),
            presence: presenceState(input, foreground: foreground, hardStop: hardStop),
            recipeShare: recipeShareState(input, foreground: foreground, hardStop: hardStop),
            routedAccessGate: MeshRoutedAccessGate(
                protectedDataAvailable: input.protectedDataAvailable,
                appIsForeground: foreground,
                duressActive: input.duressSessionActive
            )
        )
    }

    /// The policy's one foreground fact: `FernletApp.routedGateForeground(for:)`'s answer, never a
    /// raw phase compare. `.active` and `.inactive` are foreground; `.background` is not.
    ///
    /// - Parameter input: The input whose scene phase is read.
    /// - Returns: Whether the scene is not backgrounded.
    static func isForeground(_ input: Input) -> Bool {
        FernletApp.routedGateForeground(for: input.scenePhase)
    }

    /// Whether any hard stop is in force: a delete-all in flight, a duress session, or a
    /// below-minimum-age ruling. Every radio is ``ProximityRunState/stop`` under one, whatever
    /// else the input says; the gate is unaffected except through its own duress leg.
    ///
    /// - Parameter input: The input whose three hard-stop facts are read.
    /// - Returns: Whether a hard stop is in force.
    static func isHardStop(_ input: Input) -> Bool {
        input.deleteAllInProgress || input.duressSessionActive || input.belowMinimumAge
    }

    /// The session radio. A hard stop tears it down; a running continuation task with something to
    /// continue lets it claim the background (§13: "user-started mesh + CPT granted → mesh `run` in
    /// background"); otherwise it runs in the foreground and is held in the background.
    private static func meshState(_ input: Input, foreground: Bool, hardStop: Bool) -> ProximityRunState {
        if hardStop { return .stop }
        if continuationGrantsBackground(input) { return .run }
        return foreground ? .foregroundOnly : .hold
    }

    /// Whether P8's task lets the mesh claim the background: a **running** task with a mesh or a
    /// peer to continue. A task with nothing to continue grants nothing, and no non-running state
    /// grants anything — `.refused`, `.expired` and `.notRequested` are one row here.
    private static func continuationGrantsBackground(_ input: Input) -> Bool {
        switch input.continuation {
        case .running:
            switch input.session {
            case .meshHeld, .peerCommitted: return true
            case .absent: return false
            }
        case .notRequested, .refused, .expired:
            return false
        }
    }

    /// The discovery radio. A hard stop stands it down; in the foreground the Friends tab wants it
    /// and any other tab keeps it only for a committed peer; in the background a live continuation
    /// task must not browse or admit (invariant 5), and otherwise a committed peer's links are held
    /// while a search with nobody stands down.
    private static func discoveryState(_ input: Input, foreground: Bool, hardStop: Bool) -> ProximityRunState {
        if hardStop { return .stop }
        if foreground {
            switch input.selectedTab {
            case .social: return .foregroundOnly
            case .home, .food, .move, .personal: return heldForACommittedPeer(input.session)
            }
        }
        switch input.continuation {
        case .running: return .stop
        case .notRequested, .refused, .expired: return heldForACommittedPeer(input.session)
        }
    }

    /// ``ProximityRunState/hold`` for a committed peer — standing the radios down would drop the
    /// link — and ``ProximityRunState/stop`` for anything else, because `stopJoin()` on a held mesh
    /// with no links drops nothing the mesh needs.
    private static func heldForACommittedPeer(_ session: ProximitySessionPresence) -> ProximityRunState {
        switch session {
        case .peerCommitted: return .hold
        case .absent, .meshHeld: return .stop
        }
    }

    /// The presence radio: today's `ContentView.shouldRunPresence` — opted in, foreground, not
    /// app-locked, on Home / Food / Move / Friends — with `.inactive` counted as foreground.
    private static func presenceState(_ input: Input, foreground: Bool, hardStop: Bool) -> ProximityRunState {
        guard !hardStop, foreground, input.allowNearbyPresence, !input.appLockEngaged else { return .stop }
        switch input.selectedTab {
        case .home, .food, .move, .social: return .foregroundOnly
        case .personal: return .stop
        }
    }

    /// The recipe-share listener: today's `ContentView.shouldListenForRecipeShares` — opted in,
    /// foreground, not app-locked, on Home / Food / Move (never Friends) — with `.inactive` counted
    /// as foreground.
    private static func recipeShareState(_ input: Input, foreground: Bool, hardStop: Bool) -> ProximityRunState {
        guard !hardStop, foreground, input.allowNearbyRecipeShares, !input.appLockEngaged else { return .stop }
        switch input.selectedTab {
        case .home, .food, .move: return .foregroundOnly
        case .social, .personal: return .stop
        }
    }
}
