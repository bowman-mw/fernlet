// ProximityNamespaceTestBindings.swift
// FernletTests
//
// ProximityKit plan step A0.2.3 (Docs/Plan-FernletCoach-ProximityKit-2026-10-01.md §4 A0.2): the one
// place the test target gets back the call shapes A0.2 to A0.4 took out of ProximityKit. ProximityKit
// offers no namespace default, so every API that used to spell Fernlet's bytes for itself now takes
// the host's `ProximityNamespace`, or a value read off it. The suites were written against the old
// shapes; rather than rewrite every construction in every suite, each old shape comes back here
// once, passing Fernlet's value. The shapes of the types that left ProximityKit for FernletSocial
// follow them to `FernletSocialTestBindings.swift`, under the same rule, so this file never imports
// FernletSocial; and the identity's two initializers, which carry Fernlet's custody (the app's
// sealed-backup escrow key, the identity's provisioning participant), are in
// `FernletAppTestBindings.swift`, so it never imports the app either.
//
// THE RULE. A binding restores a call SHAPE, never a value: it passes `ProximityNamespace.fernlet`,
// exactly the value FernletConnections ships and the app hands ProximityKit, so a suite that goes
// through one sees the bytes it always saw, and nothing here may pass anything else or compute a
// label, a row or a name of its own. A test that PINS a value does not lean on a binding: it names
// `.fernlet` explicitly (`IdentityService(namespace: .fernlet)`), so what it pins is visibly
// Fernlet's and still reads correctly once a binding is retired. Each plan-step commit adds its
// bindings to this file, beside the API it restores.
//
// Where an API takes the namespace's labels rather than the whole namespace (step A0.2.4 on), the
// binding passes `.fernlet` for a `ProximityNamespace.Purposes`: FernletConnections'
// `ProximityNamespace.Purposes.fernlet`, the very value `ProximityNamespace.fernlet.family.purposes`
// holds (ProximityNamespaceGoldenTests pins the two equal). Where it takes the family, because it
// needs the vocabulary's record kinds beside the labels (the membership verifier, the ledger adoption
// and the inventory digest), the binding passes `.fernlet` for a `ProximityNamespace.Family`:
// `ProximityNamespace.Family.fernlet`, the value `ProximityNamespace.fernlet.family` holds (pinned
// equal beside the purposes). Where it takes a vocabulary group (the routed type registry and its ack
// projection, a peer's capability gate), the binding reads the group off
// `ProximityNamespace.fernlet.family.vocabulary`.

import CryptoKit
import FernletConnections
import FernletDomainModel
import Foundation
@testable import ProximityKit

// MARK: - Signed transcripts I: the canonical bytes (A0.2.4)
//
// The ten `canonicalBytes(for:)` overloads whose domain step A0.2.4 moved onto the namespace, and the
// membership inventory digest's preimage, each restored over its `in purposes:` form with Fernlet's
// labels. The routed and channel-introduction overloads follow in their own section (A0.2.5).

/// `canonicalBytes(for: envelope, in: .fernlet)`: the identity envelope under Fernlet's labels.
func canonicalBytes(for envelope: FernletIdentityEnvelope) -> Data {
    canonicalBytes(for: envelope, in: .fernlet)
}

/// `canonicalBytes(for: token, in: .fernlet)`: the admission token under Fernlet's labels.
func canonicalBytes(for token: MeshAdmissionToken) -> Data {
    canonicalBytes(for: token, in: .fernlet)
}

/// `canonicalBytes(for: record, in: .fernlet)`: a departure record under Fernlet's labels.
func canonicalBytes(for record: SignedDepartureRecord) -> Data {
    canonicalBytes(for: record, in: .fernlet)
}

/// `canonicalBytes(for: record, in: .fernlet)`: a completed removal under Fernlet's labels.
func canonicalBytes(for record: SignedRemovalRecord) -> Data {
    canonicalBytes(for: record, in: .fernlet)
}

/// `canonicalBytes(for: record, in: .fernlet)`: a termination record under Fernlet's labels.
func canonicalBytes(for record: SignedTerminationRecord) -> Data {
    canonicalBytes(for: record, in: .fernlet)
}

/// `canonicalBytes(for: payload, in: .fernlet)`: a signed inventory digest under Fernlet's labels.
func canonicalBytes(for payload: MeshInventoryDigestPayload) -> Data {
    canonicalBytes(for: payload, in: .fernlet)
}

/// `canonicalBytes(for: payload, in: .fernlet)`: an epoch-heads message under Fernlet's labels.
func canonicalBytes(for payload: MeshEpochHeadsPayload) -> Data {
    canonicalBytes(for: payload, in: .fernlet)
}

/// `canonicalBytes(for: advertisement, in: .fernlet)`: a key advertisement under Fernlet's labels.
func canonicalBytes(for advertisement: SignedKeyAgreementAdvertisement) -> Data {
    canonicalBytes(for: advertisement, in: .fernlet)
}

/// `canonicalBytes(for: proposal, in: .fernlet)`: a removal proposal under Fernlet's labels.
func canonicalBytes(for proposal: SignedRemovalProposal) -> Data {
    canonicalBytes(for: proposal, in: .fernlet)
}

/// `canonicalBytes(for: vote, in: .fernlet)`: a removal vote under Fernlet's labels.
func canonicalBytes(for vote: SignedRemovalVote) -> Data {
    canonicalBytes(for: vote, in: .fernlet)
}

/// `canonicalInventoryDigestBytes(for: identities, in: .fernlet)`: the membership inventory digest's
/// hash preimage under Fernlet's labels.
func canonicalInventoryDigestBytes(for identities: [MeshRecordIdentity]) -> Data {
    canonicalInventoryDigestBytes(for: identities, in: .fernlet)
}

// MARK: - Signed transcripts I: verifiers and helpers (A0.2.4)

/// The verifier initializer the suites were written against, restored over
/// `init(meshID:founderSigningPublicKey:ledger:family:)` with Fernlet's family (plan steps A0.2.4 and
/// A0.3.3).
extension MeshMembershipRecordVerifier {

    /// A verifier keeping Fernlet's family (its labels and record kinds) as its copy, otherwise
    /// exactly the retired initializer.
    ///
    /// - Parameters:
    ///   - meshID: The mesh every accepted record must name.
    ///   - founderSigningPublicKey: The key that may bootstrap an admission, if known.
    ///   - ledger: The records to start from.
    init(meshID: UUID, founderSigningPublicKey: Data? = nil, ledger: MeshMembershipLedger = .empty) {
        self.init(meshID: meshID, founderSigningPublicKey: founderSigningPublicKey, ledger: ledger,
                  family: .fernlet)
    }
}

/// The joiner's two ledger steps in the shapes the suites were written against, restored over their
/// `in family:` forms with Fernlet's family (plan steps A0.2.4 and A0.3.3).
extension MeshLedgerAdoption {

    /// `bootstrapVerifier(meshID:ownAdmission:in: .fernlet)`.
    static func bootstrapVerifier(meshID: UUID, ownAdmission: SignedAdmissionRecord) -> MeshLedgerAdoptionOutcome {
        bootstrapVerifier(meshID: meshID, ownAdmission: ownAdmission, in: .fernlet)
    }

    /// `adopt(offered:ownAdmission:meshID:in: .fernlet)`.
    static func adopt(
        offered: MeshMembershipLedger, ownAdmission: SignedAdmissionRecord, meshID: UUID
    ) -> MeshLedgerAdoptionOutcome {
        adopt(offered: offered, ownAdmission: ownAdmission, meshID: meshID, in: .fernlet)
    }
}

/// The digest initializer the suites were written against, restored over
/// `init(meshID:ledger:family:)` with Fernlet's family (plan steps A0.2.4 and A0.3.3).
extension MeshInventoryDigest {

    /// The digest of `ledger`, its records hash under Fernlet's labels over Fernlet's record kinds.
    init(meshID: UUID, ledger: MeshMembershipLedger) {
        self.init(meshID: meshID, ledger: ledger, family: .fernlet)
    }
}

/// The token check the suites were written against, restored over its `in purposes:` form with
/// Fernlet's labels (plan step A0.2.4).
extension MeshAdmissionToken {

    /// `verify(joinerSigningPublicKey:expectedMeshID:expectedAdmitterSigningPublicKey:now:in: .fernlet)`.
    func verify(
        joinerSigningPublicKey presentedKey: Data, expectedMeshID: UUID,
        expectedAdmitterSigningPublicKey: Data?, now: Date = Date()
    ) throws {
        try verify(joinerSigningPublicKey: presentedKey, expectedMeshID: expectedMeshID,
                   expectedAdmitterSigningPublicKey: expectedAdmitterSigningPublicKey, now: now, in: .fernlet)
    }
}

// MARK: - Signed transcripts II: the canonical bytes (A0.2.5)
//
// The seven `canonicalBytes(for:)` overloads whose domain step A0.2.5 moved onto the namespace — the
// QUIC channel introduction and the six routed transcripts — each restored over its `in purposes:`
// form with Fernlet's labels.

/// `canonicalBytes(for: transcript, in: .fernlet)`: a channel introduction under Fernlet's labels.
func canonicalBytes(for transcript: MeshChannelIntroductionTranscript) -> Data {
    canonicalBytes(for: transcript, in: .fernlet)
}

/// `canonicalBytes(for: manifest, in: .fernlet)`: a routed manifest under Fernlet's labels.
func canonicalBytes(for manifest: MeshRoutedManifest) -> Data {
    canonicalBytes(for: manifest, in: .fernlet)
}

/// `canonicalBytes(for: chunk, in: .fernlet)`: a routed chunk under Fernlet's labels.
func canonicalBytes(for chunk: MeshChunk) -> Data {
    canonicalBytes(for: chunk, in: .fernlet)
}

/// `canonicalBytes(for: receipt, in: .fernlet)`: a custody receipt under Fernlet's labels.
func canonicalBytes(for receipt: MeshCustodyReceipt) -> Data {
    canonicalBytes(for: receipt, in: .fernlet)
}

/// `canonicalBytes(for: receipt, in: .fernlet)`: a recipient receipt under Fernlet's labels.
func canonicalBytes(for receipt: MeshRecipientReceipt) -> Data {
    canonicalBytes(for: receipt, in: .fernlet)
}

/// `canonicalBytes(for: payload, in: .fernlet)`: a routed inventory digest under Fernlet's labels.
func canonicalBytes(for payload: MeshRoutedInventoryPayload) -> Data {
    canonicalBytes(for: payload, in: .fernlet)
}

/// `canonicalBytes(for: payload, in: .fernlet)`: a routed drain answer under Fernlet's labels.
func canonicalBytes(for payload: MeshRoutedDrainAnswerPayload) -> Data {
    canonicalBytes(for: payload, in: .fernlet)
}

// MARK: - Signed transcripts II: the verifiers and the exchange (A0.2.5)
//
// The six routed verifiers and the channel-introduction exchange each keep a copy of the labels they
// check under (a trailing `purposes:` since step A0.2.5); each old initializer comes back here,
// keeping Fernlet's labels as that copy.

/// The manifest door's initializer the suites were written against (plan step A0.2.5).
extension MeshRoutedManifestVerifier {

    /// `init(meshID:hardDeadline:ledger:acceptedTypeTokens:purposes: .fernlet)`.
    init(meshID: UUID, hardDeadline: Date, ledger: MeshMembershipLedger, acceptedTypeTokens: Set<String>) {
        self.init(meshID: meshID, hardDeadline: hardDeadline, ledger: ledger,
                  acceptedTypeTokens: acceptedTypeTokens, purposes: .fernlet)
    }
}

/// The chunk door's initializer the suites were written against (plan step A0.2.5).
extension MeshChunkVerifier {

    /// `init(meshID:hardDeadline:ledger:manifest:purposes: .fernlet)`.
    init(meshID: UUID, hardDeadline: Date, ledger: MeshMembershipLedger, manifest: MeshRoutedManifest?) {
        self.init(meshID: meshID, hardDeadline: hardDeadline, ledger: ledger, manifest: manifest, purposes: .fernlet)
    }
}

/// The custody-receipt door's initializer the suites were written against (plan step A0.2.5).
extension MeshCustodyReceiptVerifier {

    /// `init(meshID:hardDeadline:ledger:manifest:purposes: .fernlet)`.
    init(meshID: UUID, hardDeadline: Date, ledger: MeshMembershipLedger, manifest: MeshRoutedManifest?) {
        self.init(meshID: meshID, hardDeadline: hardDeadline, ledger: ledger, manifest: manifest, purposes: .fernlet)
    }
}

/// The recipient-receipt door's initializer the suites were written against (plan step A0.2.5).
extension MeshRecipientReceiptVerifier {

    /// `init(meshID:hardDeadline:ledger:manifest:purposes: .fernlet)`.
    init(meshID: UUID, hardDeadline: Date, ledger: MeshMembershipLedger, manifest: MeshRoutedManifest?) {
        self.init(meshID: meshID, hardDeadline: hardDeadline, ledger: ledger, manifest: manifest, purposes: .fernlet)
    }
}

/// The routed-inventory door's initializer the suites were written against (plan step A0.2.5).
extension MeshRoutedInventoryVerifier {

    /// `init(meshID:ledger:purposes: .fernlet)`.
    init(meshID: UUID, ledger: MeshMembershipLedger) {
        self.init(meshID: meshID, ledger: ledger, purposes: .fernlet)
    }
}

/// The drain-answer door's initializer the suites were written against (plan step A0.2.5).
extension MeshRoutedDrainAnswerVerifier {

    /// `init(meshID:ledger:purposes: .fernlet)`.
    init(meshID: UUID, ledger: MeshMembershipLedger) {
        self.init(meshID: meshID, ledger: ledger, purposes: .fernlet)
    }
}

/// The channel-introduction exchange's initializer the suites were written against (plan step
/// A0.2.5).
extension MeshChannelIntroductionExchange {

    /// `init(role:localHello:purposes: .fernlet)`.
    init(role: MeshChannelRole, localHello: MeshChannelHello) {
        self.init(role: role, localHello: localHello, purposes: .fernlet)
    }
}

// MARK: - The verify QR (A0.2.5)

/// The verify QR's calls in the shapes the suites were written against, restored over their
/// namespace forms with Fernlet's namespace (plan step A0.2.5).
extension ProximityVerifyQR {

    /// The scheme the retired `ProximityVerifyQR.urlScheme` spelled: `.fernlet`'s
    /// `family.verifyQR.urlScheme`, read off the value, never respelled here.
    static let urlScheme = ProximityNamespace.fernlet.family.verifyQR.urlScheme

    /// `parse(url, in: .fernlet)`.
    static func parse(_ url: URL) -> Payload? {
        parse(url, in: .fernlet)
    }

    /// `isValid(payload, at: now, in: .fernlet)`.
    static func isValid(_ payload: Payload, at now: Date = Date()) -> Bool {
        isValid(payload, at: now, in: .fernlet)
    }
}

/// The response transcript in the shape the suites were written against (plan step A0.2.5).
extension ProximityVerifySignature {

    /// `message(scannerKeyAgreementPublicKey:challengeNonce:qrNonce:in: .fernlet)`.
    static func message(scannerKeyAgreementPublicKey: Data, challengeNonce: Data, qrNonce: Data) -> Data {
        message(scannerKeyAgreementPublicKey: scannerKeyAgreementPublicKey, challengeNonce: challengeNonce,
                qrNonce: qrNonce, in: .fernlet)
    }
}

// MARK: - Hashes, AEAD, salts, epoch: the routed digests and ids (A0.2.6)
//
// Step A0.2.6 moved the routed family's hash and id domains onto the namespace. The three
// `MeshRoutedContentDigest` statics, the streaming hasher's initializer and the assembly's two verbs
// come back here in their old shapes, and the three ids that used to be computed properties come
// back as properties — `chunk.chunkID`, `receipt.receiptID` — each over its `in:` form with
// Fernlet's labels.

/// The routed digests in the shapes the suites were written against (plan step A0.2.6).
extension MeshRoutedContentDigest {

    /// `contentHash(of: blob, in: .fernlet)`.
    static func contentHash(of blob: Data) -> Data {
        contentHash(of: blob, in: .fernlet)
    }

    /// `chunkHash(of: payload, in: .fernlet)`.
    static func chunkHash(of payload: Data) -> Data {
        chunkHash(of: payload, in: .fernlet)
    }

    /// `chunkID(itemID:chunkIndex:in: .fernlet)`.
    static func chunkID(itemID: UUID, chunkIndex: UInt32) -> UUID {
        chunkID(itemID: itemID, chunkIndex: chunkIndex, in: .fernlet)
    }
}

/// A chunk's replay-window id as the property the suites were written against (plan step A0.2.6).
extension MeshChunk {

    /// `chunkID(in: .fernlet)`.
    var chunkID: UUID { chunkID(in: .fernlet) }
}

/// A custody receipt's dedup id as the property the suites were written against (plan step A0.2.6).
extension MeshCustodyReceipt {

    /// `receiptID(in: .fernlet)`.
    var receiptID: UUID { receiptID(in: .fernlet) }
}

/// A recipient receipt's dedup id as the property the suites were written against (plan step A0.2.6).
extension MeshRecipientReceipt {

    /// `receiptID(in: .fernlet)`.
    var receiptID: UUID { receiptID(in: .fernlet) }
}

/// The streaming content hasher's initializer the suites were written against (plan step A0.2.6).
extension MeshRoutedContentHasher {

    /// `MeshRoutedContentHasher(purposes: .fernlet)`.
    init() {
        self.init(purposes: .fernlet)
    }
}

/// The in-memory reassembler's two verbs in the shapes the suites were written against (plan step
/// A0.2.6).
extension MeshChunkAssembly {

    /// `admit(chunk, in: .fernlet)`.
    mutating func admit(_ chunk: MeshChunk) -> MeshChunkAdmission {
        admit(chunk, in: .fernlet)
    }

    /// `completion(against: manifest, in: .fernlet)`.
    func completion(against manifest: MeshRoutedManifest) -> MeshChunkCompletion {
        completion(against: manifest, in: .fernlet)
    }
}

// MARK: - Hashes, AEAD, salts, epoch: the routed seals (A0.2.6)
//
// The item seal and the per-recipient content-key wrap read their AEAD labels — and the wrap its
// HKDF salt — off the namespace since step A0.2.6; each door comes back here with Fernlet's labels.

/// The routed item seal's three doors in the shapes the suites were written against (plan step
/// A0.2.6).
extension MeshRoutedItemSealer {

    /// `seal(_:contentKey:binding:typeToken:in: .fernlet)`.
    static func seal(
        _ plaintext: Data, contentKey: Data, binding: MeshRoutedWrapBinding, typeToken: String
    ) throws -> Data {
        try seal(plaintext, contentKey: contentKey, binding: binding, typeToken: typeToken, in: .fernlet)
    }

    /// `open(_:contentKey:binding:typeToken:in: .fernlet)`.
    static func open(
        _ blob: Data, contentKey: Data, binding: MeshRoutedWrapBinding, typeToken: String
    ) throws -> Data {
        try open(blob, contentKey: contentKey, binding: binding, typeToken: typeToken, in: .fernlet)
    }

    /// `additionalData(binding:typeToken:in: .fernlet)`.
    static func additionalData(binding: MeshRoutedWrapBinding, typeToken: String) -> Data {
        additionalData(binding: binding, typeToken: typeToken, in: .fernlet)
    }
}

/// The content-key wrap's three doors in the shapes the suites were written against (plan step
/// A0.2.6).
extension MeshRoutedContentKeyWrapper {

    /// `wrap(contentKey:recipientFingerprint:recipientKeyAgreementPublicKey:binding:in: .fernlet)`.
    static func wrap(
        contentKey: Data, recipientFingerprint: String, recipientKeyAgreementPublicKey: Data,
        binding: MeshRoutedWrapBinding
    ) throws -> MeshRecipientKeyWrap {
        try wrap(contentKey: contentKey, recipientFingerprint: recipientFingerprint,
                 recipientKeyAgreementPublicKey: recipientKeyAgreementPublicKey, binding: binding, in: .fernlet)
    }

    /// `unwrap(_:binding:localFingerprint:localKeyAgreementPublicKey:staticAgreement:in: .fernlet)`.
    static func unwrap(
        _ wrap: MeshRecipientKeyWrap, binding: MeshRoutedWrapBinding, localFingerprint: String,
        localKeyAgreementPublicKey: Data, staticAgreement: (Data) throws -> SharedSecret
    ) throws -> Data {
        try unwrap(wrap, binding: binding, localFingerprint: localFingerprint,
                   localKeyAgreementPublicKey: localKeyAgreementPublicKey, staticAgreement: staticAgreement,
                   in: .fernlet)
    }

    /// `additionalData(binding:recipientFingerprint:in: .fernlet)`.
    static func additionalData(binding: MeshRoutedWrapBinding, recipientFingerprint: String) -> Data {
        additionalData(binding: binding, recipientFingerprint: recipientFingerprint, in: .fernlet)
    }
}

// MARK: - Hashes, AEAD, salts, epoch: the epoch (A0.2.6)
//
// Step A0.2.6 deleted `MeshEpochBounds.derivationDomain`: every epoch id is derived under the
// namespace's `hash.meshEpochIDV1`. The two minting doors and the rotation plan come back here with
// Fernlet's labels.

/// The epoch's two minting doors in the shapes the suites were written against (plan step A0.2.6).
extension MeshEpochRef {

    /// `minted(counter:coordinatorFingerprint:meshID:in: .fernlet)`.
    static func minted(counter: UInt32, coordinatorFingerprint: String, meshID: UUID) -> MeshEpochRef? {
        minted(counter: counter, coordinatorFingerprint: coordinatorFingerprint, meshID: meshID, in: .fernlet)
    }

    /// `successor(coordinatorFingerprint:meshID:in: .fernlet)`.
    func successor(coordinatorFingerprint: String, meshID: UUID) -> MeshEpochRef? {
        successor(coordinatorFingerprint: coordinatorFingerprint, meshID: meshID, in: .fernlet)
    }
}

/// The rotation plan in the shape the suites were written against (plan step A0.2.6).
extension MeshRotationPolicy {

    /// `plan(head:coordinatorFingerprint:meshID:presentedRoster:in: .fernlet)`.
    static func plan(
        head: MeshEpochRef?, coordinatorFingerprint: String, meshID: UUID, presentedRoster: [String]
    ) -> MeshRotationPlan {
        plan(head: head, coordinatorFingerprint: coordinatorFingerprint, meshID: meshID,
             presentedRoster: presentedRoster, in: .fernlet)
    }
}

// MARK: - The three radios (A0.2.7)

/// The argument-less radio initializer the suites were written against, restored over
/// `init(namespace:)` with Fernlet's namespace (plan step A0.2.7). The radios are internal, so this
/// file imports ProximityKit `@testable`.
///
/// A binding restores a call shape, never a value: a test that pins a service type, an ALPN or the
/// heartbeat reads it off `ProximityNamespace.fernlet.family.radios` instead of off a radio built
/// here. Each inherits the class's main-actor isolation, as the initializer it replaces had.
extension NetworkMeshSession {

    /// `NetworkMeshSession(namespace: .fernlet)`: the friend mesh's radio on Fernlet's wire, the radio
    /// the retired `init()` built.
    convenience init() {
        self.init(namespace: .fernlet)
    }
}

/// The presence radio's argument-less initializer, restored as ``NetworkMeshSession``'s is.
extension NetworkPresenceSession {

    /// `NetworkPresenceSession(namespace: .fernlet)`: the presence radio on Fernlet's wire, the radio
    /// the retired `init()` built.
    convenience init() {
        self.init(namespace: .fernlet)
    }
}

/// The recipe-share radio's argument-less initializer, restored as ``NetworkMeshSession``'s is.
extension NetworkRecipeShareSession {

    /// `NetworkRecipeShareSession(namespace: .fernlet)`: the recipe-share radio on Fernlet's wire, the
    /// radio the retired `init()` built.
    convenience init() {
        self.init(namespace: .fernlet)
    }
}

// MARK: - At rest: names and rows (A0.2.8)
//
// Step A0.2.8 moved the mesh stores' file names and seal-key accounts and the identity's four
// accounts onto the namespace's installation: the seal-key helpers take the row's `account:` and the
// identity's row classifier the `accounts:` its refusals name. Each old shape comes back here with
// Fernlet's rows, read off `.fernlet`, never respelled. The routed store's two hashing verbs that
// step A0.2.6 restored above are gone from this file: since A0.2.8 the store measures under its
// scope's namespace, so `stagingChunk(_:now:)` and `committingCustody(item:custodian:now:)` are its
// own shapes again.

/// The mesh-session seal key's two reads in the shapes the suites were written against (plan step
/// A0.2.8), with Fernlet's mesh-session seal-key account.
extension MeshSessionSealKey {

    /// `forOpen(service:account:)` with `.fernlet`'s `installation.keychain.meshSessionSealKey.account`.
    static func forOpen(service: String) -> MeshSessionSealKeyOutcome {
        forOpen(service: service, account: ProximityNamespace.fernlet.installation.keychain.meshSessionSealKey.account)
    }

    /// `forSeal(service:account:)` with `.fernlet`'s `installation.keychain.meshSessionSealKey.account`.
    static func forSeal(service: String) -> MeshSessionSealKeyOutcome {
        forSeal(service: service, account: ProximityNamespace.fernlet.installation.keychain.meshSessionSealKey.account)
    }
}

/// The routed seal key's two reads and its account in the shapes the suites were written against
/// (plan step A0.2.8), with Fernlet's routed seal-key account.
extension MeshRoutedSealKey {

    /// The account the retired `MeshRoutedSealKey.keychainAccount` spelled: `.fernlet`'s
    /// `installation.keychain.meshRoutedSealKey.account`, read off the value, never respelled here.
    static let keychainAccount = ProximityNamespace.fernlet.installation.keychain.meshRoutedSealKey.account

    /// `forOpen(service:account:)` with `.fernlet`'s routed seal-key account.
    static func forOpen(service: String) -> MeshRoutedSealKeyOutcome {
        forOpen(service: service, account: keychainAccount)
    }

    /// `forSeal(service:account:)` with `.fernlet`'s routed seal-key account.
    static func forSeal(service: String) -> MeshRoutedSealKeyOutcome {
        forSeal(service: service, account: keychainAccount)
    }
}

/// The identity-row classifier in the shape the suites were written against (plan step A0.2.8). It
/// inherits the class's main-actor isolation, as the function it restores has. Since step A0.2.11 the
/// two reads are ProximityKit's own `ProximityKeychainItem.ReadResult`, as the function takes them.
extension IdentityService {

    /// `classifyDeviceIdentityRows(signing:keyAgreement:accounts:)` with `.fernlet`'s
    /// `installation.keychain.identity`.
    static func classifyDeviceIdentityRows(
        signing: ProximityKeychainItem.ReadResult, keyAgreement: ProximityKeychainItem.ReadResult
    ) -> DeviceIdentityRead {
        classifyDeviceIdentityRows(signing: signing, keyAgreement: keyAgreement,
                                   accounts: ProximityNamespace.fernlet.installation.keychain.identity)
    }
}

// MARK: - Presentation strings (A0.3.2)
//
// The radios' instance-name prefixes and certificate name, and the name display's prefix, are read
// off the namespace: the minting doors take the prefix and the common name their radio or manager
// read from its namespace, and `PeerNameDisplay` takes the namespace last. Each old shape comes back
// here with `.fernlet`'s `family.radios` values, read off the value, never respelled. A cell whose
// subject is a prefix or the common name passes `.fernlet`'s value explicitly instead. FernletSocial's
// `PresenceManager.firstName`, which takes the namespace last too, has its old shape in
// `FernletSocialTestBindings.swift`.

/// The mesh instance name in the shape the suites were written against (plan step A0.3.2).
extension MeshLinkAdvertisement {

    /// `randomInstanceName(prefix:)` with `.fernlet`'s `family.radios.meshInstanceNamePrefix`.
    static func randomInstanceName() -> String {
        randomInstanceName(prefix: ProximityNamespace.fernlet.family.radios.meshInstanceNamePrefix)
    }
}

/// The certificate path's two doors in the shapes the suites were written against (plan step
/// A0.3.2), with `.fernlet`'s common name.
extension EphemeralMeshTLSIdentity {

    /// `mint(commonName:now:)` with `.fernlet`'s `family.radios.tlsCommonName`.
    static func mint(now: Date = Date()) throws -> Minted {
        try mint(commonName: ProximityNamespace.fernlet.family.radios.tlsCommonName, now: now)
    }

    /// `selfSignedCertificateDER(for:commonName:notBefore:notAfter:serial:)` with `.fernlet`'s
    /// `family.radios.tlsCommonName`.
    static func selfSignedCertificateDER(
        for privateKey: P256.Signing.PrivateKey, notBefore: Date, notAfter: Date, serial: [UInt8]
    ) throws -> Data {
        try selfSignedCertificateDER(
            for: privateKey, commonName: ProximityNamespace.fernlet.family.radios.tlsCommonName,
            notBefore: notBefore, notAfter: notAfter, serial: serial)
    }
}

/// The presence posture's minting, rotation and naming doors in the shapes the suites were written
/// against (plan step A0.3.2), with `.fernlet`'s presence prefix and, where a door mints the
/// certificate itself, its common name.
extension PresenceEpochPosture {

    /// `minted(at:instanceNamePrefix:commonName:)` with `.fernlet`'s values.
    static func minted(at now: Date) throws -> PresenceEpochPosture {
        let radios = ProximityNamespace.fernlet.family.radios
        return try minted(
            at: now, instanceNamePrefix: radios.presenceInstanceNamePrefix, commonName: radios.tlsCommonName)
    }

    /// `minted(at:instanceNamePrefix:entropy:mintIdentity:)` with `.fernlet`'s presence prefix.
    static func minted(
        at now: Date, entropy: (Int) -> [UInt8], mintIdentity: (Date) throws -> EphemeralMeshTLSIdentity.Minted
    ) throws -> PresenceEpochPosture {
        try minted(
            at: now, instanceNamePrefix: ProximityNamespace.fernlet.family.radios.presenceInstanceNamePrefix,
            entropy: entropy, mintIdentity: mintIdentity)
    }

    /// `rotated(at:instanceNamePrefix:commonName:)` with `.fernlet`'s values.
    func rotated(at now: Date) throws -> PresenceEpochPosture {
        let radios = ProximityNamespace.fernlet.family.radios
        return try rotated(
            at: now, instanceNamePrefix: radios.presenceInstanceNamePrefix, commonName: radios.tlsCommonName)
    }

    /// `rotated(at:instanceNamePrefix:entropy:mintIdentity:)` with `.fernlet`'s presence prefix.
    func rotated(
        at now: Date, entropy: (Int) -> [UInt8], mintIdentity: (Date) throws -> EphemeralMeshTLSIdentity.Minted
    ) throws -> PresenceEpochPosture {
        try rotated(
            at: now, instanceNamePrefix: ProximityNamespace.fernlet.family.radios.presenceInstanceNamePrefix,
            entropy: entropy, mintIdentity: mintIdentity)
    }

    /// `instanceName(prefix:entropy:)` with `.fernlet`'s presence prefix.
    static func instanceName(entropy: (Int) -> [UInt8]) throws -> String {
        try instanceName(prefix: ProximityNamespace.fernlet.family.radios.presenceInstanceNamePrefix, entropy: entropy)
    }
}

/// The recipe posture's mint in the shape the suites were written against (plan step A0.3.2).
extension RecipeSharePosture {

    /// `minted(instanceNamePrefix:commonName:now:)` with `.fernlet`'s mesh prefix and common name.
    static func minted(now: Date = Date()) throws -> RecipeSharePosture {
        let radios = ProximityNamespace.fernlet.family.radios
        return try minted(
            instanceNamePrefix: radios.meshInstanceNamePrefix, commonName: radios.tlsCommonName, now: now)
    }
}

/// The name display's three rules in the shapes the suites were written against (plan step
/// A0.3.2), each recognizing `.fernlet`'s mesh instance-name prefix.
extension PeerNameDisplay {

    /// `personName(_:fingerprint:in: .fernlet)`.
    static func personName(_ raw: String, fingerprint: String?) -> String? {
        personName(raw, fingerprint: fingerprint, in: .fernlet)
    }

    /// `shown(_:fingerprint:placeholder:in: .fernlet)`.
    static func shown(_ raw: String, fingerprint: String?, placeholder: Placeholder = .nearby) -> String {
        shown(raw, fingerprint: fingerprint, placeholder: placeholder, in: .fernlet)
    }

    /// `firstName(_:fingerprint:placeholder:in: .fernlet)`.
    static func firstName(_ raw: String, fingerprint: String?, placeholder: Placeholder = .nearby) -> String {
        firstName(raw, fingerprint: fingerprint, placeholder: placeholder, in: .fernlet)
    }
}

// MARK: - Record kinds and routed types (A0.3.3)
//
// ProximityKit spells no routed type: the routed type registry builds its rows from the routed types
// it is handed, its ack-stage projection likewise, and the manifest mint takes its registry with no
// default. The routed-type constants, the two `increment1` values and the mint's old shape come back
// here with `.fernlet`'s `family.vocabulary.routedTypes`, read off the value, never respelled. A cell
// whose subject is a token's spelling, or a registry's tokens, names `.fernlet` explicitly instead.
// (The membership record kinds need no binding of their own: the verifier, the adoption and the
// digest above take Fernlet's family, record kinds included.)

/// The routed-type tokens the suites were written against, each read off `.fernlet`'s
/// `family.vocabulary.routedTypes` (plan step A0.3.3), never respelled here.
enum MeshRoutedTypeToken {
    /// `.fernlet`'s routed photo type.
    static let photo = ProximityNamespace.fernlet.family.vocabulary.routedTypes.photo
    /// `.fernlet`'s routed temporary-message type.
    static let tempMessage = ProximityNamespace.fernlet.family.vocabulary.routedTypes.tempMessage
    /// `.fernlet`'s routed heart type, whose manifest's item id is the gift id.
    static let heart = ProximityNamespace.fernlet.family.vocabulary.routedTypes.heart
    /// `.fernlet`'s reserved control type, registered for nothing.
    static let control = ProximityNamespace.fernlet.family.vocabulary.routedTypes.control
}

/// The shipping registry in the shape the suites were written against (plan step A0.3.3).
extension MeshRoutedTypeRegistry {

    /// `increment1(_:)` over `.fernlet`'s `family.vocabulary.routedTypes`: the registry the retired
    /// `increment1` value held.
    static var increment1: MeshRoutedTypeRegistry {
        increment1(ProximityNamespace.fernlet.family.vocabulary.routedTypes)
    }
}

/// The ack-stage projection in the shape the suites were written against (plan step A0.3.3).
extension MeshRoutedAckStageTable {

    /// `increment1(_:)` over `.fernlet`'s `family.vocabulary.routedTypes`: the table the retired
    /// `increment1` value held.
    static var increment1: MeshRoutedAckStageTable {
        increment1(ProximityNamespace.fernlet.family.vocabulary.routedTypes)
    }
}

/// The manifest mint in the shape the suites were written against, with the registry its retired
/// `types:` default named (plan step A0.3.3). It inherits the mint's main-actor isolation.
extension MeshRoutedManifest {

    /// `signed(...types:)` with `.fernlet`'s registry, `increment1(_:)` over its routed types.
    @MainActor
    static func signed(
        meshID: UUID, target: MeshDeliveryTarget, typeToken: String, contentHash: Data, size: UInt64,
        createdAt: Date, hardDeadline: Date, contentKey: Data, recipientKeys: [String: Data],
        identity: IdentityService
    ) throws -> MeshRoutedManifest {
        try signed(
            meshID: meshID, target: target, typeToken: typeToken, contentHash: contentHash, size: size,
            createdAt: createdAt, hardDeadline: hardDeadline, contentKey: contentKey,
            recipientKeys: recipientKeys, identity: identity,
            types: MeshRoutedTypeRegistry.increment1(ProximityNamespace.fernlet.family.vocabulary.routedTypes))
    }
}

// MARK: - The envelope's and the coordinator's vocabulary (A0.3.4)
//
// The envelope seals and parks by its identity's namespace's payload rules, and the coordinator signs
// its session messages under that namespace's tokens and titles; neither changed a call shape. The
// capability gates did: a peer's `supports` takes the host's capabilities, whose legacy assumption it
// applies to a peer that listed none. Its old shape comes back here with `.fernlet`'s
// `family.vocabulary.capabilities`, read off the value. A cell whose subject is the legacy
// assumption names `.fernlet` explicitly instead.

/// The coordinator's capability gate in the shape the suites were written against (plan step A0.3.4).
/// It is main-actor, as the gate it restores is.
extension ProximityCoordinator.PeerIdentity {

    /// `supports(_:in:)` with `.fernlet`'s `family.vocabulary.capabilities`.
    @MainActor
    func supports(_ capability: ProximityCapability) -> Bool {
        supports(capability, in: ProximityNamespace.fernlet.family.vocabulary.capabilities)
    }
}

// MARK: - The display-name policy (A0.3.12)
//
// ProximityKit sanitizes a peer's name with its own sanitizer (`ProximityDisplayName`) and applies the
// cap and the floor of the namespace each reader holds (`installation.peerNames`): its coercion is
// `ProximityDisplayName.peerDisplayName(_:in:)` rather than an extension of FernletDomainModel's
// `ItemNameModeration`, the envelope's two sender reads are functions taking the namespace, and the
// advertised recipe name and the session message store's ingest take it last. Each old shape comes
// back here with `.fernlet`'s peer-name policy, never a cap or a floor of its own. A cell whose subject
// is the cap or the floor names `.fernlet` explicitly instead.

/// ProximityKit's peer-name coercion in the shape the suites were written against (plan step
/// A0.3.12), on the type that used to carry it.
extension ItemNameModeration {

    /// `ProximityDisplayName.peerDisplayName(raw, in: .fernlet)`.
    static func moderatedPeerDisplayName(_ raw: String) -> String {
        ProximityDisplayName.peerDisplayName(raw, in: .fernlet)
    }
}

/// The envelope's two sender reads as the properties the suites were written against (plan step
/// A0.3.12), each under `.fernlet`'s peer-name policy.
extension FernletIdentityEnvelope {

    /// `sanitizedSenderDisplayName(in: .fernlet)`.
    var sanitizedSenderDisplayName: String { sanitizedSenderDisplayName(in: .fernlet) }

    /// `disclosedSenderDisplayName(in: .fernlet)`.
    var disclosedSenderDisplayName: String? { disclosedSenderDisplayName(in: .fernlet) }
}

/// The advertised recipe name in the shape the suites were written against (plan step A0.3.12).
extension RecipeShareAdvertisedName {

    /// `publishable(_:in: .fernlet)`.
    static func publishable(_ raw: String) -> String {
        publishable(raw, in: .fernlet)
    }
}

/// The session message store's ingest in the shape the suites were written against (plan step
/// A0.3.12). It inherits the store's main-actor isolation, as the function it restores has.
extension SessionMessageStore {

    /// `receiveIncoming(id:senderFingerprint:senderDisplayName:text:sentAt:seenAt:in: .fernlet)`.
    func receiveIncoming(
        id: UUID, senderFingerprint: String, senderDisplayName: String, text rawText: String,
        sentAt: Date, seenAt: Date
    ) -> Acceptance {
        receiveIncoming(id: id, senderFingerprint: senderFingerprint, senderDisplayName: senderDisplayName,
                        text: rawText, sentAt: sentAt, seenAt: seenAt, in: .fernlet)
    }
}

// MARK: - The static key agreement (A0.4.2)
//
// The identity's static key agreement names no feature: it is `staticKeyAgreement(withEphemeralPublicKey:)`,
// which the routed content-key unwrap and the heart dead-drop's static fallback both call. The suites
// were written against its heart-drop spelling, which comes back here as a pure rename: it takes no
// namespace, so it passes nothing at all.

/// The static key agreement in the spelling the suites were written against (plan step A0.4.2). It
/// inherits the class's main-actor isolation, as the method it restores has.
extension IdentityService {

    /// `staticKeyAgreement(withEphemeralPublicKey:)`.
    func heartDropStaticAgreement(withEphemeralPublicKey key: Data) throws -> SharedSecret {
        try staticKeyAgreement(withEphemeralPublicKey: key)
    }
}
