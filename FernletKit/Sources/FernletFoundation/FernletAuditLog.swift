import Foundation
import os

public enum FernletAuditLog {
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
