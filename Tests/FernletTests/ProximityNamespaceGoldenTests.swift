// ProximityNamespaceGoldenTests.swift
// FernletTests
//
// ProximityKit plan step A0.2.0 (Docs/Plan-FernletCoach-ProximityKit-2026-10-01.md §4 A0.2): every
// byte string by which ProximityKit's wire, keychain and disk formats identify Fernlet, pinned BEFORE
// the later A0.2 commits re-route each one through a host-supplied `ProximityNamespace`. Those commits
// must move no byte; this file is how that claim is checked rather than asserted.
//
// Four groups of claims:
//
// 1. **The golden table.** One row per value `ProximityNamespace.fernlet` will carry: the 39
//    domain-separation labels (the 38 core registry purposes plus the ProximityKit-local epoch
//    domain), the three radios' service types and ALPNs, the mesh heartbeat, the QR scheme, the
//    identity keychain service and its four device accounts, the two seal-key rows, the storage
//    directory and its three on-disk names, and the radios' log subsystem. Plus the QR host, which
//    stays a ProximityKit constant but travels beside the scheme. 62 rows.
// 2. **Known answers for the six labels nothing else pinned** (`fernlet.mesh.groupkey.v1`,
//    `fernlet.mesh.groupkey.wrap.aead.v2`, `fernlet.mesh.encrypted-metadata.aead.v2`,
//    `fernlet.mesh.routed.content-key.v1`, `fernlet.mesh.session-context.v1`,
//    `fernlet.mesh.routed-store.v1`): column keys and blobs that ColumnCrypto and the two mesh stores
//    must open, and literal-built group-key, transport, routed-key and metadata blobs that production
//    must open. A consumer that reads the wrong field opens nothing, so these pin the CONSUMER too.
// 3. **Transcripts, epoch ids and wire tokens.** The framed label at the front of the channel
//    introduction and of both QR transcripts, the two epoch ids the epoch domain derives, and the
//    payload tokens and record kinds that are spelled exactly like a signature label.
// 4. **The format constants that stay ProximityKit's** (`FPT2`, `FGK2`, `FMGM2`, `FMRI1`, the
//    column byte `0x03`, the QR host, query key and version, the `corrupt` and `chunk` extensions):
//    not namespace values, but later A0.2 commits edit the code right next to each of them.
//
// Every hex vector below was derived from the FORMAT by an independent Python re-implementation,
// proved honest first by reproducing vectors the repo already pins (SealedBackupFormatPinTests' two
// escrow KATs, MeshMembershipEventGoldenTests' epoch-heads golden, MeshRoutedManifestGoldenTests' wrap
// AAD), then cross-checked in CryptoKit — never copied out of Swift's output.

import CryptoKit
import FernletDomainModel
import FernletFoundation
import Foundation
import Security
import Testing
@testable import FernletCrypto
@testable import ProximityKit
@testable import Fernlet

// MARK: - The table's row

/// One value `ProximityNamespace.fernlet` will carry: the namespace field it fills, its FROZEN literal,
/// and where today's code holds it.
struct NamespaceGoldenRow: Sendable {

    /// The part of the namespace a row belongs to; the shape cell counts rows by it.
    enum Group: Hashable, Sendable {
        /// A domain-separation label (`family.purposes.*`).
        case label
        /// A radio's service type or ALPN, or the mesh heartbeat (`family.radios.*`).
        case radio
        /// The verify QR's URL scheme, and the QR host that travels beside it.
        case verifyQR
        /// A keychain service or account (`installation.keychain.*`).
        case keychain
        /// The storage directory or an on-disk name (`installation.storage.*`).
        case storage
        /// The radios' `os.Logger` subsystem (`installation.logSubsystem`).
        case logSubsystem
    }

    /// Where today's code holds the value. **The only column a later A0.2 commit may edit.**
    enum Today: Equatable, Sendable {
        /// A value the test can name — internal ones through `@testable` — compared as its UTF-8.
        case text(String)
        /// A value that is bytes rather than text: the heartbeat datagram.
        case bytes(Data)
        /// A value no test can name even through `@testable`. A behaviour cell pins it instead, and
        /// selects the row by `field`, so that cell keeps running after the row is re-pointed.
        case unnamed
    }

    /// Which part of the namespace the row belongs to.
    let group: Group
    /// The `ProximityNamespace` field path the value will fill (the plan's A0.2 design spells them).
    let field: String
    /// The bytes, written by hand from the A0.2 census. Never computed from a constant; never edited.
    let frozen: String
    /// Today's accessor.
    let today: Today

    /// One row.
    init(_ group: Group, _ field: String, frozen: String, today: Today) {
        self.group = group
        self.field = field
        self.frozen = frozen
        self.today = today
    }

    /// Today's bytes, or nil for an ``Today/unnamed`` row.
    var todayBytes: Data? {
        switch today {
        case .text(let text): return Data(text.utf8)
        case .bytes(let bytes): return bytes
        case .unnamed: return nil
        }
    }
}

// MARK: - The suite

/// Every byte string `ProximityNamespace.fernlet` will carry, pinned by literal before any of them
/// moves — the gate every later A0.2 commit has to pass unchanged.
///
/// **The rule for every later commit: re-point the `today:` column, never the `frozen:` one.** A
/// row's `frozen` literal was written by hand from the A0.2 census and never changes again. A commit
/// that moves a value into the namespace edits only that row's `today` accessor — say
/// `.text(FernletCryptoPurpose.Signature.meshRoutedChunkV1.rawValue)` becomes the namespace's field —
/// and the row has to stay green. The same holds for every hex vector here: a failing vector or row
/// is a WIRE or AT-REST decision, so it is never re-pinned from Swift's output to go green. Failure
/// messages print the actual bytes so a deliberate change can be argued from them.
@MainActor
@Suite(.serialized)
struct ProximityNamespaceGoldenTests {

    // MARK: Group 1 — the golden table

    /// The 62 rows, in the design's field order.
    static var table: [NamespaceGoldenRow] {
        signatureRows + otherLabelRows + radioRows + verifyQRRows + keychainRows + storageRows + logRows
    }

    /// The 21 signature labels: 17 length-prefixed transcripts, the two raw-prefixed QR transcripts
    /// and the verify-only legacy pair.
    private static var signatureRows: [NamespaceGoldenRow] {
        typealias Signature = FernletCryptoPurpose.Signature
        let field = "family.purposes.signature."
        return [
            NamespaceGoldenRow(.label, field + "identityEnvelopeV2", frozen: "fernlet.canonical.identity-envelope.v2",
                               today: .text(Signature.identityEnvelopeV2.rawValue)),
            NamespaceGoldenRow(.label, field + "meshAdmissionTokenV2", frozen: "fernlet.canonical.mesh-admission-token.v2",
                               today: .text(Signature.meshAdmissionTokenV2.rawValue)),
            NamespaceGoldenRow(.label, field + "meshChannelIntroductionV1", frozen: "fernlet.mesh.channel-introduction.v1",
                               today: .text(Signature.meshChannelIntroductionV1.rawValue)),
            NamespaceGoldenRow(.label, field + "meshMemberDepartureV1", frozen: "fernlet.mesh.member-departure.v1",
                               today: .text(Signature.meshMemberDepartureV1.rawValue)),
            NamespaceGoldenRow(.label, field + "meshMemberRemovalV1", frozen: "fernlet.mesh.member-removal.v1",
                               today: .text(Signature.meshMemberRemovalV1.rawValue)),
            NamespaceGoldenRow(.label, field + "meshTerminatedV1", frozen: "fernlet.mesh.terminated.v1",
                               today: .text(Signature.meshTerminatedV1.rawValue)),
            NamespaceGoldenRow(.label, field + "meshInventoryDigestV1", frozen: "fernlet.mesh.inventory-digest.v1",
                               today: .text(Signature.meshInventoryDigestV1.rawValue)),
            NamespaceGoldenRow(.label, field + "meshEpochHeadsV1", frozen: "fernlet.mesh.epoch-heads.v1",
                               today: .text(Signature.meshEpochHeadsV1.rawValue)),
            NamespaceGoldenRow(.label, field + "meshRemovalProposalV1", frozen: "fernlet.mesh.removal-proposal.v1",
                               today: .text(Signature.meshRemovalProposalV1.rawValue)),
            NamespaceGoldenRow(.label, field + "meshRemovalVoteV1", frozen: "fernlet.mesh.removal-vote.v1",
                               today: .text(Signature.meshRemovalVoteV1.rawValue)),
            NamespaceGoldenRow(.label, field + "meshKeyAgreementV1", frozen: "fernlet.mesh.key-agreement.v1",
                               today: .text(Signature.meshKeyAgreementV1.rawValue)),
            NamespaceGoldenRow(.label, field + "meshRoutedManifestV1", frozen: "fernlet.mesh.routed-manifest.v1",
                               today: .text(Signature.meshRoutedManifestV1.rawValue)),
            NamespaceGoldenRow(.label, field + "meshRoutedChunkV1", frozen: "fernlet.mesh.routed-chunk.v1",
                               today: .text(Signature.meshRoutedChunkV1.rawValue)),
            NamespaceGoldenRow(.label, field + "meshCustodyReceiptV1", frozen: "fernlet.mesh.custody-receipt.v1",
                               today: .text(Signature.meshCustodyReceiptV1.rawValue)),
            NamespaceGoldenRow(.label, field + "meshRecipientReceiptV1", frozen: "fernlet.mesh.recipient-receipt.v1",
                               today: .text(Signature.meshRecipientReceiptV1.rawValue)),
            NamespaceGoldenRow(.label, field + "meshRoutedInventoryDigestV1",
                               frozen: "fernlet.mesh.routed-inventory-digest.v1",
                               today: .text(Signature.meshRoutedInventoryDigestV1.rawValue)),
            NamespaceGoldenRow(.label, field + "meshRoutedDrainAnswerV1", frozen: "fernlet.mesh.routed-drain-answer.v1",
                               today: .text(Signature.meshRoutedDrainAnswerV1.rawValue)),
            NamespaceGoldenRow(.label, field + "proximityQRIdentityV1", frozen: "fernlet.verify.qr.v1",
                               today: .text(Signature.proximityQRIdentityV1.rawValue)),
            NamespaceGoldenRow(.label, field + "proximityQRResponseV1", frozen: "fernlet.verify.response.v1",
                               today: .text(Signature.proximityQRResponseV1.rawValue)),
            NamespaceGoldenRow(.label, field + "legacyV1.identityEnvelopeV1", frozen: "fernlet.canonical.identity-envelope.v1",
                               today: .text(Signature.identityEnvelopeLegacyV1.rawValue)),
            NamespaceGoldenRow(.label, field + "legacyV1.meshAdmissionTokenV1",
                               frozen: "fernlet.canonical.mesh-admission-token.v1",
                               today: .text(Signature.meshAdmissionTokenLegacyV1.rawValue))
        ]
    }

    /// The 18 other labels: six key-derivation labels, five AEAD labels, seven hash domains — the
    /// last of them the ProximityKit-local epoch domain, which no registry or domain test covers.
    private static var otherLabelRows: [NamespaceGoldenRow] {
        typealias KeyDerivation = FernletCryptoPurpose.KeyDerivation
        typealias AEAD = FernletCryptoPurpose.AEAD
        typealias Hash = FernletCryptoPurpose.Hash
        let derivation = "family.purposes.keyDerivation."
        let aead = "family.purposes.aead."
        let hash = "family.purposes.hash."
        return [
            NamespaceGoldenRow(.label, derivation + "proximityTransportV1", frozen: "fernlet.proximity.v1",
                               today: .text(KeyDerivation.proximityTransportV1.rawValue)),
            NamespaceGoldenRow(.label, derivation + "meshGroupKeyWrapV1", frozen: "fernlet.mesh.groupkey.v1",
                               today: .text(KeyDerivation.meshGroupKeyWrapV1.rawValue)),
            NamespaceGoldenRow(.label, derivation + "meshTLSExporterV1", frozen: "fernlet.mesh.tls-exporter.v1",
                               today: .text(KeyDerivation.meshTLSExporterV1.rawValue)),
            NamespaceGoldenRow(.label, derivation + "meshRoutedContentKeyWrapV1", frozen: "fernlet.mesh.routed.content-key.v1",
                               today: .text(KeyDerivation.meshRoutedContentKeyWrapV1.rawValue)),
            NamespaceGoldenRow(.label, derivation + "meshSessionContextV1", frozen: "fernlet.mesh.session-context.v1",
                               today: .text(KeyDerivation.meshSessionContextV1.rawValue)),
            NamespaceGoldenRow(.label, derivation + "meshRoutedStoreV1", frozen: "fernlet.mesh.routed-store.v1",
                               today: .text(KeyDerivation.meshRoutedStoreV1.rawValue)),
            NamespaceGoldenRow(.label, aead + "proximityTransportV2", frozen: "fernlet.proximity.transport.aead.v2",
                               today: .text(AEAD.proximityTransportV2.rawValue)),
            NamespaceGoldenRow(.label, aead + "meshGroupKeyWrapV2", frozen: "fernlet.mesh.groupkey.wrap.aead.v2",
                               today: .text(AEAD.meshGroupKeyWrapV2.rawValue)),
            NamespaceGoldenRow(.label, aead + "meshEncryptedMetadataV2", frozen: "fernlet.mesh.encrypted-metadata.aead.v2",
                               today: .text(AEAD.meshEncryptedMetadataV2.rawValue)),
            NamespaceGoldenRow(.label, aead + "meshRoutedContentKeyWrapV1",
                               frozen: "fernlet.mesh.routed.content-key.wrap.aead.v1",
                               today: .text(AEAD.meshRoutedContentKeyWrapV1.rawValue)),
            NamespaceGoldenRow(.label, aead + "meshRoutedItemV1", frozen: "fernlet.mesh.routed.item.aead.v1",
                               today: .text(AEAD.meshRoutedItemV1.rawValue)),
            NamespaceGoldenRow(.label, hash + "meshInventoryDigestV1", frozen: "fernlet.mesh.inventory-digest.hash.v1",
                               today: .text(Hash.meshInventoryDigestV1.rawValue)),
            NamespaceGoldenRow(.label, hash + "meshRoutedContentV1", frozen: "fernlet.mesh.routed-content.hash.v1",
                               today: .text(Hash.meshRoutedContentV1.rawValue)),
            NamespaceGoldenRow(.label, hash + "meshRoutedChunkV1", frozen: "fernlet.mesh.routed-chunk.hash.v1",
                               today: .text(Hash.meshRoutedChunkV1.rawValue)),
            NamespaceGoldenRow(.label, hash + "meshRoutedChunkIDV1", frozen: "fernlet.mesh.routed-chunk-id.hash.v1",
                               today: .text(Hash.meshRoutedChunkIDV1.rawValue)),
            NamespaceGoldenRow(.label, hash + "meshCustodyReceiptIDV1", frozen: "fernlet.mesh.custody-receipt-id.hash.v1",
                               today: .text(Hash.meshCustodyReceiptIDV1.rawValue)),
            NamespaceGoldenRow(.label, hash + "meshRecipientReceiptIDV1", frozen: "fernlet.mesh.recipient-receipt-id.hash.v1",
                               today: .text(Hash.meshRecipientReceiptIDV1.rawValue)),
            NamespaceGoldenRow(.label, hash + "meshEpochIDV1", frozen: "fernlet.mesh.epoch.v1",
                               today: .text(MeshEpochBounds.derivationDomain))
        ]
    }

    /// The three radios' service types and ALPNs, and the heartbeat the mesh radio filters by equality.
    private static var radioRows: [NamespaceGoldenRow] {
        [
            NamespaceGoldenRow(.radio, "family.radios.mesh.serviceType", frozen: "_fernlet-mesh2._udp",
                               today: .text(NetworkMeshSession.friendServiceType)),
            NamespaceGoldenRow(.radio, "family.radios.mesh.alpn", frozen: "fernlet-mesh-v1",
                               today: .text(NetworkMeshSession.alpn)),
            NamespaceGoldenRow(.radio, "family.radios.presence.serviceType", frozen: "_fernlet-near2._udp",
                               today: .text(NetworkPresenceSession.serviceType)),
            NamespaceGoldenRow(.radio, "family.radios.presence.alpn", frozen: "fernlet-near-v1",
                               today: .text(NetworkPresenceSession.alpn)),
            NamespaceGoldenRow(.radio, "family.radios.recipeShare.serviceType", frozen: "_fernlet-recipe2._udp",
                               today: .text(NetworkRecipeShareSession.serviceType)),
            NamespaceGoldenRow(.radio, "family.radios.recipeShare.alpn", frozen: "fernlet-recipe-v1",
                               today: .text(NetworkRecipeShareSession.alpn)),
            NamespaceGoldenRow(.radio, "family.radios.meshHeartbeat", frozen: "fernlet-mesh-heartbeat",
                               today: .bytes(NetworkMeshSession.heartbeatDatagram))
        ]
    }

    /// The QR's scheme, which the namespace will carry, and its host, which stays a ProximityKit
    /// constant (``theVerifyQRURLKeepsItsHostQueryKeyAndVersion()`` pins it by behaviour as well).
    private static var verifyQRRows: [NamespaceGoldenRow] {
        [
            NamespaceGoldenRow(.verifyQR, "family.verifyQR.urlScheme", frozen: "fernlet",
                               today: .text(ProximityVerifyQR.urlScheme)),
            NamespaceGoldenRow(.verifyQR, "proximityKit.verifyQR.urlHost", frozen: "verify",
                               today: .text(ProximityVerifyQR.urlHost))
        ]
    }

    /// The identity service and its four device accounts, and the two seal-key rows.
    ///
    /// The two seal-key services are read through the derivation the isolation walls themselves use
    /// (the production heart-drop service in, the production service out): the production scopes'
    /// own spellings are banned by substring in every other test file.
    private static var keychainRows: [NamespaceGoldenRow] {
        let identity = "installation.keychain.identity."
        let heartDrop = HeartPrekeyStore.keychainService
        return [
            NamespaceGoldenRow(.keychain, identity + "service", frozen: "com.fernlet.identity",
                               today: .text(IdentityService().keychainService)),
            NamespaceGoldenRow(.keychain, identity + "signingPrivateKey", frozen: "signingPrivateKey", today: .unnamed),
            NamespaceGoldenRow(.keychain, identity + "keyAgreementPrivateKey", frozen: "keyAgreementPrivateKey",
                               today: .unnamed),
            NamespaceGoldenRow(.keychain, identity + "signingPublicKeyCache", frozen: "signingPublicKeyCache",
                               today: .unnamed),
            NamespaceGoldenRow(.keychain, identity + "keyAgreementPublicKeyCache", frozen: "keyAgreementPublicKeyCache",
                               today: .unnamed),
            NamespaceGoldenRow(.keychain, "installation.keychain.meshSessionSealKey.service",
                               frozen: "com.fernlet.mesh-session",
                               today: .text(MeshSessionStorageScope.keychainService(besideHeartDrop: heartDrop))),
            NamespaceGoldenRow(.keychain, "installation.keychain.meshSessionSealKey.account", frozen: "meshSessionContextKey",
                               today: .text(MeshSessionSealKey.keychainAccount)),
            NamespaceGoldenRow(.keychain, "installation.keychain.meshRoutedSealKey.service",
                               frozen: "com.fernlet.mesh-routed",
                               today: .text(MeshRoutedStorageScope.keychainService(besideHeartDrop: heartDrop))),
            NamespaceGoldenRow(.keychain, "installation.keychain.meshRoutedSealKey.account", frozen: "meshRoutedStoreKey",
                               today: .text(MeshRoutedSealKey.keychainAccount))
        ]
    }

    /// The storage directory and the three names the two sealed mesh stores write under it.
    private static var storageRows: [NamespaceGoldenRow] {
        let storage = "installation.storage."
        return [
            NamespaceGoldenRow(.storage, storage + "directoryName", frozen: "Fernlet",
                               today: .text(ProximitySupportLayout.defaultDirectory.lastPathComponent)),
            NamespaceGoldenRow(.storage, storage + "meshSessionContextFileName", frozen: "MeshSessionContext.sealed",
                               today: .text(MeshSessionStore.fileName)),
            NamespaceGoldenRow(.storage, storage + "meshRoutedIndexFileName", frozen: "MeshRoutedIndex.sealed",
                               today: .text(MeshRoutedStore.indexFileName)),
            NamespaceGoldenRow(.storage, storage + "meshRoutedChunkDirectoryName", frozen: "MeshRoutedChunks",
                               today: .text(MeshRoutedStore.chunkDirectoryName))
        ]
    }

    /// The radios' log subsystem: their loggers are private and a `Logger` does not expose its
    /// subsystem, so ``theThreeRadiosLogUnderTheFrozenSubsystem()`` reads it from their declarations.
    private static var logRows: [NamespaceGoldenRow] {
        [NamespaceGoldenRow(.logSubsystem, Self.logSubsystemField, frozen: "com.fernlet", today: .unnamed)]
    }

    /// The four identity accounts' fields: ``theIdentityAccountsAreTheFourRowsAProvisionedIdentityWrites()``
    /// pins them by a real provision, whatever their `today` column says.
    static let identityAccountFields: Set<String> = [
        "installation.keychain.identity.signingPrivateKey",
        "installation.keychain.identity.keyAgreementPrivateKey",
        "installation.keychain.identity.signingPublicKeyCache",
        "installation.keychain.identity.keyAgreementPublicKeyCache"
    ]

    /// The log subsystem's field.
    static let logSubsystemField = "installation.logSubsystem"

    /// The table holds every namespace value exactly once, in the shape the design counts: 39 labels,
    /// 7 radio values, the QR scheme and host, 9 keychain names, 4 storage names, 1 log subsystem.
    /// The labels are pairwise distinct and none is a byte prefix of another — `signingBytes` matches
    /// by `starts(with:)` and several AADs are bare concatenations, so a prefix would be a collision.
    @Test func theTableHoldsEveryNamespaceValueOnce() {
        let table = Self.table
        #expect(table.count == 62, "the golden table has \(table.count) rows")
        let expected: [NamespaceGoldenRow.Group: Int] = [
            .label: 39, .radio: 7, .verifyQR: 2, .keychain: 9, .storage: 4, .logSubsystem: 1
        ]
        // R2: bounded by the six groups.
        for (group, count) in expected {
            let found = table.filter { $0.group == group }.count
            #expect(found == count, "\(group) has \(found) rows, the design counts \(count)")
        }
        #expect(Set(table.map(\.field)).count == table.count, "a namespace field appears twice")

        let labels = table.filter { $0.group == .label }.map { Data($0.frozen.utf8) }
        #expect(Set(labels).count == labels.count, "two labels share a spelling")
        var prefixed: [String] = []
        // R2: bounded by the 39 × 39 label pairs.
        for shorter in labels {
            for longer in labels where longer != shorter && longer.starts(with: shorter) {
                prefixed.append("\(String(decoding: shorter, as: UTF8.self)) ⊂ \(String(decoding: longer, as: UTF8.self))")
            }
        }
        #expect(prefixed.isEmpty, "labels that are byte prefixes of another: \(prefixed)")

        let unnamed = Set(table.filter { $0.today == .unnamed }.map(\.field))
        #expect(unnamed.isSubset(of: Self.identityAccountFields.union([Self.logSubsystemField])),
                "an unnamed row no behaviour cell pins: \(unnamed.sorted())")
    }

    /// The 39 labels, byte for byte.
    @Test func everyLabelIsItsFrozenSpelling() {
        #expect(Self.expectFrozen(.label) >= 39)
    }

    /// The service types, ALPNs and heartbeat of the three radios, byte for byte.
    @Test func everyRadioValueIsItsFrozenBytes() {
        #expect(Self.expectFrozen(.radio) >= 7)
    }

    /// The QR scheme and host, byte for byte.
    @Test func theVerifyQRSchemeAndHostAreTheirFrozenBytes() {
        #expect(Self.expectFrozen(.verifyQR) >= 2)
    }

    /// The identity service and both seal-key rows, byte for byte. The four identity accounts are
    /// pinned by a real provision in the next cell.
    @Test func everyNamedKeychainValueIsItsFrozenBytes() {
        #expect(Self.expectFrozen(.keychain) >= 5)
    }

    /// The directory and the three on-disk names, byte for byte — and the directory resolves under
    /// Application Support, the root the design's `Storage.defaultDirectory` names.
    @Test func everyStorageNameIsItsFrozenBytes() {
        #expect(Self.expectFrozen(.storage) >= 4)
        let expected = URL.applicationSupportDirectory
            .appendingPathComponent(Self.frozen("installation.storage.directoryName"), isDirectory: true)
        #expect(ProximitySupportLayout.defaultDirectory == expected,
                "the proximity sidecar root is \(ProximitySupportLayout.defaultDirectory.path), not \(expected.path)")
    }

    /// The four identity accounts, by what a real provision writes: `IdentityKeychainKey` is private,
    /// so a fresh identity on an isolated service is provisioned and that service's rows are listed.
    /// Exactly the four device accounts — no escrow row, which is minted only when backup is enabled.
    @Test func theIdentityAccountsAreTheFourRowsAProvisionedIdentityWrites() throws {
        let service = Self.isolatedIdentityService()
        defer { KeychainItem.deleteAll(service: service) }
        try IdentityService(keychainService: service).ensureProvisioned()

        let written = Set(KeychainItem.loadAll(service: service).map { $0.account })
        let frozen = Set(Self.table.filter { Self.identityAccountFields.contains($0.field) }.map(\.frozen))
        #expect(frozen.count == 4, "the table holds \(frozen.count) identity accounts")
        #expect(written == frozen, "a provisioned identity wrote \(written.sorted()); the table freezes \(frozen.sorted())")
    }

    /// The radios' log subsystem, read from the one `Logger` declaration in each radio's source.
    @Test func theThreeRadiosLogUnderTheFrozenSubsystem() throws {
        Self.expectFrozen(.logSubsystem)   // compares nothing until a later commit names the row
        let frozen = Self.frozen(Self.logSubsystemField)
        let radios = [
            "FernletKit/Sources/ProximityKit/Transport/NetworkMeshSession.swift",
            "FernletKit/Sources/ProximityKit/Transport/NetworkPresenceSession.swift",
            "FernletKit/Sources/ProximityKit/Transport/NetworkRecipeShareSession.swift"
        ]
        // R2: bounded by the three radios.
        for path in radios {
            let subsystems = Self.loggerSubsystems(in: try RepoRoot.source(path))
            #expect(subsystems == [frozen], "\(path) declares its Logger under \(subsystems), not [\(frozen)]")
        }
    }

    /// Every service type the namespace carries is declared in the app's `NSBonjourServices`: a type
    /// missing there fails discovery silently on device, with no log and no error.
    @Test func everyServiceTypeIsDeclaredInTheAppInfoPlist() throws {
        let declared = try NoTrackingBoundaryTests.declaredBonjourServiceTypes()
        #expect(!declared.isEmpty, "App/Fernlet/Info.plist declared no NSBonjourServices — the reader is broken")
        let serviceTypes = Self.table.filter { $0.field.hasSuffix(".serviceType") }.map(\.frozen)
        #expect(serviceTypes.count == 3)
        // R2: bounded by the three radios.
        for serviceType in serviceTypes {
            #expect(declared.contains(serviceType), "\(serviceType) is not in App/Fernlet/Info.plist NSBonjourServices")
        }
    }

    // MARK: Group 2 — known answers for the labels nothing else pinned

    /// The content key every column vector derives from: `00 01 … 1f`, FernletLockCryptoTests' key.
    static let columnContentKey = SymmetricKey(data: sequence(from: 0x00))

    /// The install binding every column vector is sealed under: `A7` × 16
    /// (`MeshSessionStoreFixtures.installA`).
    static let installBinding = Data(repeating: 0xA7, count: 16)

    /// HKDF-SHA256(`columnContentKey`, no salt, info `fernlet.mesh.session-context.v1`, 32).
    static let sessionColumnKeyHex = "05140c847fcf2310de39159e6bb63f15bdc45e2cbefca852babff8f641651a3c"

    /// HKDF-SHA256(`columnContentKey`, no salt, info `fernlet.mesh.routed-store.v1`, 32).
    static let routedColumnKeyHex = "88abbc36629412d103e0ab8a725996a367ced7c8456875d5381f1a5dabca30d3"

    /// V3 column blob, 39 bytes: `03` ‖ nonce `00…0b` ‖ ChaChaPoly(`["golden"]`) under the session
    /// column key with AAD `fernlet.mesh.session-context.v1` ‖ binding (crypto census §3.6).
    static let sessionColumnBlobHex = "03000102030405060708090a0ba1920d28007bc19c37b8ae79712f2be189cb51a4e38fc8a5b9e2"

    /// The same for `fernlet.mesh.routed-store.v1` (crypto census §3.6).
    static let routedColumnBlobHex = "03000102030405060708090a0b86a641157982173490f36a963d95d5f07342b61df00b128c113d"

    /// V3 blob, 49 bytes, nonce `10…1b`, plaintext `{"schemaVersion":99}` — a schema no build owns, so
    /// a store that reports 99 decrypted the bytes to read it. Session-context column.
    static let sessionStoreBlobHex =
        "03101112131415161718191a1b02d56166eff260f5e0ceb25e3bbcb65e1aa7ef61e86e252d842b2e01bcb2f933a73d21c8"

    /// The same plaintext and nonce under the routed-store column.
    static let routedStoreBlobHex =
        "03101112131415161718191a1ba4b8aa18f252b912c70bc5b06ff23ff5ed39af15f1fc28e5f303e00fb15bfd7a07f2456a"

    /// X25519 public key of the planted key-agreement key `60…7f`.
    static let plantedKeyAgreementPublicKeyHex = "675dd574ed7789310b3d2e7681f3790b466c773b1521fecf36577958371ea52f"

    /// `FGK2` group-key wrap to the planted key, 96 bytes: `FGK2` ‖ ephemeral public key (private
    /// `80…9f`) ‖ nonce `c0…cb` ‖ AES-256-GCM(group key `e0…ff`) under HKDF salt
    /// `fernlet.mesh.groupkey.v1` (info = ephemeral ‖ recipient) with AAD `fernlet.mesh.groupkey.wrap.aead.v2`.
    static let groupKeyWrapHex = "46474b32493e82fc74464a59268817623d2053c5eb8e2cc4a988b4fee179ec6b010d531dc0c1c2c3c4c5"
        + "c6c7c8c9cacbf5404ca8b35cf9c1794714bddf1960341a9d64f4b340a0b9b13b332933365a352ade1f485918499a370460a36ba60186"

    /// The X25519 public key of the transport vector's sender static key `20…3f`.
    static let transportSenderPublicKeyHex = "358072d6365880d1aeea329adf9121383851ed21a28e3b75e965d0d2cd166254"

    /// `FPT2` transport seal to the planted key, 92 bytes: `FPT2` ‖ ephemeral public key (private
    /// `a0…bf`) ‖ ChaChaPoly(`fernlet golden transport`, nonce `d0…db`) under HKDF salt
    /// `fernlet.proximity.v1` (info = sender ‖ recipient) with AAD
    /// `fernlet.proximity.transport.aead.v2` ‖ sender.
    static let transportSealHex = "46505432605a725d2a4adfeeb1a29e17edd621c1b7593ee8cdbc44ac6c4ab6e2f805d23cd0d1d2d3d4d5"
        + "d6d7d8d9dadb66bf51abaace59e289c9dab60d9c402168eaa30ac8eb11e4cff88a3ab81b6dd2891b642f0cce9d4c"

    /// The routed wrap's recipient public key (private `30…4f`) and ephemeral public key (private `90…af`).
    static let routedRecipientPublicKeyHex = "34e42d4af5ef94a07a3a84201b889d4cd1a743cb27b11b6a10438a8feb8e5847"
    static let routedEphemeralPublicKeyHex = "9fd7ad6dcff4298dd3f96d5b1b2af910a0535b1488d7f8fabb349a982880b615"

    /// The routed per-recipient wrap of content key `10…2f`: AES-256-GCM, nonce `b0…bb`, under HKDF
    /// salt `fernlet.mesh.routed.content-key.v1` (info = ephemeral ‖ recipient), with the AAD
    /// `MeshRoutedManifestGoldenTests.goldenWrapAADHex` pins (mesh `1F1F…`, item `5A5A…`, `fp001` → `fp002`).
    static let routedSealedKeyHex = "c8c9ae877144ea9ef3d40b5e4c7961d9a4164d6f15cbaff16ee377cdaaaf4e58"
        + "852ff83c5ea99c35050d4196b41654bc"

    /// One mesh column's vectors, with today's accessor for its purpose.
    private struct ColumnVector {
        let name: String
        let purpose: CryptographicPurpose
        let columnKeyHex: String
        let blobHex: String
    }

    /// The two mesh columns.
    private static var columnVectors: [ColumnVector] {
        [
            ColumnVector(name: "session-context", purpose: FernletCryptoPurpose.KeyDerivation.meshSessionContextV1,
                         columnKeyHex: sessionColumnKeyHex, blobHex: sessionColumnBlobHex),
            ColumnVector(name: "routed-store", purpose: FernletCryptoPurpose.KeyDerivation.meshRoutedStoreV1,
                         columnKeyHex: routedColumnKeyHex, blobHex: routedColumnBlobHex)
        ]
    }

    /// The two mesh column keys: salt-free HKDF with the label as `info`.
    @Test func theTwoMeshColumnKeysAreTheirKnownAnswers() {
        // R2: bounded by the two columns.
        for vector in Self.columnVectors {
            let key = ColumnCrypto.deriveColumnKey(contentKey: Self.columnContentKey, purpose: vector.purpose,
                                                   outputByteCount: 32)
            let actual = Self.hex(key.withUnsafeBytes { Data($0) })
            #expect(actual == vector.columnKeyHex, "\(vector.name) column key moved — actual hex = \(actual)")
        }
    }

    /// A V3 blob built from the literal label opens under each column's purpose and the pinned binding:
    /// the label is the HKDF `info` AND the front of the AAD, in that order.
    @Test func theTwoKnownColumnBlobsOpenUnderTheirPurposes() throws {
        try DeviceBindingID.$testOverride.withValue(.identifier(Self.installBinding)) {
            // R2: bounded by the two columns.
            for vector in Self.columnVectors {
                let blob = try #require(Self.bytes(hex: vector.blobHex))
                #expect(blob.first == 0x03)
                let opened: [String]? = try ColumnCrypto(purpose: vector.purpose).open(blob, contentKey: Self.columnContentKey)
                #expect(opened == ["golden"], "the \(vector.name) column did not open its known blob")
            }
        }
    }

    /// The session store, on an isolated scope, opens a blob planted at the frozen file name under a
    /// seal key planted at the frozen account — so the store's file name, its seal-key account, its
    /// column purpose and the binding's place in the AAD are all pinned by one load.
    @Test func theSessionStoreOpensItsKnownBlobUnderItsFrozenNames() throws {
        let scope = MeshSessionStorageScope(
            directory: Self.scratchDirectory(),
            keychainService: "com.fernlet.mesh-session.test.namespacegolden.\(UUID().uuidString)"
        )
        defer {
            MeshSessionStore.wipeForDeleteAll(scope: scope)
            try? FileManager.default.removeItem(at: scope.directory)
        }
        Self.plantSealKey(account: Self.frozen("installation.keychain.meshSessionSealKey.account"),
                          service: scope.keychainService)
        try Self.writeBlob(Self.sessionStoreBlobHex, named: Self.frozen("installation.storage.meshSessionContextFileName"),
                           in: scope.directory)

        let load = DeviceBindingID.$testOverride.withValue(.identifier(Self.installBinding)) {
            MeshSessionStore(scope: scope).load()
        }
        guard case .corrupt(let corruption) = load, case .unsupportedSchemaVersion(let version) = corruption.detail else {
            Issue.record("the session store did not decrypt its known blob at its frozen names: \(load)")
            return
        }
        #expect(version == 99)
    }

    /// The routed store, likewise: its index file name, seal-key account and column purpose by one
    /// load, and its chunk directory by the path it composes.
    @Test func theRoutedStoreOpensItsKnownBlobUnderItsFrozenNames() throws {
        let scope = MeshRoutedStorageScope(
            directory: Self.scratchDirectory(),
            keychainService: "com.fernlet.mesh-routed.test.namespacegolden.\(UUID().uuidString)"
        )
        defer {
            MeshRoutedStore.wipeForDeleteAll(scope: scope)
            try? FileManager.default.removeItem(at: scope.directory)
        }
        Self.plantSealKey(account: Self.frozen("installation.keychain.meshRoutedSealKey.account"),
                          service: scope.keychainService)
        try Self.writeBlob(Self.routedStoreBlobHex, named: Self.frozen("installation.storage.meshRoutedIndexFileName"),
                           in: scope.directory)

        let store = MeshRoutedStore(scope: scope)
        let chunks = scope.directory.appendingPathComponent(
            Self.frozen("installation.storage.meshRoutedChunkDirectoryName"), isDirectory: true)
        #expect(store.chunkDirectory == chunks, "the routed store keeps its chunks at \(store.chunkDirectory.path)")
        let load = DeviceBindingID.$testOverride.withValue(.identifier(Self.installBinding)) { store.load() }
        guard case .corrupt(let corruption) = load, case .unsupportedSchemaVersion(let version) = corruption.detail else {
            Issue.record("the routed store did not decrypt its known blob at its frozen names: \(load)")
            return
        }
        #expect(version == 99)
    }

    /// The group-key wrap: an `FGK2` blob built from the literal salt and AAD opens to its known key in
    /// the real `decryptGroupKey`, over an identity planted at the frozen account names.
    @Test func aLiteralBuiltGroupKeyWrapOpensToItsKnownKey() throws {
        let planted = try Self.plantedIdentity()
        defer { KeychainItem.deleteAll(service: planted.service) }
        let wrap = try #require(Self.bytes(hex: Self.groupKeyWrapHex))
        do {
            let opened = try planted.identity.decryptGroupKey(wrap)
            #expect(opened == Self.sequence(from: 0xE0), "the FGK2 wrap opened to \(Self.hex(opened))")
        } catch {
            Issue.record("production refused the literal-built FGK2 wrap (\(error)): its salt, AAD or marker moved")
        }
    }

    /// The transport seal: an `FPT2` blob built from the literal salt and AAD opens to its known
    /// plaintext in the real `open`, over the same planted identity.
    @Test func aLiteralBuiltTransportSealOpensToItsKnownPlaintext() throws {
        let planted = try Self.plantedIdentity()
        defer { KeychainItem.deleteAll(service: planted.service) }
        let sealed = try #require(Self.bytes(hex: Self.transportSealHex))
        let sender = try #require(Self.bytes(hex: Self.transportSenderPublicKeyHex))
        do {
            let opened = try planted.identity.open(sealed, from: sender)
            #expect(opened == Data("fernlet golden transport".utf8), "the FPT2 seal opened to \(Self.hex(opened))")
        } catch {
            Issue.record("production refused the literal-built FPT2 seal (\(error)): its salt, AAD or marker moved")
        }
    }

    /// The routed per-recipient key wrap opens to its known content key in the real `unwrap`. The
    /// recipient's static agreement is a closure, so no keychain is involved.
    @Test func aLiteralBuiltRoutedContentKeyWrapOpensToItsKnownKey() throws {
        let recipient = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Self.sequence(from: 0x30))
        #expect(Self.hex(recipient.publicKey.rawRepresentation) == Self.routedRecipientPublicKeyHex)
        let wrap = MeshRecipientKeyWrap(
            recipientFingerprint: "fp002",
            ephemeralPublicKey: try #require(Self.bytes(hex: Self.routedEphemeralPublicKeyHex)),
            nonce: Self.sequence(from: 0xB0, count: 12),
            sealedKey: try #require(Self.bytes(hex: Self.routedSealedKeyHex))
        )
        let binding = MeshRoutedWrapBinding(
            meshID: try #require(UUID(uuidString: "1F1F1F1F-2E2E-4D4D-8C8C-0B0B0B0B0B0B")),
            itemID: try #require(UUID(uuidString: "5A5A5A5A-6B6B-4C4C-8D8D-3E3E3E3E3E3E")),
            originFingerprint: "fp001"
        )
        do {
            let opened = try MeshRoutedContentKeyWrapper.unwrap(
                wrap, binding: binding, localFingerprint: "fp002",
                localKeyAgreementPublicKey: recipient.publicKey.rawRepresentation,
                staticAgreement: { try recipient.sharedSecretFromKeyAgreement(
                    with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: $0)) }
            )
            #expect(opened == Self.sequence(from: 0x10), "the routed wrap opened to \(Self.hex(opened))")
        } catch {
            Issue.record("production refused the literal-built routed key wrap (\(error)): its salt or AAD moved")
        }
    }

    /// The closed-mode metadata door: a wrapper built from the literal `FMGM2` marker and the literal
    /// AAD opens under the joined mesh's group key and is dispatched — the descriptor inside it renames
    /// the mesh. `decryptPayload` is private, so the manager's own inbound door is the way in.
    ///
    /// The control is the same frame sealed under the group-key-wrap label and stamped LATER, so it
    /// would win the name if it opened: a door keyed to that neighbouring label ends on "Refused",
    /// and one keyed to any other label, or to none, stays on "Before".
    @Test func aLiteralBuiltMetadataWrapperOpensUnderTheGroupKey() async throws {
        let store = makeTestStore()
        defer { withExtendedLifetime(store) {} }   // `MeshNetworkManager.store` is `unowned`
        let manager = MeshNetworkManager(store: store)
        let coordinator = Self.unprovisionedCoordinator()
        manager.addSlotForTesting(coordinator: coordinator,
                                  peer: PeerHandle(id: UUID(), displayHint: "Member", discoveryInfo: nil,
                                                   advertisedFingerprint: nil),
                                  fingerprint: "fp-member")
        let admitterService = Self.isolatedIdentityService()
        defer { KeychainItem.deleteAll(service: admitterService) }
        let admitter = IdentityService(keychainService: admitterService)
        try admitter.ensureProvisioned()
        let groupKey = Self.sequence(from: 0x70)
        let mesh = try Self.join(manager, on: coordinator, admitter: admitter, groupKey: groupKey, epoch: 5)
        #expect(manager.currentGroupKey?.keyBytes == groupKey, "precondition: the join installed the group key")

        let control = Self.renamed(mesh, to: "Refused", secondsLater: 2)
        try Self.deliverMetadata(control, label: Self.frozen("family.purposes.aead.meshGroupKeyWrapV2"),
                                 groupKey: groupKey, nonce: Self.sequence(from: 0x5C, count: 12), epoch: 5,
                                 to: manager, on: coordinator)
        let golden = Self.renamed(mesh, to: "Golden", secondsLater: 1)
        try Self.deliverMetadata(golden, label: Self.frozen("family.purposes.aead.meshEncryptedMetadataV2"),
                                 groupKey: groupKey, nonce: Self.sequence(from: 0x50, count: 12), epoch: 5,
                                 to: manager, on: coordinator)

        await Self.waitUntil { manager.currentMesh?.name == "Golden" }
        // Both handlers run as spawned tasks; let them drain so a late open of the control would show.
        for _ in 0..<20 { await Task.yield() }
        #expect(manager.currentMesh?.name == "Golden", """
            the metadata door did not open the literal-built FMGM2 wrapper, or opened the control: the \
            mesh is named \(manager.currentMesh?.name ?? "nothing")
            """)
    }

    // MARK: Group 3 — transcripts, epoch ids and the tokens spelled like labels

    /// `lp(fernlet.mesh.channel-introduction.v1)`: the 8-byte length, then the label.
    static let channelIntroductionPrefixHex =
        "00000000000000246665726e6c65742e6d6573682e6368616e6e656c2d696e74726f64756374696f6e2e7631"

    /// `fernlet.verify.qr.v1` raw, then the version byte `01`.
    static let verifyQRPrefixHex = "6665726e6c65742e7665726966792e71722e763101"

    /// `fernlet.verify.response.v1` raw, then the scanner key's first byte (`44` in the fixture).
    static let verifyResponsePrefixHex = "6665726e6c65742e7665726966792e726573706f6e73652e763144"

    /// The channel introduction transcript opens with its label LENGTH-PREFIXED, and the registry
    /// purpose accepts it.
    @Test func theChannelIntroductionTranscriptOpensWithItsFramedLabel() throws {
        let transcript = canonicalBytes(for: MeshChannelIntroductionTranscript(
            protocolVersion: MeshChannelIntroductionFormat.protocolVersion,
            meshID: try #require(UUID(uuidString: "1F1F1F1F-2E2E-4D4D-8C8C-0B0B0B0B0B0B")),
            epochRef: "7",
            initiatorSigningPublicKey: Data(repeating: 0x06, count: 32),
            responderSigningPublicKey: Data(repeating: 0x07, count: 32),
            initiatorNonce: Data(repeating: 0x08, count: 16),
            responderNonce: Data(repeating: 0x09, count: 16),
            channelBindingHash: Data(repeating: 0x0A, count: 32)
        ))
        let prefix = try #require(Self.bytes(hex: Self.channelIntroductionPrefixHex))
        #expect(transcript.count > prefix.count)
        #expect(transcript.prefix(prefix.count) == prefix,
                "actual prefix hex = \(Self.hex(transcript.prefix(prefix.count)))")
        #expect(FernletCryptoPurpose.Signature.meshChannelIntroductionV1.signingBytes(transcript) != nil)
    }

    /// The verify QR transcript opens with its label RAW, the version byte straight after it, and is
    /// exactly 109 bytes: label 20 ‖ version 1 ‖ two keys 64 ‖ timestamp 8 ‖ nonce 16.
    @Test func theVerifyQRTranscriptOpensWithItsRawLabel() throws {
        let transcript = ProximityVerifyQR.canonicalBytes(
            version: 1,
            signingPublicKey: Data(repeating: 0x11, count: 32),
            keyAgreementPublicKey: Data(repeating: 0x22, count: 32),
            timestamp: 1_700_000_000,
            nonce: Data(repeating: 0x33, count: 16)
        )
        let prefix = try #require(Self.bytes(hex: Self.verifyQRPrefixHex))
        #expect(transcript.prefix(prefix.count) == prefix,
                "actual prefix hex = \(Self.hex(transcript.prefix(prefix.count)))")
        #expect(transcript.count == 109, "the QR transcript is \(transcript.count) bytes")
        #expect(FernletCryptoPurpose.Signature.proximityQRIdentityV1.signingBytes(transcript) != nil)
    }

    /// The verify response transcript opens with its label RAW, the scanner's key straight after it,
    /// and is exactly 90 bytes: label 26 ‖ scanner key 32 ‖ two nonces 32.
    @Test func theVerifyResponseTranscriptOpensWithItsRawLabel() throws {
        let transcript = ProximityVerifySignature.message(
            scannerKeyAgreementPublicKey: Data(repeating: 0x44, count: 32),
            challengeNonce: Data(repeating: 0x55, count: 16),
            qrNonce: Data(repeating: 0x66, count: 16)
        )
        let prefix = try #require(Self.bytes(hex: Self.verifyResponsePrefixHex))
        #expect(transcript.prefix(prefix.count) == prefix,
                "actual prefix hex = \(Self.hex(transcript.prefix(prefix.count)))")
        #expect(transcript.count == 90, "the response transcript is \(transcript.count) bytes")
        #expect(FernletCryptoPurpose.Signature.proximityQRResponseV1.signingBytes(transcript) != nil)
    }

    /// The two epoch ids `MeshMembershipEventGoldenTests.goldenEpochHeadsHex` embeds, pinned on their
    /// own: SHA-256 over the RAW epoch domain ‖ lowercase mesh id ‖ u32 counter ‖ fingerprint, first 16
    /// bytes. A length-prefixed domain, or another label, moves both.
    @Test func theEpochIDsAreTheirKnownAnswers() throws {
        let meshID = try #require(UUID(uuidString: "1F1F1F1F-2E2E-4D4D-8C8C-0B0B0B0B0B0B"))
        let first = try #require(MeshEpochRef.minted(counter: 7, coordinatorFingerprint: "00000000000000aa", meshID: meshID))
        let second = try #require(MeshEpochRef.minted(counter: 7, coordinatorFingerprint: "00000000000000bb", meshID: meshID))
        let firstID = first.epochID.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let secondID = second.epochID.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        #expect(firstID == "355c877a3834ff2b9b86b074fccaf2e7", "actual epoch id = \(firstID)")
        #expect(secondID == "da5a41f47fff542d2acaf1260ab01d31", "actual epoch id = \(secondID)")
        #expect(first.canonicalString == "7.355c877a3834ff2b9b86b074fccaf2e7.00000000000000aa")
    }

    /// The wire tokens spelled exactly like a signature label — fifteen `PayloadType` tokens and three
    /// membership record kinds — still equal the frozen label. `meshKeyAgreement` and `verifyResponse`
    /// had no such pin before this suite. The fourth record kind equals no label; it is persisted and
    /// hashed into the signed inventory digest, so it is pinned by literal beside them.
    @Test func theWireTokensSpelledLikeALabelStillEqualIt() {
        let signature = "family.purposes.signature."
        let vocabulary: [(token: String, spelling: String, label: String)] = [
            ("PayloadType.verifyResponse", PayloadType.verifyResponse.rawValue, "proximityQRResponseV1"),
            ("PayloadType.meshKeyAgreement", PayloadType.meshKeyAgreement.rawValue, "meshKeyAgreementV1"),
            ("PayloadType.meshMemberDeparture", PayloadType.meshMemberDeparture.rawValue, "meshMemberDepartureV1"),
            ("PayloadType.meshMemberRemoval", PayloadType.meshMemberRemoval.rawValue, "meshMemberRemovalV1"),
            ("PayloadType.meshTerminated", PayloadType.meshTerminated.rawValue, "meshTerminatedV1"),
            ("PayloadType.meshInventoryDigest", PayloadType.meshInventoryDigest.rawValue, "meshInventoryDigestV1"),
            ("PayloadType.meshEpochHeads", PayloadType.meshEpochHeads.rawValue, "meshEpochHeadsV1"),
            ("PayloadType.meshRemovalProposalSigned", PayloadType.meshRemovalProposalSigned.rawValue,
             "meshRemovalProposalV1"),
            ("PayloadType.meshRemovalVote", PayloadType.meshRemovalVote.rawValue, "meshRemovalVoteV1"),
            ("PayloadType.meshRoutedManifest", PayloadType.meshRoutedManifest.rawValue, "meshRoutedManifestV1"),
            ("PayloadType.meshRoutedChunk", PayloadType.meshRoutedChunk.rawValue, "meshRoutedChunkV1"),
            ("PayloadType.meshCustodyReceipt", PayloadType.meshCustodyReceipt.rawValue, "meshCustodyReceiptV1"),
            ("PayloadType.meshRecipientReceipt", PayloadType.meshRecipientReceipt.rawValue, "meshRecipientReceiptV1"),
            ("PayloadType.meshRoutedInventoryDigest", PayloadType.meshRoutedInventoryDigest.rawValue,
             "meshRoutedInventoryDigestV1"),
            ("PayloadType.meshRoutedDrainAnswer", PayloadType.meshRoutedDrainAnswer.rawValue, "meshRoutedDrainAnswerV1"),
            ("MeshMembershipRecordKind.departure", MeshMembershipRecordKind.departure.rawValue, "meshMemberDepartureV1"),
            ("MeshMembershipRecordKind.removal", MeshMembershipRecordKind.removal.rawValue, "meshMemberRemovalV1"),
            ("MeshMembershipRecordKind.termination", MeshMembershipRecordKind.termination.rawValue, "meshTerminatedV1")
        ]
        #expect(vocabulary.count == 18)
        // R2: bounded by the eighteen tokens.
        for entry in vocabulary {
            let frozen = Self.frozen(signature + entry.label)
            #expect(entry.spelling == frozen, "\(entry.token) is \(entry.spelling); the label it equals is \(frozen)")
        }
        #expect(MeshMembershipRecordKind.admission.rawValue == "fernlet.mesh.member-admission.v1",
                "the admission record kind moved: \(MeshMembershipRecordKind.admission.rawValue)")
    }

    // MARK: Group 4 — the format constants that stay ProximityKit's

    /// The markers, the column byte and the two extensions, by their constants where a test can name
    /// one, and by what the production writers stamp where the constant is private (`FPT2`, `FGK2`).
    /// `FMGM2` has no writer left; ``aLiteralBuiltMetadataWrapperOpensUnderTheGroupKey()`` pins its reader.
    @Test func theFormatConstantsKeepTheirBytes() throws {
        #expect(MeshRoutedItemSealFormat.marker == Data("FMRI1".utf8))
        #expect(ColumnCrypto.deviceBoundFormatVersionV3 == 0x03)
        #expect(MeshSessionStore.quarantineExtension == "corrupt")
        #expect(MeshRoutedStore.quarantineExtension == "corrupt")
        #expect(MeshRoutedStore.chunkFileExtension == "chunk")
        #expect(URL(fileURLWithPath: MeshRoutedStore.newChunkFileName()).pathExtension == "chunk")

        let service = Self.isolatedIdentityService()
        defer { KeychainItem.deleteAll(service: service) }
        let identity = IdentityService(keychainService: service)
        try identity.ensureProvisioned()
        let sealed = try identity.seal(Data("marker".utf8), to: identity.localKeyAgreementPublicKey)
        #expect(sealed.prefix(4) == Data("FPT2".utf8), "the transport seal starts \(Self.hex(sealed.prefix(4)))")
        let wrapped = try identity.encryptGroupKey(Self.sequence(from: 0xE0), for: identity.localKeyAgreementPublicKey)
        #expect(wrapped.prefix(4) == Data("FGK2".utf8), "the group-key wrap starts \(Self.hex(wrapped.prefix(4)))")
        #expect(wrapped.count == 96)
    }

    /// The verify QR's URL: scheme, host, the one query key `d` and payload version 1. A URL written
    /// by hand from those spellings parses, and the payload it carries is version 1 and valid.
    @Test func theVerifyQRURLKeepsItsHostQueryKeyAndVersion() throws {
        let service = Self.isolatedIdentityService()
        defer { KeychainItem.deleteAll(service: service) }
        let identity = IdentityService(keychainService: service)
        try identity.ensureProvisioned()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let made = try ProximityVerifyQR.makeURL(identity: identity, now: now)
        let components = try #require(URLComponents(url: made.url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "fernlet")
        #expect(components.host == "verify")
        #expect(components.queryItems?.map(\.name) == ["d"])
        let encoded = try #require(components.queryItems?.first?.value)
        let handBuilt = try #require(URL(string: "fernlet://verify?d=" + encoded))
        let payload = try #require(ProximityVerifyQR.parse(handBuilt), "a hand-built verify URL no longer parses")
        #expect(payload.version == 1)
        #expect(ProximityVerifyQR.isValid(payload, at: now))
    }

    // MARK: Helpers

    /// Compares every named row of `group` with its frozen literal, byte for byte, and returns how
    /// many it compared.
    @discardableResult
    private static func expectFrozen(_ group: NamespaceGoldenRow.Group) -> Int {
        var compared = 0
        // R2: bounded by the table.
        for row in table where row.group == group {
            guard let actual = row.todayBytes else { continue }
            compared += 1
            #expect(actual == Data(row.frozen.utf8), """
                \(row.field) moved: today it is "\(String(decoding: actual, as: UTF8.self))" \
                (\(hex(actual))), its frozen literal is "\(row.frozen)". Re-point the accessor; never \
                the literal.
                """)
        }
        return compared
    }

    /// The frozen literal of `field`, so a fixture spells a name the table pins instead of restating it.
    static func frozen(_ field: String) -> String {
        guard let row = table.first(where: { $0.field == field }) else {
            Issue.record("the golden table has no row \(field)")
            return ""
        }
        return row.frozen
    }

    /// Every `Logger(subsystem: "…"` literal in `source`, in order.
    private static func loggerSubsystems(in source: String) -> [String] {
        let opener = "Logger(subsystem: \""
        var found: [String] = []
        var rest = Substring(source)
        // R2: each pass consumes the opener it found, so the loop ends within the source's length.
        while let start = rest.range(of: opener) {
            let tail = rest[start.upperBound...]
            guard let close = tail.firstIndex(of: "\"") else { break }
            found.append(String(tail[..<close]))
            rest = tail[close...]
        }
        return found
    }

    /// A fresh identity keychain service nobody else uses.
    private static func isolatedIdentityService() -> String {
        "com.fernlet.identity.test.namespacegolden.\(UUID().uuidString)"
    }

    /// A fresh scratch directory nobody else uses.
    private static func scratchDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ProximityNamespaceGolden-\(UUID().uuidString)", isDirectory: true)
    }

    /// An identity whose two private keys are planted at the frozen account names — signing `40…5f`,
    /// key agreement `60…7f` — and adopted by `ensureProvisioned()`'s first case. If the accounts
    /// moved, provisioning would mint fresh keys and nothing planted for the vectors would open.
    private static func plantedIdentity() throws -> (identity: IdentityService, service: String) {
        let service = isolatedIdentityService()
        let accessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let signing = KeychainItem.store(sequence(from: 0x40), account: frozen("installation.keychain.identity.signingPrivateKey"),
                                         service: service, accessibility: accessibility)
        let agreement = KeychainItem.store(sequence(from: 0x60),
                                           account: frozen("installation.keychain.identity.keyAgreementPrivateKey"),
                                           service: service, accessibility: accessibility)
        #expect(signing == errSecSuccess && agreement == errSecSuccess, "the planted identity rows did not land")
        let identity = IdentityService(keychainService: service)
        try identity.ensureProvisioned()
        #expect(hex(identity.localKeyAgreementPublicKey) == plantedKeyAgreementPublicKeyHex,
                "provisioning did not adopt the planted key agreement key")
        return (identity, service)
    }

    /// Plants the column content key under `account` in `service`.
    private static func plantSealKey(account: String, service: String) {
        let status = KeychainItem.store(sequence(from: 0x00), account: account, service: service,
                                        accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
        #expect(status == errSecSuccess, "the planted seal key did not land: \(status)")
    }

    /// Writes a hex vector to `name` inside `directory`.
    private static func writeBlob(_ blobHex: String, named name: String, in directory: URL) throws {
        let blob = try #require(bytes(hex: blobHex))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try blob.write(to: directory.appendingPathComponent(name, isDirectory: false))
    }

    /// A coordinator the manager only identity-compares against its slots. Never provisioned, so it
    /// writes no keychain row (the `MeshEncryptionTests` harness).
    private static func unprovisionedCoordinator() -> ProximityCoordinator {
        ProximityCoordinator(
            identity: IdentityService(keychainService: isolatedIdentityService()),
            transport: MockMultipeerTransport(),
            ranging: MockRangingProvider(),
            replayCache: ReplayCache(),
            displayName: "Local",
            timeoutSeconds: 0)
    }

    /// Drives the real descriptor → grant join so the manager holds `groupKey` at `epoch`: the group
    /// key is private-set, so the join (which itself opens a production `FGK2` wrap) is the only way in.
    private static func join(_ manager: MeshNetworkManager, on coordinator: ProximityCoordinator,
                             admitter: IdentityService, groupKey: Data, epoch: Int) throws -> MeshDescriptor {
        let now = Date()
        let member = MeshMember(fingerprint: IdentityService.fingerprint(of: admitter.localSigningPublicKey),
                                displayName: "Admitter", signingPublicKey: admitter.localSigningPublicKey,
                                keyAgreementPublicKey: admitter.localKeyAgreementPublicKey, joinedAt: now)
        let mesh = MeshDescriptor(meshID: UUID(), name: "Before", mode: .open, members: [member],
                                  nameSetAt: now, nameSetBy: member.fingerprint,
                                  modeSetAt: now, modeSetBy: member.fingerprint, createdAt: now)
        try deliver(.meshDescriptor, MeshStateChangePayload(descriptor: mesh), to: manager, on: coordinator, from: nil)
        let token = try MeshAdmissionToken.signed(meshID: mesh.meshID, joinerFingerprint: manager.localFingerprint,
                                                  joinerSigningPublicKey: manager.localSigningPublicKey,
                                                  admitterIdentity: admitter)
        let grant = MeshAdmissionGrantPayload(
            meshID: mesh.meshID, requesterFingerprint: manager.localFingerprint, token: token,
            encryptedCurrentKey: try admitter.encryptGroupKey(groupKey, for: manager.localKeyAgreementPublicKey),
            currentKeyEpoch: epoch)
        try deliver(.meshAdmissionGrant, grant, to: manager, on: coordinator, from: peerIdentity(for: admitter))
        return mesh
    }

    /// `mesh` renamed `name`, its name stamped `secondsLater` after the original's.
    private static func renamed(_ mesh: MeshDescriptor, to name: String, secondsLater: TimeInterval) -> MeshDescriptor {
        var renamed = mesh
        renamed.name = name
        renamed.nameSetAt = mesh.nameSetAt.addingTimeInterval(secondsLater)
        return renamed
    }

    /// Seals `descriptor` as `FMGM2` ‖ AES-256-GCM(ciphertext ‖ tag) under the group key with `label`
    /// as the AAD — the marker and the label spelled from literals, never from production constants —
    /// and hands the wrapper to the manager's inbound door.
    private static func deliverMetadata(_ descriptor: MeshDescriptor, label: String, groupKey: Data, nonce: Data,
                                        epoch: Int, to manager: MeshNetworkManager,
                                        on coordinator: ProximityCoordinator) throws {
        let inner = try JSONEncoder().encode(EncryptedMetadataInner(
            payloadType: PayloadType.meshDescriptor.rawValue,
            payload: try JSONEncoder().encode(MeshStateChangePayload(descriptor: descriptor))))
        let box = try AES.GCM.seal(inner, using: SymmetricKey(data: groupKey), nonce: try AES.GCM.Nonce(data: nonce),
                                   authenticating: Data(label.utf8))
        let wrapper = MeshEncryptedMetadataPayload(ciphertext: Data("FMGM2".utf8) + box.ciphertext + box.tag,
                                                   nonce: nonce, keyEpoch: epoch)
        try deliver(.meshEncryptedMetadata, wrapper, to: manager, on: coordinator, from: nil)
    }

    /// Hands one already-verified envelope to the manager, as the coordinator does.
    private static func deliver<Payload: Encodable>(
        _ type: PayloadType, _ payload: Payload, to manager: MeshNetworkManager,
        on coordinator: ProximityCoordinator, from peer: ProximityCoordinator.PeerIdentity?
    ) throws {
        let plaintext = try JSONEncoder().encode(payload)
        let envelope = FernletIdentityEnvelope(
            schemaVersion: FernletIdentityEnvelope.currentSchemaVersion, envelopeID: UUID(),
            senderSigningPublicKey: Data(), senderKeyAgreementPublicKey: Data(), senderDisplayName: "Peer",
            recipientFingerprint: nil, payloadType: type, payloadEncryption: .none,
            payloadSummary: PayloadSummary(title: "Golden"), payload: plaintext, createdAt: Date(),
            expiresAt: nil, signature: Data())
        manager.proximityCoordinator(coordinator, didReceive: envelope, plaintext: plaintext, from: peer)
    }

    /// The identity a grant is credited to.
    private static func peerIdentity(for identity: IdentityService) -> ProximityCoordinator.PeerIdentity {
        ProximityCoordinator.PeerIdentity(
            id: UUID(), displayName: "Admitter", signingPublicKey: identity.localSigningPublicKey,
            keyAgreementPublicKey: identity.localKeyAgreementPublicKey,
            fingerprint: IdentityService.fingerprint(of: identity.localSigningPublicKey),
            rangingMode: .none, firstSeenAt: Date())
    }

    /// Polls until `condition` holds, giving up only after the deadline AND `minimumPolls` real looks,
    /// so a starved main actor cannot time out having barely looked (the `MeshEncryptionTests` rule).
    private static func waitUntil(timeout: Duration = .seconds(3), minimumPolls: Int = 400,
                                  _ condition: @escaping @MainActor () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var polls = 0
        // R2: ends once both the poll count and the deadline are reached; every pass sleeps.
        while !condition() {
            polls += 1
            if polls >= minimumPolls, clock.now >= deadline { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Lowercase hex.
    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// Bytes from an even-length hex literal, or nil for anything else.
    static func bytes(hex: String) -> Data? {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var out = Data()
        var index = hex.startIndex
        // R2: each pass consumes two characters of a finite literal.
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }

    /// `count` bytes counting up from `start` — the fixed key material every vector here is built on.
    static func sequence(from start: UInt8, count: Int = 32) -> Data {
        Data((0..<count).map { start &+ UInt8($0) })
    }
}
