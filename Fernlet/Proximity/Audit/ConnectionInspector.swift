import Foundation
import Observation
import SwiftUI
import FernletDomainModel

@MainActor
@Observable
final class ConnectionInspector: ProximityInspectorRecording {
    private(set) var liveLog: ConnectionSessionLog?
    private(set) var historicalLogs: [ConnectionSessionLog] = []

    @ObservationIgnored weak var store: FernletStore?
    @ObservationIgnored private var sampleSubsamplingCounter = 0
    @ObservationIgnored private let sampleSubsamplingStride = 3
    @ObservationIgnored private let now: () -> Date

    init(store: FernletStore? = nil, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.now = now
        self.historicalLogs = store?.connectionSessionLogs ?? []
    }

    func attachStore(_ store: FernletStore) {
        self.store = store
        historicalLogs = store.connectionSessionLogs
        purgeOld()
    }

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

    func recordEvent(_ kind: ConnectionSessionLog.Event.Kind, message: String) {
        guard var log = liveLog else { return }
        log.events.append(ConnectionSessionLog.Event(timestamp: now(), kind: kind, message: message))
        liveLog = log
        trimLiveLog()
    }

    func recordRangingSample(_ sample: ConnectionSessionLog.DistanceSample) {
        guard var log = liveLog else { return }
        sampleSubsamplingCounter += 1
        guard sampleSubsamplingCounter % sampleSubsamplingStride == 0 else { return }
        let meters = sample.meters
        log.ranging.samples.append(sample)
        log.ranging.samples = Array(log.ranging.samples.suffix(600))
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

    func endSession(endState: String) {
        guard var log = liveLog else { return }
        log.endedAt = now()
        log.endState = endState
        log.events.append(ConnectionSessionLog.Event(timestamp: now(), kind: .sessionEnded, message: endState))
        liveLog = nil
        guard store?.settings.connectionInspectorMode != .disabled else { return }
        historicalLogs.insert(log, at: 0)
        historicalLogs = Array(historicalLogs.sorted { $0.startedAt > $1.startedAt }.prefix(50))
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

    func exportAsJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(historicalLogs)
    }

    static func jsonDecoder() -> JSONDecoder {
        JSONDecoder()
    }

    func purgeOld() {
        let cutoff = now().addingTimeInterval(-60 * 24 * 60 * 60)
        let filtered = historicalLogs.filter { $0.startedAt >= cutoff }
        guard filtered != historicalLogs else { return }
        historicalLogs = filtered
        persistHistoricalLogs()
    }

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
        log.events = Array(log.events.suffix(250))
        log.envelopes = Array(log.envelopes.suffix(250))
        log.errors = Array(log.errors.suffix(100))
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
