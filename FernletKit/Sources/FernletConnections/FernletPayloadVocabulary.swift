// FernletPayloadVocabulary.swift
// FernletConnections
//
// Fernlet's payload vocabulary as ONE `ProximityNamespace.Vocabulary` value, `.fernlet`, which
// `ProximityNamespace.Family.fernlet` carries: the coordinator's three session messages, every payload
// token and the seventeen whose payload must arrive sealed, the capability tokens, the membership
// record kinds and the routed-type tokens. Payload and capability tokens are read off
// FernletDomainModel's `PayloadType` and `ProximityCapability`, so each keeps one spelling. ProximityKit's
// consumers still read their own constants for all of these until plan step A0.3 re-points them here,
// so the strings ProximityKit also spells for itself until then (the session titles, the record kinds,
// the routed-type tokens) are written here byte for byte as it writes them.
//
// Every value is pinned by `ProximityVocabularyGoldenTests`' frozen column, so a change here is a wire
// change for every device already in the field: it fails that suite rather than shipping. Every token
// and title is frozen English, never localized: a title is signed into its envelope.

import FernletDomainModel
import ProximityKit

// MARK: - The vocabulary

nonisolated extension ProximityNamespace.Vocabulary {

    /// Fernlet's payload vocabulary: the session messages, the payload rules, the capabilities, the
    /// membership record kinds and the routed types, each `.fernlet`.
    ///
    /// Sound by construction (`ProximityNamespaceGoldenTests` pins `ProximityNamespace.fernlet` as
    /// `.sound`, vocabulary included).
    public nonisolated static let fernlet = ProximityNamespace.Vocabulary(
        session: .fernlet,
        payloads: .fernlet,
        capabilities: .fernlet,
        membershipRecordKinds: .fernlet,
        routedTypes: .fernlet
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

    /// The four record kinds, each spelled like the payload token of the message that carries its
    /// record.
    public nonisolated static let fernlet = ProximityNamespace.MembershipRecordKinds(
        admission: "fernlet.mesh.member-admission.v1",
        departure: "fernlet.mesh.member-departure.v1",
        removal: "fernlet.mesh.member-removal.v1",
        termination: "fernlet.mesh.terminated.v1"
    )
}

nonisolated extension ProximityNamespace.RoutedTypes {

    /// The routed engine's photo, temporary-message and heart types, and the reserved control type.
    public nonisolated static let fernlet = ProximityNamespace.RoutedTypes(
        photo: "fernlet.mesh.routed-type.photo.v1",
        tempMessage: "fernlet.mesh.routed-type.temp-message.v1",
        heart: "fernlet.mesh.routed-type.heart.v1",
        control: "fernlet.mesh.routed-type.control.v1"
    )
}
