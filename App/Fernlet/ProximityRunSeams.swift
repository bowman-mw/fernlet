// ProximityRunSeams.swift
// Fernlet
//
// Network migration P7 item 3: the radios' `apply(_:)` seams, and the ONE place in the app that
// speaks a radio verb.
//
// Before this file `ContentView` owned the radios: `startFriendsDiscovery()` /
// `stopFriendsDiscovery()` resolved `FriendsDiscoveryEntry` and called `startJoin()` /
// `resumeSearchingForPartitionedMesh()` / `stopJoin()`, guarded on `isSearching` and on
// `hasCommittedPeer`; `updateRecipeShareListener()` / `updatePresenceListener()` started and stopped
// the two listeners from their own `scenePhase == .active` / tab / lock guards; and `FernletStore`
// reached around all of it from its two opt-out setters and from delete-all's leg 7b. Item 1 made
// those guards one table (`ProximityRunPolicy`), item 2 made the store's funnel the one place that
// runs it, and this item makes that funnel the only WRITER of the radios — walled by
// `ProximityRunSeamsTests`, which counts every radio verb under `App/` into this file (and, by
// name, the DEBUG Lane C harness's own `startJoin()`).
//
// Two halves, deliberately. `ProximityRunTransition` is PURE: from the last verdict applied and the
// new one, plus the mesh manager's three live predicates, to an ordered list of
// `ProximityRunAction` — so "which verb, and when" is a tier-1 table rather than a condition only a
// scene can reach. The executor below is a `switch` with nothing to decide.
//
// Edge-triggered on purpose — for the mesh radio. A mesh verb runs only when that radio's verdict
// CHANGED (the first application counts every radio as an edge): `stopJoin()` funnels through
// `stopSearching()`, whose three "if the session ended" hooks are meant to fire once per ending,
// and today's chain reached them only from the Friends tab's own exits.
//
// The two listeners are reconciled against the radio, not the last verdict (P8 item 0, device
// finding (b)). Both managers stand themselves down on a `didNotStart*` — which the Local Network
// permission prompt guarantees on a fresh install's very first start — and the prompt's
// inactive → active round trip is not a verdict change (`.inactive` is foreground by design), so a
// seam whose only memory was the previous verdict believed the listener up while the manager knew
// it was down, until the share sheet's own out-of-band `start()`: the owner's observed workaround.
// `MeshFacts` therefore carries each listener's own `isListening`, and a listener's verdict is
// re-applied whenever the two disagree. Both `start()` / `stop()` are idempotent (each guards
// `isRunning`), and a policy run is event-driven, so nothing spins: a denied permission costs one
// failed start per edge, not a loop.
//
// What the seams keep apart. `hasCommittedPeer` guards the radios — a `hold` verdict is its value;
// `isInSession` picks `leaveSession()` over `stopJoin()` on a hard stop; and `isSessionLive` is
// read by nothing here, because projections and ceremonies own it (P6 item 2's pass-B P1).
// `FriendsDiscoveryEntry` is still the three-way, unmoved.
//
// The row P7 could not execute is P8 item 3's verb: discovery `stop` with mesh `run` — a live
// background process that must stop browsing and admitting while KEEPING its links (invariant 5).
// `stopJoin()` would drop them, so P7 refused the row aloud; the seam now emits `.holdLinks` and
// the executor calls `MeshNetworkManager.holdCommittedLinks()`, which lowers `isSearching`, closes
// the admission doors and pauses the radio's browser/advertiser while every committed slot, its
// coordinator and the group-key state stay exactly where they are. The refusal, its action case and
// its audit token are gone, and `ProximityRunSeamsTests` holds the token at zero under `App/`.
//
// The row back out is explicit, and it has to be: after the hold the facts are `!isSearching` with
// a committed peer, which `FriendsDiscoveryEntry` answers `.none` — right for a Friends visit over
// a live session, and a one-way door for a foreground return whose radios are down. So
// `discoveryStart` emits `.resumeSearch` for exactly that pair of facts, without arming the "found
// nobody" timeout: a committed peer is not nobody. Off the FACTS, not off the previous verdict —
// the way out of a hold need not be direct, and foreground-on-Home (discovery `hold`) leaves the
// radios down with the hold row already behind it.

import Foundation
import FernletFoundation
import ProximityKit

// MARK: - ProximityRunAction

/// One thing a seam does to a radio — the transition's decision as a value, so the whole "which
/// verb, given the last verdict and this one" table is tier 1 and the executor decides nothing.
nonisolated enum ProximityRunAction: Equatable, Sendable {

    /// `MeshNetworkManager.startJoin()` — a fresh search cycle (`FriendsDiscoveryEntry.fresh`).
    case startJoin

    /// `MeshNetworkManager.resumeSearchingForPartitionedMesh()` — a mesh that outlived its links
    /// (`FriendsDiscoveryEntry.resume`).
    case resumeSearch

    /// `MeshNetworkManager.stopJoin()` — stand the discovery radios down; nothing committed to keep.
    case stopJoin

    /// `MeshNetworkManager.leaveSession()` — the mesh's own teardown. Only a hard stop asks for it.
    case leaveSession

    /// Arm the fresh search's five-minute "found nobody" timeout — the tab's half of door 3, which
    /// `ContentView.armDiscoveryTimeout()` used to own.
    case armDiscoveryTimeout

    /// Cancel that timeout.
    case cancelDiscoveryTimeout

    /// `MeshNetworkManager.holdCommittedLinks()` — stop browsing and admission, keep every
    /// committed link (P8 item 3). The row is discovery `stop` while the mesh keeps `run`, which P7
    /// could only refuse. Deliberately spelled differently from the verb it runs, so the retirement
    /// wall's needle counts the manager call and nothing else.
    case holdLinks

    /// `PresenceManager.apply(_:)` with the presence verdict.
    case presence(ProximityRunState)

    /// `ProximityRecipeShareManager.apply(_:)` with the recipe-share verdict.
    case recipeShare(ProximityRunState)
}

// MARK: - ProximityRunTransition

/// The pure half of the seams: which actions one verdict change asks for.
nonisolated enum ProximityRunTransition {

    /// The mesh manager's live facts the discovery seam reads — the same three
    /// `ContentView.startFriendsDiscovery()` and `stopFriendsDiscovery()` read.
    nonisolated struct MeshFacts: Equatable, Sendable {

        /// `MeshNetworkManager.isSearching` — the discovery radios are up.
        let isSearching: Bool

        /// `MeshNetworkManager.isInSession` — a mesh is held, or some slot committed.
        let isInSession: Bool

        /// `MeshNetworkManager.hasCommittedPeer` — a slot holds a committed fingerprint now.
        let hasCommittedPeer: Bool

        /// `PresenceManager.isListening` — the presence radio is up, by its own account.
        let presenceListening: Bool

        /// `ProximityRecipeShareManager.isListening` — the recipe listener is up, by its own account.
        let recipeShareListening: Bool

        /// Builds the facts.
        ///
        /// - Parameters:
        ///   - isSearching: Whether the discovery radios are up.
        ///   - isInSession: Whether a mesh is held or a slot committed.
        ///   - hasCommittedPeer: Whether a slot holds a committed fingerprint now.
        ///   - presenceListening: Whether the presence radio is up now.
        ///   - recipeShareListening: Whether the recipe listener is up now.
        init(
            isSearching: Bool, isInSession: Bool, hasCommittedPeer: Bool,
            presenceListening: Bool, recipeShareListening: Bool
        ) {
            self.isSearching = isSearching
            self.isInSession = isInSession
            self.hasCommittedPeer = hasCommittedPeer
            self.presenceListening = presenceListening
            self.recipeShareListening = recipeShareListening
        }
    }

    /// The actions, in the order the executor runs them: the mesh radios first, then presence,
    /// then recipe share. A mesh radio whose verdict did not move asks for nothing; a listener
    /// asks for nothing while its own account matches its verdict, and is re-applied when it does
    /// not (``listenerNeedsReconciling(_:listening:)``).
    ///
    /// - Parameters:
    ///   - previous: The last verdict applied, or nil before the first — when every radio is an edge.
    ///   - verdict: The verdict to apply.
    ///   - mesh: The mesh manager's live facts.
    /// - Returns: The ordered actions; empty when nothing moved.
    static func actions(
        from previous: ProximityRunPolicy.Verdict?,
        to verdict: ProximityRunPolicy.Verdict,
        mesh: MeshFacts
    ) -> [ProximityRunAction] {
        var actions = meshActions(from: previous, to: verdict, mesh: mesh)
        if previous?.presence != verdict.presence
            || listenerNeedsReconciling(verdict.presence, listening: mesh.presenceListening) {
            actions.append(.presence(verdict.presence))
        }
        if previous?.recipeShare != verdict.recipeShare
            || listenerNeedsReconciling(verdict.recipeShare, listening: mesh.recipeShareListening) {
            actions.append(.recipeShare(verdict.recipeShare))
        }
        return actions
    }

    /// Whether a listener's verdict must be re-applied because the radio no longer matches it.
    ///
    /// - Parameters:
    ///   - state: The listener's verdict.
    ///   - listening: The radio's own account of whether it is up.
    /// - Returns: Whether the seam re-applies the verdict.
    static func listenerNeedsReconciling(_ state: ProximityRunState, listening: Bool) -> Bool {
        switch state {
        case .run, .foregroundOnly: return !listening
        case .stop: return listening
        case .hold: return false
        }
    }

    /// The mesh half. A hard stop (mesh `stop`) tears down whatever is up — the session if one is
    /// held, else the search — and cancels the tab's timeout; otherwise only a discovery edge acts.
    private static func meshActions(
        from previous: ProximityRunPolicy.Verdict?,
        to verdict: ProximityRunPolicy.Verdict,
        mesh: MeshFacts
    ) -> [ProximityRunAction] {
        let meshMoved = previous?.mesh != verdict.mesh
        let discoveryMoved = previous?.discovery != verdict.discovery
        switch verdict.mesh {
        case .stop:
            guard meshMoved else { return [] }
            if mesh.isInSession { return [.cancelDiscoveryTimeout, .leaveSession] }
            if mesh.isSearching { return [.cancelDiscoveryTimeout, .stopJoin] }
            return [.cancelDiscoveryTimeout]
        case .run, .foregroundOnly, .hold:
            break
        }
        guard discoveryMoved else { return [] }
        switch verdict.discovery {
        case .foregroundOnly:
            return discoveryStart(mesh)
        case .hold:
            return [.cancelDiscoveryTimeout]
        case .stop:
            return discoveryStop(verdict.mesh, mesh: mesh)
        case .run:
            // Never emitted for discovery (invariant 5); answered rather than trapped.
            return []
        }
    }

    /// A discovery edge INTO `foregroundOnly`: the three-way, guarded on `isSearching` exactly as
    /// the tab's arm was, and arming the timeout for exactly the entries that arm it — plus the one
    /// way in that the three-way cannot see, the return from P8 item 3's background hold.
    private static func discoveryStart(_ mesh: MeshFacts) -> [ProximityRunAction] {
        guard !mesh.isSearching else { return [] }
        // The re-entry row (P8 item 3). **Radios down with a peer still committed** is a state only
        // `holdCommittedLinks()` can produce — `stopJoin()` lowers `isSearching` too, but it empties
        // the slots on the way, so `hasCommittedPeer` is false there — and it is the one state
        // `FriendsDiscoveryEntry` answers wrongly: `entry(true, true)` is `.none`, which is right
        // for a Friends visit over a session whose radios are already up, and a ONE-WAY DOOR here.
        // Without this row a held session could never browse, admit or re-dial again.
        //
        // Read off the FACTS rather than off the previous verdict on purpose: the return out of a
        // hold need not be direct. Foreground on Home is discovery `hold` ("keep what you have"),
        // which leaves the radios down and the previous verdict no longer the hold row, so a test
        // on `previous` would miss the next Friends visit entirely.
        //
        // No timeout is armed: a committed peer is not "found nobody", and the manager arms its own
        // give-up clock at the slot-loss doors. A hold with NO committed peer is deliberately not
        // here — it falls through to `.resume` plus the arm, which is already the right answer.
        if mesh.hasCommittedPeer { return [.resumeSearch] }
        let entry = FriendsDiscoveryEntry.entry(
            isInSession: mesh.isInSession, hasCommittedPeer: mesh.hasCommittedPeer
        )
        var actions: [ProximityRunAction] = []
        switch entry {
        case .fresh: actions.append(.startJoin)
        case .resume: actions.append(.resumeSearch)
        case .none: break
        }
        if entry.armsDiscoveryTimeout { actions.append(.armDiscoveryTimeout) }
        return actions
    }

    /// A discovery edge INTO `stop`: the stand-down, or — while the mesh keeps running — P8's hold.
    private static func discoveryStop(
        _ meshState: ProximityRunState, mesh: MeshFacts
    ) -> [ProximityRunAction] {
        switch meshState {
        case .run:
            return [.holdLinks]
        case .foregroundOnly, .hold, .stop:
            return mesh.isSearching ? [.cancelDiscoveryTimeout, .stopJoin] : [.cancelDiscoveryTimeout]
        }
    }
}

// MARK: - The executor

extension FernletStore {

    /// Runs the actions a transition decided, in order — the ONLY place in the app that speaks a
    /// radio verb (`ProximityRunSeamsTests` counts every verb under `App/` into this file).
    ///
    /// - Parameter actions: The ordered actions from
    ///   ``ProximityRunTransition/actions(from:to:mesh:)``.
    func executeProximityRunActions(_ actions: [ProximityRunAction]) {
        // R2: bounded by the transition's own list.
        for action in actions {
            switch action {
            case .startJoin:
                meshNetworkManager.startJoin()
            case .resumeSearch:
                meshNetworkManager.resumeSearchingForPartitionedMesh()
            case .stopJoin:
                meshNetworkManager.stopJoin()
            case .leaveSession:
                meshNetworkManager.leaveSession()
            case .armDiscoveryTimeout:
                armDiscoveryTimeout()
            case .cancelDiscoveryTimeout:
                cancelDiscoveryTimeout()
            case .holdLinks:
                meshNetworkManager.holdCommittedLinks()
            case .presence(let state):
                presenceManager.apply(state)
            case .recipeShare(let state):
                recipeShareManager.apply(state)
            }
        }
    }

    /// The tab's half of door 3 (P6 item 2 fix review, P2-1), moved here from
    /// `ContentView.armDiscoveryTimeout()` with its behaviour intact: five minutes of finding
    /// nobody ends the session through `endSessionAfterDiscoveryTimeout()`, which refuses while a
    /// peer is committed. Cancellation means the arm was superseded and ends nothing. The manager
    /// arms the same interval itself at the slot-loss doors; this arm exists because a search that
    /// never had a peer never loses one, so the manager's edge never fires for it.
    private func armDiscoveryTimeout() {
        discoveryTimeoutTask?.cancel()
        discoveryTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(MeshNetworkManager.discoveryGiveUpInterval))
            } catch {
                // Cancellation means the timeout was superseded (a stand-down, or a new start).
                return
            }
            self?.meshNetworkManager.endSessionAfterDiscoveryTimeout()
        }
    }

    /// Stands the tab's timeout down.
    private func cancelDiscoveryTimeout() {
        discoveryTimeoutTask?.cancel()
        discoveryTimeoutTask = nil
    }
}

// MARK: - The listeners' seams

extension PresenceManager {

    /// The presence radio's one seam: `run` and `foregroundOnly` start it, `stop` stops it, and
    /// `hold` — which the policy never emits for a listener — keeps what it has. Both verbs are
    /// idempotent inside the manager.
    ///
    /// - Parameter state: The presence radio's verdict.
    func apply(_ state: ProximityRunState) {
        switch state {
        case .run, .foregroundOnly: start()
        case .hold: break
        case .stop: stop()
        }
    }
}

extension ProximityRecipeShareManager {

    /// The recipe-share listener's one seam, on the same terms as ``PresenceManager/apply(_:)``.
    ///
    /// - Parameter state: The recipe-share listener's verdict.
    func apply(_ state: ProximityRunState) {
        switch state {
        case .run, .foregroundOnly: start()
        case .hold: break
        case .stop: stop()
        }
    }
}
