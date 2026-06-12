import Foundation
import simd

struct ConnectionSessionLog: Identifiable, Codable, Equatable {
    let id: UUID
    var startedAt: Date
    var endedAt: Date?
    var role: ProximityCoordinator.Role
    var mode: ProximityCoordinator.Mode
    var localFingerprint: String
    var peer: PeerInfo?
    var ranging: RangingInfo
    var transport: TransportInfo
    var events: [Event]
    var envelopes: [EnvelopeRecord]
    var errors: [ErrorRecord]
    var endState: String

    var summary: Summary {
        Summary(
            durationSeconds: endedAt.map { $0.timeIntervalSince(startedAt) },
            totalEnvelopes: envelopes.count,
            totalBytes: transport.bytesSent + transport.bytesReceived,
            errorCount: errors.count,
            endState: endState
        )
    }

    init(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        role: ProximityCoordinator.Role,
        mode: ProximityCoordinator.Mode,
        localFingerprint: String,
        peer: PeerInfo? = nil,
        ranging: RangingInfo = RangingInfo(mode: .none),
        transport: TransportInfo = TransportInfo(),
        events: [Event] = [],
        envelopes: [EnvelopeRecord] = [],
        errors: [ErrorRecord] = [],
        endState: String = "active"
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.role = role
        self.mode = mode
        self.localFingerprint = localFingerprint
        self.peer = peer
        self.ranging = ranging
        self.transport = transport
        self.events = events
        self.envelopes = envelopes
        self.errors = errors
        self.endState = endState
    }

    struct PeerInfo: Codable, Equatable {
        let displayName: String
        let advertisedFingerprint: String?
        let confirmedFingerprint: String?
        let signingPublicKey: Data?
        let firstSeenAt: Date
        let lastSeenAt: Date
    }

    struct RangingInfo: Codable, Equatable {
        var mode: ProximityCoordinator.RangingMode
        var samples: [DistanceSample]
        var tapConfirmedAt: Date?
        var minDistanceMeters: Double?
        var maxDistanceMeters: Double?

        init(
            mode: ProximityCoordinator.RangingMode,
            samples: [DistanceSample] = [],
            tapConfirmedAt: Date? = nil,
            minDistanceMeters: Double? = nil,
            maxDistanceMeters: Double? = nil
        ) {
            self.mode = mode
            self.samples = samples
            self.tapConfirmedAt = tapConfirmedAt
            self.minDistanceMeters = minDistanceMeters
            self.maxDistanceMeters = maxDistanceMeters
        }
    }

    struct DistanceSample: Codable, Equatable, Identifiable {
        var id: UUID = UUID()
        let timestamp: Date
        let meters: Double
        let directionX: Float?
        let directionY: Float?
        let directionZ: Float?

        init(timestamp: Date, meters: Double, direction: simd_float3? = nil) {
            self.timestamp = timestamp
            self.meters = meters
            self.directionX = direction?.x
            self.directionY = direction?.y
            self.directionZ = direction?.z
        }
    }

    struct TransportInfo: Codable, Equatable {
        var mcSessionState: String
        var connectedAt: Date?
        var disconnectedAt: Date?
        var bytesSent: Int
        var bytesReceived: Int
        var bluetoothActive: Bool
        var wifiActive: Bool
        var rttSamplesMs: [Double]

        var averageRttMs: Double? {
            guard !rttSamplesMs.isEmpty else { return nil }
            return rttSamplesMs.reduce(0, +) / Double(rttSamplesMs.count)
        }

        init(
            mcSessionState: String = "notConnected",
            connectedAt: Date? = nil,
            disconnectedAt: Date? = nil,
            bytesSent: Int = 0,
            bytesReceived: Int = 0,
            bluetoothActive: Bool = true,
            wifiActive: Bool = true,
            rttSamplesMs: [Double] = []
        ) {
            self.mcSessionState = mcSessionState
            self.connectedAt = connectedAt
            self.disconnectedAt = disconnectedAt
            self.bytesSent = bytesSent
            self.bytesReceived = bytesReceived
            self.bluetoothActive = bluetoothActive
            self.wifiActive = wifiActive
            self.rttSamplesMs = rttSamplesMs
        }
    }

    struct Event: Codable, Equatable, Identifiable {
        var id: UUID = UUID()
        let timestamp: Date
        let kind: Kind
        let message: String

        enum Kind: String, Codable, CaseIterable {
            case stateTransition
            case peerDiscovered
            case peerLost
            case rangingUpdated
            case tapConfirmed
            case inviteSent
            case inviteReceived
            case inviteAccepted
            case inviteRejected
            case identityIntroductionSent
            case identityIntroductionReceived
            case identityVerified
            case identityRejected
            case userConfirmed
            case envelopeSent
            case envelopeReceived
            case envelopeVerified
            case envelopeRejected
            case heartbeatSent
            case heartbeatReceived
            case sessionEnded
            case error
        }
    }

    struct EnvelopeRecord: Codable, Equatable, Identifiable {
        var id: UUID = UUID()
        let envelopeID: UUID
        let direction: Direction
        let payloadType: String
        let payloadByteCount: Int
        let timestamp: Date
        let signatureVerified: Bool?
        let encrypted: Bool
        let summary: String

        enum Direction: String, Codable {
            case sent
            case received
        }
    }

    struct ErrorRecord: Codable, Equatable, Identifiable {
        var id: UUID = UUID()
        let timestamp: Date
        let domain: String
        let message: String
        let recoverable: Bool
    }

    struct Summary: Equatable {
        let durationSeconds: TimeInterval?
        let totalEnvelopes: Int
        let totalBytes: Int
        let errorCount: Int
        let endState: String
    }
}
