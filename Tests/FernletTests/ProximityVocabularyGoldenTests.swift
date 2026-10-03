// ProximityVocabularyGoldenTests.swift
// FernletTests
//
// ProximityKit plan step A0.3 (Docs/Plan-FernletCoach-ProximityKit-2026-10-01.md §4 A0.3) takes
// Fernlet's payload vocabulary and session rules out of ProximityKit's own code and has the host
// supply them. This suite holds every token and byte string that step routes through the host to
// the value Fernlet ships: each by a hand-written literal, and wherever a production consumer can
// be reached without a new seam, by driving that consumer and reading what it emits.
//
// THE RULE. Every row pairs a FROZEN literal with today's accessor. The literal column never
// changes: a red row is a wire, keychain or at-rest decision, never re-pinned from Swift's output.
// When a value moves, only its accessor is re-pointed at the path production then reads, and a
// moved consumer no cell drives yet gains a cell. A behavioural cell needs no re-pointing at all:
// it pins the consumer along with the value, and it reads its expectations off the frozen column.
//
// Thirteen groups:
//
// 1. **Payload tokens.** All 55 `PayloadType` tokens, and a table that is exactly the type's cases.
// 2. **The sealing rule, by behaviour.** The 17 tokens an envelope must carry sealed; every one of
//    the 55 signed unsealed under a real identity is refused exactly when it is one of them, and a
//    token no build knows verifies unsealed, parked and empty.
// 3. **Capabilities.** The 9 tokens; the coordinator's receive bounds (18 kept, each cut to 32
//    characters) by driving it; the legacy default (no list means photos alone) where the
//    coordinator and the mesh's seats decide it; and `wire2`'s role, framing sealed bodies.
// 4. **Session enums.** `ProximityMode`, `ProximityRole` and `ProximityRangingMode`, both ways.
// 5. **Membership record kinds.** The 4 tokens, the digest's kind-first order and one known-answer
//    inventory digest over a ledger of one record per kind.
// 6. **Routed types.** The 4 `MeshRoutedTypeToken` spellings and the heart row's cap.
// 7. **The coordinator's session messages.** The token and title of the introduction, the
//    acknowledgement, the heartbeat and its reply, read off what a live coordinator sends; and the
//    mesh's rule that an envelope's summary title is its payload token.
// 8. **Presentation strings.** The two instance-name prefixes and the certificate's common name,
//    read off `.fernlet`'s radios, off what the radios, the presence manager and the minting doors
//    mint under them and off what the name display hides, under `.fernlet` and under a namespace
//    whose strings are its own; and the coordinator's display default and its two service types,
//    deleted rather than moved, which no accessor reads and no transport is handed.
// 9. **The trainer export body.** Its format token, version, JSON bytes and two size caps.
// 10. **The generic types.** `PayloadEncryption` and `PayloadSummary`: one envelope's schema-v1
//     canonical bytes, both types' JSON, and the summary's decode bounds.
// 11. **Persisted records that stay Fernlet's.** A trusted peer, a trainer audit row and a session
//     log, each as the JSON Fernlet's repositories write, both ways.
// 12. **Display-name sanitizing.** `ItemNameModeration.sanitizedName` over a fixed corpus, and the
//     "A friend" floor ProximityKit puts under it.
// 13. **`.fernlet`'s vocabulary and presentation strings.** Every token, title and presentation
//     string FernletConnections ships in `ProximityNamespace.fernlet` equals its frozen literal, its
//     token sets and lists are the frozen tables whole, reflection finds no field left unpinned, and
//     the bounds the namespace's soundness rules apply are those of the consumers they protect.
//
// What another suite already pins literally is referenced, not repeated: the schema-v2 envelope
// golden (`FernletIdentityEnvelopeTests.goldenEnvelopeHex`), the routed registry's columns and its
// photo and text caps (`MeshRoutedTypeRegistryTests`, `MeshRoutedTextBodyTests`), the tolerant
// record decodes (`ProximityRecordDecodeCompatTests`), and the one-admission inventory digest
// (`MeshMembershipEventGoldenTests.goldenRecordsHashHex`). The token tables are whole on purpose:
// a table that is exactly a type's cases is what makes a new case fail here until it has a row.
//
// Every identity and every label-taking consumer this suite builds names its namespace explicitly
// (`.fernlet`, or group 8's namespace that differs from it in the presentation strings alone), never
// a test binding (ProximityNamespaceTestBindings.swift). Every hex vector and JSON golden
// below was derived from the FORMAT by an independent Python re-implementation —
// `CanonicalByteWriter`'s fields, and Foundation's JSON output rules (keys sorted by code point,
// `/` escaped unless `.withoutEscapingSlashes`, a whole number printed without a fraction,
// ISO-8601 to the second), which a probe over unrelated keys confirmed on the iOS 26.5 simulator.
// The model was proved honest first by reproducing
// `MeshMembershipEventGoldenTests.goldenRecordsHashHex`; nothing here was copied out of Swift's
// output.

import FernletConnections
import FernletDomainModel
import FernletFoundation
import Foundation
import Security
import Testing
import simd
@testable import ProximityKit

// MARK: - The tables' rows

/// One token or byte string plan step A0.3 routes through the host: what it is, its FROZEN literal,
/// and where today's code holds it.
struct VocabularyGoldenRow: Sendable {
    /// A stable path naming the value, e.g. `payloadType.recipeShare` or `capability.wire2`.
    let field: String
    /// The bytes, written by hand from the A0.3 census. Never computed from a constant; never edited.
    let frozen: String
    /// Today's accessor: **the only column a later A0.3 commit may re-point.** `nil` where no test
    /// can name the value (an inline literal, a default argument) or where the value was deleted
    /// rather than moved (a "deleted: no value" row); a behaviour cell pins it instead and reads its
    /// expectation off `frozen`.
    let today: String?
}

/// One number plan step A0.3 moves or reads beside a token: a bound, a version, a cap.
struct VocabularyGoldenNumber: Sendable {
    /// A stable path naming the value, e.g. `capability.maxAdvertised`.
    let field: String
    /// The number, written by hand. Never edited.
    let frozen: Int
    /// Today's accessor, the only column a later commit may re-point.
    let today: Int
}

// MARK: - The suite

/// Every token and byte string plan step A0.3 routes through the host, pinned by literal and by
/// behaviour, so that moving a value cannot change a byte unseen.
///
/// **The rule for every later commit: re-point the `today:` column, never the `frozen:` one.** The
/// same holds for every hex vector and JSON golden here: a failing one is a WIRE or AT-REST decision,
/// so it is never re-pinned from Swift's output to go green. Failure messages print the actual bytes
/// so a deliberate change can be argued from them.
@MainActor
@Suite(.serialized)
struct ProximityVocabularyGoldenTests {

    /// Every string row, across the groups.
    static var allRows: [VocabularyGoldenRow] {
        payloadRows + capabilityRows + sessionEnumRows + recordKindRows + routedTypeRows
            + presentationRows + trainerExportRows + moderationRows
    }

    /// Every number row, across the groups.
    static var allNumbers: [VocabularyGoldenNumber] {
        capabilityBoundNumbers + routedTypeNumbers + trainerExportNumbers + summaryBoundNumbers
            + moderationNumbers
    }

    /// The tables hold every value once, in the shape the design counts: 55 payload tokens, 9
    /// capabilities, 7 session-enum values, 4 record kinds, 4 routed types, 7 presentation strings,
    /// the trainer format and the name floor, and nine numbers.
    @Test func theTablesHoldEveryValueOnce() {
        let counts = [Self.payloadRows.count, Self.capabilityRows.count, Self.sessionEnumRows.count,
                      Self.recordKindRows.count, Self.routedTypeRows.count, Self.presentationRows.count,
                      Self.trainerExportRows.count, Self.moderationRows.count]
        #expect(counts == [55, 9, 7, 4, 4, 7, 1, 1], "the tables hold \(counts) rows")
        #expect(Self.allNumbers.count == 9, "the number tables hold \(Self.allNumbers.count) rows")
        let fields = Self.allRows.map(\.field) + Self.allNumbers.map(\.field)
        #expect(Set(fields).count == fields.count, "a field appears twice")
    }

    // MARK: Group 1 — the payload tokens

    /// All 55 `PayloadType` tokens, in declaration order. Pieces of this table also have literal pins
    /// elsewhere — the fifteen spelled like a signature label in ProximityNamespaceGoldenTests group 3,
    /// the activity tokens in `ActivityTests`, the parked tokens in `MeshNetworkManagerTests` and
    /// `MeshRoutedDrainWallTests` — but this is the one place every token meets its case.
    static var payloadRows: [VocabularyGoldenRow] {
        handshakeAndTrainerRows + featureRows + meshControlRows + membershipRows + routedAndRotationRows
    }

    /// The handshake, verify ceremony, trainer and session tokens.
    private static var handshakeAndTrainerRows: [VocabularyGoldenRow] {
        [
            payload(.identityIntroduction, "fernlet.identity.intro.v1"),
            payload(.identityAcknowledge, "fernlet.identity.ack.v1"),
            payload(.verifyChallenge, "fernlet.verify.challenge.v1"),
            payload(.verifyResponse, "fernlet.verify.response.v1"),
            payload(.trainerPlan, "fernlet.trainer.plan.v1"),
            payload(.trainerPlanDelta, "fernlet.trainer.plan.delta.v1"),
            payload(.workoutCompletion, "fernlet.workout.completion.v1"),
            payload(.workoutLiveUpdate, "fernlet.workout.live.v1"),
            payload(.sessionHeartbeat, "fernlet.session.ping.v1"),
            payload(.sessionGoodbye, "fernlet.session.bye.v1")
        ]
    }

    /// The feature tokens: photos, recipes, the shop, hearts, messages, moderation, state, activities.
    private static var featureRows: [VocabularyGoldenRow] {
        [
            payload(.friendPhoto, "fernlet.friend.photo.v1"),
            payload(.friendPhotoManifest, "fernlet.friend.photo.manifest.v1"),
            payload(.friendPhotoRequest, "fernlet.friend.photo.request.v1"),
            payload(.recipeShare, "fernlet.recipe.share.v1"),
            payload(.clothingCatalog, "fernlet.clothing.catalog.v1"),
            payload(.clothingCatalogRequest, "fernlet.clothing.catalog.request.v1"),
            payload(.friendHeart, "fernlet.friend.heart.v1"),
            payload(.friendHeartDrop, "fernlet.friend.heart.drop.v1"),
            payload(.tempMessage, "fernlet.message.temp.v1"),
            payload(.itemReport, "fernlet.item.report.v1"),
            payload(.friendState, "fernlet.friend.state.v1"),
            payload(.activityOffer, "fernlet.activity.offer.v1"),
            payload(.activityJoinRequest, "fernlet.activity.join.request.v1"),
            payload(.activityJoinGrant, "fernlet.activity.join.grant.v1"),
            payload(.activityRosterSnapshot, "fernlet.activity.roster.v1"),
            payload(.activitySync, "fernlet.activity.sync.v1")
        ]
    }

    /// The mesh control tokens, the legacy two-party removal pair among them.
    private static var meshControlRows: [VocabularyGoldenRow] {
        [
            payload(.meshDescriptor, "fernlet.mesh.descriptor.v1"),
            payload(.meshAdmissionGrant, "fernlet.mesh.admission.grant.v1"),
            payload(.meshAdmissionToken, "fernlet.mesh.admission.token.v1"),
            payload(.meshAdmissionRequest, "fernlet.mesh.admission.request.v1"),
            payload(.meshStateChange, "fernlet.mesh.state.v1"),
            payload(.meshFriendVouchList, "fernlet.mesh.vouch.v1"),
            payload(.meshRemovalProposal, "fernlet.mesh.removal.proposal.v1"),
            payload(.meshRemovalSecond, "fernlet.mesh.removal.second.v1")
        ]
    }

    /// The signed membership tokens: records, digest, epoch heads, key agreement, the removal quorum.
    private static var membershipRows: [VocabularyGoldenRow] {
        [
            payload(.meshMemberDeparture, "fernlet.mesh.member-departure.v1"),
            payload(.meshMemberAdmission, "fernlet.mesh.member-admission.v1"),
            payload(.meshMemberRemoval, "fernlet.mesh.member-removal.v1"),
            payload(.meshTerminated, "fernlet.mesh.terminated.v1"),
            payload(.meshInventoryDigest, "fernlet.mesh.inventory-digest.v1"),
            payload(.meshEpochHeads, "fernlet.mesh.epoch-heads.v1"),
            payload(.meshKeyAgreement, "fernlet.mesh.key-agreement.v1"),
            payload(.meshRemovalProposalSigned, "fernlet.mesh.removal-proposal.v1"),
            payload(.meshRemovalVote, "fernlet.mesh.removal-vote.v1")
        ]
    }

    /// The routed-delivery tokens, the group-key rotation tokens, the metadata wrapper, the beacon and
    /// the diagnostic echo.
    private static var routedAndRotationRows: [VocabularyGoldenRow] {
        [
            payload(.meshRoutedManifest, "fernlet.mesh.routed-manifest.v1"),
            payload(.meshRoutedChunk, "fernlet.mesh.routed-chunk.v1"),
            payload(.meshCustodyReceipt, "fernlet.mesh.custody-receipt.v1"),
            payload(.meshRecipientReceipt, "fernlet.mesh.recipient-receipt.v1"),
            payload(.meshRoutedInventoryDigest, "fernlet.mesh.routed-inventory-digest.v1"),
            payload(.meshRoutedDrainAnswer, "fernlet.mesh.routed-drain-answer.v1"),
            payload(.meshKeyRotation, "fernlet.mesh.key.rotation.v1"),
            payload(.meshKeyAck, "fernlet.mesh.key.ack.v1"),
            payload(.meshRotationSync, "fernlet.mesh.rotation.sync.v1"),
            payload(.meshEncryptedMetadata, "fernlet.mesh.encrypted.meta.v1"),
            payload(.meshCoordinatorBeacon, "fernlet.mesh.coordinator.beacon.v1"),
            payload(.inspectorEcho, "fernlet.diagnostic.echo.v1")
        ]
    }

    /// A payload row: the field names the case, today's accessor is the case's `rawValue`.
    private static func payload(_ type: PayloadType, _ frozen: String) -> VocabularyGoldenRow {
        VocabularyGoldenRow(field: "payloadType.\(type)", frozen: frozen, today: type.rawValue)
    }

    /// The table is exactly `PayloadType`'s cases: 55 rows, 55 cases, one set. A new payload type
    /// fails here until it gets a row.
    @Test func thePayloadTableIsExactlyTheTypesCases() {
        let rows = Self.payloadRows
        #expect(rows.count == 55, "the payload table has \(rows.count) rows")
        #expect(PayloadType.allCases.count == 55, "PayloadType has \(PayloadType.allCases.count) cases")
        let frozen = Set(rows.map(\.frozen))
        #expect(frozen.count == rows.count, "two payload rows share a token")
        let shipped = Set(PayloadType.allCases.map(\.rawValue))
        #expect(frozen == shipped, """
            tokens no row holds: \(shipped.subtracting(frozen).sorted()); \
            rows no case spells: \(frozen.subtracting(shipped).sorted())
            """)
    }

    /// Every token, byte for byte, both ways: today's accessor spells the literal, and the literal
    /// decodes to the case whose row it is — what a receiver does with an envelope's `payloadType`.
    @Test func everyPayloadTokenIsItsFrozenSpelling() {
        #expect(Self.expectFrozen(Self.payloadRows) == 55)
        // R2: bounded by the 55 rows.
        for row in Self.payloadRows {
            let decoded = PayloadType(rawValue: row.frozen).map { "payloadType.\($0)" }
            #expect(decoded == row.field, "\(row.frozen) decodes to \(decoded ?? "no case"), not \(row.field)")
        }
    }

    // MARK: Group 2 — the sealing rule, by behaviour

    /// The 17 tokens an envelope must carry sealed. `FernletIdentityEnvelope.sealingRequiredTypes` is
    /// private to the envelope, so this set is held to what `verify` does with each token rather
    /// than to the declaration (which `SealedPayloadFramingTests` reads off disk for its own wall).
    static let sealingRequiredTokens: Set<String> = [
        "fernlet.verify.challenge.v1", "fernlet.verify.response.v1",
        "fernlet.trainer.plan.v1", "fernlet.trainer.plan.delta.v1",
        "fernlet.workout.completion.v1", "fernlet.workout.live.v1",
        "fernlet.friend.photo.v1", "fernlet.recipe.share.v1", "fernlet.clothing.catalog.v1",
        "fernlet.friend.heart.v1", "fernlet.message.temp.v1", "fernlet.item.report.v1",
        "fernlet.friend.state.v1", "fernlet.activity.offer.v1", "fernlet.activity.join.grant.v1",
        "fernlet.activity.roster.v1", "fernlet.activity.sync.v1"
    ]

    /// A token no build has ever spelled.
    static let unknownToken = "example.unknown.v1"

    /// The set is seventeen of the table's tokens.
    @Test func theSealingSetIsSeventeenOfTheTablesTokens() {
        #expect(Self.sealingRequiredTokens.count == 17)
        let table = Set(Self.payloadRows.map(\.frozen))
        #expect(Self.sealingRequiredTokens.isSubset(of: table),
                "sealing tokens the table does not hold: \(Self.sealingRequiredTokens.subtracting(table).sorted())")
    }

    /// For every one of the 55 tokens, an envelope signed UNSEALED under a real identity is refused
    /// with `.sealingRequired` exactly when its token is in the set, and otherwise verifies and hands
    /// back its payload: the rule's members and the point that enforces it, pinned together.
    @Test func anUnsealedEnvelopeIsRefusedExactlyWhenItsTokenRequiresSealing() throws {
        let service = Self.isolatedIdentityService()
        defer { KeychainItem.deleteAll(service: service) }
        let identity = IdentityService(namespace: .fernlet, keychainService: service)
        try identity.ensureProvisioned()
        let cache = ReplayCache()
        var refused: Set<String> = []
        // R2: bounded by the 55 rows.
        for row in Self.payloadRows {
            let type = try #require(PayloadType(rawValue: row.frozen), "\(row.field) decodes to no case")
            let payload = Data(row.field.utf8)
            let envelope = try FernletIdentityEnvelope.signed(
                identityService: identity, senderDisplayName: "", payloadType: type,
                payloadEncryption: .none, payloadSummary: PayloadSummary(title: row.frozen), payload: payload)
            do {
                let opened = try envelope.verify(identityService: identity, replayCache: cache)
                #expect(opened == payload, "\(row.frozen) verified unsealed but handed back other bytes")
            } catch FernletIdentityEnvelope.VerifyError.sealingRequired {
                refused.insert(row.frozen)
            }
        }
        #expect(refused == Self.sealingRequiredTokens, """
            refused but not frozen as sealing-required: \(refused.subtracting(Self.sealingRequiredTokens).sorted()); \
            frozen as sealing-required but verified unsealed: \(Self.sealingRequiredTokens.subtracting(refused).sorted())
            """)
    }

    /// A token this build has no case for verifies unsealed — the build has no sealing rule for a type
    /// it does not know — and is parked: `isUnknownPayloadType`, no case, and empty bytes back.
    @Test func anUnknownTokenVerifiesUnsealedButIsParked() throws {
        let service = Self.isolatedIdentityService()
        defer { KeychainItem.deleteAll(service: service) }
        let identity = IdentityService(namespace: .fernlet, keychainService: service)
        try identity.ensureProvisioned()
        var envelope = FernletIdentityEnvelope(
            schemaVersion: FernletIdentityEnvelope.currentSchemaVersion, envelopeID: UUID(),
            senderSigningPublicKey: identity.localSigningPublicKey,
            senderKeyAgreementPublicKey: identity.localKeyAgreementPublicKey,
            senderDisplayName: "", recipientFingerprint: nil, payloadTypeToken: Self.unknownToken,
            payloadEncryption: .none, payloadSummary: PayloadSummary(title: Self.unknownToken),
            payload: Data("parked".utf8), createdAt: Date(), expiresAt: nil, signature: Data())
        envelope.signature = try identity.sign(
            canonicalBytes(for: envelope, in: .fernlet),
            purpose: ProximityNamespace.fernlet.family.purposes.signature.identityEnvelopeV2)
        #expect(envelope.isUnknownPayloadType && envelope.payloadType == nil, "\(Self.unknownToken) decoded to a case")
        let opened = try envelope.verify(identityService: identity, replayCache: ReplayCache())
        #expect(opened.isEmpty, "a parked type handed back \(opened.count) bytes")
    }

    // MARK: Group 3 — the capabilities

    /// The nine capability tokens, implicit case names with no literal in their declaration — so a
    /// renamed case silently renames a wire token, which these rows refuse.
    static var capabilityRows: [VocabularyGoldenRow] {
        [
            capability(.photos, "photos"),
            capability(.shop, "shop"),
            capability(.hearts, "hearts"),
            capability(.messages, "messages"),
            capability(.moderation, "moderation"),
            capability(.friendState, "friendState"),
            capability(.activities, "activities"),
            capability(.wire2, "wire2"),
            capability(.heartsAway, "heartsAway")
        ]
    }

    /// The coordinator's receive bounds on a peer's capability list.
    static var capabilityBoundNumbers: [VocabularyGoldenNumber] {
        [
            VocabularyGoldenNumber(field: "capability.maxAdvertised", frozen: 18,
                                   today: ProximityCoordinator.maxAdvertisedCapabilities),
            VocabularyGoldenNumber(field: "capability.maxTokenLength", frozen: 32,
                                   today: ProximityCoordinator.maxCapabilityTokenLength)
        ]
    }

    /// A capability row: the field names the case, today's accessor is its `rawValue`.
    private static func capability(_ capability: ProximityCapability, _ frozen: String) -> VocabularyGoldenRow {
        VocabularyGoldenRow(field: "capability.\(capability)", frozen: frozen, today: capability.rawValue)
    }

    /// The table is exactly `ProximityCapability`'s cases, and every token is its frozen spelling.
    @Test func everyCapabilityIsItsFrozenSpelling() {
        let rows = Self.capabilityRows
        #expect(rows.count == ProximityCapability.allCases.count, "\(ProximityCapability.allCases.count) capabilities")
        #expect(Set(rows.map(\.frozen)) == Set(ProximityCapability.allCases.map(\.rawValue)))
        #expect(Self.expectFrozen(rows) == 9)
        // R2: bounded by the nine rows.
        for row in rows {
            #expect(ProximityCapability(rawValue: row.frozen).map { "capability.\($0)" } == row.field,
                    "\(row.frozen) does not decode to \(row.field)")
        }
    }

    /// The bounds' two numbers, and by behaviour the cut: an introduction listing 30 tokens of 40
    /// characters leaves the coordinator holding the first 18, each cut to its first 32 characters.
    @Test func theCoordinatorKeepsEighteenTokensEachCutToThirtyTwoCharacters() async throws {
        #expect(Self.expectFrozen(Self.capabilityBoundNumbers) == 2)
        let kept = Self.frozenNumber("capability.maxAdvertised")
        let length = Self.frozenNumber("capability.maxTokenLength")
        let advertised = (0..<30).map {
            String(format: "capability-token-%02d-", $0).padding(toLength: 40, withPad: "x", startingAt: 0)
        }
        let rig = try VocabularyCoordinatorRig()
        defer { rig.forgetKeychainRows() }
        let body = VocabularyCoordinatorRig.IntroductionBody(rangingMode: "rssi", capabilities: advertised)
        let peer = try await rig.handshake(payload: JSONEncoder().encode(body))
        await rig.coordinator.cancel()
        let built = try #require(peer, "the handshake reached the manual-commit gate")
        let held = try #require(built.capabilities, "the coordinator dropped the list")
        #expect(held == advertised.prefix(kept).map { String($0.prefix(length)) }, "the coordinator kept \(held)")
    }

    /// A peer whose introduction carries NO capability list is treated as supporting photos and
    /// nothing else — where `PeerIdentity` decides it, on the identity the coordinator builds from
    /// such an introduction, and where the mesh's seats decide it. An empty list is not that peer.
    @Test func aPeerWithNoCapabilityListSupportsExactlyPhotos() async throws {
        let photos = Self.frozen("capability.photos")
        let legacy = Self.peerIdentity(capabilities: nil)
        let empty = Self.peerIdentity(capabilities: [])
        // R2: bounded by the nine capabilities.
        for capability in ProximityCapability.allCases {
            #expect(legacy.supports(capability) == (capability.rawValue == photos), "a legacy peer and \(capability)")
            #expect(!empty.supports(capability), "a peer that listed nothing supports \(capability)")
        }
        let rig = try VocabularyCoordinatorRig()
        defer { rig.forgetKeychainRows() }
        let quiet = VocabularyCoordinatorRig.IntroductionBody(rangingMode: "rssi", capabilities: nil)
        let peer = try await rig.handshake(payload: JSONEncoder().encode(quiet))
        await rig.coordinator.cancel()
        let built = try #require(peer, "the handshake reached the manual-commit gate")
        #expect(built.capabilities == nil, "an introduction with no list built \(built.capabilities ?? [])")
        let mesh = MeshNameWithholdingRig()
        #expect(!mesh.manager.slots.isEmpty, "the mesh rig seats its peers")
        // R2: bounded by the rig's three seats × nine capabilities.
        for slot in mesh.manager.slots {
            #expect(slot.peerCapabilities == nil, "the rig's seats carry no list")
            for capability in ProximityCapability.allCases {
                #expect(slot.supports(capability) == (capability.rawValue == photos), "a legacy seat and \(capability)")
            }
        }
    }

    /// `wire2`'s role: a coordinator whose peer advertised the `wire2` token frames every body it
    /// seals (a frame tag, padded, which only a `.wire2` open undoes), and one whose peer did not
    /// seals the body as it is.
    @Test func aSessionBetweenTwoWire2PeersFramesItsSealedBodies() async throws {
        let body = Data(#"{"name":"Soup"}"#.utf8)
        let framed = try await Self.sealedBody(body, peerAdvertising: [Self.frozen("capability.wire2")])
        let plain = try await Self.sealedBody(body, peerAdvertising: [])
        #expect(SealedPayloadFraming.hasFrameTag(framed.legacy) && framed.legacy != body,
                "a wire2 peer was sent an unframed body: \(Self.hex(framed.legacy.prefix(8)))")
        #expect(framed.wire2 == body, "the wire2 open did not recover the body")
        #expect(plain.legacy == body, "a peer without wire2 was sent a framed body: \(Self.hex(plain.legacy.prefix(8)))")
    }

    /// Runs a session to the commit with a peer advertising `capabilities`, has the coordinator send
    /// `body` sealed, and opens what it sent as a legacy and as a wire2 receiver would.
    private static func sealedBody(
        _ body: Data, peerAdvertising capabilities: [String]
    ) async throws -> (legacy: Data, wire2: Data) {
        let rig = try VocabularyCoordinatorRig()
        defer { rig.forgetKeychainRows() }
        let introduction = VocabularyCoordinatorRig.IntroductionBody(rangingMode: "rssi", capabilities: capabilities)
        let peer = try await rig.handshake(payload: JSONEncoder().encode(introduction))
        _ = try #require(peer, "the handshake reached the manual-commit gate")
        await rig.coordinator.commitManualProximity()
        try await rig.coordinator.sendPayload(
            type: .recipeShare, summary: PayloadSummary(title: "Recipe share"), payload: body, sealed: true)
        let envelopes = try rig.sentEnvelopes()
        await rig.coordinator.cancel()
        let sent = try #require(envelopes.last(where: { $0.payloadType == .recipeShare }), "the body was never sent")
        let from = sent.senderKeyAgreementPublicKey
        let legacy = try rig.remoteIdentity.open(sent.payload, from: from, format: .legacy)
        let wire2 = try rig.remoteIdentity.open(sent.payload, from: from, format: .wire2)
        return (legacy, wire2)
    }

    /// A handshake-verified identity with `capabilities` and nothing else of interest.
    private static func peerIdentity(capabilities: [String]?) -> ProximityCoordinator.PeerIdentity {
        ProximityCoordinator.PeerIdentity(
            id: UUID(), displayName: "", signingPublicKey: Data(repeating: 0x01, count: 32),
            keyAgreementPublicKey: Data(repeating: 0x02, count: 32), fingerprint: "0102030405060708",
            rangingMode: .rssi, firstSeenAt: Date(timeIntervalSince1970: 1_700_000_000), capabilities: capabilities)
    }

    // MARK: Group 4 — the session enums

    /// `ProximityMode`, `ProximityRole` and `ProximityRangingMode`: persisted in the trust vault and the
    /// session log, and the ranging mode signed into every introduction's body.
    static var sessionEnumRows: [VocabularyGoldenRow] {
        [
            VocabularyGoldenRow(field: "mode.trainer", frozen: "trainer", today: ProximityMode.trainer.rawValue),
            VocabularyGoldenRow(field: "mode.friend", frozen: "friend", today: ProximityMode.friend.rawValue),
            VocabularyGoldenRow(field: "role.advertiser", frozen: "advertiser", today: ProximityRole.advertiser.rawValue),
            VocabularyGoldenRow(field: "role.browser", frozen: "browser", today: ProximityRole.browser.rawValue),
            VocabularyGoldenRow(field: "rangingMode.uwb", frozen: "uwb", today: ProximityRangingMode.uwb.rawValue),
            VocabularyGoldenRow(field: "rangingMode.rssi", frozen: "rssi", today: ProximityRangingMode.rssi.rawValue),
            VocabularyGoldenRow(field: "rangingMode.none", frozen: "none", today: ProximityRangingMode.none.rawValue)
        ]
    }

    /// Every value both ways: the case spells the literal, and the literal decodes to the case.
    @Test func everySessionEnumIsItsFrozenSpellingBothWays() {
        #expect(Self.expectFrozen(Self.sessionEnumRows) == 7)
        #expect(ProximityMode(rawValue: Self.frozen("mode.trainer")) == .trainer)
        #expect(ProximityMode(rawValue: Self.frozen("mode.friend")) == .friend)
        #expect(ProximityRole(rawValue: Self.frozen("role.advertiser")) == .advertiser)
        #expect(ProximityRole(rawValue: Self.frozen("role.browser")) == .browser)
        #expect(ProximityRangingMode(rawValue: Self.frozen("rangingMode.uwb")) == .uwb)
        #expect(ProximityRangingMode(rawValue: Self.frozen("rangingMode.rssi")) == .rssi)
        #expect(ProximityRangingMode(rawValue: Self.frozen("rangingMode.none")) == ProximityRangingMode.none)
    }

    // MARK: Group 5 — the membership record kinds

    /// The four record kinds. Three are spelled like a signature label and the admission kind is
    /// not; ProximityNamespaceGoldenTests group 3 holds those three equal to their labels and the
    /// fourth by literal. Each kind is hashed into the signed inventory digest, kind first.
    static var recordKindRows: [VocabularyGoldenRow] {
        [
            recordKind(.admission, "fernlet.mesh.member-admission.v1"),
            recordKind(.departure, "fernlet.mesh.member-departure.v1"),
            recordKind(.removal, "fernlet.mesh.member-removal.v1"),
            recordKind(.termination, "fernlet.mesh.terminated.v1")
        ]
    }

    /// A record-kind row: the field names the case, today's accessor is its `rawValue`.
    private static func recordKind(_ kind: MeshMembershipRecordKind, _ frozen: String) -> VocabularyGoldenRow {
        VocabularyGoldenRow(field: "recordKind.\(kind)", frozen: frozen, today: kind.rawValue)
    }

    /// The table is exactly the kinds, and every kind is its frozen spelling.
    @Test func everyRecordKindIsItsFrozenSpelling() {
        #expect(Self.recordKindRows.count == MeshMembershipRecordKind.allCases.count)
        #expect(Set(Self.recordKindRows.map(\.frozen)) == Set(MeshMembershipRecordKind.allCases.map(\.rawValue)))
        #expect(Self.expectFrozen(Self.recordKindRows) == 4)
    }

    /// The digest lists a ledger's records kind first, by the kind token's bytes: the fixture's
    /// instants run opposite to its kinds, and the order that comes out is the kinds' — the frozen
    /// tokens sorted bytewise — not the clock's.
    @Test func theDigestOrdersRecordsByKindTokenBeforeTime() {
        let identities = MeshInventoryDigest.identities(in: Self.fourKindLedger())
        let byBytes = Self.recordKindRows.map(\.frozen).sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        #expect(identities.map(\.kind.rawValue) == byBytes, "the digest's kind order is \(identities.map(\.kind.rawValue))")
        let instants = identities.map(\.occurredAt)
        #expect(instants == instants.sorted(by: >), "the fixture no longer runs its instants against its kinds")
    }

    /// One known answer for the inventory digest over a ledger holding one record of each kind: the
    /// preimage `canonicalInventoryDigestBytes(for:in: .fernlet)` writes and the records hash the
    /// digest takes of it. (`MeshMembershipEventGoldenTests` pins the one-admission ledger's hash.)
    @Test func aLedgerOfOneRecordPerKindDigestsToItsKnownAnswer() {
        let ledger = Self.fourKindLedger()
        let preimage = canonicalInventoryDigestBytes(for: MeshInventoryDigest.identities(in: ledger), in: .fernlet)
        #expect(Self.hex(preimage) == Self.fourKindPreimageHex, "actual preimage hex = \(Self.hex(preimage))")
        let digest = MeshInventoryDigest(meshID: Self.uuid("1F1F1F1F-2E2E-4D4D-8C8C-0B0B0B0B0B0B"),
                                         ledger: ledger, purposes: .fernlet)
        #expect(Self.hex(digest.recordsHash) == Self.fourKindRecordsHashHex,
                "actual records hash = \(Self.hex(digest.recordsHash))")
        let counts: [Int] = [digest.admissionCount, digest.departureCount, digest.removalCount, digest.terminationCount]
        #expect(counts == [1, 1, 1, 1], "the digest counts \(counts) records per kind")
    }

    /// lp(`fernlet.mesh.inventory-digest.hash.v1`) ‖ u64 4 ‖ per record, in kind order:
    /// lp(kind) ‖ lp(member) ‖ i64 seconds ‖ lp(author) ‖ lp(signature).
    static let fourKindPreimageHex = [
        "00000000000000256665726e6c65742e6d6573682e696e76656e746f72792d6469676573742e686173682e7631000000",
        "000000000400000000000000206665726e6c65742e6d6573682e6d656d6265722d61646d697373696f6e2e7631000000",
        "000000000b66702d61646d6974746564000000006553f1f0000000000000000b66702d61646d69747465720000000000",
        "000004a1a1a1a100000000000000206665726e6c65742e6d6573682e6d656d6265722d6465706172747572652e763100",
        "0000000000000b66702d6465706172746564000000006553f1b4000000000000000b66702d6465706172746564000000",
        "0000000004d1d1d1d1000000000000001e6665726e6c65742e6d6573682e6d656d6265722d72656d6f76616c2e763100",
        "0000000000000a66702d72656d6f766564000000006553f178000000000000000a66702d74616c6c6965720000000000",
        "000004e1e1e1e1000000000000001a6665726e6c65742e6d6573682e7465726d696e617465642e763100000000000000",
        "0866702d66696e616c000000006553f13c000000000000000866702d66696e616c0000000000000004f1f1f1f1"
    ].joined()

    /// SHA-256 of ``fourKindPreimageHex``'s bytes.
    static let fourKindRecordsHashHex = "8289ac71f5efc08a63c689d44fc4ece8e2fdc9459aca219a62d274315985b975"

    /// One record of each kind, their instants in the REVERSE of the kind order (the termination
    /// earliest), so a digest that sorted by time would write a different preimage.
    static func fourKindLedger() -> MeshMembershipLedger {
        let meshID = uuid("1F1F1F1F-2E2E-4D4D-8C8C-0B0B0B0B0B0B")
        let admission = SignedAdmissionRecord(token: MeshAdmissionToken(
            meshID: meshID, joinerFingerprint: "fp-admitted", joinerSigningPublicKey: Data(repeating: 0x0A, count: 32),
            admitterFingerprint: "fp-admitter", grantedAt: at(240), expiresAt: at(7_440),
            admitterSigningPublicKey: Data(repeating: 0x0B, count: 32), admitterSignature: Data(repeating: 0xA1, count: 4)))
        let departure = SignedDepartureRecord(meshID: meshID, memberFingerprint: "fp-departed", occurredAt: at(180),
                                              signature: Data(repeating: 0xD1, count: 4))
        let removal = SignedRemovalRecord(meshID: meshID, memberFingerprint: "fp-removed",
                                          proposalID: uuid("2A2A2A2A-3B3B-4C4C-8D8D-0E0E0E0E0E0E"),
                                          voterFingerprints: ["fp-a", "fp-b"], occurredAt: at(120),
                                          authorFingerprint: "fp-tallier", signature: Data(repeating: 0xE1, count: 4))
        let termination = SignedTerminationRecord(meshID: meshID, memberFingerprint: "fp-final",
                                                  rosterAtSigning: ["fp-final", "fp-a"], occurredAt: at(60),
                                                  signature: Data(repeating: 0xF1, count: 4))
        return MeshMembershipLedger(
            admissions: MeshMembershipRecordSet([admission]), departures: MeshMembershipRecordSet([departure]),
            removals: MeshMembershipRecordSet([removal]), terminations: MeshMembershipRecordSet([termination]))
    }

    // MARK: Group 6 — the routed types

    /// The four routed-type tokens — the three the registry carries rows for, and the reserved
    /// `control` one. `MeshRoutedAckStageTests` pins the same spellings, and
    /// `MeshRoutedTypeRegistryTests` the registry's tokens and every column of its three rows.
    static var routedTypeRows: [VocabularyGoldenRow] {
        [
            VocabularyGoldenRow(field: "routedType.photo", frozen: "fernlet.mesh.routed-type.photo.v1",
                                today: MeshRoutedTypeToken.photo),
            VocabularyGoldenRow(field: "routedType.tempMessage", frozen: "fernlet.mesh.routed-type.temp-message.v1",
                                today: MeshRoutedTypeToken.tempMessage),
            VocabularyGoldenRow(field: "routedType.heart", frozen: "fernlet.mesh.routed-type.heart.v1",
                                today: MeshRoutedTypeToken.heart),
            VocabularyGoldenRow(field: "routedType.control", frozen: "fernlet.mesh.routed-type.control.v1",
                                today: MeshRoutedTypeToken.control)
        ]
    }

    /// The heart row's cap: framed header 8 + 512, seal overhead 5 + 12 + 16 = 553 bytes. The photo
    /// row's 10 551 337 (`MeshRoutedTypeRegistryTests`) and the text row's 9 065
    /// (`MeshRoutedTextBodyTests`) already have literal pins; the heart row's had only its formula.
    static var routedTypeNumbers: [VocabularyGoldenNumber] {
        [VocabularyGoldenNumber(field: "routedType.heart.maxItemByteCount", frozen: 553,
                                today: registeredCap(MeshRoutedTypeToken.heart))]
    }

    /// The registry's cap for `token`, or -1 when it has no row.
    private static func registeredCap(_ token: String) -> Int {
        MeshRoutedTypeRegistry.increment1.entry(for: token).map { Int(clamping: $0.maxItemByteCount) } ?? -1
    }

    /// Every routed-type token is its frozen spelling, and the heart row's cap its frozen bytes.
    @Test func everyRoutedTypeTokenAndTheHeartCapIsFrozen() {
        #expect(Self.expectFrozen(Self.routedTypeRows) == 4)
        #expect(Self.expectFrozen(Self.routedTypeNumbers) == 1)
    }

    // MARK: Group 7 — the coordinator's session messages

    /// One message the coordinator signs: the payload row whose token it carries, and its title.
    struct SessionMessage: Sendable {
        /// What the message is, for failure messages.
        let name: String
        /// The group 1 row holding the token the message carries.
        let tokenField: String
        /// The frozen `PayloadSummary.title`. No accessor: each is an inline literal at its send site.
        let title: String
    }

    /// The four messages a friend-mode coordinator signs on its own, in the order a session sends them.
    static let sessionMessages: [SessionMessage] = [
        SessionMessage(name: "identity introduction", tokenField: "payloadType.identityIntroduction", title: "Hello"),
        SessionMessage(name: "identity acknowledgement", tokenField: "payloadType.identityAcknowledge",
                       title: "Identity acknowledged"),
        SessionMessage(name: "heartbeat", tokenField: "payloadType.sessionHeartbeat", title: "Heartbeat"),
        SessionMessage(name: "heartbeat reply", tokenField: "payloadType.sessionHeartbeat", title: "Heartbeat ack")
    ]

    /// A live coordinator, driven over `FakePeerTransport` through the introduction, the commit and a
    /// peer's ping, signs its four messages under their frozen tokens and titles — and the two it
    /// sends after the commit disclose the display name the rig gave it, the two before it nothing.
    @Test func theCoordinatorSignsItsFourSessionMessagesUnderTheirTokensAndTitles() async throws {
        let rig = try VocabularyCoordinatorRig()
        defer { rig.forgetKeychainRows() }
        let quiet = VocabularyCoordinatorRig.IntroductionBody(rangingMode: "rssi", capabilities: nil)
        let peer = try await rig.handshake(payload: JSONEncoder().encode(quiet))
        _ = try #require(peer, "the handshake reached the manual-commit gate")
        await rig.coordinator.commitManualProximity()
        await VocabularyCoordinatorRig.settle { rig.local.sentFrames.count >= 3 }
        try await rig.deliver(rig.heartbeatPing())
        await VocabularyCoordinatorRig.settle { rig.local.sentFrames.count >= 4 }
        let sent = try rig.sentEnvelopes()
        await rig.coordinator.cancel()
        #expect(sent.count == Self.sessionMessages.count, "the coordinator sent \(sent.map(\.payloadTypeToken))")
        // R2: bounded by the four messages.
        for (message, envelope) in zip(Self.sessionMessages, sent) {
            #expect(envelope.payloadTypeToken == Self.frozen(message.tokenField),
                    "the \(message.name) carries \(envelope.payloadTypeToken)")
            #expect(envelope.payloadSummary.title == message.title,
                    "the \(message.name) is titled \(envelope.payloadSummary.title)")
        }
        let name = VocabularyCoordinatorRig.displayName
        #expect(sent.map(\.senderDisplayName) == ["", "", name, name], "they named \(sent.map(\.senderDisplayName))")
    }

    /// The mesh signs every envelope at one door, titling its summary with its payload token: the
    /// coordinator beacon reaches all three of the rig's seats under the frozen beacon token, as its
    /// title too.
    @Test func aMeshEnvelopesSummaryTitleIsItsPayloadToken() async throws {
        let rig = MeshNameWithholdingRig()
        rig.manager.broadcastCoordinatorBeaconForTesting()
        await rig.drain()
        let sent = try rig.envelopes(on: rig.memberA) + rig.envelopes(on: rig.memberB) + rig.envelopes(on: rig.stranger)
        let beacon = Self.frozen("payloadType.meshCoordinatorBeacon")
        #expect(sent.filter { $0.payloadTypeToken == beacon }.count == 3, "beacons sent: \(sent.map(\.payloadTypeToken))")
        // R2: bounded by the frames the three seats were sent.
        for envelope in sent {
            #expect(envelope.payloadSummary.title == envelope.payloadTypeToken,
                    "a mesh \(envelope.payloadTypeToken) envelope is titled \(envelope.payloadSummary.title)")
        }
    }

    // MARK: Group 8 — the presentation strings

    /// The strings that name Fernlet to a scanner, a TLS stack or a discovery dictionary without being
    /// a protocol label: free to change per host, frozen until a host supplies its own. The first four
    /// are read off `.fernlet`'s radios, where the radios and the name display take them from; the
    /// namespace carries the presence prefix and its separator as one field, so their two rows read
    /// its two parts. The coordinator's display default and its two service types were deleted, not
    /// moved: "deleted: no value" rows, which no accessor can read and
    /// ``theCoordinatorsDisplayDefaultAndServiceTypesAreDeleted()`` proves reach no transport.
    static var presentationRows: [VocabularyGoldenRow] {
        let radios = ProximityNamespace.fernlet.family.radios
        return [
            VocabularyGoldenRow(field: "presentation.meshInstanceNamePrefix", frozen: "fernlet-mesh-",
                                today: radios.meshInstanceNamePrefix),
            VocabularyGoldenRow(field: "presentation.presenceInstanceNamePrefix", frozen: "fn",
                                today: String(radios.presenceInstanceNamePrefix.dropLast())),
            VocabularyGoldenRow(field: "presentation.presenceInstanceNameSeparator", frozen: "-",
                                today: String(radios.presenceInstanceNamePrefix.suffix(1))),
            VocabularyGoldenRow(field: "presentation.tlsCommonName", frozen: "fernlet-mesh",
                                today: radios.tlsCommonName),
            VocabularyGoldenRow(field: "presentation.coordinatorDisplayName", frozen: "Fernlet", today: nil),
            VocabularyGoldenRow(field: "presentation.trainerServiceType", frozen: "fernlet-coach", today: nil),
            VocabularyGoldenRow(field: "presentation.friendServiceType", frozen: "fernlet-friend", today: nil)
        ]
    }

    /// The four with an accessor, byte for byte. The three deleted values have none.
    @Test func everyPresentationStringIsItsFrozenSpelling() {
        #expect(Self.expectFrozen(Self.presentationRows) == 4)
    }

    /// What the minting doors mint under `.fernlet`'s strings carries the frozen spellings: a mesh
    /// instance name is the prefix and 12 lowercase hex, a presence one the prefix, the separator and
    /// 16 (`fn-0123456789abcdef` from fixed entropy, every one as long as the presence length says),
    /// and a minted certificate's subject common name is the frozen token.
    @Test func theMintedNamesAndCertificateCarryTheFrozenSpellings() throws {
        let radios = ProximityNamespace.fernlet.family.radios
        let meshPattern = try Regex(#"^fernlet-mesh-[0-9a-f]{12}$"#)
        let presencePattern = try Regex(#"^fn-[0-9a-f]{16}$"#)
        let meshName = MeshLinkAdvertisement.randomInstanceName(prefix: radios.meshInstanceNamePrefix)
        #expect(meshName.wholeMatch(of: meshPattern) != nil, "a mesh instance name: \(meshName)")
        let presence = Self.frozen("presentation.presenceInstanceNamePrefix")
            + Self.frozen("presentation.presenceInstanceNameSeparator")
        let fixed = try PresenceEpochPosture.instanceName(
            prefix: radios.presenceInstanceNamePrefix, entropy: { _ in [0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF] })
        #expect(fixed == presence + "0123456789abcdef", "fixed entropy minted \(fixed)")
        let posture = try PresenceEpochPosture.minted(
            at: Date(), instanceNamePrefix: radios.presenceInstanceNamePrefix, commonName: radios.tlsCommonName)
        #expect(posture.instanceName.wholeMatch(of: presencePattern) != nil, "a presence instance name: \(posture.instanceName)")
        #expect(PresenceEpochPosture.instanceNameLength(prefix: radios.presenceInstanceNamePrefix) == presence.count + 16)
        let minted = try EphemeralMeshTLSIdentity.mint(commonName: radios.tlsCommonName)
        let named = Self.commonName(of: minted.certificateDER)
        #expect(named == Self.frozen("presentation.tlsCommonName"), "the certificate names \(named ?? "nothing")")
    }

    /// The consumers read the strings off the namespace they hold, never off a constant. Built from
    /// `.fernlet`, the mesh radio keeps the frozen prefix and common name as its copies, the recipe
    /// radio wears a posture named and certified under them, and the presence manager's own posture
    /// mint names and certifies its posture, and the one it rotates into at the next boundary, under
    /// the frozen presence prefix and common name. Built from a namespace that differs from `.fernlet`
    /// in its three presentation strings alone, each carries that namespace's strings instead: no
    /// consumer keeps a Fernlet spelling of its own, the presence prefix included, which spells no
    /// `fernlet` for the boundary wall to catch.
    @Test func theRadiosAndThePresenceManagerMintUnderTheirNamespacesStrings() throws {
        let frozenName = Self.frozen("presentation.tlsCommonName")
        let meshPattern = try Regex(#"^fernlet-mesh-[0-9a-f]{12}$"#)
        let presencePattern = try Regex(#"^fn-[0-9a-f]{16}$"#)
        let fernlet = try Self.presentationReadings(of: .fernlet)
        #expect(fernlet.meshPrefix == Self.frozen("presentation.meshInstanceNamePrefix") && fernlet.meshCommonName == frozenName,
                "the mesh radio keeps \(fernlet.meshPrefix) and \(fernlet.meshCommonName)")
        #expect(fernlet.recipeName.wholeMatch(of: meshPattern) != nil && fernlet.recipeCommonName == frozenName,
                "the recipe radio wears \(fernlet.recipeName), certified as \(fernlet.recipeCommonName ?? "nothing")")
        #expect(fernlet.presenceNames.count == 2 && fernlet.presenceNames.allSatisfy { $0.wholeMatch(of: presencePattern) != nil },
                "the presence manager minted \(fernlet.presenceNames)")
        #expect(fernlet.presenceCommonNames == [frozenName, frozenName], "its certificates name \(fernlet.presenceCommonNames)")

        let renamed = Self.renamedPresentationNamespace()
        let radios = renamed.family.radios
        #expect(renamed.soundness == .sound, "the renamed namespace is unsound: \(renamed.soundness)")
        let other = try Self.presentationReadings(of: renamed)
        let presenceLength = PresenceEpochPosture.instanceNameLength(prefix: radios.presenceInstanceNamePrefix)
        #expect(other.meshPrefix == radios.meshInstanceNamePrefix && other.meshCommonName == radios.tlsCommonName,
                "a mesh radio of another namespace keeps \(other.meshPrefix) and \(other.meshCommonName)")
        #expect(other.recipeName.hasPrefix(radios.meshInstanceNamePrefix) && other.recipeCommonName == radios.tlsCommonName,
                "a recipe radio of another namespace wears \(other.recipeName) (\(other.recipeCommonName ?? "nothing"))")
        #expect(other.presenceNames.count == 2 && other.presenceNames.allSatisfy {
            $0.hasPrefix(radios.presenceInstanceNamePrefix) && $0.count == presenceLength
        }, "a presence manager of another namespace minted \(other.presenceNames)")
        #expect(other.presenceCommonNames == [radios.tlsCommonName, radios.tlsCommonName],
                "its certificates name \(other.presenceCommonNames)")
    }

    /// The name display hides what the radios mint, by the namespace it is handed. Under `.fernlet`
    /// a name that begins with the frozen mesh prefix (whole, upper-cased, or in the participant
    /// projection's 24-character form) reads as no name while a name that only mentions Fernlet is
    /// one; under the renamed namespace its own prefix is hidden and Fernlet's instance name is text.
    @Test func theNameDisplayHidesTheMeshPrefixOfTheNamespaceItIsHanded() {
        let instanceName = Self.frozen("presentation.meshInstanceNamePrefix") + "0123456789ab"
        let forms = [instanceName, instanceName.uppercased(), ItemNameModeration.moderatedPeerDisplayName(instanceName)]
        // R2: bounded by the three forms.
        for form in forms {
            #expect(PeerNameDisplay.personName(form, fingerprint: nil, in: .fernlet) == nil, "\(form) reads as a name")
        }
        #expect(PeerNameDisplay.personName("Fernlet fan", fingerprint: nil, in: .fernlet) == "Fernlet fan")
        let renamed = Self.renamedPresentationNamespace()
        let ownName = renamed.family.radios.meshInstanceNamePrefix + "0123456789ab"
        #expect(PeerNameDisplay.personName(ownName, fingerprint: nil, in: renamed) == nil, "\(ownName) reads as a name")
        let text = PeerNameDisplay.personName(instanceName, fingerprint: nil, in: renamed)
        #expect(text == ItemNameModeration.sanitizedName(instanceName),
                "under another namespace Fernlet's instance name is text, not hidden: \(text ?? "hidden")")
    }

    /// The coordinator's display default and its two per-mode service types are deleted, not moved,
    /// so their rows read no accessor. A coordinator advertises the name its caller gave it, the rig's,
    /// in trainer mode and on a friend join alike, and hands its transport a discovery dictionary and
    /// nothing else: `PeerTransport`'s discovery doors take no service type, which
    /// `FakePeerTransport`'s conformance holds at compile time. No deleted spelling reaches the
    /// transport either way, and `ProximityNamespaceBoundaryTests` holds the three literals out of
    /// ProximityKit's code.
    @Test func theCoordinatorsDisplayDefaultAndServiceTypesAreDeleted() async throws {
        let rig = try VocabularyCoordinatorRig()
        defer { rig.forgetKeychainRows() }
        await rig.coordinator.begin(role: .advertiser, mode: .trainer)
        let trainer = rig.local.lastDiscoveryInfo ?? [:]
        await rig.coordinator.beginFriendJoin()
        let friend = rig.local.lastDiscoveryInfo ?? [:]
        let browses = rig.local.browseStartCount
        await rig.coordinator.cancel()
        let name = VocabularyCoordinatorRig.displayName
        #expect(trainer["name"] == name && friend["name"] == name,
                "the coordinator advertised \(trainer["name"] ?? "nothing") and \(friend["name"] ?? "nothing")")
        #expect(browses == 1, "a friend join browsed \(browses) times")
        let deleted = ["presentation.coordinatorDisplayName", "presentation.trainerServiceType",
                       "presentation.friendServiceType"].map { Self.frozen($0) }
        #expect(!deleted.contains(""), "a deleted value lost its row")
        // R2: bounded by the two dictionaries' values and the three spellings.
        for value in Array(trainer.values) + Array(friend.values) {
            #expect(!deleted.contains { value.contains($0) }, "the transport was handed \(value)")
        }
    }

    /// What the three consumers of the presentation strings hold and mint when built from one
    /// namespace.
    struct PresentationReadings {
        /// The mesh radio's copy of the instance-name prefix.
        let meshPrefix: String
        /// The mesh radio's copy of the common name.
        let meshCommonName: String
        /// The instance name of the recipe radio's posture.
        let recipeName: String
        /// The common name of the recipe radio's certificate.
        let recipeCommonName: String?
        /// The presence manager's minted posture's name, then its rotated posture's.
        let presenceNames: [String]
        /// The two presence postures' certificates' common names, in the same order.
        let presenceCommonNames: [String?]
    }

    /// Builds the mesh radio, the recipe radio (running without radios) and a presence manager over a
    /// host of `namespace`, and reads what each holds and mints. The manager's posture mint is called
    /// exactly as its epoch tick calls it, for a fresh posture and for the next epoch's rotation; its
    /// identity sits on a throwaway service it never writes.
    static func presentationReadings(of namespace: ProximityNamespace) throws -> PresentationReadings {
        let mesh = NetworkMeshSession(namespace: namespace)
        let recipe = NetworkRecipeShareSession(namespace: namespace)
        let recipePosture = try recipe.runWithoutRadiosForTesting()
        recipe.stop()
        let host = PresentationNamespaceHost(namespace: namespace)
        let ledgerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("VocabularyGolden-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("HeartLedger.json")
        let postures: [PresenceEpochPosture] = try withExtendedLifetime(host) {
            let manager = PresenceManager(
                store: host, ledger: ProximityHeartLedger(fileURL: ledgerURL, now: { Self.at(0) }),
                identity: IdentityService(namespace: namespace, keychainService: Self.isolatedIdentityService()))
            let minted = try manager.postureMint(nil, Self.at(0))
            return [minted, try manager.postureMint(minted, Self.at(IdentityService.presenceEpochSeconds))]
        }
        return PresentationReadings(
            meshPrefix: mesh.instanceNamePrefix, meshCommonName: mesh.tlsCommonName,
            recipeName: recipePosture.instanceName,
            recipeCommonName: Self.commonName(of: recipePosture.tlsIdentity.certificateDER),
            presenceNames: postures.map(\.instanceName),
            presenceCommonNames: postures.map { Self.commonName(of: $0.tlsIdentity.certificateDER) })
    }

    /// `.fernlet` with its three presentation strings replaced by strings of its own and nothing else
    /// changed, so a reader that took a string from anywhere but its namespace would read Fernlet's
    /// where this namespace's belongs.
    static func renamedPresentationNamespace() -> ProximityNamespace {
        let fernlet = ProximityNamespace.fernlet
        let radios = fernlet.family.radios
        return ProximityNamespace(
            family: ProximityNamespace.Family(
                purposes: fernlet.family.purposes,
                radios: ProximityNamespace.Radios(
                    mesh: radios.mesh, presence: radios.presence, recipeShare: radios.recipeShare,
                    meshHeartbeat: radios.meshHeartbeat, meshInstanceNamePrefix: "golden-link-",
                    presenceInstanceNamePrefix: "gl-", tlsCommonName: "golden-link"),
                verifyQR: fernlet.family.verifyQR,
                vocabulary: fernlet.family.vocabulary),
            installation: fernlet.installation)
    }

    // MARK: Group 9 — the trainer export body

    /// The export body's format token.
    static var trainerExportRows: [VocabularyGoldenRow] {
        [VocabularyGoldenRow(field: "trainerExport.format", frozen: "fernlet.trainer.export",
                             today: TrainerExportPayload(bundle: Data()).format)]
    }

    /// Its version and its two size caps: 2 MiB of bundle, and twice that on the wire.
    static var trainerExportNumbers: [VocabularyGoldenNumber] {
        [
            VocabularyGoldenNumber(field: "trainerExport.version", frozen: 1,
                                   today: TrainerExportPayload(bundle: Data()).version),
            VocabularyGoldenNumber(field: "trainerExport.maxBundleBytes", frozen: 2_097_152,
                                   today: TrainerExportPayload.maxBundleBytes),
            VocabularyGoldenNumber(field: "trainerExport.maxTrainerWireBytes", frozen: 4_194_304,
                                   today: TrainerExportPayload.maxTrainerWireBytes)
        ]
    }

    /// A bundle of `{"weeks":4}`, as `JSONEncoder` with sorted keys writes it.
    static let trainerExportJSON = #"{"bundle":"eyJ3ZWVrcyI6NH0=","format":"fernlet.trainer.export","version":1}"#

    /// The body's bytes for a fixed bundle, both ways — and the format and version are checked on
    /// receipt, not merely written: a body one byte off in either is not well formed.
    @Test func theTrainerExportBodyIsItsFrozenBytes() throws {
        #expect(Self.expectFrozen(Self.trainerExportRows) == 1)
        #expect(Self.expectFrozen(Self.trainerExportNumbers) == 3)
        let payload = TrainerExportPayload(bundle: Data(#"{"weeks":4}"#.utf8))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(payload)
        #expect(encoded == Data(Self.trainerExportJSON.utf8), "the body encodes as \(String(decoding: encoded, as: UTF8.self))")
        let decoded = try JSONDecoder().decode(TrainerExportPayload.self, from: Data(Self.trainerExportJSON.utf8))
        #expect(decoded == payload && decoded.isWellFormed, "the golden decodes to \(decoded)")
        let otherFormat = Self.trainerExportJSON.replacingOccurrences(of: "trainer.export", with: "trainer.Export")
        let otherVersion = Self.trainerExportJSON.replacingOccurrences(of: #""version":1"#, with: #""version":2"#)
        // R2: bounded by the two variants.
        for variant in [otherFormat, otherVersion] {
            let parsed = try JSONDecoder().decode(TrainerExportPayload.self, from: Data(variant.utf8))
            #expect(!parsed.isWellFormed, "\(variant) is well formed")
        }
    }

    // MARK: Group 10 — the generic types

    /// The summary's two decode bounds.
    static var summaryBoundNumbers: [VocabularyGoldenNumber] {
        [
            VocabularyGoldenNumber(field: "payloadSummary.maxExtraDetails", frozen: 16, today: PayloadSummary.maxExtraDetails),
            VocabularyGoldenNumber(field: "payloadSummary.maxDetailCharacters", frozen: 200,
                                   today: PayloadSummary.maxDetailCharacters)
        ]
    }

    /// A sealed encryption whose key's base64 is `/+++`, so the two encoders' slash rules show.
    static let sealedEncryption = PayloadEncryption.sealedTo(recipientKeyAgreementPublicKey: Data([0xFF, 0xEF, 0xBE]))

    /// A summary with every field set, its details out of order and one carrying a slash.
    static var fullSummary: PayloadSummary {
        PayloadSummary(title: "Soup", subtitle: "Dinner", itemCount: 3,
                       dateRange: DateRange(start: at(0), end: at(3_600)),
                       extraDetails: ["z": "last", "a": "first", "m": "1/2 cup"])
    }

    /// One envelope's schema-v1 canonical bytes: the legacy encoder's sorted-keys JSON (`/` unescaped,
    /// ISO-8601 dates), the signature blanked. The schema-v2 golden is
    /// `FernletIdentityEnvelopeTests.goldenEnvelopeHex`.
    static let legacyEnvelopeHex = [
        "7b22637265617465644174223a22323032332d31312d31345432323a31333a32305a222c22656e76656c6f7065494422",
        "3a2230413041304130412d314231422d344334432d384438442d324532453245324532453245222c2265787069726573",
        "4174223a22323032332d31312d31355430303a31333a32305a222c227061796c6f6164223a2263474635624739685a43",
        "31696558526c63773d3d222c227061796c6f6164456e6372797074696f6e223a7b227365616c6564546f223a7b227265",
        "63697069656e744b657941677265656d656e745075626c69634b6579223a222f2b2b2b227d7d2c227061796c6f616453",
        "756d6d617279223a7b226461746552616e6765223a7b22656e64223a22323032332d31312d31345432333a31333a3230",
        "5a222c227374617274223a22323032332d31312d31345432323a31333a32305a227d2c22657874726144657461696c73",
        "223a7b2261223a226669727374222c226d223a22312f3220637570222c227a223a226c617374227d2c226974656d436f",
        "756e74223a332c227375627469746c65223a2244696e6e6572222c227469746c65223a22536f7570227d2c227061796c",
        "6f616454797065223a226665726e6c65742e7265636970652e73686172652e7631222c22726563697069656e7446696e",
        "6765727072696e74223a2261626364656630313233343536373839222c22736368656d6156657273696f6e223a312c22",
        "73656e646572446973706c61794e616d65223a22416973686120f09f8cbf222c2273656e6465724b657941677265656d",
        "656e745075626c69634b6579223a224251594843413d3d222c2273656e6465725369676e696e675075626c69634b6579",
        "223a224151494442413d3d222c227369676e6174757265223a22227d"
    ].joined()

    /// `PayloadEncryption.none` under `JSONEncoder` with sorted keys.
    static let encryptionNoneJSON = #"{"none":{}}"#

    /// ``sealedEncryption`` under the same encoder, its slash escaped.
    static let encryptionSealedJSON = #"{"sealedTo":{"recipientKeyAgreementPublicKey":"\/+++"}}"#

    /// ``fullSummary`` under the same encoder, its dates as seconds since 2001.
    static let summaryJSON = [
        #"{"dateRange":{"end":721696400,"start":721692800},"extraDetails":{"a":"first","m":"1\/2 cup","#,
        #""z":"last"},"itemCount":3,"subtitle":"Dinner","title":"Soup"}"#
    ].joined()

    /// The schema-v1 canonical bytes of one fixed envelope, as `legacyCanonicalBytes(for:)` writes them.
    @Test func theSchemaV1CanonicalBytesOfOneEnvelopeAreTheirKnownAnswer() {
        let actual = Self.hex(legacyCanonicalBytes(for: Self.legacyEnvelope()))
        #expect(actual == Self.legacyEnvelopeHex, "actual schema-v1 canonical hex = \(actual)")
    }

    /// Both encryption cases and the full summary encode to their frozen JSON and decode back.
    @Test func theEncryptionAndSummaryEncodeToTheirFrozenJSON() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let none = try encoder.encode(PayloadEncryption.none)
        let sealed = try encoder.encode(Self.sealedEncryption)
        let summary = try encoder.encode(Self.fullSummary)
        let pairs: [(name: String, encoded: Data, golden: String)] = [
            ("PayloadEncryption.none", none, Self.encryptionNoneJSON),
            ("PayloadEncryption.sealedTo", sealed, Self.encryptionSealedJSON),
            ("PayloadSummary", summary, Self.summaryJSON)
        ]
        // R2: bounded by the three values.
        for pair in pairs {
            #expect(pair.encoded == Data(pair.golden.utf8),
                    "\(pair.name) encodes as \(String(decoding: pair.encoded, as: UTF8.self))")
        }
        let decoder = JSONDecoder()
        #expect(try decoder.decode(PayloadEncryption.self, from: Data(Self.encryptionNoneJSON.utf8)) == PayloadEncryption.none)
        #expect(try decoder.decode(PayloadEncryption.self, from: Data(Self.encryptionSealedJSON.utf8)) == Self.sealedEncryption)
        #expect(try decoder.decode(PayloadSummary.self, from: Data(Self.summaryJSON.utf8)) == Self.fullSummary)
    }

    /// A summary at its bounds decodes — 16 details, a 200-character title — and one past either
    /// is refused, so the receiver never holds or renders it.
    @Test func aSummaryDecodesUpToItsBoundsAndNoFurther() throws {
        #expect(Self.expectFrozen(Self.summaryBoundNumbers) == 2)
        let details = Self.frozenNumber("payloadSummary.maxExtraDetails")
        let characters = Self.frozenNumber("payloadSummary.maxDetailCharacters")
        let atBounds = PayloadSummary(title: String(repeating: "t", count: characters), extraDetails: Self.details(details))
        #expect(try Self.roundTrip(atBounds) == atBounds, "a summary at its bounds did not survive its own decode")
        #expect(throws: DecodingError.self, "\(details + 1) detail rows decoded") {
            _ = try Self.roundTrip(PayloadSummary(title: "t", extraDetails: Self.details(details + 1)))
        }
        #expect(throws: DecodingError.self, "a \(characters + 1)-character title decoded") {
            _ = try Self.roundTrip(PayloadSummary(title: String(repeating: "t", count: characters + 1)))
        }
    }

    /// The fixed envelope behind ``legacyEnvelopeHex``: non-ASCII name, a recipient, a sealed
    /// encryption, the full summary, an expiry — and a signature the canonical bytes leave out.
    static func legacyEnvelope() -> FernletIdentityEnvelope {
        FernletIdentityEnvelope(
            schemaVersion: FernletIdentityEnvelope.legacySchemaVersion,
            envelopeID: uuid("0A0A0A0A-1B1B-4C4C-8D8D-2E2E2E2E2E2E"),
            senderSigningPublicKey: Data([0x01, 0x02, 0x03, 0x04]),
            senderKeyAgreementPublicKey: Data([0x05, 0x06, 0x07, 0x08]),
            senderDisplayName: "Aisha \u{1F33F}",
            recipientFingerprint: "abcdef0123456789",
            payloadType: .recipeShare,
            payloadEncryption: sealedEncryption,
            payloadSummary: fullSummary,
            payload: Data("payload-bytes".utf8),
            createdAt: at(0),
            expiresAt: at(7_200),
            signature: Data("left out of the canonical bytes".utf8)
        )
    }

    /// `count` distinct detail rows.
    private static func details(_ count: Int) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (0..<count).map { ("detail-\($0)", "value") })
    }

    /// `summary` through `JSONEncoder` and back through its bounded decode.
    private static func roundTrip(_ summary: PayloadSummary) throws -> PayloadSummary {
        try JSONDecoder().decode(PayloadSummary.self, from: JSONEncoder().encode(summary))
    }

    // MARK: Group 11 — the persisted records that stay Fernlet's

    /// A trusted peer with its mode and report fields set, as the repositories write it.
    static let trustedPeerJSON = [
        #"{"blockedAt":"2023-11-15T00:13:20Z","displayName":"Robin","fingerprint":"a1b2c3d4e5f60718","#,
        #""firstAcceptedAt":"2023-11-14T22:13:20Z","id":"1A1A1A1A-2B2B-4C4C-8D8D-3E3E3E3E3E3E","#,
        #""keyAgreementPublicKey":"IiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiI=","#,
        #""lastSeenAt":"2023-11-14T23:13:20Z","mode":"friend","reportReason":"hateful","#,
        #""reportedAt":"2023-11-15T00:13:20Z","#,
        #""signingPublicKey":"ERERERERERERERERERERERERERERERERERERERERERE="}"#
    ].joined()

    /// A trainer audit row with its payload type set.
    static let trainerAuditJSON = [
        #"{"id":"2B2B2B2B-3C3C-4D4D-8E8E-4F4F4F4F4F4F","kind":"envelopeReceived","#,
        #""message":"Received fernlet.recipe.share.v1","payloadType":"fernlet.recipe.share.v1","#,
        #""peerDisplayName":"Robin","peerFingerprint":"a1b2c3d4e5f60718","#,
        #""timestamp":"2023-11-14T22:14:20Z"}"#
    ].joined()

    /// A session log with its role, mode and ranging mode, and one of each nested record.
    static let sessionLogJSON = [
        #"{"endState":"ended.completedSuccessfully","endedAt":"2023-11-14T22:18:20Z","#,
        #""envelopes":[{"direction":"sent","encrypted":false,"#,
        #""envelopeID":"7A7A7A7A-8B8B-4C4C-8D8D-9E9E9E9E9E9E","id":"6F6F6F6F-7A7A-4B4B-8C8C-8D8D8D8D8D8D","#,
        #""payloadByteCount":512,"payloadType":"fernlet.identity.intro.v1","signatureVerified":true,"#,
        #""summary":"Hello","timestamp":"2023-11-14T22:13:27Z"}],"errors":[{"domain":"Ranging","#,
        #""id":"8B8B8B8B-9C9C-4D4D-8E8E-AFAFAFAFAFAF","message":"fallback to rssi","recoverable":true,"#,
        #""timestamp":"2023-11-14T22:13:28Z"}],"events":[{"id":"5E5E5E5E-6F6F-4A4A-8B8B-7C7C7C7C7C7C","#,
        #""kind":"identityVerified","message":"identity verified","timestamp":"2023-11-14T22:13:26Z"}],"#,
        #""id":"3C3C3C3C-4D4D-4E4E-8F8F-5A5A5A5A5A5A","localFingerprint":"0f1e2d3c4b5a6978","#,
        #""mode":"trainer","peer":{"advertisedFingerprint":"a1b2c3d4e5f60718","#,
        #""confirmedFingerprint":"a1b2c3d4e5f60718","displayName":"Robin","#,
        #""firstSeenAt":"2023-11-14T22:13:30Z","lastSeenAt":"2023-11-14T22:18:10Z","#,
        #""signingPublicKey":"ERERERERERERERERERERERERERERERERERERERERERE="},"#,
        #""ranging":{"maxDistanceMeters":1.5,"minDistanceMeters":0.25,"mode":"uwb","#,
        #""samples":[{"directionX":0.5,"directionY":-0.25,"directionZ":0.75,"#,
        #""id":"4D4D4D4D-5E5E-4F4F-8A8A-6B6B6B6B6B6B","meters":0.5,"timestamp":"2023-11-14T22:13:35Z"}],"#,
        #""tapConfirmedAt":"2023-11-14T22:13:40Z"},"role":"advertiser","startedAt":"2023-11-14T22:13:20Z","#,
        #""transport":{"bluetoothActive":false,"bytesReceived":3400,"bytesSent":1200,"#,
        #""connectedAt":"2023-11-14T22:13:25Z","disconnectedAt":"2023-11-14T22:18:20Z","#,
        #""mcSessionState":"connected","rttSamplesMs":[12.5,20.25],"wifiActive":true}}"#
    ].joined()

    /// A trusted peer persists as its frozen JSON, and the JSON reads back as the record.
    @Test func aTrustedPeerRecordPersistsAsItsFrozenJSON() throws {
        try Self.expectPersisted(Self.trustedPeerRecord(), as: Self.trustedPeerJSON, "the trusted peer")
    }

    /// A trainer audit row persists as its frozen JSON, and the JSON reads back as the row.
    @Test func aTrainerAuditEventPersistsAsItsFrozenJSON() throws {
        try Self.expectPersisted(Self.trainerAuditEvent(), as: Self.trainerAuditJSON, "the audit row")
    }

    /// A session log persists as its frozen JSON, and the JSON reads back as the log.
    @Test func aConnectionSessionLogPersistsAsItsFrozenJSON() throws {
        try Self.expectPersisted(Self.sessionLog(), as: Self.sessionLogJSON, "the session log")
    }

    /// `value` through the encoder Fernlet's synced repository writes with (`RowPayloadCoders`, the
    /// local one pretty-printing the same keys), equal to `golden`, and `golden` back through the
    /// matching decoder, equal to `value`.
    private static func expectPersisted<Value: Codable & Equatable>(_ value: Value, as golden: String, _ name: String) throws {
        let encoded = try RowPayloadCoders.makeEncoder().encode(value)
        #expect(encoded == Data(golden.utf8), "\(name) persists as \(String(decoding: encoded, as: UTF8.self))")
        let decoded = try RowPayloadCoders.makeDecoder().decode(Value.self, from: Data(golden.utf8))
        #expect(decoded == value, "\(name)'s golden reads back as \(decoded)")
    }

    /// The trusted peer behind ``trustedPeerJSON``: a friend, blocked and reported, never revoked.
    static func trustedPeerRecord() -> ProximityTrustedPeerRecord {
        ProximityTrustedPeerRecord(
            id: uuid("1A1A1A1A-2B2B-4C4C-8D8D-3E3E3E3E3E3E"), displayName: "Robin", fingerprint: "a1b2c3d4e5f60718",
            signingPublicKey: Data(repeating: 0x11, count: 32), keyAgreementPublicKey: Data(repeating: 0x22, count: 32),
            mode: .friend, firstAcceptedAt: at(0), lastSeenAt: at(3_600), blockedAt: at(7_200),
            reportedAt: at(7_200), reportReason: "hateful")
    }

    /// The audit row behind ``trainerAuditJSON``.
    static func trainerAuditEvent() -> TrainerAuditEvent {
        TrainerAuditEvent(
            id: uuid("2B2B2B2B-3C3C-4D4D-8E8E-4F4F4F4F4F4F"), timestamp: at(60), kind: .envelopeReceived,
            peerFingerprint: "a1b2c3d4e5f60718", peerDisplayName: "Robin", payloadType: .recipeShare,
            message: "Received fernlet.recipe.share.v1")
    }

    /// The session log behind ``sessionLogJSON``.
    static func sessionLog() -> ConnectionSessionLog {
        ConnectionSessionLog(
            id: uuid("3C3C3C3C-4D4D-4E4E-8F8F-5A5A5A5A5A5A"), startedAt: at(0), endedAt: at(300),
            role: .advertiser, mode: .trainer, localFingerprint: "0f1e2d3c4b5a6978",
            peer: ConnectionSessionLog.PeerInfo(
                displayName: "Robin", advertisedFingerprint: "a1b2c3d4e5f60718", confirmedFingerprint: "a1b2c3d4e5f60718",
                signingPublicKey: Data(repeating: 0x11, count: 32), firstSeenAt: at(10), lastSeenAt: at(290)),
            ranging: sessionRanging(),
            transport: ConnectionSessionLog.TransportInfo(
                mcSessionState: "connected", connectedAt: at(5), disconnectedAt: at(300), bytesSent: 1_200,
                bytesReceived: 3_400, bluetoothActive: false, wifiActive: true, rttSamplesMs: [12.5, 20.25]),
            events: [ConnectionSessionLog.Event(
                id: uuid("5E5E5E5E-6F6F-4A4A-8B8B-7C7C7C7C7C7C"), timestamp: at(6), kind: .identityVerified,
                message: "identity verified")],
            envelopes: [ConnectionSessionLog.EnvelopeRecord(
                id: uuid("6F6F6F6F-7A7A-4B4B-8C8C-8D8D8D8D8D8D"), envelopeID: uuid("7A7A7A7A-8B8B-4C4C-8D8D-9E9E9E9E9E9E"),
                direction: .sent, payloadType: "fernlet.identity.intro.v1", payloadByteCount: 512, timestamp: at(7),
                signatureVerified: true, encrypted: false, summary: "Hello")],
            errors: [ConnectionSessionLog.ErrorRecord(
                id: uuid("8B8B8B8B-9C9C-4D4D-8E8E-AFAFAFAFAFAF"), timestamp: at(8), domain: "Ranging",
                message: "fallback to rssi", recoverable: true)],
            endState: "ended.completedSuccessfully")
    }

    /// The log's ranging record: UWB, one sample with a direction, a tap, both distance bounds.
    private static func sessionRanging() -> ConnectionSessionLog.RangingInfo {
        var sample = ConnectionSessionLog.DistanceSample(timestamp: at(15), meters: 0.5, direction: simd_float3(0.5, -0.25, 0.75))
        sample.id = uuid("4D4D4D4D-5E5E-4F4F-8A8A-6B6B6B6B6B6B")
        return ConnectionSessionLog.RangingInfo(
            mode: .uwb, samples: [sample], tapConfirmedAt: at(20), minDistanceMeters: 0.25, maxDistanceMeters: 1.5)
    }

    // MARK: Group 12 — display-name sanitizing

    /// The floor ProximityKit puts under a peer name that sanitizes to nothing. No accessor: an
    /// inline literal in `ItemNameModeration.moderatedPeerDisplayName`.
    static var moderationRows: [VocabularyGoldenRow] {
        [VocabularyGoldenRow(field: "moderation.peerNameFallback", frozen: "A friend", today: nil)]
    }

    /// The sanitizer's length cap, in characters.
    static var moderationNumbers: [VocabularyGoldenNumber] {
        [VocabularyGoldenNumber(field: "moderation.maxNameLength", frozen: 24, today: ItemNameModeration.maxNameLength)]
    }

    /// Raw names and what `sanitizedName` makes of them, compared as UTF-8 so a recomposed or
    /// reordered scalar fails where `==`'s canonical equivalence would pass.
    static let sanitizerCorpus: [(raw: String, sanitized: String)] = [
        ("Ali\u{200B}ce", "Alice"),
        ("\u{202E}Bob\u{202C}", "Bob"),
        ("\u{2066}Eve\u{2069}\u{FEFF}", "Eve"),
        ("Sam\u{0007}my\u{001B}", "Sammy"),
        ("Soup\nIgnore this", "Soup Ignore this"),
        ("Tab\tSeparated", "Tab Separated"),
        ("  Lots   of\u{00A0}\u{3000}space  ", "Lots of space"),
        ("ABCDEFGHIJKLMNOPQRSTUVWXYZ1234", "ABCDEFGHIJKLMNOPQRSTUVWX"),
        ("Zo\u{00EB} \u{1F331}\u{2728}", "Zo\u{00EB} \u{1F331}\u{2728}"),
        ("\u{1F469}\u{200D}\u{1F4BB} Dev", "\u{1F469}\u{1F4BB} Dev"),
        ("Cafe\u{0301}", "Cafe\u{0301}"),
        (String(repeating: "e\u{0301}", count: 30), String(repeating: "e\u{0301}", count: 24)),
        ("", ""),
        ("\u{200B}\u{200D}\u{FEFF}", ""),
        ("   \n\t ", "")
    ]

    /// Zero-width and bidi scalars vanish (a joiner too, splitting its emoji), control characters
    /// vanish, a newline or tab becomes a space, whitespace runs collapse and trim, the cap counts
    /// characters (a combining mark rides its letter), and emoji and marks keep their scalars.
    @Test func theSanitizerTurnsItsCorpusIntoTheFrozenOutputs() {
        #expect(Self.expectFrozen(Self.moderationNumbers) == 1)
        // R2: bounded by the corpus.
        for entry in Self.sanitizerCorpus {
            let actual = ItemNameModeration.sanitizedName(entry.raw)
            #expect(Data(actual.utf8) == Data(entry.sanitized.utf8),
                    "\(entry.raw.debugDescription) sanitized to \(actual.debugDescription) (UTF-8 \(Self.hex(Data(actual.utf8))))")
        }
    }

    /// A peer name that is empty, invisible or blank becomes "A friend", in ProximityKit's coercion
    /// and in the envelope's display read built on it; a name with something left passes, sanitized.
    @Test func anEmptyOrInvisiblePeerNameBecomesAFriend() {
        let fallback = Self.frozen("moderation.peerNameFallback")
        // R2: bounded by the four names.
        for raw in ["", "\u{200B}\u{2060}\u{FEFF}", "  \n\t  ", "\u{202E}\u{202C}"] {
            let moderated = ItemNameModeration.moderatedPeerDisplayName(raw)
            #expect(Data(moderated.utf8) == Data(fallback.utf8), "\(raw.debugDescription) became \(moderated)")
        }
        #expect(ItemNameModeration.moderatedPeerDisplayName("  Robin \u{200B} ") == "Robin")
        let envelope = Self.legacyEnvelope()
        let blank = FernletIdentityEnvelope(
            schemaVersion: envelope.schemaVersion, envelopeID: envelope.envelopeID,
            senderSigningPublicKey: envelope.senderSigningPublicKey,
            senderKeyAgreementPublicKey: envelope.senderKeyAgreementPublicKey,
            senderDisplayName: "\u{200B}\u{FEFF}", recipientFingerprint: nil, payloadTypeToken: envelope.payloadTypeToken,
            payloadEncryption: .none, payloadSummary: envelope.payloadSummary, payload: envelope.payload,
            createdAt: envelope.createdAt, expiresAt: nil, signature: Data())
        #expect(blank.sanitizedSenderDisplayName == fallback, "an invisible sender reads as \(blank.sanitizedSenderDisplayName)")
    }

    // MARK: Group 13 — `.fernlet`'s vocabulary and presentation strings

    /// One single value `ProximityNamespace.fernlet` carries, by its path in the namespace, beside the
    /// frozen literal it must equal.
    struct FernletValue: Sendable {
        /// The value's path from the namespace root, as reflection names it.
        let field: String
        /// What `.fernlet` carries there.
        let shipped: String
        /// The frozen literal it must equal, read off the tables above.
        let frozen: String
    }

    /// The vocabulary's token sets and lists, which ``fernletsTokenSetsAndListsAreTheFrozenTablesWhole()``
    /// compares whole.
    static let wholeVocabularyFields: Set<String> = [
        "family.vocabulary.payloads.known", "family.vocabulary.payloads.sealingRequired",
        "family.vocabulary.capabilities.known", "family.vocabulary.capabilities.assumedForLegacyPeers"
    ]

    /// The radio values `ProximityNamespaceGoldenTests` pins: the three service types and ALPNs and
    /// the mesh heartbeat.
    static let radioFieldsTheNamespaceGoldenPins: Set<String> = [
        "family.radios.mesh.serviceType", "family.radios.mesh.alpn",
        "family.radios.presence.serviceType", "family.radios.presence.alpn",
        "family.radios.recipeShare.serviceType", "family.radios.recipeShare.alpn",
        "family.radios.meshHeartbeat"
    ]

    /// Every single token and title of `.fernlet`'s vocabulary and its three presentation strings,
    /// each beside the frozen literal of the value ProximityKit's consumers read: the payload rows,
    /// the session messages' titles, the capability, record-kind, routed-type and presentation rows.
    /// The presence prefix is the frozen prefix and separator together, as the namespace carries it.
    static var fernletValues: [FernletValue] {
        let vocabulary = ProximityNamespace.fernlet.family.vocabulary
        let radios = ProximityNamespace.fernlet.family.radios
        let (session, kinds, routed) = (vocabulary.session, vocabulary.membershipRecordKinds, vocabulary.routedTypes)
        let path = "family.vocabulary."
        return [
            FernletValue(field: path + "session.identityIntroduction.payloadType",
                         shipped: session.identityIntroduction.payloadType, frozen: frozen("payloadType.identityIntroduction")),
            FernletValue(field: path + "session.identityIntroduction.summaryTitle",
                         shipped: session.identityIntroduction.summaryTitle, frozen: frozenTitle("identity introduction")),
            FernletValue(field: path + "session.identityAcknowledge.payloadType",
                         shipped: session.identityAcknowledge.payloadType, frozen: frozen("payloadType.identityAcknowledge")),
            FernletValue(field: path + "session.identityAcknowledge.summaryTitle",
                         shipped: session.identityAcknowledge.summaryTitle, frozen: frozenTitle("identity acknowledgement")),
            FernletValue(field: path + "session.heartbeat.payloadType",
                         shipped: session.heartbeat.payloadType, frozen: frozen("payloadType.sessionHeartbeat")),
            FernletValue(field: path + "session.heartbeat.pingTitle",
                         shipped: session.heartbeat.pingTitle, frozen: frozenTitle("heartbeat")),
            FernletValue(field: path + "session.heartbeat.replyTitle",
                         shipped: session.heartbeat.replyTitle, frozen: frozenTitle("heartbeat reply")),
            FernletValue(field: path + "capabilities.wire2", shipped: vocabulary.capabilities.wire2,
                         frozen: frozen("capability.wire2")),
            FernletValue(field: path + "membershipRecordKinds.admission", shipped: kinds.admission,
                         frozen: frozen("recordKind.admission")),
            FernletValue(field: path + "membershipRecordKinds.departure", shipped: kinds.departure,
                         frozen: frozen("recordKind.departure")),
            FernletValue(field: path + "membershipRecordKinds.removal", shipped: kinds.removal,
                         frozen: frozen("recordKind.removal")),
            FernletValue(field: path + "membershipRecordKinds.termination", shipped: kinds.termination,
                         frozen: frozen("recordKind.termination")),
            FernletValue(field: path + "routedTypes.photo", shipped: routed.photo, frozen: frozen("routedType.photo")),
            FernletValue(field: path + "routedTypes.tempMessage", shipped: routed.tempMessage,
                         frozen: frozen("routedType.tempMessage")),
            FernletValue(field: path + "routedTypes.heart", shipped: routed.heart, frozen: frozen("routedType.heart")),
            FernletValue(field: path + "routedTypes.control", shipped: routed.control, frozen: frozen("routedType.control")),
            FernletValue(field: "family.radios.meshInstanceNamePrefix", shipped: radios.meshInstanceNamePrefix,
                         frozen: frozen("presentation.meshInstanceNamePrefix")),
            FernletValue(field: "family.radios.presenceInstanceNamePrefix", shipped: radios.presenceInstanceNamePrefix,
                         frozen: frozen("presentation.presenceInstanceNamePrefix")
                             + frozen("presentation.presenceInstanceNameSeparator")),
            FernletValue(field: "family.radios.tlsCommonName", shipped: radios.tlsCommonName,
                         frozen: frozen("presentation.tlsCommonName"))
        ]
    }

    /// Every single token and title of `.fernlet`'s vocabulary, and its three presentation strings,
    /// is its frozen literal byte for byte: FernletConnections spells exactly what ProximityKit's
    /// consumers read, so pointing a consumer at the namespace moves no byte.
    @Test func everyFernletVocabularyValueIsItsFrozenLiteral() {
        let values = Self.fernletValues
        #expect(values.count == 19, "\(values.count) single values compared")
        #expect(Set(values.map(\.field)).count == values.count, "a field is compared twice")
        // R2: bounded by the 19 values.
        for value in values {
            #expect(!value.frozen.isEmpty && Data(value.shipped.utf8) == Data(value.frozen.utf8), """
                ProximityNamespace.fernlet's \(value.field) is "\(value.shipped)" \
                (UTF-8 \(Self.hex(Data(value.shipped.utf8)))); its frozen literal is "\(value.frozen)". \
                The literal never moves: fix FernletConnections.
                """)
        }
    }

    /// `.fernlet`'s token sets and lists are the frozen tables whole: `known` is the 55 payload tokens,
    /// exactly `PayloadType`'s cases; the sealing set is the 17; the capabilities are the nine in
    /// declaration order, photos alone assumed for a legacy peer; and twice their count is the
    /// coordinator's receive bound.
    @Test func fernletsTokenSetsAndListsAreTheFrozenTablesWhole() {
        let vocabulary = ProximityNamespace.fernlet.family.vocabulary
        let payloads = Set(Self.payloadRows.map(\.frozen))
        #expect(payloads.count == 55, "the frozen payload table holds \(payloads.count) tokens")
        #expect(vocabulary.payloads.known == payloads,
                "known and the frozen table differ by \(vocabulary.payloads.known.symmetricDifference(payloads).sorted())")
        #expect(vocabulary.payloads.known == Set(PayloadType.allCases.map(\.rawValue)), "known is not PayloadType's cases")
        #expect(vocabulary.payloads.sealingRequired == Self.sealingRequiredTokens, """
            the sealing set and the frozen 17 differ by \
            \(vocabulary.payloads.sealingRequired.symmetricDifference(Self.sealingRequiredTokens).sorted())
            """)
        let capabilities = Self.capabilityRows.map(\.frozen)
        #expect(vocabulary.capabilities.known == capabilities, "the capabilities are \(vocabulary.capabilities.known)")
        #expect(vocabulary.capabilities.assumedForLegacyPeers == [Self.frozen("capability.photos")],
                "a legacy peer is assumed to support \(vocabulary.capabilities.assumedForLegacyPeers)")
        #expect(vocabulary.capabilities.known.count * 2 == Self.frozenNumber("capability.maxAdvertised"),
                "twice the \(vocabulary.capabilities.known.count) capabilities is not the coordinator's receive bound")
    }

    /// Reflection over `.fernlet`'s vocabulary and radios finds no field the cells above and
    /// `ProximityNamespaceGoldenTests` leave out: a token added to the vocabulary, or a string to the
    /// radios, fails here until it has a frozen literal.
    @Test func reflectionFindsNoVocabularyOrPresentationFieldLeftUnpinned() {
        let family = ProximityNamespace.fernlet.family
        let reflected = Self.reflectedLeaves(of: family.vocabulary, under: "family.vocabulary")
            + Self.reflectedLeaves(of: family.radios, under: "family.radios")
        let pinned = Set(Self.fernletValues.map(\.field))
            .union(Self.wholeVocabularyFields).union(Self.radioFieldsTheNamespaceGoldenPins)
        #expect(reflected.count == 30, "reflection found \(reflected.count) leaves: \(reflected.sorted())")
        #expect(Set(reflected) == pinned, """
            reflected but unpinned: \(Set(reflected).subtracting(pinned).sorted()); \
            pinned but not reflected: \(pinned.subtracting(reflected).sorted())
            """)
    }

    /// The bounds the namespace's soundness rules hold a vocabulary and the presentation strings to
    /// are those of the consumers they protect, so a sound namespace names no value a receiver refuses
    /// or cuts: the summary decode's 200 characters (FernletDomainModel's, out of `Namespace/`'s
    /// reach), the coordinator's 32-character capability cut, the routed manifest's 64-byte type
    /// token, and the 12 and 16 hex characters after each instance-name prefix.
    @Test func theNamespacesSoundnessBoundsAreItsConsumersBounds() {
        let bounds: [(name: String, namespace: Int, consumer: Int)] = [
            ("summary title characters", ProximityNamespace.maximumSummaryTitleCharacters,
             PayloadSummary.maxDetailCharacters),
            ("capability token bytes", ProximityNamespace.maximumCapabilityTokenBytes,
             ProximityCoordinator.maxCapabilityTokenLength),
            ("routed-type token bytes", ProximityNamespace.maximumRoutedTypeTokenBytes,
             MeshRoutedManifestFormat.maxTypeTokenLength),
            ("mesh instance-name hex characters", ProximityNamespace.meshInstanceNameTokenLength,
             MeshLinkAdvertisement.instanceNameTokenLength),
            ("presence instance-name hex characters", ProximityNamespace.presenceInstanceNameTokenLength,
             2 * PresenceEpochPosture.instanceNameEntropyByteCount)
        ]
        // R2: bounded by the five bounds.
        for bound in bounds {
            #expect(bound.namespace == bound.consumer,
                    "the namespace allows \(bound.namespace) \(bound.name); its consumer \(bound.consumer)")
        }
        #expect(ProximityNamespace.maximumSummaryTitleCharacters == Self.frozenNumber("payloadSummary.maxDetailCharacters"))
        #expect(ProximityNamespace.maximumCapabilityTokenBytes == Self.frozenNumber("capability.maxTokenLength"))
    }

    /// The frozen title of the session message named `name`; empty for a name the table does not hold.
    static func frozenTitle(_ name: String) -> String {
        sessionMessages.first { $0.name == name }?.title ?? ""
    }

    /// The paths of every string, token set or list and byte string under `value`, by reflection over
    /// its labeled children; empty if the walk was cut short, which fails the cell that reads it.
    private static func reflectedLeaves(of value: Any, under root: String) -> [String] {
        var leaves: [String] = []
        var pending: [(path: String, value: Any)] = [(path: root, value: value)]
        var visits = 0
        // R2: at most 128 nodes; the vocabulary and the radios hold about 45 between them.
        while visits < 128, let node = pending.popLast() {
            visits += 1
            if node.value is String || node.value is Set<String> || node.value is [String] || node.value is Data {
                leaves.append(node.path)
                continue
            }
            pending += Mirror(reflecting: node.value).children.compactMap { child in
                child.label.map { (path: node.path + "." + $0, value: child.value) }
            }
        }
        return pending.isEmpty ? leaves : []
    }

    // MARK: Helpers

    /// Compares every row that has an accessor with its frozen literal, byte for byte, recording each
    /// mismatch with today's bytes; returns how many rows were compared.
    @discardableResult
    static func expectFrozen(_ rows: [VocabularyGoldenRow]) -> Int {
        var compared = 0
        // R2: bounded by the rows.
        for row in rows {
            guard let today = row.today else { continue }
            compared += 1
            #expect(Data(today.utf8) == Data(row.frozen.utf8),
                    "\(row.field) is \(today) (UTF-8 \(Self.hex(Data(today.utf8)))); its frozen spelling is \(row.frozen)")
        }
        return compared
    }

    /// Compares every number row with its frozen value; returns how many rows were compared.
    @discardableResult
    static func expectFrozen(_ rows: [VocabularyGoldenNumber]) -> Int {
        // R2: bounded by the rows.
        for row in rows {
            #expect(row.today == row.frozen, "\(row.field) is \(row.today); it is frozen at \(row.frozen)")
        }
        return rows.count
    }

    /// The frozen literal of `field`; empty for a field no table holds, which fails what reads it.
    static func frozen(_ field: String) -> String {
        allRows.first { $0.field == field }?.frozen ?? ""
    }

    /// The frozen number of `field`; -1 for a field no table holds.
    static func frozenNumber(_ field: String) -> Int {
        allNumbers.first { $0.field == field }?.frozen ?? -1
    }

    /// `seconds` after the fixtures' fixed instant, 2023-11-14T22:13:20Z.
    static func at(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + seconds)
    }

    /// A fixture id; a malformed literal falls back to a random id, which fails every golden it reaches.
    static func uuid(_ text: String) -> UUID {
        UUID(uuidString: text) ?? UUID()
    }

    /// Lowercase hex.
    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// The subject common name Security reads out of a certificate's DER; nil when it parses no
    /// certificate or no common name.
    static func commonName(of certificateDER: Data) -> String? {
        guard let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData) else { return nil }
        var commonName: CFString?
        guard SecCertificateCopyCommonName(certificate, &commonName) == errSecSuccess else { return nil }
        return commonName.map { $0 as String }
    }

    /// A keychain service no other test uses, in the `.test.` family the wipe wall's discovery skips.
    static func isolatedIdentityService() -> String {
        "com.fernlet.identity.test.vocabularygolden.\(UUID().uuidString)"
    }
}

// MARK: - A coordinator on a fabric endpoint

/// One friend-mode coordinator on one endpoint of a two-endpoint `FakePeerNetwork`, its peer driven by
/// hand: the peer signs what it sends with an identity of its own, the fabric carries it on the
/// virtual clock, and every frame the coordinator sends is read back off its endpoint.
///
/// The coordinator is built with ``displayName``, the rig's own (the engine has no default name),
/// and on a ranging provider with no UWB, so a verified introduction lands it at the manual-commit
/// gate.
@MainActor
final class VocabularyCoordinatorRig {

    /// The name the coordinator advertises and discloses after its commit. Spells no `fernlet`, so a
    /// deleted spelling can never pass for it.
    static let displayName = "Golden Rig"

    /// The body of an identity introduction as a peer sends it: its ranging mode, and its capability
    /// list or none at all — an older peer's introduction carries no `capabilities` key.
    struct IntroductionBody: Encodable {
        /// The sender's ranging mode token.
        let rangingMode: String
        /// The advertised capability tokens, or nil for no key at all.
        let capabilities: [String]?
    }

    /// The body of a session heartbeat ping as a peer sends it.
    struct HeartbeatBody: Encodable {
        /// `ping`.
        let kind: String
        /// The id an acknowledgement quotes back.
        let heartbeatID: UUID
        /// When the ping was sent.
        let sentAt: Date
    }

    /// Held strongly: an endpoint points at its fabric weakly.
    let network: FakePeerNetwork
    /// The coordinator's endpoint; its `sentFrames` are what the coordinator signed.
    let local: FakePeerTransport
    /// The coordinator's handle on the fabric.
    let localHandle: PeerHandle
    /// The hand-driven peer's endpoint.
    let remote: FakePeerTransport
    /// The peer's handle, which the coordinator sees as its peer.
    let remoteHandle: PeerHandle
    /// The coordinator's identity.
    let identity: IdentityService
    /// The peer's identity, which signs everything the peer sends and opens what it is sent.
    let remoteIdentity: IdentityService
    /// The coordinator under test.
    let coordinator: ProximityCoordinator
    /// The two throwaway keychain services, removed by ``forgetKeychainRows()``.
    private let services: [String]

    /// Two provisioned identities on throwaway services, the fabric, and the coordinator.
    init() throws {
        let localService = ProximityVocabularyGoldenTests.isolatedIdentityService()
        let remoteService = ProximityVocabularyGoldenTests.isolatedIdentityService()
        let localIdentity = IdentityService(namespace: .fernlet, keychainService: localService)
        let peerIdentity = IdentityService(namespace: .fernlet, keychainService: remoteService)
        try localIdentity.ensureProvisioned()
        try peerIdentity.ensureProvisioned()
        let fabric = FakePeerNetwork()
        let near = fabric.addEndpoint(named: "vocabulary-local")
        let far = fabric.addEndpoint(named: "vocabulary-remote")
        services = [localService, remoteService]
        identity = localIdentity
        remoteIdentity = peerIdentity
        network = fabric
        local = near.transport
        localHandle = near.handle
        remote = far.transport
        remoteHandle = far.handle
        coordinator = ProximityCoordinator(
            identity: localIdentity, transport: near.transport, ranging: MockRangingProvider(isHardwareSupported: false),
            replayCache: ReplayCache(), displayName: Self.displayName, timeoutSeconds: 0)
    }

    /// Removes both identities' keychain rows.
    func forgetKeychainRows() {
        // R2: bounded by the two services.
        for service in services {
            KeychainItem.deleteAll(service: service)
        }
    }

    /// Starts the coordinator in friend mode as the browser, opens the link, and lets the peer's
    /// introduction (built over `payload`) arrive. Returns the peer identity the coordinator holds at
    /// the manual-commit gate, or nil when it never got there.
    func handshake(payload: Data) async throws -> ProximityCoordinator.PeerIdentity? {
        await coordinator.begin(role: .browser, mode: .friend)
        network.connect(localHandle, remoteHandle)
        network.clock.advance(by: FakePeerNetwork.defaultLatency)
        await Self.settle { self.local.sentFrames.count >= 1 }
        try await deliver(FernletIdentityEnvelope.signed(
            identityService: remoteIdentity, senderDisplayName: "", payloadType: .identityIntroduction,
            payloadSummary: PayloadSummary(title: "Hello"), payload: payload))
        await Self.settle {
            if case .awaitingManualCommit = self.coordinator.state { return true }
            return false
        }
        guard case .awaitingManualCommit(let peer) = coordinator.state else { return nil }
        return peer
    }

    /// A ping from the peer, which a connected coordinator must answer.
    func heartbeatPing() throws -> FernletIdentityEnvelope {
        let body = HeartbeatBody(kind: "ping", heartbeatID: UUID(), sentAt: Date())
        return try FernletIdentityEnvelope.signed(
            identityService: remoteIdentity, senderDisplayName: "", payloadType: .sessionHeartbeat,
            payloadSummary: PayloadSummary(title: "Heartbeat"), payload: JSONEncoder().encode(body))
    }

    /// Sends `envelope` from the peer across the fabric and runs the clock until it lands.
    func deliver(_ envelope: FernletIdentityEnvelope) async throws {
        try await remote.send(JSONEncoder().encode(envelope), to: localHandle, mode: .reliable)
        network.clock.advance(by: FakePeerNetwork.defaultLatency)
    }

    /// Every frame the coordinator sent, decoded as the envelope it is.
    func sentEnvelopes() throws -> [FernletIdentityEnvelope] {
        try local.sentFrames.map { try JSONDecoder().decode(FernletIdentityEnvelope.self, from: $0.data) }
    }

    /// Yields until `condition` holds, a bounded number of times: the coordinator reacts to its
    /// transport on main-actor tasks it spawns, and nothing here sleeps or reads a wall clock.
    @discardableResult
    static func settle(_ condition: () -> Bool) async -> Bool {
        // R2: bounded by 2 000 yields.
        for _ in 0..<2_000 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
}

// MARK: - A host of one namespace

/// A `ProximityHost` that supplies the namespace a cell hands it and the requirements with no default,
/// so a presence manager can be built over `.fernlet` or over a namespace whose presentation strings
/// are its own. Building one touches no disk and no keychain.
@MainActor
private final class PresentationNamespaceHost: ProximityHost {
    let proximityNamespace: ProximityNamespace
    let proximityInstallBinding: any ProximityInstallBinding = FernletDeviceBindingAdapter()
    let proximityTrustVault = ProximityTrustVault()
    var proximityDisplayName: String { VocabularyCoordinatorRig.displayName }
    var trustedProximityPeers: [ProximityTrustedPeerRecord] { proximityTrustVault.trustedPeers }

    /// A host of `namespace`.
    init(namespace: ProximityNamespace) {
        proximityNamespace = namespace
    }

    func isBlockedFingerprint(_ fingerprint: String) -> Bool { proximityTrustVault.isBlockedFingerprint(fingerprint) }
    func blockProximityPeer(signingPublicKey: Data) { proximityTrustVault.block(signingPublicKey: signingPublicKey) }
}
