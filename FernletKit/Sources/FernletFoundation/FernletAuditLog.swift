import Foundation
import os

/// The app-wide audit sink for privacy- and security-relevant events.
///
/// Every subsystem that touches sensitive data — the lock service, the sealed
/// `PendingNarrativeBuffer` drain, CloudKit sync, HealthKit sync, snapshot saves, and the
/// Proximity identity/trust/heart-drop stack — reports through ``log(_:context:)`` rather than
/// ad-hoc `print`s, so the audit-completeness tests can assert that a given flow emitted its
/// expected trail. Events go to the unified `os.Logger` (subsystem `com.fernlet`, category
/// `audit`) with the free-form context marked `.private`, and are additionally fanned out to
/// every registered capture handler.
///
/// Capture handlers form a token-keyed *registry* rather than a single slot: parallel test
/// suites install handlers concurrently, and with one slot whichever installed last clobbered
/// the others, silently swallowing an in-flight test's events. The registry lives *inside* an
/// `OSAllocatedUnfairLock` (state and lock are one immutable `let`, so there is no mutable
/// static to race); ``log(_:context:)`` snapshots the handler list under the lock and invokes
/// handlers outside it, so a handler is free to re-enter the log (or block) without deadlocking.
/// All members are `nonisolated` and callable from any executor.
public enum FernletAuditLog {
    /// A test-installed sink receiving each logged event name and its context dictionary.
    public typealias CaptureHandler = (String, [String: String]) -> Void

    nonisolated private static let logger = Logger(subsystem: "com.fernlet", category: "audit")

    // A *set* of handlers rather than a single slot. Several tests across
    // different (parallel) suites install a capture handler at once; with a
    // single slot whichever installs last clobbers the others, so events from
    // an in-flight async test silently vanish into another test's sink. That
    // made the audit-completeness tests flaky under full-suite parallel load.
    // The registry lets every installed handler observe every event; tests add
    // one on setup and remove it (by token) on teardown.
    //
    // R6/R9: the registry is an immutable `let` that OWNS its lock, so there is no stored
    // `static var` and no `nonisolated(unsafe)` opt-out. `uncheckedState`/`withLockUnchecked`
    // because `CaptureHandler` is a plain (non-`Sendable`) closure; the lock is what makes the
    // dictionary safe, and no reference to it ever escapes a `withLockUnchecked` body.
    nonisolated private static let captureHandlers =
        OSAllocatedUnfairLock<[UUID: CaptureHandler]>(uncheckedState: [:])

    /// Registers a capture handler and returns a token used to remove it later.
    ///
    /// Handlers accumulate — installing one never displaces another — so concurrent test suites
    /// each observe every event. The token is the ONLY way to remove the handler, so it is not
    /// discardable: dropping it leaks a handler that then receives every event for the rest of the
    /// process. Pair with ``removeCaptureHandler(_:)`` on teardown.
    nonisolated public static func addCaptureHandler(_ handler: @escaping CaptureHandler) -> UUID {
        let token = UUID()
        captureHandlers.withLockUnchecked { $0[token] = handler }
        return token
    }

    /// Removes a previously-registered capture handler.
    nonisolated public static func removeCaptureHandler(_ token: UUID) {
        captureHandlers.withLockUnchecked { handlers in handlers[token] = nil }
    }

    /// Records an audit event to the unified log and to every registered capture handler.
    ///
    /// - Parameters:
    ///   - event: A short, stable event name (logged with `.auto` privacy).
    ///   - context: Free-form key/value detail, sorted by key for stable output and logged with
    ///     `.private` privacy so values are redacted outside a connected debugger.
    nonisolated public static func log(_ event: String, context: [String: String] = [:]) {
        // Snapshot under the lock, then invoke outside it so a handler is free
        // to call back into the log (or block) without deadlocking.
        let handlers = captureHandlers.withLockUnchecked { Array($0.values) }
        for handler in handlers {
            handler(event, context)
        }

        let ctx = context.isEmpty ? "" : " " + context
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        logger.info("\(event, privacy: .auto)\(ctx, privacy: .private)")
    }
}
