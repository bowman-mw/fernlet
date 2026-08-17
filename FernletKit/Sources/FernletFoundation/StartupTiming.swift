import Foundation
import os
import os.signpost

/// Launch-performance instrumentation: `os_signpost` intervals for app-startup work.
///
/// The app (`FernletApp`, `FernletStore`, `LaunchPreparationService`) and the heavier module
/// loads (CloudKit persistence and repositories, the food catalog, derived-signal rebuilds) wrap
/// startup phases in these signposts (subsystem `com.fernlet`, category `startup`) so Instruments
/// can attribute launch time per phase. ``beginAppLaunch()``/``endAppLaunch()`` bracket the
/// single overall "App Launch" interval, guarded by a lock + flag so repeated calls (e.g. scene
/// reactivation) cannot emit unbalanced signposts.
///
/// Concurrency: the module's `MainActor` default isolation applies to the app-launch pair and its
/// state; the general-purpose ``begin(_:)``/``end(_:signpostID:)`` and both `timed(_:_:)`
/// overloads are explicitly `nonisolated` so any executor can instrument its own interval. In
/// DEBUG builds, `timed` additionally prints the elapsed milliseconds to the console.
public enum StartupTiming {
    private static let appLaunchLog = OSLog(subsystem: "com.fernlet", category: "startup")
    private static let appLaunchID = OSSignpostID(log: appLaunchLog)
    /// The once-per-launch "App Launch interval is open" latch.
    ///
    /// R6/R9: an immutable `let` that owns its lock rather than a stored `static var` beside a
    /// separate `NSLock` — the flag can only be read or written while the lock is held, so
    /// repeated `beginAppLaunch()`/`endAppLaunch()` calls (scene reactivation) can never emit an
    /// unbalanced signpost pair, whatever executor they arrive on.
    private static let appLaunchIsActive = OSAllocatedUnfairLock(initialState: false)

    nonisolated private static var log: OSLog {
        OSLog(subsystem: "com.fernlet", category: "startup")
    }

    /// Opens the overall "App Launch" signpost interval; redundant calls while one is already
    /// active are ignored.
    public static func beginAppLaunch() {
        let opened = appLaunchIsActive.withLock { isActive -> Bool in
            guard !isActive else { return false }
            isActive = true
            return true
        }
        guard opened else { return }
        os_signpost(.begin, log: appLaunchLog, name: "App Launch", signpostID: appLaunchID)
    }

    /// Closes the overall "App Launch" signpost interval; a call with no interval open is ignored.
    public static func endAppLaunch() {
        let closed = appLaunchIsActive.withLock { isActive -> Bool in
            guard isActive else { return false }
            isActive = false
            return true
        }
        guard closed else { return }
        os_signpost(.end, log: appLaunchLog, name: "App Launch", signpostID: appLaunchID)
    }

    /// Opens a named signpost interval and returns the ID that ``end(_:signpostID:)`` must be
    /// called with to close it.
    nonisolated public static func begin(_ label: StaticString) -> OSSignpostID {
        let log = Self.log
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: label, signpostID: id)
        return id
    }

    /// Closes the signpost interval opened by ``begin(_:)`` with the same label and ID.
    nonisolated public static func end(_ label: StaticString, signpostID: OSSignpostID) {
        os_signpost(.end, log: Self.log, name: label, signpostID: signpostID)
    }

    /// Runs `work` inside a signpost interval, returning its result; in DEBUG builds also prints
    /// the elapsed milliseconds.
    @discardableResult
    nonisolated public static func timed<T>(_ label: StaticString, _ work: () throws -> T) rethrows -> T {
        let log = Self.log
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: label, signpostID: id)
        defer { os_signpost(.end, log: log, name: label, signpostID: id) }

        let start = CFAbsoluteTimeGetCurrent()
        let result = try work()
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000

        #if DEBUG
        print(String(format: "[startup] %@ took %.1f ms", String(describing: label), ms))
        #endif

        return result
    }

    /// Async variant of `timed(_:_:)`: runs `work` inside a signpost interval — suspension time
    /// counts toward the measured duration.
    @discardableResult
    nonisolated public static func timed<T>(_ label: StaticString, _ work: () async throws -> T) async rethrows -> T {
        let log = Self.log
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: label, signpostID: id)
        defer { os_signpost(.end, log: log, name: label, signpostID: id) }

        let start = CFAbsoluteTimeGetCurrent()
        let result = try await work()
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000

        #if DEBUG
        print(String(format: "[startup] %@ took %.1f ms", String(describing: label), ms))
        #endif

        return result
    }
}
