// FernletAuditBridge.swift
// FernletConnections
//
// ProximityKit plan step A0.2 (Docs/Plan-FernletCoach-ProximityKit-2026-10-01.md §4 A0.2, "Injected
// by the host ... which Fernlet bridges back so audit-capture tests keep working"): ProximityKit
// writes its audit lines to the sink its host installs (`ProximityAudit`), and this is Fernlet's.
// It hands every line to `FernletAuditLog` unchanged, on the caller's executor, before returning, so
// Fernlet's unified-log output and every test that captures a ProximityKit event through
// `FernletAuditLog.addCaptureHandler` see exactly what they saw when ProximityKit named
// `FernletAuditLog` itself. `FernletApp.init` installs it before anything touches ProximityKit.

import FernletFoundation
import ProximityKit

/// Fernlet's ProximityKit audit sink: forwards each event and its context to `FernletAuditLog`,
/// verbatim and synchronously.
///
/// **Verbatim.** No prefix, no rename, no namespace rewrite, no key dropped: the event names are
/// tokens tests pin byte for byte, and the `held`, `peer`, `reason` and `state` keys are what they
/// scope their counts by. Redaction stays `FernletAuditLog`'s (`.auto` for the name, `.private` for
/// the context).
///
/// **Synchronous.** ``record(_:context:)`` returns after `FernletAuditLog.log(_:context:)` has run
/// every capture handler and written the `os.Logger` line, on the executor that emitted the event:
/// one capture test changes the outcome of the emitting operation from inside its handler, inside a
/// task-local scope, and every other one reads its results right after the action returns.
///
/// **Installed once, unconditionally.** `FernletApp.init` installs it first, not behind the UI-test
/// harness check: the unit tests run hosted in the app, so the bridge is in place before any of them
/// builds a ProximityKit object. `ProximityAuditBridgeTests` fails if it is not.
///
/// `nonisolated` against this module's `defaultIsolation(MainActor.self)`: a main-actor conformance
/// could not be called from ProximityKit's `nonisolated` stores. A stateless value, so `Sendable`.
public nonisolated struct FernletAuditBridge: ProximityAuditSink {

    /// Makes the bridge. It holds no state: every line goes straight to `FernletAuditLog`.
    public init() {}

    /// Forwards one ProximityKit audit event to `FernletAuditLog`, unchanged, before returning.
    ///
    /// - Parameters:
    ///   - event: The event name, forwarded as given.
    ///   - context: The context, forwarded as given.
    public func record(_ event: String, context: [String: String]) {
        FernletAuditLog.log(event, context: context)
    }
}
