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
    /// unreadable device row is never minted over.
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
        for key in FernletLockService.mintSafetyRows + [.deviceContentKey] {
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
    /// reads `.notConfigured` and can set up again, or holds a complete lock the passcode opens.
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
                    try await next.configure(credential: .pin6("654321"), grantingScope: .privateHub, acknowledgedPriorData: true)
                    #expect(next.state == .unlocked(scope: .privateHub), "setup could not be retried after op \(index)")
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
