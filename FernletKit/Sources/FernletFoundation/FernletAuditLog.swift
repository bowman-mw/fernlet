import Foundation
import os

public enum FernletAuditLog {
    nonisolated private static let logger = Logger(subsystem: "com.fernlet", category: "audit")
    nonisolated(unsafe) public static var captureHandler: ((String, [String: String]) -> Void)?

    nonisolated public static func log(_ event: String, context: [String: String] = [:]) {
        captureHandler?(event, context)
        let ctx = context.isEmpty ? "" : " " + context
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        logger.info("\(event, privacy: .auto)\(ctx, privacy: .private)")
    }
}
