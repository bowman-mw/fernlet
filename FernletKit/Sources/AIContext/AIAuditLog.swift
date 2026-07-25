import Foundation
import FernletDomainModel

// MARK: - Outcome

/// How an AI call turned out (Ladder §7.2). Persisted inside the device-local audit log, so it is a
/// brick-vector raw-value enum: a new case rides the `EnumDecodeCompat` freeze/park discipline
/// (`AIAuditEntry`'s tolerant decode below), and an unknown token from a future build freezes to
/// `freezeDefault` rather than failing the whole log.
public enum AIAuditOutcome: String, Codable, Sendable, CaseIterable {
    /// The call produced a usable result.
    case succeeded
    /// The call returned/threw nothing usable and the caller fell back to a deterministic path.
    case fellBack
    /// The model declined the request (guardrail / safety refusal).
    case refused
    /// The model responded but the structured result did not conform / could not be resolved.
    case schemaFailed

    /// The frozen default an unknown persisted token decodes to (never fail the log).
    public static let freezeDefault: AIAuditOutcome = .succeeded
}

// MARK: - Audit entry

/// A record of a single AI call. Stores metadata only — never prompt text, generated content, or
/// user data values. Persisted DEVICE-LOCAL ONLY (see `AIAuditLogPersisting`); it never enters
/// `FernletSnapshot`, CloudKit, the sealed backup, or the data export (`AIContext` depends only on
/// `FernletDomainModel`, so there is no wall-safe *synced* home for it, which is the point — a
/// "what left my device" record that itself left the device would be the wrong privacy semantics).
public struct AIAuditEntry: Identifiable, Sendable, Codable {
    public var id: UUID
    public var timestamp: Date
    public var payloadKind: String
    public var destination: AIDestination
    /// Which model handled the call (not just the vendor/destination). `nil` when there is no single
    /// model to name (e.g. the web-nutrition search path). For the on-device floor, pass
    /// `AIAuditEntry.onDeviceFoundationModel`.
    public var modelIdentifier: String?
    /// How the call turned out.
    public var outcome: AIAuditOutcome
    /// Names of the fields that were included in the payload (not their values).
    public var includedFields: [String]
    /// Character length of the filtered memory context that was injected (0 if none).
    public var memorySummaryCharCount: Int

    /// Preserved raw token for a `destination` written by a FUTURE build (the same-device app-downgrade
    /// edge). The typed `destination` freezes to the floor, but the true token is kept here and
    /// re-encoded so a re-upgrade self-heals and a settings UI can still surface the real value. `nil`
    /// in the normal case.
    public var destinationParkedToken: String?
    /// Preserved raw token for an `outcome` written by a future build. Same discipline as above.
    public var outcomeParkedToken: String?

    /// Stable identifier for Apple's on-device Foundation model — the always-available floor. Used
    /// instead of a live SDK version string (the installed SDK exposes none) so the audit log carries
    /// a durable, greppable constant rather than a build-specific token.
    public static let onDeviceFoundationModel = "apple.ondevice.foundation-models"

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        payloadKind: String,
        destination: AIDestination,
        modelIdentifier: String? = nil,
        outcome: AIAuditOutcome = .succeeded,
        includedFields: [String],
        memorySummaryCharCount: Int = 0,
        destinationParkedToken: String? = nil,
        outcomeParkedToken: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.payloadKind = payloadKind
        self.destination = destination
        self.modelIdentifier = modelIdentifier
        self.outcome = outcome
        self.includedFields = includedFields
        self.memorySummaryCharCount = memorySummaryCharCount
        self.destinationParkedToken = destinationParkedToken
        self.outcomeParkedToken = outcomeParkedToken
    }

    private enum CodingKeys: String, CodingKey {
        case id, timestamp, payloadKind
        case destination, destinationParkedToken
        case modelIdentifier
        case outcome, outcomeParkedToken
        case includedFields, memorySummaryCharCount
    }

    /// Tolerant decode: an unknown `destination`/`outcome` raw value from a newer build freezes to the
    /// floor default and parks its token (`EnumDecodeCompat`) rather than throwing — a single unknown
    /// enum value must never fail the whole persisted log.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        timestamp = try c.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date()
        payloadKind = try c.decodeIfPresent(String.self, forKey: .payloadKind) ?? ""
        modelIdentifier = try c.decodeIfPresent(String.self, forKey: .modelIdentifier)
        includedFields = try c.decodeIfPresent([String].self, forKey: .includedFields) ?? []
        memorySummaryCharCount = try c.decodeIfPresent(Int.self, forKey: .memorySummaryCharCount) ?? 0

        let dest = try c.decodeTolerantEnum(
            AIDestination.self,
            forKey: .destination,
            parkedTokenKey: .destinationParkedToken,
            default: .onDeviceFoundationModels
        )
        destination = dest.value
        destinationParkedToken = dest.parkedToken

        let out = try c.decodeTolerantEnum(
            AIAuditOutcome.self,
            forKey: .outcome,
            parkedTokenKey: .outcomeParkedToken,
            default: AIAuditOutcome.freezeDefault
        )
        outcome = out.value
        outcomeParkedToken = out.parkedToken
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode(payloadKind, forKey: .payloadKind)
        // Main key always carries a raw value this build knows (the frozen default when the true value
        // is a parked future token), so a strict older build can still decode this re-save.
        try c.encode(destination.rawValue, forKey: .destination)
        try c.encodeIfPresent(destinationParkedToken, forKey: .destinationParkedToken)
        try c.encodeIfPresent(modelIdentifier, forKey: .modelIdentifier)
        try c.encode(outcome.rawValue, forKey: .outcome)
        try c.encodeIfPresent(outcomeParkedToken, forKey: .outcomeParkedToken)
        try c.encode(includedFields, forKey: .includedFields)
        try c.encode(memorySummaryCharCount, forKey: .memorySummaryCharCount)
    }
}

// MARK: - Persistence sink

/// The injectable DEVICE-LOCAL persistence seam for the audit log (Ladder §7.2). Declared here in
/// `AIContext` so the log can be persisted without `AIContext` gaining a dependency on any storage
/// module — the concrete file-backed store lives in the app (composition root) and conforms to this,
/// exactly like `AICallQuotaStore`. It MUST be device-local only: never `CloudKitSync`, never the
/// snapshot, never the sealed backup. A synced "what left my device" log would itself leave the
/// device — the wrong semantics and the `AIDestination` brick-vector trigger.
public protocol AIAuditLogPersisting: Sendable {
    /// The persisted entries (oldest first), already capped to the ring-buffer limit. `[]` when none.
    func load() -> [AIAuditEntry]
    /// Persist the given entries (the sink caps/prunes to the ring-buffer limit).
    func save(_ entries: [AIAuditEntry])
    /// Erase the persisted log (delete-all-data).
    func clear()
}

// MARK: - Audit log

/// Thread-safe log of AI calls, backed by a device-local ring buffer once a sink is configured.
/// Survives relaunch (the sink reloads it on `configure`) so a future settings UI can show the user
/// what left their device — a log that died with the process could not.
public actor AIAuditLog {
    public static let shared = AIAuditLog()

    /// Ring-buffer cap for BOTH the in-memory working set and the persisted file (FIFO prune of the
    /// oldest). ~500 keeps a meaningful history at a quota ceiling of ~60 calls/day without unbounded
    /// growth.
    public static let entryLimit = 500

    public private(set) var entries: [AIAuditEntry] = []
    private var sink: AIAuditLogPersisting?

    public init() {}

    /// Wire the device-local persistence sink and adopt whatever survived the last relaunch. Any
    /// entries recorded before configuration are session-only; at real app launch this runs before any
    /// AI call, so the in-memory set is empty and simply adopts the persisted history.
    public func configure(sink: AIAuditLogPersisting) {
        self.sink = sink
        entries = Array(sink.load().suffix(Self.entryLimit))
    }

    /// Records an AI call. Extract `payloadKind` and `includedFields` from the payload at the call site
    /// (before any actor hop) to avoid Sendable boundary issues. Persists immediately when a sink is
    /// wired.
    public func record(
        payloadKind: String,
        destination: AIDestination,
        modelIdentifier: String? = nil,
        includedFields: [String],
        memorySummaryCharCount: Int = 0,
        outcome: AIAuditOutcome = .succeeded
    ) {
        entries.append(AIAuditEntry(
            timestamp: Date(),
            payloadKind: payloadKind,
            destination: destination,
            modelIdentifier: modelIdentifier,
            outcome: outcome,
            includedFields: includedFields,
            memorySummaryCharCount: memorySummaryCharCount
        ))
        if entries.count > Self.entryLimit {
            entries.removeFirst(entries.count - Self.entryLimit)
        }
        sink?.save(entries)
    }

    public func clear() {
        entries = []
        sink?.clear()
    }
}
