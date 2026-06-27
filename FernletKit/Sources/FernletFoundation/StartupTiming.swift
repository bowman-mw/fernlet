import Foundation
import os.signpost

public enum StartupTiming {
    private static let appLaunchLog = OSLog(subsystem: "com.fernlet", category: "startup")
    private static let appLaunchID = OSSignpostID(log: appLaunchLog)
    private static let appLaunchLock = NSLock()
    private static var appLaunchIsActive = false

    nonisolated private static var log: OSLog {
        OSLog(subsystem: "com.fernlet", category: "startup")
    }

    public static func beginAppLaunch() {
        appLaunchLock.lock()
        defer { appLaunchLock.unlock() }
        guard !appLaunchIsActive else { return }
        appLaunchIsActive = true
        os_signpost(.begin, log: appLaunchLog, name: "App Launch", signpostID: appLaunchID)
    }

    public static func endAppLaunch() {
        appLaunchLock.lock()
        defer { appLaunchLock.unlock() }
        guard appLaunchIsActive else { return }
        appLaunchIsActive = false
        os_signpost(.end, log: appLaunchLog, name: "App Launch", signpostID: appLaunchID)
    }

    nonisolated public static func begin(_ label: StaticString) -> OSSignpostID {
        let log = Self.log
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: label, signpostID: id)
        return id
    }

    nonisolated public static func end(_ label: StaticString, signpostID: OSSignpostID) {
        os_signpost(.end, log: Self.log, name: label, signpostID: signpostID)
    }

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
