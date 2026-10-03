// FernletPayloadVocabulary.swift
// FernletConnections
//
// Fernlet's payload vocabulary as ONE `ProximityNamespace.Vocabulary` value, `.fernlet`, which
// `ProximityNamespace.Family.fernlet` carries: the coordinator's three session messages, every payload
// token and the seventeen whose payload must arrive sealed, the capability tokens, the membership
// record kinds, the routed-type tokens and the mesh engine's thirty messages. Payload and capability
// tokens are read off FernletDomainModel's `PayloadType` and `ProximityCapability`, and so are the
// record kinds (a record kind IS the payload token of the frame that carries its record) and the mesh
// messages, so each keeps one spelling. The routed-type tokens and the session titles have no
// `PayloadType` twin and are spelled here alone. ProximityKit reads every group off the namespace: its
// identity envelope seals and parks by the payload rules, its coordinator signs and dispatches by the
// session messages and reads the capability rules, its mesh and presence managers advertise the wire2
// token (and the mesh frames by it), its inventory digest hashes the record kinds, its routed type
// registry builds its rows from the routed types and its mesh manager signs and dispatches its
// engine's own frames by the mesh messages.
//
// Every value is pinned by `ProximityVocabularyGoldenTests`' frozen column, so a change here is a wire
// change for every device already in the field: it fails that suite rather than shipping. Every token
// and title is frozen English, never localized: a title is signed into its envelope.

import FernletDomainModel
import ProximityKit

// MARK: - The vocabulary

nonisolated extension ProximityNamespace.Vocabulary {

    /// Fernlet's payload vocabulary: the session messages, the payload rules, the capabilities, the
    /// membership record kinds, the routed types and the mesh messages, each `.fernlet`.
    ///
    /// Sound by construction (`ProximityNamespaceGoldenTests` pins `ProximityNamespace.fernlet` as
    /// `.sound`, vocabulary included).
    public nonisolated static let fernlet = ProximityNamespace.Vocabulary(
        session: .fernlet,
        payloads: .fernlet,
        capabilities: .fernlet,
        membershipRecordKinds: .fernlet,
        routedTypes: .fernlet,
        mesh: .fernlet
    )
}

// MARK: - The parts

nonisolated extension ProximityNamespace.SessionMessages {

    /// The coordinator's identity introduction, titled "Hello", its acknowledgement, titled "Identity
    /// acknowledged", and the session heartbeat, a "Heartbeat" answered by a "Heartbeat ack".
    public nonisolated static let fernlet = ProximityNamespace.SessionMessages(
        identityIntroduction: ProximityNamespace.SessionMessage(
            payloadType: PayloadType.identityIntroduction.rawValue, summaryTitle: "Hello"),
        identityAcknowledge: ProximityNamespace.SessionMessage(
            payloadType: PayloadType.identityAcknowledge.rawValue, summaryTitle: "Identity acknowledged"),
        heartbeat: ProximityNamespace.Heartbeat(
            payloadType: PayloadType.sessionHeartbeat.rawValue,
            pingTitle: "Heartbeat",
            replyTitle: "Heartbeat ack")
    )
}

nonisolated extension ProximityNamespace.PayloadRules {

    /// Every `PayloadType` token, and the seventeen whose payload must arrive sealed: the verify
    /// ceremony, the trainer channel, and the friend features that carry personal content.
    public nonisolated static let fernlet = ProximityNamespace.PayloadRules(
        known: Set(PayloadType.allCases.map(\.rawValue)),
        sealingRequired: Set([
            PayloadType.friendPhoto, .recipeShare, .clothingCatalog, .friendHeart, .tempMessage, .itemReport,
            .friendState, .activityOffer, .activityJoinGrant, .activityRosterSnapshot, .activitySync,
            .trainerPlan, .trainerPlanDelta, .workoutCompletion, .workoutLiveUpdate,
            .verifyChallenge, .verifyResponse
        ].map(\.rawValue))
    )
}

nonisolated extension ProximityNamespace.Capabilities {

    /// Every `ProximityCapability` token in declaration order, `wire2` marking the wire2 framing, and
    /// photos alone for a peer whose introduction lists none: every friend radio that predates
    /// capability advertisement could exchange only photos.
    public nonisolated static let fernlet = ProximityNamespace.Capabilities(
        known: ProximityCapability.allCases.map(\.rawValue),
        wire2: ProximityCapability.wire2.rawValue,
        assumedForLegacyPeers: [ProximityCapability.photos.rawValue]
    )
}

nonisolated extension ProximityNamespace.MembershipRecordKinds {

    /// The four record kinds, each the `PayloadType` token of the message that carries its record:
    /// a record kind IS its payload token, so it is read off `PayloadType` and keeps one spelling.
    public nonisolated static let fernlet = ProximityNamespace.MembershipRecordKinds(
        admission: PayloadType.meshMemberAdmission.rawValue,
        departure: PayloadType.meshMemberDeparture.rawValue,
        removal: PayloadType.meshMemberRemoval.rawValue,
        termination: PayloadType.meshTerminated.rawValue
    )
}

nonisolated extension ProximityNamespace.RoutedTypes {

    /// The routed engine's photo, temporary-message and heart types, and the reserved control type:
    /// Fernlet's only spelling of each, which ProximityKit's routed type registry builds its three
    /// rows from (the control type has none).
    public nonisolated static let fernlet = ProximityNamespace.RoutedTypes(
        photo: "fernlet.mesh.routed-type.photo.v1",
        tempMessage: "fernlet.mesh.routed-type.temp-message.v1",
        heart: "fernlet.mesh.routed-type.heart.v1",
        control: "fernlet.mesh.routed-type.control.v1"
    )
}

nonisolated extension ProximityNamespace.MeshMessages {

    /// The mesh engine's thirty messages, each the `PayloadType` token Fernlet's mesh signs and
    /// dispatches its frame under, so each keeps one spelling: four of them are also the record kinds
    /// above, and fifteen spell a signature label (`ProximityNamespaceGoldenTests` holds the pairs).
    public nonisolated static let fernlet = ProximityNamespace.MeshMessages(
        descriptor: PayloadType.meshDescriptor.rawValue,
        admissionGrant: PayloadType.meshAdmissionGrant.rawValue,
        admissionRequest: PayloadType.meshAdmissionRequest.rawValue,
        stateChange: PayloadType.meshStateChange.rawValue,
        friendVouchList: PayloadType.meshFriendVouchList.rawValue,
        removalProposal: PayloadType.meshRemovalProposal.rawValue,
        removalSecond: PayloadType.meshRemovalSecond.rawValue,
        memberDeparture: PayloadType.meshMemberDeparture.rawValue,
        memberAdmission: PayloadType.meshMemberAdmission.rawValue,
        memberRemoval: PayloadType.meshMemberRemoval.rawValue,
        terminated: PayloadType.meshTerminated.rawValue,
        inventoryDigest: PayloadType.meshInventoryDigest.rawValue,
        epochHeads: PayloadType.meshEpochHeads.rawValue,
        keyAgreement: PayloadType.meshKeyAgreement.rawValue,
        removalProposalSigned: PayloadType.meshRemovalProposalSigned.rawValue,
        removalVote: PayloadType.meshRemovalVote.rawValue,
        routedManifest: PayloadType.meshRoutedManifest.rawValue,
        routedChunk: PayloadType.meshRoutedChunk.rawValue,
        custodyReceipt: PayloadType.meshCustodyReceipt.rawValue,
        recipientReceipt: PayloadType.meshRecipientReceipt.rawValue,
        routedInventoryDigest: PayloadType.meshRoutedInventoryDigest.rawValue,
        routedDrainAnswer: PayloadType.meshRoutedDrainAnswer.rawValue,
        keyRotation: PayloadType.meshKeyRotation.rawValue,
        keyAck: PayloadType.meshKeyAck.rawValue,
        rotationSync: PayloadType.meshRotationSync.rawValue,
        encryptedMetadata: PayloadType.meshEncryptedMetadata.rawValue,
        coordinatorBeacon: PayloadType.meshCoordinatorBeacon.rawValue,
        verifyChallenge: PayloadType.verifyChallenge.rawValue,
        verifyResponse: PayloadType.verifyResponse.rawValue,
        sessionGoodbye: PayloadType.sessionGoodbye.rawValue
    )
}
