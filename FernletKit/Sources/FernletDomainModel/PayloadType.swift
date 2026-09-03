import Foundation

// MARK: - Payload classification

// Carved DOWN into the FernletDomainModel module so the persistence/audit DTOs (TrainerAuditEvent,
// ConnectionSessionLog) can reference these wire types without an upward edge. Codable identity is by
// rawValue / case structure — moving the type's location does NOT change the persisted JSON.

/// Every versioned wire payload type the proximity subsystem exchanges, by reverse-DNS raw value.
///
/// Carved down into DomainModel so the persistence/audit DTOs (``TrainerAuditEvent``,
/// ``ConnectionSessionLog``) can reference wire types without an upward edge. Raw values ARE the
/// wire identity — never rename a case. Which types must be sealed is decided in ProximityKit
/// (`sealingRequiredTypes`); the per-case notes below record each payload's sealing stance and
/// additive-compat behavior (older clients park unknown types instead of dropping the session).
public nonisolated enum PayloadType: String, Codable, CaseIterable, Sendable {
    // Handshake
    case identityIntroduction  = "fernlet.identity.intro.v1"
    case identityAcknowledge   = "fernlet.identity.ack.v1"
    // QR verification ceremony (bitchat adoptions Increment 4, Docs/Plan-Bitchat-Adoptions-2026-07-25.md):
    // upgrades a non-UWB `awaitingManualCommit` slot to ceremony grade — scan the peer's signed QR,
    // then prove key possession + liveness over the live session. Both sealed (in
    // `sealingRequiredTypes`); additive-safe (older clients park them).
    /// Scanner → displayer: a fresh nonce bound to the scanned QR (`VerifyChallengePayload`). Sealed.
    case verifyChallenge       = "fernlet.verify.challenge.v1"
    /// Displayer → scanner: Ed25519 proof over the challenge + QR nonce (`VerifyResponsePayload`). Sealed.
    case verifyResponse        = "fernlet.verify.response.v1"
    // Trainer
    case trainerPlan           = "fernlet.trainer.plan.v1"
    case trainerPlanDelta      = "fernlet.trainer.plan.delta.v1"
    case workoutCompletion     = "fernlet.workout.completion.v1"
    case workoutLiveUpdate     = "fernlet.workout.live.v1"
    // Session control
    case sessionHeartbeat      = "fernlet.session.ping.v1"
    /// **Frozen and parked: parsed, never emitted** (network migration P3 item 3, plan §8.3).
    ///
    /// A goodbye is an UNSIGNED courtesy frame — its whole body is a `PayloadSummary` — so it can
    /// say only "this link is going away", and that is exactly how a receiver must read it: the
    /// peer is treated as **disconnected, not departed** (plan §8.2's "disconnect ≠ removal"). It
    /// deliberately produces no `SignedDepartureRecord`: letting an unsigned frame subtract a
    /// member from a signed roster would make membership forgeable by anyone who can reach the
    /// link, and grow-only records are permanent, so the forgery could never be undone.
    ///
    /// New builds emit ``meshMemberDeparture`` instead, which is signed by the leaver. Decoding
    /// stays for peers built before the transition; `MeshMembershipGoodbyeInterop` states the rule
    /// in one place and `MeshMembershipEventWireTests` holds it.
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
    /// Asks a committed peer to (re)send its `clothingCatalog` (mesh redesign Phase 3a, "Catalog
    /// delivery must not assume commit symmetry"): each side sends this at ITS OWN slot commit, so a
    /// peer whose commit landed later — whose registry gate dropped the early catalog — still receives
    /// one. Carries no payload body; signed like other control payloads but never sealed (nothing to
    /// protect) and deliberately NOT in `sealingRequiredTypes`. Additive-safe post-Phase-1: older
    /// clients park unknown types without dropping the session.
    case clothingCatalogRequest = "fernlet.clothing.catalog.request.v1"
    /// A "good vibes" heart sent to a trusted friend in person (`HeartPayload` — id + day key only,
    /// no note, no numbers, no sender state). Always sealed to the recipient like a recipe share.
    case friendHeart           = "fernlet.friend.heart.v1"
    /// An offline "away" heart (`HeartPayload` again), carried INSIDE a heart-drop outer seal via
    /// the CloudKit public-DB dead-drop instead of a live radio (bitchat adoptions Increment 3).
    /// Deliberately NOT in `sealingRequiredTypes`: the inner envelope rides with
    /// `payloadEncryption == .none` because the dead-drop's outer prekey/static seal IS the
    /// confidentiality layer, and the opener only ever parses bytes it unsealed itself. Never
    /// dispatched on a live radio — no mesh/presence payload handler registers it.
    case friendHeartDrop       = "fernlet.friend.heart.drop.v1"
    /// A live-session temporary chat message (`TempMessagePayload`, mesh redesign Phase 5). Exchanged
    /// ONLY while a friend session is active and VANISHES at session end — nothing retained on device,
    /// nothing synced, no dead-drop, no offline queue (owner decision). Always sealed to the recipient
    /// (in `sealingRequiredTypes`) — messages are private. Registered on the mesh via the Phase-1
    /// payload registry + the `messages` capability; additive-safe post-Phase-1 (older clients park it).
    case tempMessage           = "fernlet.message.temp.v1"
    /// A one-hop content-moderation report bundle (`ModerationReportPayload`): the sender's OWN
    /// Ed25519-signed report rows about shop items, handed to a vault-trusted friend in person so the
    /// friend's device can tally reports it has personally verified (2026-07-11 ban memo). Always
    /// sealed to the recipient. Additive-safe post-Phase-1 (older clients park it); gated on the
    /// `moderation` capability so a peer that can't handle it is never sent one.
    case itemReport            = "fernlet.item.report.v1"
    /// A friend's current fuzzy wellbeing vibe + avatar appearance (`FriendStatePayload`), exchanged at
    /// an in-person friend session so friends see "vibes, never numbers." Always sealed. Gated on the
    /// `friendState` capability + the `allowNearbyFriendState` opt-in; additive-safe (older clients park).
    case friendState           = "fernlet.friend.state.v1"
    // Group Activities (Phase 6). Small-group, proximity-only. Ride the friend mesh (no new radio /
    // Bonjour service); gated on the `activities` capability; additive-safe (older clients park them).
    /// A host advertises an activity it is running to a committed friend (`ActivityOfferPayload`). Sealed.
    case activityOffer         = "fernlet.activity.offer.v1"
    /// A committed peer asks to join an offered activity (`ActivityJoinRequestPayload`). UNSEALED (mirror
    /// `clothingCatalogRequest`) — it carries only public keys, and the host re-validates the claimed
    /// identity against the transport-verified slot before minting, so nothing here is confidential.
    case activityJoinRequest   = "fernlet.activity.join.request.v1"
    /// The host's signed grant: an invitee-key-bound `ActivityJoinToken` + the current roster snapshot
    /// (`ActivityJoinGrantPayload`). Sealed to the joiner.
    case activityJoinGrant     = "fernlet.activity.join.grant.v1"
    /// A host-signed roster snapshot, gossiped opportunistically to keep members consistent
    /// (`ActivityRosterSnapshotPayload`). Sealed.
    case activityRosterSnapshot = "fernlet.activity.roster.v1"
    /// A version digest exchanged between committed members so the highest verified snapshot propagates
    /// (`ActivitySyncPayload`). Sealed.
    case activitySync          = "fernlet.activity.sync.v1"
    // Mesh
    case meshDescriptor        = "fernlet.mesh.descriptor.v1"
    case meshAdmissionGrant    = "fernlet.mesh.admission.grant.v1"
    case meshAdmissionToken    = "fernlet.mesh.admission.token.v1"
    case meshAdmissionRequest  = "fernlet.mesh.admission.request.v1"
    case meshStateChange       = "fernlet.mesh.state.v1"
    case meshFriendVouchList   = "fernlet.mesh.vouch.v1"
    case meshRemovalProposal   = "fernlet.mesh.removal.proposal.v1"
    case meshRemovalSecond     = "fernlet.mesh.removal.second.v1"
    // Membership events (network migration P3, plan §8.3). Each token is the SAME spelling as its
    // membership-record kind and its Ed25519 signing domain — record kind, wire token and crypto
    // purpose are one frozen English vocabulary, so grepping the token finds every layer that
    // touches those bytes. None is in `sealingRequiredTypes`: a membership record is signed gossip
    // that every member must be able to re-broadcast verbatim (plan §10.5), and pairwise sealing
    // would make a record readable only by its first hop. Additive-safe — older clients park them.
    /// A member's own signed statement that it left (`MeshMemberDeparturePayload`). Replaces the
    /// legacy `.sessionGoodbye` as the thing that ends a MEMBERSHIP; a goodbye only ends a link.
    case meshMemberDeparture   = "fernlet.mesh.member-departure.v1"
    /// An admitter's signed credential, kept as a durable record (`MeshMemberAdmissionPayload`,
    /// plan §8.3/§10.5). It carries NO new signed bytes: the record wraps the existing
    /// `MeshAdmissionToken`, still signed under `meshAdmissionTokenV2`, so this token names a frame
    /// and never a signing domain. Re-gossiped so a member admitted by one peer appears on every
    /// member's derived roster — without it a joiner is excluded from the next key distribution.
    case meshMemberAdmission   = "fernlet.mesh.member-admission.v1"
    /// A completed removal: quorum was reached and the tallier signed the evidence
    /// (`MeshMemberRemovalPayload`, plan §8.3/§10.4). Sent to every member EXCEPT the removed one,
    /// who is not told and does not need to be — plan §8.3 excludes a removed member from the new
    /// epoch's key distribution, so the removal reaches them as the key they no longer hold.
    case meshMemberRemoval     = "fernlet.mesh.member-removal.v1"
    /// A final-pair member's signed statement that the mesh is over (`MeshTerminationPayload`).
    case meshTerminated        = "fernlet.mesh.terminated.v1"
    /// A signed summary of the records the sender's ledger holds, so a counterpart can tell it is
    /// MISSING some and ask for a re-gossip (`MeshInventoryDigestPayload`, plan §10.5).
    case meshInventoryDigest   = "fernlet.mesh.inventory-digest.v1"
    /// A signed statement of the epoch branch head(s) the sender is on — the **epoch half** of plan
    /// §10.3's union exchange (`MeshEpochHeadsPayload`, network migration P4 item 3).
    ///
    /// The record half already had frames (`meshInventoryDigest` asks, the record frames answer);
    /// the head half had none, so two branches that both rotated while split could fold only what
    /// each had assembled locally. Signed for the same reason the digest is: the heads are the
    /// input to the successor a merge mints, and an unsigned one could push a mesh toward its
    /// counter cap.
    case meshEpochHeads        = "fernlet.mesh.epoch-heads.v1"
    /// A member's **signed** proposal to remove another member, which is also the proposer's own
    /// vote (`SignedRemovalProposal`, plan §10.4, network migration P4 item 5).
    ///
    /// Additive beside the frozen, UNSIGNED `meshRemovalProposal` / `meshRemovalSecond` pair
    /// declared earlier, not a replacement for it: those hard-code quorum at two and are what
    /// already-shipped builds speak. The hyphenated spelling is the tell — `removal-proposal` is the signed, quorum-derived
    /// family; `removal.proposal` is the legacy two-party one.
    case meshRemovalProposalSigned = "fernlet.mesh.removal-proposal.v1"
    /// One member's **signed** vote on an open removal proposal (`SignedRemovalVote`, plan §10.4).
    ///
    /// Never a record: the receiver tallies it against its OWN merged roster, and an incomplete
    /// proposal expires after five minutes leaving no trace. Only the completed removal
    /// (`meshMemberRemoval`) is durable.
    case meshRemovalVote       = "fernlet.mesh.removal-vote.v1"
    /// The origin-signed description of one routed item — id, type, ciphertext hash and size,
    /// immutable destination set, expiry, and a per-recipient content-key wrap
    /// (`MeshRoutedManifestPayload`, network migration P5 item 1, plan §11). Same spelling as
    /// `Signature.meshRoutedManifestV1`: token, record and signing domain are one vocabulary.
    ///
    /// NOT in `sealingRequiredTypes`, on purpose: a custodian forwards the origin's exact signed
    /// object inside its own envelope, and pairwise sealing would make the manifest readable only
    /// by its first hop. Confidentiality is the wrap, not the envelope — every roster member (all
    /// of whom are destinations) can read the type token, size and destination fingerprints.
    /// Additive: older builds park the token (`isUnknownPayloadType`) and still verify the envelope.
    case meshRoutedManifest    = "fernlet.mesh.routed-manifest.v1"
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
    /// One-hop content-moderation report relay (Phase 3b).
    case moderation
    /// Fuzzy wellbeing state + cached appearance exchange (Phase 4).
    case friendState
    /// Small-group Group Activities: signed roster + invitee-key-bound join tokens (Phase 6).
    case activities
    /// wire2 sealed-payload framing (bitchat adoptions Increment 2): sealed payload bodies between
    /// two `wire2` peers are deflate-compressed and padded to size buckets BEFORE sealing, so an
    /// observer can't size-class them. A wire format, not a user feature — advertised
    /// unconditionally by every build that ships it.
    case wire2
    /// Offline "away" hearts via the CloudKit dead-drop (bitchat adoptions Increment 3): this peer
    /// mints/gossips one-time prekey bundles and understands `friendHeartDrop`. Advertised only
    /// when the user opted into away delivery (`heartsAwayDelivery`).
    case heartsAway
}

/// Whether an envelope's payload rides plaintext or sealed to a recipient key.
///
/// `sealedTo` carries the recipient's X25519 key-agreement public key; the sealing itself is
/// performed in ProximityKit — this module only names the intent.
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

/// The human-readable disclosure summary shown before a payload is accepted.
///
/// Built by the sender to describe what a payload contains (title, item count, date range) so the
/// receiving user can consent to it without the app decoding the body first.
///
/// **DO NOT LOCALIZE `title`, `subtitle`, or any `extraDetails` key or value.** They are wire
/// tokens despite reading exactly like UI copy — which is why this banner is here, on a type whose
/// first sentence says "human-readable", sitting in a module a bulk localization pass would
/// reasonably assume is display-bearing. Two things break at once if they are translated:
/// `CanonicalSignatureSerializer` folds all of them into the Ed25519 canonical signing bytes, and
/// they render on the **receiving** device, not the sender's — so a Spanish sender's payload would
/// arrive as Spanish consent copy on a German peer's phone. Signature verification still passes
/// either way, so no test would catch it. A localized Connection Inspector belongs on the receiving
/// side, mapping the frozen title to a local label keyed on the payload type token.
public nonisolated struct PayloadSummary: Codable, Equatable, Sendable {
    public let title: String
    public let subtitle: String?
    public let itemCount: Int
    public let dateRange: DateRange?
    public let extraDetails: [String: String]

    /// Most `extraDetails` entries a decoded summary may carry, and the longest any single summary
    /// string may be.
    ///
    /// R3: the summary is built by the SENDER and rendered to the receiving user before consent, so
    /// its strings and dictionary are untrusted peer input with nothing else bounding them. A
    /// legitimate disclosure is a handful of short lines; anything past these caps is rejected.
    public static let maxExtraDetails = 16
    public static let maxDetailCharacters = 200

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

    /// Bounded decode (R3/R5): rejects an oversize summary rather than holding and rendering it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try Self.boundedText(c.decode(String.self, forKey: .title), in: c, key: .title)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
            .map { try Self.boundedText($0, in: c, key: .subtitle) }
        itemCount = try c.decode(Int.self, forKey: .itemCount)
        dateRange = try c.decodeIfPresent(DateRange.self, forKey: .dateRange)
        let details = try c.decode([String: String].self, forKey: .extraDetails)
        guard details.count <= Self.maxExtraDetails else {
            throw DecodingError.dataCorruptedError(
                forKey: .extraDetails, in: c,
                debugDescription: "\(details.count) detail rows exceeds the \(Self.maxExtraDetails) allowed")
        }
        for (key, value) in details {
            _ = try Self.boundedText(key, in: c, key: .extraDetails)
            _ = try Self.boundedText(value, in: c, key: .extraDetails)
        }
        extraDetails = details
    }

    /// Rejects a summary string longer than ``maxDetailCharacters``.
    private static func boundedText(_ value: String, in container: KeyedDecodingContainer<CodingKeys>,
                                    key: CodingKeys) throws -> String {
        guard value.count <= maxDetailCharacters else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: container,
                debugDescription: "summary text of \(value.count) characters exceeds the \(maxDetailCharacters) allowed")
        }
        return value
    }

    /// Wire JSON keys for a disclosure summary.
    private enum CodingKeys: String, CodingKey {
        case title, subtitle, itemCount, dateRange, extraDetails
    }
}
