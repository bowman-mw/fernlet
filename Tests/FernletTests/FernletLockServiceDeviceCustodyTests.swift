// FernletLockServiceDeviceCustodyTests.swift
// FernletTests
//
// The no-passcode key custody (period-data design 2026-09-30, §4; unit 1), as part of the
// `FernletLockServiceTests` suite: the tap state (I5), the device row's formats (I7), the
// mint-safety proof (I8), adding and removing a passcode around ONE key (I9), the owner check
// before adoption (I24), the shared state derivation (§4.6), and the fault-injection and
// process-death sweep over every keychain write AND delete of adoption, removal, the sweep and a
// fresh setup (I6).
//
// Every service runs on a `LockTestHarness`'s UUID-scoped keychain service with a fake enclave for
// the device row and an in-memory sealed store; nothing here touches the production service.

import CryptoKit
import Foundation
import Security
import Testing
import FernletFoundation
import PrivateStoreCore
@testable import FernletLock

extension FernletLockServiceTests {

    // MARK: - I5: the tap state

    /// A tap opens `.privateHub` and nothing else, releases the key only there, and every close —
    /// lock, background, a foreign surface arriving — returns to `.notConfigured` and scrubs it.
    @Test func aTapOpensOnlyThePrivateHubAndEveryCloseScrubsTheKey() throws {
        let fixture = DeviceCustodyFixture()
        defer { fixture.cleanup() }
        let service = fixture.makeService()
        #expect(service.state == .notConfigured)

        #expect(throws: FernletLockError.locked) {
            try service.openWithoutPasscode(for: .progressPhotos, allowingMint: true)
        }
        try service.openWithoutPasscode(for: .privateHub, allowingMint: true)
        #expect(service.state == .openedWithoutPasscode(scope: .privateHub))
        #expect(service.state.unlockedScope == .privateHub)
        #expect(!service.state.isPasscodeConfigured)
        #expect(!service.isLockConfigured, "a tap proves no credential; it must not read as a passcode")
        #expect(service.contentKey(for: .privateHub) != nil)
        #expect(service.contentKey(for: .progressPhotos) == nil)
        #expect(service.contentKey(for: .appLockSettings) == nil)

        for close in [FernletLockReason.background, .manual, .viewDisappeared] {
            service.lock(reason: close)
            #expect(service.state == .notConfigured)
            #expect(!service.hasResidentContentKey, "\(close) left the key resident")
            try service.openWithoutPasscode(for: .privateHub, allowingMint: false)
        }
        service.revokeUnlockOutside(.progressPhotos)
        #expect(service.state == .notConfigured, "a foreign surface arriving must close the tap session")
        #expect(!service.hasResidentContentKey)
    }

    /// The key minted at the first tap is the key every later tap opens — in this launch and the
    /// next — and a second tap never mints again.
    @Test func theMintedDeviceKeyIsTheOneEveryLaterTapOpens() throws {
        let fixture = DeviceCustodyFixture()
        defer { fixture.cleanup() }
        let first = fixture.makeService()
        #expect(throws: FernletLockError.deviceKeyAbsent) {
            try first.openWithoutPasscode(for: .privateHub, allowingMint: false)
        }
        #expect(fixture.row(.deviceContentKey) == nil, "no mint without allowingMint")

        try first.openWithoutPasscode(for: .privateHub, allowingMint: true)
        let minted = try #require(hubKeyBytes(first))
        let storedRow = try #require(fixture.row(.deviceContentKey))
        first.lock(reason: .manual)
        try first.openWithoutPasscode(for: .privateHub, allowingMint: true)
        #expect(hubKeyBytes(first) == minted)
        #expect(fixture.row(.deviceContentKey) == storedRow, "a second tap must never re-mint")

        let relaunched = fixture.makeService()
        #expect(relaunched.state == .notConfigured)
        try relaunched.openWithoutPasscode(for: .privateHub, allowingMint: false)
        #expect(hubKeyBytes(relaunched) == minted)
    }

    /// `refreshStateFromKeychain` is a no-op while the tap session holds, like a passcode unlock.
    @Test func refreshingFromTheKeychainNeverClosesATapSession() throws {
        let fixture = DeviceCustodyFixture()
        defer { fixture.cleanup() }
        let service = fixture.makeService()
        try service.openWithoutPasscode(for: .privateHub, allowingMint: true)
        service.refreshStateFromKeychain()
        #expect(service.state == .openedWithoutPasscode(scope: .privateHub))
        #expect(service.hasResidentContentKey)
    }

    // MARK: - I7: the device row's at-rest format

    /// Where an enclave exists the row is `FDS1` and nothing else; where none does it is `FDR1`
    /// holding the raw key; and a wrap that fails persists NOTHING rather than falling back.
    @Test func theDeviceRowIsEnclaveWrappedWhereverAnEnclaveExists() throws {
        let withEnclave = DeviceCustodyFixture(enclaveAvailable: true)
        defer { withEnclave.cleanup() }
        try withEnclave.makeService().openWithoutPasscode(for: .privateHub, allowingMint: true)
        let wrapped = try #require(withEnclave.row(.deviceContentKey))
        #expect(wrapped.starts(with: Data("FDS1".utf8)))
        #expect(LockWrapFormatCensus.inspectDeviceCustody(service: withEnclave.harness.serviceID) == .enclaveWrapped)

        let noEnclave = DeviceCustodyFixture(enclaveAvailable: false)
        defer { noEnclave.cleanup() }
        let rawService = noEnclave.makeService()
        try rawService.openWithoutPasscode(for: .privateHub, allowingMint: true)
        let raw = try #require(noEnclave.row(.deviceContentKey))
        #expect(raw == Data("FDR1".utf8) + (hubKeyBytes(rawService) ?? Data()))
        #expect(LockWrapFormatCensus.inspectDeviceCustody(service: noEnclave.harness.serviceID) == .raw)

        let refusing = DeviceCustodyFixture(enclaveAvailable: true)
        defer { refusing.cleanup() }
        refusing.enclave.refusesToWrap = true
        let service = refusing.makeService()
        #expect(throws: FernletLockError.contentKeyTemporarilyUnavailable(status: errSecNotAvailable)) {
            try service.openWithoutPasscode(for: .privateHub, allowingMint: true)
        }
        #expect(refusing.row(.deviceContentKey) == nil, "a failed enclave wrap must persist nothing, never FDR1")
        #expect(service.state == .notConfigured)
    }

    /// An `FDR1` row found on enclave hardware (a simulator-to-device restore, an older build) opens
    /// AND is upgraded in place to an `FDS1` row that opens to the same key.
    @Test func aRawRowOnEnclaveHardwareIsUpgradedInPlace() throws {
        let fixture = DeviceCustodyFixture(enclaveAvailable: true)
        defer { fixture.cleanup() }
        let key = Data(repeating: 0x42, count: 32)
        #expect(KeychainItem.store(Data("FDR1".utf8) + key, for: .deviceContentKey,
                                   service: fixture.harness.serviceID) == errSecSuccess)
        let service = fixture.makeService()
        try service.openWithoutPasscode(for: .privateHub, allowingMint: false)
        #expect(hubKeyBytes(service) == key)
        let upgraded = try #require(fixture.row(.deviceContentKey))
        #expect(upgraded.starts(with: Data("FDS1".utf8)), "the raw row must be upgraded to FDS1")

        service.lock(reason: .manual)
        let relaunched = fixture.makeService()
        try relaunched.openWithoutPasscode(for: .privateHub, allowingMint: false)
        #expect(hubKeyBytes(relaunched) == key, "the upgraded row must open to the same key")
    }

    /// Terminal and transient enclave failures stay distinct, an unknown marker is retryable, and
    /// none of them mints over, rewrites or deletes the row.
    @Test func deviceRowFailuresAreClassifiedAndNeverMintedOver() throws {
        let cases: [(SecureEnclaveContentKeyWrap.UnwrapOutcome?, Data?, FernletLockError)] = [
            (.keyAbsent, nil, .contentKeyUnrecoverable),
            (.blobRejected, nil, .contentKeyUnrecoverable),
            (.unavailable(errSecInteractionNotAllowed), nil, .contentKeyTemporarilyUnavailable(status: errSecInteractionNotAllowed)),
            (nil, Data("FDX9 a newer build's format".utf8), .contentKeyTemporarilyUnavailable(status: errSecDecode))
        ]
        for (outcome, plantedRow, expected) in cases {
            let fixture = DeviceCustodyFixture(enclaveAvailable: true)
            defer { fixture.cleanup() }
            if let plantedRow {
                #expect(KeychainItem.store(plantedRow, for: .deviceContentKey, service: fixture.harness.serviceID) == errSecSuccess)
            } else {
                try fixture.makeService().openWithoutPasscode(for: .privateHub, allowingMint: true)
            }
            let before = try #require(fixture.row(.deviceContentKey))
            fixture.enclave.forcedUnwrapOutcome = outcome
            let service = fixture.makeService()
            #expect(throws: expected) {
                try service.openWithoutPasscode(for: .privateHub, allowingMint: true)
            }
            #expect(fixture.row(.deviceContentKey) == before, "\(expected) must leave the row exactly as it was")
            #expect(service.state == .notConfigured)
        }
    }

    // MARK: - I8: the mint-safety proof

    /// With the device row absent, ANY present key-bearing row refuses the mint as an inconsistency
    /// and any unreadable one as a keychain failure — nothing is written either way — and an
    /// unreadable device row is never minted over. The salt-bound residue rows refuse when
    /// unreadable too (their presence is `saltlessResidueIsSweptUnlessAPreSplitVerifierOpensIt`'s).
    @Test func theMintSafetyProofRefusesEveryKeyBearingRow() throws {
        for key in FernletLockService.mintSafetyRows {
            let fixture = DeviceCustodyFixture()
            defer { fixture.cleanup() }
            let service = fixture.makeService()
            #expect(KeychainItem.store(Data([0x01]), for: key, service: fixture.harness.serviceID) == errSecSuccess)
            #expect(throws: FernletLockError.deviceCustodyInconsistent, "\(key.rawValue) present must refuse the mint") {
                try service.openWithoutPasscode(for: .privateHub, allowingMint: true)
            }
            #expect(fixture.row(.deviceContentKey) == nil)
        }
        for key in FernletLockService.mintSafetyRows + FernletLockService.saltBoundResidueRows + [.deviceContentKey] {
            let fixture = DeviceCustodyFixture()
            defer { fixture.cleanup() }
            let service = fixture.makeService(unreadableRows: [key: errSecInteractionNotAllowed])
            #expect(throws: FernletLockError.self, "\(key.rawValue) unreadable must refuse the mint") {
                try service.openWithoutPasscode(for: .privateHub, allowingMint: true)
            }
            #expect(fixture.row(.deviceContentKey) == nil, "\(key.rawValue) unreadable: nothing may be minted")
            #expect(!service.hasResidentContentKey)
        }
    }

    /// A verifier and a scrypt wrap with NO salt open nothing — the verifier is a digest of a key
    /// only the salt re-derives — so they are residue: the tap mints over them and its sweep
    /// deletes them (review C-U1-R2). The one exception is a PRE-SPLIT verifier, which stored the
    /// raw wrapping key itself; the proof tries it, and one that opens the wrap (or one this build
    /// cannot try against a retired wrap format) refuses both fresh-key routes with nothing written.
    @Test func saltlessResidueIsSweptUnlessAPreSplitVerifierOpensIt() async throws {
        let key = Data(repeating: 0x5A, count: 32)
        let derived = Data(repeating: 0xD1, count: 32)
        let dead = DeviceCustodyFixture()
        defer { dead.cleanup() }
        let deadWrap = try dead.harness.crypto.wrapContentKey(key, using: derived)
        dead.plant(.verifier, FernletLockCrypto.verifierDigest(of: derived))
        dead.plant(.wrappedContentKey, deadWrap)
        let tapping = dead.makeService()
        #expect(tapping.state == .notConfigured)
        #expect(try tapping.checkFreshKeyMintIsSafe(forPasscodeSetup: false) == .noEarlierKeySurvives)
        #expect(try tapping.checkFreshKeyMintIsSafe(forPasscodeSetup: true) == .noEarlierKeySurvives)
        try tapping.openWithoutPasscode(for: .privateHub, allowingMint: true)
        #expect(tapping.state == .openedWithoutPasscode(scope: .privateHub))
        #expect(dead.row(.verifier) == nil && dead.row(.wrappedContentKey) == nil, "the tap's sweep must clear the residue")
        #expect(dead.row(.deviceContentKey) != nil)

        let legacyWraps: [(String, (DeviceCustodyFixture) throws -> Data)] = [
            ("a pre-split verifier that opens the wrap", { try $0.harness.crypto.wrapContentKey(key, using: derived) }),
            ("a retired wrap this build cannot try", { $0.harness.crypto.makeLegacyWrap(contentKey: key, wrappingKey: derived) })
        ]
        for (label, makeWrap) in legacyWraps {
            let live = DeviceCustodyFixture()
            defer { live.cleanup() }
            let wrap = try makeWrap(live)
            live.plant(.verifier, derived)
            live.plant(.wrappedContentKey, wrap)
            let service = live.makeService()
            for forPasscodeSetup in [false, true] {
                #expect(throws: FernletLockError.deviceCustodyInconsistent, "\(label): the read-only check must refuse") {
                    try service.checkFreshKeyMintIsSafe(forPasscodeSetup: forPasscodeSetup)
                }
            }
            #expect(throws: FernletLockError.deviceCustodyInconsistent, "\(label): the tap must refuse") {
                try service.openWithoutPasscode(for: .privateHub, allowingMint: true)
            }
            await #expect(throws: FernletLockError.deviceCustodyInconsistent, "\(label): setup must refuse") {
                try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
            }
            #expect(live.row(.verifier) == derived && live.row(.wrappedContentKey) == wrap, "\(label): the rows must survive")
            #expect(live.row(.deviceContentKey) == nil && live.row(.salt) == nil)
        }
    }

    /// The read-only fresh-key check answers `.noEarlierKeySurvives` — the one answer the open
    /// coordinator's "can't be opened" card may rest on — only while no key can be reached from this
    /// iPhone (review N-U1-1). A device row (it holds the key: nothing is minted, nothing is dead), a
    /// salt (a passcode lock may hold it), or a device row or recovery row that will not answer
    /// refuses it on BOTH routes, and the check writes nothing whatever it answers.
    @Test func theReadOnlyCheckNeverClearsTheCardWhileAKeyMayBeReachable() throws {
        let clean = DeviceCustodyFixture()
        defer { clean.cleanup() }
        let opened = DeviceCustodyFixture()
        defer { opened.cleanup() }
        let tapping = opened.makeService()
        try tapping.openWithoutPasscode(for: .privateHub, allowingMint: true)
        tapping.lock(reason: .manual)
        let deviceRow = try #require(opened.row(.deviceContentKey))
        let salted = DeviceCustodyFixture()
        defer { salted.cleanup() }
        salted.plant(.salt, Data(repeating: 0x5A, count: FernletLockCrypto.saltLength))
        let unanswered: [(LockKeychainKey, String)] = [
            (.deviceContentKey, "read \(LockKeychainKey.deviceContentKey.rawValue)"),
            (.recoveryBlob, "read recovery material")
        ]

        for forPasscodeSetup in [false, true] {
            #expect(try clean.makeService().checkFreshKeyMintIsSafe(forPasscodeSetup: forPasscodeSetup) == .noEarlierKeySurvives)
            #expect(throws: FernletLockError.deviceCustodyInconsistent, "a device row holds the key (setup: \(forPasscodeSetup))") {
                try opened.makeService().checkFreshKeyMintIsSafe(forPasscodeSetup: forPasscodeSetup)
            }
            #expect(throws: FernletLockError.deviceCustodyInconsistent, "a salt: a passcode lock may hold the key (setup: \(forPasscodeSetup))") {
                try salted.makeService().checkFreshKeyMintIsSafe(forPasscodeSetup: forPasscodeSetup)
            }
            for (row, operation) in unanswered {
                let service = clean.makeService(unreadableRows: [row: errSecInteractionNotAllowed])
                #expect(throws: FernletLockError.keychainFailure(operation: operation, status: errSecInteractionNotAllowed),
                        "\(row.rawValue) unreadable (setup: \(forPasscodeSetup))") {
                    try service.checkFreshKeyMintIsSafe(forPasscodeSetup: forPasscodeSetup)
                }
            }
        }
        #expect(opened.row(.deviceContentKey) == deviceRow, "the check changed the device row")
        #expect(clean.row(.deviceContentKey) == nil && clean.row(.salt) == nil, "the check wrote a row")
    }

    /// A fresh passcode setup (no device row) never mints over a copy of an old key that opens
    /// WITHOUT the salt (review L-U1-R1): the mint's pre-deletes would destroy the last copy of a
    /// key that still opens every entry sealed under it. Planted row by row, and then the real
    /// shape — a hard-bound lock that lost only its salt keeps its key in the enclave wrap.
    @Test func aFreshSetupNeverMintsOverASaltIndependentKeyCopy() async throws {
        for row in FernletLockService.saltIndependentKeyCopyRows {
            let fixture = DeviceCustodyFixture()
            defer { fixture.cleanup() }
            fixture.plant(row, Data([0x0C]))
            let service = fixture.makeService()
            await #expect(throws: FernletLockError.deviceCustodyInconsistent, "\(row.rawValue) must refuse setup") {
                try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
            }
            #expect(fixture.row(row) == Data([0x0C]), "\(row.rawValue) must survive the refused setup")
            #expect(fixture.row(.salt) == nil && fixture.row(.verifier) == nil)
        }
        guard SecureEnclaveContentKeyWrap.isAvailable else { return }
        let fixture = DeviceCustodyFixture()
        defer { fixture.cleanup() }
        let first = fixture.makeService()
        try await first.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        let key = try #require(hubKeyBytes(first))
        let enclaveCopy = try #require(fixture.row(.seWrappedContentKey), "precondition: born hard-bound on this host")
        KeychainItem.delete(for: .salt, service: fixture.harness.serviceID)
        let saltLost = fixture.makeService()
        #expect(saltLost.state == .notConfigured)
        await #expect(throws: FernletLockError.deviceCustodyInconsistent) {
            try await saltLost.configure(credential: .pin6("654321"), grantingScope: .privateHub)
        }
        #expect(fixture.row(.seWrappedContentKey) == enclaveCopy, "setup destroyed the only copy of a live key")
        #expect(SecureEnclaveContentKeyWrap.unwrapResult(enclaveCopy, service: fixture.harness.serviceID) == .recovered(key))
    }

    // MARK: - I9: adding and removing a passcode keep ONE key

    /// Tap → add a passcode → unlock → remove it → tap: the same key at every step, and an entry
    /// sealed before the first step opens after the last. The device row is retired once the new
    /// passcode custody is proven, and comes back when the passcode goes.
    @Test func addingThenRemovingAPasscodeKeepsTheSameKey() async throws {
        let fixture = DeviceCustodyFixture()
        defer { fixture.cleanup() }
        let service = fixture.makeService()
        try service.openWithoutPasscode(for: .privateHub, allowingMint: true)
        let original = try #require(hubKeyBytes(service))
        let sealedEntry = try DeviceCustodyFixture.seal("sealed before", under: SymmetricKey(data: original))
        service.lock(reason: .manual)

        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub, acknowledgedPriorData: false)
        #expect(service.state == .unlocked(scope: .privateHub))
        #expect(hubKeyBytes(service) == original, "setup must ADOPT the device key, not mint")
        #expect(fixture.row(.deviceContentKey) == nil, "the proven passcode custody retires the device row")

        service.lock(reason: .manual)
        _ = try await service.unlock(passcode: "123456", for: .privateHub)
        #expect(hubKeyBytes(service) == original)

        try await service.removeCredential(current: "123456")
        #expect(service.state == .notConfigured)
        #expect(!service.hasResidentContentKey)
        #expect(!service.passcodeUnlockedThisProcess && !service.passcodeVerifiedThisProcess)
        for key in [LockKeychainKey.salt] + FernletLockService.passcodeRowsAfterRecovery where key != .biometricBypass {
            #expect(fixture.row(key) == nil, "\(key.rawValue) survived the removal")
        }
        try service.openWithoutPasscode(for: .privateHub, allowingMint: false)
        let reopened = try #require(hubKeyBytes(service))
        #expect(reopened == original)
        #expect(DeviceCustodyFixture.open(sealedEntry, under: SymmetricKey(data: reopened)) == "sealed before")
    }

    /// A wrong passcode removes nothing: the attempt is counted like any failed unlock, the lock is
    /// intact, and no device row is written. With no passcode at all the call is `.notConfigured`.
    @Test func removingWithAWrongPasscodeChangesNothingButTheAttemptCount() async throws {
        let fixture = DeviceCustodyFixture()
        defer { fixture.cleanup() }
        let service = fixture.makeService()
        await #expect(throws: FernletLockError.notConfigured) {
            try await service.removeCredential(current: "123456")
        }
        try await service.configure(credential: .pin6("123456"), grantingScope: .appLockSettings)
        let salt = try #require(fixture.row(.salt))

        await #expect(throws: FernletLockError.invalidPasscode) {
            try await service.removeCredential(current: "000000")
        }
        #expect(service.currentAttemptCount == 1)
        #expect(fixture.row(.salt) == salt)
        #expect(fixture.row(.deviceContentKey) == nil)
        #expect(service.state.isPasscodeConfigured)
    }

    // MARK: - I24: the owner check before adoption

    /// Adopting a device key that already seals entries needs the device owner: a failed check
    /// writes NOTHING and keeps the key reachable by tap; a passing one (or an iPhone with no
    /// passcode, audited) proceeds. With no entries there is nothing to take, and no check runs.
    @Test func adoptingOverSealedEntriesRequiresTheDeviceOwner() async throws {
        let fixture = DeviceCustodyFixture()
        defer { fixture.cleanup() }
        let opener = fixture.makeService()
        try opener.openWithoutPasscode(for: .privateHub, allowingMint: true)
        let key = try #require(hubKeyBytes(opener))
        try fixture.plantSealedRow(sealedUnder: SymmetricKey(data: key))
        opener.lock(reason: .manual)

        let refused = ScriptedDeviceOwnerVerifier(answer: .failed)
        let service = fixture.makeService(owner: refused)
        await #expect(throws: FernletLockError.ownerVerificationFailed) {
            try await service.configure(credential: .pin6("123456"), grantingScope: .appLockSettings, acknowledgedPriorData: false)
        }
        #expect(refused.callCount == 1)
        for row in [LockKeychainKey.salt, .verifier, .kind, .scryptN, .wrappedContentKey] {
            #expect(fixture.row(row) == nil, "a refused owner check wrote \(row.rawValue)")
        }
        #expect(service.state == .notConfigured)
        try service.openWithoutPasscode(for: .privateHub, allowingMint: false)
        #expect(hubKeyBytes(service) == key, "the device key must still open by tap")
        service.lock(reason: .manual)

        for answer in [DeviceOwnerVerification.verified, .passcodeNotSet] {
            let owner = ScriptedDeviceOwnerVerifier(answer: answer)
            let adopting = fixture.makeService(owner: owner)
            try await adopting.configure(credential: .pin6("123456"), grantingScope: .privateHub, acknowledgedPriorData: false)
            #expect(owner.callCount == 1)
            #expect(hubKeyBytes(adopting) == key, "\(answer): the adopted key must be the device key")
            try await adopting.removeCredential(current: "123456")
        }
    }

    /// With no device row, a fresh key over sealed entries waits for the caller's acknowledgement
    /// (nothing written); the legacy two-argument setup keeps today's behaviour; and an unreadable
    /// device row refuses setup outright.
    @Test func aFreshKeyOverSealedEntriesNeedsTheAcknowledgement() async throws {
        let fixture = DeviceCustodyFixture()
        defer { fixture.cleanup() }
        try fixture.plantSealedRow(sealedUnder: SymmetricKey(data: Data(repeating: 9, count: 32)))
        let service = fixture.makeService()
        await #expect(throws: FernletLockError.priorSealedDataPending) {
            try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub, acknowledgedPriorData: false)
        }
        #expect(fixture.row(.salt) == nil && fixture.row(.verifier) == nil)

        let unreadable = fixture.makeService(unreadableRows: [.deviceContentKey: errSecInteractionNotAllowed])
        await #expect(throws: FernletLockError.keychainFailure(operation: "read device custody", status: errSecInteractionNotAllowed)) {
            try await unreadable.configure(credential: .pin6("123456"), grantingScope: .privateHub, acknowledgedPriorData: true)
        }
        #expect(fixture.row(.salt) == nil)

        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        #expect(service.state == .unlocked(scope: .privateHub), "the two-argument setup keeps today's behaviour")
    }

    // MARK: - §4.6: the shared derivation

    /// A salt beside an incomplete passcode custody and a live device row is an interrupted
    /// transition: it reads `.notConfigured`, the tap opens the device key, and the sweep deletes
    /// the salt and every leftover. Without the device row the same rows stay `.locked`.
    @Test func anInterruptedTransitionReadsNotConfiguredAndTheTapSweepsIt() throws {
        let fixture = DeviceCustodyFixture()
        defer { fixture.cleanup() }
        let opener = fixture.makeService()
        try opener.openWithoutPasscode(for: .privateHub, allowingMint: true)
        let key = try #require(hubKeyBytes(opener))
        opener.lock(reason: .manual)
        for leftover in [LockKeychainKey.salt, .kind, .scryptN, .duressSalt, .recoveryBlob] {
            #expect(KeychainItem.store(Data([0x07]), for: leftover, service: fixture.harness.serviceID) == errSecSuccess)
        }

        let relaunched = fixture.makeService()
        #expect(relaunched.state == .notConfigured)
        #expect(relaunched.interruptedTransitionPending)
        try relaunched.openWithoutPasscode(for: .privateHub, allowingMint: false)
        #expect(hubKeyBytes(relaunched) == key)
        for leftover in [LockKeychainKey.salt, .kind, .scryptN, .duressSalt, .recoveryBlob] {
            #expect(fixture.row(leftover) == nil, "the sweep left \(leftover.rawValue)")
        }
        #expect(!relaunched.interruptedTransitionPending)
        #expect(fixture.row(.deviceContentKey) != nil, "the sweep must never touch the device row")

        let noDeviceRow = DeviceCustodyFixture()
        defer { noDeviceRow.cleanup() }
        #expect(KeychainItem.store(Data([0x07]), for: .salt, service: noDeviceRow.harness.serviceID) == errSecSuccess)
        #expect(noDeviceRow.makeService().state == .locked(cooldownDeadline: nil))
    }

    // MARK: - I6: fault injection and process death at every step

    /// Every keychain write and delete of an ADOPTION, refused one at a time and then "the process
    /// died" after each: the state the next launch derives always opens the SAME key by its own
    /// route — the tap when no passcode was committed, the passcode when one was.
    @Test func anAdoptionInterruptedAtEveryStepNeverStrandsTheKey() async throws {
        let operations = try await countOperations { fixture, keychain in
            try await Self.adopt(fixture, keychain: keychain)
        }
        #expect(operations > 5, "the adoption must be observed doing its writes: \(operations)")
        for index in 0...operations {
            for dying in [false, true] {
                let fixture = DeviceCustodyFixture()
                defer { fixture.cleanup() }
                let key = try Self.mintDeviceKey(fixture)
                let keychain = FaultInjectingKeychain()
                if dying { keychain.dyingAfter = index } else { keychain.failingOperation = index }
                do { try await Self.adopt(fixture, keychain: keychain) } catch { }
                let next = fixture.makeService()
                #expect(try await openHubByItsOwnPath(next, passcode: "123456") == key,
                        "adoption \(dying ? "died after" : "failed at") op \(index): derived \(next.state)")
            }
        }
    }

    /// The same sweep over a passcode REMOVAL: the device row is written and proven before the salt
    /// (the commit point) goes, so no step can leave the key unreachable.
    @Test func aRemovalInterruptedAtEveryStepNeverStrandsTheKey() async throws {
        let operations = try await countOperations { fixture, keychain in
            try await fixture.makeService(keychain: keychain).removeCredential(current: "123456")
        } prepare: { fixture in
            _ = try Self.mintDeviceKey(fixture)
            try await Self.adopt(fixture, keychain: nil)
        }
        #expect(operations > 10, "the removal must be observed doing its deletes: \(operations)")
        for index in 0...operations {
            for dying in [false, true] {
                let fixture = DeviceCustodyFixture()
                defer { fixture.cleanup() }
                let key = try Self.mintDeviceKey(fixture)
                try await Self.adopt(fixture, keychain: nil)
                let keychain = FaultInjectingKeychain()
                if dying { keychain.dyingAfter = index } else { keychain.failingOperation = index }
                do { try await fixture.makeService(keychain: keychain).removeCredential(current: "123456") } catch { }
                let next = fixture.makeService()
                #expect(try await openHubByItsOwnPath(next, passcode: "123456") == key,
                        "removal \(dying ? "died after" : "failed at") op \(index): derived \(next.state)")
            }
        }
    }

    /// The sweep itself, interrupted at every delete: it runs only with the key already in hand
    /// from the device row and never deletes that row, so every interruption still opens by tap.
    @Test func theSweepInterruptedAtEveryStepNeverStrandsTheKey() async throws {
        let sweepRows = 1 + FernletLockService.recoveryRowsBlobFirst.count + FernletLockService.passcodeRowsAfterRecovery.count
        for index in 0...sweepRows {
            let fixture = DeviceCustodyFixture()
            defer { fixture.cleanup() }
            let key = try Self.mintDeviceKey(fixture)
            try await Self.adopt(fixture, keychain: nil)
            // A removal killed right after its commit point: the device row written, the salt gone,
            // every other passcode row still there (planted, so the fixture does not depend on how
            // many writes precede the commit).
            let service = fixture.harness.serviceID
            let blob = try #require(fixture.enclave.wrapVerified(key, service: service))
            #expect(KeychainItem.store(Data("FDS1".utf8) + blob, for: .deviceContentKey, service: service) == errSecSuccess)
            #expect(KeychainItem.store(Data([0x01]), for: .recoveryBlob, service: service) == errSecSuccess)
            #expect(KeychainItem.store(Data([0x02]), for: .duressVerifier, service: service) == errSecSuccess)
            KeychainItem.delete(for: .salt, service: service)
            #expect(fixture.row(.salt) == nil && fixture.row(.verifier) != nil, "precondition: killed after the commit")

            let sweeping = FaultInjectingKeychain()
            sweeping.dyingAfter = index
            let tapping = fixture.makeService(keychain: sweeping)
            try tapping.openWithoutPasscode(for: .privateHub, allowingMint: false)
            #expect(hubKeyBytes(tapping) == key)
            let next = fixture.makeService()
            #expect(try await openHubByItsOwnPath(next, passcode: "123456") == key, "sweep died after op \(index)")
        }
    }

    /// A FRESH setup (no device row) killed or failed at every write never leaves the
    /// `.locked`-with-no-verifier dead end the salt-first order produced: the next launch either
    /// holds a complete lock the passcode opens, or reads `.notConfigured` — and then BOTH routes
    /// out work: the tap opens (the salt-less residue does not refuse the mint; review C-U1-R2) and
    /// its sweep clears the residue, and a passcode set afterwards adopts the tap's key.
    @Test func aFreshSetupInterruptedAtEveryStepCanAlwaysBeFinishedOrOpened() async throws {
        let operations = try await countOperations { fixture, keychain in
            try await fixture.makeService(keychain: keychain)
                .configure(credential: .pin6("123456"), grantingScope: .privateHub, acknowledgedPriorData: true)
        } prepare: { _ in }
        #expect(operations > 5, "the setup must be observed doing its writes: \(operations)")
        for index in 0...operations {
            for dying in [false, true] {
                let fixture = DeviceCustodyFixture()
                defer { fixture.cleanup() }
                let keychain = FaultInjectingKeychain()
                if dying { keychain.dyingAfter = index } else { keychain.failingOperation = index }
                do {
                    try await fixture.makeService(keychain: keychain)
                        .configure(credential: .pin6("123456"), grantingScope: .privateHub, acknowledgedPriorData: true)
                } catch { }
                let next = fixture.makeService()
                switch next.state {
                case .notConfigured:
                    try next.openWithoutPasscode(for: .privateHub, allowingMint: true)
                    let tapKey = try #require(hubKeyBytes(next), "the tap could not open after op \(index)")
                    for row in [LockKeychainKey.verifier, .kind, .scryptN, .wrappedContentKey] {
                        #expect(fixture.row(row) == nil, "op \(index): the tap's sweep left \(row.rawValue)")
                    }
                    next.lock(reason: .manual)
                    try await next.configure(credential: .pin6("654321"), grantingScope: .privateHub, acknowledgedPriorData: true)
                    #expect(next.state == .unlocked(scope: .privateHub), "setup could not be retried after op \(index)")
                    #expect(hubKeyBytes(next) == tapKey, "op \(index): the retried setup must adopt the tap's key")
                default:
                    _ = try await next.unlock(passcode: "123456", for: .privateHub)
                    #expect(hubKeyBytes(next) != nil, "a salt-bearing lock must open after op \(index)")
                }
            }
        }
    }

    // MARK: - reset

    /// `reset()` fires `onResetCompleted` exactly once, after the state is back to `.notConfigured`,
    /// and takes the device row with the service-wide sweep.
    @Test func resetFiresItsHookOnceAndDestroysTheDeviceRow() throws {
        let fixture = DeviceCustodyFixture()
        defer { fixture.cleanup() }
        let service = fixture.makeService()
        try service.openWithoutPasscode(for: .privateHub, allowingMint: true)
        let firings = ResetHookRecorder()
        service.onResetCompleted = { firings.states.append(service.state) }
        try service.reset()
        #expect(firings.states == [.notConfigured])
        #expect(fixture.row(.deviceContentKey) == nil)
    }

    /// Once `reset()`'s keychain sweep has run the keys are gone, so its tail is owed even when a
    /// later step fails (review C-U1-R1): a buffer file that cannot be removed still leaves the
    /// state `.notConfigured`, the key scrubbed, and the hook fired once — and the failure is
    /// still thrown, after all of that, never swallowed.
    @Test func resetFiresItsHookEvenWhenTheBufferPurgeFails() throws {
        let fixture = DeviceCustodyFixture()
        defer { fixture.cleanup() }
        let service = fixture.makeService()
        try service.openWithoutPasscode(for: .privateHub, allowingMint: true)
        let directory = fixture.harness.narrativeBufferScope.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("held".utf8).write(to: PendingNarrativeBuffer.fileURL(in: directory))
        // A read-only directory: the file inside it cannot be unlinked, so `buffer.purge()` throws.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer {
            do {
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            } catch {
                Issue.record("could not restore the buffer directory's permissions: \(error)")
            }
        }
        let firings = ResetHookRecorder()
        service.onResetCompleted = { firings.states.append(service.state) }

        #expect(throws: (any Error).self, "the purge failure must still be reported") {
            try service.reset()
        }
        #expect(firings.states == [.notConfigured], "the keys are gone, so the hook is owed")
        #expect(service.state == .notConfigured)
        #expect(!service.hasResidentContentKey)
        #expect(fixture.row(.deviceContentKey) == nil)
    }

    // MARK: - Helpers

    /// Mints the device key through a tap, closes the tab again, and returns the key.
    private static func mintDeviceKey(_ fixture: DeviceCustodyFixture) throws -> Data {
        let service = fixture.makeService()
        try service.openWithoutPasscode(for: .privateHub, allowingMint: true)
        let key = try #require(hubKeyBytes(service))
        service.lock(reason: .manual)
        return key
    }

    /// A passcode setup that adopts the device key (no sealed entries, so no owner check).
    private static func adopt(_ fixture: DeviceCustodyFixture, keychain: FaultInjectingKeychain?) async throws {
        try await fixture.makeService(keychain: keychain)
            .configure(credential: .pin6("123456"), grantingScope: .privateHub, acknowledgedPriorData: false)
    }

    /// How many keychain writes + deletes `run` performs on a fresh fixture (after `prepare`).
    private func countOperations(
        _ run: (DeviceCustodyFixture, FaultInjectingKeychain) async throws -> Void,
        prepare: ((DeviceCustodyFixture) async throws -> Void)? = nil
    ) async throws -> Int {
        let fixture = DeviceCustodyFixture()
        defer { fixture.cleanup() }
        if let prepare { try await prepare(fixture) } else { _ = try Self.mintDeviceKey(fixture) }
        let counter = FaultInjectingKeychain()
        try await run(fixture, counter)
        return counter.operationCount
    }
}

/// A reference box for the states `onResetCompleted` observed (a captured `var` cannot be mutated
/// from the main-actor closure the hook takes).
@MainActor
final class ResetHookRecorder {
    /// Every state the hook saw, in order.
    var states: [FernletLockState] = []
}
