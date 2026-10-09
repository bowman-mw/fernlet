// FernletFeatureGoldenTests.swift
// FernletTests
//
// Fernlet's features over the proximity stack (the heart dead-drop, presence, moderation, closeness,
// friend state, and the sealed-backup escrow beside the identity) put bytes on the wire,
// in the keychain and on disk that no other suite pins, and plan step A0.4 moved every one of those
// features or re-derived its bytes (Docs/Plan-FernletCoach-ProximityKit-2026-10-01.md §4 A0.4). Plan
// step A0.5 does the same for the features the routed mesh manager still carries (the advertised
// capabilities, the routed rows, bodies and senders, activities, the clothing shop, the moderation
// relay, friend state, the vouch list and the session's photos, chat and hearts), splitting them out
// of the engine into FernletSocial (§4 A0.5). This suite holds each such byte to the value Fernlet
// ships: by a hand-written literal, and wherever a production consumer can be reached without a new
// seam, by driving that consumer and reading what it emits or opens; and it holds the order a
// session's commit and end run their legs in, by observing it. Moving a feature moves no byte and
// reorders no leg; this file is how that claim is checked rather than asserted.
//
// THE RULE. Every literal is FROZEN: a red cell is a wire, keychain or at-rest decision, never
// re-pinned from Swift's output. A cell reaches production only through today's production spellings:
// the label rows' `today` column, the name rows' `today` column, and the accessors gathered under
// "Accessors" at the foot of the suite. When a value or its reader moves, only its accessor is
// re-pointed at the path production then reads, and a moved consumer no cell drives yet gains a cell.
//
// Twenty-nine groups:
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
// 15. **The advertised capability array**: the array `localCapabilities()` advertises in each of the
//     32 states of the five switches it reads, in order, driven through the app's own wiring of each,
//     and a fresh install's.
// 16. **The routed caps and their bounds**: the numbers the photo, text and heart rows' caps are built
//     from, each row's cap as its terms, and the widest row's cap as the bound the item seal, its open
//     and the delivery projection's resident guard read, held at the seal's two edges, and held by the
//     manager where no fixture registry handed to it afterwards moves it.
// 17. **The tokens the senders mint**: one photo, one message and one heart from a founded pair, each
//     staged under its sender's frozen token.
// 18. **The routed item bodies**: the routed heart body for an item, a day and a name, and again for a
//     name holding a `/`, a quoted word and a non-ASCII letter, and the routed text body under that
//     name, sent half a second past a whole second, each framed by production as its frozen bytes,
//     which are its frozen JSON after its length, and decoded back to its inputs.
// 19. **The canonical signing transcripts** of the activity and moderation features: the four
//     FernletCrypto labels as the length-prefixed fields `signingBytes` hands CryptoKit, four activity
//     descriptors' canonical bytes and params hashes (a fractional, a pre-1970, two saturating and an
//     infinite date among them), the join token's and a two-member roster's transcripts with frozen
//     RFC 8032 signatures production's verify accepts and byte-flipped twins it refuses, the roster
//     cap verifying twelve members and refusing a validly signed thirteen, the two moderation rows'
//     transcripts and signatures through the relay, and the three signers writing the frozen
//     transcripts.
// 20. **The feature payloads' JSON**: the five activity payloads, the clothing catalog and the shop's
//     catalog request, the moderation report (with its decode defaults and its 32-row cap) and the
//     friend vouch list, each a frozen sorted-keys text that production decodes to its fixture value
//     and re-encodes as the same JSON object, and the catalog and request the mesh itself sends on a
//     commit.
// 21. **The heart ledger's file**: a v2 HeartLedger.json and a v1 blob load into their state, and three
//     sends write their frozen files.
// 22. **The activity ledger's file**: bob's ActivityLedger.json loads into his hosted and joined
//     activities, saves unchanged, drops the joined row at its expiry, and a received grant writes the
//     joined ledger.
// 23. **The photo wall's files and the proximity root's layout**: the legacy wall index and the wall
//     preferences load into the wall's posts, stale preferences are pruned and rewritten, and the mesh
//     and its composition file every store they build under its frozen name inside the host's proximity
//     root.
// 24. **The keychain role that seals each photo corpus**: the wall's resealed index opens under the
//     friend-wall key alone, and a held photo under the pending-session-photos key alone, each refused
//     by the other role's key.
// 25. **The vouch list's lifetime and label**: the list a manager would send expires two hours after it
//     is built, a received one is cached for no longer than two hours, and a friend it names is
//     labelled "Friend of " and the voucher's name.
// 26. **The item report and the friend state sent at a commit**: both sealed to the kept friend's
//     key-agreement key in the legacy framing, the report carrying group 20's frozen rows but for their
//     signatures and kept whole by the relay, the friend state decoding to the state sent.
// 27. **The camera's hold-failure line**: its key, English default and comment, as the copy vault asks
//     for them and the catalog files them.
// 28. **The audit lines the moved code writes**: every line a moved file, range or mesh-manager range
//     writes on a path a cell can drive today, its token and its whole context, read from the one call
//     that wrote it, and the frozen spelling of the reasons a line only a second device's item reaches
//     carries.
// 29. **The order of a session's commit and end**: the closeness hook, then the catalog and its
//     request, the item report, the friend state and the activity offer; the review's roster half, its
//     photo half, the shop window, the transcript and the heart state; and the photo-session ids a new
//     search and a leave keep until the session's photos are moved.
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
// Groups 15 to 29 cite the same way: the capability tokens' spellings and the coordinator's receive
// bounds (`ProximityVocabularyGoldenTests.everyCapabilityIsItsFrozenSpelling` and
// `theCoordinatorKeepsEighteenTokensEachCutToThirtyTwoCharacters`), the routed-type tokens and the heart
// row's cap (`ProximityVocabularyGoldenTests.everyRoutedTypeTokenAndTheHeartCapIsFrozen`), every column
// of the three routed rows (`MeshRoutedTypeRegistryTests.everyFieldOfEveryEntryIsSet`,
// `theForegroundDecryptRequirementIsDerivedFromTheStage`), the photo row's cap and payload bound
// (`MeshRoutedTypeRegistryTests.theReceivePolicyBytesAreAPinnedChoiceNotADriveBy`), the text row's cap
// (`MeshRoutedTextBodyTests.theTextRowsCapIsTheSanitizedMaximumsCiphertextBound`), the seal and open
// bounds as one number (`MeshRoutedItemSealTests.theSealBoundAndTheOpenBoundAreTheSameNumber`), the
// routed expiry's grace (`MeshRoutedManifestTests.expiryIsHardDeadlinePlusTwentyMinutesFloored`), the
// heart sender's one destination (`MeshSessionHeartTests.aHeartMintsOneDestinationAndIsConsumedOnStage`),
// the routed photo bodies with and without a session and the routed text body with a whole-second date
// and an ASCII name (`MeshRoutedItemSealGoldenTests.goldenBodyHex` and `goldenSessionBodyHex`,
// `MeshRoutedTextBodyTests.goldenTextBodyHex`), the routed heart body's round trip, hostile shapes, name
// bound and day-key refusal (`MeshRoutedHeartBodyTests`), the moderation label's framing, behaviourally
// (`CryptographicPurposeBoundaryTests.canonicalSerializerTranscriptsMatchTheirDeclaredFraming`), the
// labels' pairwise separation (`CryptographicDomainSeparationTests`), the activity and relay round trips
// (`ActivityTests`, `ModerationTests`, on the mesh-features line), the payload-type tokens and the
// sealing set (`ProximityVocabularyGoldenTests`' payload rows; group 20 pins only the bodies), a full
// `PayloadSummary`'s JSON
// (`ProximityVocabularyGoldenTests.theEncryptionAndSummaryEncodeToTheirFrozenJSON`), the catalog's wire2
// framing (`ProximityVocabularyGoldenTests.theMeshFramesItsSealedSendsByItsHostsWire2Token`), the wall's
// layout names through the media census's restatement
// (`Phase3GateReadoutTests.theMediaLabelMappingHoldsAgainstLiteralPathComponents`), the pending corpus's
// index and folder names inside its directory (`PendingSessionPhotoStoreTests`' fixtures), the media key
// rows' attributes and their independence (`KeyCustodyBoundaryTests`), the vouch gate's default and its
// sender binding (`VouchListBroadcastGateTests`, on the mesh-features line), the friend state's field
// names (`CompanionEmotionPrivacyTests.theFriendFoldIsUnchanged`), the module catalogs' existence
// (`LocalizationBoundaryTests.theModuleStringCatalogsAddedBySection40StillExist`), a new search moving a
// left photo into the review
// (`MeshLastMemberPhotoReviewTests.aNewSearchMovesLeftoverPhotosIntoTheReviewRatherThanDroppingThem`),
// the moved audit lines a mesh suite already captures (`mesh.routedShare.skipped`,
// `MeshRoutedPhotoDeliveryTests.aCaptureWithNoDestinationsStillReachesTheOwnWallSilently`; the photo
// opener's `mesh.routedProjection.openFailed`, `.aBodyWhoseIDIsNotTheItemIDIsRefused`;
// `mesh.routedProjection.photoAlreadyAnswered`,
// `MeshHeldSessionPhotoTests.anAnsweredPhotoIsRefusedFromCustodyByARebuiltManager`), and the reasons a
// heart that is not sent names (`MeshSessionHeartTests.everyHeartFailureCauseIsAFrozenToken`) and a
// refused share's (`RoutedShareRefusalCopyTests.everyCauseHasLocalizedCopy`).
//
// Fixed inputs: alice's key-agreement private key is the bytes 0x01…0x20 and her signing key
// 0x21…0x40; bob's are 0x41…0x60 and 0x61…0x80; the reporter-tag salt is 0x80…0x9f, the sidecar key
// 0xa0…0xbf and a third key-agreement key, the escrow fixture's, 0xc0…0xdf; group 14's stranger and
// carol hold 0xe0…0xff and 0xf0…0x0f as signing keys only, from which nothing is derived. A planted
// identity is its signing and key-agreement private rows stored device-only at `.fernlet`'s identity
// accounts under a throwaway service (`com.fernlet.test.ffgt.<UUID>`, swept in a `defer`), then built with
// `IdentityService(namespace: .fernlet, keychainService:)` and provisioned, which adopts them
// (provisioning's Case 1). Every identity here names its namespace or the app's factory, never a test
// binding (ProximityNamespaceTestBindings.swift, FernletAppTestBindings.swift), but for group 17's
// founded pair (below); the escrow group builds its identities through one accessor,
// ``FernletFeatureGoldenTests/escrowIdentity(keychainService:)``, today the app's factory, whose
// identity carries the sealed-backup escrow key.
//
// Groups 15 to 29 claim no new key bytes. Group 16's seal probes reuse the sidecar key's bytes as a
// content key, bound to the mesh `0A050000-7AB1-4E50-8000-000000000001`, the item
// `0A050000-7AB1-4E50-8000-000000000002` and alice's fingerprint, and read only the sizes the seal and
// the open take and refuse; group 17 mints on the routed suites' founded pair (`MeshFoundingRig`), as
// those suites build it. Group 18's bodies name the routed suites' item
// `5A5A5A5A-6B6B-4C4C-8D8D-3E3E3E3E3E3E`. Group 19's activity, `A1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D`,
// is alice's, signed with her fixed key, and groups 20 and 22 carry it too; its roster guests 3…13
// hold `Data(repeating: k, count: 32)` and `Data(repeating: 0x10 + k, count: 32)` as stand-in keys,
// from which nothing is derived. Groups 20 to 23's other ids read `XXXXXXXX-4A53-4F4E-8000-0000000000NN`
// (`4A53 4F4E` is "JSON"), and bob's own activity among them is signed with his fixed key; groups 24
// to 29's read `XXXXXXXX-4841-4E44-8000-0000000000NN` (`4841 4E44` is "HAND"); and every photo groups
// 23, 24 and 29 hold is the routed suites' tiny JPEG (`MeshRoutedPhotoFixtures.tinyJPEG()`). Group
// 28's origins are labels (`ffgt-origin-…`), its forged report row carries 64 zero bytes as a
// signature, and its clocks stand at 780 000 000 s after the reference date.
//
// Every vector of groups 1 to 14 was confirmed by two independent computations before it was frozen:
// a Python re-implementation over OpenSSL (`cryptography`), proved honest first by reproducing
// `SealedBackupFormatPinTests`' two escrow known answers, and a CryptoKit construction written from
// the format with no production type in it; the two frozen blobs were built once by the CryptoKit
// construction and rebuilt byte for byte by the Python one, and the bundle JSON was built by
// Foundation's output rules (keys sorted, no whitespace, `/` escaped, a whole number printed without
// a fraction, a UUID upper-case, data base64). Nothing here was copied out of Swift's output.
//
// Groups 15 to 23's vectors were confirmed by two independent computations too, but both of them are
// Python: per family of vectors, two implementations, the second written from the Swift source before
// the first's vectors were opened, reconciled byte for byte with no disagreement left (the tables'
// 92 vectors, the bodies' 7, the transcripts' 31, the JSON's 38). The tables were evaluated from the
// source text, once by interpreting `localCapabilities()` and each constant's declaration and once by
// hand transcription held to a mechanical scan of the declarations; the bodies' two writers first
// reproduced the three body vectors other suites pin; the transcripts were signed over OpenSSL
// (`cryptography`) and over libsodium (PyNaCl), with pycryptodome and a pure-Python RFC 8032 made to
// agree; the JSON follows each encoder as production configures it, frozen as Foundation's
// `.sortedKeys` spelling. No Swift ran where they were frozen, so production's run on the Mac is each
// vector's third computation, and for group 19 its first CryptoKit one: its signatures are RFC 8032's
// deterministic ones, and CryptoKit signs with fresh randomness, so a cell pins that production's
// verify accepts a frozen signature, never a signature production makes. Groups 24 to 29 compute no
// byte: their frozen values are read off today's code (a keychain role, `2 * 3600`, a label prefix, a
// catalog entry, an audit line's token and context, the legs of a commit and of an end) or recompose
// groups 19, 20 and 23's vectors; the orders were checked against the A0.5 census's independent
// reading of the same code, and the one derived figure, 15 500 bytes for 500 Characters of `e` and
// fifteen U+0301, was computed in Python and recounted by hand. Nothing in groups 15 to 29 was copied
// out of Swift's output either.

import CryptoKit
import FernletConnections
import FernletCrypto
import FernletDomainModel
import FernletFoundation
import Foundation
import Observation
import os
import Security
import Testing
@testable import Fernlet
@testable import FernletSocial
@testable import PrivateMediaStore
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

/// One number a moving feature's routed bytes are built from: what it is, its FROZEN value, and the
/// constant production reads.
struct FeatureGoldenNumberRow: Sendable {
    /// A stable path naming the number, e.g. `text.payloadBound`.
    let field: String
    /// The number, written by hand. Never computed from a constant; never edited.
    let frozen: Int
    /// The constant production reads: **the only column a commit that moves the number may re-point.**
    let today: Int
}

/// One FernletCrypto label a moving feature's canonical transcript opens with: the bytes its framing
/// requires a transcript to begin with, FROZEN, and the purpose production reads.
struct FeatureGoldenTranscriptLabelRow: Sendable {
    /// The registry entry, as `Group.name`.
    let field: String
    /// The prefix, written by hand from the A0.5 vectors: the spelling's UTF-8 byte count as 8 big-endian
    /// bytes, then those bytes, in hex. Never computed from a constant; never edited.
    let frozenPrefix: String
    /// The purpose production names: **the only column a commit that moves the label may re-point.**
    let today: CryptographicPurpose
}

// MARK: - The suite

/// Every byte the features plan steps A0.4 and A0.5 move or re-derive put on the wire, in the keychain
/// or on disk, pinned by literal and by behaviour, and the order a session's commit and end run their
/// legs in: the gate each of those moves passes unchanged, and every later one must.
///
/// **The rule for every commit: re-point an accessor, never a literal.** A frozen literal was written
/// by hand and confirmed by two independent computations, or read off today's code; a failing one is a
/// WIRE, KEYCHAIN or AT-REST decision, so it is never re-pinned from Swift's output to go green.
/// Failure messages print the actual bytes so a deliberate change can be argued from them.
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

    // MARK: Group 15 — the advertised capability array

    /// The capability array a device advertises in its signed identity introduction, for every state of
    /// the five switches `localCapabilities()` reads.
    ///
    /// A state's id is five characters, `1` for on, in the order the function reads the switches: the
    /// away-hearts consent, clothing-shop sharing, the 13+ chat gate, the friend-state opt-in and the
    /// hearts opt-in. `photos` and the host's `wire2` lead; each switched token keeps its place around
    /// `moderation` and `activities`; `hearts` closes.
    ///
    /// The ORDER is a signed wire byte: the coordinator carries the array verbatim into the introduction
    /// and its acknowledgement. `.fernlet`'s declared capability order would reorder every state.
    static let advertisedCapabilityArrays: [(state: String, array: [String])] = [
        ("00000", ["photos", "wire2", "moderation", "activities"]),
        ("00001", ["photos", "wire2", "moderation", "activities", "hearts"]),
        ("00010", ["photos", "wire2", "moderation", "friendState", "activities"]),
        ("00011", ["photos", "wire2", "moderation", "friendState", "activities", "hearts"]),
        ("00100", ["photos", "wire2", "messages", "moderation", "activities"]),
        ("00101", ["photos", "wire2", "messages", "moderation", "activities", "hearts"]),
        ("00110", ["photos", "wire2", "messages", "moderation", "friendState", "activities"]),
        ("00111", ["photos", "wire2", "messages", "moderation", "friendState", "activities", "hearts"]),
        ("01000", ["photos", "wire2", "shop", "moderation", "activities"]),
        ("01001", ["photos", "wire2", "shop", "moderation", "activities", "hearts"]),
        ("01010", ["photos", "wire2", "shop", "moderation", "friendState", "activities"]),
        ("01011", ["photos", "wire2", "shop", "moderation", "friendState", "activities", "hearts"]),
        ("01100", ["photos", "wire2", "shop", "messages", "moderation", "activities"]),
        ("01101", ["photos", "wire2", "shop", "messages", "moderation", "activities", "hearts"]),
        ("01110", ["photos", "wire2", "shop", "messages", "moderation", "friendState", "activities"]),
        ("01111", ["photos", "wire2", "shop", "messages", "moderation", "friendState", "activities", "hearts"]),
        ("10000", ["photos", "wire2", "heartsAway", "moderation", "activities"]),
        ("10001", ["photos", "wire2", "heartsAway", "moderation", "activities", "hearts"]),
        ("10010", ["photos", "wire2", "heartsAway", "moderation", "friendState", "activities"]),
        ("10011", ["photos", "wire2", "heartsAway", "moderation", "friendState", "activities", "hearts"]),
        ("10100", ["photos", "wire2", "heartsAway", "messages", "moderation", "activities"]),
        ("10101", ["photos", "wire2", "heartsAway", "messages", "moderation", "activities", "hearts"]),
        ("10110", ["photos", "wire2", "heartsAway", "messages", "moderation", "friendState", "activities"]),
        ("10111", ["photos", "wire2", "heartsAway", "messages", "moderation", "friendState", "activities",
                   "hearts"]),
        ("11000", ["photos", "wire2", "heartsAway", "shop", "moderation", "activities"]),
        ("11001", ["photos", "wire2", "heartsAway", "shop", "moderation", "activities", "hearts"]),
        ("11010", ["photos", "wire2", "heartsAway", "shop", "moderation", "friendState", "activities"]),
        ("11011", ["photos", "wire2", "heartsAway", "shop", "moderation", "friendState", "activities", "hearts"]),
        ("11100", ["photos", "wire2", "heartsAway", "shop", "messages", "moderation", "activities"]),
        ("11101", ["photos", "wire2", "heartsAway", "shop", "messages", "moderation", "activities", "hearts"]),
        ("11110", ["photos", "wire2", "heartsAway", "shop", "messages", "moderation", "friendState",
                   "activities"]),
        ("11111", ["photos", "wire2", "heartsAway", "shop", "messages", "moderation", "friendState",
                   "activities", "hearts"])
    ]

    /// Each of the 32 states advertises exactly its frozen array, in order. The states are driven on one
    /// store through the app's own wiring of the five switches, and the table holds 32 distinct states.
    @Test func theAdvertisedCapabilityArrayIsFrozenInEveryState() {
        let rows = Self.advertisedCapabilityArrays
        #expect(rows.count == 32 && Set(rows.map(\.state)).count == 32,
                "the capability table holds \(rows.count) states")
        let store = makeTestStore()
        // R2: bounded by the 32 states.
        for row in rows {
            Self.setCapabilitySwitches(row.state, on: store)
            let advertised = Self.advertisedCapabilities(of: store)
            #expect(advertised == row.array, "state \(row.state) advertises \(advertised)")
        }
    }

    /// A fresh install advertises state `01000`'s array: clothing-shop sharing defaults on, the other
    /// three opt-ins default off, and the chat gate stays shut while no age has been determined.
    @Test func aFreshInstallAdvertisesItsFrozenArray() {
        let store = makeTestStore()
        let advertised = Self.advertisedCapabilities(of: store)
        #expect(advertised == Self.frozenCapabilityArray("01000"), "a fresh install advertises \(advertised)")
    }

    // MARK: Group 16 — the routed caps and the bounds built from them

    /// The numbers the three routed rows' caps are built from, each a byte A0.5 moves or re-derives:
    /// - the photo header allowance, 64 KiB, framed with the 8-byte length prefix;
    /// - the text family's 500-character product cap, its 8 000-byte payload bound (16 bytes a
    ///   character), its 1 KiB header allowance framed to 1 032, and its 128-byte name bound;
    /// - the heart family's 512-byte header allowance framed to 520, and its 128-byte name bound;
    /// - the seal's overhead (marker 5 + nonce 12 + tag 16);
    /// - the widest plaintext the seal takes and the widest blob the seal makes, its open takes and the
    ///   delivery projection keeps resident.
    static var routedCapNumbers: [FeatureGoldenNumberRow] {
        [
            FeatureGoldenNumberRow(field: "photo.headerJSONAllowance", frozen: 65_536,
                                   today: MeshRoutedItemBodyFormat.maxHeaderJSONByteCount),
            FeatureGoldenNumberRow(field: "photo.framedHeaderAllowance", frozen: 65_544,
                                   today: MeshRoutedItemBodyFormat.maxFramedHeaderByteCount),
            FeatureGoldenNumberRow(field: "text.maxTextLengthCharacters", frozen: 500,
                                   today: SessionMessageStore.maxTextLength),
            FeatureGoldenNumberRow(field: "text.payloadBound", frozen: 8_000,
                                   today: MeshRoutedTextBody.maxTextUTF8ByteCount),
            FeatureGoldenNumberRow(field: "text.headerJSONAllowance", frozen: 1_024,
                                   today: MeshRoutedItemBodyFormat.maxTextHeaderJSONByteCount),
            FeatureGoldenNumberRow(field: "text.framedHeaderAllowance", frozen: 1_032,
                                   today: MeshRoutedItemBodyFormat.maxFramedTextHeaderByteCount),
            FeatureGoldenNumberRow(field: "text.maxSenderNameUTF8ByteCount", frozen: 128,
                                   today: MeshRoutedTextBody.maxSenderNameUTF8ByteCount),
            FeatureGoldenNumberRow(field: "heart.headerJSONAllowance", frozen: 512,
                                   today: MeshRoutedHeartBody.maxHeaderJSONByteCount),
            FeatureGoldenNumberRow(field: "heart.framedHeaderAllowance", frozen: 520,
                                   today: MeshRoutedHeartBody.maxFramedHeaderByteCount),
            FeatureGoldenNumberRow(field: "heart.maxSenderNameUTF8ByteCount", frozen: 128,
                                   today: MeshRoutedHeartBody.maxSenderNameUTF8ByteCount),
            FeatureGoldenNumberRow(field: "seal.overheadByteCount", frozen: 33,
                                   today: MeshRoutedItemSealFormat.overheadByteCount),
            FeatureGoldenNumberRow(field: "seal.maxPlaintextByteCount", frozen: 10_551_304,
                                   today: Self.sealPlaintextBound),
            FeatureGoldenNumberRow(field: "residentBound", frozen: 10_551_337,
                                   today: Self.residentBlobBound)
        ]
    }

    /// The first plaintext the seal refuses, one byte past `seal.maxPlaintextByteCount`.
    static let firstRefusedPlaintextByteCount = 10_551_305
    /// The first blob the open refuses, one byte past `residentBound`.
    static let firstRefusedBlobByteCount = 10_551_338

    /// Each number is its frozen value, and the table holds thirteen distinct fields.
    @Test func theRoutedCapNumbersAreTheirFrozenBytes() {
        let rows = Self.routedCapNumbers
        #expect(rows.count == 13 && Set(rows.map(\.field)).count == 13, "the number table holds \(rows.count) rows")
        #expect(Self.expectFrozen(rows) == 13)
    }

    /// Each routed row Fernlet registers caps its ciphertext at its payload bound, plus its family's
    /// framed header allowance, plus the seal's overhead:
    /// - the photo row at 10 485 760 + 65 544 + 33 = 10 551 337;
    /// - the text row at 8 000 + 1 032 + 33 = 9 065;
    /// - the heart row at 0 + 520 + 33 = 553 (a header-only body has no payload term).
    ///
    /// The photo payload bound is `MeshRoutedTypeRegistryTests`' pin, read here through its constant. The
    /// three totals are pinned already (`MeshRoutedTypeRegistryTests`, `MeshRoutedTextBodyTests`,
    /// `ProximityVocabularyGoldenTests`). What this holds is that the rows the mesh registers are built
    /// from these terms, and the terms are what A0.5 moves.
    @Test func eachRoutedRowsCapIsItsFrozenTerms() throws {
        let registry = Self.fernletRoutedTypeRegistry
        let overhead = Self.frozenNumber("seal.overheadByteCount")
        let terms: [(sender: String, payload: Int, framedHeader: Int)] = [
            ("photo", Self.photoPayloadBound, Self.frozenNumber("photo.framedHeaderAllowance")),
            ("tempMessage", Self.frozenNumber("text.payloadBound"), Self.frozenNumber("text.framedHeaderAllowance")),
            ("heart", 0, Self.frozenNumber("heart.framedHeaderAllowance"))
        ]
        #expect(registry.tokens.count == terms.count, "the registry holds \(registry.tokens.count) rows")
        // R2: bounded by the three rows.
        for term in terms {
            let token = Self.frozenMintedToken(term.sender)
            let row = try #require(registry.entry(for: token), "the registry has no \(token) row")
            let cap = UInt64(clamping: term.payload + term.framedHeader + overhead)
            #expect(row.maxItemByteCount == cap,
                    "the \(term.sender) row caps at \(row.maxItemByteCount); its terms sum to \(cap)")
        }
    }

    /// The widest routed row Fernlet registers is the photo row, alone. Its cap is the bound the seal,
    /// the open and the delivery projection's resident guard all read: 10 551 337 bytes, the photo
    /// payload bound plus its framed header allowance plus the seal's overhead.
    ///
    /// At the seal's edges: the seal takes a plaintext of exactly 10 551 304 bytes and refuses 10 551 305
    /// by name. The blob it makes measures the bound and opens. The open refuses a blob of 10 551 338 by
    /// name before any key is used.
    ///
    /// Plan step A0.5.4 re-derives this bound as the maximum over the registered rows, so the number
    /// holds only if the rows do.
    @Test func theResidentBoundIsTheWidestRowAndBoundsBothEndsOfTheSeal() throws {
        let registry = Self.fernletRoutedTypeRegistry
        let caps: [(token: String, cap: UInt64)] = registry.tokens.sorted().compactMap { token in
            registry.entry(for: token).map { (token: token, cap: $0.maxItemByteCount) }
        }
        let widestCap = caps.map { $0.cap }.max() ?? 0
        let widest = caps.filter { $0.cap == widestCap }.map { $0.token }
        let bound = Self.frozenNumber("residentBound")
        #expect(widest == [Self.frozenMintedToken("photo")], "the widest rows are \(widest)")
        #expect(widestCap == UInt64(clamping: bound), "the widest row caps at \(widestCap)")
        #expect(Self.photoPayloadBound + Self.frozenNumber("photo.framedHeaderAllowance")
                    + Self.frozenNumber("seal.overheadByteCount") == bound,
                "the photo row's terms do not sum to the resident bound")
        let typeToken = Self.frozenMintedToken("photo")
        let widestPlaintext = Self.frozenNumber("seal.maxPlaintextByteCount")
        try #require(widestPlaintext > 0 && Self.firstRefusedPlaintextByteCount > 0, "the seal bounds are missing")
        let blob = try Self.sealRoutedProbe(Data(repeating: 0x5A, count: widestPlaintext), typeToken: typeToken)
        #expect(blob.count == bound, "the widest plaintext seals to \(blob.count) bytes")
        #expect(try Self.openRoutedProbe(blob, typeToken: typeToken).count == widestPlaintext,
                "the widest blob does not open to the widest plaintext")
        let refusedPlaintext = Self.firstRefusedPlaintextByteCount
        #expect(throws: MeshRoutedItemSealError.plaintextTooLarge(byteCount: refusedPlaintext)) {
            _ = try Self.sealRoutedProbe(Data(repeating: 0x5A, count: refusedPlaintext), typeToken: typeToken)
        }
        let refusedBlob = blob + Data([0x00])
        #expect(refusedBlob.count == Self.firstRefusedBlobByteCount)
        #expect(throws: MeshRoutedItemSealError.blobTooLargeToOpen(byteCount: Self.firstRefusedBlobByteCount)) {
            _ = try Self.openRoutedProbe(refusedBlob, typeToken: typeToken)
        }
    }

    /// The manager holds the resident bound from the rows its host registered, once, at `init`: a
    /// fixture registry handed to it afterwards narrows every door that resolves a token and leaves
    /// the bound at 10 551 337 bytes.
    ///
    /// The fixture is Fernlet's registry without its widest row, the photo row, so its own widest row
    /// is the text row's, far below the bound; the manager stops registering the photo token, so the
    /// fixture took. Plan step A0.5.4 holds the bound from the host registry for exactly this: a bound
    /// read through the fixture would have moved with it.
    @Test func aNarrowedFixtureRegistryLeavesTheResidentBound() {
        let store = makeTestStore()
        let bound = Self.frozenNumber("residentBound")
        let photoToken = Self.frozenMintedToken("photo")
        let narrowed = Self.routedTypes(Self.fernletRoutedTypeRegistry, dropping: photoToken)
        let narrowedWidest = Self.widestRoutedRow(of: narrowed)
        #expect(narrowed.tokens.count == 2, "the fixture holds \(narrowed.tokens.count) rows")
        #expect(narrowedWidest < UInt64(clamping: bound), "the fixture's widest row is \(narrowedWidest) bytes")
        let before = Self.heldResidentBlobBound(of: store)
        #expect(before == bound, "the manager holds \(before)")
        Self.narrowRoutedTypes(of: store, to: narrowed)
        #expect(!Self.registersRoutedType(photoToken, in: store), "the manager still registers the photo row")
        let after = Self.heldResidentBlobBound(of: store)
        #expect(after == bound, "the fixture registry moved the bound to \(after)")
        withExtendedLifetime(store) {}
    }

    // MARK: Group 17 — the tokens the senders mint

    /// The routed-type token each sender mints its item under:
    /// - the photo sender, the friend-photo wall's row;
    /// - the text sender, the session transcript's row;
    /// - the heart sender, the heart ledger's row.
    ///
    /// The token is signed into every manifest the sender stages and bound into the item seal's
    /// authenticated data.
    static let mintedTypeTokens: [(sender: String, token: String)] = [
        ("photo", "fernlet.mesh.routed-type.photo.v1"),
        ("tempMessage", "fernlet.mesh.routed-type.temp-message.v1"),
        ("heart", "fernlet.mesh.routed-type.heart.v1")
    ]

    /// On a founded, chatting pair, one photo, one message and one heart from member 0 each stage exactly
    /// one item of member 0's own. Each is signed under its sender's frozen token and addressed to
    /// member 1.
    ///
    /// A staged item also shows that each sender's audience fits its row: the origination door refuses a
    /// full-roster audience on a single-recipient row, and the reverse, so a sender wired to the wrong
    /// row stages nothing. On a pair the two audiences address the same one member; a roster of three
    /// would tell them apart.
    @Test func theThreeSendersMintUnderTheirFrozenTokens() async throws {
        let rig = try MeshFoundingRig.build(2, label: "ffgt-mint")
        defer { rig.teardown() }
        try await rig.settleChattingPair()
        Self.armHearts(at: 0, in: rig)
        let recipient = rig.nodes[1].fingerprint
        var minted: [String: MeshRoutedManifest] = [:]
        // R2: bounded by the three senders.
        for row in Self.mintedTypeTokens {
            let before = Set(Self.ownStagedManifests(at: 0, in: rig).map(\.itemID))
            Self.mint(row.sender, from: 0, to: 1, in: rig)
            let staged = Self.ownStagedManifests(at: 0, in: rig).filter { !before.contains($0.itemID) }
            #expect(staged.count == 1, "the \(row.sender) sender staged \(staged.count) items")
            minted[row.sender] = staged.first
        }
        // R2: bounded by the three senders.
        for row in Self.mintedTypeTokens {
            let manifest = try #require(minted[row.sender], "the \(row.sender) sender staged nothing")
            #expect(manifest.typeToken == row.token, "the \(row.sender) sender minted under \(manifest.typeToken)")
            #expect(manifest.destinations == [recipient],
                    "the \(row.sender) item is addressed to \(manifest.destinations)")
        }
    }

    // MARK: Group 18 — the routed item bodies

    /// The routed item id: the routed suites' fixture item (`MeshRoutedManifestFixtures.itemID`), which
    /// both pinned body vectors carry.
    static var routedItemID: UUID { uuid("5A5A5A5A-6B6B-4C4C-8D8D-3E3E3E3E3E3E") }

    /// The heart bodies' day key, the `yyyy-MM-dd` that `HeartPayload` requires:
    /// `MeshRoutedHeartBodyTests`' own.
    static let routedHeartDayKey = "2026-09-11"

    /// A sender name that exercises each string rule the routed header coder applies: a `/` it writes
    /// raw, two `"` it escapes, and U+00E9 it writes as its two UTF-8 bytes.
    static let routedEscapedName = "a/b \"q\" \u{E9}"

    /// Two routed heart bodies for ``routedItemID`` on ``routedHeartDayKey``: `Fixture Origin`'s and
    /// ``routedEscapedName``'s. Each is the header's JSON (keys `id`, `senderName` and `sentAtDayKey`,
    /// sorted, no whitespace, the id upper-case) after its u64 big-endian length (103 and 101), with
    /// nothing after it. 111 and 109 bytes.
    static var routedHeartBodies: [(senderName: String, json: String, hex: String, count: Int)] {
        [
            ("Fixture Origin",
             #"{"id":"5A5A5A5A-6B6B-4C4C-8D8D-3E3E3E3E3E3E","senderName":"Fixture Origin","sentAtDayKey":"2026-09-11"}"#,
             [
                 "00000000000000677b226964223a2235413541354135412d364236422d344334432d384438442d334533453345334533",
                 "453345222c2273656e6465724e616d65223a2246697874757265204f726967696e222c2273656e7441744461794b6579",
                 "223a22323032362d30392d3131227d"
             ].joined(), 111),
            (routedEscapedName,
             #"{"id":"5A5A5A5A-6B6B-4C4C-8D8D-3E3E3E3E3E3E","senderName":"a/b \"q\" \#u{E9}","sentAtDayKey":"2026-09-11"}"#,
             [
                 "00000000000000657b226964223a2235413541354135412d364236422d344334432d384438442d334533453345334533",
                 "453345222c2273656e6465724e616d65223a22612f62205c22715c2220c3a9222c2273656e7441744461794b6579223a",
                 "22323032362d30392d3131227d"
             ].joined(), 109)
        ]
    }

    /// Production frames each routed heart body as its frozen bytes. Those bytes are its frozen JSON
    /// after its length and nothing more, and they decode back to the routed item id, the day and the
    /// name. No other suite pins a heart body's bytes: `MeshRoutedHeartBodyTests` round-trips one and
    /// refuses its hostile shapes. The escaped name's row is insurance. Today the heart family writes its
    /// header through the coder it shares with the text family, whose escaping this group's text cell
    /// pins.
    @Test func eachRoutedHeartBodyEncodesToItsFrozenBytesAndBack() throws {
        let bodies = Self.routedHeartBodies
        #expect(bodies.count == 2, "the heart table holds \(bodies.count) bodies")
        // R2: bounded by the two bodies.
        for frozen in bodies {
            let bytes = Self.bytes(fromHex: frozen.hex)
            #expect(bytes.count == frozen.count, "\(frozen.senderName)'s frozen heart body holds \(bytes.count) bytes")
            #expect(bytes == Self.framedBody(header: Data(frozen.json.utf8)),
                    "\(frozen.senderName)'s frozen hex is not its frozen JSON after its length")
            let encoded = try Self.routedHeartBody(
                id: Self.routedItemID, sentAtDayKey: Self.routedHeartDayKey, senderName: frozen.senderName)
            #expect(Self.hex(encoded) == frozen.hex, "\(frozen.senderName)'s heart body is \(Self.hex(encoded))")
            let decoded = try Self.decodedRoutedHeartBody(bytes)
            #expect(decoded.id == Self.routedItemID && decoded.sentAtDayKey == Self.routedHeartDayKey
                        && decoded.senderName == frozen.senderName,
                    "\(frozen.senderName)'s frozen heart body decodes to \(decoded)")
        }
    }

    /// A routed text body under ``routedEscapedName``, sent half a second past the pinned text body's
    /// instant: the header's JSON (keys `id`, `senderName` and `sentAt`, sorted, no whitespace, `sentAt`
    /// as seconds since 1970 with its fraction) after its u64 big-endian length (95), then
    /// ``routedText``'s UTF-8, raw. 119 bytes.
    static let routedTextBodyHex = [
        "000000000000005f7b226964223a2235413541354135412d364236422d344334432d384438442d334533453345334533",
        "453345222c2273656e6465724e616d65223a22612f62205c22715c2220c3a9222c2273656e744174223a313730303030",
        "303438302e357d68656c6c6f20746865726520f09f918b"
    ].joined()

    /// The text body's header as text: the frozen hex's bytes after its length and before the text.
    static let routedTextHeaderJSON =
        #"{"id":"5A5A5A5A-6B6B-4C4C-8D8D-3E3E3E3E3E3E","senderName":"a/b \"q\" \#u{E9}","sentAt":1700000480.5}"#

    /// The text body's message, multi-byte so that the raw UTF-8 half is pinned:
    /// `MeshRoutedTextBodyTests`' own.
    static let routedText = "hello there \u{1F44B}"

    /// When the text body was sent: 1 700 000 480.5 s after 1970 (721 693 280.5 s after the reference
    /// date). The sender's `Date()` stamps a shipping message with a fraction of a second like this one.
    static var routedTextSentAt: Date { Date(timeIntervalSince1970: 1_700_000_480.5) }

    /// Production frames the text body as its frozen bytes. Those bytes are its frozen JSON after its
    /// length, then its text, and they decode back to the routed item id, the instant with its half
    /// second, the name and the text. `MeshRoutedTextBodyTests` pins a text body with a whole-second date
    /// and an ASCII name. This one adds a fraction, which `.secondsSince1970` keeps rather than floors; a
    /// `/` left raw; an escaped quote; and a non-ASCII letter written as UTF-8.
    @Test func theRoutedTextBodyEncodesToItsFrozenBytesAndBack() throws {
        let bytes = Self.bytes(fromHex: Self.routedTextBodyHex)
        #expect(bytes.count == 119, "the frozen text body holds \(bytes.count) bytes")
        #expect(bytes == Self.framedBody(header: Data(Self.routedTextHeaderJSON.utf8), payload: Data(Self.routedText.utf8)),
                "the frozen hex is not the frozen JSON after its length, then the text")
        let encoded = try Self.routedTextBody(
            id: Self.routedItemID, sentAt: Self.routedTextSentAt, senderName: Self.routedEscapedName, text: Self.routedText)
        #expect(Self.hex(encoded) == Self.routedTextBodyHex, "the text body is \(Self.hex(encoded))")
        let decoded = try Self.decodedRoutedTextBody(bytes)
        #expect(decoded.id == Self.routedItemID && decoded.senderName == Self.routedEscapedName
                    && decoded.text == Self.routedText, "the frozen text body decodes to \(decoded)")
        #expect(decoded.sentAt.timeIntervalSince1970 == 1_700_000_480.5,
                "the frozen text body's instant decodes to \(decoded.sentAt.timeIntervalSince1970) s after 1970")
    }

    // MARK: Group 19 — the canonical signing transcripts

    /// The four labels the activity and moderation transcripts open with, each as the prefix its
    /// `.lengthPrefixed` framing requires: the count, then the spelling. The spellings alone are
    /// `CryptographicPurposeBoundaryTests`'.
    static var transcriptLabelRows: [FeatureGoldenTranscriptLabelRow] {
        [
            FeatureGoldenTranscriptLabelRow(
                field: "Signature.activityDescriptorV2",
                frozenPrefix: "0000000000000028"
                    + "6665726e6c65742e63616e6f6e6963616c2e61637469766974792d64657363726970746f722e7632",
                today: FernletCryptoPurpose.Signature.activityDescriptorV2),
            FeatureGoldenTranscriptLabelRow(
                field: "Signature.activityJoinTokenV2",
                frozenPrefix: "0000000000000028"
                    + "6665726e6c65742e63616e6f6e6963616c2e61637469766974792d6a6f696e2d746f6b656e2e7632",
                today: FernletCryptoPurpose.Signature.activityJoinTokenV2),
            FeatureGoldenTranscriptLabelRow(
                field: "Signature.activityRosterSnapshotV2",
                frozenPrefix: "000000000000002d"
                    + "6665726e6c65742e63616e6f6e6963616c2e61637469766974792d726f737465722d736e617073686f742e7632",
                today: FernletCryptoPurpose.Signature.activityRosterSnapshotV2),
            FeatureGoldenTranscriptLabelRow(
                field: "Signature.moderationReportV2",
                frozenPrefix: "0000000000000026"
                    + "6665726e6c65742e63616e6f6e6963616c2e6d6f6465726174696f6e2d7265706f72742e7632",
                today: FernletCryptoPurpose.Signature.moderationReportV2)
        ]
    }

    /// Each label is a length-prefixed field. Its purpose hands CryptoKit a transcript that is exactly
    /// the frozen prefix, unmodified. It refuses its own raw spelling, which only a positional check can.
    /// Each frozen transcript below begins with its own label's prefix and no other's, so `signingBytes`
    /// passes it on unchanged under its label and refuses it under the other three. The bytes CryptoKit
    /// signs and verifies are the transcript itself.
    @Test func theFourTranscriptLabelsAreLengthPrefixedFields() {
        let rows = Self.transcriptLabelRows
        #expect(rows.count == 4 && Set(rows.map(\.field)).count == 4, "the transcript label table holds \(rows.count) rows")
        // R2: bounded by the four rows.
        for row in rows {
            let prefix = Self.bytes(fromHex: row.frozenPrefix)
            #expect(row.today.signingBytes(prefix) == prefix, "\(row.field) refuses its frozen prefix \(row.frozenPrefix)")
            #expect(row.today.signingBytes(row.today.data) == nil, "\(row.field) accepts its raw spelling")
            #expect(Self.hex(row.today.data) == Self.hex(Data(prefix.dropFirst(8))),
                    "\(row.field) spells \(Self.hex(row.today.data))")
        }
        let transcripts = [
            ("Signature.activityDescriptorV2", Self.descriptorD1Hex), ("Signature.activityJoinTokenV2", Self.joinTokenHex),
            ("Signature.activityRosterSnapshotV2", Self.rosterR2Hex), ("Signature.moderationReportV2", Self.moderationReportHex)
        ]
        // R2: bounded by four transcripts times four rows.
        for (field, frozen) in transcripts {
            let transcript = Self.bytes(fromHex: frozen)
            for row in rows {
                let handed = row.today.signingBytes(transcript)
                #expect(handed == (row.field == field ? transcript : nil),
                        "\(row.field) hands CryptoKit \(handed.map { Self.hex($0) } ?? "nothing") for \(field)'s transcript")
            }
        }
    }

    /// D1's canonical bytes, one field per line:
    /// - the label, then the activity id;
    /// - alice's fingerprint and signing key;
    /// - `Sunset walk` and `walk`;
    /// - `Portland`, present;
    /// - the two dates as whole seconds since 1970, 1 758 307 200 and 1 758 310 800.
    ///
    /// 192 bytes.
    static let descriptorD1Hex = [
        "00000000000000286665726e6c65742e63616e6f6e6963616c2e61637469766974792d64657363726970746f722e7632",
        "a1b2c3d4e5f64a7b8c9d0e1f2a3b4c5d",
        "000000000000001063393435636266326135363032303032",
        "0000000000000020e7f162a10bec559afea195e4dce84b69568d5d2cb0963eb446c0685e2b17f2f0",
        "000000000000000b53756e7365742077616c6b",
        "000000000000000477616c6b",
        "010000000000000008506f72746c616e64",
        "0000000068cda380",
        "0000000068cdb190"
    ].joined()

    /// D1's params hash, SHA-256 over its canonical bytes: the hash the join token binds.
    static let descriptorD1ParamsHashHex = "1173bc09e8ecfba9b4f27c523f8246c38be3103f489311e93afae0a19dcf3cc3"

    /// D2's canonical bytes. The title is 15 UTF-8 bytes. The absent location is one `00`. The dates
    /// 780 000 000.75 and 780 003 599.5 are floored, not rounded, to 1 758 307 200 and 1 758 310 799.
    /// 182 bytes.
    static let descriptorD2Hex = [
        "00000000000000286665726e6c65742e63616e6f6e6963616c2e61637469766974792d64657363726970746f722e7632",
        "a1b2c3d4e5f64a7b8c9d0e1f2a3b4c5d",
        "000000000000001063393435636266326135363032303032",
        "0000000000000020e7f162a10bec559afea195e4dce84b69568d5d2cb0963eb446c0685e2b17f2f0",
        "000000000000000f436166c3a920637261776c20e29895",
        "0000000000000006636f66666565",
        "00",
        "0000000068cda380",
        "0000000068cdb18f"
    ].joined()

    /// D2's params hash.
    static let descriptorD2ParamsHashHex = "02cd465ad31e820c881293da2e7224471d777595f3a9b0cbdf7c406707713e6f"

    /// D3's canonical bytes: D1's fields with hostile dates.
    /// - 1.25 s before 1970 floors to -2, where truncation would give -1.
    /// - 1e19 s after 2001 is past `Int64.max` seconds and saturates.
    ///
    /// 192 bytes.
    static let descriptorD3Hex = [
        "00000000000000286665726e6c65742e63616e6f6e6963616c2e61637469766974792d64657363726970746f722e7632",
        "a1b2c3d4e5f64a7b8c9d0e1f2a3b4c5d",
        "000000000000001063393435636266326135363032303032",
        "0000000000000020e7f162a10bec559afea195e4dce84b69568d5d2cb0963eb446c0685e2b17f2f0",
        "000000000000000b53756e7365742077616c6b",
        "000000000000000477616c6b",
        "010000000000000008506f72746c616e64",
        "fffffffffffffffe",
        "7fffffffffffffff"
    ].joined()

    /// D3's params hash.
    static let descriptorD3ParamsHashHex = "8bffe91910b24d8f8b611e90c840dd089eab7fc83f909a122ea83485e972cfed"

    /// D4's canonical bytes: D1's fields with more hostile dates.
    /// - -1e19 s saturates to `Int64.min`.
    /// - An infinite expiry is written as 0, not `Int64.max`, because it is not finite.
    ///
    /// 192 bytes.
    static let descriptorD4Hex = [
        "00000000000000286665726e6c65742e63616e6f6e6963616c2e61637469766974792d64657363726970746f722e7632",
        "a1b2c3d4e5f64a7b8c9d0e1f2a3b4c5d",
        "000000000000001063393435636266326135363032303032",
        "0000000000000020e7f162a10bec559afea195e4dce84b69568d5d2cb0963eb446c0685e2b17f2f0",
        "000000000000000b53756e7365742077616c6b",
        "000000000000000477616c6b",
        "010000000000000008506f72746c616e64",
        "8000000000000000",
        "0000000000000000"
    ].joined()

    /// D4's params hash.
    static let descriptorD4ParamsHashHex = "367485178f7a40c204370525ce2915285e8321a91550c0603fd5780ed89f0f10"

    /// The four descriptors of alice's activity, each with its frozen canonical bytes and params hash.
    static var descriptorCases: [(name: String, descriptor: ActivityDescriptor, transcript: String, hash: String)] {
        [
            ("D1", descriptorD1, descriptorD1Hex, descriptorD1ParamsHashHex),
            ("D2", descriptorD2, descriptorD2Hex, descriptorD2ParamsHashHex),
            ("D3", aliceActivity(title: "Sunset walk", type: "walk", location: "Portland",
                                 created: -978_307_201.25, expires: 1e19), descriptorD3Hex, descriptorD3ParamsHashHex),
            ("D4", aliceActivity(title: "Sunset walk", type: "walk", location: "Portland",
                                 created: -1e19, expires: .infinity), descriptorD4Hex, descriptorD4ParamsHashHex)
        ]
    }

    /// Each descriptor's canonical bytes and params hash are their known answers, and each frozen hash is
    /// SHA-256 over the frozen bytes. A descriptor is never signed: its hash is what the signed token
    /// binds, so a drift here refuses every grant across builds.
    @Test func theActivityDescriptorsHashToTheirKnownAnswers() {
        // R2: bounded by the four descriptors.
        for frozen in Self.descriptorCases {
            let transcript = Self.descriptorTranscript(frozen.descriptor)
            #expect(Self.hex(transcript) == frozen.transcript, "\(frozen.name)'s canonical bytes are \(Self.hex(transcript))")
            let hash = Self.paramsHash(of: frozen.descriptor)
            #expect(Self.hex(hash) == frozen.hash, "\(frozen.name)'s params hash is \(Self.hex(hash))")
            let digest = Data(SHA256.hash(data: Self.bytes(fromHex: frozen.transcript)))
            #expect(Self.hex(digest) == frozen.hash, "\(frozen.name)'s frozen bytes hash to \(Self.hex(digest))")
        }
    }

    /// J1's canonical bytes:
    /// - the label and schema version 1;
    /// - the activity id and D1's params hash;
    /// - bob's fingerprint and signing key, then alice's;
    /// - granted at 1 758 307 800 and expiring at D1's 1 758 310 800 s since 1970;
    /// - roster version 2.
    ///
    /// 264 bytes.
    static let joinTokenHex = [
        "00000000000000286665726e6c65742e63616e6f6e6963616c2e61637469766974792d6a6f696e2d746f6b656e2e7632",
        "0000000000000001",
        "a1b2c3d4e5f64a7b8c9d0e1f2a3b4c5d",
        "00000000000000201173bc09e8ecfba9b4f27c523f8246c38be3103f489311e93afae0a19dcf3cc3",
        "000000000000001062346362346239336334303237636533",
        "0000000000000020882d0ea3b2864e7a587f3e698cea4459998312e655e05fa5e8b5119d8baac8cd",
        "000000000000001063393435636266326135363032303032",
        "0000000000000020e7f162a10bec559afea195e4dce84b69568d5d2cb0963eb446c0685e2b17f2f0",
        "0000000068cda5d8",
        "0000000068cdb190",
        "0000000000000002"
    ].joined()

    /// alice's RFC 8032 signature over ``joinTokenHex``, R then S.
    static let joinTokenSignatureHex = [
        "3692a1b649477989399cfadbd98dabb686f258ea26cb5866806723113ed52eff",
        "cb5a89b2c62d7685dc864f6def7fb52997518383d5bb06a4d1b35d15e1673f00"
    ].joined()

    /// ``joinTokenSignatureHex`` with its first byte XORed with 0x01.
    static let joinTokenFlippedSignatureHex = [
        "3792a1b649477989399cfadbd98dabb686f258ea26cb5866806723113ed52eff",
        "cb5a89b2c62d7685dc864f6def7fb52997518383d5bb06a4d1b35d15e1673f00"
    ].joined()

    /// J1's canonical bytes are their known answer. Production's verify, run as bob runs it, accepts the
    /// frozen signature. It refuses the flipped twin as `.signatureInvalid`, every guard before the
    /// signature having passed.
    @Test func theJoinTokenIsItsKnownAnswerAndVerifiesItsFrozenSignature() {
        let token = Self.joinToken(signature: Self.bytes(fromHex: Self.joinTokenSignatureHex))
        let transcript = Self.joinTokenTranscript(token)
        #expect(Self.hex(transcript) == Self.joinTokenHex, "J1's canonical bytes are \(Self.hex(transcript))")
        #expect(throws: Never.self) { try Self.verifyJoinTokenAsBob(token) }
        let flipped = Self.joinToken(signature: Self.bytes(fromHex: Self.joinTokenFlippedSignatureHex))
        #expect(throws: JoinTokenRefusal.signatureInvalid) { try Self.verifyJoinTokenAsBob(flipped) }
    }

    /// R2's canonical bytes:
    /// - the label, schema version 1, the activity id, version 2 and two members;
    /// - alice: her fingerprint, `Alice`, both her keys, joined 1 758 307 200;
    /// - bob: his fingerprint, `B\u{F8}b \u{1F33F}` as 9 UTF-8 bytes, both his keys, joined 780 000 600.5
    ///   s after 2001, floored to 1 758 307 800;
    /// - issued at 1 758 307 860, then alice's key as host key.
    ///
    /// 395 bytes.
    static let rosterR2Hex = [
        "000000000000002d6665726e6c65742e63616e6f6e6963616c2e61637469766974792d726f737465722d736e617073686f742e7632",
        "0000000000000001",
        "a1b2c3d4e5f64a7b8c9d0e1f2a3b4c5d",
        "0000000000000002",
        "0000000000000002",
        "000000000000001063393435636266326135363032303032",
        "0000000000000005416c696365",
        "0000000000000020e7f162a10bec559afea195e4dce84b69568d5d2cb0963eb446c0685e2b17f2f0",
        "000000000000002007a37cbc142093c8b755dc1b10e86cb426374ad16aa853ed0bdfc0b2b86d1c7c",
        "0000000068cda380",
        "000000000000001062346362346239336334303237636533",
        "000000000000000942c3b86220f09f8cbf",
        "0000000000000020882d0ea3b2864e7a587f3e698cea4459998312e655e05fa5e8b5119d8baac8cd",
        "000000000000002064b101b1d0be5a8704bd078f9895001fc03e8e9f9522f188dd128d9846d48466",
        "0000000068cda5d8",
        "0000000068cda614",
        "0000000000000020e7f162a10bec559afea195e4dce84b69568d5d2cb0963eb446c0685e2b17f2f0"
    ].joined()

    /// alice's RFC 8032 signature over ``rosterR2Hex``, R then S.
    static let rosterR2SignatureHex = [
        "cc04b68891f2e6c13e2ae33818483767f527ae30169315c86683130715a6441b",
        "627caad949b65932f4f9cdfe2cd10e7f5057256835841083ac53d3cf15d1dc07"
    ].joined()

    /// ``rosterR2SignatureHex`` with its first byte XORed with 0x01.
    static let rosterR2FlippedSignatureHex = [
        "cd04b68891f2e6c13e2ae33818483767f527ae30169315c86683130715a6441b",
        "627caad949b65932f4f9cdfe2cd10e7f5057256835841083ac53d3cf15d1dc07"
    ].joined()

    /// R2's canonical bytes are their known answer, members in the host's order. Production's verify,
    /// pinned to alice's key, accepts the frozen signature and refuses its flipped twin as
    /// `.signatureInvalid`.
    @Test func theRosterSnapshotIsItsKnownAnswerAndVerifiesItsFrozenSignature() {
        let snapshot = Self.roster(version: 2, members: Self.rosterMembers(2), issuedAt: 780_000_660,
                                   signature: Self.bytes(fromHex: Self.rosterR2SignatureHex))
        let transcript = Self.rosterTranscript(snapshot)
        #expect(Self.hex(transcript) == Self.rosterR2Hex, "R2's canonical bytes are \(Self.hex(transcript))")
        #expect(throws: Never.self) {
            try Self.verifyRoster(snapshot, activityID: Self.activityID, hostKey: Self.aliceSigningPub)
        }
        let flipped = Self.roster(version: 2, members: Self.rosterMembers(2), issuedAt: 780_000_660,
                                  signature: Self.bytes(fromHex: Self.rosterR2FlippedSignatureHex))
        #expect(throws: RosterRefusal.signatureInvalid) {
            try Self.verifyRoster(flipped, activityID: Self.activityID, hostKey: Self.aliceSigningPub)
        }
    }

    /// R12's canonical bytes, version 12, alice, bob and guests 3 to 12, issued 780 001 200 s after 2001:
    /// their length and SHA-256. R2 pins the layout in full.
    static let rosterR12Length = 1668

    /// SHA-256 over R12's canonical bytes.
    static let rosterR12SHA256Hex = "da82348440176270a5c4e3004571abc873b498ff392c8a758305611573064c6d"

    /// alice's RFC 8032 signature over R12's canonical bytes, R then S.
    static let rosterR12SignatureHex = [
        "aec8aaddd12230c82cbf65947747ea164d49aea3c5015cc694b4092a39739b7b",
        "9437564267630d3a20d63bad2710db8cec46cc9a8e11186216a5a265235bb804"
    ].joined()

    /// R13's canonical bytes, version 13, R12's twelve members and guest 13: their length.
    static let rosterR13Length = 1796

    /// SHA-256 over R13's canonical bytes.
    static let rosterR13SHA256Hex = "732bd2bc6d405e7c604d0f4c60386c7c171851217d7c9f8338b64fd50b792586"

    /// alice's RFC 8032 signature over R13's canonical bytes, R then S: valid, yet production refuses
    /// R13.
    static let rosterR13SignatureHex = [
        "e7f496b9d86268daa8afed17176823a9abd81d9ac2bd6240360a7de38955d0a4",
        "92b99d91a2c85c17a510ef08b91c888f96c0ec519f79e52765cff59c97a75703"
    ].joined()

    /// The roster cap is twelve members, the host included. R12 verifies. R13 is refused as
    /// `.rosterTooLarge` although its frozen signature is valid over its canonical bytes, because the cap
    /// runs before the members' bounds and the signature.
    @Test func theRosterCapVerifiesTwelveMembersAndRefusesThirteen() throws {
        let label = try #require(Self.todayLabel("Signature.activityRosterSnapshotV2"), "the table holds no roster label")
        let twelve = Self.roster(version: 12, members: Self.rosterMembers(12), issuedAt: 780_001_200,
                                 signature: Self.bytes(fromHex: Self.rosterR12SignatureHex))
        let thirteen = Self.roster(version: 13, members: Self.rosterMembers(13), issuedAt: 780_001_200,
                                   signature: Self.bytes(fromHex: Self.rosterR13SignatureHex))
        let cases = [("R12", twelve, Self.rosterR12Length, Self.rosterR12SHA256Hex),
                     ("R13", thirteen, Self.rosterR13Length, Self.rosterR13SHA256Hex)]
        // R2: bounded by the two rosters.
        for (name, snapshot, length, digest) in cases {
            let transcript = Self.rosterTranscript(snapshot)
            let actual = Self.hex(Data(SHA256.hash(data: transcript)))
            #expect(transcript.count == length && actual == digest,
                    "\(name)'s canonical bytes are \(transcript.count) bytes hashing to \(actual)")
            #expect(Self.verifies(snapshot.hostSignature, over: transcript, by: Self.aliceSigningPub, under: label),
                    "\(name)'s frozen signature does not verify over its canonical bytes")
        }
        #expect(throws: Never.self) {
            try Self.verifyRoster(twelve, activityID: Self.activityID, hostKey: Self.aliceSigningPub)
        }
        #expect(throws: RosterRefusal.rosterTooLarge) {
            try Self.verifyRoster(thirteen, activityID: Self.activityID, hostKey: Self.aliceSigningPub)
        }
    }

    /// M1's canonical bytes, group 10's row field by field:
    /// - the label and `report`;
    /// - alice's key as reporter, then bob's as subject;
    /// - the item id and the content hash `abcd`;
    /// - `offensive`, sequence 1, created 1 758 307 200.
    ///
    /// 199 bytes.
    static let moderationReportHex = [
        "00000000000000266665726e6c65742e63616e6f6e6963616c2e6d6f6465726174696f6e2d7265706f72742e7632",
        "00000000000000067265706f7274",
        "0000000000000020e7f162a10bec559afea195e4dce84b69568d5d2cb0963eb446c0685e2b17f2f0",
        "0000000000000020882d0ea3b2864e7a587f3e698cea4459998312e655e05fa5e8b5119d8baac8cd",
        "d1e2f3a4b5c64d7e8f90a1b2c3d4e5f6",
        "0000000000000002abcd",
        "00000000000000096f6666656e73697665",
        "0000000000000001",
        "0000000068cda380"
    ].joined()

    /// alice's RFC 8032 signature over ``moderationReportHex``, R then S.
    static let moderationReportSignatureHex = [
        "d30d5510a80f73613df7cf9bab06b0a75f3a00afa737791cda06279ffa5b1769",
        "3ab0cb17190fd817b9ae562033589de723d4e2da7971e32b7403aecd76800f03"
    ].joined()

    /// ``moderationReportSignatureHex`` with its first byte XORed with 0x01.
    static let moderationReportFlippedSignatureHex = [
        "d20d5510a80f73613df7cf9bab06b0a75f3a00afa737791cda06279ffa5b1769",
        "3ab0cb17190fd817b9ae562033589de723d4e2da7971e32b7403aecd76800f03"
    ].joined()

    /// M2's canonical bytes: alice's retraction of M1, `retract`, sequence 2, created 780 003 600.75 s
    /// after 2001, floored to 1 758 310 800. 200 bytes.
    static let moderationRetractHex = [
        "00000000000000266665726e6c65742e63616e6f6e6963616c2e6d6f6465726174696f6e2d7265706f72742e7632",
        "000000000000000772657472616374",
        "0000000000000020e7f162a10bec559afea195e4dce84b69568d5d2cb0963eb446c0685e2b17f2f0",
        "0000000000000020882d0ea3b2864e7a587f3e698cea4459998312e655e05fa5e8b5119d8baac8cd",
        "d1e2f3a4b5c64d7e8f90a1b2c3d4e5f6",
        "0000000000000002abcd",
        "00000000000000096f6666656e73697665",
        "0000000000000002",
        "0000000068cdb190"
    ].joined()

    /// alice's RFC 8032 signature over ``moderationRetractHex``, R then S.
    static let moderationRetractSignatureHex = [
        "5b90f5ba86ced58053e1a4c6e510d46e7d284f12e5479ea66fa0d46c937a0ba6",
        "8a908c91474d0db6af4782d51e558002d2b06d0086eeafff622cb1fb4f21db0f"
    ].joined()

    /// The two rows' canonical bytes are their known answers. The relay, handed alice's payload by alice
    /// an hour after the retraction:
    /// - keeps both rows exactly: each id re-derived to the one it carries, neither date clamped;
    /// - keeps only the retraction once the report's signature is flipped;
    /// - keeps nothing alice signed when bob is the sender.
    @Test func theModerationRowsAreTheirKnownAnswersAndTheRelayKeepsTheirFrozenSignatures() {
        let report = Self.moderationReport
        let retract = Self.moderationRetract
        // R2: bounded by the two rows.
        for (name, row, frozen) in [("the report", report, Self.moderationReportHex),
                                    ("the retraction", retract, Self.moderationRetractHex)] {
            let actual = Self.hex(Self.moderationTranscript(row))
            #expect(actual == frozen, "\(name)'s canonical bytes are \(actual)")
        }
        let signedReport = SignedReport(entry: report, signature: Self.bytes(fromHex: Self.moderationReportSignatureHex))
        let signedRetract = SignedReport(entry: retract, signature: Self.bytes(fromHex: Self.moderationRetractSignatureHex))
        let flippedReport = SignedReport(entry: report, signature: Self.bytes(fromHex: Self.moderationReportFlippedSignatureHex))
        let now = Date(timeIntervalSinceReferenceDate: 780_007_200)
        let kept = Self.relayedRows([signedReport, signedRetract], sender: Self.aliceSigningPub, now: now)
        #expect(kept == [report, retract], "the relay kept \(kept)")
        let afterFlip = Self.relayedRows([flippedReport, signedRetract], sender: Self.aliceSigningPub, now: now)
        #expect(afterFlip == [retract], "with the report's signature flipped the relay kept \(afterFlip)")
        let fromBob = Self.relayedRows([signedReport, signedRetract], sender: Self.bobSigningPub, now: now)
        #expect(fromBob.isEmpty, "the relay kept rows alice signed from bob: \(fromBob)")
    }

    /// Each frozen signature verifies over its frozen transcript by alice's key under its own label and
    /// under neither other signature label: the bytes `signingBytes` hands CryptoKit are the transcript
    /// itself. Each flipped twin verifies under none.
    @Test func theFrozenSignaturesVerifyUnderTheirOwnLabelOnly() {
        let signed: [(field: String, transcript: String, signature: String, flipped: String?)] = [
            ("Signature.activityJoinTokenV2", Self.joinTokenHex, Self.joinTokenSignatureHex,
             Self.joinTokenFlippedSignatureHex),
            ("Signature.activityRosterSnapshotV2", Self.rosterR2Hex, Self.rosterR2SignatureHex,
             Self.rosterR2FlippedSignatureHex),
            ("Signature.moderationReportV2", Self.moderationReportHex, Self.moderationReportSignatureHex,
             Self.moderationReportFlippedSignatureHex),
            ("Signature.moderationReportV2", Self.moderationRetractHex, Self.moderationRetractSignatureHex, nil)
        ]
        let labels = Self.transcriptLabelRows.filter { $0.field != "Signature.activityDescriptorV2" }
        #expect(labels.count == 3, "the table holds \(labels.count) signature labels")
        // R2: bounded by four signatures times three labels.
        for frozen in signed {
            let transcript = Self.bytes(fromHex: frozen.transcript)
            for row in labels {
                let verified = Self.verifies(Self.bytes(fromHex: frozen.signature), over: transcript,
                                             by: Self.aliceSigningPub, under: row.today)
                #expect(verified == (row.field == frozen.field),
                        "\(frozen.field)'s frozen signature verifies \(verified) under \(row.field)")
                guard let flipped = frozen.flipped else { continue }
                #expect(!Self.verifies(Self.bytes(fromHex: flipped), over: transcript, by: Self.aliceSigningPub,
                                       under: row.today), "\(frozen.field)'s flipped signature verifies under \(row.field)")
            }
        }
    }

    /// Over planted alice, each signer writes the frozen transcript and a signature production accepts:
    /// - the join token's signer fills the host's fingerprint and key from the identity;
    /// - the roster's signer fills the host's key;
    /// - the relay's payload builder keeps and signs both of alice's rows.
    ///
    /// CryptoKit signs with fresh randomness, so these signatures are verified, never compared.
    @Test func theFeatureSignersWriteTheFrozenTranscripts() throws {
        let service = Self.throwawayService()
        defer { Self.sweep([service]) }
        let alice = try Self.plantedAlice(service: service)
        let token = try Self.signedJoinToken(
            activityID: Self.activityID, paramsHash: Self.bytes(fromHex: Self.descriptorD1ParamsHashHex),
            joinerFingerprint: Self.bobFingerprint, joinerKey: Self.bobSigningPub, host: alice,
            grantedAt: Date(timeIntervalSinceReferenceDate: 780_000_600),
            expiresAt: Date(timeIntervalSinceReferenceDate: 780_003_600), rosterVersion: 2)
        let tokenBytes = Self.hex(Self.joinTokenTranscript(token))
        #expect(tokenBytes == Self.joinTokenHex, "the signed token's canonical bytes are \(tokenBytes)")
        #expect(throws: Never.self) { try Self.verifyJoinTokenAsBob(token) }
        let snapshot = try Self.signedRoster(
            activityID: Self.activityID, version: 2, participants: Self.rosterMembers(2),
            issuedAt: Date(timeIntervalSinceReferenceDate: 780_000_660), host: alice)
        let rosterBytes = Self.hex(Self.rosterTranscript(snapshot))
        #expect(rosterBytes == Self.rosterR2Hex, "the signed roster's canonical bytes are \(rosterBytes)")
        #expect(throws: Never.self) {
            try Self.verifyRoster(snapshot, activityID: Self.activityID, hostKey: Self.aliceSigningPub)
        }
        let rows = [Self.moderationReport, Self.moderationRetract]
        let signed = Self.signedReportBundle(of: rows, by: alice).reports
        #expect(signed.map(\.entry) == rows, "the built payload carries \(signed.map(\.entry))")
        let kept = Self.relayedRows(signed, sender: Self.aliceSigningPub, now: Date(timeIntervalSinceReferenceDate: 780_007_200))
        #expect(kept == rows, "the relay kept \(kept) of the built payload")
    }

    // MARK: Group 20 — the feature payloads' JSON

    /// D1 as alice's offer and grant carry it: coarse location present, whole-second dates.
    static let frozenDescriptorD1JSON = [
        #"{"activityID":"A1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D","activityTypeToken":"walk","#,
        #""coarseLocation":"Portland","createdAt":780000000,"expiresAt":780003600,"#,
        #""hostFingerprint":"c945cbf2a5602002","#,
        #""hostSigningPublicKey":"5\/FioQvsVZr+oZXk3OhLaVaNXSywlj60RsBoXisX8vA=","title":"Sunset walk"}"#
    ].joined()

    /// D2: no location, so no `coarseLocation` key at all; the title written raw
    /// (`Caf\u{E9} crawl \u{2615}`); the fractional dates printed as written.
    static let frozenDescriptorD2JSON = [
        #"{"activityID":"A1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D","activityTypeToken":"coffee","#,
        #""createdAt":780000000.75,"expiresAt":780003599.5,"hostFingerprint":"c945cbf2a5602002","#,
        #""hostSigningPublicKey":"5\/FioQvsVZr+oZXk3OhLaVaNXSywlj60RsBoXisX8vA=","#,
        #""title":"Caf\#u{E9} crawl \#u{2615}"}"#
    ].joined()

    /// alice in R2: her fingerprint, `Alice`, both keys, joined 780 000 000 s after the reference date.
    static let frozenParticipantAliceJSON = [
        #"{"displayName":"Alice","fingerprint":"c945cbf2a5602002","joinedAt":780000000,"#,
        #""keyAgreementPublicKey":"B6N8vBQgk8i3VdwbEOhstCY3StFqqFPtC9\/AsrhtHHw=","#,
        #""signingPublicKey":"5\/FioQvsVZr+oZXk3OhLaVaNXSywlj60RsBoXisX8vA="}"#
    ].joined()

    /// bob in R2: `B\u{F8}b \u{1F33F}` written raw, joined 780 000 600.5 s after the reference date.
    static let frozenParticipantBobJSON = [
        #"{"displayName":"B\#u{F8}b \#u{1F33F}","fingerprint":"b4cb4b93c4027ce3","joinedAt":780000600.5,"#,
        #""keyAgreementPublicKey":"ZLEBsdC+WocEvQePmJUAH8A+jp+VIvGI3RKNmEbUhGY=","#,
        #""signingPublicKey":"iC0Oo7KGTnpYfz5pjOpEWZmDEuZV4F+l6LURnYuqyM0="}"#
    ].joined()

    /// R2 with alice's frozen signature (group 19's `rosterR2SignatureHex`, base64).
    static let frozenSnapshotR2JSON = [
        #"{"activityID":"A1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D","#,
        #""hostSignature":"zAS2iJHy5sE+KuM4GEg3Z\/UnrjAWkxXIZoMTBxWmRBtifKrZSbZZMvT5zf4s0Q5\/UFclaDWEEIOsU9PPFdHcBw==","#,
        #""hostSigningPublicKey":"5\/FioQvsVZr+oZXk3OhLaVaNXSywlj60RsBoXisX8vA=","issuedAt":780000660,"participants":["#,
        frozenParticipantAliceJSON, ",", frozenParticipantBobJSON, #"],"schemaVersion":1,"version":2}"#
    ].joined()

    /// J1 with alice's frozen signature (group 19's `joinTokenSignatureHex`, base64) and D1's params
    /// hash.
    static let frozenTokenJ1JSON = [
        #"{"activityID":"A1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D","#,
        #""activityParamsHash":"EXO8Cejs+6m08nxSP4JGw4vjED9IkxHpOvrgoZ3PPMM=","expiresAt":780003600,"#,
        #""grantedAt":780000600,"hostFingerprint":"c945cbf2a5602002","#,
        #""hostSignature":"NpKhtklHeYk5nPrb2Y2rtobyWOomy1hmgGcjET7VLv\/LWomyxi12hdyGT23vf7Upl1GDg9W7BqTRs10V4Wc\/AA==","#,
        #""hostSigningPublicKey":"5\/FioQvsVZr+oZXk3OhLaVaNXSywlj60RsBoXisX8vA=","#,
        #""joinerFingerprint":"b4cb4b93c4027ce3","#,
        #""joinerSigningPublicKey":"iC0Oo7KGTnpYfz5pjOpEWZmDEuZV4F+l6LURnYuqyM0=","rosterVersionAtGrant":2,"#,
        #""schemaVersion":1}"#
    ].joined()

    /// alice's offer of D1 at roster version 2, as bob decodes it. 371 bytes.
    static let frozenOfferD1JSON = [
        #"{"descriptor":"#, frozenDescriptorD1JSON, #","format":"fernlet.proximity.activity.offer","rosterVersion":2,"version":1}"#
    ].joined()

    /// An offer of D2 at roster version 1. 354 bytes.
    static let frozenOfferD2JSON = [
        #"{"descriptor":"#, frozenDescriptorD2JSON, #","format":"fernlet.proximity.activity.offer","rosterVersion":1,"version":1}"#
    ].joined()

    /// bob's (unsealed) request to join alice's activity. 336 bytes.
    static let frozenJoinRequestJSON = [
        #"{"activityID":"A1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D","#,
        #""format":"fernlet.proximity.activity.join.request","joinerDisplayName":"B\#u{F8}b \#u{1F33F}","#,
        #""joinerFingerprint":"b4cb4b93c4027ce3","#,
        #""joinerKeyAgreementPublicKey":"ZLEBsdC+WocEvQePmJUAH8A+jp+VIvGI3RKNmEbUhGY=","#,
        #""joinerSigningPublicKey":"iC0Oo7KGTnpYfz5pjOpEWZmDEuZV4F+l6LURnYuqyM0=","version":1}"#
    ].joined()

    /// alice's sealed grant: J1 and R2. 1 358 bytes.
    static let frozenJoinGrantJSON = [
        #"{"format":"fernlet.proximity.activity.join.grant","snapshot":"#, frozenSnapshotR2JSON,
        #","token":"#, frozenTokenJ1JSON, #","version":1}"#
    ].joined()

    /// R2 gossiped. 809 bytes.
    static let frozenRosterGossipJSON = [
        #"{"format":"fernlet.proximity.activity.roster","snapshot":"#, frozenSnapshotR2JSON, #","version":1}"#
    ].joined()

    /// A two-line digest: alice's activity at version 2, bob's at version 1. 205 bytes.
    static let frozenSyncJSON = [
        #"{"format":"fernlet.proximity.activity.sync","#,
        #""held":[{"activityID":"A1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D","versionHeld":2},"#,
        #"{"activityID":"B0B0AC71-4A53-4F4E-8000-000000000003","versionHeld":1}],"version":1}"#
    ].joined()

    /// Each activity payload decodes from its frozen text to its fixture value and encodes back to it
    /// (sorted keys, byte for byte; production's own encoder, as a JSON object); each is well formed
    /// under its format token and version 1; D2's offer carries no location key.
    @Test func theActivityPayloadsDecodeFromTheirFrozenJSONAndEncodeToIt() throws {
        let offerD1 = try Self.expectFrozenJSON(Self.frozenOfferD1JSON, decodesTo: Self.offerD1, "the D1 offer")
        let offerD2 = try Self.expectFrozenJSON(Self.frozenOfferD2JSON, decodesTo: Self.offerD2, "the D2 offer")
        let request = try Self.expectFrozenJSON(Self.frozenJoinRequestJSON, decodesTo: Self.joinRequest, "the join request")
        let grant = try Self.expectFrozenJSON(Self.frozenJoinGrantJSON, decodesTo: Self.joinGrant, "the join grant")
        let gossip = try Self.expectFrozenJSON(Self.frozenRosterGossipJSON, decodesTo: Self.rosterGossip, "the roster gossip")
        let sync = try Self.expectFrozenJSON(Self.frozenSyncJSON, decodesTo: Self.syncDigest, "the sync digest")
        let wellFormed = [offerD1.isWellFormed, offerD2.isWellFormed, request.isWellFormed, grant.isWellFormed,
                          gossip.isWellFormed, sync.isWellFormed]
        #expect(wellFormed == Array(repeating: true, count: 6), "well formed: \(wellFormed)")
        #expect(offerD2.descriptor.coarseLocation == nil && !Self.frozenOfferD2JSON.contains("coarseLocation"),
                "D2's offer carries a location")
    }

    /// alice's shop of one item: the hat group 4 hashes, created 779 990 000 s after the reference date
    /// and listed at 5 coins. 473 bytes.
    static let frozenCatalogJSON = [
        #"{"designerID":"E1F2A3B4-C5D6-4E7F-8091-A2B3C4D5E6F7","displayName":"Alice","#,
        #""format":"fernlet.proximity.clothing.catalog","id":"CA7A1060-4A53-4F4E-8000-000000000001","#,
        #""items":[{"createdAt":779990000,"designer":{"id":"E1F2A3B4-C5D6-4E7F-8091-A2B3C4D5E6F7"},"#,
        #""id":"D1E2F3A4-B5C6-4D7E-8F90-A1B2C3D4E5F6","isShareable":true,"name":"Golden hat","price":5,"#,
        #""slot":"hat","texture":{"cols":2,"palette":["2E2A24","FFFFFF"],"pixels":[0,1,-1,0],"rows":2}}],"#,
        #""sentAt":780000000,"version":1}"#
    ].joined()

    /// The shop's catalog request, whose summary is its whole body: the title, no subtitle or date range
    /// (their keys absent), zero items, no details. 68 bytes.
    static let frozenCatalogRequestJSON = #"{"extraDetails":{},"itemCount":0,"title":"Clothing catalog request"}"#

    /// The catalog and the request decode from their frozen texts to their fixture values and encode back
    /// to them; the receive path's sanitizer leaves the listed hat exactly as it is.
    @Test func theCatalogAndTheShopsRequestDecodeFromTheirFrozenJSON() throws {
        let catalog = try Self.expectFrozenJSON(Self.frozenCatalogJSON, decodesTo: Self.aliceCatalog, "alice's catalog")
        #expect(catalog.items.map(Self.shopSanitized) == catalog.items, "the receive path's sanitizer changed the hat")
        _ = try Self.expectFrozenJSON(Self.frozenCatalogRequestJSON, decodesTo: Self.catalogRequest, "the catalog request")
    }

    /// The mesh writes the catalog it seals and the request it sends unsealed with its own encoder: a
    /// manager over planted alice, its shop opted in with alice's catalog, seats bob's committed slot
    /// advertising `shop` alone (so the catalog is sealed in the legacy framing) and sends both on the
    /// commit; bob opens the catalog. Each body is its frozen text as a JSON object.
    @Test func theMeshSendsTheFrozenCatalogAndRequestBodies() async throws {
        let sent = try await Self.shopBodiesSentOnCommit(catalog: Self.aliceCatalog)
        #expect(try Self.jsonObjectsEqual(sent.catalog, Data(Self.frozenCatalogJSON.utf8)),
                "the mesh sent the catalog \(String(decoding: sent.catalog, as: UTF8.self))")
        #expect(try Self.jsonObjectsEqual(sent.request, Data(Self.frozenCatalogRequestJSON.utf8)),
                "the mesh sent the request \(String(decoding: sent.request, as: UTF8.self))")
    }

    /// M1 signed, as the report payload's rows array carries it (group 19's
    /// `moderationReportSignatureHex`).
    static let frozenReportRowM1JSON = [
        #"{"entry":{"contentHash":"q80=","createdAt":780000000,"id":"report:c945cbf2a5602002:abcd","#,
        #""itemID":"D1E2F3A4-B5C6-4D7E-8F90-A1B2C3D4E5F6","kind":"report","reasonToken":"offensive","#,
        #""reporterSeq":1,"reporterSigningPublicKey":"5\/FioQvsVZr+oZXk3OhLaVaNXSywlj60RsBoXisX8vA=","#,
        #""subjectSigningPublicKey":"iC0Oo7KGTnpYfz5pjOpEWZmDEuZV4F+l6LURnYuqyM0="},"#,
        #""signature":"0w1VEKgPc2E998+bqwawp186AK+nN3kc2gYnn\/pbF2k6sMsXGQ\/YF7muViAzWJ3nI9Ti2nlx4yt0A67NdoAPAw=="}"#
    ].joined()

    /// M2 signed (group 19's `moderationRetractSignatureHex`).
    static let frozenReportRowM2JSON = [
        #"{"entry":{"contentHash":"q80=","createdAt":780003600.75,"id":"retract:c945cbf2a5602002:abcd","#,
        #""itemID":"D1E2F3A4-B5C6-4D7E-8F90-A1B2C3D4E5F6","kind":"retract","reasonToken":"offensive","#,
        #""reporterSeq":2,"reporterSigningPublicKey":"5\/FioQvsVZr+oZXk3OhLaVaNXSywlj60RsBoXisX8vA=","#,
        #""subjectSigningPublicKey":"iC0Oo7KGTnpYfz5pjOpEWZmDEuZV4F+l6LURnYuqyM0="},"#,
        #""signature":"W5D1uobO1YBT4aTG5RDUbn0oTxLlR56mb6DUbJN6C6aKkIyRR00Ntq9HgtUeVYAC0rBtAIbur\/9iLLH7TyHbDw=="}"#
    ].joined()

    /// alice's report and its retraction. 976 bytes.
    static let frozenReportPayloadJSON = [
        #"{"format":"fernlet.proximity.moderation.report","reports":["#, frozenReportRowM1JSON, ",", frozenReportRowM2JSON,
        #"],"version":1}"#
    ].joined()

    /// The rows alone, no format and no version. 917 bytes.
    static let frozenReportRowsOnlyJSON = [#"{"reports":["#, frozenReportRowM1JSON, ",", frozenReportRowM2JSON, "]}"].joined()

    /// What `{}` decodes to, with sorted keys: the default format, version 1, no rows. 73 bytes.
    static let frozenReportDefaultsJSON = #"{"format":"fernlet.proximity.moderation.report","reports":[],"version":1}"#

    /// 33 signed rows, one past the cap: 32 copies of M1, then M2. 14 926 bytes, built rather than
    /// embedded.
    static var frozenReportCapJSON: String {
        let rows = Array(repeating: frozenReportRowM1JSON, count: 32) + [frozenReportRowM2JSON]
        return [#"{"format":"fernlet.proximity.moderation.report","reports":["#, rows.joined(separator: ","), #"],"version":1}"#]
            .joined()
    }

    /// SHA-256 of ``frozenReportCapJSON``'s UTF-8, frozen so the build rule cannot drift.
    static let frozenReportCapSHA256Hex = "ed416aad434ba39ccdb7b944c96a3c13282501e2b09171d54387f866b9905354"

    /// What the capped text decodes to, with sorted keys: the first 32 rows, every one M1. 14 472 bytes.
    static var frozenReportCapKeptJSON: String {
        let rows = Array(repeating: frozenReportRowM1JSON, count: 32)
        return [#"{"format":"fernlet.proximity.moderation.report","reports":["#, rows.joined(separator: ","), #"],"version":1}"#]
            .joined()
    }

    /// The report payload decodes from its frozen text to alice's two signed rows and encodes back to it;
    /// `{}` decodes to the defaults; the rows alone decode to the full payload; 33 rows decode to their
    /// first 32 (a prefix), all M1; and the relay keeps exactly the rows alice signed, both from the full
    /// payload and 32 from the capped one.
    @Test func theModerationReportDecodesWithItsDefaultsAndItsCap() throws {
        let payload = try Self.expectFrozenJSON(Self.frozenReportPayloadJSON, decodesTo: Self.reportBundle, "alice's report")
        let decoder = Self.meshPayloadDecoder()
        let defaults = try decoder.decode(ReportBundle.self, from: Data("{}".utf8))
        #expect(defaults == ReportBundle(reports: []), "{} decoded to \(defaults)")
        let defaultsJSON = try Self.sortedJSON(defaults)
        #expect(defaultsJSON == Self.frozenReportDefaultsJSON, "{} re-encodes as \(defaultsJSON)")
        let rowsOnly = try decoder.decode(ReportBundle.self, from: Data(Self.frozenReportRowsOnlyJSON.utf8))
        #expect(rowsOnly == payload, "the rows alone decoded to \(rowsOnly)")
        let cap = Self.frozenReportCapJSON
        #expect(cap.utf8.count == 14_926 && Self.hex(Data(SHA256.hash(data: Data(cap.utf8)))) == Self.frozenReportCapSHA256Hex,
                "the cap text's build rule drifted")
        let capped = try decoder.decode(ReportBundle.self, from: Data(cap.utf8))
        #expect(capped.reports == Array(repeating: Self.signedReportRows[0], count: 32),
                "the 33-row text decoded to \(capped.reports.count) rows")
        #expect(try Self.sortedJSON(capped) == Self.frozenReportCapKeptJSON, "the capped value re-encodes otherwise")
        let now = Date(timeIntervalSinceReferenceDate: 780_007_200)
        #expect(Self.moderationRows(from: payload, sender: Self.aliceSigningPub, now: now)
                    == [Self.moderationReport, Self.moderationRetract], "the relay kept another set of rows")
        #expect(Self.moderationRows(from: capped, sender: Self.aliceSigningPub, now: now)
                    == Array(repeating: Self.moderationReport, count: 32), "the relay kept another set of capped rows")
    }

    /// alice's vouch list naming bob and carol, expiring 2100-01-01T00:00:00Z. 155 bytes.
    static let frozenVouchListJSON = [
        #"{"expiresAt":3124137600,"trustedFingerprints":["b4cb4b93c4027ce3","f0f1f2f3f4f5f6f7"],"#,
        #""voucherDisplayName":"Alice","voucherFingerprint":"c945cbf2a5602002"}"#
    ].joined()

    /// The vouch list decodes from its frozen text and encodes back to it; with the broadcast gate forced
    /// on, a manager caches it from alice with her name kept, its expiry capped two hours out, and labels
    /// bob "Friend of Alice": group 25's lifetime and prefix, read where that group freezes them.
    @Test func theVouchListDecodesFromItsFrozenJSONAndIsCachedCapped() throws {
        let list = try Self.expectFrozenJSON(Self.frozenVouchListJSON, decodesTo: Self.aliceVouchList, "alice's vouch list")
        let root = Self.scratchDirectory()
        let service = Self.throwawayService()
        defer {
            Self.sweep([service])
            Self.removeDirectory(root)
        }
        let store = makeTestStore(proximitySupportDirectory: root)
        let alice = try Self.plantedAlice(service: service)
        let features = Self.meshFeatures(over: store, identity: alice)
        let before = Date()
        let cached = Self.receiveVouchList(list, from: Self.aliceFingerprint, on: features)
        let after = Date()
        #expect(cached?.voucherDisplayName == "Alice" && cached?.trustedFingerprints == [Self.bobFingerprint, Self.carolFingerprint])
        let expiry = try #require(cached?.expiresAt, "nothing was cached")
        let lifetime = Self.vouchListLifetimeSeconds
        #expect(expiry >= before.addingTimeInterval(lifetime) && expiry <= after.addingTimeInterval(lifetime),
                "cached until \(expiry)")
        let label = Self.vouchLabel(for: Self.bobFingerprint, on: features)
        #expect(label == Self.vouchLabelPrefix + "Alice", "bob is labelled \(String(describing: label))")
        withExtendedLifetime((store, features)) {}
    }

    // MARK: Group 21 — the heart ledger's file

    /// H0, the v1 blob's heart from bob, received 780 001 000 s after the reference date.
    static let frozenHeartH0JSON = [
        #"{"id":"4EA27000-4A53-4F4E-8000-000000000010","receivedAt":780001000,"senderDisplayName":"Bob","#,
        #""senderFingerprint":"b4cb4b93c4027ce3"}"#
    ].joined()
    /// H1, an older heart from bob whose bubble was dismissed.
    static let frozenHeartH1JSON = [
        #"{"bubbleDismissedAt":779990100,"id":"4EA27001-4A53-4F4E-8000-000000000011","receivedAt":779990000,"#,
        #""senderDisplayName":"Bob","senderFingerprint":"b4cb4b93c4027ce3"}"#
    ].joined()
    /// H2, carol's heart 200 s before the load clock, its bubble showing (no `bubbleDismissedAt` key).
    static let frozenHeartH2JSON = [
        #"{"id":"4EA27002-4A53-4F4E-8000-000000000012","receivedAt":780001600,"senderDisplayName":"Carol","#,
        #""senderFingerprint":"f0f1f2f3f4f5f6f7"}"#
    ].joined()

    /// A v2 ledger: bob's send stamp, carol's receive stamp, H1 and H2. 424 bytes.
    static let frozenHeartLedgerV2JSON = [
        #"{"lastReceivedAt":{"f0f1f2f3f4f5f6f7":780001600},"lastSentAt":{"b4cb4b93c4027ce3":780001700},"#,
        #""receivedHearts":["#, frozenHeartH1JSON, ",", frozenHeartH2JSON, #"],"version":2}"#
    ].joined()

    /// A v1 blob: a day-scoped `rateLimitKeys` set, no timestamp maps, no version key. 202 bytes.
    static let frozenHeartLedgerV1JSON = [
        #"{"rateLimitKeys":["b4cb4b93c4027ce3:2025-09-19"],"receivedHearts":["#, frozenHeartH0JSON, "]}"
    ].joined()

    /// The v2 file after a heart to carol at the load clock: her send stamp added, nothing
    /// pruned. 453 bytes.
    static let frozenHeartLedgerSentToCarolJSON = [
        #"{"lastReceivedAt":{"f0f1f2f3f4f5f6f7":780001600},"#,
        #""lastSentAt":{"b4cb4b93c4027ce3":780001700,"f0f1f2f3f4f5f6f7":780001800},"receivedHearts":["#,
        frozenHeartH1JSON, ",", frozenHeartH2JSON, #"],"version":2}"#
    ].joined()

    /// The v2 file after a heart to carol 48 h + 1 s after H1: H1 and both old stamps pruned. 232 bytes.
    static let frozenHeartLedgerPrunedJSON = [
        #"{"lastReceivedAt":{},"lastSentAt":{"f0f1f2f3f4f5f6f7":780162801},"receivedHearts":["#, frozenHeartH2JSON,
        #"],"version":2}"#
    ].joined()

    /// The v1 blob after a heart to bob: both maps, no `rateLimitKeys`, and still version 1. 230 bytes.
    static let frozenHeartLedgerV1SentToBobJSON = [
        #"{"lastReceivedAt":{},"lastSentAt":{"b4cb4b93c4027ce3":780001800},"receivedHearts":["#, frozenHeartH0JSON,
        #"],"version":1}"#
    ].joined()

    /// A ledger over the frozen v2 file, at the load clock, holds exactly its state and writes nothing:
    /// its hearts oldest first; no heart to bob inside his 5-minute window, one to carol; carol's second
    /// heart refused inside hers and H1's re-delivery refused as a duplicate; a commit proof for H1 and
    /// none for H3; H2's bubble showing, and the glow H2's at 200 s, 1 − 200/86 400.
    @Test func aFrozenV2HeartLedgerLoadsIntoItsState() throws {
        let root = Self.scratchDirectory()
        defer { Self.removeDirectory(root) }
        let url = Self.heartLedgerFile(in: root)
        try Self.write(Self.frozenHeartLedgerV2JSON, to: url)
        let ledger = Self.heartLedger(fileURL: url, clock: Self.heartLoadClock)
        #expect(ledger.isLoaded && ledger.receivedHearts == [Self.heartH1, Self.heartH2],
                "the ledger loaded \(ledger.receivedHearts)")
        #expect(!ledger.canSendHeart(to: Self.bobFingerprint) && ledger.canSendHeart(to: Self.carolFingerprint))
        #expect(!ledger.recordReceivedHeart(id: Self.heartH3ID, senderDisplayName: "Carol",
                                            senderFingerprint: Self.carolFingerprint))
        #expect(!ledger.recordReceivedHeart(id: Self.heartH1.id, senderDisplayName: "Bob", senderFingerprint: Self.bobFingerprint))
        #expect(ledger.commitProof(for: Self.heartH1.id)?.giftID == Self.heartH1.id
                    && ledger.commitProof(for: Self.heartH3ID) == nil)
        #expect(ledger.pendingBubbleHeart == Self.heartH2 && ledger.activeGlow() == 1 - 200.0 / 86_400)
        #expect(try Data(contentsOf: url) == Data(Self.frozenHeartLedgerV2JSON.utf8), "loading or a refusal wrote the file")
    }

    /// A ledger over the frozen v1 blob loads tolerantly (version 1, both maps empty, the day keys
    /// ignored): H0 alone, and a heart to bob allowed; the send writes the file with both maps and still
    /// version 1.
    @Test func aFrozenV1HeartLedgerLoadsTolerantlyAndKeepsItsVersion() throws {
        let root = Self.scratchDirectory()
        defer { Self.removeDirectory(root) }
        let url = Self.heartLedgerFile(in: root)
        try Self.write(Self.frozenHeartLedgerV1JSON, to: url)
        let ledger = Self.heartLedger(fileURL: url, clock: Self.heartLoadClock)
        #expect(ledger.isLoaded && ledger.receivedHearts == [Self.heartH0], "the v1 blob loaded \(ledger.receivedHearts)")
        #expect(ledger.canSendHeart(to: Self.bobFingerprint), "the v1 day key still gates")
        ledger.recordHeartSent(to: Self.bobFingerprint)
        let written = try Data(contentsOf: url)
        #expect(try Self.jsonObjectsEqual(written, Data(Self.frozenHeartLedgerV1SentToBobJSON.utf8)),
                "the v1 ledger wrote \(String(decoding: written, as: UTF8.self))")
    }

    /// A heart to carol over the frozen v2 file writes its frozen file: at the load clock nothing is
    /// pruned; 48 h + 1 s after H1 the load still holds both hearts (a load prunes nothing), bob's old
    /// stamp no longer gates and H2 no longer glows, and the send prunes H1 (`>` 48 h) and both old
    /// stamps.
    @Test func aHeartToCarolWritesItsFrozenFile() throws {
        let cases = [(Self.heartLoadClock, Self.frozenHeartLedgerSentToCarolJSON, [Self.heartH1, Self.heartH2]),
                     (Self.heartPruneClock, Self.frozenHeartLedgerPrunedJSON, [Self.heartH2])]
        // R2: bounded by the two clocks.
        for (clock, frozen, kept) in cases {
            let root = Self.scratchDirectory()
            defer { Self.removeDirectory(root) }
            let url = Self.heartLedgerFile(in: root)
            try Self.write(Self.frozenHeartLedgerV2JSON, to: url)
            let ledger = Self.heartLedger(fileURL: url, clock: clock)
            if clock == Self.heartPruneClock {
                #expect(ledger.receivedHearts == [Self.heartH1, Self.heartH2] && ledger.canSendHeart(to: Self.bobFingerprint)
                        && ledger.pendingBubbleHeart == nil, "the late load holds \(ledger.receivedHearts)")
            }
            ledger.recordHeartSent(to: Self.carolFingerprint)
            let written = try Data(contentsOf: url)
            #expect(try Self.jsonObjectsEqual(written, Data(frozen.utf8)),
                    "at \(clock) the ledger wrote \(String(decoding: written, as: UTF8.self))")
            #expect(ledger.receivedHearts == kept, "at \(clock) the ledger keeps \(ledger.receivedHearts)")
        }
    }

    // MARK: Group 22 — the activity ledger's file

    /// DB, bob's own activity: no location, created 780 000 300 s after the reference date, two hours
    /// long.
    static let frozenDescriptorDBJSON = [
        #"{"activityID":"B0B0AC71-4A53-4F4E-8000-000000000003","activityTypeToken":"coffee","#,
        #""createdAt":780000300,"expiresAt":780007500,"hostFingerprint":"b4cb4b93c4027ce3","#,
        #""hostSigningPublicKey":"iC0Oo7KGTnpYfz5pjOpEWZmDEuZV4F+l6LURnYuqyM0=","title":"Coffee run"}"#
    ].joined()

    /// bob as DB's host, joined at its creation.
    static let frozenParticipantBobHostJSON = [
        #"{"displayName":"B\#u{F8}b \#u{1F33F}","fingerprint":"b4cb4b93c4027ce3","joinedAt":780000300,"#,
        #""keyAgreementPublicKey":"ZLEBsdC+WocEvQePmJUAH8A+jp+VIvGI3RKNmEbUhGY=","#,
        #""signingPublicKey":"iC0Oo7KGTnpYfz5pjOpEWZmDEuZV4F+l6LURnYuqyM0="}"#
    ].joined()

    /// RB1, bob's first roster for DB, with bob's frozen signature (``rosterRB1SignatureHex``, base64).
    static let frozenSnapshotRB1JSON = [
        #"{"activityID":"B0B0AC71-4A53-4F4E-8000-000000000003","#,
        #""hostSignature":"OVRzh5or0+bmCvXXtom4fFndsaWqMJveVHzOA+Kilkj1VPyfeHo5AKH\/RmVshiNchUCg2ZyoS9gol37UgV7GBA==","#,
        #""hostSigningPublicKey":"iC0Oo7KGTnpYfz5pjOpEWZmDEuZV4F+l6LURnYuqyM0=","issuedAt":780000300,"participants":["#,
        frozenParticipantBobHostJSON, #"],"schemaVersion":1,"version":1}"#
    ].joined()

    /// bob's hosted row: DB, himself, version 1, RB1.
    static let frozenHostedDBJSON = [
        #"{"currentSnapshot":"#, frozenSnapshotRB1JSON, #","descriptor":"#, frozenDescriptorDBJSON,
        #","participants":["#, frozenParticipantBobHostJSON, #"],"version":1}"#
    ].joined()

    /// bob's joined row: D1 pinned, J1, R2.
    static let frozenJoinedD1JSON = [
        #"{"descriptor":"#, frozenDescriptorD1JSON, #","lastSnapshot":"#, frozenSnapshotR2JSON, #","token":"#, frozenTokenJ1JSON, "}"
    ].joined()

    /// bob's ActivityLedger.json. 2 688 bytes.
    static let frozenActivityLedgerJSON = [
        #"{"hosted":["#, frozenHostedDBJSON, #"],"joined":["#, frozenJoinedD1JSON, #"],"version":1}"#
    ].joined()

    /// The ledger after D1's expiry: DB alone. 1 091 bytes.
    static let frozenActivityLedgerAfterExpiryJSON = [#"{"hosted":["#, frozenHostedDBJSON, #"],"joined":[],"version":1}"#].joined()

    /// A fresh ledger after alice's grant: D1 joined. 1 634 bytes.
    static let frozenActivityLedgerJoinedJSON = [#"{"hosted":[],"joined":["#, frozenJoinedD1JSON, #"],"version":1}"#].joined()

    /// The empty ledger as a save writes it. 37 bytes.
    static let frozenActivityLedgerEmptyJSON = #"{"hosted":[],"joined":[],"version":1}"#

    /// A manager over bob's frozen ledger, at the load clock, holds his hosted DB and his joined D1
    /// exactly and writes nothing (init's expiry pass removes nothing); RB1 verifies under bob's key; and
    /// a save of the unchanged state, leaving an activity nobody holds, writes the frozen ledger back.
    @Test func aFrozenActivityLedgerLoadsIntoItsStateAndSavesUnchanged() throws {
        let host = MockPresenceQUICHost()
        let root = Self.scratchDirectory()
        defer { Self.removeDirectory(root) }
        let url = Self.activityLedgerFile(in: root)
        try Self.write(Self.frozenActivityLedgerJSON, to: url)
        let manager = Self.activityManager(host: host, identity: nil, fileURL: url, clock: Self.activityLoadClock)
        #expect(manager.hostedActivities == [Self.hostedDB], "the ledger hosts \(manager.hostedActivities)")
        #expect(manager.joinedActivities == [Self.joinedD1], "the ledger joined \(manager.joinedActivities)")
        #expect(manager.offeredActivities.isEmpty && manager.pendingJoinRequests.isEmpty)
        #expect(try Data(contentsOf: url) == Data(Self.frozenActivityLedgerJSON.utf8), "loading wrote the ledger")
        #expect(throws: Never.self, "RB1 does not verify under bob's key") {
            try Self.verifyRoster(Self.rosterRB1, activityID: Self.dbActivityID, hostKey: Self.bobSigningPub)
        }
        manager.leaveJoined(activityID: Self.uuid("CA7A1060-4A53-4F4E-8000-0000000000FF"))
        let written = try Data(contentsOf: url)
        #expect(try Self.jsonObjectsEqual(written, Data(Self.frozenActivityLedgerJSON.utf8)),
                "an unchanged save wrote \(String(decoding: written, as: UTF8.self))")
        withExtendedLifetime(host) {}
    }

    /// At D1's expiry exactly (`now >= expiresAt`) init drops the joined row and writes DB alone; and
    /// `{}` loads as no activities and saves as the empty ledger.
    @Test func anActivityLedgerDropsItsExpiredRowAndAnEmptyOneSavesEmpty() throws {
        let host = MockPresenceQUICHost()
        let root = Self.scratchDirectory()
        defer { Self.removeDirectory(root) }
        let url = Self.activityLedgerFile(in: root)
        try Self.write(Self.frozenActivityLedgerJSON, to: url)
        let expired = Self.activityManager(host: host, identity: nil, fileURL: url, clock: Self.d1ExpiryClock)
        #expect(expired.hostedActivities == [Self.hostedDB] && expired.joinedActivities.isEmpty)
        let afterExpiry = try Data(contentsOf: url)
        #expect(try Self.jsonObjectsEqual(afterExpiry, Data(Self.frozenActivityLedgerAfterExpiryJSON.utf8)),
                "the expiry pass wrote \(String(decoding: afterExpiry, as: UTF8.self))")
        try Self.write("{}", to: url)
        let empty = Self.activityManager(host: host, identity: nil, fileURL: url, clock: Self.activityLoadClock)
        #expect(empty.hostedActivities.isEmpty && empty.joinedActivities.isEmpty)
        empty.leaveJoined(activityID: Self.uuid("CA7A1060-4A53-4F4E-8000-0000000000FF"))
        let saved = try Data(contentsOf: url)
        #expect(try Self.jsonObjectsEqual(saved, Data(Self.frozenActivityLedgerEmptyJSON.utf8)),
                "the empty ledger saved \(String(decoding: saved, as: UTF8.self))")
        withExtendedLifetime(host) {}
    }

    /// A fresh manager for planted bob, at the load clock, offered D1 by alice (the frozen offer) and
    /// granted it (the frozen grant, whose J1 and R2 verify under alice's key), joins D1 and writes the
    /// frozen joined ledger.
    @Test func aGrantFromTheHostJoinsAndWritesTheFrozenLedger() throws {
        let host = MockPresenceQUICHost()
        let service = Self.throwawayService()
        let root = Self.scratchDirectory()
        defer {
            Self.sweep([service])
            Self.removeDirectory(root)
        }
        let bob = try Self.plantedIdentity(signing: Self.bobSigningRaw, keyAgreement: Self.bobKeyAgreementRaw, service: service)
        let url = Self.activityLedgerFile(in: root)
        let manager = Self.activityManager(host: host, identity: bob, fileURL: url, clock: Self.activityLoadClock)
        let decoder = Self.meshPayloadDecoder()
        let offer = try decoder.decode(ActivityOffer.self, from: Data(Self.frozenOfferD1JSON.utf8))
        manager.receiveOffer(offer, fromFingerprint: Self.aliceFingerprint, verifiedHostSigningPublicKey: Self.aliceSigningPub)
        #expect(manager.offeredActivities.map(\.descriptor) == [Self.descriptorD1], "bob holds \(manager.offeredActivities)")
        let grant = try decoder.decode(ActivityJoinGrant.self, from: Data(Self.frozenJoinGrantJSON.utf8))
        manager.receiveGrant(grant, fromFingerprint: Self.aliceFingerprint)
        #expect(manager.activityError == nil && manager.offeredActivities.isEmpty,
                "the grant was refused: \(String(describing: manager.activityError))")
        #expect(manager.joinedActivities == [Self.joinedD1], "bob joined \(manager.joinedActivities)")
        let written = try Data(contentsOf: url)
        #expect(try Self.jsonObjectsEqual(written, Data(Self.frozenActivityLedgerJoinedJSON.utf8)),
                "the joined ledger is \(String(decoding: written, as: UTF8.self))")
        withExtendedLifetime(host) {}
    }

    // MARK: Group 23 — the photo wall's files and the proximity root's layout

    /// S1, sunny-meadow's session with alice and bob.
    static let frozenSessionS1JSON = [
        #"{"id":"5E55100A-4A53-4F4E-8000-000000000021","meshID":"3E5A1D01-4A53-4F4E-8000-000000000031","#,
        #""meshName":"sunny-meadow","participants":[{"displayName":"Alice","fingerprint":"c945cbf2a5602002"},"#,
        #"{"displayName":"Bob","fingerprint":"b4cb4b93c4027ce3"}],"startedAt":"2025-09-19T18:40:00Z"}"#
    ].joined()
    /// S2, a session with no mesh id or name (both keys absent).
    static let frozenSessionS2JSON = [
        #"{"id":"5E55100B-4A53-4F4E-8000-000000000022","participants":[{"displayName":"Alice","#,
        #""fingerprint":"c945cbf2a5602002"},{"displayName":"Bob","fingerprint":"b4cb4b93c4027ce3"}],"#,
        #""startedAt":"2025-09-19T19:45:00Z"}"#
    ].joined()

    /// P1…P6, metadata only, ISO-8601 dates. P4 is a legacy single photo: no fingerprint, key or session
    /// key at all.
    static let frozenWallPhotoP1JSON = [
        #"{"addedAt":"2025-09-19T18:41:00Z","id":"F0700001-4A53-4F4E-8000-000000000041","keyEpoch":0,"#,
        #""senderFingerprint":"b4cb4b93c4027ce3","senderName":"Bob","#,
        #""senderSigningPublicKey":"iC0Oo7KGTnpYfz5pjOpEWZmDEuZV4F+l6LURnYuqyM0=","#,
        #""session":{"id":"5E55100A-4A53-4F4E-8000-000000000021","#,
        #""meshID":"3E5A1D01-4A53-4F4E-8000-000000000031","meshName":"sunny-meadow","#,
        #""participants":[{"displayName":"Alice","fingerprint":"c945cbf2a5602002"},{"displayName":"Bob","#,
        #""fingerprint":"b4cb4b93c4027ce3"}],"startedAt":"2025-09-19T18:40:00Z"}}"#
    ].joined()
    static let frozenWallPhotoP2JSON = [
        #"{"addedAt":"2025-09-19T18:42:00Z","id":"F0700002-4A53-4F4E-8000-000000000042","keyEpoch":0,"#,
        #""senderFingerprint":"c945cbf2a5602002","senderName":"Alice","#,
        #""senderSigningPublicKey":"5\/FioQvsVZr+oZXk3OhLaVaNXSywlj60RsBoXisX8vA=","#,
        #""session":{"id":"5E55100A-4A53-4F4E-8000-000000000021","#,
        #""meshID":"3E5A1D01-4A53-4F4E-8000-000000000031","meshName":"sunny-meadow","#,
        #""participants":[{"displayName":"Alice","fingerprint":"c945cbf2a5602002"},{"displayName":"Bob","#,
        #""fingerprint":"b4cb4b93c4027ce3"}],"startedAt":"2025-09-19T18:40:00Z"}}"#
    ].joined()
    static let frozenWallPhotoP3JSON = [
        #"{"addedAt":"2025-09-19T18:43:00Z","id":"F0700003-4A53-4F4E-8000-000000000043","keyEpoch":0,"#,
        #""senderFingerprint":"b4cb4b93c4027ce3","senderName":"Bob","#,
        #""senderSigningPublicKey":"iC0Oo7KGTnpYfz5pjOpEWZmDEuZV4F+l6LURnYuqyM0=","#,
        #""session":{"id":"5E55100A-4A53-4F4E-8000-000000000021","#,
        #""meshID":"3E5A1D01-4A53-4F4E-8000-000000000031","meshName":"sunny-meadow","#,
        #""participants":[{"displayName":"Alice","fingerprint":"c945cbf2a5602002"},{"displayName":"Bob","#,
        #""fingerprint":"b4cb4b93c4027ce3"}],"startedAt":"2025-09-19T18:40:00Z"}}"#
    ].joined()
    static let frozenWallPhotoP4JSON = [
        #"{"addedAt":"2025-09-19T15:53:20Z","id":"F0700004-4A53-4F4E-8000-000000000044","keyEpoch":0,"#,
        #""senderName":"Bob"}"#
    ].joined()
    static let frozenWallPhotoP5JSON = [
        #"{"addedAt":"2025-09-19T19:46:40Z","id":"F0700005-4A53-4F4E-8000-000000000045","keyEpoch":0,"#,
        #""senderFingerprint":"c945cbf2a5602002","senderName":"Alice","#,
        #""senderSigningPublicKey":"5\/FioQvsVZr+oZXk3OhLaVaNXSywlj60RsBoXisX8vA=","#,
        #""session":{"id":"5E55100B-4A53-4F4E-8000-000000000022","participants":[{"displayName":"Alice","#,
        #""fingerprint":"c945cbf2a5602002"},{"displayName":"Bob","fingerprint":"b4cb4b93c4027ce3"}],"#,
        #""startedAt":"2025-09-19T19:45:00Z"}}"#
    ].joined()
    static let frozenWallPhotoP6JSON = [
        #"{"addedAt":"2025-09-19T19:47:40Z","id":"F0700006-4A53-4F4E-8000-000000000046","keyEpoch":0,"#,
        #""senderFingerprint":"b4cb4b93c4027ce3","senderName":"Bob","#,
        #""senderSigningPublicKey":"iC0Oo7KGTnpYfz5pjOpEWZmDEuZV4F+l6LURnYuqyM0=","#,
        #""session":{"id":"5E55100B-4A53-4F4E-8000-000000000022","participants":[{"displayName":"Alice","#,
        #""fingerprint":"c945cbf2a5602002"},{"displayName":"Bob","fingerprint":"b4cb4b93c4027ce3"}],"#,
        #""startedAt":"2025-09-19T19:45:00Z"}}"#
    ].joined()

    /// The wall's legacy plaintext index, MeshPhotoCache.json, P1 to P6. 2 550 bytes.
    static let frozenWallIndexJSON = [
        "[",
        [frozenWallPhotoP1JSON, frozenWallPhotoP2JSON, frozenWallPhotoP3JSON, frozenWallPhotoP4JSON, frozenWallPhotoP5JSON,
         frozenWallPhotoP6JSON].joined(separator: ","),
        "]"
    ].joined()

    /// MeshPhotoWallPreferences.json: S1 and S2 aggregated, covers S1→P2 and S2→P5, favorite S1→P3; the
    /// Set and each flat [key, value, …] array in ascending order of the key's uuidString (production's
    /// order is the process's). 395 bytes.
    static let frozenWallPreferencesJSON = [
        #"{"aggregatedSessionIDs":["5E55100A-4A53-4F4E-8000-000000000021","#,
        #""5E55100B-4A53-4F4E-8000-000000000022"],"#,
        #""coverPhotoIDsBySession":["5E55100A-4A53-4F4E-8000-000000000021","#,
        #""F0700002-4A53-4F4E-8000-000000000042","5E55100B-4A53-4F4E-8000-000000000022","#,
        #""F0700005-4A53-4F4E-8000-000000000045"],"#,
        #""favoritePhotoIDsBySession":["5E55100A-4A53-4F4E-8000-000000000021","#,
        #""F0700003-4A53-4F4E-8000-000000000043"]}"#
    ].joined()

    /// The same plus one stale entry per prune leg: S9 aggregated, a cover keyed by S9, a favorite P9 for
    /// S2. 590 bytes.
    static let frozenWallPreferencesWithStaleJSON = [
        #"{"aggregatedSessionIDs":["5E55100A-4A53-4F4E-8000-000000000021","#,
        #""5E55100B-4A53-4F4E-8000-000000000022","5E55100F-4A53-4F4E-8000-000000000029"],"#,
        #""coverPhotoIDsBySession":["5E55100A-4A53-4F4E-8000-000000000021","#,
        #""F0700002-4A53-4F4E-8000-000000000042","5E55100B-4A53-4F4E-8000-000000000022","#,
        #""F0700005-4A53-4F4E-8000-000000000045","5E55100F-4A53-4F4E-8000-000000000029","#,
        #""F0700001-4A53-4F4E-8000-000000000041"],"#,
        #""favoritePhotoIDsBySession":["5E55100A-4A53-4F4E-8000-000000000021","#,
        #""F0700003-4A53-4F4E-8000-000000000043","5E55100B-4A53-4F4E-8000-000000000022","#,
        #""F0700009-4A53-4F4E-8000-000000000049"]}"#
    ].joined()

    /// A manager over a root holding the frozen index and preferences loads the wall newest first and the
    /// preferences into its posts: S2's carousel (P5 its cover), S1's (P3, its favorite, over the P2
    /// cover entry), then P4 alone; five entries, one favorite; and, every entry live, init's prune
    /// writes nothing.
    @Test func theWallLoadsItsFrozenIndexAndPreferences() throws {
        let root = Self.scratchDirectory()
        let service = Self.throwawayService()
        defer {
            Self.sweep([service])
            Self.removeDirectory(root)
        }
        let preferences = root.appendingPathComponent("MeshPhotoWallPreferences.json")
        try Self.write(Self.frozenWallIndexJSON, to: root.appendingPathComponent("MeshPhotoCache.json"))
        try Self.write(Self.frozenWallPreferencesJSON, to: preferences)
        let store = makeTestStore(proximitySupportDirectory: root)
        let alice = try Self.plantedAlice(service: service)
        let manager = Self.meshManager(over: store, identity: alice)
        #expect(manager.meshPhotos == Self.wallNewestFirst, "the wall loaded \(manager.meshPhotos.map(\.id))")
        Self.expectWallPosts(of: manager)
        #expect(try Data(contentsOf: preferences) == Data(Self.frozenWallPreferencesJSON.utf8), "init rewrote live preferences")
        withExtendedLifetime(store) {}
    }

    /// Over the stale preferences init prunes all three stale entries and writes what is left, which is
    /// the clean preferences as a set and two dictionaries (``WallPreferencesShape``); the wall reads as
    /// the clean one does.
    @Test func theWallPrunesItsStalePreferencesAndWritesTheRest() throws {
        let root = Self.scratchDirectory()
        let service = Self.throwawayService()
        defer {
            Self.sweep([service])
            Self.removeDirectory(root)
        }
        let preferences = root.appendingPathComponent("MeshPhotoWallPreferences.json")
        try Self.write(Self.frozenWallIndexJSON, to: root.appendingPathComponent("MeshPhotoCache.json"))
        try Self.write(Self.frozenWallPreferencesWithStaleJSON, to: preferences)
        let store = makeTestStore(proximitySupportDirectory: root)
        let alice = try Self.plantedAlice(service: service)
        let manager = Self.meshManager(over: store, identity: alice)
        Self.expectWallPosts(of: manager)
        let written = try Self.wallPreferencesShape(Data(contentsOf: preferences))
        let frozen = try Self.wallPreferencesShape(Data(Self.frozenWallPreferencesJSON.utf8))
        #expect(written == frozen, "the prune wrote \(written)")
        withExtendedLifetime(store) {}
    }

    /// The mesh and its composition file every store they build under its frozen name directly inside
    /// the host's proximity root (the activity manager is the composition's since plan step A0.5.8, the
    /// photo stores the mesh's): over a root holding bob's ledger (every row long expired at the real
    /// clock), the wall index and the preferences, the composition rewrites `ActivityLedger.json` as the
    /// empty ledger, and the mesh reads `MeshPhotoCache.json` and reseals it as `MeshPhotoCache.sealed`
    /// beside `MeshPhotos/` and `MeshPhotoThumbnails/`, reads `MeshPhotoWallPreferences.json`, and holds
    /// a photo inside `PendingSessionPhotos/`; a wall store at the index path the mesh builds files a
    /// photo's bytes under `MeshPhotos/` and `MeshPhotoThumbnails/` by its id; and the pending corpus's
    /// names are frozen.
    @Test func theMeshFilesItsStoresUnderTheirFrozenNames() throws {
        #expect(Self.expectFrozen(Self.pendingCorpusNameRows) == 4)
        let root = Self.scratchDirectory()
        let service = Self.throwawayService()
        defer {
            Self.sweep([service])
            Self.removeDirectory(root)
        }
        try Self.write(Self.frozenActivityLedgerJSON, to: root.appendingPathComponent("ActivityLedger.json"))
        try Self.write(Self.frozenWallIndexJSON, to: root.appendingPathComponent("MeshPhotoCache.json"))
        try Self.write(Self.frozenWallPreferencesJSON, to: root.appendingPathComponent("MeshPhotoWallPreferences.json"))
        let store = makeTestStore(proximitySupportDirectory: root)
        let alice = try Self.plantedAlice(service: service)
        let features = Self.meshFeatures(over: store, identity: alice)
        let manager = features.mesh
        #expect(features.activities.hostedActivities.isEmpty && features.activities.joinedActivities.isEmpty)
        let ledger = try Data(contentsOf: root.appendingPathComponent("ActivityLedger.json"))
        #expect(try Self.jsonObjectsEqual(ledger, Data(Self.frozenActivityLedgerEmptyJSON.utf8)),
                "the mesh's activity ledger wrote \(String(decoding: ledger, as: UTF8.self))")
        #expect(manager.meshPhotos.count == 6 && Self.wallPreferenceEntryCount(manager) == 5)
        let held = FriendPhotoPayload(
            id: Self.pendingLocalID, imageData: MeshRoutedPhotoFixtures.tinyJPEG(),
            addedAt: Date(timeIntervalSinceReferenceDate: 780_000_000), senderName: "Bob",
            senderFingerprint: Self.bobFingerprint, senderSigningPublicKey: Self.bobSigningPub)
        #expect(Self.hold(held, on: manager) == .held, "the photo was not held")
        let wallRoot = Self.scratchDirectory()
        defer { Self.removeDirectory(wallRoot) }
        let p1 = FriendPhotoPayload(
            id: Self.uuid("F0700001-4A53-4F4E-8000-000000000041"), imageData: MeshRoutedPhotoFixtures.tinyJPEG(),
            addedAt: Date(timeIntervalSinceReferenceDate: 780_000_060), senderName: "Bob")
        Self.wallStore(indexedAt: wallRoot.appendingPathComponent("MeshPhotoCache.json")).save([p1])
        let present = [
            ("ActivityLedger.json", root), ("MeshPhotoCache.sealed", root), ("MeshPhotos/", root),
            ("MeshPhotoThumbnails/", root), ("MeshPhotoWallPreferences.json", root), ("PendingSessionPhotos/", root),
            ("PendingSessionPhotos/PendingSessionPhotoIndex.sealed", root),
            ("PendingSessionPhotos/Photos/F0700010-4A53-4F4E-8000-000000000050.jpg", root),
            ("PendingSessionPhotos/Thumbnails/F0700010-4A53-4F4E-8000-000000000050.jpg", root),
            ("MeshPhotos/F0700001-4A53-4F4E-8000-000000000041.jpg", wallRoot),
            ("MeshPhotoThumbnails/F0700001-4A53-4F4E-8000-000000000041.jpg", wallRoot)
        ]
        // R2: bounded by the eleven paths.
        for (path, base) in present {
            #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent(path).path),
                    "\(path) is not where the mesh files it")
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("MeshPhotoCache.json").path),
                "the legacy wall index outlived its reseal")
        withExtendedLifetime((features, store)) {}
    }

    // MARK: Group 24 — the keychain role that seals each photo corpus

    /// Which keychain role seals each photo corpus, and which role's key must not open it: the wall's
    /// index under the friend-wall role (`…contentKey`, the backup-restorable row) and a held photo under
    /// the pending-session-photos role (`…pendingContentKey`, born device-bound), as the manager picks
    /// each store's key provider at construction. FROZEN: a swap is invisible to every other cell, since
    /// one process seals and opens under the same wrong key, and on a device it would read the wall's
    /// index as unrecoverable and start the wall empty.
    static let photoCorpusSealRoles: [(corpus: String, sealedBy: KeychainPrivateMediaKeyProvider.Role,
                                       refusedBy: KeychainPrivateMediaKeyProvider.Role)] = [
        ("wallIndex", .friendWall, .pendingSessionPhotos),
        ("heldPhoto", .pendingSessionPhotos, .friendWall)
    ]

    /// A manager built over a root holding the legacy wall index (group 23's P1 to P6) reseals it as
    /// `MeshPhotoCache.sealed`. The friend-wall key opens the sealed index under the wall index's purpose
    /// to the six frozen entries, newest first, as values and as the wall's JSON; the
    /// pending-session-photos key, present in the keychain, does not open it. Over today's manager with
    /// the held corpus on its keychain row (`heldPhotoKeys` nil), so both providers are the ones
    /// production builds.
    @Test func theWallIndexIsSealedUnderTheFriendWallRoleAlone() throws {
        let row = try #require(Self.photoCorpusSealRoles.first { $0.corpus == "wallIndex" }, "the table holds no wall row")
        let root = Self.scratchDirectory()
        let service = Self.throwawayService()
        defer {
            Self.sweep([service])
            Self.removeDirectory(root)
        }
        try Self.write(Self.frozenWallIndexJSON, to: root.appendingPathComponent("MeshPhotoCache.json"))
        let store = makeTestStore(proximitySupportDirectory: root)
        let alice = try Self.plantedAlice(service: service)
        let manager = Self.meshManager(over: store, identity: alice)
        let sealedURL = root.appendingPathComponent("MeshPhotoCache.sealed")
        try #require(manager.meshPhotos.count == 6 && FileManager.default.fileExists(atPath: sealedURL.path),
                     "the wall loaded \(manager.meshPhotos.count) photos and resealed no index")
        let sealed = try Data(contentsOf: sealedURL)
        try #require(Self.hasMediaKey(for: row.refusedBy), "no \(row.refusedBy) key to refuse with")
        let opened = try #require(Self.openedAtRest(sealed, under: row.sealedBy, purpose: Self.wallIndexPurpose),
                                  "the \(row.sealedBy) key does not open the wall index")
        let entries = try Self.wallIndexDecoder().decode([FriendPhotoPayload].self, from: opened)
        #expect(entries == Self.wallNewestFirst, "the sealed index holds \(entries.map(\.id))")
        #expect(try Self.jsonObjectsEqual(opened, Data(Self.frozenWallIndexNewestFirstJSON.utf8)),
                "the sealed index is \(String(decoding: opened, as: UTF8.self))")
        #expect(Self.openedAtRest(sealed, under: row.refusedBy, purpose: Self.wallIndexPurpose) == nil,
                "the \(row.refusedBy) key opens the wall index")
        withExtendedLifetime((store, manager)) {}
    }

    /// A photo held for review through today's manager lands at the pending corpus's photo path sealed
    /// under the pending-session-photos key: that key opens `PendingSessionPhotos/Photos/<id>.jpg` under
    /// the held photo's purpose to the very JPEG held, and the friend-wall key, present in the keychain,
    /// does not open it. The path is group 23's layout vector, and the photo is the one its layout cell
    /// holds.
    @Test func aHeldPhotoIsSealedUnderThePendingSessionPhotosRoleAlone() throws {
        let row = try #require(Self.photoCorpusSealRoles.first { $0.corpus == "heldPhoto" }, "the table holds no held row")
        let root = Self.scratchDirectory()
        let service = Self.throwawayService()
        defer {
            Self.sweep([service])
            Self.removeDirectory(root)
        }
        let store = makeTestStore(proximitySupportDirectory: root)
        let alice = try Self.plantedAlice(service: service)
        let manager = Self.meshManager(over: store, identity: alice)
        let jpeg = MeshRoutedPhotoFixtures.tinyJPEG()
        let held = FriendPhotoPayload(
            id: Self.pendingLocalID, imageData: jpeg, addedAt: Date(timeIntervalSinceReferenceDate: 780_000_000),
            senderName: "Bob", senderFingerprint: Self.bobFingerprint, senderSigningPublicKey: Self.bobSigningPub)
        try #require(Self.hold(held, on: manager) == .held, "the photo was not held")
        let stored = try Data(contentsOf: root.appendingPathComponent(
            "PendingSessionPhotos/Photos/F0700010-4A53-4F4E-8000-000000000050.jpg"))
        try #require(Self.hasMediaKey(for: row.refusedBy), "no \(row.refusedBy) key to refuse with")
        let opened = Self.openedAtRest(stored, under: row.sealedBy, purpose: Self.heldPhotoImagePurpose)
        #expect(opened == jpeg,
                "the \(row.sealedBy) key opens the held photo to \(opened.map { Self.hex($0.prefix(16)) } ?? "nothing")")
        #expect(Self.openedAtRest(stored, under: row.refusedBy, purpose: Self.heldPhotoImagePurpose) == nil,
                "the \(row.refusedBy) key opens the held photo")
        withExtendedLifetime((store, manager)) {}
    }

    // MARK: Group 25 — the vouch list's two-hour lifetime and its label

    /// The vouch list's lifetime, written as the code writes it at both of its sites and never read from
    /// a constant: the expiry the send stamps and the cap the receive applies.
    static let vouchListLifetimeSeconds: TimeInterval = 2 * 3600

    /// The label's frozen English prefix, which the camera shows before the voucher's name for a friend
    /// that a cached, unexpired vouch list names.
    static let vouchLabelPrefix = "Friend of "

    /// With the broadcast gate forced on, the list a manager over planted alice would send names alice
    /// and her one kept friend, bob, and expires two hours after it is built: no earlier than two hours
    /// after the instant before the build, and no later than two hours after the instant after it.
    @Test func theSentVouchListExpiresTwoHoursAfterItIsBuilt() throws {
        let root = Self.scratchDirectory()
        let service = Self.throwawayService()
        defer {
            Self.sweep([service])
            Self.removeDirectory(root)
        }
        let store = makeTestStore(proximitySupportDirectory: root)
        let alice = try Self.plantedAlice(service: service)
        let features = Self.meshFeatures(over: store, identity: alice)
        Self.keep(Self.bobPeerIdentity(id: UUID(), capabilities: nil), in: store)
        let lifetime = Self.vouchListLifetimeSeconds
        let before = Date()
        let sent = try #require(Self.vouchListToSend(on: features), "the forced-on gate built no list")
        let after = Date()
        #expect(sent.expiresAt >= before.addingTimeInterval(lifetime)
                    && sent.expiresAt <= after.addingTimeInterval(lifetime),
                "the list built between \(before) and \(after) expires at \(sent.expiresAt)")
        #expect(sent.voucherFingerprint == Self.aliceFingerprint && sent.trustedFingerprints == [Self.bobFingerprint],
                "the list vouches as \(sent.voucherFingerprint) for \(sent.trustedFingerprints)")
        withExtendedLifetime((store, features)) {}
    }

    /// Received from bob with the gate forced on, a list claiming ten hours is cached until two hours
    /// after its receipt, and a later one claiming one hour keeps its own expiry: the cap is a ceiling
    /// (`min`). While cached, the list labels the friend it names with the frozen prefix and bob's name,
    /// and labels no one else.
    @Test func aReceivedVouchListIsCappedAtTwoHoursAndLabelsTheFriendItNames() throws {
        let root = Self.scratchDirectory()
        let service = Self.throwawayService()
        defer {
            Self.sweep([service])
            Self.removeDirectory(root)
        }
        let store = makeTestStore(proximitySupportDirectory: root)
        let alice = try Self.plantedAlice(service: service)
        let features = Self.meshFeatures(over: store, identity: alice)
        let lifetime = Self.vouchListLifetimeSeconds
        let before = Date()
        let tenHours = Self.bobVouchList(expiresAt: before.addingTimeInterval(10 * 3600))
        let capped = try #require(Self.receiveVouchList(tenHours, from: Self.bobFingerprint, on: features),
                                  "bob's ten-hour list was not cached")
        let after = Date()
        #expect(capped.expiresAt >= before.addingTimeInterval(lifetime)
                    && capped.expiresAt <= after.addingTimeInterval(lifetime),
                "a ten-hour claim received between \(before) and \(after) is cached until \(capped.expiresAt)")
        let oneHour = Date().addingTimeInterval(3_600)
        let kept = try #require(Self.receiveVouchList(Self.bobVouchList(expiresAt: oneHour), from: Self.bobFingerprint,
                                                      on: features), "bob's one-hour list was not cached")
        #expect(kept.expiresAt == oneHour, "a one-hour claim is cached until \(kept.expiresAt), not \(oneHour)")
        let label = Self.vouchLabel(for: Self.carolFingerprint, on: features)
        #expect(label == Self.vouchLabelPrefix + "Bob", "carol is labelled \(String(describing: label))")
        let stranger = Self.vouchLabel(for: Self.strangerFingerprint, on: features)
        #expect(stranger == nil, "a friend no list names is labelled \(String(describing: stranger))")
        withExtendedLifetime((store, features)) {}
    }

    // MARK: Group 26 — the item report and the friend state sent at a commit

    /// alice's own two rows, M1 and M2, go to bob at his commit (he advertises `moderation` and
    /// `friendState` and no wire2, and is a kept friend) under the item report's token, sealed to his
    /// key-agreement key in the legacy framing. Every key of the report bob opens but the rows'
    /// signatures is group 20's frozen report: its format, its version and each row's entry object. The
    /// relay, verifying the rows against alice's key an hour after the retraction, keeps both.
    /// **Signatures are never compared**: the relay re-signs through CryptoKit's Ed25519, which is
    /// randomized, so group 19's frozen M1 and M2 signatures are verify-side pins only.
    @Test func theCommitSealsAlicesOwnReportsToBobInTheLegacyFraming() async throws {
        let report = try await Self.reportAndStateSentOnCommit().report
        #expect(report.envelope.payloadEncryption == .sealedTo(recipientKeyAgreementPublicKey: Self.bobPub),
                "the report was sent \(report.envelope.payloadEncryption)")
        #expect(!SealedPayloadFraming.hasFrameTag(report.body),
                "the report was framed for wire2: \(Self.hex(report.body.prefix(8)))")
        let sent = try Self.reportWithoutSignatures(report.body)
        let frozen = try Self.reportWithoutSignatures(Data(Self.frozenReportPayloadJSON.utf8))
        #expect(sent.isEqual(frozen), "bob opened the report \(String(decoding: report.body, as: UTF8.self))")
        let payload = try Self.meshPayloadDecoder().decode(ReportBundle.self, from: report.body)
        let now = Date(timeIntervalSinceReferenceDate: 780_007_200)
        let kept = Self.moderationRows(from: payload, sender: Self.aliceSigningPub, now: now)
        #expect(kept == [Self.moderationReport, Self.moderationRetract], "the relay kept \(kept) of the sent report")
    }

    /// The friend-state fixture goes to bob at his commit under the friend state's token, sealed to his
    /// key-agreement key in the legacy framing, and bob's open decodes to it exactly: the engine's own
    /// encoder over the payload whose field names `CompanionEmotionPrivacyTests.theFriendFoldIsUnchanged`
    /// pins.
    @Test func theCommitSealsTheFriendStateToBobInTheLegacyFraming() async throws {
        let state = try await Self.reportAndStateSentOnCommit().state
        #expect(state.envelope.payloadEncryption == .sealedTo(recipientKeyAgreementPublicKey: Self.bobPub),
                "the friend state was sent \(state.envelope.payloadEncryption)")
        #expect(!SealedPayloadFraming.hasFrameTag(state.body),
                "the friend state was framed for wire2: \(Self.hex(state.body.prefix(8)))")
        let decoded = try Self.meshPayloadDecoder().decode(FriendStatePayload.self, from: state.body)
        #expect(decoded == Self.friendStateFixture,
                "bob opened the friend state \(String(decoding: state.body, as: UTF8.self))")
    }

    // MARK: Group 27 — the camera's hold-failure line

    /// The camera's hold-failure line's key, as its copy vault spells it today and ProximityKit's catalog
    /// files it (Localizable.xcstrings): what the catalog is looked up by, never translated.
    static let cameraHoldFailedKey = "proximity.camera.holdFailed"

    /// Its English default (the catalog's `en` value), which every locale shows while the catalog holds
    /// English alone.
    static let cameraHoldFailedDefault = "Couldn't keep that photo. Try again."

    /// The comment its translators read (the catalog's `comment`).
    static let cameraHoldFailedComment = [
        "Alert on the in-person camera when a photo just taken could not be saved securely on this phone. ",
        "No film was used and nothing was shared."
    ].joined()

    /// The line resolves to its frozen English; the copy vault asks its own module's bundle for exactly
    /// the frozen key with the frozen default and comment; and the catalog beside it files the key with
    /// the frozen comment and the frozen English value. A move that dropped the catalog entry or re-keyed
    /// the vault would still render the default, untranslatable and silent, which is why the key and the
    /// comment are pinned at their source. Re-pointed at A0.5.11, when the line moves to
    /// `FernletSocialCopy` and FernletSocial's catalog.
    @Test func theCamerasHoldFailureLineKeepsItsKeyDefaultAndComment() throws {
        let resolved = Self.cameraHoldFailedLine
        #expect(resolved == Self.cameraHoldFailedDefault, "the hold-failure line resolves to \(resolved)")
        let declaration = "String(localized: \"\(Self.cameraHoldFailedKey)\", "
            + "defaultValue: \"\(Self.cameraHoldFailedDefault)\", bundle: .module, "
            + "comment: \"\(Self.cameraHoldFailedComment)\")"
        let vault = try Self.collapsingWhitespace(RepoRoot.source(Self.cameraCopyVaultPath))
        #expect(vault.contains(declaration), "\(Self.cameraCopyVaultPath) declares no \(declaration)")
        let entry = try Self.catalogEntry(Self.cameraHoldFailedKey, in: Self.cameraCopyCatalogPath)
        #expect(entry.comment == Self.cameraHoldFailedComment, "the catalog's comment is \(entry.comment ?? "absent")")
        #expect(entry.english == Self.cameraHoldFailedDefault, "the catalog's English is \(entry.english ?? "absent")")
    }

    // MARK: Group 28 — the audit lines the moved code writes

    /// The relay names a payload's refused rows in one line of counts, never a key or a fingerprint: of
    /// alice's own report, signed by the relay's own builder, and a row claiming bob as its reporter
    /// (refused one hop before its signature is read), it keeps one of two; the bundle without the forged
    /// row keeps both and writes nothing.
    @Test func theRelayCountsTheRowsItRefusesInOneLine() throws {
        let service = Self.throwawayService()
        defer { Self.sweep([service]) }
        let alice = try Self.plantedAlice(service: service)
        let aliceKey = Self.aliceSigningPub
        let bobKey = Self.bobSigningPub
        let signed = Self.signedReportBundle(of: [Self.reportRow(reporter: aliceKey, subject: bobKey)], by: alice)
        try #require(signed.reports.count == 1, "the relay's builder signed \(signed.reports.count) rows")
        let forged = SignedReport(entry: Self.reportRow(reporter: bobKey, subject: aliceKey),
                                  signature: Data(repeating: 0, count: 64))
        let bundle = ReportBundle(reports: signed.reports + [forged])
        let now = Date(timeIntervalSinceReferenceDate: 780_003_600)
        let whole = MovedAuditLines.delivered { _ = Self.moderationRows(from: signed, sender: aliceKey, now: now) }
        #expect(Self.movedLines(whole).isEmpty, "a bundle kept whole wrote \(whole)")
        let refused = MovedAuditLines.delivered { _ = Self.moderationRows(from: bundle, sender: aliceKey, now: now) }
        #expect(Self.movedLines(refused) == [Self.auditLine("moderation.relay.rowsRejected",
                                                             ["received": "2", "kept": "1"])],
                "the refused row was named as \(refused)")
    }

    /// The activity host names each signature it could not make: over the ledger planted alice wrote
    /// after hosting an activity and admitting bob, a manager whose identity was never provisioned can
    /// neither re-sign the roster that removes bob nor re-mint the grant bob asks for again, and says so
    /// once each with the identity's own error, `notProvisioned`.
    @Test func theActivityHostNamesTheSignaturesItCouldNotMake() throws {
        let host = MockPresenceQUICHost()
        let root = Self.scratchDirectory()
        let services = [Self.throwawayService(), Self.throwawayService()]
        defer {
            Self.sweep(services)
            Self.removeDirectory(root)
        }
        let alice = try Self.plantedAlice(service: services[0])
        let ledger = Self.activityLedgerFile(in: root)
        let hosting = Self.activityManager(host: host, identity: alice, fileURL: ledger, clock: Self.auditClock)
        let walk = try #require(hosting.host(title: "Walk", activityTypeToken: "walk", coarseLocation: nil,
                                             expiresAt: Self.auditClock.addingTimeInterval(3_600)),
                                "alice could not host")
        let request = Self.bobsJoinRequest(for: walk.activityID)
        Self.receiveFromBob(request, on: hosting)
        let pending = try #require(hosting.pendingJoinRequests.first, "bob's request was not queued")
        hosting.admitJoin(pending)
        let unsigned = Self.activityManager(
            host: host, identity: IdentityService(namespace: .fernlet, keychainService: services[1]),
            fileURL: ledger, clock: Self.auditClock)
        try #require(unsigned.hostedActivities.first?.participants.count == 2, "the relaunch holds no roster of two")
        let removal = MovedAuditLines.delivered {
            unsigned.removeParticipant(activityID: walk.activityID, fingerprint: Self.bobFingerprint)
        }
        #expect(Self.movedLines(removal) == [Self.auditLine("activity.removeParticipant.signFailed",
                                                             ["error": "notProvisioned"])],
                "the unsigned removal wrote \(removal)")
        let regrant = MovedAuditLines.delivered { Self.receiveFromBob(request, on: unsigned) }
        #expect(Self.movedLines(regrant) == [Self.auditLine("activity.regrant.signFailed", ["error": "notProvisioned"])],
                "the unsigned re-grant wrote \(regrant)")
    }

    /// The JSON sidecar names each failed save by the file's last path component and the error's
    /// description, one token per stage: a state whose encoding throws (only a probe's can; no store's
    /// does) is `sidecar.encodeFailed` with the planted error, a parent path that is a file is
    /// `sidecar.createDirectoryFailed`, and a file path that is a directory is `sidecar.saveFailed`. The
    /// system's error text is not pinned; its key is.
    @Test func theSidecarNamesEachFailedSaveByFileAndError() throws {
        let root = Self.scratchDirectory()
        defer { Self.removeDirectory(root) }
        let file = "SidecarProbe.json"
        try Self.write("a file where a folder belongs", to: root.appendingPathComponent("Blocker"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Occupied/\(file)/Inside"),
                                                withIntermediateDirectories: true)
        let encode = MovedAuditLines.delivered {
            Self.saveSidecar(UnencodableSidecarProbe(), to: root.appendingPathComponent(file))
        }
        #expect(Self.movedLines(encode) == [Self.auditLine("sidecar.encodeFailed", ["file": file, "error": "encode"])],
                "the unencodable save wrote \(encode)")
        let stages: [(token: String, fileURL: URL)] = [
            ("sidecar.createDirectoryFailed", root.appendingPathComponent("Blocker/\(file)")),
            ("sidecar.saveFailed", root.appendingPathComponent("Occupied/\(file)"))
        ]
        // R2: bounded by the two staged failures.
        for stage in stages {
            let lines = Self.movedLines(MovedAuditLines.delivered { Self.saveSidecar(SidecarProbe(), to: stage.fileURL) })
            let context = lines.first?.context ?? [:]
            #expect(lines.map(\.event) == [stage.token], "\(stage.token): the save wrote \(lines)")
            #expect(context["file"] == file && Set(context.keys) == ["file", "error"] && !(context["error"] ?? "").isEmpty,
                    "\(stage.token)'s context is \(context)")
        }
    }

    /// The heart ledger's sidecar names its four reachable failures under the `heartledger` prefix the
    /// moved initializer hands `ProtectedSidecar`, which it gives no seal and no salvage: a read that
    /// throws defers the load (`reason` `read`), a mutation of the ledger that never loaded is refused
    /// inside the retry floor, a write that throws is named with its error, and a file that is not JSON
    /// is discarded whole.
    @Test func theHeartLedgerNamesItsReachableFailuresUnderItsPrefix() throws {
        let root = Self.scratchDirectory()
        defer { Self.removeDirectory(root) }
        let unreadable = Self.heartLedgerFile(in: root.appendingPathComponent("Unreadable", isDirectory: true))
        let corrupt = Self.heartLedgerFile(in: root.appendingPathComponent("Corrupt", isDirectory: true))
        try Self.write("{}", to: unreadable)
        try Self.write("not json", to: corrupt)
        var deferred: ProximityHeartLedger?
        let load = MovedAuditLines.delivered {
            deferred = Self.heartLedger(fileURL: unreadable, clock: Self.auditClock,
                                        reading: { _ in throw PlantedFileFailure.read }, writing: nil)
        }
        #expect(Self.movedLines(load) == [Self.auditLine("heartledger.readDeferred", ["reason": "read"])],
                "the throwing read wrote \(load)")
        let refused = MovedAuditLines.delivered { deferred?.recordHeartSent(to: Self.bobFingerprint) }
        #expect(Self.movedLines(refused) == [Self.auditLine("heartledger.mutateRefused")],
                "the unloaded ledger's mutation wrote \(refused)")
        let failing = Self.heartLedger(fileURL: Self.heartLedgerFile(in: root), clock: Self.auditClock,
                                       reading: nil, writing: { _, _ in throw PlantedFileFailure.write })
        let write = MovedAuditLines.delivered { failing.recordHeartSent(to: Self.bobFingerprint) }
        #expect(Self.movedLines(write) == [Self.auditLine("heartledger.writeFailed", ["error": "write"])],
                "the throwing write wrote \(write)")
        let discard = MovedAuditLines.delivered {
            _ = Self.heartLedger(fileURL: corrupt, clock: Self.auditClock, reading: nil, writing: nil)
        }
        #expect(Self.movedLines(discard) == [Self.auditLine("heartledger.corrupt", ["salvaged": "0", "lost": "all"])],
                "the undecodable file wrote \(discard)")
    }

    /// A feature frame from a committed slot whose sender the transport never verified is dropped in one
    /// bare line for each of the clothing catalog, the catalog request and the item report; friend state
    /// drops the same frame silently, as it always has.
    @Test func aFeatureFrameFromAnUnverifiedSenderIsDroppedInOneBareLine() throws {
        let rig = try AuditMeshRig()
        defer { rig.tearDown() }
        let rows: [(type: PayloadType, expected: [MovedAuditLines.Line])] = [
            (.clothingCatalog, [Self.auditLine("mesh.clothingCatalog.droppedUnverifiedSender")]),
            (.clothingCatalogRequest, [Self.auditLine("mesh.clothingCatalogRequest.droppedUnverifiedSender")]),
            (.itemReport, [Self.auditLine("mesh.itemReport.droppedUnverifiedSender")]),
            (.friendState, [])
        ]
        // R2: bounded by the four payloads.
        for row in rows {
            let lines = MovedAuditLines.delivered {
                Self.deliverUnverified(row.type, to: rig.manager, coordinatorIdentity: rig.alice)
            }
            #expect(Self.movedLines(lines) == row.expected, "\(row.type.rawValue) from an unverified sender wrote \(lines)")
        }
    }

    /// A session heart that is not sent says why in one line whose `reason` is its frozen cause, in the
    /// order the sender reads its gates: hearts off, no ledger wired, nobody to address (no mesh, so the
    /// origination skips), a claim already in flight, and a send inside the five-minute cooldown.
    @Test func aSessionHeartThatIsNotSentSaysWhyInOneLine() throws {
        let rig = try AuditMeshRig()
        defer { rig.tearDown() }
        let ledgerRoot = rig.root.appendingPathComponent("Hearts", isDirectory: true)
        let ledger = Self.heartLedger(fileURL: Self.heartLedgerFile(in: ledgerRoot), clock: Self.auditClock,
                                      reading: nil, writing: nil)
        let bob = Self.bobAsFriend
        let rows: [(reason: String, arrange: () -> Void)] = [
            ("heartsOff", { Self.allowNearbyHearts(false, in: rig.store) }),
            ("ledgerUnavailable", { Self.allowNearbyHearts(true, in: rig.store) }),
            ("recipientLeft", { Self.wireHeartLedger(ledger, into: rig.features.hearts) }),
            ("alreadySending", { Self.claimSessionHeart(for: bob.fingerprint, on: rig.features.hearts) }),
            ("cooldown", { ledger.recordHeartSent(to: bob.fingerprint) })
        ]
        // R2: bounded by the five causes.
        for row in rows {
            row.arrange()
            let lines = MovedAuditLines.delivered { Self.sendSessionHeart(to: bob, from: rig.features.hearts) }
            #expect(Self.movedLines(lines) == [Self.auditLine("mesh.routedHeart.sendFailed", ["reason": row.reason])],
                    "the \(row.reason) refusal wrote \(lines)")
        }
    }

    /// A chat message the age gate stops is audited bare, and one the wire's byte bound cuts is audited
    /// with what it was before the cut, 500 Characters and 15 500 bytes; with no mesh the cut message
    /// then reaches nobody, which writes no moved line.
    @Test func aStoppedOrCutChatMessageIsAudited() throws {
        let rig = try AuditMeshRig()
        defer { rig.tearDown() }
        var outcome = MeshTextSendOutcome.empty
        let gated = MovedAuditLines.delivered { outcome = Self.sendChat("hello", from: rig.features.chat) }
        #expect(outcome == .ageGated, "the age gate answered \(outcome)")
        #expect(Self.movedLines(gated) == [Self.auditLine("mesh.routedShare.textBlockedAgeGated")],
                "the gated message wrote \(gated)")
        Self.allowChat(on: rig.features.chat)
        let cut = MovedAuditLines.delivered { outcome = Self.sendChat(Self.overlongChatDraft, from: rig.features.chat) }
        #expect(outcome == .noDestinations, "the cut message answered \(outcome)")
        #expect(Self.movedLines(cut) == [Self.auditLine("mesh.routedShare.textByteBounded",
                                                         ["characters": "500", "bytes": "15500"])],
                "the cut message wrote \(cut)")
    }

    /// The incoming per-origin text quota names both refusals bare: the message past the cap from one
    /// origin in one mesh, and a new origin once the map holds its bound of keys.
    @Test func theIncomingTextQuotaNamesBothRefusals() throws {
        let rig = try AuditMeshRig()
        defer { rig.tearDown() }
        let manifest = Self.quotaManifest(origin: "ffgt-quota-origin")
        // R2: bounded by the quota's own cap.
        for _ in 0..<Self.textQuotaCap {
            _ = Self.textQuotaAdmits(UUID(), from: manifest, on: rig.features.chat)
        }
        let spent = MovedAuditLines.delivered { _ = Self.textQuotaAdmits(UUID(), from: manifest, on: rig.features.chat) }
        #expect(Self.movedLines(spent) == [Self.auditLine("mesh.routedProjection.textQuotaSpent")],
                "the message past the cap wrote \(spent)")
        // R2: bounded by the map's key bound; the first origin already holds one key.
        for index in 1..<Self.textQuotaKeyBound {
            _ = Self.textQuotaAdmits(UUID(), from: Self.quotaManifest(origin: "ffgt-bulk-\(index)"), on: rig.features.chat)
        }
        let full = MovedAuditLines.delivered {
            _ = Self.textQuotaAdmits(UUID(), from: Self.quotaManifest(origin: "ffgt-one-too-many"), on: rig.features.chat)
        }
        #expect(Self.movedLines(full) == [Self.auditLine("mesh.routedProjection.textQuotaMapFull")],
                "the origin past the map's bound wrote \(full)")
    }

    /// The transcript store's three answers are frozen tokens. The two refusals are the `reason` of
    /// `mesh.routedProjection.transcriptRefused`, a line only a second device's sealed item reaches, so
    /// their spellings are pinned here in its stead.
    @Test func theTranscriptRefusalReasonsAreFrozenTokens() {
        #expect(Self.transcriptAcceptanceTokens == ["appended", "alreadyHeld", "emptyAfterSanitizing"],
                "the transcript store answers \(Self.transcriptAcceptanceTokens)")
    }

    /// Each hold and delete names its outcome, on a manager whose routed gate is still closed: a held
    /// photo awaits (`pending` the batch's count), a second origin reusing its id is held under a fresh
    /// local id after a bare collision line, a held photo cannot be deleted from the wall, and a hold of
    /// bytes no image reader can read, or under a key taken away, is refused with its frozen outcome
    /// token.
    @Test func eachHoldAndDeleteOfAHeldPhotoNamesItsOutcome() throws {
        let rig = try AuditMeshRig()
        defer { rig.tearDown() }
        let first = Self.heldPhoto(origin: "ffgt-origin-a")
        let rows: [(what: String, act: () -> Void, expected: [MovedAuditLines.Line])] = [
            ("a held photo", { _ = Self.hold(first, on: rig.manager) },
             [Self.auditLine("mesh.heldPhotos.heldAwaiting", ["pending": "1"])]),
            ("a reused id", { _ = Self.hold(Self.heldPhoto(id: first.id, origin: "ffgt-origin-b"), on: rig.manager) },
             [Self.auditLine("mesh.heldPhotos.idCollision"), Self.auditLine("mesh.heldPhotos.heldAwaiting", ["pending": "2"])]),
            ("a held photo's delete", { Self.deleteWallPhoto(first.id, on: rig.manager) },
             [Self.auditLine("mesh.heldPhotos.deleteRefused")]),
            ("unreadable bytes", { _ = Self.hold(Self.unreadableImagePhoto(origin: "ffgt-origin-c"), on: rig.manager) },
             [Self.auditLine("mesh.heldPhotos.holdRefused", ["reason": "unsafeImage"])]),
            ("no key", {
                rig.keys.available = false
                _ = Self.hold(Self.heldPhoto(origin: "ffgt-origin-d"), on: rig.manager)
            }, [Self.auditLine("mesh.heldPhotos.holdRefused", ["reason": "notPersisted"])])
        ]
        // R2: bounded by the five rows.
        for row in rows {
            let lines = MovedAuditLines.delivered { row.act() }
            #expect(Self.movedLines(lines) == row.expected, "\(row.what) wrote \(lines)")
        }
    }

    /// A session's ending and the answers given while the routed gate is closed name what they moved and
    /// why nothing applied: the ending moves the live photo into the review, each review's answer meets
    /// the closed gate, the Develop review's then names the pending photo it answered and the session-end
    /// review's its five counts, and delete-all's purge reports the corpus gone.
    @Test func anEndingAndItsAnswersBehindAClosedGateNameWhatTheyDid() throws {
        let rig = try AuditMeshRig()
        defer { rig.tearDown() }
        let photo = Self.heldPhoto(origin: "ffgt-origin-live")
        let held = MovedAuditLines.delivered { _ = Self.holdLive(photo, on: rig.manager) }
        #expect(Self.movedLines(held).isEmpty, "a live hold wrote \(held)")
        let ending = MovedAuditLines.delivered { Self.endSession(rig.manager) }
        #expect(Self.movedLines(ending) == [Self.auditLine("mesh.session.photosPendingReview", ["moved": "1", "pending": "1"])],
                "the ending wrote \(ending)")
        let batch = try #require(Self.pendingReview(on: rig.manager), "the ending offered no review")
        let closed = Self.auditLine("mesh.heldPhotos.answerRefused", ["reason": "gateClosed"])
        let develop = MovedAuditLines.delivered {
            _ = Self.answerDevelop(showing: [photo.id], keeping: [], on: rig.manager)
        }
        #expect(Self.movedLines(develop) == [closed, Self.auditLine("mesh.session.developAnsweredPendingPhotos", ["answered": "1"])],
                "the Develop review's answer wrote \(develop)")
        let review = MovedAuditLines.delivered {
            _ = Self.answerReview(showing: [photo.id], keeping: [], in: batch.id, on: rig.manager)
        }
        #expect(Self.movedLines(review) == [closed, Self.reviewAnswered(kept: 0, discarded: 0, unreadable: 0,
                                                                        notApplied: 1, stillPending: 1)],
                "the session-end review's answer wrote \(review)")
        let purge = MovedAuditLines.delivered { _ = Self.purgeHeldPhotos(on: rig.manager) }
        #expect(Self.movedLines(purge) == [Self.auditLine("mesh.heldPhotos.purgedForDeleteAll", ["purged": "true"])],
                "delete-all's purge wrote \(purge)")
    }

    /// With the routed gate open, a keep names what it could not land and an answer what it could not
    /// persist, each before the review's counts: a ticked photo whose bytes do not open, one whose key is
    /// gone right now (`unavailable` 1), and a discard whose index write has no key; under a duress gate
    /// a hold is refused.
    @Test func anOpenGatesAnswersNameWhatTheyCouldNotLandOrPersist() throws {
        let rig = try AuditMeshRig()
        defer { rig.tearDown() }
        let gone = Self.heldPhoto(origin: "ffgt-origin-gone")
        let locked = Self.heldPhoto(origin: "ffgt-origin-locked")
        try #require(Self.hold(gone, on: rig.manager) == .held, "the photo whose bytes will not open was not held")
        try #require(Self.hold(locked, on: rig.manager) == .held, "the photo whose key will go was not held")
        Self.openRoutedGate(on: rig.manager)
        try Data("FMA2 corrupt".utf8).write(to: Self.heldImageFile(in: rig.store, localID: gone.id))
        let batch = try #require(Self.pendingReview(on: rig.manager), "the holds offered no review")
        let unopened = MovedAuditLines.delivered {
            _ = Self.answerReview(showing: [gone.id], keeping: [gone.id], in: batch.id, on: rig.manager)
        }
        #expect(Self.movedLines(unopened) == [
            Self.auditLine("mesh.heldPhotos.unreadableAtKeep", ["count": "1"]),
            Self.reviewAnswered(kept: 0, discarded: 0, unreadable: 1, notApplied: 0, stillPending: 1)
        ], "the keep of bytes that do not open wrote \(unopened)")
        rig.keys.available = false
        let keyless = MovedAuditLines.delivered {
            _ = Self.answerReview(showing: [locked.id], keeping: [locked.id], in: batch.id, on: rig.manager)
        }
        #expect(Self.movedLines(keyless) == [
            Self.auditLine("mesh.heldPhotos.keepNotLanded", ["count": "1", "unavailable": "1"]),
            Self.reviewAnswered(kept: 0, discarded: 0, unreadable: 0, notApplied: 1, stillPending: 1)
        ], "the keep with no key wrote \(keyless)")
        let unwritten = MovedAuditLines.delivered {
            _ = Self.answerReview(showing: [locked.id], keeping: [], in: batch.id, on: rig.manager)
        }
        #expect(Self.movedLines(unwritten) == [
            Self.auditLine("mesh.heldPhotos.answerNotPersisted", ["count": "1"]),
            Self.reviewAnswered(kept: 0, discarded: 1, unreadable: 0, notApplied: 0, stillPending: 0)
        ], "the discard with no key wrote \(unwritten)")
        rig.keys.available = true
        Self.pushDuressGate(on: rig.manager)
        let duress = MovedAuditLines.delivered { _ = Self.hold(Self.heldPhoto(origin: "ffgt-origin-duress"), on: rig.manager) }
        #expect(Self.movedLines(duress) == [Self.auditLine("mesh.heldPhotos.holdRefused", ["reason": "duress"])],
                "the hold under duress wrote \(duress)")
    }

    /// A relaunch over the held corpus names what its load found: under the same key every held photo is
    /// offered again; under the key taken away the index is deferred, which a launch does not name, and a
    /// hold and an answer are then refused with `pendingIndexDeferred`; under another present key the
    /// index cannot open and the corpus is purged.
    @Test func aRelaunchOverTheHeldCorpusNamesWhatItsLoadFound() throws {
        let rig = try AuditMeshRig()
        defer { rig.tearDown() }
        let photo = Self.heldPhoto(origin: "ffgt-origin-kept")
        try #require(Self.hold(photo, on: rig.manager) == .held, "the photo was not held")
        var relaunch: MeshNetworkManager?
        let offered = MovedAuditLines.delivered { relaunch = rig.relaunched(keys: rig.keys) }
        #expect(Self.movedLines(offered) == [Self.auditLine("mesh.heldPhotos.offeredFromIndex", ["photos": "1"])],
                "the relaunch under the same key wrote \(offered)")
        rig.keys.available = false
        let deferring = MovedAuditLines.delivered { relaunch = rig.relaunched(keys: rig.keys) }
        #expect(Self.movedLines(deferring).isEmpty, "the relaunch with no key wrote \(deferring)")
        let locked = try #require(relaunch)
        let hold = MovedAuditLines.delivered { _ = Self.hold(Self.heldPhoto(origin: "ffgt-origin-late"), on: locked) }
        #expect(Self.movedLines(hold) == [Self.auditLine("mesh.heldPhotos.holdRefused", ["reason": "pendingIndexDeferred"])],
                "the hold over a deferred index wrote \(hold)")
        Self.openRoutedGate(on: locked)
        let answer = MovedAuditLines.delivered { _ = Self.applyPhotoAnswers(kept: [], discarded: [photo.id], on: locked) }
        #expect(Self.movedLines(answer) == [Self.auditLine("mesh.heldPhotos.answerRefused", ["reason": "pendingIndexDeferred"])],
                "the answer over a deferred index wrote \(answer)")
        rig.keys.available = true
        let purged = MovedAuditLines.delivered { relaunch = rig.relaunched(keys: SwitchableMediaKeyProvider()) }
        #expect(Self.movedLines(purged) == [Self.auditLine("mesh.heldPhotos.indexUnrecoverable", ["purged": "true"])],
                "the relaunch under another key wrote \(purged)")
    }

    /// A wall whose sealed index cannot be read names how the review copes and how it recovers: with
    /// protected data available the held photo is offered over the unreadable wall, a keep is refused,
    /// and once the wall reads again the next answer names the recovery (nothing was on the wall) before
    /// it applies.
    @Test func anUnreadableWallNamesHowTheReviewCopesAndRecovers() throws {
        let rig = try AuditMeshRig()
        defer { rig.tearDown() }
        let photo = Self.heldPhoto(origin: "ffgt-origin-wall")
        try #require(Self.hold(photo, on: rig.manager) == .held, "the photo was not held")
        let aside = try Self.makeWallUnreadable(rig.store)
        let relaunched = rig.relaunched(keys: rig.keys)
        let offered = MovedAuditLines.delivered { Self.openRoutedGate(on: relaunched) }
        #expect(Self.movedLines(offered) == [Self.auditLine("mesh.heldPhotos.offeredOverUnreadableWall"),
                                             Self.auditLine("mesh.heldPhotos.offeredFromIndex", ["photos": "1"])],
                "the unlock over an unreadable wall wrote \(offered)")
        let batch = try #require(Self.pendingReview(on: relaunched), "nothing was offered over the unreadable wall")
        let keep = MovedAuditLines.delivered {
            _ = Self.answerReview(showing: [photo.id], keeping: [photo.id], in: batch.id, on: relaunched)
        }
        #expect(Self.movedLines(keep) == [
            Self.auditLine("mesh.heldPhotos.keepRefused", ["reason": "wallDeferred"]),
            Self.reviewAnswered(kept: 0, discarded: 0, unreadable: 0, notApplied: 1, stillPending: 1)
        ], "the keep over an unreadable wall wrote \(keep)")
        try Self.restoreWall(rig.store, aside: aside)
        let recovered = MovedAuditLines.delivered {
            _ = Self.answerReview(showing: [photo.id], keeping: [], in: batch.id, on: relaunched)
        }
        #expect(Self.movedLines(recovered) == [
            Self.auditLine("mesh.photoIndex.recoveredAfterDeferral", ["photos": "0"]),
            Self.reviewAnswered(kept: 0, discarded: 1, unreadable: 0, notApplied: 0, stillPending: 0)
        ], "the answer after the wall read again wrote \(recovered)")
    }

    /// A wall index that is not the wall's JSON is unrecoverable at the manager's launch, said bare:
    /// nothing brings those entries back, so the wall starts empty.
    @Test func anUnrecoverableWallIndexIsNamedAtLaunch() throws {
        let rig = try AuditMeshRig()
        defer { rig.tearDown() }
        try Self.write("not a wall index", to: Self.legacyWallIndex(in: rig.root))
        let launch = MovedAuditLines.delivered { _ = rig.relaunched(keys: rig.keys) }
        #expect(Self.movedLines(launch) == [Self.auditLine("mesh.photoIndex.unrecoverable")],
                "the launch over an undecodable wall index wrote \(launch)")
    }

    /// The launch reconcile drops a held photo the wall already holds, the crash window of an answer (its
    /// wall commit landed, its pending write did not), and says how many. The wall commit goes through
    /// the process-wide wall key, as `MeshHeldSessionPhotoTests`' I8 builds the same window.
    @Test func theLaunchReconcileNamesTheHeldPhotosTheWallAlreadyHolds() throws {
        let rig = try AuditMeshRig()
        defer { rig.tearDown() }
        let photo = Self.heldPhoto(origin: "ffgt-origin-twice")
        try #require(Self.hold(photo, on: rig.manager) == .held, "the photo was not held")
        let kept = try Self.commitHeldPhotoToWall(photo.id, in: rig.store, keys: rig.keys)
        try #require(kept == [photo.id], "precondition: the held photo is on the wall too, kept \(kept)")
        let launch = MovedAuditLines.delivered { _ = rig.relaunched(keys: rig.keys) }
        #expect(Self.movedLines(launch) == [Self.auditLine("mesh.heldPhotos.reconciled", ["dropped": "1"])],
                "the reconciling launch wrote \(launch)")
    }

    /// The hold past the corpus bound is refused with `full`, the 200 photos before it all held.
    @Test func theHoldPastTheCorpusBoundIsRefusedFull() throws {
        let rig = try AuditMeshRig()
        defer { rig.tearDown() }
        // R2: a hard constant ceiling, the corpus bound.
        for position in 0..<Self.heldPhotoBound {
            let outcome = Self.hold(Self.heldPhoto(origin: "ffgt-origin-cap"), on: rig.manager)
            try #require(outcome == .held, "hold \(position) of \(Self.heldPhotoBound) was \(outcome)")
        }
        let overflow = MovedAuditLines.delivered { _ = Self.hold(Self.heldPhoto(origin: "ffgt-origin-cap"), on: rig.manager) }
        #expect(Self.movedLines(overflow) == [Self.auditLine("mesh.heldPhotos.holdRefused", ["reason": "full"])],
                "the hold past the bound wrote \(overflow)")
    }

    // MARK: Group 29 — the order of a session's commit and end

    /// The frames one commit sends a peer advertising every capability, in order, written from the commit
    /// hook and checked against an independent reading of the same code: the catalog and its request in
    /// one task, then the item report, the friend state and the activity offer (through the activity
    /// manager), one task each, each run in the order it was spawned.
    static let commitFrameOrder = ["catalog", "catalogRequest", "itemReport", "friendState", "activityOffer"]

    /// The commit's three observable moments, each with how many frames bob's link had carried when it
    /// fired: the closeness hook before any frame (the hook's first statement), the catalog's send hook
    /// before the catalog's frame and the request's hook after the catalog's and the request's frames.
    static let commitHookMoments = ["closeness@0", "catalogSend@0", "catalogRequestSent@2"]

    /// The legs of one session end, in order, written from the teardown funnel, the promotion (the roster
    /// half, which empties the roster, before the photo half, which logs its move) and the transcript's
    /// clear (the transcript before the heart state), and checked against an independent reading of the
    /// same code.
    static let sessionEndOrder = ["reviewMerge", "photoMove", "shopWindow", "transcriptClear", "heartReset"]

    /// One commit with bob advertising every capability, alice's shop opted in, her own reports and
    /// friend state armed and one activity hosted: the closeness hook fires before any frame, the frames
    /// leave in ``commitFrameOrder`` and the shop's two hooks fire at ``commitHookMoments``. Observed
    /// through the closeness hook, the shop's two send hooks and the frames bob's link carries, in send
    /// order.
    @Test func oneCommitRunsClosenessFirstThenTheCatalogRequestReportStateAndOffer() async throws {
        let rig = try Self.sessionRig(bobAdvertising: Self.everyCapability)
        defer { Self.tearDown(rig) }
        Self.armReportAndState(in: rig)
        Self.armShop(in: rig)
        try #require(Self.hostActivity(in: rig) != nil, "alice hosts no activity")
        Self.seatBob(in: rig)
        let recorder = LifecycleRecorder()
        Self.recordCommitHooks(of: rig, into: recorder)
        try Self.commitBob(in: rig)
        let tokens = Self.commitFrameOrder.map { Self.featureToken($0) }
        await Self.settle(rig, untilSent: tokens)
        let sent = Self.envelopes(sentIn: rig).map(\.payloadTypeToken)
        #expect(sent == tokens, "the commit sent \(sent)")
        #expect(recorder.order == Self.commitHookMoments, "the commit's hooks fired at \(recorder.order)")
    }

    /// One session end, over a session holding something for each leg (bob in the live roster, one live
    /// photo, bob's catalog, one message, a refused heart): the legs run in ``sessionEndOrder``. Observed
    /// where each begins: the roster's first change, the photo move's audit line, and the shop window's,
    /// the transcript's and the heart state's first changes. Observation calls each handler inline in the
    /// property's `willSet`, on the main actor that changes it, so the order noted is the order run.
    @Test func oneSessionEndRunsItsReviewPhotoShopTranscriptAndHeartLegsInOrder() throws {
        let rig = try Self.sessionRig(bobAdvertising: [])
        defer { Self.tearDown(rig) }
        let manager = rig.manager
        let shop = rig.features.clothingShop
        let hearts = rig.features.hearts
        try Self.armSessionToEnd(rig)
        try #require(manager.sessionRoster.count == 1 && manager.sessionPhotos.count == 1
                         && manager.pendingFriendReview == nil,
                     "the roster holds \(manager.sessionRoster.count), the roll \(manager.sessionPhotos.count)")
        try #require(shop.peerCatalogs.count == 1 && shop.window == nil,
                     "the shop holds \(shop.peerCatalogs.count) catalogs")
        let transcript = rig.features.chat.sessionMessages
        try #require(transcript.messages.count == 1 && hearts.sessionHeartState != .idle,
                     "the transcript holds \(transcript.messages.count), the heart \(hearts.sessionHeartState)")
        try #require(!manager.isSessionLive, "the session is still live")
        let recorder = LifecycleRecorder()
        defer { recorder.uninstall() }
        Self.recordSessionEnd(of: rig, into: recorder)
        Self.endSession(manager)
        #expect(recorder.order == Self.sessionEndOrder, "the session ended in the order \(recorder.order)")
        let review = manager.pendingFriendReview
        #expect(review?.entries.map(\.fingerprint) == [Self.bobFingerprint] && review?.photos.count == 1,
                "the review holds \(String(describing: review))")
        #expect(shop.window != nil && transcript.messages.isEmpty
                    && hearts.sessionHeartState == .idle, "a leg left its state; the heart is \(hearts.sessionHeartState)")
    }

    /// A new search holds what the last session left live before it mints the new session's ids: the
    /// photo moves into the review, its move logged, still stamped with the old session's id and start,
    /// and only the next live photo carries a new session's id.
    @Test func aNewSearchHoldsTheOldSessionsPhotosBeforeMintingNewIDs() throws {
        let rig = try Self.sessionRig(bobAdvertising: [])
        defer { Self.tearDown(rig) }
        let manager = rig.manager
        defer { manager.leaveMesh() }
        try #require(Self.holdLive(Self.sessionPhoto(1), on: manager) == .held, "the live photo was not held")
        let old = try #require(manager.sessionPhotos.first?.session, "the live photo carries no session")
        let recorder = LifecycleRecorder()
        defer { recorder.uninstall() }
        recorder.install(noting: "photoMove", whenLogged: "mesh.session.photosPendingReview")
        Self.startNewSearch(on: manager)
        #expect(recorder.order == ["photoMove"], "the new search noted \(recorder.order)")
        let moved = manager.pendingFriendReview?.photos.first?.session
        #expect(moved?.id == old.id && moved?.startedAt == old.startedAt,
                "the old roll moved stamped \(String(describing: moved)), not \(old)")
        try #require(Self.holdLive(Self.sessionPhoto(2), on: manager) == .held, "the next live photo was not held")
        let next = manager.sessionPhotos.first?.session?.id
        #expect(next != nil && next != old.id, "the new session's photo carries \(String(describing: next))")
    }

    /// Leaving a session stamps its photos with the session's last metadata before it forgets the
    /// session's ids (`leaveMesh()` runs before the two clears): the first photo, taken alone, moves into
    /// the review naming bob as well, who was seated when the second was taken, so the stamp ran with the
    /// ids still set; the move is logged; and the next live photo carries a new session's id, so the ids
    /// were then forgotten.
    @Test func leavingASessionStampsItsPhotosBeforeForgettingItsIDs() throws {
        let rig = try Self.sessionRig(bobAdvertising: [])
        defer { Self.tearDown(rig) }
        let manager = rig.manager
        try #require(Self.holdLive(Self.sessionPhoto(1), on: manager) == .held, "the first photo was not held")
        Self.seatBob(in: rig)
        try #require(Self.holdLive(Self.sessionPhoto(2), on: manager) == .held, "the second photo was not held")
        let first = try #require(manager.sessionPhotos.last?.session, "the first photo carries no session")
        try #require(first.participants.map(\.fingerprint) == [Self.aliceFingerprint],
                     "the first photo names \(first.participants.map(\.fingerprint))")
        let recorder = LifecycleRecorder()
        defer { recorder.uninstall() }
        recorder.install(noting: "photoMove", whenLogged: "mesh.session.photosPendingReview")
        Self.endSession(manager)
        #expect(recorder.order == ["photoMove"], "the leave noted \(recorder.order)")
        let moved = manager.pendingFriendReview?.photos.compactMap(\.session) ?? []
        let both = [Self.aliceFingerprint, Self.bobFingerprint]
        #expect(moved.count == 2 && moved.allSatisfy { $0.id == first.id && $0.participants.map(\.fingerprint) == both },
                "the roll moved stamped \(moved)")
        try #require(Self.holdLive(Self.sessionPhoto(3), on: manager) == .held, "the next photo was not held")
        #expect(manager.sessionPhotos.first?.session?.id != first.id, "the next photo still carries the left session's id")
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
    /// `FernletSocialHost.isTrustedUnblockedPeer(signingPublicKey:fingerprint:)` (`ProximityHost`'s until
    /// plan step A0.5.10, when this re-typed).
    static func coreHeartEligibility(of signingKey: Data, fingerprint: String, in host: any FernletSocialHost) -> Bool {
        host.isTrustedUnblockedPeer(signingPublicKey: signingKey, fingerprint: fingerprint)
    }

    /// Presence's heart-eligibility gate: today
    /// `PresenceManager.isHeartEligible(signingPublicKey:fingerprint:in:)`.
    static func presenceHeartEligibility(
        of signingKey: Data, fingerprint: String, in host: any FernletSocialHost
    ) -> Bool {
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

    /// The capability array `store`'s mesh advertises: today `MeshNetworkManager.localCapabilities()`,
    /// which the manager reads once per coordinator and the coordinator carries verbatim into the signed
    /// introduction, on the store's own composition (`FernletStore.meshFeatures`, plan step A0.5.5),
    /// whose capability list (`FernletMeshCapabilities`) is the mesh's provider: the list composed in
    /// FernletSocial, read through the engine as the coordinator reads it.
    static func advertisedCapabilities(of store: FernletStore) -> [String] {
        store.meshFeatures.mesh.localCapabilities()
    }

    /// Puts `store` in capability state `state`: five characters, `1` on, in the order
    /// `localCapabilities()` reads its switches. Each switch is set at the app's own wiring of it, today:
    /// - the away-hearts consent `settings.heartsAwayDelivery`;
    /// - clothing-shop sharing `settings.allowNearbyClothingShares`;
    /// - the chat gate `ageAssurance.allows(.chat)`, opened by a 13–16 bracket the system returns as a
    ///   guardian's declaration and shut by a cleared record, a fresh install's;
    /// - the friend-state opt-in `settings.allowNearbyFriendState`;
    /// - the hearts opt-in `settings.allowNearbyHearts` the host answers.
    ///
    /// The settings are written through `FernletStore.settings`, never through their setters: their side
    /// effects, the away-hearts purge and the shop clear, are not the subject. A malformed state sets
    /// nothing, which fails every cell that reaches it.
    static func setCapabilitySwitches(_ state: String, on store: FernletStore) {
        let on = state.map { $0 == "1" }
        guard on.count == 5, state.allSatisfy({ $0 == "0" || $0 == "1" }) else { return }
        store.settings.heartsAwayDelivery = on[0]
        store.settings.allowNearbyClothingShares = on[1]
        if on[2] {
            store.ageAssurance.applyDetermination(
                lowerBound: AgeGate.chat.minimumAge, upperBound: AgeGate.intimacy.minimumAge,
                provenance: .guardianDeclared)
        } else {
            store.ageAssurance.clear()
        }
        store.settings.allowNearbyFriendState = on[3]
        store.settings.allowNearbyHearts = on[4]
    }

    /// The routed-type rows Fernlet's mesh registers: today the registry `MeshNetworkManager` builds once
    /// in `init` and reads through `routedTypes`, its resident rows and the host's
    /// (`increment1(_:hostEntries:)` with `ProximityHost.meshRoutedTypeEntries`, since plan step A0.5.9),
    /// which for `.fernlet`'s routed types is the test target's `MeshRoutedTypeRegistry.increment1(_:)`
    /// (the resident rows and `FernletRoutedTypes.entries`). The manager's own copy is private, so this
    /// is the expression it is built from.
    static var fernletRoutedTypeRegistry: MeshRoutedTypeRegistry {
        MeshRoutedTypeRegistry.increment1(ProximityNamespace.fernlet.family.vocabulary.routedTypes)
    }

    /// The bound the delivery projection's resident guard reads and the seal and the open enforce, on
    /// a fresh store's own manager: today ``heldResidentBlobBound(of:)`` of a `makeTestStore()`, the
    /// app's wiring of the manager (plan step A0.5.4; until then the constant
    /// `MeshRoutedItemSealFormat.maxResidentBlobByteCount`).
    static var residentBlobBound: Int {
        heldResidentBlobBound(of: makeTestStore())
    }

    /// The resident bound `store`'s own manager holds (`FernletStore.meshNetworkManager`): today
    /// `MeshNetworkManager.routedResidentBlobBoundForTesting`, its host registry's widest routed row
    /// clamped into an `Int` once at `init`.
    static func heldResidentBlobBound(of store: FernletStore) -> Int {
        store.meshNetworkManager.routedResidentBlobBoundForTesting
    }

    /// The widest plaintext the seal takes: today ``residentBlobBound`` less
    /// `MeshRoutedItemSealFormat.overheadByteCount`, the edge `MeshRoutedItemSealer.seal` draws by
    /// refusing a plaintext whose length plus the overhead exceeds the bound it is handed (plan step
    /// A0.5.4; until then the constant `MeshRoutedItemSealFormat.maxPlaintextByteCount`).
    static var sealPlaintextBound: Int {
        residentBlobBound - MeshRoutedItemSealFormat.overheadByteCount
    }

    /// The photo row's payload bound: today `PrivateMediaStore.maxIncomingPhotoBytes`, the term the
    /// photo row's cap starts from (`MeshRoutedTypeRegistry.increment1Rows(_:)` since plan step
    /// A0.5.4). Its literal is `MeshRoutedTypeRegistryTests`' pin.
    static var photoPayloadBound: Int {
        PrivateMediaStore.maxIncomingPhotoBytes
    }

    /// Seals `plaintext` as one routed item of `typeToken` under the probe key and binding: today
    /// `MeshRoutedItemSealer.seal(_:contentKey:binding:typeToken:maxBlobByteCount:in:)` under
    /// `.fernlet`'s purposes and the bound a fresh store's manager holds (``residentBlobBound``), which
    /// refuses a plaintext whose length plus the seal's overhead exceeds that bound.
    static func sealRoutedProbe(_ plaintext: Data, typeToken: String) throws -> Data {
        try MeshRoutedItemSealer.seal(plaintext, contentKey: routedProbeKey, binding: routedProbeBinding,
                                      typeToken: typeToken, maxBlobByteCount: Self.residentBlobBound,
                                      in: ProximityNamespace.fernlet.family.purposes)
    }

    /// Opens a routed item blob of `typeToken` under the probe key and binding: today
    /// `MeshRoutedItemSealer.open(_:contentKey:binding:typeToken:maxBlobByteCount:in:)` under
    /// `.fernlet`'s purposes and the bound a fresh store's manager holds (``residentBlobBound``), which
    /// refuses a blob above that bound.
    static func openRoutedProbe(_ blob: Data, typeToken: String) throws -> Data {
        try MeshRoutedItemSealer.open(blob, contentKey: routedProbeKey, binding: routedProbeBinding,
                                      typeToken: typeToken, maxBlobByteCount: Self.residentBlobBound,
                                      in: ProximityNamespace.fernlet.family.purposes)
    }

    /// `registry` without its `token` row, a fixture registry: today `MeshRoutedTypeRegistry(entries:)`
    /// over `registry`'s other rows, each read back out of it.
    static func routedTypes(_ registry: MeshRoutedTypeRegistry, dropping token: String) -> MeshRoutedTypeRegistry {
        MeshRoutedTypeRegistry(entries: registry.tokens.sorted().filter { $0 != token }.compactMap {
            registry.entry(for: $0)
        })
    }

    /// The widest row `registry` accepted, in bytes: today `MeshRoutedTypeRegistry.maxItemByteCount`,
    /// the value a manager clamps its resident bound from at `init` (plan step A0.5.4).
    static func widestRoutedRow(of registry: MeshRoutedTypeRegistry) -> UInt64 {
        registry.maxItemByteCount
    }

    /// Hands `store`'s own manager `registry` in place of the one it built at `init`: today
    /// `MeshNetworkManager.routedTypeRegistryForTesting`, which every door that resolves a routed
    /// token reads and the resident bound does not.
    static func narrowRoutedTypes(of store: FernletStore, to registry: MeshRoutedTypeRegistry) {
        store.meshNetworkManager.routedTypeRegistryForTesting = registry
    }

    /// Whether `store`'s own manager registers `token` right now: today
    /// `MeshNetworkManager.isRoutedTypeRegistered(_:)`, which reads a fixture registry when one is set.
    static func registersRoutedType(_ token: String, in store: FernletStore) -> Bool {
        store.meshNetworkManager.isRoutedTypeRegistered(token)
    }

    /// Captures one photo at `node` through the photo sender: today `MeshFoundingRig.capturePhoto(at:)`,
    /// which calls `MeshNetworkManager.addPhoto(_:)`, whose share originates the item under the photo
    /// wall's token to the full roster.
    static func sendPhoto(at node: Int, in rig: MeshFoundingRig) {
        rig.capturePhoto(at: node)
    }

    /// Sends one message at `node` through the text sender: today `MeshFoundingRig.sendText(at:_:)`,
    /// which calls the node's chat's `sendTempMessage(_:)` (FernletSocial's since plan step A0.5.9),
    /// which originates the item under the host's text row's token to the full roster.
    static func sendText(_ text: String, at node: Int, in rig: MeshFoundingRig) -> MeshTextSendOutcome {
        rig.sendText(at: node, text)
    }

    /// Readies `node` to send a heart: today a ledger on its composition's session hearts
    /// (`heartLedger`; the manager's until plan step A0.5.10), from
    /// `MeshFoundingRig.isolatedHeartLedger(now:)`, and the hearts opt-in on its host
    /// (`FernletStore.setAllowNearbyHearts(_:)`), as the heart sender's gates read them.
    static func armHearts(at node: Int, in rig: MeshFoundingRig) {
        rig.nodes[node].features.hearts.heartLedger = rig.isolatedHeartLedger(now: Date())
        rig.nodes[node].store.setAllowNearbyHearts(true)
    }

    /// Sends one heart from `node` to `friend` through the heart sender: today
    /// `MeshFoundingRig.sendHeart(from:to:)`, which calls the node's composition's
    /// `MeshSessionHearts.sendSessionHeart(to:)` (the manager's until plan step A0.5.10), which
    /// originates the item under the host's heart row's token to `friend` alone.
    static func sendHeart(from node: Int, to friend: ProximityTrustedPeerRecord, in rig: MeshFoundingRig) {
        rig.sendHeart(from: node, to: friend)
    }

    /// The manifests `node` staged as its own origin: today read from its routed store under the rig's
    /// pinned install binding (`MeshFoundingRig.routedIndex(_:)`, then `MeshRoutedIndex.items` and each
    /// record's `key` and `manifest`).
    static func ownStagedManifests(at node: Int, in rig: MeshFoundingRig) -> [MeshRoutedManifest] {
        let origin = rig.nodes[node].fingerprint
        return (rig.routedIndex(node)?.items ?? []).filter { $0.key.originFingerprint == origin }.compactMap(\.manifest)
    }

    /// The routed heart body production mints for a gift: today
    /// `MeshRoutedHeartBody(header: MeshRoutedHeartHeader(id:sentAtDayKey:senderName:)).encoded()` in
    /// ProximityKit, which the session heart's sender calls.
    static func routedHeartBody(id: UUID, sentAtDayKey: String, senderName: String) throws -> Data {
        try MeshRoutedHeartBody(header: MeshRoutedHeartHeader(id: id, sentAtDayKey: sentAtDayKey, senderName: senderName))
            .encoded()
    }

    /// A routed heart body, decoded the way the delivery door decodes one: today
    /// `MeshRoutedHeartBody(decoding:)`. Returns its header's three fields.
    static func decodedRoutedHeartBody(_ bytes: Data) throws -> (id: UUID, sentAtDayKey: String, senderName: String) {
        let header = try MeshRoutedHeartBody(decoding: bytes).header
        return (header.id, header.sentAtDayKey, header.senderName)
    }

    /// The routed text body production mints for a message: today
    /// `MeshRoutedTextBody(header: MeshRoutedTextHeader(id:sentAt:senderName:), text:).encoded()` in
    /// FernletSocial (ProximityKit's until plan step A0.5.9), which the text sender calls.
    static func routedTextBody(id: UUID, sentAt: Date, senderName: String, text: String) throws -> Data {
        try MeshRoutedTextBody(header: MeshRoutedTextHeader(id: id, sentAt: sentAt, senderName: senderName), text: text)
            .encoded()
    }

    /// A routed text body, decoded the way the delivery door decodes one: today
    /// `MeshRoutedTextBody(decoding:)`. Returns its header's three fields and its text.
    static func decodedRoutedTextBody(_ bytes: Data) throws -> (id: UUID, sentAt: Date, senderName: String, text: String) {
        let body = try MeshRoutedTextBody(decoding: bytes)
        return (body.header.id, body.header.sentAt, body.header.senderName, body.text)
    }

    /// A join token's refusal: today `ActivityJoinToken.VerifyError`.
    typealias JoinTokenRefusal = ActivityJoinToken.VerifyError
    /// A roster snapshot's refusal: today `ActivityRosterSnapshot.VerifyError`.
    typealias RosterRefusal = ActivityRosterSnapshot.VerifyError
    /// One signed row the moderation relay carries: today FernletSocial's `SignedModerationReport`
    /// (ProximityKit's until plan step A0.5.7 moved the relay).
    typealias SignedReport = SignedModerationReport

    /// The bytes an activity descriptor is hashed over: today FernletSocial's
    /// `canonicalBytes(for: ActivityDescriptor)` (ProximityKit's until plan step A0.5.8 moved it,
    /// unchanged, to `FeatureCanonicalBytes.swift`).
    static func descriptorTranscript(_ descriptor: ActivityDescriptor) -> Data {
        FernletSocial.canonicalBytes(for: descriptor)
    }

    /// An activity's params hash: today `ActivityParamsHash.of(_:)`.
    static func paramsHash(of descriptor: ActivityDescriptor) -> Data {
        ActivityParamsHash.of(descriptor)
    }

    /// The bytes a join token is signed over: today FernletSocial's
    /// `canonicalBytes(for: ActivityJoinToken)` (ProximityKit's until plan step A0.5.8).
    static func joinTokenTranscript(_ token: ActivityJoinToken) -> Data {
        FernletSocial.canonicalBytes(for: token)
    }

    /// The bytes a roster snapshot is signed over: today FernletSocial's
    /// `canonicalBytes(for: ActivityRosterSnapshot)` (ProximityKit's until plan step A0.5.8).
    static func rosterTranscript(_ snapshot: ActivityRosterSnapshot) -> Data {
        FernletSocial.canonicalBytes(for: snapshot)
    }

    /// The bytes a moderation row is signed over: today FernletSocial's
    /// `canonicalBytes(for: ModerationLedgerEntry)` (ProximityKit's until plan step A0.5.7 moved it,
    /// unchanged, to `FeatureCanonicalBytes.swift`).
    static func moderationTranscript(_ entry: ModerationLedgerEntry) -> Data {
        FernletSocial.canonicalBytes(for: entry)
    }

    /// Whether `signature` verifies over `transcript` by `key` under a registry label: the one raw
    /// Ed25519 check every transcript here reaches. Today `IdentityService.verify(_:of:by:purpose:)`, its
    /// `CryptographicPurpose` overload.
    static func verifies(_ signature: Data, over transcript: Data, by key: Data, under label: CryptographicPurpose) -> Bool {
        IdentityService.verify(signature, of: transcript, by: key, purpose: label)
    }

    /// The joiner's check of a join token: today `ActivityJoinToken.verify(...)`, handed the signing key
    /// the joiner presents, the activity id, params hash and host key it expects, and the time.
    static func verifyJoinToken(_ token: ActivityJoinToken, presentedKey: Data, activityID: UUID, paramsHash: Data,
                                hostKey: Data, now: Date) throws {
        try token.verify(joinerSigningPublicKey: presentedKey, expectedActivityID: activityID,
                         expectedParamsHash: paramsHash, expectedHostSigningPublicKey: hostKey, now: now)
    }

    /// A member's check of a roster snapshot: today
    /// `ActivityRosterSnapshot.verify(expectedActivityID:expectedHostSigningPublicKey:)`.
    static func verifyRoster(_ snapshot: ActivityRosterSnapshot, activityID: UUID, hostKey: Data) throws {
        try snapshot.verify(expectedActivityID: activityID, expectedHostSigningPublicKey: hostKey)
    }

    /// The rows the moderation relay keeps from one payload of `reports` that `sender` sent:
    /// ``moderationRows(from:sender:now:)`` over the payload `ReportBundle(reports:)` builds, so one
    /// accessor names the relay's verify.
    static func relayedRows(_ reports: [SignedReport], sender: Data, now: Date) -> [ModerationLedgerEntry] {
        moderationRows(from: ReportBundle(reports: reports), sender: sender, now: now)
    }

    /// A join token `host` grants and signs: today `ActivityJoinToken.signed(...)`.
    static func signedJoinToken(activityID: UUID, paramsHash: Data, joinerFingerprint: String, joinerKey: Data,
                                host: IdentityService, grantedAt: Date, expiresAt: Date,
                                rosterVersion: Int) throws -> ActivityJoinToken {
        try ActivityJoinToken.signed(activityID: activityID, activityParamsHash: paramsHash,
                                     joinerFingerprint: joinerFingerprint, joinerSigningPublicKey: joinerKey,
                                     hostIdentity: host, grantedAt: grantedAt, expiresAt: expiresAt,
                                     rosterVersionAtGrant: rosterVersion)
    }

    /// A roster snapshot `host` issues and signs: today `ActivityRosterSnapshot.signed(...)`.
    static func signedRoster(activityID: UUID, version: Int, participants: [ActivityParticipant], issuedAt: Date,
                             host: IdentityService) throws -> ActivityRosterSnapshot {
        try ActivityRosterSnapshot.signed(activityID: activityID, version: version, participants: participants,
                                          issuedAt: issuedAt, hostIdentity: host)
    }

    /// The report bundle `identity` signs over its own rows: today
    /// `ModerationReportRelay.buildPayload(ownReports:identity:)`, which keeps only the identity's own
    /// reports and retractions and signs each; FernletSocial's since plan step A0.5.7 moved the relay
    /// whole, so only its module changed.
    static func signedReportBundle(of rows: [ModerationLedgerEntry], by identity: IdentityService) -> ReportBundle {
        ModerationReportRelay.buildPayload(ownReports: rows, identity: identity)
    }

    /// alice's offer, today FernletSocial's `ActivityOfferPayload` (ProximityKit's until plan step
    /// A0.5.8 moved the activity payloads whole).
    typealias ActivityOffer = ActivityOfferPayload
    /// bob's join request, today FernletSocial's `ActivityJoinRequestPayload`.
    typealias ActivityJoinRequest = ActivityJoinRequestPayload
    /// alice's grant, today FernletSocial's `ActivityJoinGrantPayload`.
    typealias ActivityJoinGrant = ActivityJoinGrantPayload
    /// A gossiped roster, today FernletSocial's `ActivityRosterSnapshotPayload`.
    typealias ActivityRosterGossip = ActivityRosterSnapshotPayload
    /// A version digest, today FernletSocial's `ActivitySyncPayload`.
    typealias ActivitySync = ActivitySyncPayload
    /// A shop's catalog, today ProximityKit's `ClothingCatalogPayload`.
    typealias ClothingCatalog = ClothingCatalogPayload
    /// A moderation report bundle, today FernletSocial's `ModerationReportPayload` (ProximityKit's until
    /// plan step A0.5.7 moved the relay).
    typealias ReportBundle = ModerationReportPayload
    /// A vouch list, today ProximityKit's `MeshFriendVouchListPayload`.
    typealias FriendVouchList = MeshFriendVouchListPayload
    /// A hosted activity, today `ProximityActivityManager.HostedActivity`, FernletSocial's since plan
    /// step A0.5.8 moved the manager whole.
    typealias HostedActivity = ProximityActivityManager.HostedActivity
    /// A joined activity, today `ProximityActivityManager.JoinedActivity`.
    typealias JoinedActivity = ProximityActivityManager.JoinedActivity
    /// A received heart, today FernletSocial's `ReceivedHeartRecord` (ProximityKit's until plan step
    /// A0.5.10, when it moved with the heart ledger).
    typealias HeartRecord = ReceivedHeartRecord

    /// The encoder the mesh writes every feature payload with: today a `JSONEncoder()` with no
    /// configuration, which is also the ledgers'.
    static func meshPayloadEncoder() -> JSONEncoder {
        JSONEncoder()
    }

    /// The decoder every feature payload's receive handler reads with: today a `JSONDecoder()` with no
    /// configuration.
    static func meshPayloadDecoder() -> JSONDecoder {
        JSONDecoder()
    }

    /// The receive path's repair of a listed item: today `ClothingShopLimits.sanitizedForShop(_:)`.
    static func shopSanitized(_ item: CustomizationItem) -> CustomizationItem {
        ClothingShopLimits.sanitizedForShop(item)
    }

    /// The rows the relay keeps from a decoded payload `sender` sent: today
    /// `ModerationReportRelay.verifiedRows(from:senderSigningKey:now:)`, FernletSocial's since plan step
    /// A0.5.7.
    static func moderationRows(from payload: ReportBundle, sender: Data, now: Date) -> [ModerationLedgerEntry] {
        ModerationReportRelay.verifiedRows(from: payload, senderSigningKey: sender, now: now)
    }

    /// The heart ledger's file in `root`: today `ProximityHeartLedger.fileURL(in:)`, FernletSocial's
    /// since plan step A0.5.10.
    static func heartLedgerFile(in root: URL) -> URL {
        ProximityHeartLedger.fileURL(in: root)
    }

    /// A heart ledger over `fileURL` whose clock stands at `clock`, reading and writing through the
    /// closures given, or through the file system for nil, the default: today
    /// `ProximityHeartLedger(fileURL:now:readData:writeData:)`, FernletSocial's since plan step A0.5.10,
    /// where it moved whole with this initializer.
    static func heartLedger(fileURL: URL, clock: Date, reading: ((URL) throws -> Data)? = nil,
                            writing: ((Data, URL) throws -> Void)? = nil) -> ProximityHeartLedger {
        ProximityHeartLedger(fileURL: fileURL, now: { clock }, readData: reading, writeData: writing)
    }

    /// The activity ledger's file in `root`: today `ProximityActivityManager.fileURL(in:)`, FernletSocial's
    /// since plan step A0.5.8.
    static func activityLedgerFile(in root: URL) -> URL {
        ProximityActivityManager.fileURL(in: root)
    }

    /// An activity manager over `fileURL` whose clock stands at `clock`, holding `host` unowned (the
    /// caller keeps it alive): today `ProximityActivityManager(store:identity:fileURL:now:)`,
    /// FernletSocial's since plan step A0.5.8.
    static func activityManager(host: any ProximityHost, identity: IdentityService?, fileURL: URL,
                                clock: Date) -> ProximityActivityManager {
        ProximityActivityManager(store: host, identity: identity, fileURL: fileURL, now: { clock })
    }

    /// A mesh manager over `store` (held unowned: the caller keeps it alive) on an in-memory radio, with
    /// `identity` as its device identity and `heldPhotoKeys` as the pending corpus's key, or nil, the
    /// default, for the keychain row production reads: today the internal
    /// `MeshNetworkManager(store:transport:identity:heldPhotoKeys:)`, a bare engine: the cells that read
    /// it read the photo wall, still the engine's (the activity manager's cells read the composition's
    /// since plan step A0.5.8, when it left the engine). Re-pointed at ``meshFeatures(over:identity:)``
    /// when the photo wall leaves the engine (A0.5.11).
    static func meshManager(over store: FernletStore, identity: IdentityService,
                            heldPhotoKeys: (any PrivateMediaKeyProviding)? = nil) -> MeshNetworkManager {
        MeshNetworkManager(store: store, transport: FakeMeshTransportSession(), identity: identity,
                           heldPhotoKeys: heldPhotoKeys)
    }

    /// Fernlet's mesh composition over `store` (held unowned: the caller keeps it alive) on an in-memory
    /// radio, with `identity` as the device identity it hands its mesh and its features and
    /// `heldPhotoKeys` as the pending corpus's key, or nil, the default, for the keychain row production
    /// reads: today `FernletMeshRig.features(store:transport:identity:heldPhotoKeys:)`, the app's
    /// composition over the manager's internal designated initializer (plan step A0.5.5). The caller
    /// keeps the composition for as long as it uses it.
    static func meshFeatures(over store: FernletStore, identity: IdentityService,
                             heldPhotoKeys: (any PrivateMediaKeyProviding)? = nil) -> FernletMeshFeatures {
        FernletMeshRig.features(store: store, transport: FakeMeshTransportSession(), identity: identity,
                                heldPhotoKeys: heldPhotoKeys)
    }

    /// The wall preferences' entry count: today `photoWallPreferenceEntryCountForTesting`.
    static func wallPreferenceEntryCount(_ manager: MeshNetworkManager) -> Int {
        manager.photoWallPreferenceEntryCountForTesting
    }

    /// Holds `photo` for review, not live, keyed by its sender and id: today
    /// `holdSessionPhoto(_:key:live:)`.
    static func hold(_ photo: FriendPhotoPayload, on manager: MeshNetworkManager) -> PendingSessionPhotoStore.Hold {
        manager.holdSessionPhoto(photo, key: MeshContentKey(senderFingerprint: photo.senderFingerprint ?? "", contentID: photo.id),
                                 live: false)
    }

    /// A wall store over the index at `indexURL` on an in-memory key: today
    /// `PrivateMediaStore(indexURL:keyProvider:)`, the type the mesh builds its wall from.
    static func wallStore(indexedAt indexURL: URL) -> PrivateMediaStore {
        PrivateMediaStore(indexURL: indexURL, keyProvider: SwitchableMediaKeyProvider())
    }

    /// The vouch list a composition caches after its mesh hands it `list` from `sender` with the
    /// broadcast gate forced on: today `FernletVouchList.isVouchListBroadcastEnabled`, the mesh's
    /// `vouchListExchange` (the adapter the composition installs, which the vouch arm hands every list it
    /// decodes) and `FernletVouchList.cachedVouchList(from:)` (plan step A0.5.5; the manager's until then).
    static func receiveVouchList(_ list: FriendVouchList, from sender: String, on features: FernletMeshFeatures) -> FriendVouchList? {
        features.vouchList.isVouchListBroadcastEnabled = true
        features.mesh.vouchListExchange?.receiveVouchList(list, senderFingerprint: sender)
        return features.vouchList.cachedVouchList(from: sender)
    }

    /// The pending corpus's names: today `PendingSessionPhotoStore`'s four frozen tokens, which the mesh
    /// joins under its root.
    static var pendingCorpusNameRows: [FeatureGoldenNameRow] {
        [
            FeatureGoldenNameRow(field: "pendingSessionPhotos.directoryName", frozen: "PendingSessionPhotos",
                                 today: PendingSessionPhotoStore.directoryName),
            FeatureGoldenNameRow(field: "pendingSessionPhotos.indexFileName", frozen: "PendingSessionPhotoIndex.sealed",
                                 today: PendingSessionPhotoStore.indexFileName),
            FeatureGoldenNameRow(field: "pendingSessionPhotos.photosDirectoryName", frozen: "Photos",
                                 today: PendingSessionPhotoStore.photosDirectoryName),
            FeatureGoldenNameRow(field: "pendingSessionPhotos.thumbnailsDirectoryName", frozen: "Thumbnails",
                                 today: PendingSessionPhotoStore.thumbnailsDirectoryName)
        ]
    }

    /// The catalog and the request the mesh sends a just-committed peer, as that peer reads them: a
    /// ``SessionRig`` (groups 26 and 29 drive the same one) whose bob advertises `shop` alone, so the
    /// catalog is sealed in the legacy framing; alice's shop (the rig's composition's, plan step A0.5.6)
    /// opted in with `catalog` through its two providers; bob seated (`addSlotForTesting`) and committed
    /// (`noteSlotCommittedForShop`), whose hook tells the composition's session observer, whose shop
    /// exchange sends the catalog and then the request; and the fabric settled until both have left. bob
    /// opens the catalog. The root and both identities' rows are removed before this returns.
    static func shopBodiesSentOnCommit(catalog: ClothingCatalog) async throws -> (catalog: Data, request: Data) {
        let rig = try sessionRig(bobAdvertising: [ProximityCapability.shop.rawValue])
        defer { tearDown(rig) }
        rig.features.clothingShop.isSharingEnabledProvider = { true }
        rig.features.clothingShop.localCatalogProvider = { catalog }
        seatBob(in: rig)
        try commitBob(in: rig)
        let tokens = ["catalog", "catalogRequest"].map { featureToken($0) }
        await settle(rig, untilSent: tokens)
        let sent = envelopes(sentIn: rig)
        let sentCatalog = try #require(sent.first { $0.payloadTypeToken == tokens[0] }, "the mesh sent no catalog")
        let sentRequest = try #require(sent.first { $0.payloadTypeToken == tokens[1] }, "the mesh sent no request")
        let opened = try openedByBob(sentCatalog, in: rig)
        return (opened, sentRequest.payload)
    }

    /// What the keychain row of `role` opens `stored` to under `purpose`, or nil when it does not open
    /// it: today `KeychainPrivateMediaKeyProvider(role:)` and the internal
    /// `PrivateMediaKeyProviding.gcmOpen(_:purpose:)`, the open every media store reads through. Not
    /// moved by A0.5: PrivateMediaStore stays.
    static func openedAtRest(_ stored: Data, under role: KeychainPrivateMediaKeyProvider.Role,
                             purpose: CryptographicPurpose) -> Data? {
        KeychainPrivateMediaKeyProvider(role: role).gcmOpen(stored, purpose: purpose)
    }

    /// Whether the keychain row of `role` vends a key, minting the row if it is absent as production's
    /// first use does: today `KeychainPrivateMediaKeyProvider.mediaKey()`. A refusal by a role with no
    /// key would be vacuous; this is what makes group 24's refusals refusals by a key.
    static func hasMediaKey(for role: KeychainPrivateMediaKeyProvider.Role) -> Bool {
        KeychainPrivateMediaKeyProvider(role: role).mediaKey() != nil
    }

    /// The purpose the wall seals and opens its index under: today
    /// `FernletCryptoPurpose.AEAD.privateFriendPhotoIndexV2`.
    static var wallIndexPurpose: CryptographicPurpose {
        FernletCryptoPurpose.AEAD.privateFriendPhotoIndexV2
    }

    /// The purpose the pending corpus seals and opens a held photo's full-size file under: today
    /// `FernletCryptoPurpose.AEAD.privatePendingSessionPhotoImageV1`.
    static var heldPhotoImagePurpose: CryptographicPurpose {
        FernletCryptoPurpose.AEAD.privatePendingSessionPhotoImageV1
    }

    /// The decoder the wall reads its index with: today a `JSONDecoder` with ISO-8601 dates.
    static func wallIndexDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// The vouch list a composition's mesh would send with the broadcast gate forced on: today
    /// `FernletVouchList.isVouchListBroadcastEnabled` and the list the mesh's vouch-list send asks its
    /// `vouchListExchange` for (plan step A0.5.5, when the vouch content left the engine; until then
    /// the manager's `vouchListPayloadForBroadcast()`).
    static func vouchListToSend(on features: FernletMeshFeatures) -> FriendVouchList? {
        features.vouchList.isVouchListBroadcastEnabled = true
        return features.mesh.vouchListExchange?.vouchListForBroadcast()
    }

    /// The friend-of-friend label a composition shows for `fingerprint`: today
    /// `FernletVouchList.vouchLabel(for:)`, which the camera reads (plan step A0.5.5; the manager's
    /// `vouchLabel(for:)` until then).
    static func vouchLabel(for fingerprint: String, on features: FernletMeshFeatures) -> String? {
        features.vouchList.vouchLabel(for: fingerprint)
    }

    /// Makes `peer` a kept friend in `store`'s vault: today `ProximityTrustVault.trust(_:mode:)` on
    /// `FernletStore.proximityTrustVault`, which the features' kept-friend gates read through
    /// `FernletSocialHost.proximityTrustStore` and the vouch list through `trustedProximityPeers`, as
    /// `MeshRoutedHeartTests` seeds its friends.
    static func keep(_ peer: ProximityCoordinator.PeerIdentity, in store: FernletStore) {
        store.proximityTrustVault.trust(peer, mode: .friend)
    }

    /// The token each commit-time feature frame is signed under, by name: today Fernlet's `PayloadType`
    /// raw values, spelled at each feature's send, the activity offer's as its send's `type.rawValue`.
    /// Their spellings are `ProximityVocabularyGoldenTests`' payload rows; this table names which frame
    /// is which, never a spelling.
    static var featureTokens: [String: String] {
        ["catalog": PayloadType.clothingCatalog.rawValue, "catalogRequest": PayloadType.clothingCatalogRequest.rawValue,
         "itemReport": PayloadType.itemReport.rawValue, "friendState": PayloadType.friendState.rawValue,
         "activityOffer": PayloadType.activityOffer.rawValue]
    }

    /// A ``SessionRig`` whose bob advertises `capabilities` and is a kept friend, not yet seated, with
    /// the pending corpus on an in-memory key: a scratch store
    /// (`makeTestStore(proximitySupportDirectory:)`), planted alice and bob, Fernlet's composition over
    /// alice (its mesh the rig's manager; plan step A0.5.6, when the shop and the session observer
    /// joined it) and one link of a fake fabric for bob's slot, as
    /// `ProximityVocabularyGoldenTests.sealedCatalog(underHostOf:peerAdvertising:)` builds its own. A
    /// planting that fails removes what was made.
    static func sessionRig(bobAdvertising capabilities: [String]) throws -> SessionRig {
        let root = scratchDirectory()
        let services = [throwawayService(), throwawayService()]
        do {
            let store = makeTestStore(proximitySupportDirectory: root)
            let alice = try plantedAlice(service: services[0])
            let bob = try plantedIdentity(signing: bobSigningRaw, keyAgreement: bobKeyAgreementRaw, service: services[1])
            keep(bobPeerIdentity(id: UUID(), capabilities: capabilities), in: store)
            let features = meshFeatures(over: store, identity: alice, heldPhotoKeys: SwitchableMediaKeyProvider())
            let network = FakePeerNetwork()
            return SessionRig(root: root, services: services, store: store, alice: alice, bob: bob, features: features,
                              network: network, link: network.addEndpoint(named: "ffgt-session-peer"),
                              capabilities: capabilities)
        } catch {
            sweep(services)
            removeDirectory(root)
            throw error
        }
    }

    /// Seats bob on a committed slot of his link, his key-agreement key verified and his capabilities as
    /// the rig names them: today `addSlotForTesting`, over the slot coordinator the json and vocabulary
    /// rigs build.
    static func seatBob(in rig: SessionRig) {
        rig.manager.addSlotForTesting(
            coordinator: ProximityCoordinator(
                identity: rig.alice, transport: MockMultipeerTransport(), ranging: MockRangingProvider(),
                replayCache: ReplayCache(), displayName: "Alice", timeoutSeconds: 0),
            peer: rig.link.handle, fingerprint: bobFingerprint, verifiedKeyAgreementPublicKey: bobPub,
            peerCapabilities: rig.capabilities, channel: rig.link.transport)
    }

    /// Runs the commit hook for bob's seated slot: today `noteSlotCommittedForShop(slot:identity:)`,
    /// which `onSlotConnected` calls at every commit, and which tells the composition's session observer
    /// the commit (plan step A0.5.6) before the engine's own legs.
    static func commitBob(in rig: SessionRig) throws {
        let slot = try #require(rig.manager.slots.first, "the manager seated no slot")
        let bob = bobPeerIdentity(id: slot.id, capabilities: rig.capabilities)
        rig.manager.noteSlotCommittedForShop(slot: slot, identity: bob)
    }

    /// Every frame the mesh sent on bob's link, in send order, decoded as the envelope it is: today
    /// `FakePeerTransport.sentFrames`, appended inside `send` with no suspension before it.
    static func envelopes(sentIn rig: SessionRig) -> [FernletIdentityEnvelope] {
        rig.link.transport.sentFrames.compactMap { try? JSONDecoder().decode(FernletIdentityEnvelope.self, from: $0.data) }
    }

    /// Yields until the mesh has sent bob an envelope under each of `tokens`, a bounded number of times:
    /// `VocabularyCoordinatorRig.settle(_:)`. A commit's sends run on main-actor tasks it spawns.
    static func settle(_ rig: SessionRig, untilSent tokens: [String]) async {
        await VocabularyCoordinatorRig.settle {
            let sent = Set(envelopes(sentIn: rig).map(\.payloadTypeToken))
            return tokens.allSatisfy { sent.contains($0) }
        }
    }

    /// bob's open of a body the mesh sealed to him, read in the legacy framing, which leaves a wire2
    /// frame tag in place: today `IdentityService.open(_:from:format:)`.
    static func openedByBob(_ envelope: FernletIdentityEnvelope, in rig: SessionRig) throws -> Data {
        try rig.bob.open(envelope.payload, from: envelope.senderKeyAgreementPublicKey, format: .legacy)
    }

    /// Removes the rig's keychain rows and root, holding the composition, the store and the fabric to
    /// the end: the composition owns the manager and its features, whose sends hold them weakly (the
    /// manager holds its session observer weakly too), they hold their store `unowned`, and the link
    /// holds the fabric weakly.
    static func tearDown(_ rig: SessionRig) {
        withExtendedLifetime((rig.features, rig.store, rig.network)) {}
        sweep(rig.services)
        removeDirectory(rig.root)
    }

    /// Arms alice's two commit-time sends to a kept friend: her own rows M1 and M2 as the reports to
    /// sign, the friend-state opt-in on and ``friendStateFixture`` as the state to send. Today the
    /// composition's `moderation.ownModerationReportsProvider` and `friendState.isEnabledProvider` and
    /// `friendState.payloadProvider` (the manager's `ownModerationReportsProvider`,
    /// `friendStateEnabledProvider` and `friendStatePayloadProvider` until plan step A0.5.7 moved them,
    /// setup only), which the app wires; the opt-in gates only what alice advertises and is set as the
    /// app sets it for a user who shares.
    static func armReportAndState(in rig: SessionRig) {
        let rows = [moderationReport, moderationRetract]
        let state = friendStateFixture
        rig.features.moderation.ownModerationReportsProvider = { rows }
        rig.features.friendState.isEnabledProvider = { true }
        rig.features.friendState.payloadProvider = { state }
    }

    /// The item report and the friend state the mesh sends bob at his commit, each with bob's open of its
    /// body: a ``SessionRig`` whose bob advertises `moderation` and `friendState` alone, both sends
    /// armed, bob seated and committed, and the fabric settled until both have left.
    static func reportAndStateSentOnCommit() async throws -> (report: SentToBob, state: SentToBob) {
        let capabilities = [ProximityCapability.moderation.rawValue, ProximityCapability.friendState.rawValue]
        let rig = try sessionRig(bobAdvertising: capabilities)
        defer { tearDown(rig) }
        armReportAndState(in: rig)
        seatBob(in: rig)
        try commitBob(in: rig)
        let tokens = ["itemReport", "friendState"].map { featureToken($0) }
        await settle(rig, untilSent: tokens)
        let sent = envelopes(sentIn: rig)
        let report = try #require(sent.first { $0.payloadTypeToken == tokens[0] }, "the mesh sent bob no item report")
        let state = try #require(sent.first { $0.payloadTypeToken == tokens[1] }, "the mesh sent bob no friend state")
        let reportBody = try openedByBob(report, in: rig)
        let stateBody = try openedByBob(state, in: rig)
        return (SentToBob(envelope: report, body: reportBody), SentToBob(envelope: state, body: stateBody))
    }

    /// The camera's hold-failure line as the camera resolves it: today
    /// `ProximityUICopy.Camera.holdFailed`, which the manager publishes as `meshError` when a capture
    /// cannot be held. Re-pointed at A0.5.11 to `FernletSocialCopy`.
    static var cameraHoldFailedLine: String {
        ProximityUICopy.Camera.holdFailed
    }

    /// The file that declares the line: today ProximityKit's copy vault. Re-pointed at A0.5.11 to
    /// `FernletSocialCopy`'s file.
    static let cameraCopyVaultPath = "FernletKit/Sources/ProximityKit/UI/ProximityUICopy.swift"

    /// The catalog that files the line: today ProximityKit's, which `Scripts/sync-string-catalogs.sh`
    /// syncs. Re-pointed at A0.5.11 to FernletSocial's.
    static let cameraCopyCatalogPath = "FernletKit/Sources/ProximityKit/Localizable.xcstrings"

    /// Hands `request` to `manager` as bob's, with bob's transport-verified fingerprint and keys: today
    /// `ProximityActivityManager.receiveJoinRequest(...)`, handed the verified fingerprint and both
    /// verified keys. Re-pointed at A0.5.8 only if the activity manager's spelling changes (it moves
    /// whole).
    static func receiveFromBob(_ request: ActivityJoinRequest, on manager: ProximityActivityManager) {
        manager.receiveJoinRequest(request, verifiedFingerprint: bobFingerprint,
                                   verifiedSigningPublicKey: bobSigningPub,
                                   verifiedKeyAgreementPublicKey: bobPub)
    }

    /// Saves `state` through a JSON sidecar over `fileURL`: today ProximityKit's package
    /// `JSONSidecarFile` (its `init(fileURL:)` and `save(_:)`), which plan step A0.5.11 moves whole to
    /// FernletSocial, where those members become internal; re-pointed then only in its import, through
    /// `@testable import FernletSocial`.
    static func saveSidecar<State: Codable>(_ state: State, to fileURL: URL) {
        JSONSidecarFile<State>(fileURL: fileURL).save(state)
    }

    /// Delivers a `type` frame to `manager` from a committed slot whose peer the transport never
    /// verified, the payload door's `nil` identity: today
    /// `addSlotForTesting(coordinator:peer:fingerprint:)` and
    /// `proximityCoordinator(_:didReceive:plaintext:from:)`, the dispatch `MeshClothingShopTests` drives
    /// with a verified identity. The slot proves no key, so the frame is attributable and reaches the
    /// feature's handler: the catalog's and the request's are the composition's shop exchange's, on its
    /// mesh's payload registry, since plan step A0.5.6 (so `manager` is a composition's mesh,
    /// ``AuditMeshRig``), and the item report's and the friend state's its moderation and friend-state
    /// exchanges' since plan step A0.5.7.
    static func deliverUnverified(_ type: PayloadType, to manager: MeshNetworkManager,
                                  coordinatorIdentity: IdentityService) {
        let coordinator = ProximityCoordinator(
            identity: coordinatorIdentity, transport: MockMultipeerTransport(), ranging: MockRangingProvider(),
            replayCache: ReplayCache(), displayName: "Alice", timeoutSeconds: 0)
        let handle = PeerHandle(id: UUID(), displayHint: "Unverified", discoveryInfo: nil, advertisedFingerprint: nil)
        manager.addSlotForTesting(coordinator: coordinator, peer: handle, fingerprint: bobFingerprint)
        let frame = unverifiedFrame(type)
        manager.proximityCoordinator(coordinator, didReceive: frame, plaintext: frame.payload, from: nil)
    }

    /// Sends one in-session heart to `friend` from `hearts`: today the composition's session hearts'
    /// `sendSessionHeart(to:)` (FernletSocial's `MeshSessionHearts`; the manager's until plan step
    /// A0.5.10, when this re-pointed).
    static func sendSessionHeart(to friend: ProximityTrustedPeerRecord, from hearts: MeshSessionHearts) {
        hearts.sendSessionHeart(to: friend)
    }

    /// Sets the hearts opt-in the session hearts read off their host: today
    /// `FernletStore.setAllowNearbyHearts(_:)`, read through `FernletSocialHost.allowNearbyHearts` (a
    /// `ProximityHost` requirement until plan step A0.5.10).
    static func allowNearbyHearts(_ allowed: Bool, in store: FernletStore) {
        store.setAllowNearbyHearts(allowed)
    }

    /// Wires `ledger` as the one `hearts` gate and record on: today their `heartLedger` (the manager's
    /// until plan step A0.5.10, when this re-pointed).
    static func wireHeartLedger(_ ledger: ProximityHeartLedger, into hearts: MeshSessionHearts) {
        hearts.heartLedger = ledger
    }

    /// Takes the in-flight heart claim for `fingerprint` and leaves it held: today the session hearts'
    /// `claimSessionHeartForTesting(_:)` (the manager's until plan step A0.5.10, when this re-pointed).
    static func claimSessionHeart(for fingerprint: String, on hearts: MeshSessionHearts) {
        hearts.claimSessionHeartForTesting(fingerprint)
    }

    /// Opens the 13+ chat gate on `chat`: today the composition's chat's `chatAllowedProvider`
    /// (FernletSocial's `MeshSessionChat`; the manager's until plan step A0.5.9, when this re-pointed).
    static func allowChat(on chat: MeshSessionChat) {
        chat.chatAllowedProvider = { true }
    }

    /// Sends one chat message from `chat` and answers what the send decided: today the composition's
    /// chat's `sendTempMessage(_:)`, through the mesh's origination door. Re-pointed at A0.5.9.
    static func sendChat(_ text: String, from chat: MeshSessionChat) -> MeshTextSendOutcome {
        chat.sendTempMessage(text)
    }

    /// Whether `chat`'s incoming per-origin text quota admits `messageID` from `manifest`'s origin in its
    /// mesh: today the chat's `allowIncomingRoutedText(_:from:)` over the item's `(mesh, origin)` key,
    /// through the test target's manifest binding. Re-pointed at A0.5.9.
    static func textQuotaAdmits(_ messageID: UUID, from manifest: MeshRoutedManifest,
                                on chat: MeshSessionChat) -> Bool {
        chat.allowIncomingRoutedText(messageID, from: manifest)
    }

    /// How many messages one origin may have accepted in one mesh: today
    /// `MeshSessionChat.maxTextMessagesPerSenderPerSession`. Re-pointed at A0.5.9.
    static var textQuotaCap: Int {
        MeshSessionChat.maxTextMessagesPerSenderPerSession
    }

    /// How many `(mesh, origin)` keys the text quota's map holds: today `MeshRoutedStoreFormat.maxItems`,
    /// the routed store's item cap, which stays in ProximityKit.
    static var textQuotaKeyBound: Int {
        MeshRoutedStoreFormat.maxItems
    }

    /// The transcript store's three answers to an offered message, as the audit line spells them: today
    /// `SessionMessageStore.Acceptance`. Re-pointed at A0.5.9 only in its home.
    static var transcriptAcceptanceTokens: [String] {
        [SessionMessageStore.Acceptance.appended, .alreadyHeld, .emptyAfterSanitizing].map(\.rawValue)
    }

    /// Asks `manager` to delete a wall photo: today `deletePhoto(_:)`. Re-pointed at A0.5.11.
    static func deleteWallPhoto(_ photoID: UUID, on manager: MeshNetworkManager) {
        manager.deletePhoto(photoID)
    }

    /// The batch of ended-session photos and candidates `manager` offers for review: today
    /// `pendingFriendReview`. Re-pointed at A0.5.11.
    static func pendingReview(on manager: MeshNetworkManager) -> MeshFriendReviewBatch? {
        manager.pendingFriendReview
    }

    /// The session-end review's answer for the photos it showed: today
    /// `finishReviewedPhotos(_:keeping:in:)`. Re-pointed at A0.5.11.
    static func answerReview(showing reviewed: Set<UUID>, keeping kept: Set<UUID>, in batchID: UUID,
                             on manager: MeshNetworkManager) -> SessionPhotoAnswer {
        manager.finishReviewedPhotos(reviewed, keeping: kept, in: batchID)
    }

    /// The in-camera Develop review's answer for the photos it showed: today
    /// `finishSessionPhotos(keeping:of:)`. Re-pointed at A0.5.11.
    static func answerDevelop(showing reviewed: Set<UUID>, keeping kept: Set<UUID>,
                              on manager: MeshNetworkManager) -> SessionPhotoAnswer {
        manager.finishSessionPhotos(keeping: kept, of: reviewed)
    }

    /// The one engine every photo answer runs through, asked directly so an answer can name a photo no
    /// list shows: today the internal `applyPhotoAnswers(kept:discarded:now:)`. Re-pointed at A0.5.11.
    static func applyPhotoAnswers(kept: Set<UUID>, discarded: Set<UUID>,
                                  on manager: MeshNetworkManager) -> SessionPhotoAnswer {
        manager.applyPhotoAnswers(kept: kept, discarded: discarded, now: Date())
    }

    /// Delete-all's leg for the photos nobody chose yet: today `purgeHeldSessionPhotosForDeleteAll()`.
    /// Re-pointed at A0.5.11.
    static func purgeHeldPhotos(on manager: MeshNetworkManager) -> Bool {
        manager.purgeHeldSessionPhotosForDeleteAll()
    }

    /// Pushes the open routed gate into `manager`: today `applyRoutedAccessGate(_:now:)` through the
    /// held-photo suites' `HeldPhotos.openGate(on:now:)`, which pins the install binding the rising
    /// edge's pass may read. The gate door stays in ProximityKit; nothing here is re-pointed.
    static func openRoutedGate(on manager: MeshNetworkManager) {
        HeldPhotos.openGate(on: manager)
    }

    /// Pushes the duress gate into `manager` from an open one, an edge that runs no pass (no ciphertext
    /// leg rises and no duress clears): today `applyRoutedAccessGate(_:now:)` with
    /// `HeldPhotoFixtures.duressGate`.
    static func pushDuressGate(on manager: MeshNetworkManager) {
        manager.applyRoutedAccessGate(HeldPhotoFixtures.duressGate, now: Date())
    }

    /// The most photos the pending corpus holds: today `PendingSessionPhotoStore.maxHeldPhotos`, which
    /// stays in PrivateMediaStore.
    static var heldPhotoBound: Int {
        PendingSessionPhotoStore.maxHeldPhotos
    }

    /// A held photo's sealed full-size file under `store`'s proximity root: today
    /// `HeldPhotoFixtures.pendingImageURL(_:localID:)`, over `PendingSessionPhotoStore`'s frozen names.
    static func heldImageFile(in store: FernletStore, localID: UUID) -> URL {
        HeldPhotoFixtures.pendingImageURL(store, localID: localID)
    }

    /// The wall's legacy plaintext index under `root`, the generation read when no sealed index exists:
    /// today `MeshPhotoCache.json`, the name the manager joins under its host's root.
    static func legacyWallIndex(in root: URL) -> URL {
        root.appendingPathComponent("MeshPhotoCache.json")
    }

    /// Puts a folder where the wall's sealed index belongs, so it exists and cannot be read, and returns
    /// where any real index was set aside: today `HeldPhotoFixtures.makeWallUnreadable(_:)`.
    static func makeWallUnreadable(_ store: FernletStore) throws -> URL {
        try HeldPhotoFixtures.makeWallUnreadable(store)
    }

    /// Undoes ``makeWallUnreadable(_:)``: today `HeldPhotoFixtures.restoreWall(_:aside:)`.
    static func restoreWall(_ store: FernletStore, aside: URL) throws {
        try HeldPhotoFixtures.restoreWall(store, aside: aside)
    }

    /// Commits the held photo `localID`, read back from `store`'s pending corpus under `keys`, onto
    /// `store`'s wall under the process-wide wall key, and answers which ids the wall took: today
    /// `PendingSessionPhotoStore(directory:keyProvider:)`, `load(now:)`,
    /// `PendingSessionPhotoIndex.heldPhoto(localID:)`, `hydrated(_:)` and
    /// `PrivateMediaStore.commitKept(_:onto:)` over `HeldPhotoFixtures.wallStore(_:)`.
    static func commitHeldPhotoToWall(_ localID: UUID, in store: FernletStore,
                                      keys: SwitchableMediaKeyProvider) throws -> Set<UUID> {
        let pending = PendingSessionPhotoStore(directory: HeldPhotoFixtures.pendingDirectory(store), keyProvider: keys)
        guard case .loaded(let index) = pending.load(now: Date()) else { throw HeldPhotoCellFailure.pendingUnreadable }
        let held = try #require(index.heldPhoto(localID: localID), "the photo is not in the pending index")
        let hydrated = try #require(pending.hydrated(held), "the held photo's bytes do not open")
        let wall = HeldPhotoFixtures.wallStore(store)
        return wall.commitKept([hydrated], onto: wall.load()).keptOnWall
    }

    /// Every capability token a Fernlet build knows: today `ProximityCapability.allCases`, the list
    /// `MeshRoutedHeartTests` hands its peers.
    static var everyCapability: [String] {
        ProximityCapability.allCases.map(\.rawValue)
    }

    /// Opts alice's shop in with group 20's frozen catalog: today the two providers of the composition's
    /// shop (plan step A0.5.6; setup only).
    static func armShop(in rig: SessionRig) {
        let catalog = aliceCatalog
        rig.features.clothingShop.isSharingEnabledProvider = { true }
        rig.features.clothingShop.localCatalogProvider = { catalog }
    }

    /// Has alice host one hour-long activity, so a commit with an `activities` peer offers it: today
    /// `ProximityActivityManager.host(title:activityTypeToken:coarseLocation:expiresAt:)` on the
    /// composition's `activities` (the manager's until plan step A0.5.8; setup only). Called before bob
    /// is seated, since a host offers at once to every committed peer.
    static func hostActivity(in rig: SessionRig) -> ActivityDescriptor? {
        rig.features.activities.host(title: "Sunset walk", activityTypeToken: "walk", coarseLocation: nil,
                                     expiresAt: Date().addingTimeInterval(3_600))
    }

    /// Notes the commit's three observable moments into `recorder`, each with how many frames bob's link
    /// had carried when it fired: today the composition's closeness hook `onFriendSessionCommitted` and
    /// its shop exchange's `onShopCatalogSendForTesting` (fired before the catalog's send) and
    /// `onShopCatalogRequestSendForTesting` (fired after the request's send), plan step A0.5.6.
    static func recordCommitHooks(of rig: SessionRig, into recorder: LifecycleRecorder) {
        let link = rig.link.transport
        let shop = rig.features.shopExchange
        rig.features.onFriendSessionCommitted = { _ in recorder.note("closeness@\(link.sentFrames.count)") }
        shop.onShopCatalogSendForTesting = { _ in recorder.note("catalogSend@\(link.sentFrames.count)") }
        shop.onShopCatalogRequestSendForTesting = { _ in
            recorder.note("catalogRequestSent@\(link.sentFrames.count)")
        }
    }

    /// Holds `photo` in the live session, stamped with the session's metadata and listed in the live
    /// roll, keyed by its sender and id: today `holdSessionPhoto(_:key:live:)` with `live` true:
    /// ``hold(_:on:)`` for a live photo. Re-pointed at A0.5.11.
    static func holdLive(_ photo: FriendPhotoPayload, on manager: MeshNetworkManager) -> PendingSessionPhotoStore.Hold {
        let key = MeshContentKey(senderFingerprint: photo.senderFingerprint ?? "", contentID: photo.id)
        return manager.holdSessionPhoto(photo, key: key, live: true)
    }

    /// Gives the rig's session one thing for each leg of its end to act on, each through today's seam:
    /// bob in the live roster (`recordSessionParticipant`, the commit's own ingest); one live photo
    /// (``holdLive(_:on:)``); bob's catalog held by the opted-in shop (`MeshClothingShop.receiveCatalog`,
    /// over group 20's frozen catalog in an envelope bob signs); one message (the composition's chat's
    /// `SessionMessageStore.appendOutgoing` since A0.5.9); and a heart to bob refused with the hearts opt-in off
    /// (the composition's hearts' `sendSessionHeart(to:)`), so the heart state is not idle. Re-pointed
    /// leg by leg at A0.5.6 (shop),
    /// A0.5.9 (chat), A0.5.10 (hearts) and A0.5.11 (photos, review).
    static func armSessionToEnd(_ rig: SessionRig) throws {
        let manager = rig.manager
        manager.recordSessionParticipant(displayName: "Bob", fingerprint: bobFingerprint, signingPublicKey: bobSigningPub,
                                         keyAgreementPublicKey: bobPub)
        try #require(holdLive(sessionPhoto(1), on: manager) == .held, "the live photo was not held")
        let catalog = Data(frozenCatalogJSON.utf8)
        let token = featureToken("catalog")
        let envelope = try FernletIdentityEnvelope.signed(
            identityService: rig.bob, senderDisplayName: "Bob", payloadTypeToken: token,
            payloadSummary: PayloadSummary(title: token), payload: catalog)
        rig.features.clothingShop.isSharingEnabledProvider = { true }
        rig.features.clothingShop.receiveCatalog(envelope, plaintext: catalog, verifiedFingerprint: bobFingerprint)
        rig.features.chat.sessionMessages.appendOutgoing(
            id: uuid("7E57A9E0-4841-4E44-8000-000000000031"), senderFingerprint: aliceFingerprint,
            senderDisplayName: "Alice", text: "frozen", sentAt: Date(timeIntervalSinceReferenceDate: 780_000_000))
        rig.store.settings.allowNearbyHearts = false
        rig.features.hearts.sendSessionHeart(to: bobAsFriend)
    }

    /// Notes each leg of a session end into `recorder` where it begins: the roster's first change (the
    /// merge empties it), the photo move's audit line (`mesh.session.photosPendingReview`), and the first
    /// changes of the shop window (the rig's composition's shop since plan step A0.5.6), the transcript
    /// (its chat's since A0.5.9) and the heart state (its session hearts' since A0.5.10). Through
    /// Observation (`withObservationTracking`, one
    /// change each, as `MeshFavoriteObservationTests` observes the manager) and
    /// `FernletAuditLog.addCaptureHandler`.
    /// Nothing the teardown runs before its legs writes any of the five. Re-pointed with each leg.
    static func recordSessionEnd(of rig: SessionRig, into recorder: LifecycleRecorder) {
        let manager = rig.manager
        withObservationTracking { _ = manager.sessionRoster } onChange: { recorder.note("reviewMerge") }
        recorder.install(noting: "photoMove", whenLogged: "mesh.session.photosPendingReview")
        withObservationTracking { _ = rig.features.clothingShop.window } onChange: { recorder.note("shopWindow") }
        withObservationTracking { _ = rig.features.chat.sessionMessages.messages } onChange: { recorder.note("transcriptClear") }
        withObservationTracking { _ = rig.features.hearts.sessionHeartState } onChange: { recorder.note("heartReset") }
    }

    /// Ends the session on this device, telling nobody: today `leaveSession()`, which tears down through
    /// `leaveMesh()` and `stopSearching()`, whose last call, `endSessionIfEnded()`, runs a session end's
    /// legs, and then forgets the photo session's ids.
    static func endSession(_ manager: MeshNetworkManager) {
        manager.leaveSession()
    }

    /// Starts a new search, which is a new session: today `startJoin()`.
    static func startNewSearch(on manager: MeshNetworkManager) {
        manager.startJoin()
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

    /// The seal probes' content key: the sidecar key's bytes 0xa0…0xbf, reused because nothing is derived
    /// from it. The probes read only the sizes the seal and the open take and refuse.
    static var routedProbeKey: Data { consecutiveBytes(from: 0xa0) }

    /// The seal probes' binding: a fixture mesh and item, and alice's fingerprint as the origin.
    static var routedProbeBinding: MeshRoutedWrapBinding {
        MeshRoutedWrapBinding(meshID: uuid("0A050000-7AB1-4E50-8000-000000000001"),
                              itemID: uuid("0A050000-7AB1-4E50-8000-000000000002"),
                              originFingerprint: aliceFingerprint)
    }

    /// The frozen array of capability state `state`; empty for a state no row holds, which fails what
    /// reads it.
    static func frozenCapabilityArray(_ state: String) -> [String] {
        advertisedCapabilityArrays.first { $0.state == state }?.array ?? []
    }

    /// The frozen number `field`; -1 for a field no row holds, which fails what reads it.
    static func frozenNumber(_ field: String) -> Int {
        routedCapNumbers.first { $0.field == field }?.frozen ?? -1
    }

    /// The frozen token `sender` mints under; empty for a sender no row holds, which fails what reads it.
    static func frozenMintedToken(_ sender: String) -> String {
        mintedTypeTokens.first { $0.sender == sender }?.token ?? ""
    }

    /// Compares every number row with its frozen value; returns how many rows were compared.
    static func expectFrozen(_ rows: [FeatureGoldenNumberRow]) -> Int {
        // R2: bounded by the rows.
        for row in rows {
            #expect(row.today == row.frozen, "\(row.field) is \(row.today); its frozen value is \(row.frozen)")
        }
        return rows.count
    }

    /// Member `index` of `rig` as a kept friend, the record the heart sender is handed.
    static func heartRecipient(_ index: Int, in rig: MeshFoundingRig) -> ProximityTrustedPeerRecord {
        let met = Date(timeIntervalSince1970: 1_700_000_000)
        return ProximityTrustedPeerRecord(
            displayName: "Bob", fingerprint: rig.nodes[index].fingerprint,
            signingPublicKey: rig.identities[index].localSigningPublicKey,
            keyAgreementPublicKey: rig.identities[index].localKeyAgreementPublicKey,
            mode: .friend, firstAcceptedAt: met, lastSeenAt: met)
    }

    /// Mints one item of `sender` from member `node` through that sender's accessor, the heart to member
    /// `recipient`. An unknown sender mints nothing, which fails the cell that asked.
    static func mint(_ sender: String, from node: Int, to recipient: Int, in rig: MeshFoundingRig) {
        switch sender {
        case "photo": sendPhoto(at: node, in: rig)
        case "tempMessage": _ = sendText("frozen", at: node, in: rig)
        case "heart": sendHeart(from: node, to: heartRecipient(recipient, in: rig), in: rig)
        default: return
        }
    }

    /// The routed body framing, `u64BE(header.count) ‖ header ‖ payload` (with the prefix as
    /// `CanonicalByteWriter.appendLengthPrefixed` writes it). It is spelled here apart from production,
    /// so that each frozen JSON and its frozen hex are held to be two spellings of one body.
    static func framedBody(header: Data, payload: Data = Data()) -> Data {
        var bytes = Data()
        // R2: bounded by the prefix's eight bytes.
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: UInt64(header.count) >> UInt64(shift)))
        }
        return bytes + header + payload
    }

    /// alice's signing public key, as bytes.
    static var aliceSigningPub: Data { bytes(fromHex: aliceSigningPubHex) }
    /// bob's signing public key, as bytes.
    static var bobSigningPub: Data { bytes(fromHex: bobSigningPubHex) }

    /// The activity alice hosts in group 19, named by every descriptor, the join token and the rosters,
    /// and carried by groups 20 and 22's payloads and ledger.
    static var activityID: UUID { uuid("A1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D") }

    /// The purpose production reads for the transcript label row `field`; nil for a field no row holds,
    /// which fails what reads it.
    static func todayLabel(_ field: String) -> CryptographicPurpose? {
        transcriptLabelRows.first { $0.field == field }?.today
    }

    /// A descriptor of alice's activity: its id, her fingerprint and signing key, and the title, type
    /// token, location and dates given, the dates in seconds after the reference date.
    static func aliceActivity(title: String, type: String, location: String?, created: TimeInterval,
                              expires: TimeInterval) -> ActivityDescriptor {
        ActivityDescriptor(
            activityID: activityID, hostFingerprint: aliceFingerprint, hostSigningPublicKey: aliceSigningPub,
            title: title, activityTypeToken: type, coarseLocation: location,
            createdAt: Date(timeIntervalSinceReferenceDate: created), expiresAt: Date(timeIntervalSinceReferenceDate: expires))
    }

    /// D1: alice's walk, located in Portland, with whole-second dates an hour apart: the descriptor
    /// group 19 hashes, its join token binds and group 20's offer carries.
    static var descriptorD1: ActivityDescriptor {
        aliceActivity(title: "Sunset walk", type: "walk", location: "Portland", created: 780_000_000, expires: 780_003_600)
    }

    /// D2: no location, a non-ASCII title, fractional dates.
    static var descriptorD2: ActivityDescriptor {
        aliceActivity(title: "Caf\u{E9} crawl \u{2615}", type: "coffee", location: nil,
                      created: 780_000_000.75, expires: 780_003_599.5)
    }

    /// J1: alice's grant of bob's join to D1's activity, 600 s after creating it, until D1's expiry, at
    /// roster version 2, carrying `signature` as its host signature.
    static func joinToken(signature: Data) -> ActivityJoinToken {
        ActivityJoinToken(
            schemaVersion: 1, activityID: activityID, activityParamsHash: bytes(fromHex: descriptorD1ParamsHashHex),
            joinerFingerprint: bobFingerprint, joinerSigningPublicKey: bobSigningPub,
            hostFingerprint: aliceFingerprint, hostSigningPublicKey: aliceSigningPub,
            grantedAt: Date(timeIntervalSinceReferenceDate: 780_000_600),
            expiresAt: Date(timeIntervalSinceReferenceDate: 780_003_600), rosterVersionAtGrant: 2, hostSignature: signature)
    }

    /// J1's verify as bob runs it: his own key presented, the activity's id, D1's frozen hash and alice's
    /// key pinned, at 780 001 800 s after the reference date, half an hour before J1 expires.
    static func verifyJoinTokenAsBob(_ token: ActivityJoinToken) throws {
        try verifyJoinToken(token, presentedKey: bobSigningPub, activityID: activityID,
                            paramsHash: bytes(fromHex: descriptorD1ParamsHashHex), hostKey: aliceSigningPub,
                            now: Date(timeIntervalSinceReferenceDate: 780_001_800))
    }

    /// alice as a roster member: her fingerprint, `Alice`, both her keys, joined 780 000 000 s after the
    /// reference date.
    static var rosterAlice: ActivityParticipant {
        ActivityParticipant(fingerprint: aliceFingerprint, displayName: "Alice", signingPublicKey: aliceSigningPub,
                            keyAgreementPublicKey: alicePub, joinedAt: Date(timeIntervalSinceReferenceDate: 780_000_000))
    }

    /// bob as a roster member: his fingerprint, `B\u{F8}b \u{1F33F}` (9 UTF-8 bytes, 5 Characters), both
    /// his keys, joined 780 000 600.5 s after the reference date.
    static var rosterBob: ActivityParticipant {
        ActivityParticipant(fingerprint: bobFingerprint, displayName: "B\u{F8}b \u{1F33F}", signingPublicKey: bobSigningPub,
                            keyAgreementPublicKey: bobPub, joinedAt: Date(timeIntervalSinceReferenceDate: 780_000_600.5))
    }

    /// Guest `k` (3…13), a roster filler:
    /// - a fingerprint of k's two hex digits written eight times, and the name `Guest k`;
    /// - k repeated as its signing key and 0x10 + k as its key-agreement key, stand-in bytes from which
    ///   nothing is derived;
    /// - joined 780 001 000 + 10k s after the reference date.
    static func rosterGuest(_ k: UInt8) -> ActivityParticipant {
        ActivityParticipant(
            fingerprint: String(repeating: String(format: "%02x", k), count: 8), displayName: "Guest \(k)",
            signingPublicKey: Data(repeating: k, count: 32), keyAgreementPublicKey: Data(repeating: 0x10 + k, count: 32),
            joinedAt: Date(timeIntervalSinceReferenceDate: 780_001_000 + 10 * TimeInterval(k)))
    }

    /// The first `count` members of the group's rosters, in the host's order: alice, bob, then guests
    /// from 3.
    static func rosterMembers(_ count: UInt8) -> [ActivityParticipant] {
        [rosterAlice, rosterBob] + stride(from: UInt8(3), through: count, by: 1).map { rosterGuest($0) }
    }

    /// A roster of alice's activity that she issued `issuedAt` s after the reference date, carrying
    /// `signature` as its host signature.
    static func roster(version: Int, members: [ActivityParticipant], issuedAt: TimeInterval,
                       signature: Data) -> ActivityRosterSnapshot {
        ActivityRosterSnapshot(
            schemaVersion: 1, activityID: activityID, version: version, participants: members,
            issuedAt: Date(timeIntervalSinceReferenceDate: issuedAt), hostSigningPublicKey: aliceSigningPub,
            hostSignature: signature)
    }

    /// A row of alice's about bob's artwork `abcd`, with group 10's item and reason, and the id, kind,
    /// sequence and creation time given.
    static func moderationRow(id: String, kind: ModerationEntryKind, seq: UInt64, created: TimeInterval) -> ModerationLedgerEntry {
        ModerationLedgerEntry(
            id: id, kind: kind, reporterSigningPublicKey: aliceSigningPub, subjectSigningPublicKey: bobSigningPub,
            itemID: uuid("D1E2F3A4-B5C6-4D7E-8F90-A1B2C3D4E5F6"), contentHash: Data([0xab, 0xcd]),
            reasonToken: "offensive", reporterSeq: seq, createdAt: Date(timeIntervalSinceReferenceDate: created))
    }

    /// M1: alice's report of bob's artwork, group 10's ledger row field for field.
    static var moderationReport: ModerationLedgerEntry {
        moderationRow(id: "report:c945cbf2a5602002:abcd", kind: .report, seq: 1, created: 780_000_000)
    }

    /// M2: alice's retraction of it an hour later, which supersedes it by its higher sequence.
    static var moderationRetract: ModerationLedgerEntry {
        moderationRow(id: "retract:c945cbf2a5602002:abcd", kind: .retract, seq: 2, created: 780_003_600.75)
    }

    /// Decodes `frozen` as `T` with production's decoder and holds it to `expected`; holds `expected`'s
    /// sorted-keys encoding to `frozen` byte for byte; holds production's own encoding of it to `frozen`
    /// as a JSON object. Returns the decoded value.
    static func expectFrozenJSON<T: Codable & Equatable>(_ frozen: String, decodesTo expected: T, _ name: String) throws -> T {
        let decoded = try meshPayloadDecoder().decode(T.self, from: Data(frozen.utf8))
        #expect(decoded == expected, "\(name) decoded to \(decoded)")
        let sorted = try sortedJSON(expected)
        #expect(sorted == frozen, "\(name) encodes with sorted keys as \(sorted)")
        let produced = try meshPayloadEncoder().encode(expected)
        #expect(try jsonObjectsEqual(produced, Data(frozen.utf8)),
                "\(name) is written as \(String(decoding: produced, as: UTF8.self))")
        return decoded
    }

    /// `value` under the mesh's encoder with only `.sortedKeys` added: the frozen texts' spelling.
    static func sortedJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = meshPayloadEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// Whether two JSON texts are the same JSON object: key order free, array order kept.
    static func jsonObjectsEqual(_ lhs: Data, _ rhs: Data) throws -> Bool {
        let left = try JSONSerialization.jsonObject(with: lhs, options: [.fragmentsAllowed])
        let right = try JSONSerialization.jsonObject(with: rhs, options: [.fragmentsAllowed])
        return (left as? NSObject)?.isEqual(right) ?? false
    }

    /// The order-free shape of a wall-preferences file: its top-level keys, the aggregated sessions as a
    /// set, and each flat [key, value, …] array as a dictionary. Two files with this shape equal hold the
    /// same preferences.
    struct WallPreferencesShape: Equatable {
        /// The top-level keys.
        let keys: Set<String>
        /// `aggregatedSessionIDs`, as a set.
        let aggregated: Set<String>
        /// `coverPhotoIDsBySession`, its pairs as a dictionary.
        let covers: [String: String]
        /// `favoritePhotoIDsBySession`, its pairs as a dictionary.
        let favorites: [String: String]
    }

    /// Parses a wall-preferences file into its ``WallPreferencesShape``; a flat array of odd length, or a
    /// key that repeats, fails what reads it (an empty shape).
    static func wallPreferencesShape(_ data: Data) throws -> WallPreferencesShape {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        func pairs(_ key: String) -> [String: String] {
            let flat = object[key] as? [String] ?? []
            guard flat.count.isMultiple(of: 2) else { return ["odd": key] }
            // R2: bounded by the array.
            let keyed = stride(from: 0, to: flat.count, by: 2).map { (flat[$0], flat[$0 + 1]) }
            return Dictionary(keyed, uniquingKeysWith: { _, _ in "repeated" })
        }
        return WallPreferencesShape(keys: Set(object.keys), aggregated: Set(object["aggregatedSessionIDs"] as? [String] ?? []),
                                    covers: pairs("coverPhotoIDsBySession"), favorites: pairs("favoritePhotoIDsBySession"))
    }

    /// Holds the wall `manager` built from the frozen index and the (clean or pruned) preferences to its
    /// posts: S2's carousel P5 and P6 with P5 its cover, S1's P1 to P3 with its favorite P3 as cover,
    /// then P4 alone; S1's favorite P3 and no other; five entries.
    static func expectWallPosts(of manager: MeshNetworkManager) {
        let posts = manager.photoWallPosts
        let s1 = uuid("5E55100A-4A53-4F4E-8000-000000000021"), s2 = uuid("5E55100B-4A53-4F4E-8000-000000000022")
        let p = (1...6).map { uuid("F070000\($0)-4A53-4F4E-8000-00000000004\($0)") }
        #expect(posts.map(\.id) == [s2, s1, p[3]], "the wall's posts are \(posts.map(\.id))")
        #expect(posts.map(\.coverPhoto.id) == [p[4], p[2], p[3]], "the posts' covers are \(posts.map(\.coverPhoto.id))")
        #expect(posts.map { $0.photos.map(\.id) } == [[p[4], p[5]], [p[0], p[1], p[2]], [p[3]]])
        #expect(posts.map { manager.favoritePhotoID(for: $0) } == [nil, p[2], nil] && manager.allFavoritePhotoIDs == [p[2]])
        #expect(wallPreferenceEntryCount(manager) == 5, "the wall holds \(wallPreferenceEntryCount(manager)) preference entries")
    }

    /// DB's id, bob's own activity (groups 20 to 23's `4A53-4F4E` pattern).
    static var dbActivityID: UUID { uuid("B0B0AC71-4A53-4F4E-8000-000000000003") }

    /// DB: bob's coffee run, no location, from 780 000 300 to 780 007 500 s after the reference date.
    static var descriptorDB: ActivityDescriptor {
        ActivityDescriptor(
            activityID: dbActivityID, hostFingerprint: bobFingerprint, hostSigningPublicKey: bobSigningPub, title: "Coffee run",
            activityTypeToken: "coffee", coarseLocation: nil, createdAt: Date(timeIntervalSinceReferenceDate: 780_000_300),
            expiresAt: Date(timeIntervalSinceReferenceDate: 780_007_500))
    }

    /// bob as DB's host participant: his roster name and keys, joined at DB's creation.
    static var rosterBobHost: ActivityParticipant {
        ActivityParticipant(fingerprint: bobFingerprint, displayName: "B\u{F8}b \u{1F33F}", signingPublicKey: bobSigningPub,
                            keyAgreementPublicKey: bobPub, joinedAt: Date(timeIntervalSinceReferenceDate: 780_000_300))
    }

    /// bob's RFC 8032 signature over RB1's canonical bytes (270 bytes), R then S. Frozen here: no other
    /// group signs as bob.
    static let rosterRB1SignatureHex = [
        "395473879a2bd3e6e60af5d7b689b87c59ddb1a5aa309bde547cce03e2a29648",
        "f554fc9f787a3900a1ff46656c86235c8540a0d99ca84bd828977ed4815ec604"
    ].joined()

    /// R2, with alice's frozen signature.
    static var rosterR2: ActivityRosterSnapshot {
        roster(version: 2, members: [rosterAlice, rosterBob], issuedAt: 780_000_660, signature: bytes(fromHex: rosterR2SignatureHex))
    }

    /// RB1: bob's first roster for DB, bob alone, issued at its creation, with his frozen signature.
    static var rosterRB1: ActivityRosterSnapshot {
        ActivityRosterSnapshot(
            schemaVersion: 1, activityID: dbActivityID, version: 1, participants: [rosterBobHost],
            issuedAt: Date(timeIntervalSinceReferenceDate: 780_000_300), hostSigningPublicKey: bobSigningPub,
            hostSignature: bytes(fromHex: rosterRB1SignatureHex))
    }

    /// J1, with alice's frozen signature.
    static var tokenJ1: ActivityJoinToken { joinToken(signature: bytes(fromHex: joinTokenSignatureHex)) }

    /// alice's offer of D1 at roster version 2.
    static var offerD1: ActivityOffer { ActivityOffer(descriptor: descriptorD1, rosterVersion: 2) }
    /// An offer of D2 at roster version 1.
    static var offerD2: ActivityOffer { ActivityOffer(descriptor: descriptorD2, rosterVersion: 1) }

    /// bob's request to join alice's activity.
    static var joinRequest: ActivityJoinRequest {
        ActivityJoinRequest(activityID: activityID, joinerFingerprint: bobFingerprint, joinerDisplayName: "B\u{F8}b \u{1F33F}",
                            joinerSigningPublicKey: bobSigningPub, joinerKeyAgreementPublicKey: bobPub)
    }

    /// alice's grant: J1 and R2.
    static var joinGrant: ActivityJoinGrant { ActivityJoinGrant(token: tokenJ1, snapshot: rosterR2) }
    /// R2 gossiped.
    static var rosterGossip: ActivityRosterGossip { ActivityRosterGossip(snapshot: rosterR2) }
    /// The digest: alice's activity at version 2, DB at version 1.
    static var syncDigest: ActivitySync {
        ActivitySync(held: [.init(activityID: activityID, versionHeld: 2), .init(activityID: dbActivityID, versionHeld: 1)])
    }

    /// bob's hosted DB row and his joined D1 row.
    static var hostedDB: HostedActivity {
        HostedActivity(descriptor: descriptorDB, participants: [rosterBobHost], version: 1, currentSnapshot: rosterRB1)
    }
    static var joinedD1: JoinedActivity { JoinedActivity(descriptor: descriptorD1, token: tokenJ1, lastSnapshot: rosterR2) }

    /// The activity ledger's clocks: half an hour before D1 expires, and D1's expiry exactly.
    static let activityLoadClock = Date(timeIntervalSinceReferenceDate: 780_001_800)
    static let d1ExpiryClock = Date(timeIntervalSinceReferenceDate: 780_003_600)

    /// The hat group 4 hashes, listed: created 779 990 000 s after the reference date,
    /// shareable, 5 coins.
    static var goldenHat: CustomizationItem {
        CustomizationItem(
            id: uuid("D1E2F3A4-B5C6-4D7E-8F90-A1B2C3D4E5F6"), name: "Golden hat", slot: .hat,
            texture: ItemGridTexture(cols: 2, rows: 2, palette: ["2E2A24", "FFFFFF"], pixels: [0, 1, -1, 0]),
            designer: ItemDesigner(id: uuid("E1F2A3B4-C5D6-4E7F-8091-A2B3C4D5E6F7")),
            createdAt: Date(timeIntervalSinceReferenceDate: 779_990_000), isShareable: true, price: 5)
    }

    /// alice's catalog of the hat, sent 780 000 000 s after the reference date.
    static var aliceCatalog: ClothingCatalog {
        ClothingCatalog(id: uuid("CA7A1060-4A53-4F4E-8000-000000000001"), sentAt: Date(timeIntervalSinceReferenceDate: 780_000_000),
                        designerID: uuid("E1F2A3B4-C5D6-4E7F-8091-A2B3C4D5E6F7"), displayName: "Alice", items: [goldenHat])
    }

    /// The request's body as its sender builds it.
    static var catalogRequest: PayloadSummary { PayloadSummary(title: "Clothing catalog request") }

    /// M1 and M2 with alice's frozen signatures, and the payload of both.
    static var signedReportRows: [SignedReport] {
        [SignedReport(entry: moderationReport, signature: bytes(fromHex: moderationReportSignatureHex)),
         SignedReport(entry: moderationRetract, signature: bytes(fromHex: moderationRetractSignatureHex))]
    }
    static var reportBundle: ReportBundle { ReportBundle(reports: signedReportRows) }

    /// alice's vouch list: bob and carol, until 2100-01-01T00:00:00Z.
    static var aliceVouchList: FriendVouchList {
        FriendVouchList(voucherFingerprint: aliceFingerprint, voucherDisplayName: "Alice",
                        trustedFingerprints: [bobFingerprint, carolFingerprint],
                        expiresAt: Date(timeIntervalSinceReferenceDate: 3_124_137_600))
    }

    /// The hearts: H0 (the v1 blob's), H1 (dismissed), H2 (carol's, showing), and H3's id, a second heart
    /// from carol the 5-minute window refuses.
    static var heartH0: HeartRecord {
        HeartRecord(id: uuid("4EA27000-4A53-4F4E-8000-000000000010"), senderDisplayName: "Bob", senderFingerprint: bobFingerprint,
                    receivedAt: Date(timeIntervalSinceReferenceDate: 780_001_000))
    }
    static var heartH1: HeartRecord {
        HeartRecord(id: uuid("4EA27001-4A53-4F4E-8000-000000000011"), senderDisplayName: "Bob", senderFingerprint: bobFingerprint,
                    receivedAt: Date(timeIntervalSinceReferenceDate: 779_990_000),
                    bubbleDismissedAt: Date(timeIntervalSinceReferenceDate: 779_990_100))
    }
    static var heartH2: HeartRecord {
        HeartRecord(id: uuid("4EA27002-4A53-4F4E-8000-000000000012"), senderDisplayName: "Carol",
                    senderFingerprint: carolFingerprint, receivedAt: Date(timeIntervalSinceReferenceDate: 780_001_600))
    }
    static var heartH3ID: UUID { uuid("4EA27003-4A53-4F4E-8000-000000000013") }

    /// The heart ledger's clocks: the load, and H1's receipt + 48 h + 1 s.
    static let heartLoadClock = Date(timeIntervalSinceReferenceDate: 780_001_800)
    static let heartPruneClock = Date(timeIntervalSinceReferenceDate: 780_162_801)

    /// A held photo's local id, which names its files in the pending corpus.
    static var pendingLocalID: UUID { uuid("F0700010-4A53-4F4E-8000-000000000050") }

    /// A wall session's participants: alice, then bob, by their plain names.
    static var wallParticipants: [FriendPhotoSessionParticipant] {
        [FriendPhotoSessionParticipant(fingerprint: aliceFingerprint, displayName: "Alice"),
         FriendPhotoSessionParticipant(fingerprint: bobFingerprint, displayName: "Bob")]
    }

    /// S1 (sunny-meadow's mesh) and S2 (no mesh id or name).
    static var sessionS1: FriendPhotoSessionMetadata {
        FriendPhotoSessionMetadata(
            id: uuid("5E55100A-4A53-4F4E-8000-000000000021"), meshID: uuid("3E5A1D01-4A53-4F4E-8000-000000000031"),
            meshName: "sunny-meadow", startedAt: Date(timeIntervalSinceReferenceDate: 780_000_000), participants: wallParticipants)
    }
    static var sessionS2: FriendPhotoSessionMetadata {
        FriendPhotoSessionMetadata(id: uuid("5E55100B-4A53-4F4E-8000-000000000022"), meshID: nil, meshName: nil,
                                   startedAt: Date(timeIntervalSinceReferenceDate: 780_003_900), participants: wallParticipants)
    }

    /// One wall entry, metadata only: `n` names its id, `F070000n-4A53-4F4E-8000-00000000004n`.
    static func wallPhoto(_ n: Int, addedAt: TimeInterval, from name: String, signedBy key: Data?,
                          fingerprint: String?, session: FriendPhotoSessionMetadata?) -> FriendPhotoPayload {
        FriendPhotoPayload(id: uuid("F070000\(n)-4A53-4F4E-8000-00000000004\(n)"), imageData: Data(),
                           addedAt: Date(timeIntervalSinceReferenceDate: addedAt), senderName: name,
                           senderFingerprint: fingerprint, senderSigningPublicKey: key, session: session).withoutImageData()
    }

    /// The wall the frozen index loads, newest first: P6, P5, P3, P2, P1, then P4.
    static var wallNewestFirst: [FriendPhotoPayload] {
        [wallPhoto(6, addedAt: 780_004_060, from: "Bob", signedBy: bobSigningPub, fingerprint: bobFingerprint, session: sessionS2),
         wallPhoto(5, addedAt: 780_004_000, from: "Alice", signedBy: aliceSigningPub, fingerprint: aliceFingerprint,
                   session: sessionS2),
         wallPhoto(3, addedAt: 780_000_180, from: "Bob", signedBy: bobSigningPub, fingerprint: bobFingerprint, session: sessionS1),
         wallPhoto(2, addedAt: 780_000_120, from: "Alice", signedBy: aliceSigningPub, fingerprint: aliceFingerprint,
                   session: sessionS1),
         wallPhoto(1, addedAt: 780_000_060, from: "Bob", signedBy: bobSigningPub, fingerprint: bobFingerprint, session: sessionS1),
         wallPhoto(4, addedAt: 779_990_000, from: "Bob", signedBy: nil, fingerprint: nil, session: nil)]
    }

    /// The six frozen wall entries newest first, P6, P5, P3, P2, P1 then P4: the order the wall seals its
    /// index in (`cappedNewestFirst`), recomposed from group 23's entries, the order the wall loads them
    /// in too.
    static var frozenWallIndexNewestFirstJSON: String {
        let entries = [frozenWallPhotoP6JSON, frozenWallPhotoP5JSON, frozenWallPhotoP3JSON, frozenWallPhotoP2JSON,
                       frozenWallPhotoP1JSON, frozenWallPhotoP4JSON]
        return "[" + entries.joined(separator: ",") + "]"
    }

    /// bob as a handshake presents him, with planted bob's keys and fingerprint and the capabilities
    /// given: the identity a commit hands the hook and his vault row is kept under.
    static func bobPeerIdentity(id: UUID, capabilities: [String]?) -> ProximityCoordinator.PeerIdentity {
        ProximityCoordinator.PeerIdentity(
            id: id, displayName: "Bob", signingPublicKey: bobSigningPub, keyAgreementPublicKey: bobPub,
            fingerprint: bobFingerprint, rangingMode: .rssi, firstSeenAt: Date(timeIntervalSinceReferenceDate: 780_000_000),
            capabilities: capabilities)
    }

    /// bob's vouch list naming carol, expiring at `expiresAt`.
    static func bobVouchList(expiresAt: Date) -> FriendVouchList {
        FriendVouchList(voucherFingerprint: bobFingerprint, voucherDisplayName: "Bob",
                        trustedFingerprints: [carolFingerprint], expiresAt: expiresAt)
    }

    /// The friend state alice's commit hands bob: "okay", and group 10's pear-bodied companion with
    /// glasses, under a fixed id so bob's decode compares whole.
    static var friendStateFixture: FriendStatePayload {
        FriendStatePayload(state: .okay, appearance: CompanionAppearance(bodyStyle: .pear, accessory: .glasses),
                           id: uuid("5717E000-4841-4E44-8000-000000000001"))
    }

    /// The token of the commit-time feature frame `name`; empty for a name the table does not hold, which
    /// fails what reads it.
    static func featureToken(_ name: String) -> String {
        featureTokens[name] ?? ""
    }

    /// A report payload's JSON object with every row's `signature` removed: what a send-side cell
    /// compares, since CryptoKit's Ed25519 signs with fresh randomness. A body that is not an object
    /// reads as an empty one, which fails the comparison.
    static func reportWithoutSignatures(_ json: Data) throws -> NSDictionary {
        let object = try JSONSerialization.jsonObject(with: json, options: [.mutableContainers])
        guard let payload = object as? NSMutableDictionary else { return NSDictionary() }
        let rows = payload["reports"] as? NSMutableArray ?? NSMutableArray()
        // R2: bounded by the payload's rows.
        for case let row as NSMutableDictionary in rows {
            row.removeObject(forKey: "signature")
        }
        return payload
    }

    /// One commit-time send as bob reads it: the envelope the mesh signed and bob's open of its sealed
    /// body.
    struct SentToBob {
        /// The envelope, as bob's link carried it.
        let envelope: FernletIdentityEnvelope
        /// bob's open of its payload, in the legacy framing.
        let body: Data
    }

    /// Fernlet's composition over planted alice on an in-memory radio, bob planted beside it and kept in
    /// the store's vault, and one link of a fake fabric for bob's slot: what group 20's catalog send,
    /// group 26's sends and group 29's lifecycle cells drive. Built by ``sessionRig(bobAdvertising:)`` and
    /// removed by ``tearDown(_:)``.
    struct SessionRig {
        /// The scratch proximity root the store files under.
        let root: URL
        /// alice's and bob's throwaway keychain services.
        let services: [String]
        /// The host, held here because the manager holds it `unowned`.
        let store: FernletStore
        /// Planted alice, the manager's device identity.
        let alice: IdentityService
        /// Planted bob, who opens what the mesh seals to him and signs what he sends.
        let bob: IdentityService
        /// Fernlet's composition over alice: it owns the manager and the features (the clothing shop
        /// among them) and is the manager's session observer, so the rig holds it for its whole life.
        let features: FernletMeshFeatures
        /// The mesh manager over alice: ``features``' mesh.
        var manager: MeshNetworkManager { features.mesh }
        /// The fabric bob's link lives on, held here because the link holds it weakly.
        let network: FakePeerNetwork
        /// bob's end of the fabric: the channel his slot sends on, and its handle.
        let link: (transport: FakePeerTransport, handle: PeerHandle)
        /// The capability tokens bob advertises.
        let capabilities: [String]
    }

    /// `text` with every run of whitespace, line breaks included, collapsed to one space: how a
    /// declaration that spans lines is matched as one.
    static func collapsingWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The comment and the English value a string catalog files under `key`, read off the repository's
    /// copy of the catalog at `path`; nil for whichever is absent.
    static func catalogEntry(_ key: String, in path: String) throws -> (comment: String?, english: String?) {
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: RepoRoot.url(path))) as? [String: Any] ?? [:]
        let entry = (catalog["strings"] as? [String: Any])?[key] as? [String: Any] ?? [:]
        let localizations = entry["localizations"] as? [String: Any]
        let english = (localizations?["en"] as? [String: Any])?["stringUnit"] as? [String: Any]
        return (entry["comment"] as? String, english?["value"] as? String)
    }

    /// Every token written by the code plan step A0.5 moves, as that code writes them today: the whole
    /// files' and the ranges' lines, and the heart ledger's sidecar lines under the `heartledger` prefix
    /// its moved initializer names. A cell compares the lines one call wrote under these tokens, in
    /// order, and nothing else.
    static let movedAuditTokens: Set<String> = [
        "moderation.relay.rowsRejected",
        "activity.removeParticipant.signFailed", "activity.regrant.signFailed",
        "sidecar.encodeFailed", "sidecar.createDirectoryFailed", "sidecar.saveFailed", "sidecar.removeFailed",
        "heartledger.backupExclusionFailed", "heartledger.mutateRefused", "heartledger.sealMigrationDeferred",
        "heartledger.corrupt", "heartledger.removeFailed", "heartledger.readDeferred", "heartledger.quarantined",
        "heartledger.quarantineFailed", "heartledger.unopenableDiscarded", "heartledger.writeFailed",
        "mesh.clothingCatalog.droppedUnverifiedSender", "mesh.clothingCatalogRequest.droppedUnverifiedSender",
        "mesh.itemReport.droppedUnverifiedSender",
        "mesh.routedHeart.sendFailed", "mesh.routedHeart.noJudgement", "mesh.routedShare.mintFailed",
        "mesh.routedShare.textBlockedAgeGated", "mesh.routedShare.textByteBounded", "mesh.routedShare.textRefused",
        "mesh.routedShare.skipped",
        "mesh.routedProjection.transcriptSessionEnded", "mesh.routedProjection.transcriptNotLiveYet",
        "mesh.routedProjection.transcriptRefused", "mesh.routedProjection.textQuotaSpent",
        "mesh.routedProjection.textQuotaMapFull", "mesh.routedProjection.openFailed",
        "mesh.routedProjection.photoAlreadyAnswered", "mesh.routedProjection.quotaSpent",
        "mesh.routedProjection.quotaMapFull",
        "mesh.photoIndex.unrecoverable", "mesh.photoIndex.saveSkippedWhileDeferred",
        "mesh.photoIndex.recoveredAfterDeferral",
        "mesh.session.photoReviewAnswered", "mesh.session.photosPendingReview",
        "mesh.session.developAnsweredPendingPhotos",
        "mesh.heldPhotos.deleteRefused", "mesh.heldPhotos.holdRefused", "mesh.heldPhotos.idCollision",
        "mesh.heldPhotos.heldAwaiting", "mesh.heldPhotos.indexUnrecoverable", "mesh.heldPhotos.reconciled",
        "mesh.heldPhotos.offeredOverUnreadableWall", "mesh.heldPhotos.offeredFromIndex",
        "mesh.heldPhotos.purgedForDeleteAll", "mesh.heldPhotos.answerRefused", "mesh.heldPhotos.keepRefused",
        "mesh.heldPhotos.unreadableAtKeep", "mesh.heldPhotos.keepNotLanded", "mesh.heldPhotos.answerNotPersisted"
    ]

    /// The lines among `lines` written under a moved token, in order.
    static func movedLines(_ lines: [MovedAuditLines.Line]) -> [MovedAuditLines.Line] {
        lines.filter { movedAuditTokens.contains($0.event) }
    }

    /// One expected line: its token, and its whole context (empty for a bare line).
    static func auditLine(_ event: String, _ context: [String: String] = [:]) -> MovedAuditLines.Line {
        MovedAuditLines.Line(event: event, context: context)
    }

    /// The line a session-end review's answer writes, with its five counts in decimal under their frozen
    /// keys.
    static func reviewAnswered(kept: Int, discarded: Int, unreadable: Int, notApplied: Int,
                               stillPending: Int) -> MovedAuditLines.Line {
        auditLine("mesh.session.photoReviewAnswered", [
            "kept": String(kept), "discarded": String(discarded), "unreadable": String(unreadable),
            "notApplied": String(notApplied), "stillPending": String(stillPending)
        ])
    }

    /// The instant every clock of this group stands at, 780 000 000 s after the reference date.
    static let auditClock = Date(timeIntervalSinceReferenceDate: 780_000_000)

    /// A report of the artwork `abcd` by `reporter` about `subject`, group 10's row with its keys given.
    static func reportRow(reporter: Data, subject: Data) -> ModerationLedgerEntry {
        ModerationLedgerEntry(
            id: "report:ffgt:abcd", kind: .report, reporterSigningPublicKey: reporter, subjectSigningPublicKey: subject,
            itemID: uuid("D1E2F3A4-B5C6-4D7E-8F90-A1B2C3D4E5F6"), contentHash: Data([0xab, 0xcd]),
            reasonToken: "offensive", reporterSeq: 1, createdAt: auditClock)
    }

    /// bob's request to join the activity `activityID`, under his own fingerprint and keys.
    static func bobsJoinRequest(for activityID: UUID) -> ActivityJoinRequest {
        ActivityJoinRequest(activityID: activityID, joinerFingerprint: bobFingerprint, joinerDisplayName: "Bob",
                            joinerSigningPublicKey: bobSigningPub, joinerKeyAgreementPublicKey: bobPub)
    }

    /// A feature frame of `type` whose envelope names no key, as a slot that proved none carries it; its
    /// payload is an empty JSON object, which no handler reaches past its sender check.
    static func unverifiedFrame(_ type: PayloadType) -> FernletIdentityEnvelope {
        FernletIdentityEnvelope(
            schemaVersion: FernletIdentityEnvelope.currentSchemaVersion, envelopeID: UUID(),
            senderSigningPublicKey: Data(), senderKeyAgreementPublicKey: Data(), senderDisplayName: "Unverified",
            recipientFingerprint: nil, payloadType: type, payloadEncryption: .none,
            payloadSummary: PayloadSummary(title: "Unverified"), payload: Data("{}".utf8),
            createdAt: auditClock, expiresAt: nil, signature: Data())
    }

    /// A routed-shaped photo from `origin` with a tiny JPEG, under `id`: the held-photo suites'
    /// `HeldPhotoFixtures.peerPhoto(id:origin:name:)`, whose sender fingerprint is `origin`.
    static func heldPhoto(id: UUID = UUID(), origin: String) -> FriendPhotoPayload {
        HeldPhotoFixtures.peerPhoto(id: id, origin: origin)
    }

    /// A photo from `origin` whose bytes are no image an image reader can open, so the pending corpus
    /// refuses them as unsafe before anything is written.
    static func unreadableImagePhoto(origin: String) -> FriendPhotoPayload {
        FriendPhotoPayload(id: UUID(), imageData: Data("not an image".utf8), addedAt: auditClock, senderName: "Peer",
                           senderFingerprint: origin, senderSigningPublicKey: Data([1, 2, 3]))
    }

    /// A chat draft of 500 Characters, each an `e` and fifteen U+0301 combining acute accents (one
    /// grapheme, 31 UTF-8 bytes): 15 500 bytes, which the sanitizer keeps whole and the wire's 8 000-byte
    /// bound cuts to 258 Characters.
    static var overlongChatDraft: String {
        String(repeating: "e" + String(repeating: "\u{0301}", count: 15), count: 500)
    }

    /// A routed manifest real in the two fields the text quota reads, its item's mesh and its origin, and
    /// opaque everywhere else, as `MeshRoutedTextDeliveryTests` builds its quota's: it never reaches a
    /// verifier.
    static func quotaManifest(origin: String) -> MeshRoutedManifest {
        MeshRoutedManifest(
            meshID: MeshRoutedManifestFixtures.meshID, itemID: UUID(), originFingerprint: origin,
            typeToken: MeshRoutedManifestFixtures.typeToken, contentHash: MeshRoutedManifestFixtures.contentHash,
            size: 1, createdAt: MeshRoutedManifestFixtures.createdAt, expiresAt: MeshRoutedManifestFixtures.expiresAt,
            destinations: [], keyWraps: [], signature: MeshRoutedManifestFixtures.opaqueSignature)
    }

    /// The failures a cell plants in a store's own closures and states, whose descriptions are their
    /// names.
    nonisolated enum PlantedFileFailure: Error {
        /// A read that throws.
        case read
        /// A write that throws.
        case write
        /// An encoding that throws.
        case encode
    }

    /// A sidecar state that encodes, standing in for a store's own.
    nonisolated struct SidecarProbe: Codable, Equatable {
        /// Its one field.
        var note = "probe"
    }

    /// A sidecar state whose encoding throws ``PlantedFileFailure/encode``, which no store's state does.
    nonisolated struct UnencodableSidecarProbe: Codable {
        /// A probe.
        init() {}

        /// Refuses, as its encoding does; nothing here decodes one.
        init(from decoder: any Decoder) throws {
            throw PlantedFileFailure.encode
        }

        /// Throws instead of writing anything.
        func encode(to encoder: any Encoder) throws {
            throw PlantedFileFailure.encode
        }
    }

    /// The audit lines one synchronous call writes, captured as `ProximityAuditBridgeTests` captures them
    /// and `ProximityNamespaceGateTests.GateAuditLines` copies it: the handler records only while a
    /// task-local mark bound around that call is visible, so no line from a suite running beside this one
    /// is counted, and the capture is read the moment the call returns.
    enum MovedAuditLines {

        /// One line as a capture handler saw it.
        struct Line: Equatable, Sendable {
            /// The event name.
            let event: String
            /// The context.
            let context: [String: String]
        }

        /// The mark, bound only around the call being captured.
        @TaskLocal static var emitter: UUID?

        /// Every line written while `emit` ran under this call's own mark, in order.
        ///
        /// - Parameter emit: The synchronous call.
        /// - Returns: The lines it wrote.
        static func delivered(during emit: () throws -> Void) rethrows -> [Line] {
            let mark = UUID()
            let seen = OSAllocatedUnfairLock<[Line]>(initialState: [])
            let token = FernletAuditLog.addCaptureHandler { event, context in
                guard Self.emitter == mark else { return }
                seen.withLock { $0.append(Line(event: event, context: context)) }
            }
            defer { FernletAuditLog.removeCaptureHandler(token) }
            try Self.$emitter.withValue(mark) { try emit() }
            return seen.withLock { $0 }
        }
    }

    /// One audit cell's mesh: Fernlet's composition over a scratch store whose proximity root is the
    /// cell's own, with planted alice as its device identity and its pending corpus sealed under an
    /// in-memory key the cell can take away (the held-photo suites' `SwitchableMediaKeyProvider`); its
    /// mesh is the rig's manager, carrying the features' handlers (the shop's since plan step A0.5.6, the
    /// item report's and the friend state's since A0.5.7). The rig holds the store, which every manager
    /// holds unowned, and the composition, which the manager's session observer and handlers need alive;
    /// ``tearDown()`` sweeps alice's rows and the root.
    @MainActor
    final class AuditMeshRig {
        /// The proximity root every manager of the rig files under.
        let root: URL
        /// alice's throwaway keychain service.
        let service: String
        /// The host every manager of the rig hangs off.
        let store: FernletStore
        /// The device identity of every manager of the rig.
        let alice: IdentityService
        /// The pending corpus's key, which the cell can take away and give back.
        let keys: SwitchableMediaKeyProvider
        /// Fernlet's composition over the root: it owns ``manager`` and the features.
        let features: FernletMeshFeatures
        /// The first manager over the root: ``features``' mesh.
        let manager: MeshNetworkManager

        /// A rig over a fresh root and a freshly planted alice; a failed plant removes what it wrote.
        init() throws {
            let root = FernletFeatureGoldenTests.scratchDirectory()
            let service = FernletFeatureGoldenTests.throwawayService()
            let store = makeTestStore(proximitySupportDirectory: root)
            let alice: IdentityService
            do {
                alice = try FernletFeatureGoldenTests.plantedAlice(service: service)
            } catch {
                FernletFeatureGoldenTests.sweep([service])
                FernletFeatureGoldenTests.removeDirectory(root)
                throw error
            }
            let keys = SwitchableMediaKeyProvider()
            self.root = root
            self.service = service
            self.store = store
            self.alice = alice
            self.keys = keys
            let features = FernletFeatureGoldenTests.meshFeatures(over: store, identity: alice, heldPhotoKeys: keys)
            self.features = features
            manager = features.mesh
        }

        /// Another manager over the same root and identity, as a relaunch builds one, its pending corpus
        /// under `keys`.
        func relaunched(keys: SwitchableMediaKeyProvider) -> MeshNetworkManager {
            FernletFeatureGoldenTests.meshManager(over: store, identity: alice, heldPhotoKeys: keys)
        }

        /// Removes alice's rows and the root.
        func tearDown() {
            FernletFeatureGoldenTests.sweep([service])
            FernletFeatureGoldenTests.removeDirectory(root)
        }
    }

    /// A photo alice took in the session: `n` (1 to 9) names its id,
    /// `F070002n-4841-4E44-8000-00000000002n`, and its bytes are the routed suites' tiny JPEG.
    static func sessionPhoto(_ n: Int) -> FriendPhotoPayload {
        FriendPhotoPayload(
            id: uuid("F070002\(n)-4841-4E44-8000-00000000002\(n)"), imageData: MeshRoutedPhotoFixtures.tinyJPEG(),
            addedAt: Date(timeIntervalSinceReferenceDate: 780_000_000 + 60 * TimeInterval(n)), senderName: "Alice",
            senderFingerprint: aliceFingerprint, senderSigningPublicKey: aliceSigningPub)
    }

    /// The moments of a session's commit or end, in the order they happened. Locked, because the audit
    /// log calls its handlers from whichever thread logs; the moments this suite notes all arrive on the
    /// main actor.
    final class LifecycleRecorder {
        /// Guards ``moments``.
        private let lock = NSLock()
        /// Every moment noted, in order.
        private var moments: [String] = []
        /// The capture handler's token while one is installed.
        private var token: UUID?

        /// Every moment noted so far, in order.
        var order: [String] {
            lock.lock()
            defer { lock.unlock() }
            return moments
        }

        /// Notes one moment.
        func note(_ moment: String) {
            lock.lock()
            moments.append(moment)
            lock.unlock()
        }

        /// Notes `moment` each time the audit log carries `event`, until ``uninstall()``.
        func install(noting moment: String, whenLogged event: String) {
            token = FernletAuditLog.addCaptureHandler { [weak self] logged, _ in
                guard logged == event else { return }
                self?.note(moment)
            }
        }

        /// Removes the capture handler, if one is installed.
        func uninstall() {
            guard let token else { return }
            FernletAuditLog.removeCaptureHandler(token)
            self.token = nil
        }
    }
}
