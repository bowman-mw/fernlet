// ProximityVerificationTests.swift
// FernletTests
//
// QR verification ceremony (bitchat adoptions Increment 4): the signed verify-QR URL round trip,
// freshness + tamper rejection, base64url edge cases, the challenge/response transcript
// signature, AND the manager-side ceremony state machine (slot binding, single use, expiry,
// dismissal, and the commits on both halves). UUID-scoped keychain per IdentityServiceTests
// convention.

import Foundation
import Testing
import CryptoKit
import FernletCrypto
import MultipeerConnectivity
@testable import ProximityKit
import FernletDomainModel
import FernletFoundation
@testable import Fernlet

@MainActor
@Suite(.serialized)
struct ProximityVerificationTests {

    // Strong reference for the whole test: `MeshNetworkManager` holds the store `unowned`.
    let store = makeTestStore()

    private func makeIdentity() throws -> (IdentityService, String) {
        let serviceID = "com.fernlet.identity.test.\(UUID().uuidString)"
        let service = IdentityService(keychainService: serviceID)
        try service.ensureProvisioned()
        return (service, serviceID)
    }

    @Test func verifyQRRoundTripsAndValidates() throws {
        let (identity, serviceID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: serviceID) }

        let made = try ProximityVerifyQR.makeURL(identity: identity)
        #expect(made.url.scheme == "fernlet")
        #expect(made.nonce.count == 16)

        let parsed = try #require(ProximityVerifyQR.parse(made.url))
        #expect(parsed.signingPublicKey == identity.localSigningPublicKey)
        #expect(parsed.keyAgreementPublicKey == identity.localKeyAgreementPublicKey)
        #expect(parsed.nonce == made.nonce)
        #expect(ProximityVerifyQR.isValid(parsed))
    }

    @Test func verifyQRRejectsTamperStalenessAndForeignURLs() throws {
        let (identity, serviceID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: serviceID) }
        let made = try ProximityVerifyQR.makeURL(identity: identity)
        let parsed = try #require(ProximityVerifyQR.parse(made.url))

        // Stale: outside the ±5 min freshness window in either direction.
        let past = Date(timeIntervalSince1970: TimeInterval(parsed.timestamp) + ProximityVerifyQR.freshnessWindow + 60)
        #expect(!ProximityVerifyQR.isValid(parsed, at: past))
        let future = Date(timeIntervalSince1970: TimeInterval(parsed.timestamp) - ProximityVerifyQR.freshnessWindow - 60)
        #expect(!ProximityVerifyQR.isValid(parsed, at: future))

        // Tamper: a swapped key agreement key breaks the signature.
        let (mallory, malloryID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: malloryID) }
        let swapped = ProximityVerifyQR.Payload(
            version: parsed.version,
            signingPublicKey: parsed.signingPublicKey,
            keyAgreementPublicKey: mallory.localKeyAgreementPublicKey,
            timestamp: parsed.timestamp,
            nonce: parsed.nonce,
            signature: parsed.signature
        )
        #expect(!ProximityVerifyQR.isValid(swapped))

        // Foreign URLs never parse.
        #expect(ProximityVerifyQR.parse(URL(string: "https://example.com/verify?d=abc")!) == nil)
        #expect(ProximityVerifyQR.parse(URL(string: "fernlet://other?d=abc")!) == nil)
    }

    @Test func base64URLSurvivesPaddingVariants() {
        for length in 1...8 {
            let data = Data((0..<length).map { UInt8($0 * 37 % 251) })
            let encoded = ProximityVerifyQR.base64URLEncode(data)
            #expect(!encoded.contains("="), "base64url must be unpadded")
            #expect(ProximityVerifyQR.base64URLDecode(encoded) == data)
        }
    }

    @Test func responseTranscriptSignatureBindsScannerAndNonces() throws {
        let (displayer, displayerID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: displayerID) }
        let (scanner, scannerID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: scannerID) }

        let qrNonce = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        let challengeNonce = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })

        let message = ProximityVerifySignature.message(
            scannerKeyAgreementPublicKey: scanner.localKeyAgreementPublicKey,
            challengeNonce: challengeNonce,
            qrNonce: qrNonce
        )
        let purpose = FernletCryptoPurpose.Signature.proximityQRResponseV1
        let signature = try displayer.sign(message, purpose: purpose)
        #expect(IdentityService.verify(signature, of: message, by: displayer.localSigningPublicKey, purpose: purpose))

        // Any transcript substitution breaks it: different scanner, nonce, or signer.
        let otherScannerMessage = ProximityVerifySignature.message(
            scannerKeyAgreementPublicKey: displayer.localKeyAgreementPublicKey,
            challengeNonce: challengeNonce,
            qrNonce: qrNonce
        )
        #expect(!IdentityService.verify(signature, of: otherScannerMessage, by: displayer.localSigningPublicKey, purpose: purpose))
        let otherNonceMessage = ProximityVerifySignature.message(
            scannerKeyAgreementPublicKey: scanner.localKeyAgreementPublicKey,
            challengeNonce: qrNonce,
            qrNonce: challengeNonce
        )
        #expect(!IdentityService.verify(signature, of: otherNonceMessage, by: displayer.localSigningPublicKey, purpose: purpose))
        #expect(!IdentityService.verify(signature, of: message, by: scanner.localSigningPublicKey, purpose: purpose))
    }

    // MARK: - Ceremony state machine (MeshNetworkManager)

    /// Drives a real coordinator to the non-UWB `.awaitingManualCommit` gate for `remote`'s
    /// identity and registers it on `manager` as the pre-commit slot the ceremony upgrades.
    /// Non-UWB is reached honestly (ranging hardware unsupported → `.rssi` → manual gate) rather
    /// than by poking coordinator state, which has no test seam.
    private func makeAwaitingManualCommitSlot(
        on manager: MeshNetworkManager,
        localIdentity: IdentityService,
        remote: IdentityService,
        name: String
    ) async throws -> (coordinator: ProximityCoordinator, peer: MultipeerPeer) {
        let transport = MockMultipeerTransport()
        let coordinator = ProximityCoordinator(
            identity: localIdentity,
            transport: transport,
            ranging: MockRangingProvider(isHardwareSupported: false),
            inspector: nil,
            replayCache: ReplayCache(),
            foregroundAnchor: nil,
            displayName: "Local",
            timeoutSeconds: 0
        )
        let peer = MultipeerPeer(
            id: UUID(),
            displayName: name,
            discoveryInfo: nil,
            advertisedFingerprint: nil,
            underlying: MCPeerID(displayName: name)
        )
        await coordinator.begin(role: .browser, mode: .friend)
        transport.simulateConnected(peer: peer)
        try await Task.sleep(nanoseconds: 10_000_000)
        let introduction = try FernletIdentityEnvelope.signed(
            identityService: remote,
            senderDisplayName: name,
            payloadType: .identityIntroduction,
            payloadSummary: PayloadSummary(title: "Hello from \(name)"),
            payload: Data()
        )
        transport.simulateInboundData(try JSONEncoder().encode(introduction), from: peer)
        try await Task.sleep(nanoseconds: 10_000_000)
        guard case .awaitingManualCommit = coordinator.state else {
            Issue.record("Expected \(name) at the manual-commit gate, got \(coordinator.state)")
            throw CancellationError()
        }
        // fingerprint nil = pre-commit slot: the ceremony deliberately runs before slot commit.
        manager.addSlotForTesting(coordinator: coordinator, peer: peer, fingerprint: nil)
        return (coordinator, peer)
    }

    private func inboundCeremonyEnvelope(
        _ type: PayloadType,
        from sender: IdentityService,
        plaintext: Data
    ) -> FernletIdentityEnvelope {
        // The dispatch entry point takes already-verified, already-unsealed envelopes, so the
        // signature/ciphertext fields are inert here — the sender key fields are not: the
        // ceremony seals its reply to `senderKeyAgreementPublicKey` and binds it into the
        // transcript.
        FernletIdentityEnvelope(
            schemaVersion: FernletIdentityEnvelope.currentSchemaVersion,
            envelopeID: UUID(),
            senderSigningPublicKey: sender.localSigningPublicKey,
            senderKeyAgreementPublicKey: sender.localKeyAgreementPublicKey,
            senderDisplayName: "Peer",
            recipientFingerprint: nil,
            payloadType: type,
            payloadEncryption: .none,
            payloadSummary: PayloadSummary(title: type.rawValue),
            payload: plaintext,
            createdAt: Date(),
            expiresAt: nil,
            signature: Data()
        )
    }

    private func deliverChallenge(
        to manager: MeshNetworkManager,
        on coordinator: ProximityCoordinator,
        from sender: IdentityService,
        qrNonce: Data,
        challengeNonce: Data = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
    ) throws {
        let plaintext = try JSONEncoder().encode(
            VerifyChallengePayload(qrNonce: qrNonce, challengeNonce: challengeNonce)
        )
        let envelope = inboundCeremonyEnvelope(.verifyChallenge, from: sender, plaintext: plaintext)
        manager.proximityCoordinator(coordinator, didReceive: envelope, plaintext: plaintext, from: nil)
    }

    private func isCommitted(_ coordinator: ProximityCoordinator) -> Bool {
        if case .connected = coordinator.state { return true }
        return false
    }

    /// The commit hops through a `Task`, so a positive assertion polls and a negative one has to
    /// give that task a chance to run before concluding nothing happened.
    ///
    /// Gives up only once the deadline has passed AND `minimumPolls` observations have really been
    /// made. "Give that task a chance to run" is exactly what a `ContinuousClock` deadline alone
    /// fails to guarantee: it measures wall clock, which keeps advancing while this `@MainActor`
    /// suite is starved in a loaded full-suite run, so it can expire having genuinely looked only
    /// a handful of times — and the negative assertions then pass for the wrong reason. Counting
    /// observations ties the decision to scheduling received rather than to time elapsed, and
    /// still terminates: `polls` only climbs, and every turn of the loop sleeps.
    private func waitForCommit(
        _ coordinator: ProximityCoordinator,
        timeout: Duration = .seconds(1),
        minimumPolls: Int = 200
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var polls = 0
        while !isCommitted(coordinator) {
            polls += 1
            if polls >= minimumPolls, clock.now >= deadline { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(150))
    }

    /// FIX 1 regression: the displayed QR is bound to the row it was opened from. A third peer who
    /// can see the screen may scan the code and answer first — it must not be committed, and
    /// critically must not burn the single-use nonce the named peer still needs.
    @Test func ceremonyCommitsOnlyTheSlotTheQRWasOpenedFor() async throws {
        let (local, localID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: localID) }
        let (bob, bobID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: bobID) }
        let (mallory, malloryID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: malloryID) }
        let capture = CeremonyAuditCapture()
        capture.install()
        defer { capture.uninstall() }

        let manager = MeshNetworkManager(store: store)
        let bobSlot = try await makeAwaitingManualCommitSlot(on: manager, localIdentity: local, remote: bob, name: "Bob")
        let mallorySlot = try await makeAwaitingManualCommitSlot(on: manager, localIdentity: local, remote: mallory, name: "Mallory")

        // "Verify with Bob" — the sheet opened from Bob's row.
        let url = try #require(manager.makeLocalVerifyQRURL(slotID: bobSlot.peer.id))
        let qrNonce = try #require(ProximityVerifyQR.parse(url)?.nonce)

        try deliverChallenge(to: manager, on: mallorySlot.coordinator, from: mallory, qrNonce: qrNonce)
        await settle()
        #expect(!isCommitted(mallorySlot.coordinator),
                "A challenge from a peer other than the one the QR was shown to must never commit")
        #expect(capture.contains("mesh.verifyQR.wrongSlotChallengeDropped"))

        // The racer must not have consumed the round: Bob's genuine challenge still works.
        try deliverChallenge(to: manager, on: bobSlot.coordinator, from: bob, qrNonce: qrNonce)
        await waitForCommit(bobSlot.coordinator)
        #expect(isCommitted(bobSlot.coordinator), "The named peer's own challenge must still commit")
        #expect(!isCommitted(mallorySlot.coordinator))
    }

    /// FIX 2 regression: dismissing the sheet ends the ceremony — a photographed QR is dead even
    /// inside its own freshness window.
    @Test func dismissingTheDisplaySheetKillsTheRound() async throws {
        let (local, localID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: localID) }
        let (bob, bobID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: bobID) }
        let capture = CeremonyAuditCapture()
        capture.install()
        defer { capture.uninstall() }

        let manager = MeshNetworkManager(store: store)
        let bobSlot = try await makeAwaitingManualCommitSlot(on: manager, localIdentity: local, remote: bob, name: "Bob")
        let url = try #require(manager.makeLocalVerifyQRURL(slotID: bobSlot.peer.id))
        let qrNonce = try #require(ProximityVerifyQR.parse(url)?.nonce)

        manager.clearActiveVerifyQR()
        try deliverChallenge(to: manager, on: bobSlot.coordinator, from: bob, qrNonce: qrNonce)
        await settle()

        #expect(!isCommitted(bobSlot.coordinator))
        #expect(capture.contains("mesh.verifyQR.staleChallengeDropped"))
    }

    /// FIX 2 regression: the displayer expires the round itself. The QR's own timestamp only
    /// bounds what an honest scanner accepts; a hostile one simply ignores it.
    @Test func displayerExpiresItsOwnQRAfterTheFreshnessWindow() async throws {
        let (local, localID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: localID) }
        let (bob, bobID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: bobID) }
        let capture = CeremonyAuditCapture()
        capture.install()
        defer { capture.uninstall() }

        let manager = MeshNetworkManager(store: store)
        let bobSlot = try await makeAwaitingManualCommitSlot(on: manager, localIdentity: local, remote: bob, name: "Bob")
        let url = try #require(manager.makeLocalVerifyQRURL(slotID: bobSlot.peer.id))
        let qrNonce = try #require(ProximityVerifyQR.parse(url)?.nonce)

        manager.backdateActiveVerifyQRForTesting(by: ProximityVerifyQR.freshnessWindow + 60)
        try deliverChallenge(to: manager, on: bobSlot.coordinator, from: bob, qrNonce: qrNonce)
        await settle()

        #expect(!isCommitted(bobSlot.coordinator))
        #expect(capture.contains("mesh.verifyQR.expiredChallengeDropped"))
    }

    /// The displayed nonce is single use: a replayed challenge is dropped, and the displayer
    /// signs (and commits) exactly once per shown QR.
    @Test func replayedChallengeIsDroppedAfterTheRoundIsSpent() async throws {
        let (local, localID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: localID) }
        let (bob, bobID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: bobID) }
        let capture = CeremonyAuditCapture()
        capture.install()
        defer { capture.uninstall() }

        let manager = MeshNetworkManager(store: store)
        let bobSlot = try await makeAwaitingManualCommitSlot(on: manager, localIdentity: local, remote: bob, name: "Bob")
        let url = try #require(manager.makeLocalVerifyQRURL(slotID: bobSlot.peer.id))
        let qrNonce = try #require(ProximityVerifyQR.parse(url)?.nonce)
        let challengeNonce = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })

        try deliverChallenge(to: manager, on: bobSlot.coordinator, from: bob,
                             qrNonce: qrNonce, challengeNonce: challengeNonce)
        await waitForCommit(bobSlot.coordinator)
        #expect(isCommitted(bobSlot.coordinator))

        try deliverChallenge(to: manager, on: bobSlot.coordinator, from: bob,
                             qrNonce: qrNonce, challengeNonce: challengeNonce)
        await settle()

        #expect(capture.count("mesh.verifyQR.displayerCommitted") == 1,
                "The QR is single use — a replayed challenge must not re-run the round")
        #expect(capture.contains("mesh.verifyQR.staleChallengeDropped"))
    }

    /// L22, scanner-side counterpart to `ceremonyCommitsOnlyTheSlotTheQRWasOpenedFor`: the SCAN is
    /// bound to the row the sheet was opened from, exactly as the DISPLAY already is. A code that
    /// is perfectly valid but belongs to a different nearby peer is refused, not searched for —
    /// otherwise "verify the person in front of you" degrades to "verify whoever is nearby".
    ///
    /// The `== false` assertion is the load-bearing one: it is what makes the row's "That code
    /// didn't match" alert reachable.
    @Test func scanningADifferentPeersCodeFromThisRowIsRefused() async throws {
        let (local, localID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: localID) }
        let (bob, bobID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: bobID) }
        let (mallory, malloryID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: malloryID) }
        let capture = CeremonyAuditCapture()
        capture.install()
        defer { capture.uninstall() }

        let manager = MeshNetworkManager(store: store)
        let bobSlot = try await makeAwaitingManualCommitSlot(on: manager, localIdentity: local, remote: bob, name: "Bob")
        let mallorySlot = try await makeAwaitingManualCommitSlot(on: manager, localIdentity: local, remote: mallory, name: "Mallory")

        // The sheet was opened from BOB's row; the code scanned is MALLORY's.
        let malloryQR = try ProximityVerifyQR.makeURL(identity: mallory)
        #expect(manager.beginQRVerification(with: malloryQR.url, slotID: bobSlot.peer.id) == false,
                "A valid code belonging to a DIFFERENT nearby peer must be refused, not searched for")
        #expect(capture.contains("mesh.verifyQR.qrPeerMismatch"))

        #expect(manager.pendingVerifyChallengeNonceForTesting(slotID: mallorySlot.peer.id) == nil,
                "No round may be opened against the peer whose code was scanned from someone else's row")
        #expect(manager.pendingVerifyChallengeNonceForTesting(slotID: bobSlot.peer.id) == nil)

        await settle()
        #expect(!isCommitted(mallorySlot.coordinator))
        #expect(!isCommitted(bobSlot.coordinator))
    }

    /// Scanner half, happy path: the response signed by the peer whose QR was scanned commits
    /// this side. (The displayer half is `ceremonyCommitsOnlyTheSlotTheQRWasOpenedFor` — both
    /// halves can't run in one process, since every manager in it shares the one device identity.)
    @Test func validResponseCommitsTheScannerSide() async throws {
        let (local, localID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: localID) }
        let (bob, bobID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: bobID) }
        let capture = CeremonyAuditCapture()
        capture.install()
        defer { capture.uninstall() }

        let manager = MeshNetworkManager(store: store)
        let bobSlot = try await makeAwaitingManualCommitSlot(on: manager, localIdentity: local, remote: bob, name: "Bob")

        let bobQR = try ProximityVerifyQR.makeURL(identity: bob)
        #expect(manager.beginQRVerification(with: bobQR.url, slotID: bobSlot.peer.id))
        let challengeNonce = try #require(manager.pendingVerifyChallengeNonceForTesting(slotID: bobSlot.peer.id))

        let signature = try bob.sign(ProximityVerifySignature.message(
            scannerKeyAgreementPublicKey: manager.localKeyAgreementPublicKey,
            challengeNonce: challengeNonce,
            qrNonce: bobQR.nonce
        ), purpose: FernletCryptoPurpose.Signature.proximityQRResponseV1)
        try deliverResponse(to: manager, on: bobSlot.coordinator, from: bob,
                            challengeNonce: challengeNonce, signature: signature)
        await waitForCommit(bobSlot.coordinator)

        #expect(isCommitted(bobSlot.coordinator))
        #expect(capture.contains("mesh.verifyQR.scannerCommitted"))
    }

    /// Scanner half, rejection: a response whose signature was made by a different key than the
    /// scanned QR advertised proves nothing — no commit, and the pending round is spent.
    @Test func responseSignedByTheWrongKeyNeverCommits() async throws {
        let (local, localID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: localID) }
        let (bob, bobID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: bobID) }
        let (mallory, malloryID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: malloryID) }
        let capture = CeremonyAuditCapture()
        capture.install()
        defer { capture.uninstall() }

        let manager = MeshNetworkManager(store: store)
        let bobSlot = try await makeAwaitingManualCommitSlot(on: manager, localIdentity: local, remote: bob, name: "Bob")

        let bobQR = try ProximityVerifyQR.makeURL(identity: bob)
        #expect(manager.beginQRVerification(with: bobQR.url, slotID: bobSlot.peer.id))
        let challengeNonce = try #require(manager.pendingVerifyChallengeNonceForTesting(slotID: bobSlot.peer.id))

        // Correct transcript, wrong signer — the envelope still claims Bob's signing key, so only
        // the signature check can catch it.
        let signature = try mallory.sign(ProximityVerifySignature.message(
            scannerKeyAgreementPublicKey: manager.localKeyAgreementPublicKey,
            challengeNonce: challengeNonce,
            qrNonce: bobQR.nonce
        ), purpose: FernletCryptoPurpose.Signature.proximityQRResponseV1)
        try deliverResponse(to: manager, on: bobSlot.coordinator, from: bob,
                            challengeNonce: challengeNonce, signature: signature)
        await settle()

        #expect(!isCommitted(bobSlot.coordinator))
        #expect(capture.contains("mesh.verifyQR.badResponseSignature"))
        #expect(manager.pendingVerifyChallengeNonceForTesting(slotID: bobSlot.peer.id) == nil,
                "A failed round must be discarded, not left open for another attempt")
    }

    private func deliverResponse(
        to manager: MeshNetworkManager,
        on coordinator: ProximityCoordinator,
        from sender: IdentityService,
        challengeNonce: Data,
        signature: Data
    ) throws {
        let plaintext = try JSONEncoder().encode(
            VerifyResponsePayload(challengeNonce: challengeNonce, signature: signature)
        )
        let envelope = inboundCeremonyEnvelope(.verifyResponse, from: sender, plaintext: plaintext)
        manager.proximityCoordinator(coordinator, didReceive: envelope, plaintext: plaintext, from: nil)
    }

    // MARK: - Review 2026-07-27: fixed-length transcript fields

    /// The signed transcript concatenates `domain ‖ scannerKA ‖ challengeNonce ‖ qrNonce` with NO
    /// length prefixes, so it is unambiguous only while every field is fixed-length. `qrNonce` was
    /// pinned by the equality check against the live display nonce, but `challengeNonce` and the
    /// scanner's KA key came straight off the wire unchecked — an unbounded, unstructured signing
    /// oracle over the long-term identity key. Nothing is signed now until this holds.
    @Test func challengeWellFormednessPinsEveryTranscriptFieldLength() {
        let nonce = Data(repeating: 7, count: ProximityVerifySignature.nonceByteCount)
        let scannerKA = Data(repeating: 9, count: ProximityVerifySignature.publicKeyByteCount)
        let good = VerifyChallengePayload(qrNonce: nonce, challengeNonce: nonce)
        #expect(ProximityVerifySignature.isWellFormedChallenge(good, scannerKeyAgreementPublicKey: scannerKA))

        // An oversized challenge nonce — the 4 KB signing-oracle shape.
        let fatNonce = VerifyChallengePayload(qrNonce: nonce, challengeNonce: Data(repeating: 1, count: 4096))
        #expect(!ProximityVerifySignature.isWellFormedChallenge(fatNonce, scannerKeyAgreementPublicKey: scannerKA))
        // …and a short one, which would let two different splits produce identical signed bytes.
        let shortNonce = VerifyChallengePayload(qrNonce: nonce, challengeNonce: Data([1, 2, 3]))
        #expect(!ProximityVerifySignature.isWellFormedChallenge(shortNonce, scannerKeyAgreementPublicKey: scannerKA))
        // A wrong-length QR nonce is refused for the same reason.
        let shortQR = VerifyChallengePayload(qrNonce: Data([4, 5]), challengeNonce: nonce)
        #expect(!ProximityVerifySignature.isWellFormedChallenge(shortQR, scannerKeyAgreementPublicKey: scannerKA))
        // A non-Curve25519 scanner key shifts the field boundary too.
        #expect(!ProximityVerifySignature.isWellFormedChallenge(good, scannerKeyAgreementPublicKey: Data([1, 2, 3])))
        #expect(!ProximityVerifySignature.isWellFormedChallenge(good, scannerKeyAgreementPublicKey: Data()))
    }

    /// `canonicalBytes` concatenates the QR's two public keys with no length prefix, so
    /// "non-empty" was not a strong enough shape check — both must be exactly 32 bytes.
    @Test func qrValidationRequiresExactCurve25519KeyLengths() throws {
        let (identity, serviceID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: serviceID) }

        let made = try ProximityVerifyQR.makeURL(identity: identity)
        let genuine = try #require(ProximityVerifyQR.parse(made.url))
        #expect(ProximityVerifyQR.isValid(genuine))

        // A short key alone is enough to refuse it, before any signature math is trusted.
        let shortKA = ProximityVerifyQR.Payload(
            version: genuine.version,
            signingPublicKey: genuine.signingPublicKey,
            keyAgreementPublicKey: Data([1, 2, 3]),
            timestamp: genuine.timestamp,
            nonce: genuine.nonce,
            signature: genuine.signature
        )
        #expect(!ProximityVerifyQR.isValid(shortKA))

        let longSigning = ProximityVerifyQR.Payload(
            version: genuine.version,
            signingPublicKey: genuine.signingPublicKey + Data([0]),
            keyAgreementPublicKey: genuine.keyAgreementPublicKey,
            timestamp: genuine.timestamp,
            nonce: genuine.nonce,
            signature: genuine.signature
        )
        #expect(!ProximityVerifyQR.isValid(longSigning))
    }
}

/// Ceremony drops are silent by design (no UI, no state change), so the audit trail is the only
/// observable difference between "dropped for the right reason" and "dropped by accident".
private final class CeremonyAuditCapture {
    private let lock = NSLock()
    private var storedEvents: [String] = []
    private var token: UUID?

    func install() {
        token = FernletAuditLog.addCaptureHandler { [weak self] event, _ in
            guard let self else { return }
            self.lock.lock()
            self.storedEvents.append(event)
            self.lock.unlock()
        }
    }

    func uninstall() {
        if let token {
            FernletAuditLog.removeCaptureHandler(token)
            self.token = nil
        }
    }

    func count(_ event: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return storedEvents.filter { $0 == event }.count
    }

    func contains(_ event: String) -> Bool { count(event) > 0 }
}
