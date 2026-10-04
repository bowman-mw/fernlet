// FernletFeatureGoldenTests.swift
// FernletTests
//
// Fernlet's features over the proximity stack (the heart dead-drop, presence, moderation, closeness,
// friend state, and the sealed-backup escrow beside the identity) put bytes on the wire,
// in the keychain and on disk that no other suite pins, and plan step A0.4 moves every one of those
// features or re-derives its bytes (Docs/Plan-FernletCoach-ProximityKit-2026-10-01.md §4 A0.4). This
// suite holds each such byte to the value Fernlet ships: by a hand-written literal, and wherever a
// production consumer can be reached without a new seam, by driving that consumer and reading what it
// emits or opens. Moving a feature moves no byte; this file is how that claim is checked rather than
// asserted.
//
// THE RULE. Every literal is FROZEN: a red cell is a wire, keychain or at-rest decision, never
// re-pinned from Swift's output. A cell reaches production only through today's production spellings:
// the label rows' `today` column, the name rows' `today` column, and the accessors gathered under
// "Accessors" at the foot of the suite. When a value or its reader moves, only its accessor is
// re-pointed at the path production then reads, and a moved consumer no cell drives yet gains a cell.
//
// Fourteen groups:
//
// 1. **The seven feature labels** of the heart dead-drop, presence and the ban store: the heart pair
//    salt, the sealed drop's salt, the day-tag prefix, the sidecar's authenticated data, the presence
//    pair salt, the presence epoch-tag prefix and the ban evidence's reporter-tag domain, each read
//    where its feature reads it: the two pair salts as the feature purposes `.fernlet` declares, which
//    the heart dead-drop and presence hand ProximityKit's pair-secret door, and the other five as the
//    FernletCrypto registry entries their features hand CryptoKit themselves.
// 2. **The pair secrets.** The heart-drop and presence pair secrets of two planted identities, from
//    either side, and their refusals in their order: no key-agreement key first, a malformed peer key
//    then.
// 3. **The tags and the clocks.** Two heart day tags, three presence tags with their wire tokens, and
//    the day epoch at its boundaries.
// 4. **Moderation's two hashes**: the ban evidence's reporter tag and a reported artwork's content
//    hash, a known answer each (the content hash through both its doors).
// 5. **The sealed drop**: the drop key's known answer from primitives, then a frozen static-key drop
//    opened through the sealer.
// 6. **The sealed sidecar**: a frozen `FSC2` blob opened under a planted key.
// 7. **The prekey bundle**: its JSON both ways, with and without its signed prekey, the prekey store's
//    bundle types as the core wire type the introduction carries, and both directions of the identity
//    introduction that gossips it.
// 8. **The keychain names**: the heart-drop service and its two accounts, the ban store's two accounts
//    by behaviour, and the mesh stores' services derived beside the heart-drop service.
// 9. **The storage names**: five stores' file names, and the production heart-drop scope's folder and
//    service.
// 10. **The persisted shapes**: a closeness ledger, a friend-state cache and a moderation ledger written
//     as literal JSON load into their state, and two literal ban records decode.
// 11. **Presence on the air**: a manager over a planted identity advertises exactly its one friend's
//     frozen token and recognizes the three tokens of the matching window as that friend.
// 12. **The sealed-backup escrow**: the content-addressed account's known answer, and provisioning's
//     Cases 1 to 3 to their end states, every row and its attributes.
// 13. **The feature salts `.fernlet` declares**: the heart and presence pair salts as its family's
//     feature group, in order, each its registry twin's bytes, and ProximityKit's generic pair-secret
//     door deriving group 2's known answers under them, from either side.
// 14. **The heart-eligibility predicate**: the core's check that a peer is remembered, not removed and
//     blocked neither by key nor by fingerprint answers each of its three legs as presence's gate does.
//
// What another suite already pins is cited, not repeated: the four activity and moderation-report
// signature labels (`CryptographicPurposeBoundaryTests.framingHeldInThisFile` and
// `framingHeldElsewhere`), the escrow's two HKDF info labels (`SealedBackupFormatPinTests`' two known
// answers), presence's refusal of a malformed key on a provisioned identity
// (`PresenceTagTests.garbagePeerKeyThrowsInvalidKeyData`), the moderation keychain service
// (`PrivacyWipeCoverageTests.knownKeychainServices`), the heart sidecars' three file names
// (`HeartDropSidecarFormatCensusTests.theCorpusIsExactlyTheFourKnownFileNames`), the isolation of the
// mesh stores' derived services (`MeshSessionStoreIsolationTests`, `MeshRoutedStoreIsolationTests`),
// and provisioning's Case 4, which mints and adopts no escrow, device-only
// (`IdentityServiceEscrowTests.ensureProvisionedDoesNotMintEscrowKey`,
// `KeyCustodyBoundaryTests.identityKeysProvisionDeviceOnly`). The sent heart envelope is reached by no
// seam (presence sends it only after a sealed heart connection commits over a live coordinator pair),
// so it is cited too: its token is `ProximityVocabularyGoldenTests`' `friendHeart` row, its summary
// title is the literal `SealedIntroductionTests`' heart cell sends through the coordinator, and
// presence's receipt of the heart payload's format and version, `fernlet.proximity.heart` and 1, is
// `HeartShareTests.receivedHeartFromTrustedFriendIsPersisted` and
// `HeartShareTests.malformedHeartPayloadsAreDropped`.
//
// Fixed inputs: alice's key-agreement private key is the bytes 0x01…0x20 and her signing key
// 0x21…0x40; bob's are 0x41…0x60 and 0x61…0x80; the reporter-tag salt is 0x80…0x9f, the sidecar key
// 0xa0…0xbf and a third key-agreement key, the escrow fixture's, 0xc0…0xdf; group 14's stranger and
// carol hold 0xe0…0xff and 0xf0…0x0f as signing keys only, from which nothing is derived. A planted
// identity is its signing and key-agreement private rows stored device-only at `.fernlet`'s identity
// accounts under a throwaway service (`com.fernlet.test.ffgt.<UUID>`, swept in a `defer`), then built with
// `IdentityService(namespace: .fernlet, keychainService:)` and provisioned, which adopts them
// (provisioning's Case 1). Every identity here names its namespace or the app's factory, never a test
// binding (ProximityNamespaceTestBindings.swift, FernletAppTestBindings.swift); the escrow group builds
// its identities through one accessor, ``FernletFeatureGoldenTests/escrowIdentity(keychainService:)``,
// today the app's factory, whose identity carries the sealed-backup escrow key.
//
// Every vector below was confirmed by two independent computations before it was frozen: a Python
// re-implementation over OpenSSL (`cryptography`), proved honest first by reproducing
// `SealedBackupFormatPinTests`' two escrow known answers, and a CryptoKit construction written from the
// format with no production type in it; the two frozen blobs were built once by the CryptoKit
// construction and rebuilt byte for byte by the Python one, and the bundle JSON was built by
// Foundation's output rules (keys sorted, no whitespace, `/` escaped, a whole number printed without a
// fraction, a UUID upper-case, data base64). Nothing here was copied out of Swift's output.

import CryptoKit
import FernletConnections
import FernletCrypto
import FernletDomainModel
import FernletFoundation
import Foundation
import Security
import Testing
@testable import Fernlet
@testable import FernletSocial
@testable import ProximityKit

// MARK: - The tables' rows

/// One feature label of a Fernlet feature: the registry entry it is or twins, its FROZEN spelling, and
/// the spelling and bytes production reads.
struct FeatureGoldenLabelRow: Sendable {
    /// The registry entry, as `Group.name`.
    let field: String
    /// The spelling, written by hand from the A0.4 census. Never computed from a constant; never edited.
    let frozen: String
    /// The spelling of the accessor production reads: **the only column a commit that moves the label
    /// may re-point.**
    let todayText: String
    /// The bytes that accessor hands CryptoKit, itself or through a ProximityKit door.
    let todayData: Data

    /// A row whose accessor is a FernletCrypto registry entry.
    init(_ field: String, frozen: String, today: CryptographicPurpose) {
        self.field = field
        self.frozen = frozen
        todayText = today.rawValue
        todayData = today.data
    }

    /// A row whose accessor is a feature purpose a host declares, the salt a ProximityKit door derives
    /// under.
    init(_ field: String, frozen: String, today: ProximityCryptographicPurpose) {
        self.field = field
        self.frozen = frozen
        todayText = today.rawValue
        todayData = today.data
    }
}

/// One name a feature files its state under (a keychain service or account, a file name): what it
/// is, its FROZEN literal, and where production reads it.
struct FeatureGoldenNameRow: Sendable {
    /// A stable path naming the value, e.g. `heartPrekeyStore.keychainService`.
    let field: String
    /// The name, written by hand. Never edited.
    let frozen: String
    /// The accessor production reads: **the only column a commit that moves the value may re-point.**
    let today: String
}

// MARK: - The suite

/// Every byte the features plan step A0.4 moves or re-derives put on the wire, in the keychain or on
/// disk, pinned by literal and by behaviour: the gate each A0.4 move has to pass unchanged.
///
/// **The rule for every commit: re-point an accessor, never a literal.** A frozen literal was written
/// by hand and confirmed by two independent computations; a failing one is a WIRE, KEYCHAIN or AT-REST
/// decision, so it is never re-pinned from Swift's output to go green. Failure messages print the
/// actual bytes so a deliberate change can be argued from them.
@MainActor
@Suite(.serialized)
struct FernletFeatureGoldenTests {

    // MARK: Group 1 — the seven feature labels

    /// The seven labels, in the order their features read them.
    static var labelRows: [FeatureGoldenLabelRow] {
        [
            FeatureGoldenLabelRow("KeyDerivation.heartDropPairV1", frozen: "fernlet.heartdrop.v1",
                                  today: FernletFeaturePurposes.heartDropPairV1),
            FeatureGoldenLabelRow("KeyDerivation.heartDropOuterSealV1", frozen: "fernlet.heartdrop.seal.v1",
                                  today: FernletCryptoPurpose.KeyDerivation.heartDropOuterSealV1),
            FeatureGoldenLabelRow("HMAC.heartDropDayTagV1", frozen: "fernlet.heartdrop.day.v1",
                                  today: FernletCryptoPurpose.HMAC.heartDropDayTagV1),
            FeatureGoldenLabelRow("AEAD.heartDropSidecarV2", frozen: "fernlet.heartdrop.sidecar.aead.v2",
                                  today: FernletCryptoPurpose.AEAD.heartDropSidecarV2),
            FeatureGoldenLabelRow("KeyDerivation.presencePairV1", frozen: "fernlet.presence.tag.v1",
                                  today: FernletFeaturePurposes.presencePairV1),
            FeatureGoldenLabelRow("HMAC.presenceEpochTagV1", frozen: "fernlet.presence.epoch.v1",
                                  today: FernletCryptoPurpose.HMAC.presenceEpochTagV1),
            FeatureGoldenLabelRow("Hash.moderationBanReporterTagV1",
                                  frozen: "fernlet.moderation.ban-evidence.reporter-tag.hash.v1",
                                  today: FernletCryptoPurpose.Hash.moderationBanReporterTagV1)
        ]
    }

    /// Each label's spelling and bytes are its frozen literal's, with no terminator and no
    /// normalization, and the table holds seven distinct labels.
    @Test func theSevenFeatureLabelsAreTheirFrozenBytes() {
        let rows = Self.labelRows
        #expect(rows.count == 7, "the label table holds \(rows.count) rows")
        #expect(Set(rows.map(\.frozen)).count == rows.count && Set(rows.map(\.field)).count == rows.count,
                "two label rows share a spelling or a field")
        // R2: bounded by the seven rows.
        for row in rows {
            #expect(row.todayText == row.frozen, "\(row.field) reads \(row.todayText); its frozen spelling is \(row.frozen)")
            #expect(row.todayData == Data(row.frozen.utf8),
                    "\(row.field)'s bytes are \(Self.hex(row.todayData)), not the UTF-8 of \(row.frozen)")
        }
    }

    // MARK: Group 2 — the pair secrets

    /// The heart-drop pair secret: HKDF-SHA256 over X25519(alice, bob), salt `fernlet.heartdrop.v1`,
    /// empty info, 32 bytes.
    static let heartPairSecretHex = "dfe5d4c5593fefa9e8331887456b2f1e880c8170a11417f7040aecfb71fc102a"
    /// The presence pair secret: the same over salt `fernlet.presence.tag.v1`.
    static let presencePairSecretHex = "63d4914dc5ccf31a4af94995436c05627e9c1df17335643a946b661f297ff7c1"

    /// On planted alice and planted bob each pair secret is its known answer, and the same from either
    /// side: the info is empty, so both members of a pair derive one key, which mutual recognition and
    /// the heart day tags stand on. Each identity holds the public keys its planted rows give.
    @Test func thePairSecretsAreTheirKnownAnswersFromEitherSide() throws {
        let aliceService = Self.throwawayService()
        let bobService = Self.throwawayService()
        defer { Self.sweep([aliceService, bobService]) }
        let alice = try Self.plantedAlice(service: aliceService)
        let bob = try Self.plantedIdentity(signing: Self.bobSigningRaw, keyAgreement: Self.bobKeyAgreementRaw,
                                           service: bobService)
        #expect(Self.hex(alice.localKeyAgreementPublicKey) == Self.alicePubHex, "alice's planted key-agreement key")
        #expect(Self.hex(bob.localKeyAgreementPublicKey) == Self.bobPubHex, "bob's planted key-agreement key")
        #expect(Self.hex(alice.localSigningPublicKey) == Self.aliceSigningPubHex, "alice's planted signing key")
        #expect(Self.hex(bob.localSigningPublicKey) == Self.bobSigningPubHex, "bob's planted signing key")
        let secrets = try [
            ("alice's heart", alice.heartDropPairSecret(with: Self.bobPub), Self.heartPairSecretHex),
            ("bob's heart", bob.heartDropPairSecret(with: Self.alicePub), Self.heartPairSecretHex),
            ("alice's presence", alice.presencePairSecret(with: Self.bobPub), Self.presencePairSecretHex),
            ("bob's presence", bob.presencePairSecret(with: Self.alicePub), Self.presencePairSecretHex)
        ]
        // R2: bounded by the four secrets.
        for (name, secret, frozen) in secrets {
            let actual = Self.hex(secret.withUnsafeBytes { Data($0) })
            #expect(actual == frozen, "\(name) pair secret is \(actual)")
        }
    }

    /// Each pair secret refuses an identity that holds no key-agreement key with `.notProvisioned`
    /// before it reads the peer's key, for a malformed key and a well-formed one alike, and only then
    /// a malformed key with its own error: `.sealFailed` for the heart pair secret here (presence's
    /// `.invalidKeyData` on a provisioned identity is `PresenceTagTests`'). The order is part of the
    /// bytes: the heart path's audit lines log the error each refusal throws.
    @Test func thePairSecretsRefuseAMissingKeyFirstAndAMalformedOneThen() throws {
        let aliceService = Self.throwawayService()
        let idleService = Self.throwawayService()
        defer { Self.sweep([aliceService, idleService]) }
        let alice = try Self.plantedAlice(service: aliceService)
        let malformed = Data([0x01, 0x02, 0x03])
        #expect(throws: IdentityError.sealFailed) { _ = try alice.heartDropPairSecret(with: malformed) }
        let idle = IdentityService(namespace: .fernlet, keychainService: idleService)
        // R2: bounded by the two peer keys.
        for peer in [malformed, Self.bobPub] {
            #expect(throws: IdentityError.notProvisioned) { _ = try idle.heartDropPairSecret(with: peer) }
            #expect(throws: IdentityError.notProvisioned) { _ = try idle.presencePairSecret(with: peer) }
        }
    }

    // MARK: Group 3 — the tags and the clocks

    /// The heart day tag on day 20 000 under the heart pair secret with alice as the sender:
    /// HMAC-SHA256 keyed by the pair secret over `fernlet.heartdrop.day.v1` ‖ be64(day) ‖ the
    /// sender's key-agreement key, its first 16 bytes as lowercase hex.
    static let heartDayTagFromAlice = "7b8ea144158e69f54b0f862fc39f291b"
    /// The same tag with bob as the sender: the sender term is what makes a pair's two directions differ.
    static let heartDayTagFromBob = "63d8fd2af14da193f31f72bacc23b154"

    /// The heart day tags are their known answers, one per direction.
    @Test func theHeartDayTagsAreTheirKnownAnswers() {
        let secret = SymmetricKey(data: Self.bytes(fromHex: Self.heartPairSecretHex))
        let fromAlice = IdentityService.heartDropTag(
            pairSecret: secret, dayEpoch: 20_000, senderKeyAgreementPublicKey: Self.alicePub)
        let fromBob = IdentityService.heartDropTag(
            pairSecret: secret, dayEpoch: 20_000, senderKeyAgreementPublicKey: Self.bobPub)
        #expect(fromAlice == Self.heartDayTagFromAlice, "alice's day tag is \(fromAlice)")
        #expect(fromBob == Self.heartDayTagFromBob, "bob's day tag is \(fromBob)")
    }

    /// The heart day epoch is whole UTC days since 1970, `floor(seconds / 86 400)`, turning at
    /// midnight: 0 and 86 399 s are day 0, 86 400 s day 1, and 1 728 000 000 s day 20 000.
    @Test func theHeartDayEpochTurnsAtUTCMidnight() {
        let answers: [(seconds: TimeInterval, day: UInt64)] = [
            (0, 0), (86_399, 0), (86_400, 1), (1_727_999_999, 19_999), (1_728_000_000, 20_000)
        ]
        // R2: bounded by the five answers.
        for answer in answers {
            let day = IdentityService.heartDropDayEpoch(at: Date(timeIntervalSince1970: answer.seconds))
            #expect(day == answer.day, "\(answer.seconds) s is day \(day), not \(answer.day)")
        }
    }

    /// Planted alice's presence tags for bob at three consecutive epochs: HMAC-SHA256 keyed by the
    /// presence pair secret over `fernlet.presence.epoch.v1` ‖ be64(epoch), its first 8 bytes, and the
    /// base64 token the radio advertises for each.
    static let presenceTags: [(epoch: UInt64, hex: String, token: String)] = [
        (1_899_999, "9e2a87bb48945968", "niqHu0iUWWg="),
        (1_900_000, "e184bd3986b7c628", "4YS9OYa3xig="),
        (1_900_001, "a155e2d07ddc7b15", "oVXi0H3cexU=")
    ]

    /// Each presence tag is its known answer and its token is the tag in base64.
    @Test func thePresenceTagsAndTheirWireTokensAreTheirKnownAnswers() throws {
        let service = Self.throwawayService()
        defer { Self.sweep([service]) }
        let alice = try Self.plantedAlice(service: service)
        // R2: bounded by the three epochs.
        for frozen in Self.presenceTags {
            let tag = try alice.presenceTag(for: Self.bobPub, epoch: frozen.epoch)
            #expect(Self.hex(tag) == frozen.hex, "epoch \(frozen.epoch)'s tag is \(Self.hex(tag))")
            #expect(tag.base64EncodedString() == frozen.token,
                    "epoch \(frozen.epoch)'s token is \(tag.base64EncodedString())")
        }
    }

    // MARK: Group 4 — moderation's two hashes

    /// SHA-256 over `fernlet.moderation.ban-evidence.reporter-tag.hash.v1` ‖ the salt 0x80…0x9f ‖
    /// alice's key-agreement key (standing in for a reporter's signing key: the tagger takes any bytes).
    static let reporterTagHex = "f11f24b8dd4810a3a175ed1e4254771e86f3e5b4bba7de811e8a3fef9dd2cec0"

    /// The tag a ban record files a reporter under is its known answer.
    @Test func theBanReporterTagIsItsKnownAnswer() {
        let tag = ModerationBanStore.reporterTagger(salt: Self.consecutiveBytes(from: 0x80))(Self.alicePub)
        #expect(Self.hex(tag) == Self.reporterTagHex, "the reporter tag is \(Self.hex(tag))")
    }

    /// SHA-256 over a two-by-two hat's artwork in the content hash's frozen layout: `cols=2;rows=2;` ‖
    /// `palette=2E2A24,FFFFFF;` ‖ `pixels=0,1,-1,0` ‖ `;slot=hat` (the palette's two colours, the four
    /// cells row by row with -1 transparent, then the slot's token). The key a ledger row, a ban
    /// record's evidence and a relayed report name an artwork by.
    static let contentHashHex = "a5cf950e345ed4c3940878ad0d6b89d24e018fdfd2123bea6ee50fc50d2a24ce"

    /// The artwork a report binds to hashes to its known answer, through the texture door and through
    /// the item door the app's report, retract and listing checks call, which sanitizes the item first
    /// (this artwork is already in shape, so the sanitizer leaves it as it is).
    @Test func theReportedArtworksContentHashIsItsKnownAnswer() {
        let texture = ItemGridTexture(cols: 2, rows: 2, palette: ["2E2A24", "FFFFFF"], pixels: [0, 1, -1, 0])
        let byTexture = ModerationContentHash.of(texture: texture, slot: .hat)
        #expect(Self.hex(byTexture) == Self.contentHashHex, "the content hash is \(Self.hex(byTexture))")
        let item = CustomizationItem(
            id: Self.uuid("D1E2F3A4-B5C6-4D7E-8F90-A1B2C3D4E5F6"), name: "Golden hat", slot: .hat,
            texture: texture, designer: ItemDesigner(id: Self.uuid("E1F2A3B4-C5D6-4E7F-8091-A2B3C4D5E6F7")),
            price: 5)
        let byItem = ModerationContentHash.of(item)
        #expect(Self.hex(byItem) == Self.contentHashHex, "the item's content hash is \(Self.hex(byItem))")
    }

    // MARK: Group 5 — the sealed drop

    /// The key of a drop whose ephemeral key is bob's, sealed to alice's static key: HKDF-SHA256 over
    /// X25519(bob, alice's key), salt `fernlet.heartdrop.seal.v1`, info bob's key ‖ alice's key (the
    /// ephemeral, then the recipient), 32 bytes.
    static let dropKeyHex = "04b1a7c95a3553a2af514c92081f3770d21871ad2989ba1258d4d9d3d356f147"

    /// A static-key drop to alice, built once in a scratch run and frozen: the version byte `0x01`,
    /// 16 zero bytes (sealed to the static key, no prekey), bob's key as the ephemeral key, then
    /// ChaCha20-Poly1305's combined box (the nonce 0xe0…0xeb, the ciphertext, the tag) under the drop
    /// key, the 17-byte header as authenticated data, over the wire2 frame of ``frozenDropJSON``: the
    /// raw tag `0x02`, the JSON, zero padding and the big-endian pad count, 256 bytes. 333 bytes.
    static let frozenDropHex = [
        "010000000000000000000000000000000064b101b1d0be5a8704bd078f9895001fc03e8e9f9522f188dd128d9846d484",
        "66e0e1e2e3e4e5e6e7e8e9eaebb7d043c82d47c3184199740fef7b0093719f494c06396a5df4fa57a748db78d59e1dc5",
        "9784665ff813265ee018c95d619224c9549530ffd1827dfbb2253357b29b7cf23b6a10a12df8fb0eacafff2236d1b02f",
        "db60fa0a2078a0938f6ccb2331253188fb79e689630744f8c4d164000b263dd22c052f314c6de5c938392750fad02156",
        "063423a664c38d849e6a61b9c0ceb42bb44d0ee29697b751583cca472931f4288a4ac56d210fce52baefe227fd7a78cb",
        "1a7fddebf2c9e7e2afe84beaf788342adc8f97fba1cb35d0f9be1bff29c79c29c38f627ec2ad9936a9bfa362e526e24e",
        "724ab7c4946788b415a1208e1291f89e107d796de8152b5849ba0a8c2e804a0af93adbdfa3d8f8eb2d2ef974ad"
    ].joined()

    /// What the frozen drop holds, standing in for the signed inner envelope a real drop carries.
    static let frozenDropJSON = #"{"golden":"heart-drop","v":1}"#

    /// The drop key is its known answer from CryptoKit primitives and literals alone, and the sealer,
    /// opening the frozen drop through planted alice's static-key agreement, returns the frozen JSON.
    /// The cell never frames or seals anything itself: drops already in the public database must keep
    /// opening, so only a frozen one is a pin.
    @Test func theSealerOpensItsFrozenStaticDrop() throws {
        let bob = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Self.bobKeyAgreementRaw)
        let shared = try bob.sharedSecretFromKeyAgreement(
            with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: Self.alicePub))
        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: Data(Self.frozenLabel("KeyDerivation.heartDropOuterSealV1").utf8),
            sharedInfo: Self.bobPub + Self.alicePub, outputByteCount: 32)
        #expect(Self.hex(key.withUnsafeBytes { Data($0) }) == Self.dropKeyHex, "the drop key from primitives")
        let service = Self.throwawayService()
        defer { Self.sweep([service]) }
        let alice = try Self.plantedAlice(service: service)
        let opened = try HeartDropSealer.open(
            Self.bytes(fromHex: Self.frozenDropHex),
            prekeyPrivateKey: { _ in nil },
            staticAgreement: { try Self.staticAgreement(alice, withEphemeralPublicKey: $0) },
            staticPublicKey: Self.alicePub)
        #expect(String(decoding: opened, as: UTF8.self) == Self.frozenDropJSON,
                "the frozen drop opened to \(Self.hex(opened))")
    }

    // MARK: Group 6 — the sealed sidecar

    /// A sealed heart-drop sidecar, built once in a scratch run and frozen: the marker `FSC2`, then
    /// ChaCha20-Poly1305's combined box (the nonce 0xf0…0xfb, the ciphertext, the tag) under the key
    /// 0xa0…0xbf, `fernlet.heartdrop.sidecar.aead.v2` as authenticated data, over
    /// ``frozenSidecarJSON``. 58 bytes.
    static let frozenSidecarHex = [
        "46534332f0f1f2f3f4f5f6f7f8f9fafb4ee323029fda29d7de1f4d9516ef0e63e0462f048bbb877841ea50b69adef017",
        "a76ad5f4a4779ab299df"
    ].joined()

    /// What the frozen sidecar holds.
    static let frozenSidecarJSON = #"{"golden":"sidecar","v":2}"#

    /// With the key planted at the frozen account under a throwaway service, as the seal mints it
    /// (`WhenUnlockedThisDeviceOnly`), the sidecar seal opens the frozen blob to its plaintext.
    @Test func theSidecarSealOpensItsFrozenBlob() throws {
        let service = Self.throwawayService()
        defer { Self.sweep([service]) }
        let status = KeychainItem.store(
            Self.consecutiveBytes(from: 0xa0), account: Self.frozenName("heartDropSidecarSeal.keychainAccount"),
            service: service, accessibility: kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
        try #require(status == errSecSuccess, "the sidecar key was not planted: \(status)")
        let seal = HeartDropSidecarSeal.make(keychainService: service)
        let opened = try seal.open(Self.bytes(fromHex: Self.frozenSidecarHex))
        #expect(String(decoding: opened, as: UTF8.self) == Self.frozenSidecarJSON,
                "the frozen sidecar opened to \(Self.hex(opened))")
    }

    // MARK: Group 7 — the prekey bundle

    /// The two one-time prekeys both fixed bundles gossip.
    static var prekeyEntries: [PrekeyEntry] {
        [
            PrekeyEntry(id: uuid("11111111-2222-4333-8444-555555555555"), publicKey: alicePub),
            PrekeyEntry(id: uuid("66666666-7777-4888-9999-AAAAAAAAAAAA"), publicKey: bobPub)
        ]
    }

    /// A bundle with a signed prekey: a 30-day bundle from 780 000 000 s after the reference date, and a
    /// seven-day signed prekey whose key is the escrow fixture's.
    static var signedBundle: PrekeyBundle {
        PrekeyBundle(
            bundleID: uuid("A0B1C2D3-E4F5-4607-8819-2A3B4C5D6E7F"),
            created: Date(timeIntervalSinceReferenceDate: 780_000_000),
            expires: Date(timeIntervalSinceReferenceDate: 782_592_000),
            keys: prekeyEntries,
            signedPrekey: SignedPrekey(
                id: uuid("BBBBBBBB-CCCC-4DDD-AEEE-FFFFFFFFFFFF"), publicKey: escrowPub,
                created: Date(timeIntervalSinceReferenceDate: 780_000_000),
                expires: Date(timeIntervalSinceReferenceDate: 780_604_800)))
    }

    /// A bundle from before signed prekeys: no `signedPrekey` at all.
    static var bareBundle: PrekeyBundle {
        PrekeyBundle(
            bundleID: uuid("C3D4E5F6-0718-4293-A4B5-C6D7E8F90A1B"),
            created: Date(timeIntervalSinceReferenceDate: 781_000_000),
            expires: Date(timeIntervalSinceReferenceDate: 783_592_000),
            keys: prekeyEntries)
    }

    /// ``signedBundle`` as `JSONEncoder` with sorted keys writes it.
    static let signedBundleJSON = [
        #"{"bundleID":"A0B1C2D3-E4F5-4607-8819-2A3B4C5D6E7F","created":780000000,"expires":782592000,"#,
        #""keys":[{"id":"11111111-2222-4333-8444-555555555555","#,
        #""publicKey":"B6N8vBQgk8i3VdwbEOhstCY3StFqqFPtC9\/AsrhtHHw="},"#,
        #"{"id":"66666666-7777-4888-9999-AAAAAAAAAAAA","publicKey":"ZLEBsdC+WocEvQePmJUAH8A+jp+VIvGI3RKNmEbUhGY="}],"#,
        #""signedPrekey":{"created":780000000,"expires":780604800,"id":"BBBBBBBB-CCCC-4DDD-AEEE-FFFFFFFFFFFF","#,
        #""publicKey":"3CzKMejkO72R3\/fkdcyjNH60eBB9W9dlq6SuSjDDXUQ="}}"#
    ].joined()

    /// ``bareBundle`` as `JSONEncoder` with sorted keys writes it: the optional key is left out.
    static let bareBundleJSON = [
        #"{"bundleID":"C3D4E5F6-0718-4293-A4B5-C6D7E8F90A1B","created":781000000,"expires":783592000,"#,
        #""keys":[{"id":"11111111-2222-4333-8444-555555555555","#,
        #""publicKey":"B6N8vBQgk8i3VdwbEOhstCY3StFqqFPtC9\/AsrhtHHw="},"#,
        #"{"id":"66666666-7777-4888-9999-AAAAAAAAAAAA","publicKey":"ZLEBsdC+WocEvQePmJUAH8A+jp+VIvGI3RKNmEbUhGY="}]}"#
    ].joined()

    /// Each fixed bundle encodes to its frozen JSON (keys `bundleID`, `created`, `expires`,
    /// `keys[id, publicKey]`, `signedPrekey{created, expires, id, publicKey}`, default date and data
    /// strategies) and decodes back to an equal bundle. The type's name never reaches the bytes, which
    /// ride the signed introduction, the prekey keychain blob and the sealed peer-bundle sidecar; and
    /// the prekey store's bundle types are the very types the introduction carries, so the blob and
    /// the sidecar hold the bytes pinned here.
    @Test func thePrekeyBundleEncodesToItsFrozenJSONAndBack() throws {
        let carried = [ObjectIdentifier(PrekeyBundle.self), ObjectIdentifier(PrekeyEntry.self),
                       ObjectIdentifier(SignedPrekey.self)]
        #expect(Self.prekeyStoreBundleTypes == carried,
                "the prekey store's bundle, entry or signed prekey is not the type the introduction carries")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let cases = [("signed", Self.signedBundle, Self.signedBundleJSON), ("bare", Self.bareBundle, Self.bareBundleJSON)]
        // R2: bounded by the two bundles.
        for (name, bundle, frozen) in cases {
            let encoded = String(decoding: try encoder.encode(bundle), as: UTF8.self)
            #expect(encoded == frozen, "the \(name) bundle encodes to \(encoded)")
            let decoded = try JSONDecoder().decode(PrekeyBundle.self, from: Data(frozen.utf8))
            #expect(decoded == bundle, "the \(name) bundle's frozen JSON decodes to \(decoded)")
        }
    }

    /// The identity introduction gossips the bundle both ways, over the vocabulary golden's
    /// coordinator rig (`VocabularyCoordinatorRig`: two `FakePeerTransport`s on one `FakePeerNetwork`,
    /// a coordinator with `MockRangingProvider(isHardwareSupported: false)` and a hand-driven peer, both
    /// of `.fernlet`): a coordinator whose provider offers ``signedBundle`` sends an introduction whose
    /// payload holds an equal bundle under the frozen key `heartDropPrekeyBundle`, and the same
    /// coordinator hands the bundle its peer's introduction carries, with the peer's signing key, to
    /// its receiver, once. Decoded values are compared, never the unsorted encoder's raw bytes.
    @Test func theIdentityIntroductionCarriesThePrekeyBundleBothWays() async throws {
        let rig = try VocabularyCoordinatorRig()
        defer { rig.forgetKeychainRows() }
        let received = PrekeyBundleCollector()
        Self.offer(Self.signedBundle, on: rig.coordinator)
        Self.collect(into: received, on: rig.coordinator)
        let body = PrekeyIntroductionBody(rangingMode: "rssi", bundle: Self.signedBundle)
        let peer = try await rig.handshake(payload: JSONEncoder().encode(body))
        let sent = try rig.sentEnvelopes()
        await rig.coordinator.cancel()
        _ = try #require(peer, "the handshake reached the manual-commit gate")
        let token = ProximityNamespace.fernlet.family.vocabulary.session.identityIntroduction.payloadType
        let ours = try #require(sent.first { $0.payloadTypeToken == token }, "the coordinator sent no introduction")
        let carried = try JSONDecoder().decode(PrekeyIntroductionBody.self, from: ours.payload)
        #expect(carried.bundle == Self.signedBundle, "the introduction carried \(String(describing: carried.bundle))")
        #expect(received.deliveries.count == 1, "the receiver was handed \(received.deliveries.count) bundles")
        #expect(received.deliveries.first?.bundle == Self.signedBundle, "the receiver was handed another bundle")
        #expect(received.deliveries.first?.sender == rig.remoteIdentity.localSigningPublicKey,
                "the receiver was handed another sender's key")
    }

    /// An identity introduction's body as far as the bundle goes: the ranging mode every peer sends,
    /// and the bundle under its frozen wire key.
    struct PrekeyIntroductionBody: Codable {
        /// The sender's ranging mode token.
        let rangingMode: String
        /// The gossiped bundle, or nil for none.
        let bundle: PrekeyBundle?

        /// The wire keys; the bundle's is frozen.
        enum CodingKeys: String, CodingKey {
            case rangingMode
            case bundle = "heartDropPrekeyBundle"
        }
    }

    /// Collects what a coordinator hands its received-bundle hook.
    @MainActor
    final class PrekeyBundleCollector {
        /// Each hand-off, in order: the sender's signing key and the bundle.
        private(set) var deliveries: [(sender: Data, bundle: PrekeyBundle)] = []

        /// Records one hand-off.
        func record(sender: Data, bundle: PrekeyBundle) {
            deliveries.append((sender, bundle))
        }
    }

    // MARK: Group 8 — the keychain names

    /// The heart-drop keychain service and the two accounts its stores file under it.
    static var keychainNameRows: [FeatureGoldenNameRow] {
        [
            FeatureGoldenNameRow(field: "heartPrekeyStore.keychainService", frozen: "com.fernlet.heartdrop",
                                 today: HeartPrekeyStore.keychainService),
            FeatureGoldenNameRow(field: "heartPrekeyStore.keychainAccount", frozen: "prekeyPrivateHalves",
                                 today: HeartPrekeyStore.keychainAccount),
            FeatureGoldenNameRow(field: "heartDropSidecarSeal.keychainAccount", frozen: "sidecarSealKey",
                                 today: HeartDropSidecarSeal.keychainAccount)
        ]
    }

    /// Each keychain name is its frozen literal: the rows already on devices live under them.
    @Test func theHeartDropKeychainNamesAreFrozen() {
        #expect(Self.keychainNameRows.count == 3, "the keychain table holds \(Self.keychainNameRows.count) rows")
        #expect(Self.expectFrozen(Self.keychainNameRows) == 3)
    }

    /// One self ban and one peer ban file exactly two rows under the ban store's service: the constant
    /// device account `selfBan.device` and `peerBan:` ‖ the peer's fingerprint. Both names are frozen:
    /// existing records are filed under them, and "Delete everything" splits the two by the prefix.
    @Test func theBanStoreFilesItsBansUnderTheirFrozenAccounts() {
        let service = Self.throwawayService()
        defer { Self.sweep([service]) }
        let store = ModerationBanStore(service: service)
        store.applySelfBan()
        store.applyPeerBan(fingerprint: Self.bobFingerprint)
        #expect(store.isSelfBanned && store.isPeerBanned(fingerprint: Self.bobFingerprint), "a ban did not apply")
        let accounts = KeychainItem.loadAll(service: service).map(\.account).sorted()
        #expect(accounts == ["peerBan:" + Self.bobFingerprint, "selfBan.device"], "the bans are filed under \(accounts)")
    }

    /// The mesh stores' keychain services derived beside a heart-drop service: the production heart-drop
    /// service maps to `.fernlet`'s two seal-key services, and any other service `X` to `X.mesh-session`
    /// and `X.mesh-routed`. Compared through the derivation alone, never through a storage scope: the
    /// isolation walls keep every test off the production scopes.
    @Test func theMeshStoresServicesDeriveBesideTheHeartDropService() {
        let fernlet = ProximityNamespace.fernlet
        let production = Self.frozenName("heartPrekeyStore.keychainService")
        let session = MeshSessionStorageScope.keychainService(besideHeartDrop: production, in: fernlet)
        let routed = MeshRoutedStorageScope.keychainService(besideHeartDrop: production, in: fernlet)
        #expect(session == fernlet.installation.keychain.meshSessionSealKey.service, "the session service is \(session)")
        #expect(routed == fernlet.installation.keychain.meshRoutedSealKey.service, "the routed service is \(routed)")
        let isolated = "com.fernlet.test.ffgt.heartdrop"
        let isolatedSession = MeshSessionStorageScope.keychainService(besideHeartDrop: isolated, in: fernlet)
        let isolatedRouted = MeshRoutedStorageScope.keychainService(besideHeartDrop: isolated, in: fernlet)
        #expect(isolatedSession == "com.fernlet.test.ffgt.heartdrop.mesh-session", "beside X: \(isolatedSession)")
        #expect(isolatedRouted == "com.fernlet.test.ffgt.heartdrop.mesh-routed", "beside X: \(isolatedRouted)")
    }

    // MARK: Group 9 — the storage names

    /// Five stores' files inside a proximity-sidecar root, by their names.
    static func fileNameRows(in root: URL) -> [FeatureGoldenNameRow] {
        [
            FeatureGoldenNameRow(field: "closenessLedger.fileName", frozen: "ClosenessLedger.json",
                                 today: ClosenessLedger.fileURL(in: root).lastPathComponent),
            FeatureGoldenNameRow(field: "friendStateCache.fileName", frozen: "FriendStateCache.json",
                                 today: FriendStateCache.fileURL(in: root).lastPathComponent),
            FeatureGoldenNameRow(field: "moderationLedger.fileName", frozen: "ModerationLedger.json",
                                 today: ModerationLedger.fileURL(in: root).lastPathComponent),
            FeatureGoldenNameRow(field: "heartLedger.fileName", frozen: "HeartLedger.json",
                                 today: ProximityHeartLedger.fileURL(in: root).lastPathComponent),
            FeatureGoldenNameRow(field: "activityLedger.fileName", frozen: "ActivityLedger.json",
                                 today: ProximityActivityManager.fileURL(in: root).lastPathComponent)
        ]
    }

    /// The production heart-drop scope's folder, read where production reads it.
    static var productionFolders: [(field: String, today: URL)] {
        [
            ("heartDropStorageScope.production.directory", HeartDropStorageScope.production.directory)
        ]
    }

    /// Each store's file is its frozen name directly inside the root it is handed; the production
    /// heart-drop scope is `Application Support/Fernlet`, and its service is the heart-drop service.
    /// Nothing shipped is migrated by a move that keeps them.
    @Test func theStoresFileNamesAndTheProductionHeartDropScopeAreFrozen() {
        let root = Self.scratchDirectory()
        #expect(Self.expectFrozen(Self.fileNameRows(in: root)) == 5)
        let fileURLs = [ClosenessLedger.fileURL(in: root), FriendStateCache.fileURL(in: root),
                        ModerationLedger.fileURL(in: root), ProximityHeartLedger.fileURL(in: root),
                        ProximityActivityManager.fileURL(in: root)]
        #expect(fileURLs.allSatisfy { $0.deletingLastPathComponent().path == root.path },
                "a store's file is not directly inside its root: \(fileURLs.map(\.path))")
        let folder = URL.applicationSupportDirectory.appendingPathComponent("Fernlet", isDirectory: true)
        // R2: bounded by the production folders.
        for row in Self.productionFolders {
            #expect(row.today == folder, "\(row.field) is \(row.today.path), not \(folder.path)")
        }
        let service = HeartDropStorageScope.production.keychainService
        #expect(service == Self.frozenName("heartPrekeyStore.keychainService"), "the production scope's service is \(service)")
    }

    // MARK: Group 10 — the persisted shapes

    /// A closeness ledger as the ledger writes one: alice's counts for 3 October 2026 (two sessions, a
    /// photo session, a heart each way) and alice in a close slot since 780 000 000 s after the
    /// reference date, evaluated that day.
    static let frozenClosenessJSON = [
        #"{"version":1,"byFriend":{"c945cbf2a5602002":{"2026-10-03":"#,
        #"{"sessions":2,"photoSessions":1,"sharesAccepted":0,"heartSent":1,"heartReceived":1}}},"#,
        #""slotState":{"closeFingerprints":["c945cbf2a5602002"],"enteredAt":{"c945cbf2a5602002":780000000},"#,
        #""lastEvalDayKey":"2026-10-03"}}"#
    ].joined()

    /// A ledger over the frozen file, on the day it was written, holds its slot and its day: alice is
    /// close, the day needs no evaluation, and her closeness is the day's points at full weight, 10
    /// (two sessions 10, a photo session 3, a heart each way 1 + 1 + 1 for both, capped at 10).
    @Test func aFrozenClosenessLedgerLoadsIntoItsState() throws {
        let root = Self.scratchDirectory()
        defer { Self.removeDirectory(root) }
        let url = ClosenessLedger.fileURL(in: root)
        try Self.write(Self.frozenClosenessJSON, to: url)
        let writtenDay = Self.localNoon(year: 2026, month: 10, day: 3)
        let ledger = ClosenessLedger(fileURL: url, now: { writtenDay })
        var expected = CloseSlotState()
        expected.closeFingerprints = [Self.aliceFingerprint]
        expected.enteredAt = [Self.aliceFingerprint: Date(timeIntervalSinceReferenceDate: 780_000_000)]
        expected.lastEvalDayKey = "2026-10-03"
        #expect(ledger.slotState == expected, "the slot state loaded as \(ledger.slotState)")
        #expect(ledger.isClose(fingerprint: Self.aliceFingerprint), "alice is not close")
        #expect(!ledger.needsDailyEvaluation, "the day it was evaluated asks for evaluation again")
        let closeness = ledger.closeness(fingerprint: Self.aliceFingerprint)
        #expect(closeness == 10, "alice's closeness is \(closeness)")
    }

    /// A friend-state cache as the cache writes one: bob's "okay" state and a pear-bodied companion
    /// with glasses, captured 780 000 000 s after the reference date.
    static let frozenFriendStateJSON = [
        #"{"version":1,"states":[{"fingerprint":"b4cb4b93c4027ce3","fuzzyState":2,"#,
        #""appearance":{"bodyStyle":"pear","accessory":"glasses"},"capturedAt":780000000}]}"#
    ].joined()

    /// A cache over the frozen file, an hour after the capture, holds bob's state exactly and shows it.
    @Test func aFrozenFriendStateCacheLoadsIntoItsState() throws {
        let root = Self.scratchDirectory()
        defer { Self.removeDirectory(root) }
        let url = FriendStateCache.fileURL(in: root)
        try Self.write(Self.frozenFriendStateJSON, to: url)
        let cache = FriendStateCache(fileURL: url, now: { Date(timeIntervalSinceReferenceDate: 780_003_600) })
        let expected = CachedFriendState(
            fingerprint: Self.bobFingerprint, fuzzyState: .okay,
            appearance: CompanionAppearance(bodyStyle: .pear, accessory: .glasses),
            capturedAt: Date(timeIntervalSinceReferenceDate: 780_000_000))
        #expect(cache.states == [Self.bobFingerprint: expected], "the cache loaded \(cache.states)")
        #expect(cache.state(for: Self.bobFingerprint) == expected, "bob's fresh state is not shown")
    }

    /// A moderation ledger as the ledger writes one: alice's report of bob's artwork `abcd`.
    static let frozenModerationJSON = [
        #"{"version":1,"rows":[{"id":"report:c945cbf2a5602002:abcd","kind":"report","#,
        #""reporterSigningPublicKey":"5\/FioQvsVZr+oZXk3OhLaVaNXSywlj60RsBoXisX8vA=","#,
        #""subjectSigningPublicKey":"iC0Oo7KGTnpYfz5pjOpEWZmDEuZV4F+l6LURnYuqyM0=","#,
        #""itemID":"D1E2F3A4-B5C6-4D7E-8F90-A1B2C3D4E5F6","contentHash":"q80=","reasonToken":"offensive","#,
        #""reporterSeq":1,"createdAt":780000000}]}"#
    ].joined()

    /// A ledger over the frozen file holds the one row exactly.
    @Test func aFrozenModerationLedgerLoadsIntoItsState() throws {
        let root = Self.scratchDirectory()
        defer { Self.removeDirectory(root) }
        let url = ModerationLedger.fileURL(in: root)
        try Self.write(Self.frozenModerationJSON, to: url)
        let ledger = ModerationLedger(fileURL: url, now: { Date(timeIntervalSinceReferenceDate: 780_003_600) })
        let expected = ModerationLedgerEntry(
            id: "report:" + Self.aliceFingerprint + ":abcd", kind: .report,
            reporterSigningPublicKey: Self.bytes(fromHex: Self.aliceSigningPubHex),
            subjectSigningPublicKey: Self.bytes(fromHex: Self.bobSigningPubHex),
            itemID: Self.uuid("D1E2F3A4-B5C6-4D7E-8F90-A1B2C3D4E5F6"), contentHash: Data([0xab, 0xcd]),
            reasonToken: "offensive", reporterSeq: 1, createdAt: Date(timeIntervalSinceReferenceDate: 780_000_000))
        #expect(ledger.rows == [expected], "the ledger loaded \(ledger.rows)")
    }

    /// A ban record as the ban store writes one today: a 30-day peer ban of bob with its credited time,
    /// one tamper, the artwork it answered for, its evidence (group 4's reporter tag) under the
    /// 0x80…0x9f salt, the artworks it held before, and the instant withdrawals lifted it.
    static let frozenBanRecordJSON = [
        #"{"banID":"E1F2A3B4-C5D6-4E7F-8091-A2B3C4D5E6F7","subject":"peer:b4cb4b93c4027ce3","#,
        #""durationSeconds":2592000,"startedAtWall":780000000,"creditedMonotonic":3600,"creditedWall":0,"#,
        #""lastCheckMonotonic":5000,"lastCheckWall":780003600,"maxObservedWall":780003600,"tamperCount":1,"#,
        #""handledContentHashes":["abcd"],"evidence":[{"reporterTag":"8R8kuN1IEKOhde0eQlR3Hobz5bS7p96BHoo\/753SzsA=","#,
        #""contentHash":"q80=","reporterSeq":1}],"evidenceSalt":"gIGCg4SFhoeIiYqLjI2Oj5CRkpOUlZaXmJmam5ydnp8=","#,
        #""priorHandledContentHashes":["0102"],"liftedAtWall":780007200}"#
    ].joined()

    /// A ban record from before handled artworks, evidence, salts and lifts: a self ban with none of
    /// the optional fields.
    static let frozenEarlyBanRecordJSON = [
        #"{"banID":"F1A2B3C4-D5E6-4F70-8192-A3B4C5D6E7F8","subject":"self","#,
        #""durationSeconds":2592000,"startedAtWall":780000000,"creditedMonotonic":0,"creditedWall":0,"#,
        #""lastCheckMonotonic":12,"lastCheckWall":780000000,"maxObservedWall":780000000,"tamperCount":0}"#
    ].joined()

    /// Both frozen ban records decode, every field to its value; the early one's optional fields to nil.
    @Test func theFrozenBanRecordsDecode() throws {
        let record = try JSONDecoder().decode(BanRecord.self, from: Data(Self.frozenBanRecordJSON.utf8))
        #expect(record.banID == Self.uuid("E1F2A3B4-C5D6-4E7F-8091-A2B3C4D5E6F7") && record.subject == "peer:" + Self.bobFingerprint)
        #expect([record.durationSeconds, record.startedAtWall, record.creditedMonotonic, record.creditedWall]
                == [2_592_000, 780_000_000, 3_600, 0], "the record's credited time")
        #expect([record.lastCheckMonotonic, record.lastCheckWall, record.maxObservedWall] == [5_000, 780_003_600, 780_003_600],
                "the record's last check and high-water mark")
        #expect(record.tamperCount == 1 && record.handledContentHashes == ["abcd"] && record.liftedAtWall == 780_007_200)
        let evidence = BanEvidence(reporterTag: Self.bytes(fromHex: Self.reporterTagHex), contentHash: Data([0xab, 0xcd]),
                                   reporterSeq: 1)
        #expect(record.evidence == [evidence], "the record's evidence is \(String(describing: record.evidence))")
        #expect(record.evidenceSalt == Self.consecutiveBytes(from: 0x80) && record.priorHandledContentHashes == ["0102"])
        let early = try JSONDecoder().decode(BanRecord.self, from: Data(Self.frozenEarlyBanRecordJSON.utf8))
        #expect(early.banID == Self.uuid("F1A2B3C4-D5E6-4F70-8192-A3B4C5D6E7F8") && early.subject == "self")
        #expect(early.durationSeconds == 2_592_000 && early.lastCheckMonotonic == 12 && early.tamperCount == 0)
        #expect(early.handledContentHashes == nil && early.evidence == nil && early.evidenceSalt == nil
                && early.priorHandledContentHashes == nil && early.liftedAtWall == nil, "an early record's optional fields")
    }

    // MARK: Group 11 — presence on the air

    /// The presence clock: one second into epoch 1 900 000 (1 710 000 000 s is 1 900 000 × 900).
    static let presenceClock = Date(timeIntervalSince1970: 1_710_000_001)

    /// Bob as alice's one trusted friend: his key-agreement key, his fixed signing key and its
    /// fingerprint.
    static var bobAsFriend: ProximityTrustedPeerRecord {
        ProximityTrustedPeerRecord(
            displayName: "Bob", fingerprint: bobFingerprint, signingPublicKey: bytes(fromHex: bobSigningPubHex),
            keyAgreementPublicKey: bobPub, mode: .friend,
            firstAcceptedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastSeenAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    /// A presence manager over planted alice with bob as her one friend, at the presence clock and
    /// running without a radio, advertises exactly the record `PresenceAdvertisement`'s rules build
    /// for one tag (the version `v` = `1`, and `t` = epoch 1 900 000's frozen token), and recognizes
    /// the frozen tokens of epochs 1 899 999 to 1 900 001, its matching window, as bob and nothing
    /// else. Over the presence suites' host (`MockPresenceQUICHost`), never a second copy of a host.
    @Test func presenceAdvertisesItsFriendsFrozenTokenAndRecognizesTheWindow() throws {
        let service = Self.throwawayService()
        let root = Self.scratchDirectory()
        defer {
            Self.sweep([service])
            Self.removeDirectory(root)
        }
        let alice = try Self.plantedAlice(service: service)
        let host = MockPresenceQUICHost()
        host.proximityTrustVault.apply(peers: [Self.bobAsFriend], audit: [])
        let clock = Self.presenceClock
        let ledger = ProximityHeartLedger(fileURL: ProximityHeartLedger.fileURL(in: root), now: { clock })
        let manager = PresenceManager(store: host, ledger: ledger, identity: alice)
        manager.nowProvider = { clock }
        manager.activateForTesting()
        let current = try #require(Self.presenceTags.first { $0.epoch == 1_900_000 })
        let advertised = manager.discoveryInfoForTesting()
        #expect(advertised == ["v": "1", "t": current.token], "presence advertised \(advertised)")
        let window = Dictionary(Self.presenceTags.map { ($0.token, Self.bobFingerprint) },
                                uniquingKeysWith: { first, _ in first })
        #expect(manager.candidateTokens == window, "presence recognizes \(manager.candidateTokens)")
    }

    // MARK: Group 12 — the sealed-backup escrow

    /// alice's key-agreement key's content-addressed escrow account: `backupEscrowPrivateKey.k.` ‖
    /// the lowercase hex of SHA-256 over the public key.
    static let aliceEscrowAccount =
        "backupEscrowPrivateKey.k.aaa8fff703b50b2297f4f6e13508f72420d96fd01ebb84cb074449caaef64041"
    /// The escrow fixture key's account, the same way.
    static let escrowFixtureAccount =
        "backupEscrowPrivateKey.k.89a8cd8e5af2bd92e191c7f9fc432831a99f8b81f7a27bf93fb85cd3cd543b00"

    /// Each content-addressed account is its known answer.
    @Test func theEscrowAccountsAreTheirKnownAnswers() {
        let alice = IdentityService.escrowKeychainAccount(forPublicKey: Self.alicePub)
        let fixture = IdentityService.escrowKeychainAccount(forPublicKey: Self.escrowPub)
        #expect(alice == Self.aliceEscrowAccount, "alice's escrow account is \(alice)")
        #expect(fixture == Self.escrowFixtureAccount, "the fixture's escrow account is \(fixture)")
    }

    /// Case 1, the device keys present: over planted alice's two rows and a synchronized escrow row at
    /// the fixture key's account, provisioning adopts both device keys and the escrow, writes no row,
    /// and leaves the key-agreement row device-only and the escrow row synchronized.
    @Test func caseOneAdoptsTheEscrowBesideTheDeviceKeys() throws {
        let service = Self.throwawayService()
        defer { Self.sweep([service]) }
        try Self.plantDeviceRows(signing: Self.aliceSigningRaw, keyAgreement: Self.aliceKeyAgreementRaw, under: service)
        try Self.plantSyncedEscrow(Self.escrowRaw, account: Self.escrowFixtureAccount, under: service)
        let identity = Self.escrowIdentity(keychainService: service)
        try identity.ensureProvisioned()
        #expect(Self.hex(identity.localBackupEscrowPublicKey) == Self.escrowPubHex, "Case 1 adopted another escrow")
        #expect(Self.hex(identity.localKeyAgreementPublicKey) == Self.alicePubHex, "Case 1 minted over the device key")
        let rows = Self.rows(under: service)
        let accounts = Self.identityAccounts
        #expect(rows.synced == [Self.escrowFixtureAccount: Self.escrowRaw],
                "Case 1's synchronized rows: \(rows.synced.keys.sorted())")
        #expect(rows.local == [accounts.signingPrivateKey: Self.aliceSigningRaw,
                               accounts.keyAgreementPrivateKey: Self.aliceKeyAgreementRaw],
                "Case 1's device-only rows: \(rows.local.keys.sorted())")
        #expect(Self.attributes(of: accounts.keyAgreementPrivateKey, under: service) == Self.deviceOnly)
        #expect(Self.attributes(of: Self.escrowFixtureAccount, under: service) == Self.synchronized)
    }

    /// Case 2, the escrow present and no device keys: over a synchronized escrow row and the
    /// key-agreement row a previous build left (synchronized, alice's key) with no signing row,
    /// provisioning adopts the escrow without reading that row into it: it mints fresh device keys over
    /// every identity row, device-only, and promotes nothing, so no content-addressed row is added and
    /// the previous build's row is gone.
    @Test func caseTwoAdoptsTheEscrowAndMintsFreshDeviceKeys() throws {
        let service = Self.throwawayService()
        defer { Self.sweep([service]) }
        try Self.plantSyncedEscrow(Self.escrowRaw, account: Self.escrowFixtureAccount, under: service)
        try Self.plantPreviousBuildKeyAgreementRow(Self.aliceKeyAgreementRaw, under: service)
        let identity = Self.escrowIdentity(keychainService: service)
        try identity.ensureProvisioned()
        #expect(Self.hex(identity.localBackupEscrowPublicKey) == Self.escrowPubHex, "Case 2 adopted another escrow")
        let fresh = identity.localKeyAgreementPublicKey
        #expect(!fresh.isEmpty && fresh != Self.alicePub, "Case 2 kept the previous build's key-agreement key")
        let rows = Self.rows(under: service)
        #expect(rows.synced == [Self.escrowFixtureAccount: Self.escrowRaw],
                "Case 2's synchronized rows: \(rows.synced.keys.sorted())")
        #expect(Set(rows.local.keys) == Self.identityAccountSet, "Case 2's device-only rows: \(rows.local.keys.sorted())")
        #expect(rows.local[Self.identityAccounts.keyAgreementPublicKeyCache] == fresh, "Case 2's key cache")
        #expect(Self.attributes(of: Self.identityAccounts.keyAgreementPrivateKey, under: service) == Self.deviceOnly)
    }

    /// Case 3, a previous build's key-agreement row and nothing else: provisioning promotes that key,
    /// before the mint overwrites its row, to its own content-addressed account (alice's frozen one),
    /// synchronized and `kSecAttrAccessibleAfterFirstUnlock`, adopts it as the escrow, and mints fresh
    /// device keys over every identity row, device-only.
    @Test func caseThreePromotesThePreviousBuildsKeyBeforeTheMint() throws {
        let service = Self.throwawayService()
        defer { Self.sweep([service]) }
        try Self.plantPreviousBuildKeyAgreementRow(Self.aliceKeyAgreementRaw, under: service)
        let identity = Self.escrowIdentity(keychainService: service)
        try identity.ensureProvisioned()
        #expect(Self.hex(identity.localBackupEscrowPublicKey) == Self.alicePubHex, "Case 3 adopted another escrow")
        let fresh = identity.localKeyAgreementPublicKey
        #expect(!fresh.isEmpty && fresh != Self.alicePub, "Case 3 kept the previous build's key as the device key")
        let rows = Self.rows(under: service)
        #expect(rows.synced == [Self.aliceEscrowAccount: Self.aliceKeyAgreementRaw],
                "Case 3's synchronized rows: \(rows.synced.keys.sorted())")
        #expect(Set(rows.local.keys) == Self.identityAccountSet, "Case 3's device-only rows: \(rows.local.keys.sorted())")
        #expect(rows.local[Self.identityAccounts.keyAgreementPublicKeyCache] == fresh, "Case 3's key cache")
        #expect(Self.attributes(of: Self.aliceEscrowAccount, under: service) == Self.synchronized)
        #expect(Self.attributes(of: Self.identityAccounts.keyAgreementPrivateKey, under: service) == Self.deviceOnly)
    }

    // MARK: Group 13 — the feature salts `.fernlet` declares

    /// `.fernlet`'s family declares exactly the heart dead-drop's and presence's pair salts, in that
    /// order, under those names: each a key-derivation salt spelled as its group 1 row's frozen
    /// literal, byte for byte the FernletCrypto registry entry it twins, and the very value a caller
    /// of the door passes (`FernletFeaturePurposes`).
    @Test func fernletDeclaresTheTwoPairSaltsAsItsFeaturePurposes() {
        let entries = ProximityNamespace.fernlet.family.purposes.feature.entries
        let expected: [(name: String, frozen: String, twin: CryptographicPurpose)] = [
            ("heartDropPairV1", Self.frozenLabel("KeyDerivation.heartDropPairV1"),
             FernletCryptoPurpose.KeyDerivation.heartDropPairV1),
            ("presencePairV1", Self.frozenLabel("KeyDerivation.presencePairV1"),
             FernletCryptoPurpose.KeyDerivation.presencePairV1)
        ]
        #expect(entries.map(\.name) == expected.map(\.name), "`.fernlet` declares \(entries.map(\.name))")
        // R2: bounded by the two declared salts.
        for (entry, row) in zip(entries, expected) {
            #expect(entry.purpose.rawValue == row.frozen && entry.purpose.data == Data(row.frozen.utf8),
                    "\(entry.name) is \(entry.purpose.rawValue); its frozen spelling is \(row.frozen)")
            #expect(entry.purpose.role == .keyDerivationSalt, "\(entry.name) is declared as \(entry.purpose.role)")
            #expect(entry.purpose.data == row.twin.data, "\(entry.name)'s bytes are not its registry twin's")
        }
        #expect(entries.map(\.purpose) == [FernletFeaturePurposes.heartDropPairV1, FernletFeaturePurposes.presencePairV1],
                "the declared salts and the constants a caller passes are two spellings")
    }

    /// Under each salt `.fernlet` declares, ProximityKit's pair-secret door gives group 2's known
    /// answer on planted alice and on planted bob: the generic door re-derives the heart-drop and
    /// presence pair secrets byte for byte, from either side.
    @Test func thePairSecretDoorDerivesTheKnownAnswersUnderFernletsSalts() throws {
        let aliceService = Self.throwawayService()
        let bobService = Self.throwawayService()
        defer { Self.sweep([aliceService, bobService]) }
        let alice = try Self.plantedAlice(service: aliceService)
        let bob = try Self.plantedIdentity(signing: Self.bobSigningRaw, keyAgreement: Self.bobKeyAgreementRaw,
                                           service: bobService)
        let alicePublic = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: Self.alicePub)
        let bobPublic = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: Self.bobPub)
        let heart = FernletFeaturePurposes.heartDropPairV1
        let presence = FernletFeaturePurposes.presencePairV1
        let secrets = try [
            ("alice's heart", alice.pairSecret(with: bobPublic, purpose: heart), Self.heartPairSecretHex),
            ("bob's heart", bob.pairSecret(with: alicePublic, purpose: heart), Self.heartPairSecretHex),
            ("alice's presence", alice.pairSecret(with: bobPublic, purpose: presence), Self.presencePairSecretHex),
            ("bob's presence", bob.pairSecret(with: alicePublic, purpose: presence), Self.presencePairSecretHex)
        ]
        // R2: bounded by the four secrets.
        for (name, secret, frozen) in secrets {
            let actual = Self.hex(secret.withUnsafeBytes { Data($0) })
            #expect(actual == frozen, "\(name) pair secret through the door is \(actual)")
        }
    }

    // MARK: Group 14 — the heart-eligibility predicate

    /// A signing key and a fingerprint no record holds. The predicate compares fingerprints as the
    /// block list holds them, so a fingerprint here is a label and needs no key behind it.
    static var strangerSigningKey: Data { consecutiveBytes(from: 0xe0) }
    /// The stranger's fingerprint label.
    static let strangerFingerprint = "e0e1e2e3e4e5e6e7"
    /// carol's signing key, a removed friend's: the bytes 0xf0…0x0f, as a key only.
    static var carolSigningKey: Data { consecutiveBytes(from: 0xf0) }
    /// carol's fingerprint label.
    static let carolFingerprint = "f0f1f2f3f4f5f6f7"

    /// The vault the predicate asks: alice remembered and unblocked; bob remembered (never removed)
    /// with his key and fingerprint blocked; carol removed and unblocked. Planted as records, so each
    /// leg can be held apart from the others; `ProximityTrustVault.block(signingPublicKey:)` would
    /// remove bob too.
    static var eligibilityRecords: [ProximityTrustedPeerRecord] {
        let met = Date(timeIntervalSince1970: 1_700_000_000)
        return [
            ProximityTrustedPeerRecord(
                displayName: "Alice", fingerprint: aliceFingerprint, signingPublicKey: bytes(fromHex: aliceSigningPubHex),
                keyAgreementPublicKey: alicePub, mode: .friend, firstAcceptedAt: met, lastSeenAt: met),
            ProximityTrustedPeerRecord(
                displayName: "Bob", fingerprint: bobFingerprint, signingPublicKey: bytes(fromHex: bobSigningPubHex),
                keyAgreementPublicKey: bobPub, mode: .friend, firstAcceptedAt: met, lastSeenAt: met, blockedAt: met),
            ProximityTrustedPeerRecord(
                displayName: "Carol", fingerprint: carolFingerprint, signingPublicKey: carolSigningKey,
                keyAgreementPublicKey: escrowPub, mode: .friend, firstAcceptedAt: met, lastSeenAt: met, revokedAt: met)
        ]
    }

    /// The core's predicate answers each leg as presence's gate does, and as the frozen column says:
    /// a remembered, unblocked key with an unblocked fingerprint is eligible; a key the vault never
    /// met, a removed friend's key, a blocked key under an unblocked fingerprint and an unblocked key
    /// under a blocked fingerprint are not. Over the presence suites' host (`MockPresenceQUICHost`),
    /// never a second copy of a host.
    @Test func theHeartEligibilityPredicateAnswersItsThreeLegsAsPresenceDoes() {
        let host = MockPresenceQUICHost()
        host.proximityTrustVault.apply(peers: Self.eligibilityRecords, audit: [])
        let alice = Self.bytes(fromHex: Self.aliceSigningPubHex)
        let bob = Self.bytes(fromHex: Self.bobSigningPubHex)
        let rows: [(what: String, key: Data, fingerprint: String, eligible: Bool)] = [
            ("alice, remembered and unblocked", alice, Self.aliceFingerprint, true),
            ("a stranger the vault never met", Self.strangerSigningKey, Self.strangerFingerprint, false),
            ("carol, removed", Self.carolSigningKey, Self.carolFingerprint, false),
            ("bob's blocked key under an unblocked fingerprint", bob, Self.strangerFingerprint, false),
            ("alice's key under bob's blocked fingerprint", alice, Self.bobFingerprint, false)
        ]
        // R2: bounded by the five rows.
        for row in rows {
            let core = Self.coreHeartEligibility(of: row.key, fingerprint: row.fingerprint, in: host)
            let presence = Self.presenceHeartEligibility(of: row.key, fingerprint: row.fingerprint, in: host)
            #expect(core == row.eligible, "the core's predicate answers \(core) for \(row.what)")
            #expect(presence == core, "presence's gate answers \(presence) for \(row.what), the core \(core)")
        }
    }
}

// MARK: - Accessors

extension FernletFeatureGoldenTests {

    /// The gossiped prekey bundle's type, today the core wire type `ProximityPrekeyBundle`.
    typealias PrekeyBundle = ProximityPrekeyBundle
    /// One one-time prekey of a bundle, today `ProximityPrekeyBundle.PrekeyEntry`.
    typealias PrekeyEntry = ProximityPrekeyBundle.PrekeyEntry
    /// A bundle's signed prekey, today `ProximityPrekeyBundle.SignedPrekey`.
    typealias SignedPrekey = ProximityPrekeyBundle.SignedPrekey

    /// The bundle types the heart-drop prekey store mints and keeps, today
    /// `HeartPrekeyStore.Bundle`, `.PrekeyEntry` and `.SignedPrekey`, as object identifiers, in that
    /// order.
    static var prekeyStoreBundleTypes: [ObjectIdentifier] {
        [ObjectIdentifier(HeartPrekeyStore.Bundle.self), ObjectIdentifier(HeartPrekeyStore.PrekeyEntry.self),
         ObjectIdentifier(HeartPrekeyStore.SignedPrekey.self)]
    }

    /// The static-key agreement a static-fallback drop opens through: today
    /// `staticKeyAgreement(withEphemeralPublicKey:)`.
    static func staticAgreement(_ identity: IdentityService, withEphemeralPublicKey key: Data) throws -> SharedSecret {
        try identity.staticKeyAgreement(withEphemeralPublicKey: key)
    }

    /// Has `coordinator` offer `bundle` in every introduction it sends: today's
    /// `introductionPrekeyBundleProvider`.
    static func offer(_ bundle: PrekeyBundle, on coordinator: ProximityCoordinator) {
        coordinator.introductionPrekeyBundleProvider = { bundle }
    }

    /// Has `coordinator` hand every bundle a peer's introduction carries to `collector`: today's
    /// `onIntroductionPrekeyBundle`.
    static func collect(into collector: PrekeyBundleCollector, on coordinator: ProximityCoordinator) {
        coordinator.onIntroductionPrekeyBundle = { sender, bundle in collector.record(sender: sender, bundle: bundle) }
    }

    /// The core's heart-eligibility predicate: today
    /// `ProximityHost.isTrustedUnblockedPeer(signingPublicKey:fingerprint:)`.
    static func coreHeartEligibility(of signingKey: Data, fingerprint: String, in host: any ProximityHost) -> Bool {
        host.isTrustedUnblockedPeer(signingPublicKey: signingKey, fingerprint: fingerprint)
    }

    /// Presence's heart-eligibility gate: today
    /// `PresenceManager.isHeartEligible(signingPublicKey:fingerprint:in:)`.
    static func presenceHeartEligibility(of signingKey: Data, fingerprint: String, in host: any ProximityHost) -> Bool {
        PresenceManager.isHeartEligible(signingPublicKey: signingKey, fingerprint: fingerprint, in: host)
    }

    /// The ONE construction of every identity the escrow group provisions: today the app's factory,
    /// `IdentityService.fernletApp(keychainService:)`, whose identity carries Fernlet's sealed-backup
    /// escrow key as its provisioning participant. The only line of that group that says how Fernlet
    /// builds an identity, so a change to how it builds one re-points this line and never a literal or
    /// a case.
    static func escrowIdentity(keychainService: String) -> IdentityService {
        IdentityService.fernletApp(keychainService: keychainService)
    }
}

// MARK: - Fixtures

extension FernletFeatureGoldenTests {

    /// alice's key-agreement private key, the bytes 0x01…0x20.
    static var aliceKeyAgreementRaw: Data { consecutiveBytes(from: 0x01) }
    /// alice's signing private key, the bytes 0x21…0x40.
    static var aliceSigningRaw: Data { consecutiveBytes(from: 0x21) }
    /// bob's key-agreement private key, the bytes 0x41…0x60.
    static var bobKeyAgreementRaw: Data { consecutiveBytes(from: 0x41) }
    /// bob's signing private key, the bytes 0x61…0x80.
    static var bobSigningRaw: Data { consecutiveBytes(from: 0x61) }
    /// The escrow fixture's key-agreement private key, the bytes 0xc0…0xdf.
    static var escrowRaw: Data { consecutiveBytes(from: 0xc0) }

    /// alice's key-agreement public key, X25519 over 0x01…0x20.
    static let alicePubHex = "07a37cbc142093c8b755dc1b10e86cb426374ad16aa853ed0bdfc0b2b86d1c7c"
    /// bob's key-agreement public key, X25519 over 0x41…0x60.
    static let bobPubHex = "64b101b1d0be5a8704bd078f9895001fc03e8e9f9522f188dd128d9846d48466"
    /// The escrow fixture's public key, X25519 over 0xc0…0xdf.
    static let escrowPubHex = "dc2cca31e8e43bbd91dff7e475cca3347eb478107d5bd765aba4ae4a30c35d44"
    /// alice's signing public key, Ed25519 over the seed 0x21…0x40.
    static let aliceSigningPubHex = "e7f162a10bec559afea195e4dce84b69568d5d2cb0963eb446c0685e2b17f2f0"
    /// bob's signing public key, Ed25519 over the seed 0x61…0x80.
    static let bobSigningPubHex = "882d0ea3b2864e7a587f3e698cea4459998312e655e05fa5e8b5119d8baac8cd"
    /// alice's fingerprint: the first 16 hex characters of SHA-256 over her signing public key.
    static let aliceFingerprint = "c945cbf2a5602002"
    /// bob's fingerprint, the same way.
    static let bobFingerprint = "b4cb4b93c4027ce3"

    /// alice's key-agreement public key, as bytes.
    static var alicePub: Data { bytes(fromHex: alicePubHex) }
    /// bob's key-agreement public key, as bytes.
    static var bobPub: Data { bytes(fromHex: bobPubHex) }
    /// The escrow fixture's public key, as bytes.
    static var escrowPub: Data { bytes(fromHex: escrowPubHex) }

    /// A device-only row's attributes, as provisioning writes the identity's rows.
    static let deviceOnly = RowAttributes(
        accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String, synchronizable: false)
    /// A synchronized escrow row's attributes, as a promotion writes one.
    static let synchronized = RowAttributes(accessible: kSecAttrAccessibleAfterFirstUnlock as String, synchronizable: true)

    /// `.fernlet`'s four identity accounts.
    static var identityAccounts: ProximityNamespace.Keychain.IdentityRows {
        ProximityNamespace.fernlet.installation.keychain.identity
    }

    /// The four identity accounts as a set.
    static var identityAccountSet: Set<String> {
        let accounts = identityAccounts
        return [accounts.signingPrivateKey, accounts.signingPublicKeyCache,
                accounts.keyAgreementPrivateKey, accounts.keyAgreementPublicKeyCache]
    }

    /// A keychain row's accessibility class and synchronizable flag.
    struct RowAttributes: Equatable, Sendable {
        /// `kSecAttrAccessible`.
        let accessible: String
        /// `kSecAttrSynchronizable`.
        let synchronizable: Bool
    }

    /// The frozen spelling of the label row `field`; empty for a field no row holds, which fails what
    /// reads it.
    static func frozenLabel(_ field: String) -> String {
        labelRows.first { $0.field == field }?.frozen ?? ""
    }

    /// The frozen literal of the keychain name row `field`; empty for a field no row holds.
    static func frozenName(_ field: String) -> String {
        keychainNameRows.first { $0.field == field }?.frozen ?? ""
    }

    /// Compares every name row with its frozen literal; returns how many rows were compared.
    static func expectFrozen(_ rows: [FeatureGoldenNameRow]) -> Int {
        // R2: bounded by the rows.
        for row in rows {
            #expect(row.today == row.frozen, "\(row.field) is \(row.today); its frozen literal is \(row.frozen)")
        }
        return rows.count
    }

    /// A throwaway keychain service of this suite's own, swept by the caller's `defer`.
    static func throwawayService() -> String {
        "com.fernlet.test.ffgt.\(UUID().uuidString)"
    }

    /// Removes every row under each service.
    static func sweep(_ services: [String]) {
        // R2: bounded by the services.
        for service in services {
            KeychainItem.deleteAll(service: service)
        }
    }

    /// Stores the device rows given, device-only, at `.fernlet`'s identity accounts under `service`.
    static func plantDeviceRows(signing: Data?, keyAgreement: Data?, under service: String) throws {
        let accounts = identityAccounts
        let rows = [(accounts.signingPrivateKey, signing), (accounts.keyAgreementPrivateKey, keyAgreement)]
        // R2: bounded by the two rows.
        for (account, data) in rows {
            guard let data else { continue }
            let status = KeychainItem.store(data, account: account, service: service,
                                            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
            try #require(status == errSecSuccess, "planting \(account) failed: \(status)")
        }
    }

    /// Stores the key-agreement row a build from before the device-only identity left: synchronized,
    /// `kSecAttrAccessibleAfterFirstUnlock`, at `.fernlet`'s key-agreement account under `service`.
    static func plantPreviousBuildKeyAgreementRow(_ key: Data, under service: String) throws {
        let status = KeychainItem.store(key, account: identityAccounts.keyAgreementPrivateKey, service: service,
                                        accessibility: kSecAttrAccessibleAfterFirstUnlock, synchronizable: true)
        try #require(status == errSecSuccess, "planting the previous build's key-agreement row failed: \(status)")
    }

    /// Stores `key` as a synchronized escrow row at `account` under `service`.
    static func plantSyncedEscrow(_ key: Data, account: String, under service: String) throws {
        let status = KeychainItem.store(key, account: account, service: service,
                                        accessibility: kSecAttrAccessibleAfterFirstUnlock, synchronizable: true)
        try #require(status == errSecSuccess, "planting the escrow row failed: \(status)")
    }

    /// A planted identity under `service`: the device rows given, then `IdentityService(namespace:
    /// .fernlet, keychainService:)` provisioned, which adopts them.
    static func plantedIdentity(signing: Data, keyAgreement: Data, service: String) throws -> IdentityService {
        try plantDeviceRows(signing: signing, keyAgreement: keyAgreement, under: service)
        let identity = IdentityService(namespace: .fernlet, keychainService: service)
        try identity.ensureProvisioned()
        return identity
    }

    /// Planted alice under `service`.
    static func plantedAlice(service: String) throws -> IdentityService {
        try plantedIdentity(signing: aliceSigningRaw, keyAgreement: aliceKeyAgreementRaw, service: service)
    }

    /// Every row under `service`, by account, split by its synchronizable flag.
    static func rows(under service: String) -> (synced: [String: Data], local: [String: Data]) {
        let synced = KeychainItem.loadAll(service: service, synchronizable: .synced).map { ($0.account, $0.data) }
        let local = KeychainItem.loadAll(service: service, synchronizable: .local).map { ($0.account, $0.data) }
        return (Dictionary(synced, uniquingKeysWith: { first, _ in first }),
                Dictionary(local, uniquingKeysWith: { first, _ in first }))
    }

    /// One row's accessibility and synchronizable flag, read back with `SecItemCopyMatching` as
    /// `KeyCustodyBoundaryTests` reads them; nil when no row matches.
    static func attributes(of account: String, under service: String) -> RowAttributes? {
        var result: AnyObject?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
            kSecUseDataProtectionKeychain as String: true
        ]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let attributes = result as? [String: Any],
              let accessible = attributes[kSecAttrAccessible as String] as? String else { return nil }
        let synchronizable = (attributes[kSecAttrSynchronizable as String] as? NSNumber)?.boolValue ?? false
        return RowAttributes(accessible: accessible, synchronizable: synchronizable)
    }

    /// A fresh scratch directory nobody else uses.
    static func scratchDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ffgt-\(UUID().uuidString)", isDirectory: true)
    }

    /// Removes a scratch directory; one already gone is fine.
    static func removeDirectory(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Writes `json` to `url`, creating its folder.
    static func write(_ json: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
    }

    /// Noon on a calendar day in the current time zone, which the closeness ledger's day keys use.
    static func localNoon(year: Int, month: Int, day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? .distantPast
    }

    /// `count` consecutive bytes (32 unless given) from `start`, wrapping past 0xff.
    static func consecutiveBytes(from start: UInt8, count: Int = 32) -> Data {
        Data((0..<count).map { start &+ UInt8(truncatingIfNeeded: $0) })
    }

    /// A fixture id; a malformed literal falls back to a random id, which fails every golden it reaches.
    static func uuid(_ text: String) -> UUID {
        UUID(uuidString: text) ?? UUID()
    }

    /// Lowercase hex of `data`.
    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// Hex → bytes, for the frozen vectors. Bounded, and a bad pair is skipped rather than
    /// force-unwrapped, which fails every golden it reaches.
    static func bytes(fromHex hex: String) -> Data {
        let characters = Array(hex)
        var data = Data()
        // R2: bounded by the string's length.
        for pair in stride(from: 0, to: characters.count - 1, by: 2) {
            if let byte = UInt8(String(characters[pair...(pair + 1)]), radix: 16) { data.append(byte) }
        }
        return data
    }
}
