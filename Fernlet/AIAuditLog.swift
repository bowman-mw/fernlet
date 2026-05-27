import Foundation

// MARK: - Audit entry

/// A record of a single AI call made this session.
/// Stores metadata only — never prompt text, generated content, or user data values.
struct AIAuditEntry: Identifiable, Sendable {
    var id = UUID()
    var timestamp: Date
    var payloadKind: String
    var destination: AIDestination
    /// Names of the fields that were included in the payload (not their values).
    var includedFields: [String]
    /// Character length of the filtered memory context that was injected (0 if none).
    var memorySummaryCharCount: Int
}

// MARK: - Audit log

/// Thread-safe in-session log of AI calls.
/// Not persisted to disk — exists for privacy review and debugging within a single session.
actor AIAuditLog {
    static let shared = AIAuditLog()

    private(set) var entries: [AIAuditEntry] = []

    func record(
        _ payload: some AIContextPayload,
        destination: AIDestination,
        memorySummaryCharCount: Int = 0
    ) {
        entries.append(AIAuditEntry(
            timestamp: Date(),
            payloadKind: payload.payloadKind,
            destination: destination,
            includedFields: payload.includedFieldNames,
            memorySummaryCharCount: memorySummaryCharCount
        ))
    }

    func clear() {
        entries = []
    }
}
