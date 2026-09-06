// IdentityProvisioningReadTests.swift
// FernletTests
//
// F-1 (P5 close-out, plan §11.3 / §23.4): `IdentityService.ensureProvisioned()` must never mint over
// an identity it could not READ. Before this fix the two identity-row reads went through the
// nil-collapsing `KeychainItem.load`, so a transient keychain error (`errSecInteractionNotAllowed`
// before first unlock, `errSecNotAvailable`, an I/O failure) looked exactly like a fresh device —
// and the mint that followed `KeychainItem.store`s every row delete-then-add, destroying the live
// identity and every trust relationship built on it.
//
// The keychain cannot be made to fail on demand in a test, so the rule lives in a PURE function
// (`classifyDeviceIdentityRows`) over `KeychainItem.ReadResult` values, tabled here; the one path a
// real keychain can drive (a present-but-unparseable row) is driven for real; and a source wall pins
// that the identity rows are never read nil-collapsing again.

import CryptoKit
import Foundation
import Security
import Testing
import FernletFoundation
@testable import ProximityKit

/// The fail-closed identity read: the decision table, the one keychain-drivable path, and the wall.
@MainActor
@Suite(.serialized)
struct IdentityProvisioningReadTests {

    private static let signingRow = "signingPrivateKey"
    private static let keyAgreementRow = "keyAgreementPrivateKey"

    private func makeService() -> (IdentityService, String) {
        let serviceID = "com.fernlet.identity.readtest.\(UUID().uuidString)"
        return (IdentityService(keychainService: serviceID), serviceID)
    }

    // MARK: - The decision table

    /// **The safety property.** An unreadable row wins over every other fact, in every combination —
    /// including the Case-3 trap (signing absent, key-agreement unreadable), where falling through
    /// to the mint would `store(…, replacing: .any)` over the synced legacy row it could not read.
    @Test func anUnreadableRowWinsOverEverything() {
        let signing = Curve25519.Signing.PrivateKey().rawRepresentation
        let keyAgreement = Curve25519.KeyAgreement.PrivateKey().rawRepresentation
        let table: [(KeychainItem.ReadResult, KeychainItem.ReadResult, String, OSStatus)] = [
            (.unreadable(errSecInteractionNotAllowed), .found(keyAgreement), Self.signingRow, errSecInteractionNotAllowed),
            (.found(signing), .unreadable(errSecNotAvailable), Self.keyAgreementRow, errSecNotAvailable),
            (.absent, .unreadable(errSecIO), Self.keyAgreementRow, errSecIO),
            (.unreadable(errSecIO), .absent, Self.signingRow, errSecIO),
            (.unreadable(1), .unreadable(2), Self.signingRow, 1),
            (.found(Data([1, 2, 3])), .unreadable(errSecNotAvailable), Self.keyAgreementRow, errSecNotAvailable)
        ]
        // R2: bounded by the table.
        for (signingRead, keyAgreementRead, row, status) in table {
            let read = IdentityService.classifyDeviceIdentityRows(
                signing: signingRead, keyAgreement: keyAgreementRead
            )
            guard case .unreadable(let gotRow, let gotStatus) = read else {
                Issue.record("\(row) unreadable must refuse to mint, got \(read)")
                continue
            }
            #expect(gotRow == row, "the row named is the first unreadable one")
            #expect(gotStatus == status, "the status is carried verbatim")
        }
    }

    /// Authoritative absence on either row — and nothing unreadable — is the mint's precondition.
    @Test func absenceOnEitherRowFallsThroughToTheMint() {
        let signing = Curve25519.Signing.PrivateKey().rawRepresentation
        let keyAgreement = Curve25519.KeyAgreement.PrivateKey().rawRepresentation
        let table: [(KeychainItem.ReadResult, KeychainItem.ReadResult)] = [
            (.absent, .absent), (.found(signing), .absent), (.absent, .found(keyAgreement)),
            (.absent, .found(Data([9, 9])))
        ]
        // R2: bounded by the table.
        for (signingRead, keyAgreementRead) in table {
            let read = IdentityService.classifyDeviceIdentityRows(
                signing: signingRead, keyAgreement: keyAgreementRead
            )
            guard case .absent = read else {
                Issue.record("absence must fall through to the mint, got \(read)")
                continue
            }
        }
    }

    /// Both rows present and parseable is the identity, byte for byte.
    @Test func bothRowsFoundAndParseableIsTheIdentity() throws {
        let signing = Curve25519.Signing.PrivateKey()
        let keyAgreement = Curve25519.KeyAgreement.PrivateKey()
        let read = IdentityService.classifyDeviceIdentityRows(
            signing: .found(signing.rawRepresentation), keyAgreement: .found(keyAgreement.rawRepresentation)
        )
        guard case .found(let gotSigning, let gotKeyAgreement) = read else {
            Issue.record("two good rows must be the identity, got \(read)")
            return
        }
        #expect(gotSigning.publicKey.rawRepresentation == signing.publicKey.rawRepresentation)
        #expect(gotKeyAgreement.publicKey.rawRepresentation == keyAgreement.publicKey.rawRepresentation)
    }

    /// A row that was READ but is not a key is permanent, so it is absence — but by name, so the
    /// audit line can say which row, and so it is never confused with an unreadable one.
    @Test func aFoundRowWithTheWrongShapeIsUnparseableByName() {
        let signing = Curve25519.Signing.PrivateKey().rawRepresentation
        let keyAgreement = Curve25519.KeyAgreement.PrivateKey().rawRepresentation
        let table: [(KeychainItem.ReadResult, KeychainItem.ReadResult, String)] = [
            (.found(Data([1, 2, 3])), .found(keyAgreement), Self.signingRow),
            (.found(signing), .found(Data(repeating: 0, count: 5)), Self.keyAgreementRow)
        ]
        // R2: bounded by the table.
        for (signingRead, keyAgreementRead, row) in table {
            let read = IdentityService.classifyDeviceIdentityRows(
                signing: signingRead, keyAgreement: keyAgreementRead
            )
            guard case .unparseable(let gotRow) = read else {
                Issue.record("\(row) with the wrong shape must be unparseable by name, got \(read)")
                continue
            }
            #expect(gotRow == row)
        }
    }

    // MARK: - The one path a real keychain can drive

    /// Unparseable identity rows are minted over — the documented behaviour, because the keys they
    /// held can never be used — and the mint says so with the row's name before it writes. Both
    /// rows are planted: with only the signing row present the classification is `.absent` (the
    /// key-agreement row is authoritatively missing), which is the mint's ordinary precondition.
    @Test func anUnparseableRowIsMintedOverAndNamed() throws {
        let (service, id) = makeService()
        defer { KeychainItem.deleteAll(service: id) }
        // R2: bounded by the two rows.
        for row in [Self.signingRow, Self.keyAgreementRow] {
            let planted = KeychainItem.store(
                Data([0xDE, 0xAD, 0xBE, 0xEF]), account: row, service: id,
                accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            )
            #expect(planted == errSecSuccess, "precondition: the garbage row is on the keychain")
        }
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }

        try service.ensureProvisioned()

        #expect(!service.localSigningPublicKey.isEmpty, "the mint went ahead — the old row was unusable")
        #expect(capture.values(of: "identity.keychain.unparseableRow", key: "row").contains(Self.signingRow),
                "the row that was minted over is named before the write")
        let stored = KeychainItem.load(account: Self.signingRow, service: id)
        #expect(stored != Data([0xDE, 0xAD, 0xBE, 0xEF]), "the garbage row was replaced by the mint")
    }

    /// An intact identity is adopted by a second instance and never re-minted — the common case,
    /// unchanged, and the one the fail-closed read must not have broken.
    @Test func anIntactIdentityIsAdoptedNotReminted() throws {
        let (first, id) = makeService()
        defer { KeychainItem.deleteAll(service: id) }
        try first.ensureProvisioned()
        let second = IdentityService(keychainService: id)
        try second.ensureProvisioned()
        #expect(second.localSigningPublicKey == first.localSigningPublicKey)
        #expect(second.localKeyAgreementPublicKey == first.localKeyAgreementPublicKey)
    }

    // MARK: - The wall

    /// Neither identity private-key row is read nil-collapsing anywhere in the service, the
    /// distinguishing read is used for both rows and Case 3's legacy read, and the unreadable arm
    /// throws rather than returns.
    @Test func theIdentityRowsAreNeverReadNilCollapsing() throws {
        let source = try RepoRoot.source("FernletKit/Sources/ProximityKit/Identity/IdentityService.swift")
        // R2: bounded by the two rows.
        for row in [Self.signingRow, Self.keyAgreementRow] {
            #expect(!source.contains("KeychainItem.load(account: IdentityKeychainKey.\(row)"),
                    "\(row) is read with the nil-collapsing load again — a transient error would mint over it")
        }
        let distinguishingReads = source.components(separatedBy: "KeychainItem.loadDistinguishingAbsence(").count - 1
        #expect(distinguishingReads >= 3, "signing, key-agreement and the legacy Case-3 read all distinguish absence")
        #expect(source.components(separatedBy: "throw IdentityError.keychainReadFailed(status)").count - 1 == 2,
                "both fail-closed reads throw, neither returns nil on an error")
        #expect(source.contains("case keychainReadFailed(OSStatus)"), "the error case is named")
    }
}
