import ProximityKit
import Foundation
import Observation
import SwiftUI
import FernletDomainModel

/// The proximity subsystem's diagnostic recorder: builds one `ConnectionSessionLog` per
/// coordinator session and keeps a capped, persisted history for the debug inspector UI.
///
/// The app-side conformer of ProximityKit's `ProximityInspectorRecording` seam — a
/// `ProximityCoordinator` holds it weakly and streams state transitions, envelope records,
/// ranging samples, transport updates, and errors into it. ``ConnectionInspectorView`` renders
/// the in-flight `liveLog`; ``ConnectionInspectorHistoryView`` (Settings debug tools) lists,
/// deletes, and JSON-exports `historicalLogs`.
///
/// Responsibilities and invariants:
/// - Recording is gated on `FernletSettings.connectionInspectorMode != .disabled`, checked at
///   both `beginSession` and `endSession`, so disabling mid-session also drops that session.
/// - The live log is self-bounding: events/envelopes/errors are trimmed to the last 250/250/100
///   after every append, and ranging samples are subsampled (1 in 3) and capped at 600, so a
///   long session can't grow without limit.
/// - History is capped at the 50 newest sessions and purged past 60 days (`purgeOld`); every
///   mutation persists through `FernletStore.replaceConnectionSessionLogs`, whose snapshot the
///   initializer / `attachStore` reload on launch.
/// - `@MainActor` + `@Observable`: all recording happens on the main actor (the coordinator is
///   main-actor too) and the log properties drive SwiftUI directly. The store reference is weak
///   to avoid a retain cycle (the store owns the inspector); the clock is injectable for tests.
@MainActor
@Observable
final class ConnectionInspector: ProximityInspectorRecording {
    // R3 (bounded growth): every peer-driven collection here has a NAMED cap, applied where the
    // input enters — the live log trims after each append, ranging samples are additionally
    // subsampled 1-in-3, and history is both count-capped and time-purged.

    /// Rolling cap on the live log's timestamped events.
    private static let maxLiveEvents = 250
    /// Rolling cap on the live log's envelope records.
    private static let maxLiveEnvelopes = 250
    /// Rolling cap on the live log's error records.
    private static let maxLiveErrors = 100
    /// Rolling cap on retained UWB distance samples for one session.
    private static let maxRangingSamples = 600
    /// How many finished sessions history keeps (newest first).
    private static let maxHistoricalSessions = 50
    /// How long a finished session survives in history before ``purgeOld()`` drops it.
    private static let historyRetention: TimeInterval = 60 * 24 * 60 * 60

    /// The log of the session currently being recorded; nil outside a session (or when disabled).
    private(set) var liveLog: ConnectionSessionLog?
    /// Finished session logs, newest first — capped at 50 and purged past 60 days.
    private(set) var historicalLogs: [ConnectionSessionLog] = []

    /// The host store — write-only from the outside via ``attachStore(_:)``, so nothing can swap it
    /// mid-session (R6: smallest scope that still lets the launch path late-bind it).
    @ObservationIgnored private(set) weak var store: FernletStore?
    @ObservationIgnored private var sampleSubsamplingCounter = 0
    @ObservationIgnored private let sampleSubsamplingStride = 3
    @ObservationIgnored private let now: () -> Date

    init(store: FernletStore? = nil, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.now = now
        self.historicalLogs = store?.connectionSessionLogs ?? []
    }

    /// Late-binds the store (the inspector is created before the store finishes loading),
    /// re-seeding history from the persisted snapshot and purging aged-out sessions.
    func attachStore(_ store: FernletStore) {
        self.store = store
        historicalLogs = store.connectionSessionLogs
        purgeOld()
    }

    /// Opens a fresh live log for a starting coordinator session; a no-op while the inspector
    /// mode is `.disabled`.
    func beginSession(role: ProximityCoordinator.Role, mode: ProximityCoordinator.Mode, localFingerprint: String) {
        guard store?.settings.connectionInspectorMode != .disabled else { return }
        sampleSubsamplingCounter = 0
        liveLog = ConnectionSessionLog(
            startedAt: now(),
            role: role,
            mode: mode,
            localFingerprint: localFingerprint,
            ranging: ConnectionSessionLog.RangingInfo(mode: .none)
        )
        recordEvent(.stateTransition, message: "session started")
    }

    /// Appends one timestamped event to the live log (trimming to the rolling caps after).
    func recordEvent(_ kind: ConnectionSessionLog.Event.Kind, message: String) {
        guard var log = liveLog else { return }
        log.events.append(ConnectionSessionLog.Event(timestamp: now(), kind: kind, message: message))
        liveLog = log
        trimLiveLog()
    }

    /// Records a UWB distance sample: subsampled 1-in-3, capped at 600, and folded into the
    /// running min/max so the detail view can show the session's range.
    func recordRangingSample(_ sample: ConnectionSessionLog.DistanceSample) {
        guard var log = liveLog else { return }
        sampleSubsamplingCounter += 1
        guard sampleSubsamplingCounter % sampleSubsamplingStride == 0 else { return }
        let meters = sample.meters
        log.ranging.samples.append(sample)
        log.ranging.samples = Array(log.ranging.samples.suffix(Self.maxRangingSamples))
        if let currentMin = log.ranging.minDistanceMeters {
            log.ranging.minDistanceMeters = min(currentMin, meters)
        } else {
            log.ranging.minDistanceMeters = meters
        }
        if let currentMax = log.ranging.maxDistanceMeters {
            log.ranging.maxDistanceMeters = max(currentMax, meters)
        } else {
            log.ranging.maxDistanceMeters = meters
        }
        liveLog = log
        recordEvent(.rangingUpdated, message: String(format: "distance %.2fm", meters))
    }

    /// Logs a sent/received signed envelope, accumulating the transport byte counters.
    func recordEnvelope(_ record: ConnectionSessionLog.EnvelopeRecord) {
        guard var log = liveLog else { return }
        log.envelopes.append(record)
        switch record.direction {
        case .sent:
            log.transport.bytesSent += record.payloadByteCount
            liveLog = log
            recordEvent(.envelopeSent, message: record.payloadType)
        case .received:
            log.transport.bytesReceived += record.payloadByteCount
            liveLog = log
            recordEvent(.envelopeReceived, message: record.payloadType)
        }
    }

    func recordError(domain: String, message: String, recoverable: Bool) {
        guard var log = liveLog else { return }
        log.errors.append(ConnectionSessionLog.ErrorRecord(timestamp: now(), domain: domain, message: message, recoverable: recoverable))
        liveLog = log
        recordEvent(.error, message: "\(domain): \(message)")
    }

    func updatePeer(_ peer: ConnectionSessionLog.PeerInfo) {
        guard var log = liveLog else { return }
        log.peer = peer
        liveLog = log
    }

    func updateTransport(_ block: (inout ConnectionSessionLog.TransportInfo) -> Void) {
        guard var log = liveLog else { return }
        block(&log.transport)
        liveLog = log
    }

    func updateRangingMode(_ mode: ProximityCoordinator.RangingMode) {
        guard var log = liveLog else { return }
        log.ranging.mode = mode
        liveLog = log
    }

    /// Seals the live log with its end state and promotes it into history (newest-first, capped
    /// at 50, persisted) — unless the inspector mode was disabled, in which case it is dropped.
    func endSession(endState: String) {
        guard var log = liveLog else { return }
        log.endedAt = now()
        log.endState = endState
        log.events.append(ConnectionSessionLog.Event(timestamp: now(), kind: .sessionEnded, message: endState))
        liveLog = nil
        guard store?.settings.connectionInspectorMode != .disabled else { return }
        historicalLogs.insert(log, at: 0)
        historicalLogs = Array(historicalLogs.sorted { $0.startedAt > $1.startedAt }.prefix(Self.maxHistoricalSessions))
        persistHistoricalLogs()
    }

    func deleteLogs(at offsets: IndexSet) {
        historicalLogs.remove(atOffsets: offsets)
        persistHistoricalLogs()
    }

    func deleteLog(id: UUID) {
        historicalLogs.removeAll { $0.id == id }
        persistHistoricalLogs()
    }

    /// Pretty-printed, stably-key-ordered JSON of the whole history, for the share-sheet export.
    /// - Returns: The encoded `[ConnectionSessionLog]` bytes.
    func exportAsJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(historicalLogs)
    }

    static func jsonDecoder() -> JSONDecoder {
        JSONDecoder()
    }

    /// Drops history older than 60 days; persists only when something was actually removed.
    func purgeOld() {
        let cutoff = now().addingTimeInterval(-Self.historyRetention)
        let filtered = historicalLogs.filter { $0.startedAt >= cutoff }
        guard filtered != historicalLogs else { return }
        historicalLogs = filtered
        persistHistoricalLogs()
    }

    /// Ingests a free-text coordinator status line: classifies it into an event kind by keyword,
    /// and mines the "connected" / "tap confirmed" messages for their transport/ranging timestamps.
    func recordCoordinatorEvent(_ message: String) {
        guard liveLog != nil else { return }
        let kind = kind(for: message)
        if message.contains("connected") {
            updateTransport { transport in
                transport.mcSessionState = "connected"
                if transport.connectedAt == nil { transport.connectedAt = now() }
            }
        }
        if message.contains("tap confirmed") {
            guard var log = liveLog else { return }
            log.ranging.tapConfirmedAt = now()
            liveLog = log
        }
        recordEvent(kind, message: message)
    }

    private func persistHistoricalLogs() {
        store?.replaceConnectionSessionLogs(historicalLogs)
    }

    private func trimLiveLog() {
        guard var log = liveLog else { return }
        log.events = Array(log.events.suffix(Self.maxLiveEvents))
        log.envelopes = Array(log.envelopes.suffix(Self.maxLiveEnvelopes))
        log.errors = Array(log.errors.suffix(Self.maxLiveErrors))
        liveLog = log
    }

    private func kind(for message: String) -> ConnectionSessionLog.Event.Kind {
        if message.contains("invite sent") { return .inviteSent }
        if message.contains("invite accepted") { return .inviteAccepted }
        if message.contains("invite rejected") { return .inviteRejected }
        if message.contains("tap confirmed") { return .tapConfirmed }
        if message.contains("identity introduction sent") { return .identityIntroductionSent }
        if message.contains("identity verified") { return .identityVerified }
        if message.contains("identity confirmed") { return .userConfirmed }
        if message.contains("heartbeat sent") { return .heartbeatSent }
        if message.contains("heartbeat received") { return .heartbeatReceived }
        if message.contains("envelope sent") { return .envelopeSent }
        if message.contains("envelope received") { return .envelopeReceived }
        if message.contains("failed") { return .error }
        if message.contains("ended") { return .sessionEnded }
        return .stateTransition
    }
}
