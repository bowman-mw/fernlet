// ProximitySessionPoller.swift
// Fernlet
//
// Network migration P7 item 4: the app's half of the poller — ONE timer, owned by the composition
// root, started and stopped with `MeshNetworkManager.isSessionLive`, driving
// `MeshNetworkManager.pollSession(now:)` (ceiling → idle lapse → partition) every `interval`
// seconds while a session is live, and not one tick otherwise.
//
// Why the timer is the app's and the order is ProximityKit's: the three consumers are on demand so
// that nothing spins, and only something that already knows whether a session is live can start
// and stop one timer honestly. The store's run-policy core re-syncs the timer after every edge, and
// `ContentView` observes `isSessionLive` so a session founded or ended between edges starts or
// stops it too. The tick stops itself the moment a poll reports the session gone, and the loop is
// bounded by the ceiling itself — a session cannot outlive 6 h, so it cannot outlive
// `maxTicks` polls — which is the R2 bound and the reason a timer never outlives a session.
//
// Deliberately NOT keyed on a radio verdict. A `hold` mesh in the background with no continuation
// task is suspended by the OS along with its timer and resumes with it; a CPT-continued mesh (P8)
// keeps the process live and the poll running, which is exactly what that phase needs; and a
// session that ends by its own ceiling stops the timer without any edge at all.
//
// That last sentence is also why this tick, and not the view, is what tells P8's continuation host
// a background session is over (item 6's fix round, F3): every mesh edge into the host is a SwiftUI
// `.onChange` on the stable root, and a backgrounded scene's body is not re-evaluated, so a ceiling
// or idle end reached behind a continued task would otherwise leave the app holding a task for a
// dead session until the system's own expiry paid it `false`.

import Foundation
import ProximityKit

// MARK: - ProximitySessionPoller

/// The poller's decision half — pure, so the start/stop rule and the interval are a table.
nonisolated enum ProximitySessionPoller {

    /// The tick: 30 s, the coarsest interval that still honours the 30-minute idle stop and the
    /// 6-hour ceiling with a lateness nobody can perceive. Item 4 starts here; P8 measures.
    static let interval: TimeInterval = 30

    /// The most polls one session can take: the ceiling's 6 hours in ticks, plus one. The timer's
    /// loop bound (Power of 10, R2); a session that somehow outlived it would be re-synced by the
    /// next edge or liveness change.
    static let maxTicks = Int(MeshSessionCeiling.ceilingSeconds / interval) + 1

    /// What the store's sync does to its timer.
    nonisolated enum Decision: Equatable, Sendable, CaseIterable {

        /// A session is live and no timer runs: start one.
        case start

        /// No session is live and a timer runs: stop it.
        case stop

        /// Nothing to change.
        case keep
    }

    /// The rule: a timer if and only if a live session.
    ///
    /// - Parameters:
    ///   - isSessionLive: `MeshNetworkManager.isSessionLive`.
    ///   - isPolling: Whether the store holds a running timer.
    /// - Returns: The decision.
    static func decision(isSessionLive: Bool, isPolling: Bool) -> Decision {
        switch (isSessionLive, isPolling) {
        case (true, false): return .start
        case (false, true): return .stop
        case (true, true), (false, false): return .keep
        }
    }
}

// MARK: - The timer

extension FernletStore {

    /// Brings the one timer into line with `isSessionLive` — called by the run-policy core after
    /// every edge, and reached by `ContentView`'s liveness observer between edges.
    func syncSessionPoller() {
        let decision = ProximitySessionPoller.decision(
            isSessionLive: meshNetworkManager.isSessionLive, isPolling: sessionPollTask != nil
        )
        switch decision {
        case .start: startSessionPoller()
        case .stop: stopSessionPoller()
        case .keep: break
        }
    }

    /// The one timer. `[weak self]`, cancellation-exited, bounded by the ceiling in ticks, and
    /// self-stopping on a poll that reports the session gone.
    private func startSessionPoller() {
        sessionPollTask = Task { @MainActor [weak self] in
            // R2: bounded by the ceiling — a session cannot outlive `maxTicks` polls.
            for _ in 0..<ProximitySessionPoller.maxTicks {
                do {
                    try await Task.sleep(for: .seconds(ProximitySessionPoller.interval))
                } catch {
                    // Cancellation exits the loop — that IS the stop.
                    return
                }
                guard !Task.isCancelled, let self else { return }
                let report = await self.meshNetworkManager.pollSession(now: Date())
                // P8 item 6: the continuation task's progress bar rides THIS tick and no other.
                // The API kills a task whose progress stops advancing, and a second timer for one
                // deadline is exactly what this file exists to prevent — the host reads the
                // session's elapsed/budget/roster reading and writes one number.
                self.meshContinuationHost.sessionPollerDidTick()
                if !report.sessionLiveAfter {
                    // P8 item 6, fix round F3: a session that ends by its own 6-hour ceiling or its
                    // 30-minute idle lapse ends with NO view edge — a backgrounded scene's body is
                    // not re-evaluated, so `ContentView`'s mesh observer may never run. This is the
                    // one place that is already background-safe and already holds the host, so the
                    // task is completed and the pending request withdrawn from HERE. The view's
                    // later edge is absorbed (`fromCompleted(.sessionEnded)`), so it stays a no-op.
                    self.meshContinuationHost.meshDidEnd()
                    self.stopSessionPoller()
                    return
                }
            }
        }
    }

    /// Stands the timer down.
    private func stopSessionPoller() {
        sessionPollTask?.cancel()
        sessionPollTask = nil
    }
}
