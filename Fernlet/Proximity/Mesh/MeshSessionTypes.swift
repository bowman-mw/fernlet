import Foundation

enum MeshEncryptionError: Error {
    case decryptionFailed
    case encryptionFailed
}

enum SlotKind {
    case active      // full payload routing, up to 3
    case lightweight // heartbeats only, up to 2
}

struct PeerSlot: Identifiable {
    let id: UUID  // == peer.id
    let peer: MultipeerPeer
    let channel: PeerChannelTransport
    let coordinator: ProximityCoordinator
    var kind: SlotKind
    var fingerprint: String?
    // Handshake-verified X25519 key agreement public key used for group key wrapping.
    // Set from ProximityCoordinator.PeerIdentity after identity exchange, never descriptor gossip.
    var verifiedKeyAgreementPublicKey: Data?
    var joinedEpoch: Int = 0
    var distanceSamples: [MeshDistanceSample] = []
    var stableDistanceMeters: Double?
    var isOverflowCandidate = false
}

/// In-memory symmetric group key for the current mesh session.
/// Never written to disk or keychain; lost on app termination or mesh leave.
struct MeshGroupKey {
    let epoch: Int
    let keyBytes: Data   // 32 bytes
    let activeSince: Date
}

struct MeshDistanceSample: Equatable {
    let recordedAt: Date
    let meters: Double
}

struct MeshSessionParticipant: Identifiable, Equatable {
    var id: String { fingerprint }

    let fingerprint: String
    let displayName: String
    let isLocal: Bool
}
