import Foundation
import simd

// Carved DOWN into the FernletDomainModel module (whole file is a pure DTO) so the persistence layer
// can reference it without an upward edge. References to the proximity enums use the canonical
// DomainModel names (ProximityRole / ProximityMode / ProximityRangingMode), not the app-side
// ProximityCoordinator.* typealiases. Codable identity is unchanged.

public nonisolated struct ConnectionSessionLog: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var startedAt: Date
    public var endedAt: Date?
    // This is the PERSISTED audit log inside the synced blob (`FernletSnapshot.connectionSessionLogs`),
    // not the proximity wire protocol — the wire enums stay strict; only this record decodes its
    // enum fields tolerantly (freeze-on-unknown + parked-token side channel, EnumDecodeCompat) so a
    // session logged by a newer build can't brick an older paired device into read-only recovery.
    public var role: ProximityRole
    public var unknownRoleToken: String? = nil
    public var mode: ProximityMode
    public var unknownModeToken: String? = nil
    public var localFingerprint: String
    public var peer: PeerInfo?
    public var ranging: RangingInfo
    public var transport: TransportInfo
    public var events: [Event]
    public var envelopes: [EnvelopeRecord]
    public var errors: [ErrorRecord]
    public var endState: String

    public var summary: Summary {
        Summary(
            durationSeconds: endedAt.map { $0.timeIntervalSince(startedAt) },
            totalEnvelopes: envelopes.count,
            totalBytes: transport.bytesSent + transport.bytesReceived,
            errorCount: errors.count,
            endState: endState
        )
    }

    public init(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        role: ProximityRole,
        mode: ProximityMode,
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

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        let roleSplit = try c.decodeTolerantEnum(
            ProximityRole.self, forKey: .role, parkedTokenKey: .unknownRoleToken, default: .browser)
        role = roleSplit.value
        unknownRoleToken = roleSplit.parkedToken
        let modeSplit = try c.decodeTolerantEnum(
            ProximityMode.self, forKey: .mode, parkedTokenKey: .unknownModeToken, default: .friend)
        mode = modeSplit.value
        unknownModeToken = modeSplit.parkedToken
        localFingerprint = try c.decode(String.self, forKey: .localFingerprint)
        peer = try c.decodeIfPresent(PeerInfo.self, forKey: .peer)
        ranging = try c.decode(RangingInfo.self, forKey: .ranging)
        transport = try c.decode(TransportInfo.self, forKey: .transport)
        events = try c.decode([Event].self, forKey: .events)
        envelopes = try c.decode([EnvelopeRecord].self, forKey: .envelopes)
        errors = try c.decode([ErrorRecord].self, forKey: .errors)
        endState = try c.decode(String.self, forKey: .endState)
    }

    public struct PeerInfo: Codable, Equatable, Sendable {
        public let displayName: String
        public let advertisedFingerprint: String?
        public let confirmedFingerprint: String?
        public let signingPublicKey: Data?
        public let firstSeenAt: Date
        public let lastSeenAt: Date

        public init(
            displayName: String,
            advertisedFingerprint: String?,
            confirmedFingerprint: String?,
            signingPublicKey: Data?,
            firstSeenAt: Date,
            lastSeenAt: Date
        ) {
            self.displayName = displayName
            self.advertisedFingerprint = advertisedFingerprint
            self.confirmedFingerprint = confirmedFingerprint
            self.signingPublicKey = signingPublicKey
            self.firstSeenAt = firstSeenAt
            self.lastSeenAt = lastSeenAt
        }
    }

    public struct RangingInfo: Codable, Equatable, Sendable {
        public var mode: ProximityRangingMode
        public var unknownModeToken: String? = nil
        public var samples: [DistanceSample]
        public var tapConfirmedAt: Date?
        public var minDistanceMeters: Double?
        public var maxDistanceMeters: Double?

        public init(
            mode: ProximityRangingMode,
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

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let modeSplit = try c.decodeTolerantEnum(
                ProximityRangingMode.self, forKey: .mode, parkedTokenKey: .unknownModeToken, default: .none)
            mode = modeSplit.value
            unknownModeToken = modeSplit.parkedToken
            samples = try c.decode([DistanceSample].self, forKey: .samples)
            tapConfirmedAt = try c.decodeIfPresent(Date.self, forKey: .tapConfirmedAt)
            minDistanceMeters = try c.decodeIfPresent(Double.self, forKey: .minDistanceMeters)
            maxDistanceMeters = try c.decodeIfPresent(Double.self, forKey: .maxDistanceMeters)
        }
    }

    public struct DistanceSample: Codable, Equatable, Identifiable, Sendable {
        public var id: UUID = UUID()
        public let timestamp: Date
        public let meters: Double
        public let directionX: Float?
        public let directionY: Float?
        public let directionZ: Float?

        public init(timestamp: Date, meters: Double, direction: simd_float3? = nil) {
            self.timestamp = timestamp
            self.meters = meters
            self.directionX = direction?.x
            self.directionY = direction?.y
            self.directionZ = direction?.z
        }
    }

    public struct TransportInfo: Codable, Equatable, Sendable {
        public var mcSessionState: String
        public var connectedAt: Date?
        public var disconnectedAt: Date?
        public var bytesSent: Int
        public var bytesReceived: Int
        public var bluetoothActive: Bool
        public var wifiActive: Bool
        public var rttSamplesMs: [Double]

        public var averageRttMs: Double? {
            guard !rttSamplesMs.isEmpty else { return nil }
            return rttSamplesMs.reduce(0, +) / Double(rttSamplesMs.count)
        }

        public init(
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

    public struct Event: Codable, Equatable, Identifiable, Sendable {
        public var id: UUID = UUID()
        public let timestamp: Date
        public let kind: Kind
        /// An event kind minted by a newer build, parked (kind freezes to `.stateTransition`, the
        /// message still describes what happened) so the log row can't brick the older device.
        public var unknownKindToken: String? = nil
        public let message: String

        public init(id: UUID = UUID(), timestamp: Date, kind: Kind, message: String) {
            self.id = id
            self.timestamp = timestamp
            self.kind = kind
            self.message = message
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            timestamp = try c.decode(Date.self, forKey: .timestamp)
            let kindSplit = try c.decodeTolerantEnum(
                Kind.self, forKey: .kind, parkedTokenKey: .unknownKindToken, default: .stateTransition)
            kind = kindSplit.value
            unknownKindToken = kindSplit.parkedToken
            message = try c.decode(String.self, forKey: .message)
        }

        public enum Kind: String, Codable, CaseIterable, Sendable {
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

    public struct EnvelopeRecord: Codable, Equatable, Identifiable, Sendable {
        public var id: UUID = UUID()
        public let envelopeID: UUID
        public let direction: Direction
        /// A direction value minted by a newer build (freeze to `.received`, park the token).
        /// `payloadType` is already a plain String here, so it needs no side channel.
        public var unknownDirectionToken: String? = nil
        public let payloadType: String
        public let payloadByteCount: Int
        public let timestamp: Date
        public let signatureVerified: Bool?
        public let encrypted: Bool
        public let summary: String

        public init(
            id: UUID = UUID(),
            envelopeID: UUID,
            direction: Direction,
            payloadType: String,
            payloadByteCount: Int,
            timestamp: Date,
            signatureVerified: Bool?,
            encrypted: Bool,
            summary: String
        ) {
            self.id = id
            self.envelopeID = envelopeID
            self.direction = direction
            self.payloadType = payloadType
            self.payloadByteCount = payloadByteCount
            self.timestamp = timestamp
            self.signatureVerified = signatureVerified
            self.encrypted = encrypted
            self.summary = summary
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            envelopeID = try c.decode(UUID.self, forKey: .envelopeID)
            let directionSplit = try c.decodeTolerantEnum(
                Direction.self, forKey: .direction, parkedTokenKey: .unknownDirectionToken, default: .received)
            direction = directionSplit.value
            unknownDirectionToken = directionSplit.parkedToken
            payloadType = try c.decode(String.self, forKey: .payloadType)
            payloadByteCount = try c.decode(Int.self, forKey: .payloadByteCount)
            timestamp = try c.decode(Date.self, forKey: .timestamp)
            signatureVerified = try c.decodeIfPresent(Bool.self, forKey: .signatureVerified)
            encrypted = try c.decode(Bool.self, forKey: .encrypted)
            summary = try c.decode(String.self, forKey: .summary)
        }

        public enum Direction: String, Codable, Sendable {
            case sent
            case received
        }
    }

    public struct ErrorRecord: Codable, Equatable, Identifiable, Sendable {
        public var id: UUID = UUID()
        public let timestamp: Date
        public let domain: String
        public let message: String
        public let recoverable: Bool

        public init(
            id: UUID = UUID(),
            timestamp: Date,
            domain: String,
            message: String,
            recoverable: Bool
        ) {
            self.id = id
            self.timestamp = timestamp
            self.domain = domain
            self.message = message
            self.recoverable = recoverable
        }
    }

    public struct Summary: Equatable, Sendable {
        public let durationSeconds: TimeInterval?
        public let totalEnvelopes: Int
        public let totalBytes: Int
        public let errorCount: Int
        public let endState: String

        public init(
            durationSeconds: TimeInterval?,
            totalEnvelopes: Int,
            totalBytes: Int,
            errorCount: Int,
            endState: String
        ) {
            self.durationSeconds = durationSeconds
            self.totalEnvelopes = totalEnvelopes
            self.totalBytes = totalBytes
            self.errorCount = errorCount
            self.endState = endState
        }
    }
}
