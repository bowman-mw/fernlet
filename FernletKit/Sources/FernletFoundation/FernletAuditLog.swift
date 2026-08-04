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
/// the others, silently swallowing an in-flight test's events. The registry is guarded by an
/// `NSLock`; ``log(_:context:)`` snapshots the handler list under the lock and invokes handlers
/// outside it, so a handler is free to re-enter the log (or block) without deadlocking. All
/// members are `nonisolated` and callable from any executor.
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
    nonisolated(unsafe) private static var captureHandlers: [UUID: CaptureHandler] = [:]
    nonisolated private static let captureHandlersLock = NSLock()

    /// Registers a capture handler and returns a token used to remove it later.
    ///
    /// Handlers accumulate — installing one never displaces another — so concurrent test suites
    /// each observe every event. Pair with ``removeCaptureHandler(_:)`` on teardown.
    @discardableResult
    nonisolated public static func addCaptureHandler(_ handler: @escaping CaptureHandler) -> UUID {
        let token = UUID()
        captureHandlersLock.lock()
        captureHandlers[token] = handler
        captureHandlersLock.unlock()
        return token
    }

    /// Removes a previously-registered capture handler.
    nonisolated public static func removeCaptureHandler(_ token: UUID) {
        captureHandlersLock.lock()
        captureHandlers.removeValue(forKey: token)
        captureHandlersLock.unlock()
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
        captureHandlersLock.lock()
        let handlers = Array(captureHandlers.values)
        captureHandlersLock.unlock()
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
