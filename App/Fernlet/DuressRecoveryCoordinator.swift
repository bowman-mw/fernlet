// DuressRecoveryCoordinator.swift
// Fernlet
//
// Phase 7 (duress PIN), step 8: the two in-person ceremonies that make `DuressMode.recoveryLock`
// possible — enrolling the user's own second device as a recovery custodian, and getting the
// content key back from it afterwards.
//
// WHY THIS FILE IS IN THE APP TARGET. The crypto/custody half lives in `FernletLock`
// (`enrollRecoveryCustodian`, `custodianRecoveryBlob`, `reestablishLocalUnlock`); the ceremony half
// needs `ProximityKit` (the signed `fernlet://verify` QR, `IdentityService`'s X25519 seal/open).
// `FernletLock` must gain NO ProximityKit dependency edge (Plan §11, "Seam placement / wall"), and
// the app target already imports both — so the ceremony lands here, and the two halves meet through
// a closure (`sealingContentKeyTo:`) rather than through a package edge.
//
// THERE IS NO CLOUD PATH, DELIBERATELY. Recovery is in-person mesh + QR only (locked decision), so
// this file adds no outbound destination and `Docs/No-Tracking-Wall.md` is unchanged. Do not add
// a CloudKit or dead-drop route here: an off-device recovery channel would turn "a second key
// holder you can walk to" into "a second key holder anyone can reach".

import CryptoKit
import Foundation
import FernletFoundation
import FernletLock
import ProximityKit

// MARK: - Wire payloads

/// What a custodian did with a recovery request — the one bit its human answers with.
///
/// Persisted nowhere; it rides one byte of the signed reply transcript, so the two devices can
/// never disagree about which answer was given.
enum DuressRecoveryDecision: UInt8, Codable, Equatable, Sendable {
    /// Give the content key back; the primary rebuilds a local unlock around it.
    case returnKey = 0
    /// Refuse, and tell the primary to destroy what it still holds — the answer for "that phone is
    /// not with me any more".
    case destroy = 1
}

/// Primary → custodian, carried inside an `IdentityService.seal(_:to:format:.wire2)` envelope.
///
/// Everything the custodian needs to decide and to act: the ceremony round it is bound to, who is
/// asking (for the human's fingerprint check), and the sealed recovery blob itself. The signature
/// is over ``DuressRecoveryTranscript/request(challengeNonce:requesterSigningPublicKey:requesterKeyAgreementPublicKey:custodianSigningPublicKey:custodianKeyAgreementPublicKey:recoveryBlob:)``.
///
/// The signature is NOT what authorizes the exchange — `IdentityService`'s seal provides
/// confidentiality, not sender authentication, so a signature inside a sealed body proves only that
/// whoever composed it holds that signing key. Authorization comes from two other places: the blob
/// opens only for the genuine custodian, and the reply is sealed to the SAME key that authenticated
/// the blob. The signature is what lets the custodian's human see a stable fingerprint and lets the
/// round be pinned to one live ceremony.
struct DuressRecoveryRequest: Codable, Equatable, Sendable {
    /// Wire version; only `1` is accepted.
    let version: Int
    /// The `VerifyChallengePayload` nonce from the live QR round this request belongs to.
    let challengeNonce: Data
    /// The requesting device's Ed25519 public key — displayed as a fingerprint, never trusted.
    let requesterSigningPublicKey: Data
    /// The requesting device's X25519 public key. Informational only: the custodian opens the blob
    /// with the KA key the ceremony proved, never with this one.
    let requesterKeyAgreementPublicKey: Data
    /// `FernletLockService.custodianRecoveryBlob` — the content key sealed to the custodian at
    /// enrollment.
    let recoveryBlob: Data
    /// Ed25519 signature by `requesterSigningPublicKey` over the request transcript.
    let signature: Data
}

/// Custodian → primary, carried inside an `IdentityService.seal(_:to:format:.wire2)` envelope
/// addressed to the primary's key-agreement public key.
///
/// The signature here IS load-bearing, unlike the request's: without it anyone could seal a
/// `.destroy` reply to the primary's public key and the primary would obey it. It is verified
/// against the key `FernletLockService.enrolledCustodianSigningPublicKey` recorded at enrollment,
/// over ``DuressRecoveryTranscript/reply(challengeNonce:custodianSigningPublicKey:custodianKeyAgreementPublicKey:requesterKeyAgreementPublicKey:decision:contentKey:)``.
struct DuressRecoveryReply: Codable, Equatable, Sendable {
    /// Wire version; only `1` is accepted.
    let version: Int
    /// Echoes the request's round, so a reply cannot be replayed into a later ceremony.
    let challengeNonce: Data
    /// The custodian's answer.
    let decision: DuressRecoveryDecision
    /// The recovered content-key bytes for ``DuressRecoveryDecision/returnKey``; empty for
    /// ``DuressRecoveryDecision/destroy``.
    let contentKey: Data
    /// Ed25519 signature by the enrolled custodian over the reply transcript.
    let signature: Data
}

/// The byte layouts both devices sign over, and the fixed lengths that make them unambiguous.
///
/// Neither transcript uses length prefixes, so every field must be fixed-length — which is why the
/// variable-length members (the recovery blob, the content key) enter as SHA-256 digests and why
/// ``isWellFormed(challengeNonce:signingPublicKey:keyAgreementPublicKey:)`` is checked before
/// anything is signed or verified. Same rule, and the same reason, as
/// `ProximityVerifySignature` in ProximityKit.
enum DuressRecoveryTranscript {
    /// Domain separator for the primary → custodian request.
    static let requestDomain = Data("fernlet.duress.recovery.request.v1".utf8)
    /// Domain separator for the custodian → primary reply. Distinct from ``requestDomain`` so a
    /// signature over one can never be replayed as a signature over the other.
    static let replyDomain = Data("fernlet.duress.recovery.reply.v1".utf8)
    /// Nonce length, matching `ProximityVerifySignature.nonceByteCount`.
    static let nonceByteCount = ProximityVerifySignature.nonceByteCount
    /// Raw Curve25519 public-key length, matching `ProximityVerifySignature.publicKeyByteCount`.
    static let publicKeyByteCount = ProximityVerifySignature.publicKeyByteCount

    /// Whether the wire-supplied fields of a round have the exact lengths the transcripts assume.
    static func isWellFormed(
        challengeNonce: Data,
        signingPublicKey: Data,
        keyAgreementPublicKey: Data
    ) -> Bool {
        challengeNonce.count == nonceByteCount
            && signingPublicKey.count == publicKeyByteCount
            && keyAgreementPublicKey.count == publicKeyByteCount
    }

    /// The request transcript: domain ‖ round ‖ both of the requester's keys ‖ both of the
    /// custodian's keys ‖ SHA-256 of the blob. Naming both devices is what stops a request captured
    /// in one pairing from being presented to a different custodian.
    static func request(
        challengeNonce: Data,
        requesterSigningPublicKey: Data,
        requesterKeyAgreementPublicKey: Data,
        custodianSigningPublicKey: Data,
        custodianKeyAgreementPublicKey: Data,
        recoveryBlob: Data
    ) -> Data {
        requestDomain
            + challengeNonce
            + requesterSigningPublicKey
            + requesterKeyAgreementPublicKey
            + custodianSigningPublicKey
            + custodianKeyAgreementPublicKey
            + Data(SHA256.hash(data: recoveryBlob))
    }

    /// The reply transcript: domain ‖ round ‖ both of the custodian's keys ‖ the requester's KA key
    /// ‖ the decision byte ‖ SHA-256 of the returned key (of empty data for a refusal). Covering the
    /// decision byte is what stops a `.returnKey` reply from being edited into a `.destroy` one.
    static func reply(
        challengeNonce: Data,
        custodianSigningPublicKey: Data,
        custodianKeyAgreementPublicKey: Data,
        requesterKeyAgreementPublicKey: Data,
        decision: DuressRecoveryDecision,
        contentKey: Data
    ) -> Data {
        replyDomain
            + challengeNonce
            + custodianSigningPublicKey
            + custodianKeyAgreementPublicKey
            + requesterKeyAgreementPublicKey
            + Data([decision.rawValue])
            + Data(SHA256.hash(data: contentKey))
    }
}

// MARK: - Errors and outcomes

/// Why a duress-recovery ceremony step refused.
///
/// Every case is a refusal BEFORE anything irreversible happens — no case here describes a
/// half-completed enrollment or a partially installed key, because both ceremonies are ordered so
/// that the only durable writes come last.
enum DuressRecoveryError: Error, Equatable {
    /// The proximity identity keys are missing (`IdentityService.ensureProvisioned` failed).
    case identityUnavailable
    /// The scanned code was not a valid, fresh, correctly signed `fernlet://verify` QR.
    case invalidQRCode
    /// The scanned code is this very device's. A device cannot be its own recovery custodian: the
    /// keys that would open the blob die with the keys the duress response destroys.
    case selfEnrollmentRefused
    /// The scanned code belongs to a device that is not the enrolled custodian (or whose keys have
    /// rotated since enrollment, which makes the blob unopenable just the same).
    case notTheEnrolledCustodian
    /// No ceremony round is open on this side — nothing was scanned, or the round was already spent.
    case noRoundInProgress
    /// The challenge response did not prove possession of the displayed key.
    case challengeResponseRejected
    /// This device has no recovery material to recover from.
    case noRecoveryMaterial
    /// A sealed payload could not be opened, decoded, or had the wrong shape.
    case malformedPayload
    /// A payload's Ed25519 signature did not verify against the key it must have come from.
    case signatureRejected
    /// The custodian could not open the recovery blob — it was not sealed to this device, or its
    /// key-agreement key has rotated since enrollment.
    case recoveryBlobUnreadable
    /// The sealing/signing primitives failed (an unprovisioned or broken identity).
    case cryptoFailed
}

/// How a completed recovery ceremony ended.
enum DuressRecoveryOutcome: Equatable {
    /// The custodian returned the key and the local unlock was rebuilt under the new credential.
    case unlockReestablished
    /// The custodian refused and asked for destruction. The coordinator deliberately does NOT act
    /// on this: destroying the corpus is the app's own funnel plus `FernletLockService.reset()`, an
    /// explicit, user-visible act that belongs to the caller, not to a message from another device.
    case destructionRequested
}

/// What the custodian's UI shows its human before they answer a recovery request.
///
/// Carries no key material — the recovery blob is not opened until the human chooses
/// ``DuressRecoveryDecision/returnKey``, so a request that is refused is never even decrypted.
struct PendingRecoveryRequestSummary: Equatable, Sendable {
    /// The requesting device's 16-char identity fingerprint, for the human's eyes-on comparison.
    let requesterFingerprint: String
}

// MARK: - Coordinator

/// Drives both halves of the in-person `DuressMode.recoveryLock` ceremonies, on both devices.
///
/// One type, two roles, because one app is both: any Fernlet install can be somebody's custodian.
/// The **displayer** (always the custodian) shows a signed `fernlet://verify` QR and answers sealed
/// challenges; the **scanner** (always the primary) is the side that authenticates, because the
/// scanner is the side with something to lose — at enrollment it is about to seal its content key to
/// the scanned device, and at recovery it is about to install whatever that device hands back.
///
/// **Why not `CoachVerificationCeremony`.** That implementation binds its display to ONE named peer
/// signing key, known before the sheet opens. Custodian enrollment is a first meeting: the key is
/// *learned* from the QR, so there is nothing to bind to yet. This is therefore a third
/// implementation over the SAME wire primitives (`ProximityVerifyQR`, `VerifyChallengePayload`,
/// `VerifyResponsePayload`, `ProximityVerifySignature`) with the binding moved to where it can
/// exist: on the scanner side, against `FernletLockService.enrolledCustodianSigningPublicKey` at
/// recovery time. The display is bounded by ``clearDisplay()`` and the QR freshness window instead
/// of by single use — with no named peer there is nobody to spend the round *on*, and answering a
/// challenge only re-proves what the displayed QR already asserts in public.
///
/// **What actually authorizes a recovery**, in order of load-bearing-ness:
/// 1. The custodian can only open a blob genuinely sealed to it; a stranger's blob decrypts to
///    nothing.
/// 2. The reply is sealed to the SAME key-agreement public key that authenticated the blob — never
///    to a separately claimed one — so even a forwarded blob returns a key only the genuine primary
///    can read.
/// 3. The reply is SIGNED by the enrolled custodian. This is what stops anyone from sealing a
///    `.destroy` instruction to the primary's public key, which the seal alone would not.
/// 4. The primary refuses a key whose digest is not the one its blob seals
///    (`reestablishLocalUnlock`), so a wrong answer is a named error rather than a silent, permanent
///    re-lock around bytes that open nothing.
///
/// Transport-free by construction: every method returns the bytes to send and consumes the bytes
/// that arrived, exactly as `CoachVerificationCeremony` does, so the mesh wiring and the sheets
/// (P7 step 9) compose it without this type knowing what a radio is — and so the whole ceremony is
/// unit-testable by running two coordinators against each other.
///
/// **Audit names here are deliberately the NEUTRAL `mesh.verifyQR.*` family, not a `duressRecovery.*`
/// one.** `FernletAuditLog` sends the event NAME to the unified log with `.auto` privacy, where it
/// survives into a sysdiagnose — which is exactly why `FernletLockService.configureDuress` and
/// `enrollRecoveryCustodian` emit nothing at all: "this device enrolled a recovery custodian" is a
/// near-synonym for "this device has a duress PIN", the single fact the feature depends on hiding.
/// A ceremony that logged `duressRecovery.challengeSent` on the PROTECTED phone would hand that fact
/// straight back. These lines are structurally the same in-person QR mutual auth the mesh already
/// performs, so they log under the same names and the trail stays just as useful for debugging while
/// disclosing nothing.
///
/// `@MainActor`, like `IdentityService` and `FernletLockService`, both of which it holds directly.
@MainActor
final class DuressRecoveryCoordinator {

    /// Largest sealed hop this ceremony will even look at (R3/R5: framing declares its maximum and
    /// rejects oversize input up front). Every hop travels as a photographed QR code, and a QR
    /// carries at most 2,953 bytes; 4 KB leaves room for the base64url expansion of a legitimate
    /// payload while refusing anything a camera could not have produced.
    ///
    /// `nonisolated` because the QR carrier (`DuressCeremonyQR.parse`, itself nonisolated) states
    /// the same maximum: an immutable `Int` is safe to read from any isolation.
    nonisolated static let maxSealedHopBytes = 4_096

    /// The identity whose keys sign, seal, and open everything here. Injected so tests can point it
    /// at a throwaway keychain service, and so one process can host two coordinators (a "primary"
    /// and a "custodian") over separate identities.
    private let identity: IdentityService
    /// The lock that owns the recovery material and the local unlock this ceremony rebuilds.
    private let lockService: FernletLockService
    /// Clock seam for QR freshness, mirroring `CoachVerificationCeremony`.
    private let now: () -> Date

    /// Displayer side: the QR currently on screen. Not bound to a peer (see the type doc) — it is
    /// bound to being *displayed*, and `clearDisplay()` is what ends it.
    private var activeDisplay: (nonce: Data, issuedAt: Date)?
    /// Displayer side: the most recent challenge round this device answered, so an inbound recovery
    /// request can be pinned to a live ceremony rather than accepted cold.
    private var lastProvenRound: (challengeNonce: Data, scannerKeyAgreementPublicKey: Data)?
    /// Custodian side: a request opened and shown to the human, awaiting their answer. Holds the
    /// REQUEST, never the recovered key — the blob is opened only if they say yes.
    private var pendingRequest: (request: DuressRecoveryRequest, senderKeyAgreementPublicKey: Data)?
    /// Scanner side: the open round (one ceremony at a time, by construction — the user is holding
    /// two phones).
    private var pendingRound: (
        qrNonce: Data,
        challengeNonce: Data,
        peerSigningPublicKey: Data,
        peerKeyAgreementPublicKey: Data
    )?

    init(identity: IdentityService, lockService: FernletLockService, now: @escaping () -> Date = Date.init) {
        self.identity = identity
        self.lockService = lockService
        self.now = now
    }

    /// This device's X25519 key-agreement public key — the value the challenge hop must carry, and
    /// the one the peer's response signature covers.
    ///
    /// Exposed so the ceremony's transport (P7 step 9's QR relay) can put it on the wire without
    /// reaching past this type for the identity it deliberately owns. A public key: publishing it is
    /// what the identity QR already does.
    var localKeyAgreementPublicKey: Data { identity.localKeyAgreementPublicKey }

    // MARK: - Displayer side (the custodian device)

    /// The signed QR this device shows so the other phone can scan it.
    ///
    /// - Returns: The `fernlet://verify` URL to render, or nil when the identity is unprovisioned.
    func makeDisplayURL() -> URL? {
        guard (try? identity.ensureProvisioned()) != nil,
              let made = try? ProximityVerifyQR.makeURL(identity: identity, now: now()) else { return nil }
        activeDisplay = (nonce: made.nonce, issuedAt: now())
        return made.url
    }

    /// Ends the display half. The sheet's dismissal — not merely the QR's timestamp — is what makes
    /// a photographed code useless afterwards, so every dismissal path must reach here.
    func clearDisplay() {
        guard activeDisplay != nil else { return }
        activeDisplay = nil
        lastProvenRound = nil
        pendingRequest = nil
        FernletAuditLog.log("mesh.verifyQR.displayCleared")
    }

    /// Answers a sealed challenge quoting the QR currently on screen.
    ///
    /// Nothing is signed until the challenge is proved to quote the live display and to carry
    /// fixed-length fields — an unbounded signing oracle over the long-term identity key is exactly
    /// the defect the 2026-07-27 review round pulled out of the mesh ceremony.
    ///
    /// - Parameters:
    ///   - payload: The scanner's challenge.
    ///   - senderKeyAgreementPublicKey: The sender's KA key as the caller VERIFIED it (from the
    ///     signed envelope), never as claimed in the body.
    /// - Returns: The response to seal back, or nil when the challenge was dropped.
    func handleChallenge(
        _ payload: VerifyChallengePayload,
        senderKeyAgreementPublicKey: Data
    ) -> VerifyResponsePayload? {
        guard let active = activeDisplay, active.nonce == payload.qrNonce else {
            FernletAuditLog.log("mesh.verifyQR.staleChallengeDropped")
            return nil
        }
        // `abs` so a backwards clock jump cannot resurrect an expired display.
        guard abs(now().timeIntervalSince(active.issuedAt)) <= ProximityVerifyQR.freshnessWindow else {
            activeDisplay = nil
            FernletAuditLog.log("mesh.verifyQR.expiredChallengeDropped")
            return nil
        }
        guard ProximityVerifySignature.isWellFormedChallenge(
            payload, scannerKeyAgreementPublicKey: senderKeyAgreementPublicKey
        ) else {
            FernletAuditLog.log("mesh.verifyQR.malformedChallengeDropped")
            return nil
        }
        let message = ProximityVerifySignature.message(
            scannerKeyAgreementPublicKey: senderKeyAgreementPublicKey,
            challengeNonce: payload.challengeNonce,
            qrNonce: payload.qrNonce
        )
        guard let signature = try? identity.sign(message) else {
            FernletAuditLog.log("mesh.verifyQR.signFailed")
            return nil
        }
        lastProvenRound = (
            challengeNonce: payload.challengeNonce,
            scannerKeyAgreementPublicKey: senderKeyAgreementPublicKey
        )
        FernletAuditLog.log("mesh.verifyQR.responded")
        return VerifyResponsePayload(challengeNonce: payload.challengeNonce, signature: signature)
    }

    // MARK: - Scanner side: enrollment (the primary device)

    /// Step 1 of enrollment: the user scanned their other phone's code.
    ///
    /// Validates the QR's signature and freshness, refuses this device's own code, and opens a
    /// challenge round. Nothing is written and no key is touched — enrollment only becomes durable
    /// in ``completeCustodianEnrollment(response:senderSigningPublicKey:passcode:)``.
    ///
    /// - Returns: The challenge to seal to the scanned device's key-agreement key and send.
    func beginCustodianEnrollment(scannedURL: URL) throws -> VerifyChallengePayload {
        try ensureIdentity()
        guard let payload = ProximityVerifyQR.parse(scannedURL),
              ProximityVerifyQR.isValid(payload, at: now()) else {
            FernletAuditLog.log("mesh.verifyQR.invalidScanned")
            throw DuressRecoveryError.invalidQRCode
        }
        // A device cannot be its own custodian: `recoveryLock` destroys this device's unlock keys,
        // and if the blob were sealed to this device's own key-agreement key it would be sealed to
        // a key that survives the destruction — which is not a recovery ceremony, it is a second
        // copy of the content key sitting on the coerced phone.
        guard payload.signingPublicKey != identity.localSigningPublicKey,
              payload.keyAgreementPublicKey != identity.localKeyAgreementPublicKey else {
            FernletAuditLog.log("mesh.verifyQR.selfPeerRefused")
            throw DuressRecoveryError.selfEnrollmentRefused
        }
        return openRound(with: payload)
    }

    /// Step 2 of enrollment: the custodian's sealed response arrived.
    ///
    /// Verifies key possession, then seals the content key to the proven key-agreement key and
    /// persists the enrollment — through `FernletLockService`, which releases the key into the
    /// sealing closure and never returns it here.
    ///
    /// - Parameters:
    ///   - response: The custodian's sealed challenge response.
    ///   - senderSigningPublicKey: The sender's signing key as the caller VERIFIED it.
    ///   - passcode: The user's REAL passcode. The lock compares it against the duress verifier
    ///     first, so a coerced enrollment seals nothing — the one entry point where honoring a
    ///     duress PIN would EXPORT the content key rather than merely show a decoy.
    func completeCustodianEnrollment(
        response: VerifyResponsePayload,
        senderSigningPublicKey: Data,
        passcode: String
    ) async throws {
        let round = try consumeProvenRound(response: response, senderSigningPublicKey: senderSigningPublicKey)
        let custodianKeyAgreementPublicKey = round.peerKeyAgreementPublicKey
        try await lockService.enrollRecoveryCustodian(
            passcode: passcode,
            signingPublicKey: round.peerSigningPublicKey,
            keyAgreementPublicKey: custodianKeyAgreementPublicKey,
            // THIS device's sender key, recorded with the enrollment. `seal` binds the blob to it
            // (HKDF `sharedInfo` + AEAD additional data) and the custodian opens with the live,
            // ceremony-proven sender key — so the blob dies the moment this identity rotates, which
            // an ordinary "Delete everything" does. Recording it is what lets
            // `reconcileEnrollmentWithLocalIdentity()` notice and retire the dead enrollment.
            ownKeyAgreementPublicKey: identity.localKeyAgreementPublicKey
        ) { contentKey in
            try identity.seal(contentKey, to: custodianKeyAgreementPublicKey, format: .wire2)
        }
    }

    /// Retires a recovery enrollment that this device's proximity identity has outlived.
    ///
    /// **Call this at launch and after anything that can rotate the identity** — chiefly the
    /// "Delete everything" funnel, which wipes `com.fernlet.identity` while deliberately keeping the
    /// app-lock keychain, the content key, and these recovery rows. After that rotation the sealed
    /// blob is openable by nobody: the custodian opens it with the sender's LIVE key-agreement key,
    /// and the key it was sealed under no longer exists anywhere. Left alone, the lock would keep
    /// `DuressMode.recoveryLock` armed over it and firing it would destroy every local unlock key
    /// for a ceremony that can only end in `recoveryBlobUnreadable` — a permanent, unannounced
    /// lock-out out of an ordinary in-app action.
    ///
    /// The comparison lives HERE, not in `FernletLock`, for the same reason the ceremony does: that
    /// module has no ProximityKit edge, so it stores the enrollment-time public key and this side
    /// supplies the live one.
    ///
    /// Conservative in the only direction that matters: an unprovisioned or unreadable identity
    /// retires NOTHING (an enrollment is never thrown away on a failed read), and a matching key is
    /// a no-op.
    ///
    /// - Returns: `true` when an enrollment was retired.
    func reconcileEnrollmentWithLocalIdentity() -> Bool {
        guard let enrolledOwnerKey = lockService.enrolledRecoveryOwnerKeyAgreementPublicKey else { return false }
        guard (try? identity.ensureProvisioned()) != nil else { return false }
        let liveOwnerKey = identity.localKeyAgreementPublicKey
        guard !liveOwnerKey.isEmpty, liveOwnerKey != enrolledOwnerKey else { return false }
        return lockService.invalidateRecoveryCustodianForRotatedIdentity()
    }

    // MARK: - Scanner side: recovery (the primary device)

    /// Step 1 of recovery: the user scanned their custodian phone's code.
    ///
    /// Requires the scanned device to be exactly the enrolled custodian — BOTH keys. The
    /// key-agreement half matters as much as the signing half: a custodian whose KA key has rotated
    /// cannot open the blob at all, and finding that out here is a legible refusal rather than a
    /// ceremony that runs to the end and returns nothing.
    func beginRecovery(scannedURL: URL) throws -> VerifyChallengePayload {
        try ensureIdentity()
        guard lockService.hasRecoveryCustodian,
              let enrolledSigning = lockService.enrolledCustodianSigningPublicKey,
              let enrolledKeyAgreement = lockService.enrolledCustodianKeyAgreementPublicKey else {
            throw DuressRecoveryError.noRecoveryMaterial
        }
        guard let payload = ProximityVerifyQR.parse(scannedURL),
              ProximityVerifyQR.isValid(payload, at: now()) else {
            FernletAuditLog.log("mesh.verifyQR.invalidScanned")
            throw DuressRecoveryError.invalidQRCode
        }
        guard payload.signingPublicKey == enrolledSigning,
              payload.keyAgreementPublicKey == enrolledKeyAgreement else {
            FernletAuditLog.log("mesh.verifyQR.qrPeerMismatch")
            throw DuressRecoveryError.notTheEnrolledCustodian
        }
        return openRound(with: payload)
    }

    /// Step 2 of recovery: the custodian proved itself, so send it the blob.
    ///
    /// - Returns: The sealed request bytes to transmit.
    func makeRecoveryRequest(
        response: VerifyResponsePayload,
        senderSigningPublicKey: Data
    ) throws -> Data {
        guard let blob = lockService.custodianRecoveryBlob else {
            throw DuressRecoveryError.noRecoveryMaterial
        }
        // Deliberately does NOT consume the round: the reply still has to be matched against this
        // ceremony's challenge nonce, and burning it here would leave nothing to match against.
        let round = try provenRound(response: response, senderSigningPublicKey: senderSigningPublicKey)
        let transcript = DuressRecoveryTranscript.request(
            challengeNonce: round.challengeNonce,
            requesterSigningPublicKey: identity.localSigningPublicKey,
            requesterKeyAgreementPublicKey: identity.localKeyAgreementPublicKey,
            custodianSigningPublicKey: round.peerSigningPublicKey,
            custodianKeyAgreementPublicKey: round.peerKeyAgreementPublicKey,
            recoveryBlob: blob
        )
        guard let signature = try? identity.sign(transcript) else {
            throw DuressRecoveryError.cryptoFailed
        }
        let request = DuressRecoveryRequest(
            version: 1,
            challengeNonce: round.challengeNonce,
            requesterSigningPublicKey: identity.localSigningPublicKey,
            requesterKeyAgreementPublicKey: identity.localKeyAgreementPublicKey,
            recoveryBlob: blob,
            signature: signature
        )
        guard let encoded = try? JSONEncoder().encode(request),
              let sealed = try? identity.seal(encoded, to: round.peerKeyAgreementPublicKey, format: .wire2) else {
            throw DuressRecoveryError.cryptoFailed
        }
        FernletAuditLog.log("mesh.verifyQR.sealedPayloadSent")
        return sealed
    }

    /// Step 3 of recovery: the custodian's sealed reply arrived.
    ///
    /// Opens it from the ENROLLED custodian's key-agreement key, verifies the signature against the
    /// enrolled signing key and this ceremony's round, and — on
    /// ``DuressRecoveryDecision/returnKey`` — rebuilds the local unlock under `credential`. The lock
    /// refuses a key that is not the one the blob seals, so a wrong answer cannot re-lock the device
    /// around bytes that open nothing.
    ///
    /// - Returns: What the custodian decided. ``DuressRecoveryOutcome/destructionRequested`` is
    ///   reported, never acted on: destroying the corpus belongs to the app's own explicit,
    ///   user-visible delete path, not to a message from another phone.
    func completeRecovery(
        sealedReply: Data,
        credential: FernletLockCredential,
        grantingScope: FernletLockScope
    ) async throws -> DuressRecoveryOutcome {
        guard sealedReply.count <= Self.maxSealedHopBytes else {
            FernletAuditLog.log("mesh.verifyQR.oversizePayloadDropped", context: ["hop": "reply"])
            throw DuressRecoveryError.malformedPayload
        }
        guard let round = pendingRound else { throw DuressRecoveryError.noRoundInProgress }
        guard let enrolledSigning = lockService.enrolledCustodianSigningPublicKey,
              let enrolledKeyAgreement = lockService.enrolledCustodianKeyAgreementPublicKey else {
            throw DuressRecoveryError.noRecoveryMaterial
        }
        // Format-check the NEW credential here, before the round is spent. `reestablishLocalUnlock`
        // validates it too — but it does so after this method has cleared `pendingRound` and after
        // the custodian has already consumed its `pendingRequest`, so a five-digit "4-digit PIN" or
        // an empty field used to throw into a dead end: the re-shown step could only raise
        // `.noRoundInProgress`, and both phones had to redo every QR hop. Refusing before anything
        // is consumed keeps this method's own invariant — every refusal happens before anything
        // durable — true for the one input the human types.
        try credential.validate()
        // Opened from the ENROLLED key, not from the round's — they are equal by `beginRecovery`'s
        // gate, and naming the enrolled one here makes that a property of the code rather than of
        // the call order.
        // A rejected reply deliberately does NOT clear `pendingRound`: burning the round on
        // somebody else's garbage is exactly how a racing third party would deny the genuine
        // custodian their answer (the rule carried forward from the 2026-07-25 mesh review).
        guard let plaintext = try? identity.open(sealedReply, from: enrolledKeyAgreement, format: .wire2),
              let reply = try? JSONDecoder().decode(DuressRecoveryReply.self, from: plaintext),
              reply.version == 1,
              reply.challengeNonce == round.challengeNonce else {
            FernletAuditLog.log("mesh.verifyQR.malformedReplyDropped")
            throw DuressRecoveryError.malformedPayload
        }
        let transcript = DuressRecoveryTranscript.reply(
            challengeNonce: reply.challengeNonce,
            custodianSigningPublicKey: enrolledSigning,
            custodianKeyAgreementPublicKey: enrolledKeyAgreement,
            requesterKeyAgreementPublicKey: identity.localKeyAgreementPublicKey,
            decision: reply.decision,
            contentKey: reply.contentKey
        )
        guard IdentityService.verify(reply.signature, of: transcript, by: enrolledSigning) else {
            FernletAuditLog.log("mesh.verifyQR.badReplySignature")
            throw DuressRecoveryError.signatureRejected
        }
        pendingRound = nil
        switch reply.decision {
        case .destroy:
            FernletAuditLog.log("mesh.verifyQR.peerDeclined")
            return .destructionRequested
        case .returnKey:
            try await lockService.reestablishLocalUnlock(
                contentKey: reply.contentKey,
                credential: credential,
                grantingScope: grantingScope
            )
            return .unlockReestablished
        }
    }

    // MARK: - Custodian side: answering a recovery request

    /// A sealed recovery request arrived. Validates it and holds it for the human's answer.
    ///
    /// The recovery blob is NOT opened here. A request the human refuses is never decrypted at all,
    /// which keeps "I said no" and "I never had the key in memory" the same statement.
    ///
    /// - Parameters:
    ///   - sealed: The sealed request bytes.
    ///   - senderKeyAgreementPublicKey: The sender's KA key as the caller VERIFIED it. This — never
    ///     the key inside the body — is what opens the payload and, later, the blob.
    /// - Returns: What to show the human before they answer.
    func openRecoveryRequest(
        _ sealed: Data,
        from senderKeyAgreementPublicKey: Data
    ) throws -> PendingRecoveryRequestSummary {
        guard sealed.count <= Self.maxSealedHopBytes else {
            FernletAuditLog.log("mesh.verifyQR.oversizePayloadDropped", context: ["hop": "request"])
            throw DuressRecoveryError.malformedPayload
        }
        try ensureIdentity()
        // Pinned to a live round: this device must have answered this exact challenge, from this
        // exact scanner, moments ago. A request arriving cold — or quoting an old round — is a
        // replay, and the custodian is the one device that must never be a decrypt-on-demand
        // service for a blob someone else is holding.
        guard let proven = lastProvenRound,
              proven.scannerKeyAgreementPublicKey == senderKeyAgreementPublicKey else {
            FernletAuditLog.log("mesh.verifyQR.unboundPayloadDropped")
            throw DuressRecoveryError.noRoundInProgress
        }
        guard let plaintext = try? identity.open(sealed, from: senderKeyAgreementPublicKey, format: .wire2),
              let request = try? JSONDecoder().decode(DuressRecoveryRequest.self, from: plaintext),
              request.version == 1,
              request.challengeNonce == proven.challengeNonce,
              !request.recoveryBlob.isEmpty,
              DuressRecoveryTranscript.isWellFormed(
                  challengeNonce: request.challengeNonce,
                  signingPublicKey: request.requesterSigningPublicKey,
                  keyAgreementPublicKey: request.requesterKeyAgreementPublicKey
              ) else {
            FernletAuditLog.log("mesh.verifyQR.malformedPayloadDropped")
            throw DuressRecoveryError.malformedPayload
        }
        let transcript = DuressRecoveryTranscript.request(
            challengeNonce: request.challengeNonce,
            requesterSigningPublicKey: request.requesterSigningPublicKey,
            requesterKeyAgreementPublicKey: request.requesterKeyAgreementPublicKey,
            custodianSigningPublicKey: identity.localSigningPublicKey,
            custodianKeyAgreementPublicKey: identity.localKeyAgreementPublicKey,
            recoveryBlob: request.recoveryBlob
        )
        guard IdentityService.verify(request.signature, of: transcript, by: request.requesterSigningPublicKey) else {
            FernletAuditLog.log("mesh.verifyQR.badPayloadSignature")
            throw DuressRecoveryError.signatureRejected
        }
        pendingRequest = (request: request, senderKeyAgreementPublicKey: senderKeyAgreementPublicKey)
        return PendingRecoveryRequestSummary(
            requesterFingerprint: IdentityService.fingerprint(of: request.requesterSigningPublicKey)
        )
    }

    /// The human answered. Produces the sealed reply.
    ///
    /// For ``DuressRecoveryDecision/returnKey`` the blob is opened HERE, with the key-agreement key
    /// the ceremony proved, and the recovered bytes are re-sealed to that SAME key. Sealing to the
    /// key that authenticated the blob — rather than to any key the request claimed — is what makes
    /// a forwarded blob useless: the answer comes back readable only by the device that sealed it.
    ///
    /// - Returns: The sealed reply bytes to transmit.
    func answerPendingRecoveryRequest(_ decision: DuressRecoveryDecision) throws -> Data {
        guard let pending = pendingRequest else { throw DuressRecoveryError.noRoundInProgress }
        pendingRequest = nil
        let recipientKeyAgreementPublicKey = pending.senderKeyAgreementPublicKey
        var contentKey = Data()
        if decision == .returnKey {
            guard let opened = try? identity.open(
                pending.request.recoveryBlob,
                from: recipientKeyAgreementPublicKey,
                format: .wire2
            ), !opened.isEmpty else {
                FernletAuditLog.log("mesh.verifyQR.sealedPayloadUnreadable")
                throw DuressRecoveryError.recoveryBlobUnreadable
            }
            contentKey = opened
        }
        let transcript = DuressRecoveryTranscript.reply(
            challengeNonce: pending.request.challengeNonce,
            custodianSigningPublicKey: identity.localSigningPublicKey,
            custodianKeyAgreementPublicKey: identity.localKeyAgreementPublicKey,
            requesterKeyAgreementPublicKey: recipientKeyAgreementPublicKey,
            decision: decision,
            contentKey: contentKey
        )
        guard let signature = try? identity.sign(transcript) else {
            throw DuressRecoveryError.cryptoFailed
        }
        let reply = DuressRecoveryReply(
            version: 1,
            challengeNonce: pending.request.challengeNonce,
            decision: decision,
            contentKey: contentKey,
            signature: signature
        )
        guard let encoded = try? JSONEncoder().encode(reply),
              let sealed = try? identity.seal(encoded, to: recipientKeyAgreementPublicKey, format: .wire2) else {
            throw DuressRecoveryError.cryptoFailed
        }
        FernletAuditLog.log("mesh.verifyQR.sealedReplySent", context: ["decision": "\(decision.rawValue)"])
        return sealed
    }

    // MARK: - Shared scanner plumbing

    /// Provisions the identity or refuses; every entry point runs this first so a missing key pair
    /// is one named error rather than a nil deep inside a seal.
    private func ensureIdentity() throws {
        guard (try? identity.ensureProvisioned()) != nil,
              identity.localSigningPublicKey.count == DuressRecoveryTranscript.publicKeyByteCount,
              identity.localKeyAgreementPublicKey.count == DuressRecoveryTranscript.publicKeyByteCount else {
            throw DuressRecoveryError.identityUnavailable
        }
    }

    /// Mints the challenge for a validated QR and records the round.
    private func openRound(with payload: ProximityVerifyQR.Payload) -> VerifyChallengePayload {
        let challengeNonce = Data(
            (0..<DuressRecoveryTranscript.nonceByteCount).map { _ in UInt8.random(in: .min ... .max) }
        )
        pendingRound = (
            qrNonce: payload.nonce,
            challengeNonce: challengeNonce,
            peerSigningPublicKey: payload.signingPublicKey,
            peerKeyAgreementPublicKey: payload.keyAgreementPublicKey
        )
        FernletAuditLog.log("mesh.verifyQR.challengeSent")
        return VerifyChallengePayload(qrNonce: payload.nonce, challengeNonce: challengeNonce)
    }

    /// Verifies a challenge response against the open round WITHOUT spending it.
    private func provenRound(
        response: VerifyResponsePayload,
        senderSigningPublicKey: Data
    ) throws -> (
        qrNonce: Data,
        challengeNonce: Data,
        peerSigningPublicKey: Data,
        peerKeyAgreementPublicKey: Data
    ) {
        guard let round = pendingRound else { throw DuressRecoveryError.noRoundInProgress }
        guard response.challengeNonce == round.challengeNonce,
              senderSigningPublicKey == round.peerSigningPublicKey else {
            FernletAuditLog.log("mesh.verifyQR.unexpectedResponseDropped")
            throw DuressRecoveryError.challengeResponseRejected
        }
        let message = ProximityVerifySignature.message(
            scannerKeyAgreementPublicKey: identity.localKeyAgreementPublicKey,
            challengeNonce: round.challengeNonce,
            qrNonce: round.qrNonce
        )
        guard IdentityService.verify(response.signature, of: message, by: round.peerSigningPublicKey) else {
            pendingRound = nil
            FernletAuditLog.log("mesh.verifyQR.badResponseSignature")
            throw DuressRecoveryError.challengeResponseRejected
        }
        FernletAuditLog.log("mesh.verifyQR.proven")
        return round
    }

    /// Verifies a challenge response and SPENDS the round — for enrollment, which ends at this step.
    private func consumeProvenRound(
        response: VerifyResponsePayload,
        senderSigningPublicKey: Data
    ) throws -> (
        qrNonce: Data,
        challengeNonce: Data,
        peerSigningPublicKey: Data,
        peerKeyAgreementPublicKey: Data
    ) {
        let round = try provenRound(response: response, senderSigningPublicKey: senderSigningPublicKey)
        pendingRound = nil
        return round
    }
}
