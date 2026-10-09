// FernletMeshHost.swift
// FernletSocial/Mesh
//
// ProximityKit plan step A0.5.5: the host Fernlet's mesh features read, held the way the mesh
// manager holds its own, and the one helper that pins it for a spawned task. Every feature object the
// composition (`FernletMeshFeatures`) builds reads the host through this object, so FernletSocial's
// mesh features hold the host in exactly one file, the one `MemoryLifecycleBoundaryTests`' ML4 audits
// as a host holder; a file that holds this object instead is held by the same rule's second audit.
// Since plan step A0.5.10 the host is the features' own refinement, `FernletSocialHost`, so a feature
// reads the trust store, the trusted-peer records and the hearts opt-in through this object too.

import Foundation
import ProximityKit

/// The host Fernlet's mesh features read: the app's ``FernletSocialHost`` (ProximityKit's
/// ``ProximityHost`` and the requirements only Fernlet's features read), held `unowned`, its protocol
/// namespace, read once, and the one helper that pins the host for a spawned task.
///
/// `unowned` because the host owns the composition that owns this object (FernletStore's `lazy var`
/// mesh features), as ``MeshNetworkManager`` holds its own host; the back-reference is that
/// ownership's cycle-breaker. The namespace is read once, at construction, the same value the mesh
/// reads at its own construction (the host's contract: "read once, at construction"), so no feature
/// reads back to the host for it. `@MainActor`, like the features that read it.
@MainActor
final class FernletMeshHost {

    /// The app's host, which owns the composition this object belongs to.
    unowned let host: any FernletSocialHost

    /// The host's protocol identity, read once from ``host`` at construction and kept as the
    /// features' own copy, so no later read reaches back to the host. `nonisolated`: inert
    /// `Sendable` value data.
    nonisolated let namespace: ProximityNamespace

    /// Holds `host` and reads its namespace once.
    ///
    /// - Parameter host: The app's host; the caller keeps it alive.
    init(host: any FernletSocialHost) {
        self.host = host
        self.namespace = host.proximityNamespace
    }

    /// Spawns a detached task that PINS the host for the task's own lifetime.
    ///
    /// ``host`` is `unowned` because the host owns the features that hold this object, and the
    /// unowned back-reference is that ownership's cycle-breaker. A detached task, however, holds a
    /// feature STRONGLY for the duration of every `self?.method()` it awaits, so it can outlive the
    /// host and then read a destroyed object — `swift_abortRetainUnowned` aborts the whole process
    /// (P5 item 1a). Capturing the host here, read synchronously on the main actor at a point where it
    /// is provably alive, makes the read the task will later perform valid by construction
    /// (invariant HP1).
    ///
    /// The pin is safe ONLY because the task's handle is not stored: nothing the host owns can reach
    /// this closure context, so no `host → feature → task → host` cycle forms. NEVER build the same pin
    /// into a task whose handle a feature keeps (invariant HP2).
    ///
    /// The closure is deliberately neither `@Sendable` nor `sending`, so it inherits the caller's
    /// main-actor isolation exactly as a `Task { … }` literal would — same executor, same enqueue,
    /// same ordering. The mesh manager's own helper is this one's twin, for the engine's spawns.
    ///
    /// - Parameter operation: The work to run, which may read the host.
    func spawnHostPinned(_ operation: @escaping () async -> Void) {
        let host = self.host
        Task {   // host-pin: helper
            await operation()
            withExtendedLifetime(host) {}
        }
    }
}
