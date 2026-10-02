// ProximityNamespaceTestBindings.swift
// FernletTests
//
// ProximityKit plan step A0.2.3 (Docs/Plan-FernletCoach-ProximityKit-2026-10-01.md §4 A0.2): the one
// place the test target gets back the call shapes A0.2 takes out of ProximityKit. ProximityKit offers
// no namespace default, so every API that used to spell Fernlet's bytes for itself now takes the
// host's `ProximityNamespace`. The suites were written against the old shapes; rather than rewrite
// every construction in every suite, each old shape comes back here once, passing Fernlet's value.
//
// THE RULE. A binding restores a call SHAPE, never a value: it passes `ProximityNamespace.fernlet`,
// exactly the value FernletConnections ships and the app hands ProximityKit, so a suite that goes
// through one sees the bytes it always saw, and nothing here may pass anything else or compute a
// label, a row or a name of its own. A test that PINS a value does not lean on a binding: it names
// `.fernlet` explicitly (`IdentityService(namespace: .fernlet)`), so what it pins is visibly
// Fernlet's and still reads correctly once a binding is retired. Later A0.2 commits add their
// bindings to this file, each beside the API it restores.
//
// Where an API takes the namespace's labels rather than the whole namespace (step A0.2.4 on), the
// binding passes `.fernlet` for a `ProximityNamespace.Purposes`: FernletConnections'
// `ProximityNamespace.Purposes.fernlet`, the very value `ProximityNamespace.fernlet.family.purposes`
// holds (ProximityNamespaceGoldenTests pins the two equal).

import CryptoKit
import FernletConnections
import FernletFoundation
import Foundation
@testable import ProximityKit

// MARK: - IdentityService (A0.2.3)

/// The two `IdentityService` initializers the suites were written against, restored over
/// `init(namespace:keychainService:)` with Fernlet's namespace (plan step A0.2.3).
///
/// A binding restores a call shape, never a value; a test that pins a value names `.fernlet`
/// explicitly instead of calling one of these. Both inherit the class's main-actor isolation, as the
/// initializers they replace had.
extension IdentityService {

    /// `IdentityService(namespace: .fernlet)`: this device's identity on Fernlet's identity service,
    /// the identity the retired argument-less initializer built.
    convenience init() {
        self.init(namespace: .fernlet)
    }

    /// `IdentityService(namespace: .fernlet, keychainService:)`: an identity on a keychain service of
    /// the test's own, the identity the retired `init(keychainService:)` built.
    ///
    /// - Parameter keychainService: The test's own service, usually a throwaway one.
    convenience init(keychainService: String) {
        self.init(namespace: .fernlet, keychainService: keychainService)
    }
}

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
/// `init(meshID:founderSigningPublicKey:ledger:purposes:)` with Fernlet's labels (plan step A0.2.4).
extension MeshMembershipRecordVerifier {

    /// A verifier keeping Fernlet's labels as its copy, otherwise exactly the retired initializer.
    ///
    /// - Parameters:
    ///   - meshID: The mesh every accepted record must name.
    ///   - founderSigningPublicKey: The key that may bootstrap an admission, if known.
    ///   - ledger: The records to start from.
    init(meshID: UUID, founderSigningPublicKey: Data? = nil, ledger: MeshMembershipLedger = .empty) {
        self.init(meshID: meshID, founderSigningPublicKey: founderSigningPublicKey, ledger: ledger,
                  purposes: .fernlet)
    }
}

/// The joiner's two ledger steps in the shapes the suites were written against, restored over their
/// `in purposes:` forms with Fernlet's labels (plan step A0.2.4).
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
/// `init(meshID:ledger:purposes:)` with Fernlet's labels (plan step A0.2.4).
extension MeshInventoryDigest {

    /// The digest of `ledger`, its records hash under Fernlet's labels.
    init(meshID: UUID, ledger: MeshMembershipLedger) {
        self.init(meshID: meshID, ledger: ledger, purposes: .fernlet)
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
/// inherits the class's main-actor isolation, as the function it restores has.
extension IdentityService {

    /// `classifyDeviceIdentityRows(signing:keyAgreement:accounts:)` with `.fernlet`'s
    /// `installation.keychain.identity`.
    static func classifyDeviceIdentityRows(
        signing: KeychainItem.ReadResult, keyAgreement: KeychainItem.ReadResult
    ) -> DeviceIdentityRead {
        classifyDeviceIdentityRows(signing: signing, keyAgreement: keyAgreement,
                                   accounts: ProximityNamespace.fernlet.installation.keychain.identity)
    }
}
