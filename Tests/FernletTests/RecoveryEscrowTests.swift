// RecoveryEscrowTests.swift
// FernletTests
//
// G9-2: the recovery code end to end over a real (UUID-scoped) keychain and an in-memory iCloud
// (plan Part 2, "Tests"): sealing on make, sealing a newly minted escrow key without the code,
// recovering on a phone with no escrow key, "Make a new code" revoking the old one, "Check my code"
// accepting the current code and refusing an old or mistyped one without changing anything, and
// every call refused in a duress session.

import CloudKitSync
import CryptoKit
import FernletCrypto
import FernletFoundation
import Foundation
import ProximityKit
import Security
import Testing
@testable import Fernlet

@MainActor
@Suite(.serialized)
struct RecoveryEscrowTests {

    /// One simulated iPhone: its own keychain service and identity.
    @MainActor
    private struct Phone {
        let service: String
        let identity: IdentityService

        init() {
            service = "com.fernlet.identity.recovery.test.\(UUID().uuidString)"
            identity = IdentityService.fernletApp(keychainService: service)
        }

        /// Escrow public keys this phone can open backups with.
        var escrowPublicKeys: Set<Data> {
            Set(identity.sealedBackupKeyCandidates().map(\.publicKey))
        }

        /// Escrow rows on this phone, tagged synced or not.
        var escrowRows: [(account: String, synced: Bool)] {
            KeychainItem.loadAll(service: service, synchronizable: .synced).map(\.account)
                .filter { $0.hasPrefix("backupEscrowPrivateKey") }.map { ($0, true) }
                + KeychainItem.loadAll(service: service, synchronizable: .local).map(\.account)
                .filter { $0.hasPrefix("backupEscrowPrivateKey") }.map { ($0, false) }
        }

        func wipe() { KeychainItem.deleteAll(service: service) }
    }

    private func service(
        _ phone: Phone,
        cloud: InMemoryRecoveryEscrowStore,
        duress: Bool = false,
        backupOn: Bool = false,
        now: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> RecoveryCodeService {
        RecoveryCodeService(cloud: cloud, identityFactory: { phone.identity }, duressActive: { duress },
                            anyBackupEnabled: { backupOn }, now: { now })
    }

    /// A phone with one escrow key minted, as turning a backup on leaves it.
    private func phoneWithBackup() throws -> Phone {
        let phone = Phone()
        try phone.identity.ensureProvisioned()
        #expect(!phone.identity.provisionBackupEscrowKeyForSealing().isEmpty)
        return phone
    }

    /// Adds a second escrow key to a phone's keychain, as an adopted conflict or a fresh mint does.
    private func addEscrowKey(to phone: Phone) -> Curve25519.KeyAgreement.PrivateKey {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let account = IdentityService.escrowKeychainAccount(forPublicKey: key.publicKey.rawRepresentation)
        #expect(KeychainItem.store(key.rawRepresentation, account: account, service: phone.service,
                                   accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                   synchronizable: false, replacing: .local) == errSecSuccess)
        return key
    }

    // MARK: Make

    @Test func makingACodeSealsEveryEscrowKeyToItsPublicKey() async throws {
        let phone = try phoneWithBackup()
        defer { phone.wipe() }
        _ = addEscrowKey(to: phone)
        let cloud = InMemoryRecoveryEscrowStore()

        let code = try await service(phone, cloud: cloud).makeNewCode()

        let records = Array(cloud.recordsByName.values)
        #expect(records.count == 2)
        #expect(records.allSatisfy { $0.recoveryPublicKey == (try? code.recoveryPublicKey()) })
        #expect(Set(records.map(\.escrowPublicKeyHash)) == Set(phone.escrowPublicKeys.map(RecoveryEscrowSeal.escrowPublicKeyHash)))
        #expect(try await service(phone, cloud: cloud).status() == .madeOn(Date(timeIntervalSince1970: 1_800_000_000)))
    }

    @Test func makingACodeWithNoBackupIsRefused() async throws {
        let phone = Phone()
        defer { phone.wipe() }
        let cloud = InMemoryRecoveryEscrowStore()
        await #expect(throws: RecoveryCodeFailure.noBackupKey) { _ = try await service(phone, cloud: cloud).makeNewCode() }
        #expect(cloud.recordsByName.isEmpty)
        #expect(phone.escrowRows.isEmpty, "no switch on: nothing is minted")
    }

    @Test func makingACodeWithABackupOnButNoUploadYetMintsTheKeyDeviceOnly() async throws {
        let phone = Phone()
        defer { phone.wipe() }
        let cloud = InMemoryRecoveryEscrowStore()
        _ = try await service(phone, cloud: cloud, backupOn: true).makeNewCode()
        #expect(cloud.recordsByName.count == 1)
        #expect(phone.escrowRows.count == 1 && phone.escrowRows.allSatisfy { !$0.synced }, "WS-2: minted device-only")
    }

    // MARK: Keeping it current without the code

    @Test func aNewEscrowKeyIsSealedWithoutTheCode() async throws {
        let phone = try phoneWithBackup()
        defer { phone.wipe() }
        let cloud = InMemoryRecoveryEscrowStore()
        let code = try await service(phone, cloud: cloud).makeNewCode()
        #expect(try await service(phone, cloud: cloud).sealNewEscrowKeys() == 0, "nothing new yet")

        let added = addEscrowKey(to: phone)
        let later = Date(timeIntervalSince1970: 1_900_000_000)
        #expect(try await service(phone, cloud: cloud, now: later).sealNewEscrowKeys() == 1)

        let records = Array(cloud.recordsByName.values)
        #expect(records.count == 2)
        #expect(records.allSatisfy { $0.codeMadeAt == Date(timeIntervalSince1970: 1_800_000_000) }, "the code's date, not the seal's")
        #expect(records.contains { $0.escrowPublicKeyHash == RecoveryEscrowSeal.escrowPublicKeyHash(added.publicKey.rawRepresentation) })
        #expect(records.allSatisfy { $0.recoveryPublicKey == (try? code.recoveryPublicKey()) })
    }

    @Test func noCodeMeansNothingIsSealed() async throws {
        let phone = try phoneWithBackup()
        defer { phone.wipe() }
        let cloud = InMemoryRecoveryEscrowStore()
        #expect(try await service(phone, cloud: cloud).sealNewEscrowKeys() == 0)
        #expect(cloud.recordsByName.isEmpty)
    }

    // MARK: Recover

    @Test func aPhoneWithoutTheKeyRecoversItWithTheCode() async throws {
        let phoneA = try phoneWithBackup()
        defer { phoneA.wipe() }
        let second = addEscrowKey(to: phoneA)
        let cloud = InMemoryRecoveryEscrowStore()
        let code = try await service(phoneA, cloud: cloud).makeNewCode()
        let words = code.words.joined(separator: " ")

        let phoneB = Phone()
        defer { phoneB.wipe() }
        try phoneB.identity.ensureProvisioned()
        #expect(!phoneB.identity.loadBackupEscrowKeyForOpen(), "iCloud Keychain lost: no key here")

        let stored = try await service(phoneB, cloud: cloud).recover(with: try RecoveryCode(typing: words))

        #expect(stored == 2)
        #expect(phoneB.escrowPublicKeys == phoneA.escrowPublicKeys)
        #expect(phoneB.escrowPublicKeys.contains(second.publicKey.rawRepresentation))
        #expect(phoneB.identity.loadBackupEscrowKeyForOpen())
        #expect(phoneB.escrowRows.count == 2 && phoneB.escrowRows.allSatisfy { !$0.synced },
                "recovered keys are ThisDeviceOnly; a later launch's reconcile publishes them")
    }

    @Test func recoveringTwiceStoresNothingNew() async throws {
        let phoneA = try phoneWithBackup()
        defer { phoneA.wipe() }
        let cloud = InMemoryRecoveryEscrowStore()
        let code = try await service(phoneA, cloud: cloud).makeNewCode()
        let phoneB = Phone()
        defer { phoneB.wipe() }
        #expect(try await service(phoneB, cloud: cloud).recover(with: code) == 1)
        #expect(try await service(phoneB, cloud: cloud).recover(with: code) == 1)
        #expect(phoneB.escrowRows.count == 1)
    }

    @Test func recoveringWithNoCodeSetUpSaysSo() async throws {
        let phone = Phone()
        defer { phone.wipe() }
        await #expect(throws: RecoveryCodeFailure.noCodeSetUp) {
            _ = try await service(phone, cloud: InMemoryRecoveryEscrowStore()).recover(with: try RecoveryCode.generate())
        }
    }

    // MARK: Make a new code

    @Test func aNewCodeRevokesTheOldOne() async throws {
        let phoneA = try phoneWithBackup()
        defer { phoneA.wipe() }
        let cloud = InMemoryRecoveryEscrowStore()
        let old = try await service(phoneA, cloud: cloud).makeNewCode()
        let new = try await service(phoneA, cloud: cloud, now: Date(timeIntervalSince1970: 1_900_000_000)).makeNewCode()

        #expect(cloud.recordsByName.values.allSatisfy { $0.recoveryPublicKey == (try? new.recoveryPublicKey()) })
        let phoneB = Phone()
        defer { phoneB.wipe() }
        await #expect(throws: RecoveryCodeFailure.codeDoesNotMatch) {
            _ = try await service(phoneB, cloud: cloud).recover(with: old)
        }
        #expect(phoneB.escrowRows.isEmpty)
        #expect(try await service(phoneB, cloud: cloud).recover(with: new) == 1)
    }

    @Test func aRevokeThatDidNotLandIsFinishedByTheNextTopUp() async throws {
        let phone = try phoneWithBackup()
        defer { phone.wipe() }
        let cloud = InMemoryRecoveryEscrowStore()
        let old = try await service(phone, cloud: cloud).makeNewCode()
        let oldRecords = Array(cloud.recordsByName.values)
        let new = try await service(phone, cloud: cloud, now: Date(timeIntervalSince1970: 1_900_000_000)).makeNewCode()
        // The old code's records come back, as if the revoke's delete never reached iCloud.
        try await cloud.saveRecoveryEscrowRecords(oldRecords)
        #expect(try await service(phone, cloud: cloud).check(new) == .matches, "the newest code is current")

        _ = try await service(phone, cloud: cloud).sealNewEscrowKeys()

        #expect(cloud.recordsByName.values.allSatisfy { $0.recoveryPublicKey == (try? new.recoveryPublicKey()) })
        #expect(try await service(phone, cloud: cloud).check(old) == .doesNotMatch)
    }

    // MARK: Check my code

    @Test func checkMyCodeAcceptsTheCurrentCodeAndRefusesAnOldOneWithoutChangingAnything() async throws {
        let phoneA = try phoneWithBackup()
        defer { phoneA.wipe() }
        let cloud = InMemoryRecoveryEscrowStore()
        let old = try await service(phoneA, cloud: cloud).makeNewCode()
        let current = try await service(phoneA, cloud: cloud, now: Date(timeIntervalSince1970: 1_900_000_000)).makeNewCode()
        let before = cloud.recordsByName
        let phoneB = Phone()
        defer { phoneB.wipe() }

        #expect(try await service(phoneB, cloud: cloud).check(current) == .matches)
        #expect(try await service(phoneB, cloud: cloud).check(old) == .doesNotMatch)
        #expect(try await service(phoneB, cloud: cloud).check(try RecoveryCode.generate()) == .doesNotMatch)

        #expect(cloud.recordsByName == before, "checking stores nothing")
        #expect(phoneB.escrowRows.isEmpty, "checking restores nothing")
    }

    @Test func aMistypedCodeIsCaughtBeforeAnythingIsTried() throws {
        let code = try RecoveryCode(entropy: Data(repeating: 0x7f, count: 16))
        var words = code.words
        words[0] = words[1]
        #expect(throws: RecoveryCodeError.checksumMismatch) { try RecoveryCode(typing: words.joined(separator: " ")) }
    }

    @Test func checkingWithNoCodeSetUpSaysSo() async throws {
        let phone = Phone()
        defer { phone.wipe() }
        #expect(try await service(phone, cloud: InMemoryRecoveryEscrowStore()).check(try RecoveryCode.generate()) == .noCodeSetUp)
    }

    // MARK: Duress

    @Test func everyCallIsRefusedInADuressSession() async throws {
        let phone = try phoneWithBackup()
        defer { phone.wipe() }
        let cloud = InMemoryRecoveryEscrowStore()
        let code = try await service(phone, cloud: cloud).makeNewCode()
        let before = cloud.recordsByName
        let decoy = service(phone, cloud: cloud, duress: true)

        await #expect(throws: RecoveryCodeFailure.refusedInDuress) { _ = try await decoy.status() }
        await #expect(throws: RecoveryCodeFailure.refusedInDuress) { _ = try await decoy.makeNewCode() }
        await #expect(throws: RecoveryCodeFailure.refusedInDuress) { _ = try await decoy.sealNewEscrowKeys() }
        await #expect(throws: RecoveryCodeFailure.refusedInDuress) { _ = try await decoy.recover(with: code) }
        await #expect(throws: RecoveryCodeFailure.refusedInDuress) { _ = try await decoy.check(code) }
        #expect(cloud.recordsByName == before)
    }

    // MARK: The current set

    @Test func theNewestCodeIsCurrentAndTiesPickTheSmallerKey() {
        let early = Date(timeIntervalSince1970: 1), late = Date(timeIntervalSince1970: 2)
        func record(_ key: UInt8, _ at: Date, escrow: UInt8 = 0) -> RecoveryEscrowRecord {
            RecoveryEscrowRecord(recoveryPublicKey: Data(repeating: key, count: 32), escrowPublicKeyHash: Data(repeating: escrow, count: 32),
                                 encapsulatedKey: Data(count: 32), ciphertext: Data(count: 48), codeMadeAt: at)
        }
        #expect(RecoveryCodeService.currentSet(of: []) == nil)
        let newest = RecoveryCodeService.currentSet(of: [record(1, early), record(2, late), record(2, late, escrow: 9)])
        #expect(newest?.publicKey == Data(repeating: 2, count: 32))
        #expect(newest?.escrowHashes.count == 2)
        #expect(RecoveryCodeService.currentSet(of: [record(5, late), record(3, late)])?.publicKey == Data(repeating: 3, count: 32))
        #expect(RecoveryCodeService.currentSet(of: [record(3, late), record(5, late)])?.publicKey == Data(repeating: 3, count: 32))
    }
}
