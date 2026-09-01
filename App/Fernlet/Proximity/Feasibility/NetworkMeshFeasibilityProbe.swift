// NetworkMeshFeasibilityProbe.swift
// Fernlet
//
// DEBUG-ONLY device spike for the background-mesh decision gate. This is intentionally not a
// transport adapter and does not participate in a user's mesh, retain content, or mutate stores.

#if DEBUG
import BackgroundTasks
import CryptoKit
import Dispatch
import FernletCrypto
import Foundation
import Network
import Observation
import ProximityKit
import Security
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Fixed test-only protocol constants. The all-zero mesh ID is never advertised by production
/// code, so a debug build cannot accidentally reconnect a real mesh during the feasibility spike.
enum MeshProbeConstants {
    static let protocolVersion = 1
    static let membershipEpoch = 1
    static let meshID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))
    static let nonceByteCount = 32
    static let signingKeyByteCount = 32
    static let signatureByteCount = 64
    static let channelBindingByteCount = 32
}

/// A signed identity hello carried on the prototype's reliable control stream.
struct MeshProbeHello: Codable, Equatable {
    let protocolVersion: Int
    let meshID: UUID
    let membershipEpoch: Int
    let signingPublicKey: Data
    let nonce: Data

    var isWellFormed: Bool {
        protocolVersion == MeshProbeConstants.protocolVersion
            && meshID == MeshProbeConstants.meshID
            && membershipEpoch == MeshProbeConstants.membershipEpoch
            && signingPublicKey.count == MeshProbeConstants.signingKeyByteCount
            && nonce.count == MeshProbeConstants.nonceByteCount
    }
}

/// The exact transcript each endpoint signs after deriving the QUIC TLS-exporter binding.
struct MeshProbeChannelIntroduction: Codable, Equatable {
    let protocolVersion: Int
    let meshID: UUID
    let membershipEpoch: Int
    let initiatorSigningPublicKey: Data
    let responderSigningPublicKey: Data
    let initiatorNonce: Data
    let responderNonce: Data
    let channelBindingHash: Data
    var signature: Data

    var isWellFormed: Bool {
        protocolVersion == MeshProbeConstants.protocolVersion
            && meshID == MeshProbeConstants.meshID
            && membershipEpoch == MeshProbeConstants.membershipEpoch
            && initiatorSigningPublicKey.count == MeshProbeConstants.signingKeyByteCount
            && responderSigningPublicKey.count == MeshProbeConstants.signingKeyByteCount
            && initiatorNonce.count == MeshProbeConstants.nonceByteCount
            && responderNonce.count == MeshProbeConstants.nonceByteCount
            && channelBindingHash.count == MeshProbeConstants.channelBindingByteCount
            && signature.count == MeshProbeConstants.signatureByteCount
            && initiatorSigningPublicKey != responderSigningPublicKey
    }

    /// Positional ASCII serialization: every variable field is Base64, so `|` is unambiguous.
    /// The purpose starts the bytes, which `IdentityService.sign` validates at its raw boundary.
    var canonicalSigningBytes: Data {
        let fields = [
            FernletCryptoPurpose.Signature.meshProbeChannelIntroductionV1.rawValue,
            String(protocolVersion), meshID.uuidString.lowercased(), String(membershipEpoch),
            initiatorSigningPublicKey.base64EncodedString(), responderSigningPublicKey.base64EncodedString(),
            initiatorNonce.base64EncodedString(), responderNonce.base64EncodedString(),
            channelBindingHash.base64EncodedString()
        ]
        return Data(fields.joined(separator: "|").utf8)
    }

    func verifies(using signingPublicKey: Data) -> Bool {
        guard isWellFormed else { return false }
        return IdentityService.verify(
            signature,
            of: canonicalSigningBytes,
            by: signingPublicKey,
            purpose: FernletCryptoPurpose.Signature.meshProbeChannelIntroductionV1
        )
    }

    func hasSameTranscript(as other: Self) -> Bool {
        canonicalSigningBytes == other.canonicalSigningBytes
    }
}

/// The probe's length framing. It is deliberately tiny and never reused as a production wire codec.
enum MeshProbeWire {
    static let headerByteCount = 4
    static let maxFrameByteCount = 16 * 1024

    /// - Returns: the wire bytes written, header included, so the caller can keep P8's
    ///   throughput counters without re-encoding the value.
    @discardableResult
    static func send<T: Encodable>(
        _ value: T,
        over stream: Network.QUIC.Stream<QUICStream>
    ) async throws -> Int {
        let payload = try JSONEncoder().encode(value)
        guard payload.count <= maxFrameByteCount else { throw MeshProbeError.oversizedFrame }
        try await stream.send(header(for: payload.count))
        try await stream.send(payload)
        return headerByteCount + payload.count
    }

    /// - Returns: the decoded value and the wire bytes read, header included — the receive-side
    ///   half of the counters described on ``send(_:over:)``.
    static func receive<T: Decodable>(
        _ type: T.Type,
        from stream: Network.QUIC.Stream<QUICStream>
    ) async throws -> (value: T, byteCount: Int) {
        let header = try await stream.receive(exactly: headerByteCount).content
        let length = try payloadLength(from: header)
        let payload = try await stream.receive(exactly: length).content
        return (try JSONDecoder().decode(type, from: payload), headerByteCount + length)
    }

    private static func header(for length: Int) -> Data {
        let value = UInt32(length)
        return Data([
            UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff), UInt8(value & 0xff)
        ])
    }

    private static func payloadLength(from header: Data) throws -> Int {
        let bytes = Array(header)
        guard bytes.count == headerByteCount else { throw MeshProbeError.invalidFrameLength }
        let value = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16)
            | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
        guard value > 0, value <= UInt32(maxFrameByteCount) else { throw MeshProbeError.invalidFrameLength }
        return Int(value)
    }
}

/// Derives a value that is equal only at the two ends of this active QUIC TLS connection.
enum MeshProbeTLSBinding {
    /// The exporter label is a reviewed registry constant, not a literal: it is cryptographic
    /// format data whose spelling must stay distinct from the production
    /// `KeyDerivation.meshTLSExporterV1` so a DEBUG spike and a shipping build can never derive
    /// the same binding secret from the same connection.
    private static let channelBindingPurpose = FernletCryptoPurpose.KeyDerivation.meshProbeTLSExporterV1.rawValue

    static func hash(for connection: NetworkConnection<QUIC>) -> Data? {
        let purpose = channelBindingPurpose
        let secret = purpose.withCString { label in
            sec_protocol_metadata_create_secret(
                connection.securityProtocolMetadata,
                purpose.utf8.count,
                label,
                MeshProbeConstants.channelBindingByteCount
            )
        }
        guard let secret else { return nil }
        let exporter = Data(secret as DispatchData)
        return Data(SHA256.hash(data: exporter))
    }
}

/// Bounded failure taxonomy for the DEBUG probe: framing, hello/introduction validation,
/// TLS binding/identity availability, and datagram outcomes. Each case renders as a
/// human-readable diagnostic in the probe's event ring rather than aborting the process.
enum MeshProbeError: LocalizedError {
    case invalidFrameLength
    case oversizedFrame
    case invalidHello
    case invalidIntroduction
    case missingTLSBinding
    case missingTLSIdentity
    case invalidDatagram
    case datagramUnavailable(Int)

    var errorDescription: String? {
        switch self {
        case .invalidFrameLength: return "The mesh probe received an invalid control-frame length."
        case .oversizedFrame: return "The mesh probe control frame exceeded its 16 KiB limit."
        case .invalidHello: return "The mesh probe rejected an invalid identity hello."
        case .invalidIntroduction: return "The mesh probe rejected the signed channel introduction."
        case .missingTLSBinding: return "The mesh probe could not derive a TLS exporter binding."
        case .missingTLSIdentity: return "The mesh probe could not load its DEBUG TLS identity."
        case .invalidDatagram: return "The mesh probe received an unexpected QUIC datagram."
        case .datagramUnavailable(let size):
            return "QUIC datagrams were not negotiated; usable frame size is \(size) bytes."
        }
    }
}

/// Fixed bytes make probe datagrams distinguishable without logging their payloads.
enum MeshProbeDatagram {
    static let ping = Data("fernlet-mesh-probe-ping".utf8)
    static let pong = Data("fernlet-mesh-probe-pong".utf8)
    static let heartbeat = Data("fernlet-mesh-probe-heartbeat".utf8)
    static let heartbeatAcknowledgement = Data("fernlet-mesh-probe-heartbeat-ack".utf8)

    static func label(for payload: Data) -> String {
        if payload == ping { return "ping" }
        if payload == pong { return "pong" }
        if payload == heartbeat { return "heartbeat" }
        if payload == heartbeatAcknowledgement { return "heartbeat acknowledgement" }
        return "an unrecognized \(payload.count)-byte datagram"
    }
}

/// Supplies the certificate QUIC requires from its server-side listener.
/// Its fixed DEBUG-only key is not a Fernlet identity or trust anchor: Fernlet's signed,
/// TLS-exporter-bound introduction remains the peer-authentication decision.
enum MeshProbeTLSIdentity {
    private static let certificateDER = "MIIBKjCB0AIJAPKdKQpVh0UUMAoGCCqGSM49BAMCMB0xGzAZBgNVBAMMEmZlcm5sZXQtbWVzaC1wcm9iZTAeFw0yNjA4MjcwMjIxMjRaFw0zNjA4MjQwMjIxMjRaMB0xGzAZBgNVBAMMEmZlcm5sZXQtbWVzaC1wcm9iZTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABDDKNk/vW0y3N8mTqOgtQPbTs79nja7Px6uro+zovqkXcvaDi70Gg6ime9jixuTBY1BErcGnGEniTAkTFa2ZVaQwCgYIKoZIzj0EAwIDSQAwRgIhAI+tW7hoitTnAL2WTSH6qXrE3qbjA/XGcQmfHMIpGSZYAiEAhPTFmMBB6sr2SdGQjJmjRpdd4bJRcQxtpvwe4KvVDgM="
    private static let privateKeyX963 = "BDDKNk/vW0y3N8mTqOgtQPbTs79nja7Px6uro+zovqkXcvaDi70Gg6ime9jixuTBY1BErcGnGEniTAkTFa2ZVaQwy8uB5oP8h0VBaygd46AolGHW16n9Zpzn9QAfTPr+Og=="

    static func load() throws -> sec_identity_t {
        guard let certificateData = Data(base64Encoded: certificateDER),
              let privateKeyData = Data(base64Encoded: privateKeyX963),
              let certificate = SecCertificateCreateWithData(nil, certificateData as CFData) else {
            throw MeshProbeError.missingTLSIdentity
        }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 256
        ]
        guard let privateKey = SecKeyCreateWithData(
            privateKeyData as CFData,
            attributes as CFDictionary,
            nil
        ), let identity = SecIdentityCreate(nil, certificate, privateKey),
            let protocolIdentity = sec_identity_create(identity) else {
            throw MeshProbeError.missingTLSIdentity
        }
        return protocolIdentity
    }
}

/// Selects the transport path that is meaningful for the process hosting the DEBUG probe.
/// Simulator runs exercise infrastructure networking only; the physical-device gate retains
/// Apple peer-to-peer Wi-Fi because that radio path cannot be simulated.
enum MeshProbeNetworkProfile {
    static let txtRecordKey = "mesh-probe-host"
    static let simulatorTXTValue = "simulator"
    static let deviceTXTValue = "device"

    static var runsInSimulator: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["SIMULATOR_UDID"] != nil
            || environment["SIMULATOR_DEVICE_NAME"] != nil
    }

    static func displayName(peerToPeerIncluded: Bool) -> String {
        guard !runsInSimulator else { return "Simulator infrastructure" }
        return peerToPeerIncluded
            ? "Physical-device peer-to-peer"
            : "Physical-device infrastructure"
    }

    static var txtRecord: NWTXTRecord {
        let value = runsInSimulator ? simulatorTXTValue : deviceTXTValue
        return NWTXTRecord([txtRecordKey: value])
    }
}

/// DEBUG launch switches for the feasibility probe, read once per process from the environment so
/// `xcrun simctl launch` can drive a whole run without touching the probe's UI.
///
/// Every switch is off when its variable is absent, and off means *exactly* today's behaviour: the
/// simulator→simulator dial stays refused, nothing starts by itself, and the event ring is not
/// echoed anywhere. The variable names are frozen automation tokens, never display strings.
enum MeshProbeDebugOptions {
    static let allowSimulatorDialKey = "FERNLET_PROBE_ALLOW_SIM_DIAL"
    static let autostartKey = "FERNLET_PROBE_AUTOSTART"
    static let consoleLogKey = "FERNLET_PROBE_CONSOLE_LOG"

    /// Permits one Simulator to dial another. It widens the simulator→simulator case only: a
    /// physical device still refuses a Simulator candidate, because *that* refusal is the one the
    /// Simulator's host-only link-local address actually justifies.
    static let allowsSimulatorToSimulatorDial = isEnabled(allowSimulatorDialKey)
    /// Starts the probe from `FernletApp.init()` instead of the Settings screen's Start button.
    static let startsAutomatically = isEnabled(autostartKey)
    /// Mirrors every event-ring entry to stdout, where `simctl launch --console-pty` can read it.
    static let echoesEventsToConsole = isEnabled(consoleLogKey)

    /// Frozen diagnostic token naming the dial policy in force, for the copied report.
    static var simulatorDialDescription: String {
        allowsSimulatorToSimulatorDial
            ? "allowed (\(allowSimulatorDialKey)=1)"
            : "refused (default)"
    }

    private static func isEnabled(_ key: String) -> Bool {
        ProcessInfo.processInfo.environment[key] == "1"
    }
}

/// Keeps automatic DEBUG probing deterministic while avoiding self and failed Bonjour results.
enum MeshProbeDiscoveryPolicy {
    static func allowsOutboundConnection(
        localServiceName: String,
        candidateServiceName: String,
        candidateID: String,
        attemptedEndpointIDs: Set<String>,
        localRunsInSimulator: Bool,
        candidateRunsInSimulator: Bool,
        allowsSimulatorToSimulatorDial: Bool = false
    ) -> Bool {
        guard !localServiceName.isEmpty, !candidateServiceName.isEmpty,
              !candidateID.isEmpty else { return false }
        guard localServiceName != candidateServiceName,
              !attemptedEndpointIDs.contains(candidateID) else { return false }
        if localRunsInSimulator {
            guard candidateRunsInSimulator else { return true }
            // Same total order as the device↔device branch, so exactly one Simulator of a pair
            // dials: two mutual dials would open two tunnels for one peer pair.
            return allowsSimulatorToSimulatorDial && localServiceName < candidateServiceName
        }
        if candidateRunsInSimulator { return false }
        return localServiceName < candidateServiceName
    }

    static func candidateRunsInSimulator(_ endpoint: Bonjour.Endpoint) -> Bool {
        endpoint.txtRecord.dictionary[MeshProbeNetworkProfile.txtRecordKey]
            == MeshProbeNetworkProfile.simulatorTXTValue
    }
}

/// Debug-only owner for the physical-device Network.framework decision gate.
///
/// The class maintains at most two tunnels, writes no user content, and is never instantiated in a
/// release build. It intentionally accepts an untrusted peer *only* to prove the signed
/// TLS-exporter binding; it is not an admission, routing, or production transport implementation.
@MainActor
@Observable
final class NetworkMeshFeasibilityProbe {
    static let shared = NetworkMeshFeasibilityProbe()
    static let backgroundTaskIdentifierPattern = "MBO.Fernlet.mesh-continuation.*"
    static let backgroundTaskIdentifier = "MBO.Fernlet.mesh-continuation.feasibility"
    static let backgroundTaskRegistrationIdentifier = backgroundTaskIdentifier
    static let bonjourServiceType = "_fernlet-mesh2._udp"

    private static let alpn = "fernlet-mesh-probe-v1"
    /// Frozen console tag so a `simctl launch --console-pty` transcript can be grepped down to the
    /// probe's own lines. Never shown in the UI.
    private static let consoleLogPrefix = "[mesh-probe]"
    /// Four, not two: the runbook's four-device step (step 6 — topology changes and
    /// simultaneous starts) is impossible at a cap of two. DEBUG-only, like the rest of the file.
    private static let maxConnections = 4
    private static let maxBrowserEndpoints = 16
    private static let maxEventCount = 80
    private static let maxHeartbeatCount = 720
    private static let maxInitialDatagramAttempts = 3
    private static let maxUnexpectedDatagrams = 3
    private static let maxOutboundTunnelAttempts = 3
    private static let configuredDatagramFrameSize = 1_024
    private static let configuredUDPPayloadSize = 1_280
    private static let heartbeatInterval: Duration = .seconds(30)
    private static let outboundRetryDelay: Duration = .seconds(2)
    private static let progressTotal: Int64 = 100

    private let identity = IdentityService()
    private let serviceName = "fernlet-probe-\(UUID().uuidString.lowercased())"
    private var listener: NetworkListener<QUIC>?
    private var browser: NetworkBrowser<Bonjour>?
    private var listenerTask: Task<Void, Never>?
    private var browserTask: Task<Void, Never>?
    private var inboundTunnelTask: Task<Void, Never>?
    private var outboundTunnelTask: Task<Void, Never>?
    private var outboundRetryTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var activeConnectionIDs = Set<String>()
    private var recentBrowserEndpoints: [Bonjour.Endpoint] = []
    private var attemptedOutboundEndpointIDs = Set<String>()
    private var outboundAttemptCounts: [String: Int] = [:]
    private var outboundEndpoint: Bonjour.Endpoint?
    private var listenerIsReady = false
    private var listenerIsAdvertised = false
    private var browserHasStarted = false
    private var backgroundTask: BGContinuedProcessingTask?
    private var completedBackgroundTask = false
    private var backgroundTaskRegistrationAttempted = false
    private var backgroundTaskHandlerRegistered = false
    private var lastUsableDatagramFrameSize: Int?
    private var lastLiveQUICOptionSummary = "not observed"
    private var lastShutdownReason: String?
    /// Last power reading actually written to the event ring. The ring holds 80 entries and a
    /// six-hour soak fires 720 heartbeats, so power is recorded on CHANGE only — a soak whose
    /// thermal state never moves costs one line, and one that throttles shows exactly when.
    private var lastRecordedThermalState: ProcessInfo.ThermalState?
    private var lastRecordedLowPowerMode: Bool?

    private(set) var isRunning = false
    private(set) var usesInfrastructureCompatibility = false
    private(set) var backgroundContinuationAvailable = false
    private(set) var controlStreamVerified = false
    private(set) var datagramVerified = false
    private(set) var heartbeatCount = 0
    private(set) var lastAuthenticatedHeartbeat: Date?
    private(set) var status = "Not running"
    private(set) var events: [String] = []
    private(set) var discoveredEndpoints: [String] = []

    // P8 gate counters (plan §15). Kept as fields rather than ring entries: a counter that is
    // evicted at 80 events measures nothing over a six-hour soak. The ring records the
    // TRANSITIONS; these fields carry the totals into `diagnosticReport`.
    /// Wire bytes written across control frames and datagrams, headers included.
    private(set) var bytesSent = 0
    /// Wire bytes read across control frames and datagrams, headers included.
    private(set) var bytesReceived = 0
    /// QUIC connections that reached `.ready`, counting every peer and every re-dial.
    private(set) var connectCount = 0
    /// Re-dials scheduled after a tunnel ended — the reconnection half of §15.1's radio matrix.
    private(set) var reconnectCount = 0
    private(set) var firstConnectedAt: Date?
    private(set) var lastConnectedAt: Date?
    private(set) var lastReconnectAt: Date?

    var diagnosticReport: String {
        let taskState = backgroundTask == nil
            ? (backgroundContinuationAvailable ? "requested; handler not delivered" : "not active")
            : "active"
        let usableSize = lastUsableDatagramFrameSize.map { String($0) } ?? "not observed"
        let shutdown = lastShutdownReason ?? "none"
        let candidateText = discoveredEndpoints.isEmpty ? "none" : discoveredEndpoints.joined(separator: "\n")
        let eventText = events.isEmpty ? "none" : events.joined(separator: "\n")
        return """
        Fernlet mesh feasibility diagnostic (DEBUG only)
        generated: \(Date.now.formatted(date: .numeric, time: .standard))
        transport: \(transportDisplayName)
        simulator-to-simulator dial: \(MeshProbeDebugOptions.simulatorDialDescription)
        status: \(status)
        running: \(isRunning)
        background task: \(taskState)
        signed control stream: \(controlStreamVerified)
        QUIC datagram verified: \(datagramVerified)
        advertised QUIC DATAGRAM frame size: \(Self.configuredDatagramFrameSize)
        advertised QUIC UDP payload size: \(Self.configuredUDPPayloadSize)
        live QUIC options: \(lastLiveQUICOptionSummary)
        usable datagram frame size: \(usableSize)
        authenticated heartbeats: \(heartbeatCount)
        bytes sent: \(bytesSent)
        bytes received: \(bytesReceived)
        connects: \(connectCount) (first \(Self.timestamp(firstConnectedAt)), last \(Self.timestamp(lastConnectedAt)))
        reconnects: \(reconnectCount) (last \(Self.timestamp(lastReconnectAt)))
        thermal state: \(Self.thermalStateName(ProcessInfo.processInfo.thermalState))
        low power mode: \(ProcessInfo.processInfo.isLowPowerModeEnabled)
        shutdown reason: \(shutdown)
        candidates:
        \(candidateText)
        events:
        \(eventText)
        """
    }

    func copyDiagnosticReport() {
        record("Copied mesh feasibility diagnostic report to the pasteboard.")
        // `localOnly`, not a bare `.string =` assignment (PB1): the general pasteboard is
        // Handoff-synced to every device on the same Apple Account, and this report names the
        // device's peer candidates, endpoints and signing-key state. A debug build is exactly where
        // that leaves the device — the report is pasted into a bug note on some other machine.
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: diagnosticReport]],
                                      options: [.localOnly: true])
    }

    var datagramFrameSizeDescription: String {
        guard let lastUsableDatagramFrameSize else { return "Not observed" }
        return "\(lastUsableDatagramFrameSize) bytes"
    }

    private var includesPeerToPeer: Bool {
        !MeshProbeNetworkProfile.runsInSimulator && !usesInfrastructureCompatibility
    }

    var transportDisplayName: String {
        MeshProbeNetworkProfile.displayName(peerToPeerIncluded: includesPeerToPeer)
    }

    var pathPolicyDescription: String {
        includesPeerToPeer ? "Peer-to-peer included" : "Infrastructure only"
    }

    var canUseInfrastructureCompatibility: Bool {
        !MeshProbeNetworkProfile.runsInSimulator
    }

    func toggleInfrastructureCompatibility() {
        guard canUseInfrastructureCompatibility, !isRunning else { return }
        usesInfrastructureCompatibility.toggle()
        record("Physical-device path policy changed to \(pathPolicyDescription.lowercased()).")
    }

    /// Registration is called exactly once from `FernletApp.init()`. Continued-task registrations
    /// are exempt from the normal launch-time deadline, but early registration makes this test
    /// match the planned production lifecycle.
    static func registerBackgroundTask() {
        guard !shared.backgroundTaskRegistrationAttempted else { return }
        shared.backgroundTaskRegistrationAttempted = true
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: backgroundTaskIdentifier)
        shared.record("Launch cleanup cancelled any prior mesh feasibility continuation request.")
        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: backgroundTaskRegistrationIdentifier,
            using: nil
        ) { task in
            guard let continuedTask = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                Self.shared.handleBackgroundTask(continuedTask)
            }
        }
        shared.backgroundTaskHandlerRegistered = registered
        if !registered {
            shared.record("Background task registration was rejected; check the debug app Info.plist.")
        }
        startFromLaunchEnvironmentIfRequested()
    }

    /// Starts a run from the launch environment so an automated two-Simulator experiment needs no
    /// UI navigation. Absent `FERNLET_PROBE_AUTOSTART=1` this does nothing at all, which is what
    /// every ordinary DEBUG launch sees. The start is deferred one main-actor turn: `init()` has
    /// not returned yet, and the listener plus its BackgroundTasks submission want a live app.
    private static func startFromLaunchEnvironmentIfRequested() {
        guard MeshProbeDebugOptions.startsAutomatically else { return }
        shared.record("Autostart requested by \(MeshProbeDebugOptions.autostartKey); simulator→simulator dial is \(MeshProbeDebugOptions.simulatorDialDescription).")
        Task { @MainActor in shared.start() }
    }

    func start() {
        guard !isRunning else {
            record("The mesh feasibility probe is already running.")
            return
        }
        resetResults()
        do {
            record("Start requested; host=\(transportDisplayName), peer-to-peer=\(includesPeerToPeer), DATAGRAM=\(Self.configuredDatagramFrameSize), UDP=\(Self.configuredUDPPayloadSize).")
            try identity.ensureProvisioned()
            record("Local Fernlet signing identity is provisioned.")
            isRunning = true
            try startListener()
            submitBackgroundTask()
            status = "Starting listener"
            record("Starting \(transportDisplayName) probe on \(Self.bonjourServiceType).")
        } catch {
            fail(error, context: "The mesh feasibility probe could not start")
        }
    }

    func stop() {
        guard isRunning || backgroundTask != nil || backgroundContinuationAvailable else { return }
        endProbe(status: "Stopped", reason: "Stopped by the tester.")
    }

    private static func connectionParameters(
        includePeerToPeer: Bool
    ) -> NWParametersBuilder<QUIC> {
        let parameters = NWParametersBuilder<QUIC>.parameters {
            QUIC(alpn: [alpn])
                .tls.certificateValidator { _, _ in true }
                .tls.peerAuthentication(.none)
                .maxUDPPayloadSize(configuredUDPPayloadSize)
                .maxDatagramFrameSize(configuredDatagramFrameSize)
        }
        guard includePeerToPeer else { return parameters }
        return parameters.peerToPeerIncluded(true)
    }

    private static func listenerParameters(
        includePeerToPeer: Bool
    ) throws -> NWParametersBuilder<QUIC> {
        let identity = try MeshProbeTLSIdentity.load()
        let parameters = NWParametersBuilder<QUIC>.parameters {
            QUIC(alpn: [alpn])
                .tls.localIdentity(identity)
                .tls.certificateValidator { _, _ in true }
                .tls.peerAuthentication(.none)
                .maxUDPPayloadSize(configuredUDPPayloadSize)
                .maxDatagramFrameSize(configuredDatagramFrameSize)
        }
        guard includePeerToPeer else { return parameters }
        return parameters.peerToPeerIncluded(true)
    }

    private static func quicOptionSummary(from parameters: NWParameters) -> String {
        let stack = parameters.defaultProtocolStack
        let candidate = stack.transportProtocol ?? stack.applicationProtocols.first
        guard let options = candidate as? NWProtocolQUIC.Options else {
            return "unavailable"
        }
        return "DATAGRAM=\(options.maxDatagramFrameSize), UDP=\(options.maxUDPPayloadSize), datagram-flow=\(options.isDatagram)"
    }

    private func startListener() throws {
        let listener = try NetworkListener(
            for: .bonjour(
                name: serviceName,
                type: Self.bonjourServiceType,
                txtRecord: MeshProbeNetworkProfile.txtRecord
            ),
            using: try Self.listenerParameters(includePeerToPeer: includesPeerToPeer)
        ).newConnectionLimit(Self.maxConnections)
        self.listener = listener
        listener.onStateUpdate { [weak self] _, state in
            Task { @MainActor in self?.listenerStateChanged(state) }
        }
        listener.onServiceRegistrationUpdate { [weak self] _, change in
            Task { @MainActor in self?.listenerRegistrationChanged(change) }
        }
        listenerTask = Task { @MainActor [weak self, listener] in
            do {
                try await listener.run { connection in
                    self?.acceptIncoming(connection)
                }
            } catch {
                self?.listenerStopped(error)
            }
        }
    }

    private func startBrowser() {
        guard !browserHasStarted else { return }
        browserHasStarted = true
        let browser = NetworkBrowser(
            for: .bonjour(Self.bonjourServiceType, includeTxtRecord: true),
            using: Self.connectionParameters(includePeerToPeer: includesPeerToPeer).parameters
        )
        self.browser = browser
        browser.onStateUpdate { [weak self] _, state in
            Task { @MainActor in self?.browserStateChanged(state) }
        }
        browserTask = Task { @MainActor [weak self, browser] in
            do {
                try await browser.run { endpoints in
                    self?.observe(endpoints)
                }
            } catch {
                self?.browserStopped(error)
            }
        }
    }

    private func listenerStateChanged(_ state: NetworkListener<QUIC>.State) {
        guard isRunning else { return }
        switch state {
        case .ready:
            listenerIsReady = true
            record("QUIC listener is ready.")
            startBrowserWhenReady()
        case .waiting(let error):
            record("QUIC listener is waiting: \(error.localizedDescription)")
        case .failed(let error):
            fail(error, context: "The QUIC listener failed")
        case .setup, .cancelled:
            break
        @unknown default:
            break
        }
    }

    private func listenerRegistrationChanged(
        _ change: NetworkListener<QUIC>.ServiceRegistrationChange
    ) {
        guard isRunning else { return }
        switch change {
        case .add(let endpoint):
            listenerIsAdvertised = true
            record("Bonjour listener advertised \(endpoint.debugDescription).")
            startBrowserWhenReady()
        case .remove(let endpoint):
            listenerIsAdvertised = false
            record("Bonjour listener removed \(endpoint.debugDescription).")
        @unknown default:
            break
        }
    }

    private func startBrowserWhenReady() {
        guard listenerIsReady, listenerIsAdvertised, !browserHasStarted else { return }
        status = "Searching for another debug device"
        record("Listening and browsing on \(Self.bonjourServiceType).")
        startBrowser()
    }

    private func browserStateChanged(_ state: NetworkBrowser<Bonjour>.State) {
        guard isRunning else { return }
        switch state {
        case .ready:
            record("Bonjour browser is ready.")
        case .waiting(let error):
            record("Bonjour browser is waiting: \(error.localizedDescription)")
        case .failed(let error):
            fail(error, context: "The Bonjour browser failed")
        case .setup, .cancelled:
            break
        @unknown default:
            break
        }
    }

    private func submitBackgroundTask() {
        guard backgroundTaskHandlerRegistered else {
            backgroundContinuationAvailable = false
            record("Background continuation is unavailable because its launch handler did not register.")
            return
        }
        let request = BGContinuedProcessingTaskRequest(
            identifier: Self.backgroundTaskIdentifier,
            title: "Fernlet mesh",
            subtitle: "Waiting for friends"
        )
        request.strategy = .fail
        do {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundTaskIdentifier)
            record("Cleared any prior continuation request before submitting a new one.")
            try BGTaskScheduler.shared.submit(request)
            backgroundContinuationAvailable = true
            record("Requested continued processing with the fail-immediately strategy.")
        } catch {
            backgroundContinuationAvailable = false
            record("Background continuation is unavailable: \(error.localizedDescription)")
        }
    }

    private func handleBackgroundTask(_ task: BGContinuedProcessingTask) {
        guard backgroundTask == nil, isRunning else {
            record("Rejected continued-processing task delivery; mesh running=\(isRunning), existing task=\(backgroundTask != nil).")
            task.setTaskCompleted(success: false)
            return
        }
        completedBackgroundTask = false
        backgroundTask = task
        task.progress.totalUnitCount = Self.progressTotal
        task.progress.completedUnitCount = 5
        task.expirationHandler = { [weak self] in
            Task { @MainActor in self?.expireBackgroundTask() }
        }
        task.updateTitle("Fernlet mesh", subtitle: "Waiting for friends")
        record("The continued-processing task started; the system activity is now task-owned.")
    }

    private func expireBackgroundTask() {
        guard backgroundTask != nil else { return }
        endProbe(status: "Background task ended", reason: "iOS expired or cancelled the continued-processing task.")
    }

    private func observe(_ endpoints: [Bonjour.Endpoint]) {
        guard isRunning, outboundTunnelTask == nil, outboundRetryTask == nil else { return }
        let boundedEndpoints = Array(endpoints.prefix(Self.maxBrowserEndpoints))
        recentBrowserEndpoints = boundedEndpoints
        let candidateIDs = Set(boundedEndpoints.map(\.id))
        attemptedOutboundEndpointIDs.formIntersection(candidateIDs)
        outboundAttemptCounts = outboundAttemptCounts.filter { candidateIDs.contains($0.key) }
        refreshDiscoveredEndpoints(boundedEndpoints)
        guard let endpoint = selectOutboundEndpoint(from: boundedEndpoints) else { return }
        status = "Connecting to a debug device"
        startOutboundTunnel(to: endpoint)
    }

    private func startOutboundTunnel(to endpoint: Bonjour.Endpoint) {
        guard isRunning, outboundTunnelTask == nil else { return }
        outboundEndpoint = endpoint
        let attempt = (outboundAttemptCounts[endpoint.id] ?? 0) + 1
        record("Opening QUIC tunnel attempt \(attempt) to \(Self.endpointSummary(endpoint)).")
        outboundTunnelTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let connection = NetworkConnection(
                to: endpoint,
                using: Self.connectionParameters(includePeerToPeer: includesPeerToPeer)
            ).start()
            let connectionID = connection.id
            guard self.reserveConnection(connectionID) else {
                self.outboundTunnelTask = nil
                return
            }
            self.observeConnection(connection, endpoint: endpoint)
            do {
                try await self.runInitiator(connection)
            } catch {
                self.outboundTunnelStopped(error, endpoint: endpoint, connectionID: connectionID)
            }
        }
    }

    private func selectOutboundEndpoint(from endpoints: [Bonjour.Endpoint]) -> Bonjour.Endpoint? {
        let candidates = endpoints.sorted(by: { $0.id < $1.id })
        return candidates.first {
            MeshProbeDiscoveryPolicy.allowsOutboundConnection(
                localServiceName: serviceName,
                candidateServiceName: $0.name,
                candidateID: $0.id,
                attemptedEndpointIDs: attemptedOutboundEndpointIDs,
                localRunsInSimulator: MeshProbeNetworkProfile.runsInSimulator,
                candidateRunsInSimulator: MeshProbeDiscoveryPolicy.candidateRunsInSimulator($0),
                allowsSimulatorToSimulatorDial: MeshProbeDebugOptions.allowsSimulatorToSimulatorDial
            )
        }
    }

    private func refreshDiscoveredEndpoints(_ endpoints: [Bonjour.Endpoint]) {
        let summaries = endpoints.map(Self.endpointSummary)
        guard summaries != discoveredEndpoints else { return }
        discoveredEndpoints = summaries
        record("Bonjour discovery has \(summaries.count) candidate(s).")
    }

    private static func endpointSummary(_ endpoint: Bonjour.Endpoint) -> String {
        let origin = MeshProbeDiscoveryPolicy.candidateRunsInSimulator(endpoint)
            ? "Simulator"
            : "device"
        return "\(endpoint.name).\(endpoint.type)\(endpoint.domain) [\(origin)]"
    }

    private func acceptIncoming(_ connection: NetworkConnection<QUIC>) {
        guard isRunning, inboundTunnelTask == nil else { return }
        let connectionID = connection.id
        guard reserveConnection(connectionID) else {
            record("Ignored an additional inbound tunnel after the \(Self.maxConnections)-connection cap.")
            return
        }
        record("Accepted inbound QUIC tunnel id=\(connectionID).")
        observeConnection(connection, endpoint: nil)
        inboundTunnelTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.runResponder(connection)
            } catch {
                self.inboundTunnelStopped(error, connectionID: connectionID)
            }
        }
    }

    private func observeConnection(
        _ connection: NetworkConnection<QUIC>,
        endpoint: Bonjour.Endpoint?
    ) {
        connection.onStateUpdate { [weak self] observedConnection, state in
            Task { @MainActor in
                self?.connectionStateChanged(observedConnection, endpoint: endpoint, state: state)
            }
        }
    }

    private func connectionStateChanged(
        _ connection: NetworkConnection<QUIC>,
        endpoint: Bonjour.Endpoint?,
        state: NetworkChannel<QUIC>.State
    ) {
        guard isRunning else { return }
        let peer = endpoint.map(Self.endpointSummary) ?? "an inbound peer"
        switch state {
        case .ready:
            let remote = connection.remoteEndpoint?.debugDescription ?? "unknown endpoint"
            let usableSize = connection.usableDatagramFrameSize
            lastUsableDatagramFrameSize = usableSize
            lastLiveQUICOptionSummary = Self.quicOptionSummary(from: connection.parameters)
            connectCount += 1
            let now = Date()
            if firstConnectedAt == nil { firstConnectedAt = now }
            lastConnectedAt = now
            record("QUIC ready with \(peer) at \(remote); \(lastLiveQUICOptionSummary), usable datagram frame size=\(usableSize) bytes.")
            recordPowerStateIfChanged()
        case .waiting(let error):
            record("QUIC waiting for \(peer): \(error.localizedDescription)")
        case .failed(let error):
            record("QUIC failed for \(peer): \(error.localizedDescription)")
        case .setup, .preparing, .cancelled:
            break
        @unknown default:
            break
        }
    }

    private func outboundTunnelStopped(
        _ error: Error,
        endpoint: Bonjour.Endpoint,
        connectionID: String
    ) {
        guard !Task.isCancelled, isRunning else { return }
        activeConnectionIDs.remove(connectionID)
        outboundTunnelTask = nil
        outboundEndpoint = nil
        if let usableSize = unavailableDatagramSize(from: error) {
            attemptedOutboundEndpointIDs.insert(endpoint.id)
            endProbe(
                status: "Datagrams unavailable",
                reason: "QUIC datagrams were not negotiated; usable frame size is \(usableSize) bytes."
            )
            return
        }
        let attempts = min(
            (outboundAttemptCounts[endpoint.id] ?? 0) + 1,
            Self.maxOutboundTunnelAttempts
        )
        outboundAttemptCounts[endpoint.id] = attempts
        guard attempts < Self.maxOutboundTunnelAttempts else {
            attemptedOutboundEndpointIDs.insert(endpoint.id)
            endProbe(
                status: "Probe failed",
                reason: "Outbound QUIC tunnel ended after \(attempts) attempts: \(error.localizedDescription)"
            )
            return
        }
        status = "Retrying QUIC tunnel"
        reconnectCount += 1
        lastReconnectAt = Date()
        record("Outbound QUIC tunnel ended; retry \(attempts + 1) of \(Self.maxOutboundTunnelAttempts): \(error.localizedDescription)")
        recordPowerStateIfChanged()
        scheduleOutboundRetry(to: endpoint)
    }

    private func scheduleOutboundRetry(to endpoint: Bonjour.Endpoint) {
        guard outboundRetryTask == nil else { return }
        outboundRetryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.outboundRetryDelay)
            } catch {
                return
            }
            guard let self, self.isRunning, self.outboundTunnelTask == nil else { return }
            self.outboundRetryTask = nil
            self.status = "Retrying QUIC tunnel"
            self.startOutboundTunnel(to: endpoint)
        }
    }

    private func inboundTunnelStopped(_ error: Error, connectionID: String) {
        guard !Task.isCancelled, isRunning else { return }
        activeConnectionIDs.remove(connectionID)
        inboundTunnelTask = nil
        tunnelStopped(error, context: "Inbound QUIC tunnel ended")
    }

    private func runInitiator(_ connection: NetworkConnection<QUIC>) async throws {
        let stream = try await connection.openStream()
        record("Control initiator opened stream id=\(stream.streamID).")
        let localHello = try makeLocalHello()
        try await sendFrame(localHello, over: stream)
        record("Control initiator sent identity hello.")
        let remoteHello = try await receiveFrame(MeshProbeHello.self, from: stream)
        guard remoteHello.isWellFormed else { throw MeshProbeError.invalidHello }
        record("Control initiator accepted remote identity hello.")
        let binding = try channelBinding(for: connection)
        let localIntroduction = try signedIntroduction(
            initiator: localHello,
            responder: remoteHello,
            channelBindingHash: binding
        )
        try await sendFrame(localIntroduction, over: stream)
        record("Control initiator sent signed channel introduction.")
        let remoteIntroduction = try await receiveFrame(MeshProbeChannelIntroduction.self, from: stream)
        guard introduction(remoteIntroduction, matches: localIntroduction, signer: remoteHello.signingPublicKey) else {
            throw MeshProbeError.invalidIntroduction
        }
        record("Control initiator accepted remote signed channel introduction.")
        markControlStreamVerified()
        let datagrams = try await connection.datagrams
        try requireDatagramCapacity(for: datagrams)
        try await sendInitialDatagram(over: datagrams)
        startHeartbeatLoop(over: datagrams)
    }

    private func runResponder(_ connection: NetworkConnection<QUIC>) async throws {
        try await connection.inboundStreams { stream in
            try await self.respond(to: stream, on: connection)
        }
    }

    private func respond(
        to stream: Network.QUIC.Stream<QUICStream>,
        on connection: NetworkConnection<QUIC>
    ) async throws {
        let initiatorHello = try await receiveFrame(MeshProbeHello.self, from: stream)
        guard initiatorHello.isWellFormed else { throw MeshProbeError.invalidHello }
        record("Control responder accepted identity hello on stream id=\(stream.streamID).")
        let localHello = try makeLocalHello()
        try await sendFrame(localHello, over: stream)
        record("Control responder sent identity hello.")
        let remoteIntroduction = try await receiveFrame(MeshProbeChannelIntroduction.self, from: stream)
        let binding = try channelBinding(for: connection)
        let localIntroduction = try signedIntroduction(
            initiator: initiatorHello,
            responder: localHello,
            channelBindingHash: binding
        )
        guard introduction(remoteIntroduction, matches: localIntroduction, signer: initiatorHello.signingPublicKey) else {
            throw MeshProbeError.invalidIntroduction
        }
        record("Control responder accepted signed channel introduction.")
        try await sendFrame(localIntroduction, over: stream)
        record("Control responder sent signed channel introduction.")
        markControlStreamVerified()
        let datagrams = try await connection.datagrams
        try requireDatagramCapacity(for: datagrams)
        try await answerDatagrams(over: datagrams)
    }

    private func makeLocalHello() throws -> MeshProbeHello {
        let signingPublicKey = identity.localSigningPublicKey
        guard signingPublicKey.count == MeshProbeConstants.signingKeyByteCount else {
            throw MeshProbeError.invalidHello
        }
        return MeshProbeHello(
            protocolVersion: MeshProbeConstants.protocolVersion,
            meshID: MeshProbeConstants.meshID,
            membershipEpoch: MeshProbeConstants.membershipEpoch,
            signingPublicKey: signingPublicKey,
            nonce: Curve25519.KeyAgreement.PrivateKey().rawRepresentation
        )
    }

    private func signedIntroduction(
        initiator: MeshProbeHello,
        responder: MeshProbeHello,
        channelBindingHash: Data
    ) throws -> MeshProbeChannelIntroduction {
        guard initiator.isWellFormed, responder.isWellFormed,
              channelBindingHash.count == MeshProbeConstants.channelBindingByteCount else {
            throw MeshProbeError.invalidIntroduction
        }
        var introduction = MeshProbeChannelIntroduction(
            protocolVersion: MeshProbeConstants.protocolVersion,
            meshID: MeshProbeConstants.meshID,
            membershipEpoch: MeshProbeConstants.membershipEpoch,
            initiatorSigningPublicKey: initiator.signingPublicKey,
            responderSigningPublicKey: responder.signingPublicKey,
            initiatorNonce: initiator.nonce,
            responderNonce: responder.nonce,
            channelBindingHash: channelBindingHash,
            signature: Data()
        )
        introduction.signature = try identity.sign(
            introduction.canonicalSigningBytes,
            purpose: FernletCryptoPurpose.Signature.meshProbeChannelIntroductionV1
        )
        return introduction
    }

    private func channelBinding(for connection: NetworkConnection<QUIC>) throws -> Data {
        guard let binding = MeshProbeTLSBinding.hash(for: connection) else {
            throw MeshProbeError.missingTLSBinding
        }
        return binding
    }

    private func introduction(
        _ received: MeshProbeChannelIntroduction,
        matches expected: MeshProbeChannelIntroduction,
        signer: Data
    ) -> Bool {
        received.hasSameTranscript(as: expected) && received.verifies(using: signer)
    }

    private func requireDatagramCapacity(
        for datagrams: Network.QUIC.Datagrams<QUICDatagram>
    ) throws {
        let usableSize = datagrams.parent.usableDatagramFrameSize
        lastUsableDatagramFrameSize = usableSize
        record("QUIC datagram capability check: usable frame size=\(usableSize), required=\(MeshProbeDatagram.ping.count).")
        guard usableSize >= MeshProbeDatagram.ping.count else {
            throw MeshProbeError.datagramUnavailable(usableSize)
        }
    }

    private func sendInitialDatagram(over datagrams: Network.QUIC.Datagrams<QUICDatagram>) async throws {
        for attempt in 1...Self.maxInitialDatagramAttempts {
            record("Sending initial QUIC datagram ping attempt \(attempt) of \(Self.maxInitialDatagramAttempts).")
            try await sendDatagram(MeshProbeDatagram.ping, over: datagrams)
            let response = try await receiveDatagram(over: datagrams)
            record("Initial QUIC datagram attempt \(attempt) received \(MeshProbeDatagram.label(for: response)).")
            guard response != MeshProbeDatagram.pong else {
                markDatagramVerified()
                return
            }
            record("Initial QUIC datagram attempt \(attempt) did not receive pong; retrying.")
            try await answerProbeDatagram(response, over: datagrams)
        }
        throw MeshProbeError.invalidDatagram
    }

    private func answerDatagrams(over datagrams: Network.QUIC.Datagrams<QUICDatagram>) async throws {
        var unexpectedDatagramCount = 0
        for _ in 1...Self.maxHeartbeatCount {
            guard !Task.isCancelled else { return }
            let received = try await receiveDatagram(over: datagrams)
            record("Responder received \(MeshProbeDatagram.label(for: received)).")
            if received == MeshProbeDatagram.ping {
                try await sendDatagram(MeshProbeDatagram.pong, over: datagrams)
                markDatagramVerified()
                continue
            }
            if received == MeshProbeDatagram.heartbeat {
                try await sendDatagram(MeshProbeDatagram.heartbeatAcknowledgement, over: datagrams)
                recordAuthenticatedHeartbeat()
                continue
            }
            if received == MeshProbeDatagram.pong
                || received == MeshProbeDatagram.heartbeatAcknowledgement {
                record("Responder observed returned \(MeshProbeDatagram.label(for: received)).")
                continue
            }
            unexpectedDatagramCount += 1
            record("Responder ignored \(MeshProbeDatagram.label(for: received)).")
            guard unexpectedDatagramCount < Self.maxUnexpectedDatagrams else {
                throw MeshProbeError.invalidDatagram
            }
        }
    }

    private func answerProbeDatagram(
        _ received: Data,
        over datagrams: Network.QUIC.Datagrams<QUICDatagram>
    ) async throws {
        if received == MeshProbeDatagram.ping {
            try await sendDatagram(MeshProbeDatagram.pong, over: datagrams)
        } else if received == MeshProbeDatagram.heartbeat {
            try await sendDatagram(MeshProbeDatagram.heartbeatAcknowledgement, over: datagrams)
            recordAuthenticatedHeartbeat()
        }
    }

    private func startHeartbeatLoop(over datagrams: Network.QUIC.Datagrams<QUICDatagram>) {
        guard heartbeatTask == nil else { return }
        heartbeatTask = Task { @MainActor [weak self, datagrams] in
            guard let self else { return }
            do {
                try await self.sendHeartbeats(over: datagrams)
            } catch {
                self.heartbeatStopped(error, connectionID: datagrams.parent.id)
            }
        }
    }

    private func heartbeatStopped(_ error: Error, connectionID: String) {
        guard !Task.isCancelled, isRunning else { return }
        heartbeatTask = nil
        guard let endpoint = outboundEndpoint else {
            activeConnectionIDs.remove(connectionID)
            tunnelStopped(error, context: "QUIC heartbeat loop ended")
            return
        }
        outboundTunnelStopped(error, endpoint: endpoint, connectionID: connectionID)
    }

    private func sendHeartbeats(over datagrams: Network.QUIC.Datagrams<QUICDatagram>) async throws {
        for _ in 1...Self.maxHeartbeatCount {
            guard !Task.isCancelled else { return }
            try await Task.sleep(for: Self.heartbeatInterval)
            try await sendDatagram(MeshProbeDatagram.heartbeat, over: datagrams)
            try await receiveHeartbeatAcknowledgement(over: datagrams)
            recordAuthenticatedHeartbeat()
        }
    }

    private func receiveHeartbeatAcknowledgement(
        over datagrams: Network.QUIC.Datagrams<QUICDatagram>
    ) async throws {
        for _ in 1...Self.maxInitialDatagramAttempts {
            let received = try await receiveDatagram(over: datagrams)
            guard received != MeshProbeDatagram.heartbeatAcknowledgement else { return }
            record("Heartbeat received \(MeshProbeDatagram.label(for: received)); continuing.")
            try await answerProbeDatagram(received, over: datagrams)
        }
        throw MeshProbeError.invalidDatagram
    }

    private func markControlStreamVerified() {
        guard !controlStreamVerified else { return }
        controlStreamVerified = true
        status = "Signed QUIC control stream verified"
        updateBackgroundTask(title: "Fernlet mesh", subtitle: "1 friend connected", progress: 65)
        record("Verified both Fernlet signatures against the same TLS exporter hash.")
    }

    private func markDatagramVerified() {
        guard !datagramVerified else { return }
        datagramVerified = true
        if let endpoint = outboundEndpoint {
            outboundAttemptCounts.removeValue(forKey: endpoint.id)
        }
        updateBackgroundTask(title: "Fernlet mesh", subtitle: "1 friend connected", progress: 75)
        record("Verified a QUIC datagram round trip.")
    }

    private func recordAuthenticatedHeartbeat() {
        heartbeatCount = min(heartbeatCount + 1, Self.maxHeartbeatCount)
        lastAuthenticatedHeartbeat = Date()
        recordPowerStateIfChanged()
        let progress = min(Self.progressTotal - 1, Int64(75 + (heartbeatCount / 8)))
        updateBackgroundTask(title: "Fernlet mesh", subtitle: "1 friend connected", progress: progress)
    }

    private func updateBackgroundTask(title: String, subtitle: String, progress: Int64) {
        guard let backgroundTask else { return }
        backgroundTask.progress.completedUnitCount = min(progress, Self.progressTotal - 1)
        backgroundTask.updateTitle(title, subtitle: subtitle)
    }

    private func reserveConnection(_ id: String) -> Bool {
        guard activeConnectionIDs.count < Self.maxConnections else { return false }
        return activeConnectionIDs.insert(id).inserted
    }

    private func listenerStopped(_ error: Error) {
        guard !Task.isCancelled, isRunning else { return }
        fail(error, context: "The QUIC listener stopped")
    }

    private func browserStopped(_ error: Error) {
        guard !Task.isCancelled, isRunning else { return }
        fail(error, context: "The Bonjour browser stopped")
    }

    private func tunnelStopped(_ error: Error, context: String) {
        guard !Task.isCancelled, isRunning else { return }
        guard let usableSize = unavailableDatagramSize(from: error) else {
            endProbe(status: "Probe failed", reason: "\(context): \(error.localizedDescription)")
            return
        }
        endProbe(
            status: "Datagrams unavailable",
            reason: "QUIC datagrams were not negotiated; usable frame size is \(usableSize) bytes."
        )
    }

    private func unavailableDatagramSize(from error: Error) -> Int? {
        guard let probeError = error as? MeshProbeError else { return nil }
        guard case .datagramUnavailable(let usableSize) = probeError else { return nil }
        return usableSize
    }

    private func fail(_ error: Error, context: String) {
        endProbe(status: "Probe failed", reason: "\(context): \(error.localizedDescription)")
    }

    private func endProbe(status: String, reason: String) {
        lastShutdownReason = reason
        record("Ending mesh feasibility probe: \(reason)")
        stopNetworkOperations()
        backgroundContinuationAvailable = false
        isRunning = false
        self.status = status
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundTaskIdentifier)
        record("Cancelled the continuation request; active task=\(backgroundTask != nil).")
        completeBackgroundTask(success: false)
    }

    /// ML1: the probe is created and released with its debug screen, so its six network tasks must
    /// not outlive it. Every ordinary exit runs `stopNetworkOperations()`; this covers the path where
    /// the screen is dismissed without one — the `isolated deinit` shape `MeshNetworkManager` and
    /// `PresenceManager` use. Cancellation only: the observable state below is going away with the
    /// object, and publishing changes out of a deinit would be the wrong thing to do.
    isolated deinit {
        listenerTask?.cancel()
        browserTask?.cancel()
        inboundTunnelTask?.cancel()
        outboundTunnelTask?.cancel()
        outboundRetryTask?.cancel()
        heartbeatTask?.cancel()
    }

    private func stopNetworkOperations() {
        listenerTask?.cancel()
        browserTask?.cancel()
        inboundTunnelTask?.cancel()
        outboundTunnelTask?.cancel()
        outboundRetryTask?.cancel()
        heartbeatTask?.cancel()
        listenerTask = nil
        browserTask = nil
        inboundTunnelTask = nil
        outboundTunnelTask = nil
        outboundRetryTask = nil
        heartbeatTask = nil
        listener = nil
        browser = nil
        activeConnectionIDs.removeAll()
        recentBrowserEndpoints = []
        attemptedOutboundEndpointIDs.removeAll()
        outboundAttemptCounts.removeAll()
        outboundEndpoint = nil
        listenerIsReady = false
        listenerIsAdvertised = false
        browserHasStarted = false
    }

    private func completeBackgroundTask(success: Bool) {
        guard let backgroundTask else {
            record("No delivered continued-processing task was available to complete.")
            return
        }
        guard !completedBackgroundTask else {
            record("Skipped duplicate continued-processing task completion.")
            return
        }
        completedBackgroundTask = true
        self.backgroundTask = nil
        record("Completing continued-processing task success=\(success); system activity should end.")
        backgroundTask.setTaskCompleted(success: success)
    }

    private func resetResults() {
        backgroundContinuationAvailable = false
        controlStreamVerified = false
        datagramVerified = false
        heartbeatCount = 0
        lastAuthenticatedHeartbeat = nil
        lastUsableDatagramFrameSize = nil
        lastLiveQUICOptionSummary = "not observed"
        lastShutdownReason = nil
        events = []
        discoveredEndpoints = []
        completedBackgroundTask = false
        bytesSent = 0
        bytesReceived = 0
        connectCount = 0
        reconnectCount = 0
        firstConnectedAt = nil
        lastConnectedAt = nil
        lastReconnectAt = nil
        lastRecordedThermalState = nil
        lastRecordedLowPowerMode = nil
    }

    private func record(_ message: String) {
        if events.count == Self.maxEventCount { events.removeFirst() }
        let entry = "\(Date.now.formatted(date: .omitted, time: .standard)): \(message)"
        events.append(entry)
        // The ring holds 80 entries and is only readable through the UI. Echoing it lets a
        // headless `simctl launch --console-pty` run read the same evidence, and only when asked.
        guard MeshProbeDebugOptions.echoesEventsToConsole else { return }
        print("\(Self.consoleLogPrefix) \(entry)")
    }

    // MARK: - P8 gate counters

    /// Sends a control frame and adds its wire bytes to ``bytesSent``.
    private func sendFrame<T: Encodable>(
        _ value: T,
        over stream: Network.QUIC.Stream<QUICStream>
    ) async throws {
        bytesSent += try await MeshProbeWire.send(value, over: stream)
    }

    /// Receives a control frame and adds its wire bytes to ``bytesReceived``.
    private func receiveFrame<T: Decodable>(
        _ type: T.Type,
        from stream: Network.QUIC.Stream<QUICStream>
    ) async throws -> T {
        let frame = try await MeshProbeWire.receive(type, from: stream)
        bytesReceived += frame.byteCount
        return frame.value
    }

    /// Sends a datagram and adds its bytes to ``bytesSent``.
    private func sendDatagram(
        _ payload: Data,
        over datagrams: Network.QUIC.Datagrams<QUICDatagram>
    ) async throws {
        try await datagrams.send(payload)
        bytesSent += payload.count
    }

    /// Receives a datagram and adds its bytes to ``bytesReceived``.
    private func receiveDatagram(
        over datagrams: Network.QUIC.Datagrams<QUICDatagram>
    ) async throws -> Data {
        let content = try await datagrams.receive().content
        bytesReceived += content.count
        return content
    }

    /// Writes one ring entry when thermal state or Low Power Mode has moved since the last entry.
    /// Called from the connect, re-dial and heartbeat paths — the moments P8 correlates against —
    /// so no timer of its own is needed and the ring cannot be flooded by a steady state.
    private func recordPowerStateIfChanged() {
        let thermal = ProcessInfo.processInfo.thermalState
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard thermal != lastRecordedThermalState || lowPower != lastRecordedLowPowerMode else { return }
        lastRecordedThermalState = thermal
        lastRecordedLowPowerMode = lowPower
        record("Power state: thermal=\(Self.thermalStateName(thermal)), lowPowerMode=\(lowPower).")
    }

    /// Frozen English diagnostic token for a thermal state. `ProcessInfo.ThermalState` has no
    /// stable textual form of its own, and this text is pasted into bug notes, never shown as UI.
    nonisolated static func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:  return "nominal"
        case .fair:     return "fair"
        case .serious:  return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    /// Report formatting for an optional timestamp — "never" reads as an honest absence where a
    /// blank cell would read as a missing measurement.
    nonisolated static func timestamp(_ date: Date?) -> String {
        guard let date else { return "never" }
        return date.formatted(date: .omitted, time: .standard)
    }
}

/// Developer-only controls for the device feasibility spike. Nothing here is present in Release.
struct NetworkMeshFeasibilityProbeView: View {
    @State private var probe = NetworkMeshFeasibilityProbe.shared

    var body: some View {
        List {
            statusSection
            checksSection
            discoverySection
            eventsSection
        }
        .navigationTitle("Mesh feasibility")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarButton }
    }

    private var statusSection: some View {
        Section("Device-only probe") {
            LabeledContent("Status", value: probe.status)
            LabeledContent("Transport", value: probe.transportDisplayName)
            LabeledContent("Path policy", value: probe.pathPolicyDescription)
            if probe.canUseInfrastructureCompatibility {
                Button(probe.usesInfrastructureCompatibility ? "Use peer-to-peer" : "Use infrastructure Wi-Fi") {
                    probe.toggleInfrastructureCompatibility()
                }
                .disabled(probe.isRunning)
                if probe.isRunning {
                    Text("Stop the probe before changing its path policy.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            LabeledContent("Background continuation", value: probe.backgroundContinuationAvailable ? "Requested" : "Unavailable")
            LabeledContent("Usable datagram frame", value: probe.datagramFrameSizeDescription)
            LabeledContent("Authenticated heartbeats", value: "\(probe.heartbeatCount)")
            if let heartbeat = probe.lastAuthenticatedHeartbeat {
                LabeledContent("Last heartbeat", value: heartbeat.formatted(date: .omitted, time: .standard))
            }
        }
    }

    private var checksSection: some View {
        Section("Observed checks") {
            Label(probe.controlStreamVerified ? "Signed control stream verified" : "Control stream pending", systemImage: probe.controlStreamVerified ? "checkmark.circle.fill" : "circle")
            Label(probe.datagramVerified ? "QUIC datagram verified" : "Datagram pending", systemImage: probe.datagramVerified ? "checkmark.circle.fill" : "circle")
        }
    }

    private var discoverySection: some View {
        Section("Bonjour candidates") {
            if probe.discoveredEndpoints.isEmpty {
                Text("Waiting for a listener that has finished advertising.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(probe.discoveredEndpoints, id: \.self) { endpoint in
                    Text(endpoint)
                        .font(.footnote)
                }
            }
        }
    }

    private var eventsSection: some View {
        Section("Local events") {
            Button {
                probe.copyDiagnosticReport()
            } label: {
                Label("Copy diagnostic report", systemImage: "doc.on.doc")
            }
            .accessibilityIdentifier("meshFeasibility.copyDiagnosticReport")
            Text("Copies debug-only transport state and local events. It contains no user content.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if probe.events.isEmpty {
                Text("Use the Simulator lane for infrastructure checks, then use two devices for the required gate.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(probe.events.enumerated()), id: \.offset) { event in
                    Text(event.element)
                        .font(.footnote)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarButton: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button(probe.isRunning ? "Stop" : "Start") {
                if probe.isRunning {
                    probe.stop()
                } else {
                    probe.start()
                }
            }
        }
    }
}
#endif
