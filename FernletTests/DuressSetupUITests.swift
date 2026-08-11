// DuressSetupUITests.swift
// FernletTests
//
// Phase 7 (duress PIN), step 9: the setup screen's testable half.
//
// A settings screen is mostly `View`, and `View` is mostly untestable — so everything on this screen
// that can be got WRONG was deliberately pushed out of the view body and is pinned here:
//
//   * `DuressSetupAvailability` — which response may be armed, and whether the recovery device may
//     be un-enrolled. Both rules exist because the wrong answer arms an irreversible response over a
//     device that cannot honor it.
//   * The rejection copy the screen SURFACES rather than restates. The view shows
//     `error.localizedDescription` verbatim, so these tests assert the service's own constants reach
//     that string — if the two ever diverge, the user reads a lie.
//   * `DuressModeCopy` completeness, so a fourth `DuressMode` can never ship with a blank card or,
//     worse, a destructive response with no confirmation.
//   * `DuressCeremonyQR`, the QR relay that carries the in-person ceremony between two phones, run
//     end to end against two real `DuressRecoveryCoordinator`s — enrolment and recovery both.
//
// Lock rows go to UUID-scoped keychain services via `LockTestHarness`; identities are minted at
// throwaway services and wiped. Nothing here touches the production lock or the device identity.

import CryptoKit
import Foundation
import Security
import Testing
import FernletFoundation
import ProximityKit
@testable import Fernlet
@testable import FernletLock

// MARK: - Fixtures

/// A provisioned proximity identity at a throwaway keychain service.
@MainActor
private func makeCeremonyIdentity() throws -> IdentityService {
    let identity = IdentityService(keychainService: "com.fernlet.identity.test.\(UUID().uuidString)")
    try identity.ensureProvisioned()
    return identity
}

/// A configured lock plus the two identities a ceremony needs, wired the way the screens wire them.
@MainActor
private final class DuressSetupFixture {
    let harness = LockTestHarness()
    let service: FernletLockService
    let primaryIdentity: IdentityService
    let custodianIdentity: IdentityService
    /// A stand-in for one row of the sealed corpus, so a recovery can be proven to have worked
    /// rather than merely to have returned without throwing.
    let sealedCorpusRow: Data

    static let corpusPlaintext = Data("a note that must survive a recovery-lock and come back".utf8)

    init(realPIN: String = "123456") async throws {
        primaryIdentity = try makeCeremonyIdentity()
        custodianIdentity = try makeCeremonyIdentity()
        service = harness.makeService()
        try await service.configure(credential: .pin6(realPIN), grantingScope: .privateHub)
        let key = try #require(service.contentKey(for: .privateHub))
        sealedCorpusRow = try ChaChaPoly.seal(Self.corpusPlaintext, using: key).combined
    }

    /// Enrols the custodian directly through the lock (no ceremony), for tests that only care about
    /// the enrolled STATE.
    func enrollCustodianDirectly(passcode: String = "123456") async throws {
        let custodianKeyAgreement = custodianIdentity.localKeyAgreementPublicKey
        let primary = primaryIdentity
        try await service.enrollRecoveryCustodian(
            passcode: passcode,
            signingPublicKey: custodianIdentity.localSigningPublicKey,
            keyAgreementPublicKey: custodianKeyAgreement
        ) { contentKey in
            try primary.seal(contentKey, to: custodianKeyAgreement, format: .wire2)
        }
    }

    func cleanup() {
        harness.cleanup()
        try? primaryIdentity.wipe()
        try? custodianIdentity.wipe()
    }
}

// MARK: - Availability policy

/// The gating rules the screen renders. Pure struct in, pure answer out — no `View` involved, which
/// is the whole reason these rules were split out of the body.
@MainActor
@Suite(.serialized)
struct DuressSetupAvailabilityTests {

    /// The one response that is ever withheld, and the one reason it is: arming it without a
    /// custodian would destroy every local unlock key with nothing able to give them back.
    @Test func recoveryLockIsUnselectableWithoutAnEnrolledCustodian() {
        let availability = DuressSetupAvailability(
            hasDuressConfigured: false,
            configuredMode: nil,
            hasRecoveryCustodian: false
        )
        #expect(availability.isSelectable(.decoy))
        #expect(availability.isSelectable(.silentWipe))
        #expect(!availability.isSelectable(.recoveryLock))
        // Never a bare disabled control: a withheld option always says why.
        #expect(availability.unavailableReason(for: .recoveryLock) != nil)
        #expect(availability.unavailableReason(for: .decoy) == nil)
        #expect(availability.unavailableReason(for: .silentWipe) == nil)
    }

    @Test func enrollingACustodianMakesRecoveryLockSelectable() {
        let availability = DuressSetupAvailability(
            hasDuressConfigured: false,
            configuredMode: nil,
            hasRecoveryCustodian: true
        )
        #expect(availability.isSelectable(.recoveryLock))
        #expect(availability.unavailableReason(for: .recoveryLock) == nil)
        #expect(DuressMode.allCases.allSatisfy(availability.isSelectable))
    }

    /// The UI half of `removeRecoveryCustodian()`'s refusal. Without this the screen would offer a
    /// button whose only possible outcome is an error — and, if the refusal were ever dropped from
    /// the service, a button that silently downgrades an armed response into an unrecoverable one.
    @Test func theRecoveryDeviceCannotBeRemovedWhileTheRecoveryLockIsArmed() {
        let armed = DuressSetupAvailability(
            hasDuressConfigured: true,
            configuredMode: .recoveryLock,
            hasRecoveryCustodian: true
        )
        #expect(!armed.canRemoveRecoveryCustodian)
        #expect(armed.recoveryRemovalRefusalReason != nil)

        for mode in [DuressMode.decoy, .silentWipe] {
            let other = DuressSetupAvailability(
                hasDuressConfigured: true,
                configuredMode: mode,
                hasRecoveryCustodian: true
            )
            #expect(other.canRemoveRecoveryCustodian, "\(mode) does not depend on the custodian")
            #expect(other.recoveryRemovalRefusalReason == nil)
        }
    }

    @Test func withNoCustodianThereIsNothingToRemoveAndNothingToExplain() {
        let none = DuressSetupAvailability(
            hasDuressConfigured: true,
            configuredMode: .decoy,
            hasRecoveryCustodian: false
        )
        #expect(!none.canRemoveRecoveryCustodian)
        #expect(none.recoveryRemovalRefusalReason == nil, "a refusal reason for a device that isn't enrolled would be nonsense")
    }

    /// The snapshot the screen actually builds, read off a live service rather than hand-assembled —
    /// so a renamed or re-scoped service property fails here instead of silently reading `false`.
    @Test func theSnapshotTracksTheLiveService() async throws {
        let fixture = try await DuressSetupFixture()
        defer { fixture.cleanup() }

        var availability = DuressSetupAvailability(lockService: fixture.service)
        #expect(!availability.hasDuressConfigured)
        #expect(availability.configuredMode == nil)
        #expect(!availability.hasRecoveryCustodian)
        #expect(!availability.isSelectable(.recoveryLock))

        try await fixture.service.configureDuress(pin: "654321", mode: .silentWipe)
        availability = DuressSetupAvailability(lockService: fixture.service)
        #expect(availability.hasDuressConfigured)
        #expect(availability.configuredMode == .silentWipe)

        try await fixture.enrollCustodianDirectly()
        availability = DuressSetupAvailability(lockService: fixture.service)
        #expect(availability.hasRecoveryCustodian)
        #expect(availability.isSelectable(.recoveryLock))
        #expect(availability.canRemoveRecoveryCustodian, "the armed response is the wipe, which needs no custodian")

        try await fixture.service.configureDuress(pin: "654321", mode: .recoveryLock)
        availability = DuressSetupAvailability(lockService: fixture.service)
        #expect(availability.configuredMode == .recoveryLock)
        #expect(!availability.canRemoveRecoveryCustodian)
    }
}

// MARK: - What the screen surfaces

/// The service rejections the screen shows verbatim, and the state changes its buttons make.
///
/// The screen renders `error.localizedDescription` rather than copy of its own precisely so these
/// two can never disagree; these tests are what make that non-restatement safe.
@MainActor
@Suite(.serialized)
struct DuressSetupSurfacingTests {

    /// The distinct-code rule the "Set duress code" button depends on. A duress code equal to the
    /// real passcode would make every unlock take the duress branch, stranding the content key
    /// permanently — so the screen must show a legible refusal, not a silent no-op.
    @Test func aDuressCodeEqualToThePasscodeIsRefusedWithReadableCopy() async throws {
        let fixture = try await DuressSetupFixture()
        defer { fixture.cleanup() }

        do {
            try await fixture.service.configureDuress(pin: "123456", mode: .decoy)
            Issue.record("the duress code was allowed to equal the real passcode")
        } catch {
            // What the entry sheet puts on screen, character for character.
            #expect(error.localizedDescription == FernletLockService.duressPINMatchesPasscodeMessage)
            #expect(!error.localizedDescription.isEmpty)
        }
        #expect(!fixture.service.hasDuressConfigured)
        #expect(DuressSetupAvailability(lockService: fixture.service).configuredMode == nil)
    }

    /// The service's half of the recovery-lock gate. The screen withholds the option, but the screen
    /// is not the guarantee — a stale snapshot, or a future entry point, must still be refused here.
    @Test func recoveryLockIsRefusedWithReadableCopyWhenNoCustodianIsEnrolled() async throws {
        let fixture = try await DuressSetupFixture()
        defer { fixture.cleanup() }

        do {
            try await fixture.service.configureDuress(pin: "654321", mode: .recoveryLock)
            Issue.record("the recovery lock was armed with no device able to undo it")
        } catch {
            #expect(error.localizedDescription == FernletLockService.duressRecoveryCustodianRequiredMessage)
        }
        #expect(!fixture.service.hasDuressConfigured)
    }

    /// The remove path: the duress code stops working, the response is forgotten, and the real
    /// passcode and content key are untouched — the screen promises exactly that.
    @Test func removingTheDuressCodeLeavesTheRealLockIntact() async throws {
        let fixture = try await DuressSetupFixture()
        defer { fixture.cleanup() }
        let service = fixture.service

        try await service.configureDuress(pin: "654321", mode: .decoy)
        #expect(service.configuredDuressMode == .decoy)

        service.removeDuress()
        #expect(!service.hasDuressConfigured)
        #expect(service.configuredDuressMode == nil)

        // The old duress code is now just a wrong passcode.
        service.lock(reason: .manual)
        await #expect(throws: FernletLockError.self) {
            _ = try await service.unlock(passcode: "654321", for: .privateHub)
        }
        #expect(!service.isDuressSessionActive)

        // …and the real passcode still opens the real key.
        _ = try await service.unlock(passcode: "123456", for: .privateHub)
        #expect(service.contentKey(for: .privateHub) != nil)
    }

    /// Changing the response rewrites the mode the screen reads back, so "Duress code set — <this>"
    /// can never describe a response that is no longer armed.
    @Test func changingTheResponseUpdatesWhatTheScreenReportsIsArmed() async throws {
        let fixture = try await DuressSetupFixture()
        defer { fixture.cleanup() }

        try await fixture.service.configureDuress(pin: "654321", mode: .decoy)
        #expect(fixture.service.configuredDuressMode == .decoy)
        try await fixture.service.configureDuress(pin: "654321", mode: .silentWipe)
        #expect(fixture.service.configuredDuressMode == .silentWipe)
    }

    /// The remove-recovery-device button's refusal, from the service. The screen withholds the
    /// button in this state; if it is ever reached anyway (the response was armed from another
    /// surface while the screen was open), the thrown message is what the user reads.
    @Test func removingTheRecoveryDeviceIsRefusedWhileTheRecoveryLockIsArmed() async throws {
        let fixture = try await DuressSetupFixture()
        defer { fixture.cleanup() }

        try await fixture.enrollCustodianDirectly()
        try await fixture.service.configureDuress(pin: "654321", mode: .recoveryLock)

        do {
            try fixture.service.removeRecoveryCustodian()
            Issue.record("the only device able to undo the armed response was removed")
        } catch {
            #expect(error.localizedDescription == FernletLockService.recoveryCustodianInUseMessage)
        }
        #expect(fixture.service.hasRecoveryCustodian)

        // Changing the response first is the way out the copy points at, and it works.
        try await fixture.service.configureDuress(pin: "654321", mode: .decoy)
        #expect(DuressSetupAvailability(lockService: fixture.service).canRemoveRecoveryCustodian)
        try fixture.service.removeRecoveryCustodian()
        #expect(!fixture.service.hasRecoveryCustodian)
    }
}

// MARK: - Copy completeness

/// Every response must carry its own words, and every destructive response its own confirmation.
///
/// These are the tests a fourth `DuressMode` trips: a new case with no copy renders a blank card,
/// and a new destructive case with no confirmation title is armed on a single tap.
@Suite
struct DuressModeCopyTests {

    @Test func everyResponseHasATitleSummaryAndConsequenceParagraph() {
        for mode in DuressMode.allCases {
            #expect(!DuressModeCopy.title(mode).isEmpty, "\(mode) has no title")
            #expect(!DuressModeCopy.summary(mode).isEmpty, "\(mode) has no summary")
            #expect(DuressModeCopy.detail(mode).count > 80, "\(mode)'s consequence copy is too thin to be honest")
        }
    }

    @Test func onlyTheNonDestructiveResponseSkipsTheSecondConfirmation() {
        #expect(DuressModeCopy.armConfirmationTitle(.decoy) == nil)
        #expect(DuressModeCopy.armConfirmationTitle(.silentWipe) != nil)
        #expect(DuressModeCopy.armConfirmationTitle(.recoveryLock) != nil)
    }

    /// The wipe's copy has to say the irreversible part out loud; the recovery lock's has to name
    /// the single point of failure it creates. Both are the sentences a user would sue over.
    @Test func theDestructiveResponsesStateTheirWorstCase() {
        #expect(DuressModeCopy.detail(.silentWipe).localizedCaseInsensitiveContains("cannot be undone"))
        #expect(DuressModeCopy.detail(.recoveryLock).localizedCaseInsensitiveContains("gone for good"))
        // …and the non-destructive one must NOT be dressed up as destructive.
        #expect(DuressModeCopy.detail(.decoy).localizedCaseInsensitiveContains("untouched"))
    }

    @Test func everyResponseHasAStableAccessibilitySuffix() {
        let suffixes = DuressMode.allCases.map(\.accessibilitySuffix)
        #expect(Set(suffixes).count == DuressMode.allCases.count, "two responses share an identifier")
        #expect(suffixes.allSatisfy { !$0.isEmpty })
    }
}

// MARK: - The QR relay

/// The carrier that moves ceremony bytes between two screens.
///
/// It carries no new trust — the authentication all lives in the coordinator — so what these tests
/// pin is that it carries the bytes EXACTLY, and refuses anything it should not carry: a wrong
/// length (the transcripts are unprefixed concatenations), a friend-verification URL, an unknown
/// version, a foreign host.
@Suite
struct DuressCeremonyQRTests {

    private func nonce() -> Data { Data((0..<DuressCeremonyQR.nonceByteCount).map { _ in UInt8.random(in: .min ... .max) }) }
    private func publicKey() -> Data { Data((0..<DuressCeremonyQR.publicKeyByteCount).map { _ in UInt8.random(in: .min ... .max) }) }
    private func signature() -> Data { Data((0..<DuressCeremonyQR.signatureByteCount).map { _ in UInt8.random(in: .min ... .max) }) }

    @Test func everyHopRoundTripsByteForByte() throws {
        let messages: [DuressCeremonyMessage] = [
            .challenge(qrNonce: nonce(), challengeNonce: nonce(), senderKeyAgreementPublicKey: publicKey()),
            .response(challengeNonce: nonce(), signature: signature()),
            .request(senderKeyAgreementPublicKey: publicKey(), sealed: Data((0..<512).map { _ in UInt8.random(in: .min ... .max) })),
            .reply(sealed: Data((0..<300).map { _ in UInt8.random(in: .min ... .max) }))
        ]
        for message in messages {
            let url = try #require(DuressCeremonyQR.url(for: message), "\(message) would not encode")
            #expect(DuressCeremonyQR.parse(url) == message)
        }
    }

    /// Base64URL, not standard base64: `+` and `/` in a query value survive most parsers but not
    /// every scanner, and this ceremony is a photograph of a screen.
    @Test func theEncodingIsURLSafe() throws {
        // 0xFB 0xFF 0xBE encodes to "+/++" in standard base64 — the exact characters that break
        // naive query parsers ("+" reads as a space) and some scanner pipelines.
        let sealed = Data([0xFB, 0xFF, 0xBE, 0xEF] + (0..<63).map { UInt8($0) })
        #expect(sealed.base64EncodedString().contains("+"), "precondition: the fixture must exercise the escape")
        let url = try #require(DuressCeremonyQR.url(for: .reply(sealed: sealed)))
        // The VALUE, not the whole URL — `?v=1&d=` legitimately contains `=`.
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let encoded = try #require(items.first { $0.name == "d" }?.value)
        #expect(!encoded.contains("+"))
        #expect(!encoded.contains("/"))
        #expect(!encoded.contains("="))
        #expect(DuressCeremonyQR.parse(url) == .reply(sealed: sealed))
    }

    @Test func wrongLengthFieldsAreRefusedRatherThanTruncated() {
        #expect(DuressCeremonyQR.url(for: .challenge(
            qrNonce: Data([1, 2, 3]),
            challengeNonce: nonce(),
            senderKeyAgreementPublicKey: publicKey()
        )) == nil)
        #expect(DuressCeremonyQR.url(for: .response(challengeNonce: nonce(), signature: Data([1]))) == nil)
        #expect(DuressCeremonyQR.url(for: .request(senderKeyAgreementPublicKey: Data(), sealed: Data([1]))) == nil)
        #expect(DuressCeremonyQR.url(for: .reply(sealed: Data())) == nil)
    }

    /// A hop of the FRIEND verification ceremony must never decode as a duress hop, and vice versa —
    /// distinct hosts make that a parse failure rather than a judgement call.
    @Test func aFriendVerificationURLIsNotADuressHop() throws {
        let friendly = try #require(URL(string: "fernlet://verify?v=1&s=abc&k=def&t=1&n=ghi&sig=jkl"))
        #expect(DuressCeremonyQR.parse(friendly) == nil)
    }

    @Test func foreignSchemesHostsAndVersionsAreRefused() throws {
        let real = try #require(DuressCeremonyQR.url(for: .reply(sealed: Data([1, 2, 3, 4]))))
        let query = try #require(URLComponents(url: real, resolvingAgainstBaseURL: false)?.query)

        #expect(DuressCeremonyQR.parse(try #require(URL(string: "https://duress-reply?\(query)"))) == nil)
        #expect(DuressCeremonyQR.parse(try #require(URL(string: "fernlet://duress-elsewhere?\(query)"))) == nil)
        let bumped = query.replacingOccurrences(of: "v=1", with: "v=2")
        #expect(DuressCeremonyQR.parse(try #require(URL(string: "fernlet://duress-reply?\(bumped)"))) == nil)
    }

    @Test func garbageDoesNotDecode() throws {
        #expect(DuressCeremonyQR.parse(try #require(URL(string: "fernlet://duress-challenge"))) == nil)
        #expect(DuressCeremonyQR.parse(try #require(URL(string: "fernlet://duress-response?v=1&c=!!!&g=!!!"))) == nil)
        #expect(DuressCeremonyQR.parse(try #require(URL(string: "https://example.com/duress-reply?v=1&d=AAAA"))) == nil)
    }
}

// MARK: - End-to-end over the relay

/// Two real coordinators, two real identities, and nothing between them but the QR relay.
///
/// This is what makes the relay's "it adds no new trust" claim checkable: the same coordinator calls
/// the screens make, in the same order, with every hop forced through `url(for:)` → `parse(_:)`. If
/// the carrier dropped, reordered or reshaped a byte, the signature checks inside the coordinator
/// would fail here rather than on a user's kitchen table.
@MainActor
@Suite(.serialized)
struct DuressCeremonyRelayTests {

    /// A full enrolment: identity code out, challenge back, answer forward, key sealed.
    @Test func anEnrolmentCompletesOverTheQRRelay() async throws {
        let fixture = try await DuressSetupFixture()
        defer { fixture.cleanup() }
        let custodianHarness = LockTestHarness()
        defer { custodianHarness.cleanup() }

        let primary = DuressRecoveryCoordinator(identity: fixture.primaryIdentity, lockService: fixture.service)
        let custodian = DuressRecoveryCoordinator(
            identity: fixture.custodianIdentity,
            lockService: custodianHarness.makeService()
        )

        try await runMutualAuth(primary: primary, custodian: custodian, purpose: .enroll, fixture: fixture)
        #expect(fixture.service.hasRecoveryCustodian)
        #expect(fixture.service.enrolledCustodianSigningPublicKey == fixture.custodianIdentity.localSigningPublicKey)
    }

    /// The whole point, end to end: enrol, fire the recovery lock, and get the corpus back — with
    /// every ceremony byte having travelled through a QR payload.
    @Test func aRecoveryLockedPhoneIsRecoveredOverTheQRRelay() async throws {
        let fixture = try await DuressSetupFixture()
        defer { fixture.cleanup() }
        let custodianHarness = LockTestHarness()
        defer { custodianHarness.cleanup() }

        let primary = DuressRecoveryCoordinator(identity: fixture.primaryIdentity, lockService: fixture.service)
        let custodian = DuressRecoveryCoordinator(
            identity: fixture.custodianIdentity,
            lockService: custodianHarness.makeService()
        )
        try await runMutualAuth(primary: primary, custodian: custodian, purpose: .enroll, fixture: fixture)

        // Arm and fire the recovery lock.
        try await fixture.service.configureDuress(pin: "654321", mode: .recoveryLock)
        fixture.service.lock(reason: .manual)
        _ = try await fixture.service.unlock(passcode: "654321", for: .privateHub)
        #expect(fixture.service.isDuressSessionActive)
        #expect(fixture.service.contentKey(for: .privateHub) == nil)
        #expect(fixture.service.isAwaitingCustodianRecovery)

        // The return ceremony, from a fresh display on the custodian.
        custodian.clearDisplay()
        let request = try await runMutualAuth(primary: primary, custodian: custodian, purpose: .recover, fixture: fixture)
        let requestBytes = try #require(request)

        let requestURL = try #require(DuressCeremonyQR.url(for: .request(
            senderKeyAgreementPublicKey: primary.localKeyAgreementPublicKey,
            sealed: requestBytes
        )))
        guard case .request(let senderKey, let sealedRequest)? = DuressCeremonyQR.parse(requestURL) else {
            Issue.record("the request hop did not survive the relay")
            return
        }
        _ = try custodian.openRecoveryRequest(sealedRequest, from: senderKey)
        let sealedReply = try custodian.answerPendingRecoveryRequest(.returnKey)

        let replyURL = try #require(DuressCeremonyQR.url(for: .reply(sealed: sealedReply)))
        guard case .reply(let relayedReply)? = DuressCeremonyQR.parse(replyURL) else {
            Issue.record("the reply hop did not survive the relay")
            return
        }
        let outcome = try await primary.completeRecovery(
            sealedReply: relayedReply,
            credential: .pin6("999999"),
            grantingScope: .privateHub
        )
        #expect(outcome == .unlockReestablished)

        // The corpus opens again under the recovered key — the only assertion that proves the right
        // key came back rather than merely *a* key.
        let key = try #require(fixture.service.contentKey(for: .privateHub))
        let box = try ChaChaPoly.SealedBox(combined: fixture.sealedCorpusRow)
        #expect(try ChaChaPoly.open(box, using: key) == DuressSetupFixture.corpusPlaintext)
        #expect(!fixture.service.isDuressSessionActive)
    }

    /// A refusal comes back as a refusal, and the coordinator does NOT act on it — destroying the
    /// corpus stays the app's own explicit funnel, never a message from another phone.
    @Test func aCustodianRefusalIsReportedAndNothingIsDestroyed() async throws {
        let fixture = try await DuressSetupFixture()
        defer { fixture.cleanup() }
        let custodianHarness = LockTestHarness()
        defer { custodianHarness.cleanup() }

        let primary = DuressRecoveryCoordinator(identity: fixture.primaryIdentity, lockService: fixture.service)
        let custodian = DuressRecoveryCoordinator(
            identity: fixture.custodianIdentity,
            lockService: custodianHarness.makeService()
        )
        try await runMutualAuth(primary: primary, custodian: custodian, purpose: .enroll, fixture: fixture)
        try await fixture.service.configureDuress(pin: "654321", mode: .recoveryLock)
        fixture.service.lock(reason: .manual)
        _ = try await fixture.service.unlock(passcode: "654321", for: .privateHub)

        custodian.clearDisplay()
        let requestBytes = try #require(
            try await runMutualAuth(primary: primary, custodian: custodian, purpose: .recover, fixture: fixture)
        )
        _ = try custodian.openRecoveryRequest(requestBytes, from: primary.localKeyAgreementPublicKey)
        let sealedReply = try custodian.answerPendingRecoveryRequest(.destroy)

        let outcome = try await primary.completeRecovery(
            sealedReply: sealedReply,
            credential: .pin6("999999"),
            grantingScope: .privateHub
        )
        #expect(outcome == .destructionRequested)
        // Nothing was installed and nothing was destroyed: the recovery material is still there, so
        // a user who changes their mind can still run the ceremony again.
        #expect(fixture.service.hasRecoveryCustodian)
        #expect(fixture.service.contentKey(for: .privateHub) == nil)
    }

    /// What both flows do: identity code → challenge → response, every hop through the relay.
    ///
    /// - Returns: the sealed recovery request for `.recover`, nil for `.enroll` (which ends at the
    ///   passcode instead).
    @discardableResult
    private func runMutualAuth(
        primary: DuressRecoveryCoordinator,
        custodian: DuressRecoveryCoordinator,
        purpose: RelayPurpose,
        fixture: DuressSetupFixture
    ) async throws -> Data? {
        let identityURL = try #require(custodian.makeDisplayURL())
        let challenge = purpose == .enroll
            ? try primary.beginCustodianEnrollment(scannedURL: identityURL)
            : try primary.beginRecovery(scannedURL: identityURL)

        let challengeURL = try #require(DuressCeremonyQR.url(for: .challenge(
            qrNonce: challenge.qrNonce,
            challengeNonce: challenge.challengeNonce,
            senderKeyAgreementPublicKey: primary.localKeyAgreementPublicKey
        )))
        guard case .challenge(let qrNonce, let challengeNonce, let senderKey)? = DuressCeremonyQR.parse(challengeURL) else {
            Issue.record("the challenge hop did not survive the relay")
            return nil
        }
        let response = try #require(custodian.handleChallenge(
            VerifyChallengePayload(qrNonce: qrNonce, challengeNonce: challengeNonce),
            senderKeyAgreementPublicKey: senderKey
        ))

        let responseURL = try #require(DuressCeremonyQR.url(for: .response(
            challengeNonce: response.challengeNonce,
            signature: response.signature
        )))
        guard case .response(let relayedNonce, let relayedSignature)? = DuressCeremonyQR.parse(responseURL) else {
            Issue.record("the response hop did not survive the relay")
            return nil
        }
        let relayed = VerifyResponsePayload(challengeNonce: relayedNonce, signature: relayedSignature)
        let custodianSigning = fixture.custodianIdentity.localSigningPublicKey

        switch purpose {
        case .enroll:
            try await primary.completeCustodianEnrollment(
                response: relayed,
                senderSigningPublicKey: custodianSigning,
                passcode: "123456"
            )
            return nil
        case .recover:
            return try primary.makeRecoveryRequest(response: relayed, senderSigningPublicKey: custodianSigning)
        }
    }

    /// Which ceremony a relay run is driving.
    private enum RelayPurpose { case enroll, recover }
}
