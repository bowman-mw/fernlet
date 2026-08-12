// DuressHardeningTests.swift
// FernletTests
//
// Phase 7 review fixes: the properties the duress PIN was SUPPOSED to have and did not.
//
// Each suite here pins one confirmed defect from the adversarial review of `claude/harden-p7`, and
// they are all the same family of mistake — a protection that was argued for in prose and then left
// to a surface that could not enforce it:
//
//   * The duress code opened Settings → App lock, the one screen that announces a duress code exists
//     and lets it be changed, removed, or reset away. The screen's "real-PIN-gated by construction"
//     premise is now made TRUE in the service: a duress PIN can never hold `.appLockSettings`, and
//     every duress mutator refuses inside a duress session.
//   * The duress code could not be TYPED during a cooldown or after `requiresReset` — the two states
//     the design calls out as "when coercion is likeliest" — because the lock screen replaced its
//     entry surface with a countdown card.
//   * A credential-KIND change stranded the duress verifier while the UI kept reporting it armed.
//   * The silent wipe left the private-media key alive, so the "no sealed byte on this device can be
//     opened" claim was false for body photos — which the decoy also showed in full.
//   * A duress unlock cost one scrypt derivation where every other entry costs two.
//   * The recovery ceremony logged `duressRecovery.*` event names into the unified log, defeating
//     the deliberate audit silence of the API it drives.
//
// Lock rows go to UUID-scoped keychain services via `LockTestHarness` (shared with
// FernletLockServiceTests), so nothing here touches the production lock, the real journal device
// keys, or the real private-media keys.

import CryptoKit
import Foundation
import Security
import Testing
import UIKit
import FernletFoundation
import LocalPersistence
@testable import Fernlet
@testable import FernletLock
@testable import PrivateMediaStore

// MARK: - Shared helpers

/// Raw keychain read for one lock row under a harness's isolated service.
@MainActor
private func hardeningRow(_ key: LockKeychainKey, _ harness: LockTestHarness) -> Data? {
    KeychainItem.load(for: key, service: harness.serviceID)
}


/// `FernletLockError` is not `Equatable`, so the refusal assertions go through do/catch rather than
/// `#expect(throws:)` — the same shape the other duress suites use.
@MainActor
private func expectInvalidPasscode(
    _ body: () async throws -> Void,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    do {
        try await body()
        Issue.record("expected the entry to be refused", sourceLocation: sourceLocation)
    } catch FernletLockError.invalidPasscode {
        // Expected.
    } catch {
        Issue.record("expected invalidPasscode, got \(error)", sourceLocation: sourceLocation)
    }
}

@MainActor
private func expectInvalidCredential(
    _ message: String,
    _ body: () async throws -> Void,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    do {
        try await body()
        Issue.record("expected the call to be refused", sourceLocation: sourceLocation)
    } catch FernletLockError.invalidCredential(let actual) {
        #expect(actual == message, sourceLocation: sourceLocation)
    } catch {
        Issue.record("expected invalidCredential, got \(error)", sourceLocation: sourceLocation)
    }
}

/// A configured lock with a duress PIN armed for `mode`, locked and ready for an entry.
@MainActor
private func armedService(
    _ harness: LockTestHarness,
    realPIN: String = "123456",
    duressPIN: String = "654321",
    mode: DuressMode = .decoy
) async throws -> FernletLockService {
    let service = harness.makeService()
    try await service.configure(credential: .pin6(realPIN), grantingScope: .privateHub)
    try await service.configureDuress(pin: duressPIN, mode: mode)
    service.lock(reason: .manual)
    return service
}

// MARK: - The duress PIN may never open Settings → App lock

/// The duress-management screen is the one surface that says out loud that a duress code exists and
/// what it does, and it hosts the calls that change it, remove it, enrol a recovery device, and
/// crypto-erase the corpus. `configureDuress`'s doc argues it needs no credential of its own because
/// reaching it "already proves the real credential" — which was false while a decoy session could
/// claim `.appLockSettings` like any other scope. These tests are that premise, enforced.
@MainActor
@Suite(.serialized)
struct DuressAppLockSettingsRefusalTests {

    @Test func aDuressPINIsRefusedAtTheAppLockSettingsGate() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = try await armedService(harness)

        await expectInvalidPasscode {
            _ = try await service.unlock(passcode: "654321", for: .appLockSettings)
        }

        // Refused for THAT surface…
        #expect(!service.isUnlocked(for: .appLockSettings))
        #expect(!service.isUnlocked(for: .privateHub))
        #expect(service.state == .locked(cooldownDeadline: nil))
        #expect(!service.hasResidentContentKey)
        // …while the protective half of the decoy is in force anyway, so the sensitive surfaces stay
        // shut and biometrics stay suppressed.
        #expect(service.isDuressSessionActive)
        // …and it still leaves no residue that tells it apart from a mistype.
        #expect(service.currentAttemptCount == 0)
        #expect(!service.requiresReset)
    }

    /// The control: every OTHER surface still opens, or the response would be no response at all.
    @Test func aDuressPINStillOpensTheSurfaceItWasTypedOn() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = try await armedService(harness)

        _ = try await service.unlock(passcode: "654321", for: .privateHub)
        #expect(service.isUnlocked(for: .privateHub))
        #expect(service.isDuressSessionActive)
        #expect(!service.hasResidentContentKey)

        service.lock(reason: .manual)
        _ = try await service.unlock(passcode: "654321", for: .progressPhotos)
        #expect(service.isUnlocked(for: .progressPhotos))
    }

    /// The real passcode is unaffected — the refusal is about which secret was entered, not about
    /// the surface being unreachable.
    @Test func theRealPasscodeStillOpensAppLockSettingsAndEndsTheDecoy() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = try await armedService(harness)
        await expectInvalidPasscode {
            _ = try await service.unlock(passcode: "654321", for: .appLockSettings)
        }

        _ = try await service.unlock(passcode: "123456", for: .appLockSettings)

        #expect(service.isUnlocked(for: .appLockSettings))
        #expect(!service.isDuressSessionActive)
    }

    /// The three non-`unlock` entry points are reached from INSIDE an already-unlocked App-lock
    /// settings page, so honoring a duress PIN there used to open a decoy while leaving that exact
    /// page revealed. The unlock has to be revoked, not merely not-granted.
    @Test func aDuressPINAtTheChangePasscodePromptRevokesTheSettingsUnlock() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = try await armedService(harness)
        _ = try await service.unlock(passcode: "123456", for: .appLockSettings)
        #expect(service.isUnlocked(for: .appLockSettings))

        try await service.changeCredential(current: "654321", new: .pin6("111111"))

        #expect(!service.isUnlocked(for: .appLockSettings))
        #expect(service.state == .locked(cooldownDeadline: nil))
        #expect(service.isDuressSessionActive)
        // Nothing was re-keyed: the real passcode is untouched and the coercer's choice never took.
        _ = try await service.unlock(passcode: "123456", for: .privateHub)
        #expect(!service.isDuressSessionActive)
    }

    /// Same seam, the biometrics prompt: a coerced "turn on Face ID" must not leave the settings
    /// page open either.
    @Test func aDuressPINAtTheBiometricPromptRevokesTheSettingsUnlock() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = try await armedService(harness)
        _ = try await service.unlock(passcode: "123456", for: .appLockSettings)

        try await service.setBiometricEnabled(true, passcode: "654321")

        #expect(!service.isUnlocked(for: .appLockSettings))
        #expect(service.isDuressSessionActive)
        #expect(hardeningRow(.biometricEnabledFlag, harness) == nil)
    }

    /// The refusal is about the SURFACE, never about the response: a coerced user who typed their
    /// duress code at the settings prompt still gets the wipe they armed.
    @Test func theArmedResponseStillFiresWhenTheSettingsGateRefuses() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = try await armedService(harness, mode: .silentWipe)
        let originalVerifier = try #require(hardeningRow(.verifier, harness))
        let purged = DuressHardeningFlag()
        service.duressPurgeHook = { purged.raise() }

        await expectInvalidPasscode {
            _ = try await service.unlock(passcode: "654321", for: .appLockSettings)
        }

        #expect(hardeningRow(.verifier, harness) != originalVerifier, "the wipe must still have run")
        #expect(hardeningRow(.duressVerifier, harness) == nil)
        #expect(purged.isRaised)
        #expect(!service.isUnlocked(for: .appLockSettings))
    }
}

// MARK: - Every duress mutator refuses inside a duress session

/// Belt to the scope refusal's braces. If a decoy session ever did reach the duress-management API —
/// a new caller, a future surface — changing or removing the duress code from inside one must not be
/// a way to disarm it, and enrolling a custodian must not be a way to export the content key.
@MainActor
@Suite(.serialized)
struct DuressSessionMutatorRefusalTests {

    @Test func everyDuressMutatorRefusesInsideADecoySession() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = try await armedService(harness)
        _ = try await service.unlock(passcode: "654321", for: .privateHub)
        #expect(service.isDuressSessionActive)

        let refusal = FernletLockService.duressSessionRefusalMessage
        await expectInvalidCredential(refusal) {
            try await service.configureDuress(pin: "999999", mode: .decoy)
        }
        await expectInvalidCredential(refusal) {
            try service.removeDuress()
        }
        await expectInvalidCredential(refusal) {
            try service.removeRecoveryCustodian()
        }
        await expectInvalidCredential(refusal) {
            try await service.enrollRecoveryCustodian(
                passcode: "123456",
                signingPublicKey: Data(repeating: 1, count: 32),
                keyAgreementPublicKey: Data(repeating: 2, count: 32),
                ownKeyAgreementPublicKey: Data(repeating: 3, count: 32)
            ) { $0 }
        }

        // Nothing moved, and the session is still a session.
        #expect(service.hasDuressConfigured)
        #expect(service.configuredDuressMode == .decoy)
        #expect(!service.hasRecoveryCustodian)
        #expect(service.isDuressSessionActive)

        // The real passcode is the only thing that ends it, after which the API works again.
        _ = try await service.unlock(passcode: "123456", for: .privateHub)
        #expect(!service.isDuressSessionActive)
        try await service.configureDuress(pin: "999999", mode: .silentWipe)
        #expect(service.configuredDuressMode == .silentWipe)
    }

    /// The UI half: the setup screen's policy snapshot reports an UNCONFIGURED device during a duress
    /// session, so the status card reads "No duress code" instead of naming the armed response.
    @Test func theSetupScreenReportsAnUnconfiguredDeviceInsideADecoySession() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = try await armedService(harness, mode: .silentWipe)

        let beforeCoercion = DuressSetupAvailability(lockService: service)
        #expect(beforeCoercion.hasDuressConfigured)
        #expect(beforeCoercion.configuredMode == .silentWipe)

        _ = try await service.unlock(passcode: "654321", for: .privateHub)

        let underCoercion = DuressSetupAvailability(lockService: service)
        #expect(underCoercion.isDuressSessionActive)
        #expect(!underCoercion.hasDuressConfigured)
        #expect(underCoercion.configuredMode == nil)
        #expect(!underCoercion.hasRecoveryCustodian)
        // …and it offers nothing to arm, so no dialog can even start.
        #expect(!underCoercion.isSelectable(.decoy))
        #expect(!underCoercion.isSelectable(.silentWipe))
        #expect(!underCoercion.isSelectable(.recoveryLock))
        // No reason strings either — a "withheld because…" line is itself the disclosure.
        #expect(underCoercion.unavailableReason(for: .recoveryLock) == nil)
    }
}

// MARK: - A credential-kind change may not strand the duress PIN

/// The lock renders exactly ONE entry surface and the PIN pads are hard-capped at their exact length,
/// so a 4-digit duress code cannot be typed at a 6-digit lock. The own-salt design carries the duress
/// rows through a re-key untouched — right for a same-kind change, silently fatal across a kind
/// change, which left `hasDuressConfigured` reporting an armed response over a verifier no entry
/// surface could ever reach.
@MainActor
@Suite(.serialized)
struct DuressCredentialKindStrandingTests {

    @Test func changingTheCredentialKindIsRefusedWhileItWouldStrandTheDuressPIN() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()
        try await service.configure(credential: .pin4("1234"), grantingScope: .privateHub)
        try await service.configureDuress(pin: "4321", mode: .decoy)

        await expectInvalidCredential(FernletLockService.duressPINWouldBeUnenterableMessage) {
            try await service.changeCredential(current: "1234", new: .pin6("123456"))
        }

        // Refused means refused: the lock is untouched and the duress PIN still fires.
        #expect(service.credentialKind == .pin4)
        #expect(service.hasDuressConfigured)
        service.lock(reason: .manual)
        _ = try await service.unlock(passcode: "4321", for: .privateHub)
        #expect(service.isDuressSessionActive)
    }

    /// The way through, and the reason the refusal is a refusal rather than a silent delete: the user
    /// removes the duress code deliberately, then sets one of the new shape.
    @Test func removingTheDuressPINUnblocksTheKindChange() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()
        try await service.configure(credential: .pin4("1234"), grantingScope: .privateHub)
        try await service.configureDuress(pin: "4321", mode: .decoy)

        try service.removeDuress()
        try await service.changeCredential(current: "1234", new: .pin6("123456"))

        #expect(service.credentialKind == .pin6)
        try await service.configureDuress(pin: "654321", mode: .decoy)
        service.lock(reason: .manual)
        _ = try await service.unlock(passcode: "654321", for: .privateHub)
        #expect(service.isDuressSessionActive)
    }

    /// A SAME-kind re-key still carries the duress PIN untouched (the own-salt property), and a move
    /// to the alphanumeric surface is allowed because a free-text field can still type old digits.
    @Test func aSameKindRekeyAndAMoveToAlphanumericBothKeepTheDuressPIN() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()
        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        try await service.configureDuress(pin: "654321", mode: .decoy)

        try await service.changeCredential(current: "123456", new: .pin6("111111"))
        #expect(service.hasDuressConfigured)

        try await service.changeCredential(current: "111111", new: .alphanumeric("a-long-password"))
        #expect(service.credentialKind == .alphanumeric)
        #expect(service.hasDuressConfigured)
        service.lock(reason: .manual)
        _ = try await service.unlock(passcode: "654321", for: .privateHub)
        #expect(service.isDuressSessionActive)
    }
}

// MARK: - The silent wipe destroys the private-media keys too

/// "Every key that can open a sealed byte here" has to include the private-media key: progress
/// photos are body photos sealed under `PrivateMediaKeyStore`'s OWN key, which the app lock never
/// holds and which the delete funnel deliberately KEEPS. Leaving it alive made the sub-second
/// crypto-erase claim false until the asynchronous purge caught up — and false forever if the
/// process died first.
@MainActor
@Suite(.serialized)
struct DuressWipeMediaKeyTests {

    private func plantMediaKey(_ harness: LockTestHarness) {
        _ = KeychainItem.store(
            Data(repeating: 0xAB, count: 32),
            account: "com.fernlet.private-media.ownContentKey",
            service: harness.mediaKeychainServiceID,
            accessibility: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        )
    }

    private func mediaKeyExists(_ harness: LockTestHarness) -> Bool {
        KeychainItem.load(
            account: "com.fernlet.private-media.ownContentKey",
            service: harness.mediaKeychainServiceID
        ) != nil
    }

    @Test func theSilentWipeDestroysThePrivateMediaKey() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = try await armedService(harness, mode: .silentWipe)
        plantMediaKey(harness)
        #expect(mediaKeyExists(harness))

        _ = try await service.unlock(passcode: "654321", for: .privateHub)

        #expect(!mediaKeyExists(harness), "the sealed photo corpus must be crypto-erased too")
    }

    /// The recovery-lock deliberately does NOT: nothing in the recovery blob can give the media key
    /// back, so destroying it there would be unrecoverable loss on the one mode that promises
    /// recovery — the same argument that spares the journal/Worry Box fallback keys.
    @Test func theRecoveryLockKeepsThePrivateMediaKey() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()
        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        let key = try #require(service.contentKey(for: .privateHub))
        let contentKey = key.withUnsafeBytes { Data($0) }
        try await service.enrollRecoveryCustodian(
            passcode: "123456",
            signingPublicKey: Data(repeating: 1, count: 32),
            keyAgreementPublicKey: Data(repeating: 2, count: 32),
            ownKeyAgreementPublicKey: Data(repeating: 3, count: 32)
        ) { _ in Data(repeating: 4, count: 48) }
        try await service.configureDuress(pin: "654321", mode: .recoveryLock)
        plantMediaKey(harness)
        service.lock(reason: .manual)

        _ = try await service.unlock(passcode: "654321", for: .privateHub)

        #expect(mediaKeyExists(harness))
        #expect(hardeningRow(.verifier, harness) == nil, "precondition: the recovery-lock did fire")
        #expect(contentKey.count == FernletLockCrypto.keyLength)
    }

    /// The sweep names the media service by VALUE, because `FernletLock` has no `PrivateMediaStore`
    /// edge and gains none for a wipe. This is the pin that keeps the restated string honest.
    @Test func theRestatedMediaServiceNameMatchesTheMediaStore() {
        #expect(FernletLockService.privateMediaKeychainService == KeychainPrivateMediaKeyProvider.service)
        #expect(KeychainPrivateMediaKeyProvider.ownAccount.hasPrefix(KeychainPrivateMediaKeyProvider.service))
    }
}

// MARK: - The decoy empties the progress-photo timeline

/// Progress photos are sealed under the media key, not the lock's content key, so the KEYLESS decoy
/// does not hide them by construction the way it hides journal and Worry Box rows — and a duress
/// unlock entered on the photo strip's own gate satisfies `.progressPhotos`. Gated at the store's
/// read seam instead, which is where every surface (strip, detail sheet, anything later) goes
/// through.
@MainActor
@Suite(.serialized)
struct DuressDecoyProgressPhotoTests {

    private func makeStore() -> FernletStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("duress-photos-\(UUID().uuidString).json")
        return FernletStore(repository: LocalFernletRepository(fileURL: url))
    }

    private func sampleJPEG() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24))
        let image = renderer.image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }
        return image.jpegData(compressionQuality: 0.8) ?? Data()
    }

    @Test func aDuressSessionEmptiesTheProgressPhotoTimelineAndIsFullyReversible() throws {
        let store = makeStore()
        let jpeg = sampleJPEG()
        try #require(!jpeg.isEmpty)
        let record = try #require(store.addProgressPhoto(data: jpeg, capturedAt: Date()))
        defer { store.deleteProgressPhoto(id: record.id) }
        #expect(store.progressPhotoRecords().contains { $0.id == record.id })
        #expect(store.progressPhotoData(for: record.id) != nil)

        store.duressSessionActive = true

        // An empty Fernlet is empty of body photos too — and the decrypt seam refuses even when a
        // caller already holds an id.
        #expect(store.progressPhotoRecords().isEmpty)
        #expect(store.progressPhotoData(for: record.id) == nil)
        // …and the decoy destroys nothing, so a delete reaching this far is inert.
        store.deleteProgressPhoto(id: record.id)

        store.duressSessionActive = false

        #expect(store.progressPhotoRecords().contains { $0.id == record.id })
        #expect(store.progressPhotoData(for: record.id) != nil)
    }
}

// MARK: - A duress unlock costs what a benign one costs

/// The unconditional duress derivation made latency independent of whether a duress PIN EXISTS, but
/// not of whether the entry WAS one: a match returned before the real verifier was ever derived, so
/// the decoy came back in roughly half the time — an eyeball-visible difference to anyone who has
/// watched this phone unlock normally.
@MainActor
@Suite(.serialized)
struct DuressUnlockLatencyTests {

    private func derivations(
        _ harness: LockTestHarness,
        during body: () async throws -> Void
    ) async rethrows -> Int {
        let before = harness.crypto.deriveVerifierCallCount
        try await body()
        return harness.crypto.deriveVerifierCallCount - before
    }

    @Test func aDuressUnlockCostsTheSameDerivationsAsABenignOne() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = try await armedService(harness)

        let benign = try await derivations(harness) {
            _ = try await service.unlock(passcode: "123456", for: .privateHub)
        }
        service.lock(reason: .manual)
        let wrong = await derivations(harness) {
            await expectInvalidPasscode {
                _ = try await service.unlock(passcode: "000000", for: .privateHub)
            }
        }
        let decoy = try await derivations(harness) {
            _ = try await service.unlock(passcode: "654321", for: .privateHub)
        }

        #expect(benign == 2, "a benign unlock is the duress compare plus the real verifier")
        #expect(decoy == benign)
        #expect(wrong == benign)
    }

    /// The refused `.appLockSettings` entry must not be cheap either — it is the one a coercer is
    /// most likely to time against a mistype at the same prompt.
    @Test func aRefusedAppLockSettingsDuressEntryCostsTheSameToo() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = try await armedService(harness)

        let wrong = await derivations(harness) {
            await expectInvalidPasscode {
                _ = try await service.unlock(passcode: "000000", for: .appLockSettings)
            }
        }
        let duress = await derivations(harness) {
            await expectInvalidPasscode {
                _ = try await service.unlock(passcode: "654321", for: .appLockSettings)
            }
        }

        #expect(duress == wrong)
    }

    /// The recovery-lock spends the same balancing derivation; the silent wipe does not need one,
    /// because its re-mint already performs a second derivation of its own.
    @Test func theDestructiveResponsesCostTheSameTwoDerivations() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = try await armedService(harness, mode: .silentWipe)

        let wipe = try await derivations(harness) {
            _ = try await service.unlock(passcode: "654321", for: .privateHub)
        }

        #expect(wipe == 2)
    }
}

// MARK: - Source-shape pins for the two properties no unit test can reach

/// Two invariants live in shapes rather than in values: what the lock SCREEN renders during a
/// lockout, and what the recovery ceremony NAMES in the unified log. Both are pinned by scanning the
/// source, the same way `PrivacyWipeCoverageTests` pins the delete funnel's shape.
@Suite
struct DuressForensicSourceTests {

    private static func repoRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Fernlet/FernletStore.swift").path) {
                return url
            }
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// The headline Phase-7 property — "the duress compare runs before the `requiresReset` and
    /// cooldown guards, so it fires when coercion is likeliest" — is unreachable if the screen swaps
    /// its entry surface for a countdown card. The service half is unit-tested
    /// (`DuressLockTests.duressFiresDuringAnActiveCooldownAndAfterResetIsRequired`); this is the view
    /// half, which has no seam a unit test can drive.
    @Test func theLockScreenKeepsItsEntrySurfaceDuringACooldownAndAfterResetIsRequired() throws {
        let source = try Self.source("FernletKit/Sources/FernletLockUI/FernletLockView.swift")
        let normalized = source.split(whereSeparator: \.isWhitespace).joined(separator: " ")

        #expect(
            normalized.contains("if lockService.requiresReset { resetRequiredCard } else if isInputDisabled { cooldownCard } inputSection"),
            """
            FernletLockView no longer renders `inputSection` alongside the lockout cards. \
            A duress code that cannot be TYPED during a cooldown or after requiresReset is a duress \
            code that fails at the only moment it was built for — and DuressPINSetupView tells the \
            user in so many words that it works there.
            """
        )
    }

    /// `FernletAuditLog` sends the event NAME to the unified log with `.auto` privacy, where a
    /// sysdiagnose keeps it. `configureDuress` and `enrollRecoveryCustodian` therefore emit nothing
    /// at all — and the ceremony that DRIVES enrollment must not undo that by logging a
    /// `duressRecovery.*` family on the protected phone.
    @Test func theRecoveryCeremonyEmitsNoDuressNamedAuditEvents() throws {
        let source = try Self.source("Fernlet/DuressRecoveryCoordinator.swift")
        let logged = source
            .components(separatedBy: "FernletAuditLog.log(\"")
            .dropFirst()
            .compactMap { $0.components(separatedBy: "\"").first }

        #expect(!logged.isEmpty, "the scan found no audit calls at all — did the call shape change?")
        for name in logged {
            #expect(
                !name.localizedCaseInsensitiveContains("duress") && !name.localizedCaseInsensitiveContains("recovery"),
                "audit event name '\(name)' discloses that this device has a duress PIN"
            )
        }
    }

    /// The ceremony's sheets are on the protected phone too, so the same rule applies to them.
    @Test func theCeremonySheetsEmitNoDuressNamedAuditEvents() throws {
        for path in ["Fernlet/DuressRecoveryCeremonyViews.swift", "Fernlet/DuressPINSetupView.swift"] {
            let source = try Self.source(path)
            let logged = source
                .components(separatedBy: "FernletAuditLog.log(\"")
                .dropFirst()
                .compactMap { $0.components(separatedBy: "\"").first }
            for name in logged {
                #expect(
                    !name.localizedCaseInsensitiveContains("duress"),
                    "audit event name '\(name)' in \(path) discloses that this device has a duress PIN"
                )
            }
        }
    }
}

// MARK: - Small helper

/// One-way flag for "this closure ran", mirroring the pattern in `DuressDecoyAndWipeTests`.
@MainActor
private final class DuressHardeningFlag {
    private(set) var isRaised = false
    func raise() { isRaised = true }
}
