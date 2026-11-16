// RecoveryCodeGoldenTests.swift
// FernletTests
//
// G9-2: known-answer vectors for the recovery code's whole chain, entropy → words → recovery key
// pair → HPKE-sealed escrow key (plan Part 2, "Threat notes"). These are at-rest format: a code
// written on paper today must open records sealed today on every later build, so a change to the
// word list, the HKDF info, the HPKE suite, info or authenticated data fails here first.

import CryptoKit
import Foundation
import Testing
@testable import FernletCrypto

/// The pinned chain from 16 bytes of entropy to an opened escrow key.
struct RecoveryCodeGoldenTests {
    /// Entropy 00 01 … 0f.
    static let entropyHex = "000102030405060708090a0b0c0d0e0f"
    static let words = "abandon amount liar amount expire adjust cage candy arch gather drum buyer"
    static let recoveryPrivateKeyHex = "29d17297c07507eeeec6390300c5481e027fe71538c6f92b94fd981c94a737b6"
    static let recoveryPublicKeyHex = "0bebfbaff515a31dda0db1c918437eda671432830aa9cc89f7d411fe06b62d4f"
    /// The escrow key sealed in the vector: bytes 20 21 … 3f.
    static let escrowPrivateKeyHex = "202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f"
    static let escrowPublicKeyHex = "358072d6365880d1aeea329adf9121383851ed21a28e3b75e965d0d2cd166254"
    static let escrowPublicKeyHashHex = "a0289810032eb417274eebc4a38e6899b935321d53554e32ec6322f0fa1e724e"
    /// One HPKE seal of the escrow key to the recovery public key (sealing is randomized, so this is
    /// a recorded output; opening it is the pin).
    static let encapsulatedKeyHex = "748c572768124a7d02889fa7c6b1714694d69a449a26101ec5b42502220f1f7d"
    static let ciphertextHex = "48cfe74864267a1ce3c33025b952865e5dea18a8a4059d6a6c1f7a61b971b9c1ce86d64e6827395590ba0d62dfa36f6b"

    private static func data(_ hex: String) -> Data { RecoveryCodeEncodingTests.data(hex: hex) }
    private static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    private static var sealed: RecoveryEscrowSealedKey {
        RecoveryEscrowSealedKey(escrowPublicKeyHash: data(escrowPublicKeyHashHex),
                                encapsulatedKey: data(encapsulatedKeyHex), ciphertext: data(ciphertextHex))
    }

    @Test func theEntropyEncodesToThePinnedWords() throws {
        let code = try RecoveryCode(entropy: Self.data(Self.entropyHex))
        #expect(code.words.joined(separator: " ") == Self.words)
    }

    @Test func theWordsDeriveThePinnedRecoveryKeyPair() throws {
        let code = try RecoveryCode(typing: Self.words)
        let privateKey = try code.recoveryPrivateKey()
        #expect(Self.hex(privateKey.rawRepresentation) == Self.recoveryPrivateKeyHex)
        #expect(Self.hex(try code.recoveryPublicKey()) == Self.recoveryPublicKeyHex)
    }

    @Test func theDerivationIsHKDFUnderItsRegisteredPurpose() throws {
        let code = try RecoveryCode(entropy: Self.data(Self.entropyHex))
        let expected = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Self.data(Self.entropyHex)), salt: Data(),
            info: Data("fernlet.recovery-code.x25519.v1".utf8), outputByteCount: 32
        )
        let derived = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: expected)
        #expect(try code.recoveryPrivateKey().rawRepresentation == derived.rawRepresentation)
        #expect(FernletCryptoPurpose.KeyDerivation.recoveryCodeX25519V1.rawValue == "fernlet.recovery-code.x25519.v1")
        #expect(FernletCryptoPurpose.KeyDerivation.recoveryEscrowHPKEV1.rawValue == "fernlet.recovery-escrow.hpke.v1")
    }

    @Test func theEscrowHashIsSHA256OfItsPublicKey() throws {
        let escrow = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Self.data(Self.escrowPrivateKeyHex))
        #expect(Self.hex(escrow.publicKey.rawRepresentation) == Self.escrowPublicKeyHex)
        #expect(Self.hex(RecoveryEscrowSeal.escrowPublicKeyHash(escrow.publicKey.rawRepresentation)) == Self.escrowPublicKeyHashHex)
    }

    @Test func thePinnedSealOpensToThePinnedEscrowKey() throws {
        let recoveryKey = try RecoveryCode(typing: Self.words).recoveryPrivateKey()
        let opened = try RecoveryEscrowSeal.open(Self.sealed, with: recoveryKey)
        #expect(Self.hex(opened.rawRepresentation) == Self.escrowPrivateKeyHex)
    }

    @Test func thePinnedSealIsBaseModeHPKEWithTheRegisteredInfoAndTheHashAsAAD() throws {
        let recoveryKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Self.data(Self.recoveryPrivateKeyHex))
        var recipient = try HPKE.Recipient(
            privateKey: recoveryKey, ciphersuite: .Curve25519_SHA256_ChachaPoly,
            info: Data("fernlet.recovery-escrow.hpke.v1".utf8), encapsulatedKey: Self.data(Self.encapsulatedKeyHex)
        )
        let raw = try recipient.open(Self.data(Self.ciphertextHex), authenticating: Self.data(Self.escrowPublicKeyHashHex))
        #expect(Self.hex(raw) == Self.escrowPrivateKeyHex)
    }

    @Test func anotherCodeOrTamperedBytesDoNotOpenTheSeal() throws {
        let otherKey = try RecoveryCode(entropy: Data(count: 16)).recoveryPrivateKey()
        #expect(throws: (any Error).self) { try RecoveryEscrowSeal.open(Self.sealed, with: otherKey) }
        let recoveryKey = try RecoveryCode(typing: Self.words).recoveryPrivateKey()
        var aad = Self.data(Self.escrowPublicKeyHashHex)
        aad[0] ^= 1
        let renamed = RecoveryEscrowSealedKey(escrowPublicKeyHash: aad, encapsulatedKey: Self.data(Self.encapsulatedKeyHex),
                                              ciphertext: Self.data(Self.ciphertextHex))
        #expect(throws: (any Error).self) { try RecoveryEscrowSeal.open(renamed, with: recoveryKey) }
        var ciphertext = Self.data(Self.ciphertextHex)
        ciphertext[3] ^= 0x80
        let tampered = RecoveryEscrowSealedKey(escrowPublicKeyHash: Self.data(Self.escrowPublicKeyHashHex),
                                               encapsulatedKey: Self.data(Self.encapsulatedKeyHex), ciphertext: ciphertext)
        #expect(throws: (any Error).self) { try RecoveryEscrowSeal.open(tampered, with: recoveryKey) }
    }

    @Test func aFreshSealRoundTripsAndNamesItsKey() throws {
        let escrow = Curve25519.KeyAgreement.PrivateKey()
        let code = try RecoveryCode.generate()
        let sealed = try RecoveryEscrowSeal.seal(escrow, to: try code.recoveryPublicKey())
        #expect(sealed.escrowPublicKeyHash == RecoveryEscrowSeal.escrowPublicKeyHash(escrow.publicKey.rawRepresentation))
        #expect(sealed.encapsulatedKey.count == 32)
        #expect(sealed.ciphertext.count == 32 + 16)
        #expect(try RecoveryEscrowSeal.open(sealed, with: code.recoveryPrivateKey()).rawRepresentation == escrow.rawRepresentation)
    }
}
