import Foundation

// MARK: - Payload classification

// Carved DOWN into the FernletDomainModel module so the persistence/audit DTOs (TrainerAuditEvent,
// ConnectionSessionLog) can reference these wire types without an upward edge. Codable identity is by
// rawValue / case structure — moving the type's location does NOT change the persisted JSON.

public nonisolated enum PayloadType: String, Codable, CaseIterable, Sendable {
    // Handshake
    case identityIntroduction  = "fernlet.identity.intro.v1"
    case identityAcknowledge   = "fernlet.identity.ack.v1"
    // Trainer
    case trainerPlan           = "fernlet.trainer.plan.v1"
    case trainerPlanDelta      = "fernlet.trainer.plan.delta.v1"
    case workoutCompletion     = "fernlet.workout.completion.v1"
    case workoutLiveUpdate     = "fernlet.workout.live.v1"
    // Session control
    case sessionHeartbeat      = "fernlet.session.ping.v1"
    case sessionGoodbye        = "fernlet.session.bye.v1"
    // Friends
    case friendPhoto           = "fernlet.friend.photo.v1"
    case friendPhotoManifest   = "fernlet.friend.photo.manifest.v1"
    case friendPhotoRequest    = "fernlet.friend.photo.request.v1"
    case recipeShare           = "fernlet.recipe.share.v1"
    /// A peer's current clothing shop — their broadcast, shareable item catalog (Increment 3). Ephemeral:
    /// held in memory only while connected. Buying is local (spend coins + copy the already-received item),
    /// so there is no separate item-transfer payload type.
    case clothingCatalog       = "fernlet.clothing.catalog.v1"
    /// A "good vibes" heart sent to a trusted friend in person (`HeartPayload` — id + day key only,
    /// no note, no numbers, no sender state). Always sealed to the recipient like a recipe share.
    case friendHeart           = "fernlet.friend.heart.v1"
    // Mesh
    case meshDescriptor        = "fernlet.mesh.descriptor.v1"
    case meshAdmissionGrant    = "fernlet.mesh.admission.grant.v1"
    case meshAdmissionToken    = "fernlet.mesh.admission.token.v1"
    case meshAdmissionRequest  = "fernlet.mesh.admission.request.v1"
    case meshStateChange       = "fernlet.mesh.state.v1"
    case meshFriendVouchList   = "fernlet.mesh.vouch.v1"
    case meshRemovalProposal   = "fernlet.mesh.removal.proposal.v1"
    case meshRemovalSecond     = "fernlet.mesh.removal.second.v1"
    // Group encryption (Phase 3)
    case meshKeyRotation       = "fernlet.mesh.key.rotation.v1"
    case meshKeyAck            = "fernlet.mesh.key.ack.v1"
    case meshRotationSync      = "fernlet.mesh.rotation.sync.v1"
    case meshEncryptedMetadata = "fernlet.mesh.encrypted.meta.v1"
    case meshCoordinatorBeacon = "fernlet.mesh.coordinator.beacon.v1"
    // Diagnostic
    case inspectorEcho         = "fernlet.diagnostic.echo.v1"
}

/// Feature capabilities a device advertises in the identity handshake (Proximity Mesh Redesign
/// Phase 1). Carried on the wire as raw-string arrays (`[String]`), never as this enum, so a
/// capability token minted by a NEWER build survives decode on an older client (the same
/// forward-tolerance stance as the parked `payloadTypeToken` on the envelope). Senders skip
/// payload kinds the peer hasn't advertised — see `ProximityCoordinator.PeerIdentity.supports(_:)`.
public nonisolated enum ProximityCapability: String, Codable, CaseIterable, Sendable {
    /// Friend-mesh photo sharing (the original friend-mesh feature; also what a legacy peer
    /// whose intro predates capability advertisement is assumed to support).
    case photos
    /// Clothing-shop catalog exchange (registers on the mesh in Phase 3).
    case shop
    /// In-person friend hearts (moves onto the presence layer in Phase 4).
    case hearts
    /// Session-scoped temporary messages (Phase 5).
    case messages
}

public nonisolated enum PayloadEncryption: Codable, Equatable, Sendable {
    case none
    case sealedTo(recipientKeyAgreementPublicKey: Data)
}

/// A contiguous date interval used in PayloadSummary.
/// Using a plain struct rather than ClosedRange<Date> to sidestep retroactive Codable conformance.
public nonisolated struct DateRange: Codable, Equatable, Sendable {
    public let start: Date
    public let end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }
}

public nonisolated struct PayloadSummary: Codable, Equatable, Sendable {
    public let title: String
    public let subtitle: String?
    public let itemCount: Int
    public let dateRange: DateRange?
    public let extraDetails: [String: String]

    public init(
        title: String,
        subtitle: String? = nil,
        itemCount: Int = 0,
        dateRange: DateRange? = nil,
        extraDetails: [String: String] = [:]
    ) {
        self.title = title
        self.subtitle = subtitle
        self.itemCount = itemCount
        self.dateRange = dateRange
        self.extraDetails = extraDetails
    }
}
