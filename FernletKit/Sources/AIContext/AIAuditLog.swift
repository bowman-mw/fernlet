import Foundation
import FernletDomainModel

// MARK: - Audit entry

/// A record of a single AI call made this session.
/// Stores metadata only — never prompt text, generated content, or user data values.
public struct AIAuditEntry: Identifiable, Sendable {
    public var id = UUID()
    public var timestamp: Date
    public var payloadKind: String
    public var destination: AIDestination
    /// Names of the fields that were included in the payload (not their values).
    public var includedFields: [String]
    /// Character length of the filtered memory context that was injected (0 if none).
    public var memorySummaryCharCount: Int

    public init(id: UUID = UUID(), timestamp: Date, payloadKind: String, destination: AIDestination, includedFields: [String], memorySummaryCharCount: Int) {
        self.id = id
        self.timestamp = timestamp
        self.payloadKind = payloadKind
        self.destination = destination
        self.includedFields = includedFields
        self.memorySummaryCharCount = memorySummaryCharCount
    }
}

// MARK: - Audit log

/// Thread-safe in-session log of AI calls.
/// Not persisted to disk — exists for privacy review and debugging within a single session.
public actor AIAuditLog {
    public static let shared = AIAuditLog()

    public private(set) var entries: [AIAuditEntry] = []

    public init() {}

    /// Records an AI call. Extract `payloadKind` and `includedFieldNames` from the payload
    /// at the call site (before any actor hop) to avoid Sendable boundary issues.
    public func record(
        payloadKind: String,
        destination: AIDestination,
        includedFields: [String],
        memorySummaryCharCount: Int = 0
    ) {
        if entries.count >= 200 { entries.removeFirst() }
        entries.append(AIAuditEntry(
            timestamp: Date(),
            payloadKind: payloadKind,
            destination: destination,
            includedFields: includedFields,
            memorySummaryCharCount: memorySummaryCharCount
        ))
    }

    public func clear() {
        entries = []
    }
}
