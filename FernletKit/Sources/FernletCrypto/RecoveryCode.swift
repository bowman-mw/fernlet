//
//  RecoveryCode.swift
//  FernletCrypto
//
//  The recovery code for Fernlet's sealed backups (G9-2, plan
//  `Docs/G9-Data-Integrity-Recovery-Plan-2026-11-15.md` Part 2): 128 bits of entropy written as
//  12 BIP39 English words, the X25519 recovery key pair derived from them, and the HPKE seal that
//  wraps each sealed-backup escrow private key to the recovery public key. Pure CryptoKit: no
//  keychain, no CloudKit, no storage. The app keeps only the recovery PUBLIC key's sealed outputs
//  in iCloud; the code itself is never stored anywhere.
//

import CryptoKit
import Foundation
import Security

// MARK: - The code

/// A recovery code: 16 bytes of entropy, shown as 12 words with the BIP39 4-bit checksum.
///
/// **What it opens: backups only** (owner call R1 = A). The code derives an X25519 key pair
/// (``recoveryPrivateKey()``); every sealed-backup escrow key is sealed to the public half
/// (``RecoveryEscrowSeal``), so a phone that has lost iCloud Keychain can type the 12 words and
/// reopen its backups. It never unlocks a passcode.
///
/// **Encoding** (BIP39, English list, ``RecoveryCodeWordList``): entropy ‖ the top 4 bits of
/// SHA-256(entropy) = 132 bits, read as twelve 11-bit word indexes, most significant bit first.
/// Fernlet uses only this encoding: not BIP39's PBKDF2 seed, passphrase, or anything wallet-shaped.
///
/// **Typing it back** (``init(typing:)``): case, accents, extra spaces, commas, new lines and
/// numbering ("1." / "1)") are ignored, and any word may be shortened to its first four letters
/// (every BIP39 English word is unique by its first four). A word that is no prefix of a list word
/// is named by its position; a wrong-but-real word is caught by the checksum 15 times in 16.
///
/// The entropy is a value type and cannot be zeroed behind Swift's copies; holders drop it as soon
/// as the key pair is derived (best-effort, as the plan's threat notes say).
public nonisolated struct RecoveryCode: Equatable, Sendable {
    /// Words in every code (owner call R3 = A: 12 words, 128 bits).
    public static let wordCount = 12
    /// Entropy bytes in every code.
    public static let entropyByteCount = 16
    /// Bits each word carries.
    private static let bitsPerWord = 11
    /// Letters that identify a word on their own.
    public static let identifyingPrefixLength = 4

    /// The code's 16 bytes of entropy.
    public let entropy: Data

    /// A code over `entropy`.
    ///
    /// - Parameter entropy: Exactly ``entropyByteCount`` bytes.
    /// - Throws: ``RecoveryCodeError/wrongEntropyLength`` for any other length.
    public init(entropy: Data) throws(RecoveryCodeError) {
        guard entropy.count == Self.entropyByteCount else { throw .wrongEntropyLength }
        self.entropy = Data(entropy)
    }

    /// A fresh code from the system's secure random generator (`SecRandomCopyBytes`).
    ///
    /// - Throws: ``RecoveryCodeError/randomGeneratorFailed`` when the generator refuses.
    public static func generate() throws(RecoveryCodeError) -> RecoveryCode {
        var bytes = [UInt8](repeating: 0, count: entropyByteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, entropyByteCount, &bytes) == errSecSuccess else {
            throw .randomGeneratorFailed
        }
        let code = try RecoveryCode(entropy: Data(bytes))
        // Best-effort: the local buffer holds the entropy too.
        for index in bytes.indices { bytes[index] = 0 }  // R2: 16 iterations.
        return code
    }

    /// The 12 words, in order.
    public var words: [String] {
        let bytes = Self.checksummedBytes(entropy)
        let list = RecoveryCodeWordList.english
        return (0..<Self.wordCount).map { position in  // R2: 12 iterations.
            list[Self.wordIndex(at: position, in: bytes)]
        }
    }

    /// Reads a typed code back.
    ///
    /// - Parameter typed: What the person typed: 12 words (or 4-letter prefixes) in any case, with
    ///   any spacing, commas or numbering.
    /// - Throws: ``RecoveryCodeError/wrongWordCount(_:)``, ``RecoveryCodeError/unknownWord(position:)``
    ///   (1-based) or ``RecoveryCodeError/checksumMismatch``, in that order of checking.
    public init(typing typed: String) throws(RecoveryCodeError) {
        let tokens = Self.tokens(of: typed)
        guard tokens.count == Self.wordCount else { throw .wrongWordCount(tokens.count) }
        var indexes: [Int] = []
        for (offset, token) in tokens.enumerated() {  // R2: 12 iterations.
            guard let index = Self.listIndex(of: token) else { throw .unknownWord(position: offset + 1) }
            indexes.append(index)
        }
        let bytes = Self.bytes(fromWordIndexes: indexes)
        let entropy = Data(bytes.prefix(Self.entropyByteCount))
        guard Self.checksummedBytes(entropy) == bytes else { throw .checksumMismatch }
        try self.init(entropy: entropy)
    }

    /// The X25519 recovery private key: HKDF-SHA256 over the entropy, empty salt, info
    /// ``FernletCryptoPurpose/KeyDerivation/recoveryCodeX25519V1``, 32 bytes.
    ///
    /// Never stored: derived when a code is made (to publish its public half), and when one is
    /// typed back to recover or to check it.
    ///
    /// - Throws: CryptoKit's error if the derived bytes were refused as a key (32 bytes always
    ///   form an X25519 scalar, so this does not happen).
    public func recoveryPrivateKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: entropy),
            salt: Data(),
            info: FernletCryptoPurpose.KeyDerivation.recoveryCodeX25519V1.data,
            outputByteCount: 32
        )
        return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: derived)
    }

    /// The raw X25519 public key of ``recoveryPrivateKey()``: what phones keep and seal to.
    public func recoveryPublicKey() throws -> Data {
        try recoveryPrivateKey().publicKey.rawRepresentation
    }

    // MARK: Encoding

    /// The 17 bytes the words encode: the entropy, then a byte whose top 4 bits are the checksum
    /// (the low 4 bits are padding, always zero, so a decoded set compares byte for byte).
    private static func checksummedBytes(_ entropy: Data) -> [UInt8] {
        let checksum = Array(SHA256.hash(data: entropy))[0] & 0xF0
        return Array(entropy) + [checksum]
    }

    /// The 11-bit word index at `position`, read most significant bit first.
    private static func wordIndex(at position: Int, in bytes: [UInt8]) -> Int {
        var index = 0
        for bit in 0..<bitsPerWord {  // R2: 11 iterations.
            let offset = position * bitsPerWord + bit
            let value = (bytes[offset / 8] >> (7 - UInt8(offset % 8))) & 1
            index = (index << 1) | Int(value)
        }
        return index
    }

    /// The 17 bytes twelve word indexes spell (the last byte's low 4 bits stay zero).
    private static func bytes(fromWordIndexes indexes: [Int]) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: entropyByteCount + 1)
        for (position, index) in indexes.enumerated() {  // R2: 12 iterations.
            for bit in 0..<bitsPerWord {  // R2: 11 iterations.
                guard (index >> (bitsPerWord - 1 - bit)) & 1 == 1 else { continue }
                let offset = position * bitsPerWord + bit
                bytes[offset / 8] |= 1 << (7 - UInt8(offset % 8))
            }
        }
        return bytes
    }

    // MARK: Typing

    /// The typed words, folded (case, accents, width) and with separators and numbering removed.
    /// Bounded by the typed length: at most 64 tokens are kept, far above the 12 a code has, so a
    /// pasted essay cannot make the count check walk it all.
    private static func tokens(of typed: String) -> [String] {
        let folded = typed.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;"))
        return folded.components(separatedBy: separators)
            .lazy
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".)-:")) }
            .filter { !$0.isEmpty && !$0.allSatisfy(\.isNumber) }
            .prefix(64)
            .map { $0 }
    }

    /// The list index of a typed word: an exact word, or a prefix of at least four letters of
    /// exactly one word (BIP39 English words are unique by their first four letters).
    private static func listIndex(of token: String) -> Int? {
        if let exact = wordIndexes[token] { return exact }
        guard token.count >= identifyingPrefixLength,
              let candidate = prefixIndexes[String(token.prefix(identifyingPrefixLength))],
              RecoveryCodeWordList.english[candidate].hasPrefix(token) else { return nil }
        return candidate
    }

    /// Word → list index.
    private static let wordIndexes: [String: Int] = Dictionary(
        uniqueKeysWithValues: RecoveryCodeWordList.english.enumerated().map { ($0.element, $0.offset) }
    )

    /// First four letters → list index, for the words at least four letters long.
    private static let prefixIndexes: [String: Int] = Dictionary(
        RecoveryCodeWordList.english.enumerated()
            .filter { $0.element.count >= identifyingPrefixLength }
            .map { (String($0.element.prefix(identifyingPrefixLength)), $0.offset) },
        uniquingKeysWith: { first, _ in first }
    )
}

/// Why a recovery code could not be made or read.
public nonisolated enum RecoveryCodeError: Error, Equatable, Sendable {
    /// Entropy of a length other than 16 bytes.
    case wrongEntropyLength
    /// `SecRandomCopyBytes` refused to produce entropy.
    case randomGeneratorFailed
    /// The typed code had this many words instead of 12.
    case wrongWordCount(Int)
    /// The word at this 1-based position is not a word of the list (nor a prefix of one).
    case unknownWord(position: Int)
    /// Every word is real but the checksum does not match: a word is wrong or out of order.
    case checksumMismatch
    /// A sealed escrow key opened, but to a key other than the one its hash names.
    case sealedKeyMismatch
}

// MARK: - The escrow seal

/// One sealed-backup escrow private key, sealed to a recovery public key with HPKE.
///
/// Opaque bytes plus the hash that names which escrow key is inside. What travels to iCloud in a
/// `RecoveryEscrowRecord` (the app maps one onto the other).
public nonisolated struct RecoveryEscrowSealedKey: Equatable, Sendable {
    /// SHA-256 of the sealed escrow key's raw X25519 public key: the HPKE authenticated data, and
    /// how a phone tells which of its escrow keys already has a sealed copy.
    public let escrowPublicKeyHash: Data
    /// The HPKE encapsulated key (the sender's ephemeral X25519 public key, 32 bytes).
    public let encapsulatedKey: Data
    /// The ChaCha20-Poly1305 ciphertext and tag of the escrow key's 32 raw bytes.
    public let ciphertext: Data

    /// A sealed key from its three parts.
    public init(escrowPublicKeyHash: Data, encapsulatedKey: Data, ciphertext: Data) {
        self.escrowPublicKeyHash = escrowPublicKeyHash
        self.encapsulatedKey = encapsulatedKey
        self.ciphertext = ciphertext
    }
}

/// HPKE (RFC 9180, base mode) between the sealed-backup escrow keys and the recovery key.
///
/// Suite `DHKEM(X25519, HKDF-SHA256)`, `HKDF-SHA256`, `ChaCha20-Poly1305` (CryptoKit's
/// `Curve25519_SHA256_ChachaPoly`), info ``FernletCryptoPurpose/KeyDerivation/recoveryEscrowHPKEV1``,
/// authenticated data = SHA-256 of the escrow public key. Sealing needs only the recovery PUBLIC
/// key, which is why any phone can add a newly minted escrow key to the set without the code.
public nonisolated enum RecoveryEscrowSeal {
    /// The HPKE suite every seal uses.
    private static let suite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly

    /// The authenticated data for an escrow key: SHA-256 of its raw public key.
    ///
    /// - Parameter escrowPublicKey: The escrow key's raw X25519 public key.
    /// - Returns: 32 bytes.
    public static func escrowPublicKeyHash(_ escrowPublicKey: Data) -> Data {
        Data(SHA256.hash(data: escrowPublicKey))
    }

    /// Seals one escrow private key to the recovery public key.
    ///
    /// - Parameters:
    ///   - escrowKey: The sealed-backup escrow private key.
    ///   - recoveryPublicKey: The recovery code's raw X25519 public key.
    /// - Returns: The sealed key, named by its escrow public key hash.
    /// - Throws: CryptoKit's error for a malformed recovery public key.
    public static func seal(
        _ escrowKey: Curve25519.KeyAgreement.PrivateKey,
        to recoveryPublicKey: Data
    ) throws -> RecoveryEscrowSealedKey {
        let recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recoveryPublicKey)
        let hash = escrowPublicKeyHash(escrowKey.publicKey.rawRepresentation)
        var sender = try HPKE.Sender(
            recipientKey: recipient, ciphersuite: suite,
            info: FernletCryptoPurpose.KeyDerivation.recoveryEscrowHPKEV1.data
        )
        let ciphertext = try sender.seal(escrowKey.rawRepresentation, authenticating: hash)
        return RecoveryEscrowSealedKey(
            escrowPublicKeyHash: hash, encapsulatedKey: sender.encapsulatedKey, ciphertext: ciphertext
        )
    }

    /// Opens one sealed escrow key with the recovery private key.
    ///
    /// - Parameters:
    ///   - sealed: The sealed key.
    ///   - recoveryKey: The private key a typed recovery code derived.
    /// - Returns: The escrow private key, checked to match the hash it was sealed under.
    /// - Throws: CryptoKit's authentication error for the wrong code or tampered bytes, and
    ///   ``RecoveryCodeError/sealedKeyMismatch`` when the opened key is not the one its hash names.
    public static func open(
        _ sealed: RecoveryEscrowSealedKey,
        with recoveryKey: Curve25519.KeyAgreement.PrivateKey
    ) throws -> Curve25519.KeyAgreement.PrivateKey {
        var recipient = try HPKE.Recipient(
            privateKey: recoveryKey, ciphersuite: suite,
            info: FernletCryptoPurpose.KeyDerivation.recoveryEscrowHPKEV1.data,
            encapsulatedKey: sealed.encapsulatedKey
        )
        let raw = try recipient.open(sealed.ciphertext, authenticating: sealed.escrowPublicKeyHash)
        let escrowKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)
        guard escrowPublicKeyHash(escrowKey.publicKey.rawRepresentation) == sealed.escrowPublicKeyHash else {
            throw RecoveryCodeError.sealedKeyMismatch
        }
        return escrowKey
    }
}
