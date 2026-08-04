import Foundation
import FernletDomainModel

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Outcome

/// How an AI call turned out (Ladder §7.2).
///
/// Recorded on every ``AIAuditEntry`` and persisted inside the device-local audit log, so it is a
/// brick-vector raw-value enum: a new case rides the `EnumDecodeCompat` freeze/park discipline
/// (``AIAuditEntry``'s tolerant decode below), and an unknown token from a future build freezes to
/// ``freezeDefault`` rather than failing the whole log. ``fromModelError(_:)`` is the shared
/// classifier both `AIProviders` and the app target use to map a thrown model error to a case.
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

    /// Classifies a thrown error from an AI call into an audit outcome (Ladder §7.2). A guardrail /
    /// safety refusal maps to `.refused` — the one outcome the seam is otherwise unable to produce, so
    /// without this mapping a live content refusal (a reachable case TODAY on the on-device model) is
    /// silently misfiled as `.schemaFailed`. A cancelled task threw nothing usable and the caller falls
    /// back, so it maps to `.fellBack`; everything else (schema non-conformance, decode, plausibility)
    /// is `.schemaFailed`.
    ///
    /// Lives here — not duplicated at each call site — so the on-device catch blocks in both
    /// `AIProviders` and the app target share one classifier. The `FoundationModels` reference is a
    /// system-framework `canImport` guard: it adds no SwiftPM dependency edge and does not touch the
    /// wall. When the future PCC / BYOK adapters land, extend this mapper (or a per-rung sibling) so a
    /// vendor refusal reason also lands as `.refused` rather than a step-down-triggering schema failure.
    public static func fromModelError(_ error: Error) -> AIAuditOutcome {
        if error is CancellationError { return .fellBack }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), let generation = error as? LanguageModelSession.GenerationError {
            if case .guardrailViolation = generation { return .refused }
        }
        #endif
        return .schemaFailed
    }
}

// MARK: - Audit entry

/// A record of a single AI call — metadata only, never content.
///
/// Created by ``AIAuditLog/record(payloadKind:destination:modelIdentifier:includedFields:memorySummaryCharCount:outcome:)``
/// so a future settings UI can show the user exactly what left their device. Stores metadata only —
/// never prompt text, generated content, or user data values. Persisted DEVICE-LOCAL ONLY (see
/// ``AIAuditLogPersisting``); it never enters `FernletSnapshot`, CloudKit, the sealed backup, or the
/// data export (`AIContext` depends only on `FernletDomainModel`, so there is no wall-safe *synced*
/// home for it, which is the point — a "what left my device" record that itself left the device
/// would be the wrong privacy semantics). The custom `Codable` pair below implements the
/// `EnumDecodeCompat` freeze/park discipline for the two persisted enum fields.
public struct AIAuditEntry: Identifiable, Sendable, Codable {
    /// Stable identity for the entry; a caller that records at dispatch keeps this id so it can
    /// `updateOutcome` the same entry at completion.
    public var id: UUID
    /// When the call was recorded.
    public var timestamp: Date
    /// The `AIContextPayload.payloadKind` of the payload that was sent (e.g. `"companion-thought"`).
    public var payloadKind: String
    /// Where the call was routed (`AIDestination`) — the field that says whether data left the device.
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
    ///
    /// UI CONTRACT: any surface that displays `destination`/`outcome` MUST prefer the parked token when
    /// it is non-nil. On a downgrade an unknown future `destination` freezes to `.onDeviceFoundationModels`
    /// and an unknown `outcome` freezes to `.succeeded` — i.e. the freeze defaults read in the
    /// PRIVACY-WORST direction (an external call would otherwise render as on-device + succeeded). The
    /// parked token carries the truth; rendering the frozen enum without consulting it would understate
    /// what actually left the device.
    public var destinationParkedToken: String?
    /// Preserved raw token for an `outcome` written by a future build. Same discipline and the same UI
    /// contract as `destinationParkedToken` above (prefer this token when non-nil).
    public var outcomeParkedToken: String?

    /// Stable identifier for Apple's on-device Foundation model — the always-available floor. Used
    /// instead of a live SDK version string (the installed SDK exposes none) so the audit log carries
    /// a durable, greppable constant rather than a build-specific token.
    public static let onDeviceFoundationModel = "apple.ondevice.foundation-models"

    /// Creates an entry. The defaults model the common completion-time on-device record: a fresh id,
    /// `.succeeded`, no model identifier, no memory context, and no parked tokens.
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

    /// Persisted key set for the custom `Codable` pair, including the parked-token keys.
    ///
    /// Private so the tolerant `init(from:)` / strict-compatible `encode(to:)` below stay the only
    /// Codable surface of the entry.
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

    /// Backward-compatible encode: the main enum keys always carry a raw value this build knows, with
    /// any parked future token re-encoded alongside so nothing is lost across a downgrade round-trip.
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

/// The injectable DEVICE-LOCAL persistence seam for the audit log (Ladder §7.2).
///
/// Declared here in `AIContext` so the log can be persisted without `AIContext` gaining a dependency
/// on any storage module — the concrete file-backed store (`FileAIAuditLogStore`) lives in the app
/// (composition root) and conforms to this, exactly like ``AICallQuotaStore``; ``AIAuditLog`` only
/// ever sees the protocol. It MUST be device-local only: never `CloudKitSync`, never the snapshot,
/// never the sealed backup. A synced "what left my device" log would itself leave the device — the
/// wrong semantics and the `AIDestination` brick-vector trigger.
public protocol AIAuditLogPersisting: Sendable {
    /// The persisted entries (oldest first), already capped to the ring-buffer limit. `[]` when none.
    func load() -> [AIAuditEntry]
    /// Persist the given entries (the sink caps/prunes to the ring-buffer limit).
    func save(_ entries: [AIAuditEntry])
    /// Erase the persisted log (delete-all-data). Returns `true` when the store is known-empty
    /// afterward (removed, or nothing was there) and `false` when the erase failed and the log may
    /// still be on disk — so the delete-all funnel can surface an incomplete-wipe signal instead of
    /// claiming a clean sweep. A file-backed sink has a real removal-failure signal (unlike the plain
    /// UserDefaults quota reset); a purely in-memory sink returns `true`.
    @discardableResult
    func clear() -> Bool
}

// MARK: - Audit log

/// Thread-safe log of AI calls, backed by a device-local ring buffer once a sink is configured.
///
/// Every AI call site — in the walled `AIProviders` module and in the app target alike — records
/// through the ``shared`` instance, so the log is the single "what left my device" ledger the
/// Ladder §7.2 audit requires. It is an `actor`: records arrive from arbitrary tasks (providers,
/// view flows, launch preparation) and the isolation serializes them without a lock. Persistence
/// goes through the injected ``AIAuditLogPersisting`` sink only; until `configure` runs, entries are
/// held in memory and merged into the persisted history when the sink arrives, so the pre-configure
/// race never drops a record. Survives relaunch (the sink reloads it on `configure`) so a future
/// settings UI can show the user what left their device — a log that died with the process could not.
public actor AIAuditLog {
    /// The process-wide log every call site records through; tests may build their own instances.
    public static let shared = AIAuditLog()

    /// Ring-buffer cap for BOTH the in-memory working set and the persisted file (FIFO prune of the
    /// oldest). ~500 keeps a meaningful history at a quota ceiling of ~60 calls/day without unbounded
    /// growth.
    public static let entryLimit = 500

    /// The in-memory working set, oldest first, capped at ``entryLimit``. Mutated only through
    /// `record` / `updateOutcome` / `clear` so the sink and memory never diverge.
    public private(set) var entries: [AIAuditEntry] = []
    /// The device-local persistence sink; `nil` until `configure` wires one (entries stay in memory).
    private var sink: AIAuditLogPersisting?

    /// Creates an empty, un-persisted log; call `configure(sink:)` to wire persistence.
    public init() {}

    /// Wire the device-local persistence sink and adopt whatever survived the last relaunch. At real
    /// app launch this normally runs before any AI call, so the in-memory set is empty and simply adopts
    /// the persisted history. But `configure` is dispatched from an unstructured `Task` at store init,
    /// so an early AI call CAN record before it runs — those pending session entries are MERGED with the
    /// persisted history (deduped by id, oldest first) and re-persisted rather than discarded, so a race
    /// between the first record and configuration never silently drops an entry.
    public func configure(sink: AIAuditLogPersisting) {
        self.sink = sink
        let persisted = sink.load()
        let pending = entries
        var seen = Set<UUID>()
        var merged: [AIAuditEntry] = []
        for entry in persisted + pending where seen.insert(entry.id).inserted {
            merged.append(entry)
        }
        entries = Array(merged.suffix(Self.entryLimit))
        // Only re-persist when a pre-configure record actually happened; a plain adopt needs no write.
        if pending.isEmpty == false {
            sink.save(entries)
        }
    }

    /// Records an AI call. Extract `payloadKind` and `includedFields` from the payload at the call site
    /// (before any actor hop) to avoid Sendable boundary issues. Persists immediately when a sink is
    /// wired. Returns the new entry's id so a caller that recorded at DISPATCH can `updateOutcome` it at
    /// completion.
    ///
    /// The ON-DEVICE Foundation-model rungs (`destination.leavesDevice == false`) may record at
    /// COMPLETION with the resolved `outcome` — nothing left the device until the call returned. But any
    /// destination whose `leavesDevice == true` (the web-nutrition search rung today; PCC / BYOK when
    /// those adapters land) MUST record at DISPATCH and then `updateOutcome` at completion: a call that
    /// crashed or was killed mid-flight has already sent its payload off-device, so a log that only
    /// recorded on success would tell exactly the one lie it exists to prevent. See
    /// `FoodProductLookupSheet.loadPreview` for the web rung's dispatch-then-update pairing.
    @discardableResult
    public func record(
        payloadKind: String,
        destination: AIDestination,
        modelIdentifier: String? = nil,
        includedFields: [String],
        memorySummaryCharCount: Int = 0,
        outcome: AIAuditOutcome = .succeeded
    ) -> UUID {
        let entry = AIAuditEntry(
            timestamp: Date(),
            payloadKind: payloadKind,
            destination: destination,
            modelIdentifier: modelIdentifier,
            outcome: outcome,
            includedFields: includedFields,
            memorySummaryCharCount: memorySummaryCharCount
        )
        entries.append(entry)
        if entries.count > Self.entryLimit {
            entries.removeFirst(entries.count - Self.entryLimit)
        }
        sink?.save(entries)
        return entry.id
    }

    /// Updates the outcome of a previously-recorded entry (the DISPATCH-then-completion pairing for an
    /// off-device rung). A no-op when the id is unknown — e.g. the entry already aged out of the capped
    /// ring — so a late completion never resurrects a dropped record. Re-persists when it changed.
    public func updateOutcome(id: UUID, to outcome: AIAuditOutcome) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        guard entries[index].outcome != outcome || entries[index].outcomeParkedToken != nil else { return }
        entries[index].outcome = outcome
        // A resolved outcome supersedes any parked future-build token (this build now owns the truth).
        entries[index].outcomeParkedToken = nil
        sink?.save(entries)
    }

    /// Wipes the in-memory working set and asks the sink to erase its file (delete-all-data).
    public func clear() {
        entries = []
        // The removal-failure signal belongs to the delete-all funnel, which clears the sink directly
        // and reports on it; the actor's job is only to wipe the in-memory working set.
        _ = sink?.clear()
    }
}
